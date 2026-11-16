// libFuzzer harness: xbmgmt/xbflash firmware-archive (.xsabin) parsing from a temp file.
#include "core/tools/xbmgmt2/flash/firmware_image.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <string>

#include <unistd.h>

namespace {

size_t sink = 0;

class TempFile {
public:
  TempFile(const uint8_t* data, size_t size)
  {
    const char* dir = std::getenv("TMPDIR");
    std::string tmpl = std::string(dir && *dir ? dir : "/tmp") + "/fwimgXXXXXX.xsabin";
    fd_ = mkstemps(&tmpl[0], static_cast<int>(std::strlen(".xsabin")));
    if (fd_ < 0)
      return;
    path_ = tmpl;
    size_t off = 0;
    while (off < size) {
      ssize_t w = write(fd_, data + off, size - off);
      if (w <= 0) {
        close(fd_);
        fd_ = -1;
        unlink(path_.c_str());
        path_.clear();
        return;
      }
      off += static_cast<size_t>(w);
    }
    close(fd_);
    fd_ = -1;
  }
  ~TempFile() { if (!path_.empty()) unlink(path_.c_str()); }
  const std::string& path() const { return path_; }
private:
  int fd_ = -1;
  std::string path_;
};

}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
  if (size > (1u << 20))
    return -1;
  TempFile f(data, size);
  if (f.path().empty())
    return -1;

  try {
    DSAInfo info(f.path());
    sink += info.name.size() + info.vendor.size() + info.board.size() + info.bmcVer.size() + info.timestamp;
    sink += info.uuids.size() + info.vendor_id + info.device_id + info.subsystem_id;
    sink += info.bmcVerIsFixed() + info.hasFlashImage;
  }
  catch (const std::exception&) {
  }

  static const imageType kinds[] = {BMC_FIRMWARE, MCS_FIRMWARE_PRIMARY, MCS_FIRMWARE_SECONDARY, STRIPPED_FIRMWARE};
  for (imageType t : kinds) {
    try {
      firmwareImage img(f.path(), t);
      char buf[256];
      img.read(buf, sizeof(buf));
      sink += static_cast<size_t>(img.gcount());
    }
    catch (const std::exception&) {
    }
  }
  return 0;
}
