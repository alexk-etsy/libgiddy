#pragma once
#ifndef SRC_KERNELS_DECOMPRESSION_RUN_POSITION_CUH
#define SRC_KERNELS_DECOMPRESSION_RUN_POSITION_CUH

#include "kernels/common.cuh"
#include "cuda/on_device/primitives/warp.cuh"
#include "cuda/on_device/primitives/block.cuh"
#include "cuda/on_device/math.cuh"
#include "kernels/reduction/scan.cuh"
#include "cuda/on_device/generic_shuffle.cuh"
#include "cuda/functors.hpp"

namespace cuda {
namespace kernels {
namespace decompression {
namespace run_position_encoding {

using namespace grid_info::linear;

namespace detail {

// Everything a block needs to know in order
// to perform decompression, which does not
// involve any significant computation and can
// be allowed to be computed redundantly by all threads
template<unsigned IndexSize, unsigned PositionOffsetSize>
struct segment_decompression_params_t {
	uint_t<IndexSize>           first_run_index; // of the runs intersecting the segment
	uint_t<PositionOffsetSize>  num_runs;  // intersecting the segment; we know it fits in this type!
	uint_t<IndexSize>           uncompressed_start_position;
	uint_t<PositionOffsetSize>  decompressed_length;
		// Even though position_offset_type is the type of the offset,
		// meaning that, supposedly, the length could be
		// the unrepresentable 2^(CHAR_BIT * sizeof(position_offset_type),
		// this can't actually happen since the anchoring period
		// is also of type position_offset_type. In fact, this is
		// almost always equal to the anchoring period
};

using namespace grid_info::linear;

namespace block {

template<unsigned IndexSize, unsigned UncompressedSize, unsigned PositionOffsetSize, bool PositionsAreRelative>
__forceinline__ __device__ void decompress_a_segment_with_few_runs(
	uint_t<UncompressedSize>*          __restrict__            decompressed,
	// this may be a pointer to the absolute beginning of the input data,
	// or just the beginning of the segment - depending on whether PositionsAreRelative
	// or not.
	const uint_t<PositionOffsetSize>*  __restrict__            run_start_positions, // for this segment only
	const uint_t<UncompressedSize>*    __restrict__            run_data,            // for this segment only
	const segment_decompression_params_t<IndexSize, PositionOffsetSize>&  params)
{
	using uncompressed_type    = uint_t<UncompressedSize>;
	using position_offset_type = uint_t<PositionOffsetSize>;
	using index_type           = uint_t<IndexSize>;
	enum {
		elements_per_thread_write = UncompressedSize >= sizeof(unsigned) ?
			1 : sizeof(unsigned) / UncompressedSize
	};


	// TODO: Should we special-case segments which only have a single run,
	// or a couple of runs?

	// Note: We have two loops here, the outer one (the block-stride loop)
	// and the inner one (run-iteration loop). Now, because we synch the
	// warp lanes' knowledge of runs they've seen with each iteration of
	// the outer loop, we have that the _maximum_ number of iterations
	// of a lane on the inner loop is the increase in of
	// first_possible_run_for_next_write for the next outer-loop iteration.
	// In the next iteration of the outer loop, the number of possible
	// iterations of the inner loop decreases by that number.
	//
	// In other words, the total number of iterations of the inner loop
	// (when we take the maximum over the warp due to predicated execution),
	// over all iterators of the outer loop, is
	//
	//   I = R + L / W = L ( R/L + 1/W ) = L ( 1/A + 1/W )
	//
	// where
	// R = num_runs
	// L = params.decompressed_length
	// A = average run length
	//
	// and the number of iterations per element written is
	//
	// I / (L/W) = L/(L/W) ( 1/A + 1/W ) = W ( 1/A + 1/W ) = 1 + W/A
	//
	// This is pretty good, even if runs involve memory reads; after all,
	// other warps have likely already read that, so they'll be mostly
	// reads from L1 cache. The L1 cache will be no less than 16K, so
	// with any bit of fairness in warp scheduling we should not need
	// repeated reads from main memory.

	index_type first_possible_run_for_next_write = 0;
		// this will increase as we advance with our writes beyond further
		// and further runs

	position_offset_type write_position;
		// Keeping this out of the lambda below since we'll use it later
		// to decide which threads

	// Note that instead of at_block_stride we could do the loop ourselves
	// and avoid the + uncompressed_segment_start_position for absolute
	// positions; but maybe the optimizer takes that out of the loop anyway?
	auto locate_and_perform_next_write = [&](position_offset_type relative_write_position) {

		using write_type = promoted_size<uncompressed_type>;
		static_assert(sizeof(write_type) / UncompressedSize == elements_per_thread_write, "Type/size mismatch");

		write_position = relative_write_position +
			(PositionsAreRelative ? 0 : params.uncompressed_start_position);
			// note that this value is different for each lane; and that
			// they are spaced 4 bytes - not 4 positions - from each other

		index_type run_index = first_possible_run_for_next_write + 1;
			// TODO: Perhaps hoist this out of the function?

		array<uint_t<UncompressedSize>, elements_per_thread_write> thread_write_buffer;
			// Notes:
			// * The total size of this variable is a multiple of sizeof(unsigned)
			// * This should be optimized into registers

		index_type run_covering_current_element;

		#pragma unroll
		for(unsigned element_within_thread_write = 0;
		    element_within_thread_write < elements_per_thread_write;
		    element_within_thread_write++)
		{
			#pragma unroll
			for(; run_index < params.num_runs; run_index++)
			{
				if (run_start_positions[run_index] >
				    (write_position + element_within_thread_write)) { break; }
			}
			run_covering_current_element = run_index - 1;
				// so it may be num_runs_used - 1 - in which case we haven't
				// checked run_start_positions for the next run's start pos
			thread_write_buffer[element_within_thread_write] = run_data[run_covering_current_element];
		}

		*(reinterpret_cast<write_type*>(decompressed + write_position)) =
			reinterpret_cast<const write_type&>(thread_write_buffer);

		{
			// At this point we're done with the current write; but - note that
			// different lanes may have been considering different runs (if the lane
			// is not wholly covered by a single run) - with the last lane having
			// examined the farthest run. Since in subsequent runs we will only be
			// writing to farther elements in the output, it's useless for _any_
			// lanes to consider any run before this
			// last-run-considered-by-the-last-lane. So let's get it:

			auto next_relative_write_position_for_this_thread =
				relative_write_position + grid_info::linear::block::length() * elements_per_thread_write;
			if (next_relative_write_position_for_this_thread < params.decompressed_length) {
				first_possible_run_for_next_write =
					primitives::warp::get_from_last_lane(run_covering_current_element);
			}
			// No 'else' here, since in the 'else' case that was the last write
			// for this thread in this segment
		}

	};

	// I'd thought of making this a separate function, with or without the lambda we call here,
	// but we use the 'innards' of the lambda below for the slack so it won't be much 'cleaner'

	auto truncated_decompressed_length =
		clear_lower_k_bits(params.decompressed_length, log2_constexpr(elements_per_thread_write));
		// in fact, this will round down to a multiple of 4 = sizeof(int)
	position_offset_type relative_write_position = thread::index_in_block() * elements_per_thread_write;
	#pragma unroll
	for(;
	    relative_write_position  < truncated_decompressed_length;
		relative_write_position  += ::grid_info::linear::block::length() * elements_per_thread_write)
	{
		locate_and_perform_next_write(relative_write_position);
	}



	//
	//
	// From here on - just handling the slack
	//
	//
	// We need to write to the last few elements, which can't be grouped
	// into a single 4-byte write. We'll do that with some threads
	// performing single-element writes

	if (elements_per_thread_write > 1) {

		auto num_actually_decompressed = truncated_decompressed_length;
		auto num_slack_elements = params.decompressed_length - num_actually_decompressed;
		if (num_slack_elements == 0) { return; }

		if (truncated_decompressed_length == 0) {
			if (thread::index_in_block() >= num_slack_elements) { return; }
			first_possible_run_for_next_write = 0;
		}
		else {
			auto this_thread_wrote_last_element_so_far =
				(relative_write_position == (truncated_decompressed_length - elements_per_thread_write) +
					elements_per_thread_write * grid_info::linear::block::length());
			if (primitives::warp::all_satisfy(not this_thread_wrote_last_element_so_far)) { return; }
			auto lane_which_wrote_the_last_element_so_far =
				primitives::warp::first_lane_satisfying(this_thread_wrote_last_element_so_far);
			auto lane_which_saw_the_farthest_run_so_far = lane_which_wrote_the_last_element_so_far;
			primitives::warp::update_from_lane(first_possible_run_for_next_write, lane_which_saw_the_farthest_run_so_far);
			if (lane::index() >= num_slack_elements) { return; }
		}

		auto slack_write_position = num_actually_decompressed + lane::index() +
			(PositionsAreRelative ? 0 : params.uncompressed_start_position);

		auto run_index = first_possible_run_for_next_write + 1;

		while (run_index < params.num_runs
		       and run_start_positions[run_index] <= slack_write_position)
		{
			run_index++;
		}
		auto run_covering_current_element = run_index - 1;
		decompressed[slack_write_position] = run_data[run_covering_current_element];
	}
}

template<unsigned IndexSize, unsigned UncompressedSize, unsigned PositionOffsetSize, bool PositionsAreRelative>
__forceinline__ __device__ void decompress_segment(
	uint_t<UncompressedSize>*          __restrict__            decompressed,
	// this may be a pointer to the absolute beginning of the input data,
	// or just the beginning of the segment - depending on whether PositionsAreRelative
	// or not.
	const uint_t<PositionOffsetSize>*  __restrict__            run_start_positions, // for this segment only
	const uint_t<UncompressedSize>*    __restrict__            run_data,            // for this segment only
	const segment_decompression_params_t<IndexSize, PositionOffsetSize>&  params)
{
	// TODO: Act differently for blocks with high, low and super-low average
	// run length. (Doing that may require additional segment decompression
	// parameters to be computed.)

	decompress_a_segment_with_few_runs<IndexSize, UncompressedSize, PositionOffsetSize, PositionsAreRelative>(
		decompressed, run_start_positions, run_data, params);
}


// TODO: perhaps convert this into a named constructor idiom for
// segment_decompression_params_t ?
template<unsigned IndexSize, unsigned UncompressedSize, unsigned PositionOffsetSize, bool PositionsAreRelative>
__forceinline__ __device__ segment_decompression_params_t<IndexSize, PositionOffsetSize>
resolve_segment_decompression_params(
	const uint_t<PositionOffsetSize>*  __restrict__  run_start_positions,
	const uint_t<IndexSize>*           __restrict__  position_anchors,
	uint_t<IndexSize>                                anchoring_period,
	uint_t<IndexSize>                                num_anchors,
	uint_t<IndexSize>                                num_element_runs,
	uint_t<IndexSize>                                total_uncompressed_length)
{
	using position_offset_type = uint_t<PositionOffsetSize>;

	segment_decompression_params_t<IndexSize, PositionOffsetSize> params;
	// Each block is responsible for a certain number of output elements, not of
	// input elements (the latter option runs too much of a risk of block
	// workload imbalance). The block's output elements range from one
	// position anchor to the next (or to the end if it's the last one)

	auto anchor_index = grid_info::linear::block::index();
	auto next_anchor_index  = grid_info::linear::block::index() + 1;
	params.uncompressed_start_position = anchor_index * anchoring_period;

	auto is_last_segment = (next_anchor_index == num_anchors);
	params.decompressed_length = is_last_segment ?
		total_uncompressed_length - params.uncompressed_start_position :
		anchoring_period;

	params.first_run_index = position_anchors[anchor_index];
	uint_t<IndexSize> one_past_last_run_index;
	if (is_last_segment) { one_past_last_run_index = num_element_runs; }
	else {
		// Here is the one point where position encoding is less friendly than
		// length encoding: The anchors are not necessarily aligned to the
		// beginning of the run; but in RLE, the anchors must include an offset
		// value into the run, while in RPE that's not necessary. ... except
		// that we do need a bit of work to replace that information. This
		// is where we do that work, in order figure out whether the run at
		// the next anchor still has some elements in it belonging to this
		// segment. It will cost us an extra read :-(
		auto run_index_at_next_anchor = position_anchors[next_anchor_index];
		auto next_uncompressed_segment_start_position =
			params.uncompressed_start_position + anchoring_period;

		one_past_last_run_index = run_index_at_next_anchor +
			(run_start_positions[run_index_at_next_anchor] < next_uncompressed_segment_start_position);
		// TODO: Can we avoid this extra read, pretend we do have extras,
		// and just notice there's zero of them later on?
		// TODO: Would it be worth it, to, say, use one bit of the anchor
		// to store a flag indicating whether or not we its aligned
		// with the start of a run? It would make our lives easier here...
		// although, on the other hand, it would mess up separation of columns.
		// Hmm.
	}
	params.num_runs = one_past_last_run_index - params.first_run_index;
	return params;
}

} // namespace block

} // namespace detail

/**
 * Decompress a Run-Position-Encoded (RPE) compressed column,
 * which is made up of consecutive runs of identically-valued
 * elements (typically longer runs), using periodic anchoring
 * information.
 *
 * @note (max anchoring period)
 *
 * @note we assume all input arrays are well-aligned.
 *
 * @todo more thought for uncompressed sizes other than 4
 *
 */
template<unsigned IndexSize, unsigned UncompressedSize, unsigned PositionOffsetSize, bool PositionsAreRelative>
__global__ void decompress(
	uint_t<UncompressedSize>*          __restrict__  decompressed,
	const uint_t<UncompressedSize>*    __restrict__  run_data,
	const uint_t<PositionOffsetSize>*  __restrict__  run_start_positions,
	const uint_t<IndexSize>*           __restrict__  position_anchors,
	uint_t<IndexSize>                                anchoring_period,
	uint_t<IndexSize>                                num_anchors,
	uint_t<IndexSize>                                num_element_runs, // = length of the run_* arrays
	uint_t<IndexSize>                                uncompressed_length)
{
	using uncompressed_type    = uint_t<UncompressedSize>;
	using position_offset_type = uint_t<PositionOffsetSize>;

	static_assert(is_power_of_2(IndexSize), "IndexSize is not a power of 2");
	static_assert(is_power_of_2(PositionOffsetSize), "sizeof(position_offset_type) is not a power of 2");
	static_assert(PositionsAreRelative or PositionOffsetSize >= IndexSize,
		"If run positions are in absolute values, their type must be able to cover the entire "
		"potential range of data (i.e. their type must be at least as large as the size type");


	// Decompression is performed by individual warps. Each warp works on a single anchored segment.
	//
	// TODO: For large anchoring periods, consider breaking up segments into consecutive pieces,
	// with a warp handling each of them. While this will require an iterative search of the
	// start position by each of the warps, that should not take more than a few iterations, seeing
	// how position anchors should never ridiculously high (e.g. 16K is already very high), and
	// each warp should like to process at least warp_size times, say, 32 elements - i.e. at most
	// 16 warps. Thus with a reasonably-distributed sequence of runs, the search will conclude in
	// a single iteration (an effective guess) and with the worst-case distribution the search
	// would not be terrible because we'll recalculate the average run length at every iteration,
	//

	auto block_params = detail::block::resolve_segment_decompression_params
		<IndexSize, UncompressedSize, PositionOffsetSize, PositionsAreRelative>(
		run_start_positions, position_anchors, anchoring_period,
		num_anchors, num_element_runs, uncompressed_length);

	detail::block::decompress_segment<IndexSize, UncompressedSize, PositionOffsetSize, PositionsAreRelative>(
		PositionsAreRelative ? decompressed + block_params.uncompressed_start_position : decompressed,
			// TODO: Would it be better to use at_start_of_first_run instead of start_ ?
		run_start_positions  + block_params.first_run_index,
		run_data             + block_params.first_run_index,
		block_params); // Note we don't pass the anchor arrays
}


template<unsigned IndexSize, unsigned UncompressedSize, unsigned PositionOffsetSize, bool PositionsAreRelative>
class launch_config_resolution_params_t final : public cuda::launch_config_resolution_params_t {
public:
	using parent = cuda::launch_config_resolution_params_t;
public:
	launch_config_resolution_params_t(
		device::properties_t            device_properties_,
		size_t                          uncompressed_length,
		size_t                          position_anchoring_period,
		optional<shared_memory_size_t>  dynamic_shared_mem_limit = nullopt) :
		cuda::launch_config_resolution_params_t(
			device_properties_,
			device_function_t(decompress<IndexSize, UncompressedSize, PositionOffsetSize, PositionsAreRelative>),
			dynamic_shared_mem_limit
		)
	{
		enum { elements_per_thread_write =
			UncompressedSize >= sizeof(unsigned) ? 1 : sizeof(unsigned) / UncompressedSize };

		auto num_anchored_segments =
			util::div_rounding_up(uncompressed_length, position_anchoring_period);
		auto num_thread_writes_per_segment = div_rounding_up(position_anchoring_period, elements_per_thread_write);

		grid_construction_resolution  = block;
		length                        = num_anchored_segments;
		serialization_option          = none;
		quanta.threads_in_block       = warp_size;
		block_resolution_constraints.fixed_threads_per_block
		                              = std::min<grid_block_dimension_t>(
		                            	  num_thread_writes_per_segment, 2 * warp_size);
			// This should probably be architecture-specific, and perhaps
			// even depend on the data distribution if that's known.
			//
			// The point of setting this limit is make the block-length 'jump' between
			// consecutive writes by the same warp shorter, so that it has less work
			// looking for the next positions to write to. With an average run length
			// of 2, the number of iterations over warp_size-long sequences of runs
			// will on the average be less than 2 (i.e. one advance and two checks).
	};
};

} // namespace run_position_encoding
} // namespace decompression
} // namespace kernels
} // namespace cuda

#endif /* SRC_KERNELS_DECOMPRESSION_RUN_POSITION_CUH */
