// Known-answer probe for mayhem/test.sh: parses fixtures through the same XRT code the fuzz
// targets drive and prints one line per fact. Built with normal flags (no sanitizers).
#include "xrt/experimental/xrt_xclbin.h"
#include "core/tools/xbmgmt2/flash/firmware_image.h"

#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>

static std::vector<char> slurp(const char* path, size_t limit = static_cast<size_t>(-1))
{
  std::ifstream f(path, std::ios::binary);
  std::vector<char> b((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
  if (b.size() > limit)
    b.resize(limit);
  return b;
}

static void xclbin_facts(const char* tag, const std::vector<char>& blob)
{
  try {
    xrt::xclbin xb(blob);
    std::cout << tag << ".xsa=" << xb.get_xsa_name() << "\n"
              << tag << ".uuid=" << xb.get_uuid().to_string() << "\n"
              << tag << ".fpga=" << xb.get_fpga_device_name() << "\n";
    for (const auto& k : xb.get_kernels()) {
      std::cout << tag << ".kernel=" << k.get_name() << " args=" << k.get_args().size() << "\n";
      for (const auto& a : k.get_args())
        std::cout << tag << ".arg[" << a.get_index() << "]=" << a.get_name() << " size=" << a.get_size()
                  << " offset=0x" << std::hex << a.get_offset() << std::dec << "\n";
    }
    for (const auto& ip : xb.get_ips())
      std::cout << tag << ".ip=" << ip.get_name() << " base=0x" << std::hex << ip.get_base_address() << std::dec << "\n";
    for (const auto& m : xb.get_mems())
      std::cout << tag << ".mem=" << m.get_tag() << " kb=" << m.get_size_kb() << " used=" << int(m.get_used()) << "\n";
  }
  catch (const std::exception&) {
    std::cout << tag << ".error=exception\n";
  }
}

static void firmware_facts(const char* tag, const char* path, bool stripped_too)
{
  DSAInfo info(path);
  std::cout << tag << ".name=" << info.name << "\n" << tag << ".vendor=" << info.vendor << "\n" << tag << ".board=" << info.board
            << "\n" << tag << ".bmcver=" << info.bmcVer << "\n" << tag << ".flash=" << info.hasFlashImage
            << "\n" << tag << ".uuids=" << info.uuids.size();
  for (const auto& u : info.uuids)
    std::cout << " " << u;
  std::cout << "\n" << tag << ".timestamp=" << std::hex << info.timestamp << std::dec << "\n";

  firmwareImage bmc(path, BMC_FIRMWARE);
  std::string content((std::istreambuf_iterator<char>(bmc)), std::istreambuf_iterator<char>());
  std::cout << tag << ".bmc.size=" << content.size() << " data=" << content << tag << ".bmc.fail=" << bmc.fail() << "\n";

  firmwareImage pdi(path, MCS_FIRMWARE_PRIMARY);
  std::string pdi_all((std::istreambuf_iterator<char>(pdi)), std::istreambuf_iterator<char>());
  std::cout << tag << ".pdi.size=" << pdi_all.size() << " fail=" << pdi.fail() << "\n";

  firmwareImage sec(path, MCS_FIRMWARE_SECONDARY);
  std::cout << tag << ".secondary.fail=" << sec.fail() << "\n";

  // Stripping a section memcpy()s overlapping ranges upstream; only probe it when nothing is removed.
  if (stripped_too) {
    firmwareImage stripped(path, STRIPPED_FIRMWARE);
    std::string st((std::istreambuf_iterator<char>(stripped)), std::istreambuf_iterator<char>());
    std::cout << tag << ".stripped.size=" << st.size() << " fail=" << stripped.fail() << "\n";
  }
}

int main(int argc, char** argv)
{
  if (argc != 4) {
    std::cerr << "usage: kat_probe <file.xclbin> <bmc.xsabin> <bmc_pdi.xsabin>\n";
    return 2;
  }
  auto good = slurp(argv[1]);
  xclbin_facts("xclbin", good);
  xclbin_facts("trunc", slurp(argv[1], 300));
  auto bad = good;
  bad[0] = 'X';
  xclbin_facts("badmagic", bad);
  firmware_facts("fw", argv[2], true);
  firmware_facts("fwpdi", argv[3], false);
  return 0;
}
