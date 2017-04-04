
#include "kernel_wrappers/common.h"
#include "util/endianness.h"
#ifdef __CUDACC__
#include "kernels/decompression/discard_zero_bytes_fixed.cuh"
#endif

namespace cuda {
namespace kernels {
namespace decompression {
namespace discard_zero_bytes {
namespace fixed_width {

using util::endianness_t;

#ifndef __CUDACC__
enum : serialization_factor_t { DefaultSerializationFactor = 32 };
#endif

// TODO: This currently ignores the possibility of a sorted variant of the kernel

template<
	unsigned IndexSize, unsigned UncompressedSize, unsigned CompressedSize,
	endianness_t UncompressedEndianness  = util::compilation_target_endianness(),
	serialization_factor_t SerializationFactor = DefaultSerializationFactor>
class kernel: public cuda::registered::kernel_t {
public:
	REGISTERED_KERNEL_WRAPPER_BOILERPLATE_DEFINITIONS(kernel);

	using uncompressed_type = util::uint_t<UncompressedSize>;
	using compressed_type = util::uint_t<CompressedSize>;
};

#ifdef __CUDACC__

template<
	unsigned IndexSize, unsigned UncompressedSize, unsigned CompressedSize,
	endianness_t UncompressedEndianness, serialization_factor_t SerializationFactor>
launch_configuration_t kernel<
	IndexSize, UncompressedSize, CompressedSize, UncompressedEndianness, SerializationFactor
	>::resolve_launch_configuration(
	device::properties_t           device_properties,
	device_function::attributes_t  kernel_function_attributes,
	arguments_type                 extra_arguments,
	launch_configuration_limits_t  limits) const
{
	namespace kernel_ns = cuda::kernels::decompression::discard_zero_bytes::fixed_width;

	auto length = any_cast<size_t>(extra_arguments.at("length"));
	kernel_ns::launch_config_resolution_params_t<
		IndexSize, UncompressedSize, CompressedSize, translate(UncompressedEndianness), SerializationFactor
		> params(
		device_properties,
		length);

	return cuda::resolve_launch_configuration(params, limits);
}


template<
	unsigned IndexSize, unsigned UncompressedSize, unsigned CompressedSize,
	endianness_t UncompressedEndianness, serialization_factor_t SerializationFactor>
void kernel<IndexSize, UncompressedSize, CompressedSize, UncompressedEndianness, SerializationFactor>::launch(
	stream::id_t                   stream,
	const launch_configuration_t&  launch_config,
	arguments_type                 arguments) const
{
	using index_type        = util::uint_t<IndexSize>;
	using uncompressed_type = util::uint_t<UncompressedSize>;
	using compressed_type   = util::uint_t<CompressedSize>;

	auto decompressed     = any_cast<uncompressed_type*     >(arguments.at("decompressed"     ));
	auto compressed_input = any_cast<const compressed_type* >(arguments.at("compressed_input" ));
	auto length           = any_cast<index_type             >(arguments.at("length"           ));

	cuda::enqueue_launch(
		cuda::kernels::decompression::discard_zero_bytes::fixed_width::decompress
		<IndexSize, UncompressedSize, CompressedSize, translate(UncompressedEndianness), SerializationFactor>,
		launch_config, stream,
		decompressed, compressed_input, length
	);
}

template<
	unsigned IndexSize, unsigned UncompressedSize, unsigned CompressedSize,
	endianness_t UncompressedEndianness, serialization_factor_t SerializationFactor>
const device_function_t kernel<IndexSize, UncompressedSize, CompressedSize, UncompressedEndianness, SerializationFactor>::get_device_function() const
{
	return reinterpret_cast<const void*>(cuda::kernels::decompression::discard_zero_bytes::fixed_width::decompress
		<IndexSize, UncompressedSize, CompressedSize, translate(UncompressedEndianness), SerializationFactor>);
}

static_block {
	namespace functors = cuda::functors;

	//       IndexSize  UncompressedSize  CompressedSize
	//------------------------------------------------------------------------------------
	kernel < 4,         2,                1 >::registerInSubclassFactory();
	kernel < 4,         4,                1 >::registerInSubclassFactory();
	kernel < 4,         4,                2 >::registerInSubclassFactory();
	kernel < 4,         8,                1 >::registerInSubclassFactory();
	kernel < 4,         8,                2 >::registerInSubclassFactory();
	kernel < 4,         8,                4 >::registerInSubclassFactory();

	kernel < 8,         2,                1 >::registerInSubclassFactory();
	kernel < 8,         4,                1 >::registerInSubclassFactory();
	kernel < 8,         4,                2 >::registerInSubclassFactory();
	kernel < 8,         8,                1 >::registerInSubclassFactory();
	kernel < 8,         8,                2 >::registerInSubclassFactory();
	kernel < 8,         8,                4 >::registerInSubclassFactory();
}
#endif /* __CUDACC__ */


} // namespace fixed_width
} // namespace discard_zero_bytes
} // namespace decompression
} // namespace kernels
} // namespace cuda
