/*
 * Copyright (c) 2022, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "io/comp/nvcomp_adapter.hpp"
#include "io/text/device_data_chunks.hpp"
#include "io/utilities/config_utils.hpp"

#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/io/text/data_chunk_source_factories.hpp>
#include <cudf/utilities/default_stream.hpp>
#include <cudf/utilities/error.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_buffer.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/host_vector.h>
#include <thrust/iterator/zip_iterator.h>
#include <thrust/system/cuda/experimental/pinned_allocator.h>
#include <thrust/transform.h>

#include <fstream>
#include <limits>

namespace cudf::io::text {

namespace {

/**
 * @brief Transforms offset tuples of the form [compressed_begin, compressed_end,
 * decompressed_begin, decompressed_end] into span tuples of the form [compressed_device_span,
 * decompressed_device_span] based on the provided pointers.
 */
struct bgzip_nvcomp_transform_functor {
  uint8_t const* compressed_ptr;
  uint8_t* decompressed_ptr;

  __device__ thrust::tuple<device_span<const uint8_t>, device_span<uint8_t>> operator()(
    thrust::tuple<std::size_t, std::size_t, std::size_t, std::size_t> t)
  {
    auto const compressed_begin   = thrust::get<0>(t);
    auto const compressed_end     = thrust::get<1>(t);
    auto const decompressed_begin = thrust::get<2>(t);
    auto const decompressed_end   = thrust::get<3>(t);
    return thrust::make_tuple(device_span<const uint8_t>{compressed_ptr + compressed_begin,
                                                         compressed_end - compressed_begin},
                              device_span<uint8_t>{decompressed_ptr + decompressed_begin,
                                                   decompressed_end - decompressed_begin});
  }
};

class bgzip_data_chunk_reader : public data_chunk_reader {
 private:
  template <typename IntType>
  static IntType read_int(char* data)
  {
    IntType result{};
    // we assume little-endian
    std::memcpy(&result, &data[0], sizeof(result));
    return result;
  }

  struct bgzip_header {
    int block_size;
    int extra_length;
    [[nodiscard]] int data_size() const { return block_size - extra_length - 20; }
  };

  bgzip_header read_header()
  {
    std::array<char, 12> buffer{};
    _data_stream->read(buffer.data(), sizeof(buffer));
    std::array<uint8_t, 4> const expected_header{{31, 139, 8, 4}};
    CUDF_EXPECTS(
      std::equal(
        expected_header.begin(), expected_header.end(), reinterpret_cast<uint8_t*>(buffer.data())),
      "malformed BGZIP header");
    // we ignore the remaining bytes of the fixed header, since they don't matter to us
    auto const extra_length = read_int<uint16_t>(&buffer[10]);
    uint16_t extra_offset{};
    // read all the extra subfields
    while (extra_offset < extra_length) {
      auto const remaining_size = extra_length - extra_offset;
      CUDF_EXPECTS(remaining_size >= 4, "invalid extra field length");
      // a subfield consists of 2 identifier bytes and a uint16 length
      // 66/67 identifies a BGZIP block size field, we skip all other fields
      _data_stream->read(buffer.data(), 4);
      extra_offset += 4;
      auto const subfield_size = read_int<uint16_t>(&buffer[2]);
      if (buffer[0] == 66 && buffer[1] == 67) {
        // the block size subfield contains a single uint16 value, which is block_size - 1
        CUDF_EXPECTS(subfield_size == sizeof(uint16_t), "malformed BGZIP extra subfield");
        _data_stream->read(buffer.data(), sizeof(uint16_t));
        _data_stream->seekg(remaining_size - 6, std::ios_base::cur);
        auto const block_size_minus_one = read_int<uint16_t>(&buffer[0]);
        return {block_size_minus_one + 1, extra_length};
      } else {
        _data_stream->seekg(subfield_size, std::ios_base::cur);
        extra_offset += subfield_size;
      }
    }
    CUDF_FAIL("missing BGZIP size extra subfield");
  }

  struct bgzip_footer {
    uint32_t decompressed_size;
  };

  bgzip_footer read_footer()
  {
    std::array<char, 8> buffer{};
    _data_stream->read(buffer.data(), sizeof(buffer));
    return {read_int<uint32_t>(&buffer[4])};
  }

  template <typename T>
  using pinned_host_vector =
    thrust::host_vector<T, thrust::system::cuda::experimental::pinned_allocator<T>>;

