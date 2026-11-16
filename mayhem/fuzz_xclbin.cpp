// libFuzzer harness: build an xrt::xclbin from raw bytes and walk its parsed metadata.
#include "xrt/experimental/xrt_xclbin.h"

#include <cstddef>
#include <cstdint>
#include <exception>
#include <string>
#include <vector>

namespace {

size_t sink = 0;

void walk_arg(const xrt::xclbin::arg& a)
{
  sink += a.get_name().size() + a.get_port().size() + a.get_size() + a.get_offset() + a.get_index();
  sink += static_cast<size_t>(a.get_host_type().size());
  for (const auto& m : a.get_mems())
    sink += m.get_tag().size() + m.get_base_address() + m.get_size_kb() + m.get_index();
}

void walk_ip(const xrt::xclbin::ip& ip)
{
  sink += ip.get_name().size() + ip.get_base_address() + ip.get_size() + ip.get_num_args();
  sink += static_cast<size_t>(ip.get_type()) + static_cast<size_t>(ip.get_control_type());
  for (const auto& a : ip.get_args())
    walk_arg(a);
}

}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
  try {
    std::vector<char> blob(reinterpret_cast<const char*>(data), reinterpret_cast<const char*>(data) + size);
    xrt::xclbin xb(blob);

    sink += xb.get_xsa_name().size() + xb.get_fpga_device_name().size();
    sink += xb.get_uuid().to_string().size() + xb.get_interface_uuid().to_string().size();
    sink += static_cast<size_t>(xb.get_target_type());

    for (const auto& k : xb.get_kernels()) {
      sink += k.get_name().size() + k.get_num_args() + static_cast<size_t>(k.get_type());
      for (const auto& a : k.get_args())
        walk_arg(a);
      for (const auto& cu : k.get_cus())
        walk_ip(cu);
    }
    for (const auto& ip : xb.get_ips())
      walk_ip(ip);
    for (const auto& m : xb.get_mems())
      sink += m.get_tag().size() + m.get_base_address() + m.get_size_kb() + m.get_index() + m.get_used();
    sink += xb.get_aie_partitions().size();
    sink += static_cast<size_t>(xb.get_gmio_mem_index("gmio0") + 1);
  }
  catch (const std::exception&) {
  }
  return 0;
}
