/*
 * Copyright (c) 2019-2022, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software distributed under the License
 * is distributed on an "AS IS" BASIS,  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
 * or implied. See the License for the specific language governing permissions and limitations under
 * the License.
 */
#pragma once

#include <cudf_test/base_fixture.hpp>
#include <cudf_test/column_wrapper.hpp>
#include <cudf_test/type_lists.hpp>

#include <cudf/detail/iterator.cuh>
#include <cudf/detail/utilities/transform_unary_functions.cuh>  // for meanvar
#include <cudf/detail/utilities/vector_factories.hpp>
#include <cudf/utilities/default_stream.hpp>

#include <rmm/device_uvector.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/distance.h>
#include <thrust/equal.h>
#include <thrust/execution_policy.h>
#include <thrust/functional.h>
#include <thrust/host_vector.h>
#include <thrust/logical.h>
#include <thrust/transform.h>

#include <cub/device/device_reduce.cuh>

#include <bitset>
#include <cstdint>
#include <iostream>
#include <numeric>
#include <random>

// Base Typed test fixture for iterator test
template <typename T>
struct IteratorTest : public cudf::test::BaseFixture {
  // iterator test case which uses cub
  template <typename InputIterator, typename T_output>
  void iterator_test_cub(T_output expected, InputIterator d_in, int num_items)
  {
    T_output init = cudf::test::make_type_param_scalar<T_output>(0);
    rmm::device_uvector<T_output> dev_result(1, cudf::default_stream_value);

    // Get temporary storage size
    size_t temp_storage_bytes = 0;
    cub::DeviceReduce::Reduce(nullptr,
                              temp_storage_bytes,
                              d_in,
                              dev_result.begin(),
                              num_items,
                              thrust::minimum{},
                              init,
                              cudf::default_stream_value.value());

    // Allocate temporary storage
    rmm::device_buffer d_temp_storage(temp_storage_bytes, cudf::default_stream_value);

    // Run reduction
    cub::DeviceReduce::Reduce(d_temp_storage.data(),
                              temp_storage_bytes,
                              d_in,
                              dev_result.begin(),
                              num_items,
                              thrust::minimum{},
                              init,
                              cudf::default_stream_value.value());

    evaluate(expected, dev_result, "cub test");
  }

  // iterator test case which uses thrust
  template <typename InputIterator, typename T_output>
  void iterator_test_thrust(thrust::host_vector<T_output> const& expected,
                            InputIterator d_in,
                            int num_items)
  {
    InputIterator d_in_last = d_in + num_items;
    EXPECT_EQ(thrust::distance(d_in, d_in_last), num_items);
    auto dev_expected = cudf::detail::make_device_uvector_sync(expected);

    // using a temporary vector and calling transform and all_of separately is
    // equivalent to thrust::equal but compiles ~3x faster
    auto dev_results = rmm::device_uvector<bool>(num_items, cudf::default_stream_value);
    thrust::transform(rmm::exec_policy(cudf::default_stream_value),
                      d_in,
                      d_in_last,
                      dev_expected.begin(),
                      dev_results.begin(),
                      thrust::equal_to{});
    auto result = thrust::all_of(rmm::exec_policy(cudf::default_stream_value),
                                 dev_results.begin(),
                                 dev_results.end(),
                                 thrust::identity<bool>{});
    EXPECT_TRUE(result) << "thrust test";
  }

  template <typename T_output>
  void evaluate(T_output expected,
                rmm::device_uvector<T_output> const& dev_result,
                const char* msg = nullptr)
  {
    auto host_result = cudf::detail::make_host_vector_sync(dev_result);

    EXPECT_EQ(expected, host_result[0]) << msg;
  }

  template <typename T_output>
  void values_equal_test(thrust::host_vector<T_output> const& expected,
                         const cudf::column_device_view& col)
  {
    if (col.nullable()) {
      auto it_dev = cudf::detail::make_null_replacement_iterator(
        col, cudf::test::make_type_param_scalar<T_output>(0));
      iterator_test_thrust(expected, it_dev, col.size());
    } else {
      auto it_dev = col.begin<T_output>();
      iterator_test_thrust(expected, it_dev, col.size());
    }
  }
};