  template <typename T>
  static void copy_to_device(const pinned_host_vector<T>& host,
                             rmm::device_uvector<T>& device,
                             rmm::cuda_stream_view stream)
  {
    device.resize(host.size(), stream);
    CUDF_CUDA_TRY(cudaMemcpyAsync(
      device.data(), host.data(), host.size() * sizeof(T), cudaMemcpyHostToDevice, stream.value()));
  }

  struct decompression_blocks {
    static constexpr std::size_t default_buffer_alloc =
      1 << 24;  // 16MB buffer allocation, resized on demand
    static constexpr std::size_t default_offset_alloc =
      1 << 16;  // 64k offset allocation, resized on demand

    cudaEvent_t event;
    pinned_host_vector<char> h_compressed_blocks;
    pinned_host_vector<std::size_t> h_compressed_offsets;
    pinned_host_vector<std::size_t> h_decompressed_offsets;
    rmm::device_uvector<char> d_compressed_blocks;
    rmm::device_uvector<char> d_decompressed_blocks;
    rmm::device_uvector<std::size_t> d_compressed_offsets;
    rmm::device_uvector<std::size_t> d_decompressed_offsets;
    rmm::device_uvector<device_span<const uint8_t>> d_compressed_spans;
    rmm::device_uvector<device_span<uint8_t>> d_decompressed_spans;
    rmm::device_uvector<compression_result> d_decompression_results;
    std::size_t compressed_size_with_headers{};
    std::size_t max_decompressed_size{};
    // this is usually equal to decompressed_size()
    // unless we are in the last chunk, where it's limited by _local_end
    std::size_t available_decompressed_size{};
    std::size_t read_pos{};
    bool is_decompressed{};

    decompression_blocks(rmm::cuda_stream_view init_stream)
      : d_compressed_blocks(0, init_stream),
        d_decompressed_blocks(0, init_stream),
        d_compressed_offsets(0, init_stream),
        d_decompressed_offsets(0, init_stream),
        d_compressed_spans(0, init_stream),
        d_decompressed_spans(0, init_stream),
        d_decompression_results(0, init_stream)
    {
      CUDF_CUDA_TRY(cudaEventCreate(&event));
      h_compressed_blocks.reserve(default_buffer_alloc);
      h_compressed_offsets.reserve(default_offset_alloc);
      h_compressed_offsets.push_back(0);
      h_decompressed_offsets.reserve(default_offset_alloc);
      h_decompressed_offsets.push_back(0);
    }

    void decompress(rmm::cuda_stream_view stream)
    {
      if (is_decompressed) { return; }
      copy_to_device(h_compressed_blocks, d_compressed_blocks, stream);
      copy_to_device(h_compressed_offsets, d_compressed_offsets, stream);
      copy_to_device(h_decompressed_offsets, d_decompressed_offsets, stream);
      d_decompressed_blocks.resize(decompressed_size(), stream);
      d_compressed_spans.resize(num_blocks(), stream);
      d_decompressed_spans.resize(num_blocks(), stream);
      d_decompression_results.resize(num_blocks(), stream);

      auto offset_it = thrust::make_zip_iterator(d_compressed_offsets.begin(),
                                                 d_compressed_offsets.begin() + 1,
                                                 d_decompressed_offsets.begin(),
                                                 d_decompressed_offsets.begin() + 1);
      auto span_it =
        thrust::make_zip_iterator(d_compressed_spans.begin(), d_decompressed_spans.begin());
      thrust::transform(
        rmm::exec_policy_nosync(stream),
        offset_it,
        offset_it + num_blocks(),
        span_it,
        bgzip_nvcomp_transform_functor{reinterpret_cast<uint8_t const*>(d_compressed_blocks.data()),
                                       reinterpret_cast<uint8_t*>(d_decompressed_blocks.begin())});
      if (decompressed_size() > 0) {
        if (cudf::io::detail::nvcomp_integration::is_all_enabled()) {
          cudf::io::nvcomp::batched_decompress(cudf::io::nvcomp::compression_type::DEFLATE,
                                               d_compressed_spans,
                                               d_decompressed_spans,
                                               d_decompression_results,
                                               max_decompressed_size,
                                               decompressed_size(),
                                               stream);
        } else {
          gpuinflate(d_compressed_spans,
                     d_decompressed_spans,
                     d_decompression_results,
                     gzip_header_included::NO,
                     stream);
        }
      }
      is_decompressed = true;
    }

    void reset()
    {
      h_compressed_blocks.resize(0);
      h_compressed_offsets.resize(1);
      h_decompressed_offsets.resize(1);
      // shrinking doesn't allocate/free, so we don't need to worry about streams
      auto stream = cudf::default_stream_value;
      d_compressed_blocks.resize(0, stream);
      d_decompressed_blocks.resize(0, stream);
      d_compressed_offsets.resize(0, stream);
      d_decompressed_offsets.resize(0, stream);
      d_compressed_spans.resize(0, stream);
      d_decompressed_spans.resize(0, stream);
      d_decompression_results.resize(0, stream);
      compressed_size_with_headers = 0;
      max_decompressed_size        = 0;
      available_decompressed_size  = 0;
      read_pos                     = 0;
      is_decompressed              = false;
    }

    [[nodiscard]] std::size_t num_blocks() const { return h_compressed_offsets.size() - 1; }

    [[nodiscard]] std::size_t compressed_size() const { return h_compressed_offsets.back(); }

    [[nodiscard]] std::size_t decompressed_size() const { return h_decompressed_offsets.back(); }

    [[nodiscard]] std::size_t remaining_size() const
    {
      return available_decompressed_size - read_pos;
    }

    void read_block(bgzip_header header, std::istream& stream)
    {
      h_compressed_blocks.resize(h_compressed_blocks.size() + header.data_size());
      stream.read(h_compressed_blocks.data() + compressed_size(), header.data_size());
    }

    void add_block_offsets(bgzip_header header, bgzip_footer footer)
    {
      max_decompressed_size =
        std::max<std::size_t>(footer.decompressed_size, max_decompressed_size);
      h_compressed_offsets.push_back(compressed_size() + header.data_size());
      h_decompressed_offsets.push_back(decompressed_size() + footer.decompressed_size);
    }

    void consume_bytes(std::size_t size)
    {
      CUDF_EXPECTS(size <= remaining_size(), "out of bounds");
      read_pos += size;
    }
  };

  void read_next_compressed_chunk(std::size_t requested_size)
  {
    std::swap(_curr_blocks, _prev_blocks);
    if (_curr_blocks.is_decompressed) {
      // synchronize on the last decompression + copy, so we don't clobber any buffers
      CUDF_CUDA_TRY(cudaEventSynchronize(_curr_blocks.event));
    }
    _curr_blocks.reset();
    // read chunks until we have enough decompressed data
    while (_curr_blocks.decompressed_size() < requested_size) {
      // calling peek on an already EOF stream causes it to fail, we need to avoid that
      if (_data_stream->eof()) { break; }
      // peek is necessary if we are already at the end, but didn't try to read another byte
      _data_stream->peek();
      if (_data_stream->eof() || _compressed_pos > _compressed_end) { break; }
      auto header = read_header();
      _curr_blocks.read_block(header, *_data_stream);
      auto footer = read_footer();
      _curr_blocks.add_block_offsets(header, footer);
      // for the last GZIP block, we restrict ourselves to the bytes up to _local_end
      // but only for the reader, not for decompression!
      if (_compressed_pos == _compressed_end) {
        _curr_blocks.available_decompressed_size += _local_end;
        _compressed_pos += header.block_size;
        break;
      } else {
        _curr_blocks.available_decompressed_size += footer.decompressed_size;
        _compressed_pos += header.block_size;
      }
    }
  }

  constexpr static std::size_t chunk_load_size = 1 << 24;  // load 16 MB of data by default

 public:
  bgzip_data_chunk_reader(std::unique_ptr<std::istream> input_stream,
                          uint64_t virtual_begin,
                          uint64_t virtual_end)
    : _data_stream(std::move(input_stream)),
      _prev_blocks{cudf::default_stream_value},  // here we can use the default stream because
      _curr_blocks{cudf::default_stream_value},  // we only initialize empty device_uvectors
      _local_end{virtual_end & 0xFFFFu},
      _compressed_pos{virtual_begin >> 16},
      _compressed_end{virtual_end >> 16}
  {
    // set failbit to throw on IO failures
    _data_stream->exceptions(std::istream::failbit);
    // seek to the beginning of the provided compressed offset
    _data_stream->seekg(_compressed_pos, std::ios_base::cur);
    // read the first blocks
    read_next_compressed_chunk(chunk_load_size);
    // seek to the beginning of the provided local offset
    auto const local_pos = virtual_begin & 0xFFFFu;
    if (local_pos > 0) {
      CUDF_EXPECTS(_curr_blocks.h_compressed_offsets.size() > 1 &&
                     local_pos < _curr_blocks.h_compressed_offsets[1],
                   "local part of virtual offset is out of bounds");
      _curr_blocks.consume_bytes(local_pos);
    }
  }

  void skip_bytes(std::size_t read_size) override
  {
    while (read_size > _curr_blocks.remaining_size()) {
      read_size -= _curr_blocks.remaining_size();
      _curr_blocks.consume_bytes(_curr_blocks.remaining_size());
      read_next_compressed_chunk(chunk_load_size);
      // calling peek on an already EOF stream causes it to fail, we need to avoid that
      if (_data_stream->eof()) { break; }
      // peek is necessary if we are already at the end, but didn't try to read another byte
      _data_stream->peek();
      if (_data_stream->eof() || _compressed_pos > _compressed_end) { break; }
    }
    read_size = std::min(read_size, _curr_blocks.remaining_size());
    _curr_blocks.consume_bytes(read_size);
  }

  std::unique_ptr<device_data_chunk> get_next_chunk(std::size_t read_size,
                                                    rmm::cuda_stream_view stream) override
  {
    CUDF_FUNC_RANGE();
    if (read_size <= _curr_blocks.remaining_size()) {
      _curr_blocks.decompress(stream);
      rmm::device_uvector<char> data(read_size, stream);
      CUDF_CUDA_TRY(
        cudaMemcpyAsync(data.data(),
                        _curr_blocks.d_decompressed_blocks.data() + _curr_blocks.read_pos,
                        read_size,
                        cudaMemcpyDeviceToDevice,
                        stream.value()));
      // record the host-to-device copy, decompression and device copy
      CUDF_CUDA_TRY(cudaEventRecord(_curr_blocks.event, stream.value()));
      _curr_blocks.consume_bytes(read_size);
      return std::make_unique<device_uvector_data_chunk>(std::move(data));
    }
    read_next_compressed_chunk(read_size /* - _curr_blocks.remaining_size()*/);
    _prev_blocks.decompress(stream);
    _curr_blocks.decompress(stream);
    read_size = std::min(read_size, _prev_blocks.remaining_size() + _curr_blocks.remaining_size());
    rmm::device_uvector<char> data(read_size, stream);
    CUDF_CUDA_TRY(cudaMemcpyAsync(data.data(),
                                  _prev_blocks.d_decompressed_blocks.data() + _prev_blocks.read_pos,
                                  _prev_blocks.remaining_size(),
                                  cudaMemcpyDeviceToDevice,
                                  stream.value()));
    CUDF_CUDA_TRY(cudaMemcpyAsync(data.data() + _prev_blocks.remaining_size(),
                                  _curr_blocks.d_decompressed_blocks.data() + _curr_blocks.read_pos,
                                  read_size - _prev_blocks.remaining_size(),
                                  cudaMemcpyDeviceToDevice,
                                  stream.value()));
    // record the host-to-device copy, decompression and device copy
    CUDF_CUDA_TRY(cudaEventRecord(_curr_blocks.event, stream.value()));
    CUDF_CUDA_TRY(cudaEventRecord(_prev_blocks.event, stream.value()));
    read_size -= _prev_blocks.remaining_size();
    _prev_blocks.consume_bytes(_prev_blocks.remaining_size());
    _curr_blocks.consume_bytes(read_size);
    return std::make_unique<device_uvector_data_chunk>(std::move(data));
  }

 private:
  std::unique_ptr<std::istream> _data_stream;
  decompression_blocks _prev_blocks;
  decompression_blocks _curr_blocks;
  std::size_t _local_end;
  std::size_t _compressed_pos;
  std::size_t _compressed_end;
};

class bgzip_data_chunk_source : public data_chunk_source {
 public:
  bgzip_data_chunk_source(std::string_view filename, uint64_t virtual_begin, uint64_t virtual_end)
    : _filename{filename}, _virtual_begin{virtual_begin}, _virtual_end{virtual_end}
  {
  }

  [[nodiscard]] std::unique_ptr<data_chunk_reader> create_reader() const override
  {
    return std::make_unique<bgzip_data_chunk_reader>(
      std::make_unique<std::ifstream>(_filename, std::ifstream::in), _virtual_begin, _virtual_end);
  }

 private:
  std::string _filename;
  uint64_t _virtual_begin;
  uint64_t _virtual_end;
};

}  // namespace

std::unique_ptr<data_chunk_source> make_source_from_bgzip_file(std::string_view filename,
                                                               uint64_t virtual_begin,
                                                               uint64_t virtual_end)
{
  return std::make_unique<bgzip_data_chunk_source>(filename, virtual_begin, virtual_end);
}

std::unique_ptr<data_chunk_source> make_source_from_bgzip_file(std::string_view filename)
{
  return std::make_unique<bgzip_data_chunk_source>(
    filename, 0, std::numeric_limits<uint64_t>::max());
}

}  // namespace cudf::io::text
