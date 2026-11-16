#!/usr/bin/env bash
#
# mayhem/build.sh — builds XRT's host-side xclbin parser (xrt::xclbin and the core it links) and the
# xbmgmt/xbflash firmware-image reader, as sanitized libFuzzer harnesses, standalone reproducers and
# a normal-flags known-answer probe and upstream's xclbinutil test suite for mayhem/test.sh.
#
# XRT's CMake needs a full PCIe/driver stack and its submodules (aiebu, ELFIO) are absent from the
# source tree, so the host-side core is compiled directly: version headers are generated from
# src/CMake/config/*.h.in (the same substitutions CMake performs), aiebu and ELFIO come from the
# pinned sources the Dockerfile fetches into /opt/toolchains/deps (no network at build time).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

RT="$SRC/src/runtime_src"
AIEBU_ROOT=/opt/toolchains/deps/aiebu-1b398e72/src
AIEBU="$AIEBU_ROOT/src/cpp"
ELFIO=/opt/toolchains/deps/elfio-f849001f/src
B="$SRC/mayhem/build"
rm -rf "$B"
mkdir -p "$B/gen/xrt/detail" "$B/gen-aiebu" "$B/inc/core/common"

# --- generated headers --------------------------------------------------------------------------
for h in version-slim version-git version; do
  sed -e 's/@XRT_VERSION_MAJOR@/2/g;s/@XRT_VERSION_MINOR@/22/g;s/@XRT_VERSION_PATCH@/0/g' \
      -e 's/@XRT_VERSION_STRING@/2.22.0/g;s/@XRT_BRANCH@/master/g;s/@XRT_HASH@/unknown/g' \
      -e 's/@XRT_HASH_DATE@/unknown/g;s/@XRT_MODIFIED_FILES@//g;s/@XRT_HEAD_COMMITS@/0/g' \
      -e 's/@XRT_BRANCH_COMMITS@/0/g;s/@XRT_DATE_RFC@/unknown/g;s/@XRT_DATE@/unknown/g' \
      "$SRC/src/CMake/config/$h.h.in" > "$B/gen/xrt/detail/$h.h"
done
sed -e 's/@AIEBU_VERSION_MAJOR@/1/;s/@AIEBU_VERSION_MINOR@/0/;s/@AIEBU_VERSION_PATCH@/0/' \
    -e 's/@AIEBU_HEAD_COMMITS@/0/;s/@AIEBU_BRANCH_COMMITS@/0/;s/@AIEBU_VERSION_STRING@/1.0.0/g' \
    -e 's/@[A-Z_]*@/unknown/g' "$AIEBU_ROOT/cmake/config/version.h.in" > "$B/gen-aiebu/version.h"
# XRT includes aiebu through core/common/aiebu/... (its empty submodule dir); shadow it out of tree.
ln -sfn "$AIEBU_ROOT" "$B/inc/core/common/aiebu"

XRT_INC=(-I"$B/inc" -I"$B/gen" -I"$RT" -I"$RT/core/include" -I"$SRC/src" -I"$AIEBU/include" -I"$ELFIO")
XRT_DEF=(-DXRT_INSTALL_PREFIX=\"/usr\" -DXRT_VERSION_STRING=\"2.22.0\" -DXRT_VERSION_MAJOR=\"2\" -DXRT_LIB_DIR=\"lib\")
AIEBU_INC=(-I"$B/gen-aiebu" -I"$AIEBU" -I"$AIEBU/include" -isystem "$ELFIO" -I"$AIEBU_ROOT"
  -I"$AIEBU/preprocessor" -I"$AIEBU/preprocessor/aie2" -I"$AIEBU/preprocessor/aie2ps"
  -I"$AIEBU/encoder" -I"$AIEBU/encoder/aie2" -I"$AIEBU/encoder/aie2ps"
  -I"$AIEBU/common" -I"$AIEBU/ops" -I"$AIEBU/analyzer" -I"$AIEBU/assembler"
  -I"$AIEBU/elf" -I"$AIEBU/elf/aie2" -I"$AIEBU/elf/aie2ps" -I"$AIEBU/disassembler"
  -I"$AIEBU/aie-rt/include")
AIEBU_DEF=(-DAIEBU_NATIVE_BUILD=1 -DAIEBU_EXPORTS)

XRT_SRCS=(
  core/common/archive.cpp core/common/buffer_dumper.cpp core/common/config_reader.cpp core/common/debug.cpp
  core/common/debug_ip.cpp core/common/device.cpp core/common/error.cpp core/common/info_aie.cpp
  core/common/info_aie2.cpp core/common/info_memory.cpp core/common/info_platform.cpp
  core/common/info_telemetry.cpp core/common/info_vmr.cpp core/common/memaccess.cpp core/common/message.cpp
  core/common/module_loader.cpp core/common/query_requests.cpp core/common/sensor.cpp core/common/system.cpp
  core/common/thread.cpp core/common/time.cpp core/common/trace.cpp core/common/usage_metrics.cpp
  core/common/utils.cpp core/common/sysinfo.cpp core/common/xclbin_parser.cpp core/common/xclbin_swemu.cpp
  core/common/api/context_mgr.cpp core/common/api/elf_patcher.cpp core/common/api/hw_queue.cpp
  core/common/api/native_profile.cpp core/common/api/xrt_bo.cpp core/common/api/xrt_device.cpp
  core/common/api/xrt_elf.cpp core/common/api/xrt_error.cpp core/common/api/xrt_fence.cpp
  core/common/api/xrt_hw_context.cpp core/common/api/xrt_ini.cpp core/common/api/xrt_ip.cpp
  core/common/api/xrt_kernel.cpp core/common/api/xrt_message.cpp core/common/api/xrt_module.cpp
  core/common/api/xrt_profile.cpp core/common/api/xrt_queue.cpp core/common/api/xrt_system.cpp
  core/common/api/xrt_version.cpp core/common/api/xrt_xclbin.cpp
  core/common/runner/capture.cpp core/common/xdp/profile.cpp
)
FW_SRCS=( core/tools/xbmgmt2/flash/firmware_image.cpp )
AIEBU_SRCS=(
  analyzer/reporter.cpp analyzer/transaction.cpp analyzer/packets.cpp analyzer/passmanager.cpp
  analyzer/aie2p_passes.cpp analyzer/transform_manager.cpp assembler/aiebu_assembler.cpp assembler/assembler.cpp
  common/aiebu_error.cpp common/writer.cpp common/assembler_state.cpp common/utils.cpp common/build_info.cpp
  common/file_utils.cpp common/linux/metrics.cpp elf/elf_compression.cpp elf/elf_decompress.cpp
  elf/elfwriter.cpp elf/coredump_elfwriter.cpp elf/elf_reader.cpp
  preprocessor/aie2/aie2_blob_preprocessor_input.cpp preprocessor/aie2/aie2_asm_preprocessor_input.cpp
  preprocessor/aie2ps/aie2ps_preprocessor_input.cpp preprocessor/asm/asm_parser.cpp
  preprocessor/asm/hintmap_bitset.cpp preprocessor/asm/pager.cpp ops/ops.cpp disassembler/disassembler.cpp
  disassembler/disassembler_merged.cpp tools/debug_tools.cpp tools/trace_probe.cpp tools/opcode_information.cpp
  tools/dwarf_reader.cpp encoder/aie2ps/dwarf_writer.cpp encoder/aie2ps/aie2ps_encoder.cpp
  encoder/aie2ps/report.cpp
)
while IFS= read -r f; do AIEBU_SRCS+=("${f#"$AIEBU/"}"); done < <(find "$AIEBU/dtrace" -name '*.cpp' | LC_ALL=C sort)

# build_lib <kind> <flags...>: compile every source into $B/<kind>/{xrt,fw,aiebu}/ and archive them.
build_lib() {
  local kind="$1"; shift
  local flags=("$@")
  mkdir -p "$B/$kind"
  {
    for s in "${XRT_SRCS[@]}"; do printf 'xrt\t%s\t%s\n' "$RT/$s" "$B/$kind/xrt/$(echo "$s" | tr / _).o"; done
    for s in "${FW_SRCS[@]}"; do printf 'fw\t%s\t%s\n' "$RT/$s" "$B/$kind/fw/$(echo "$s" | tr / _).o"; done
    for s in "${AIEBU_SRCS[@]}"; do printf 'aiebu\t%s\t%s\n' "$AIEBU/$s" "$B/$kind/aiebu/$(echo "$s" | tr / _).o"; done
  } > "$B/$kind/jobs.tsv"
  mkdir -p "$B/$kind/xrt" "$B/$kind/fw" "$B/$kind/aiebu"
  export KIND_FLAGS="${flags[*]}"
  export XRT_FLAGS="${XRT_INC[*]} ${XRT_DEF[*]}" AIEBU_FLAGS="${AIEBU_INC[*]} ${AIEBU_DEF[*]}"
  xargs -P "$MAYHEM_JOBS" -L1 -d '\n' bash -c '
    IFS=$'"'"'\t'"'"' read -r grp src obj <<<"$0"
    case "$grp" in aiebu) extra="$AIEBU_FLAGS -g0" ;; *) extra="$XRT_FLAGS" ;; esac
    '"$CXX"' -std=c++17 -w $KIND_FLAGS $extra -c "$src" -o "$obj" || exit 255
  ' < "$B/$kind/jobs.tsv"
  for g in xrt fw aiebu; do
    rm -f "$B/$kind/lib$g.a"
    ar rcs "$B/$kind/lib$g.a" "$B/$kind/$g"/*.o
  done
}

SYSLIBS=(-lboost_filesystem -lboost_system -luuid -lzstd -lpthread -ldl)

# --- 1) sanitized, fuzzer-instrumented libraries ------------------------------------------------
# -fsanitize=fuzzer-no-link goes on unconditionally so the fuzzed code carries SanCov edges even
# when SANITIZER_FLAGS is overridden.
build_lib san -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link

$CXX -std=c++17 $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$B/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/standalone_main.o"

link_harness() { # <name> <libs...>
  local name="$1"; shift
  local libs=("$@")
  local obj="$B/$name.o"
  $CXX -std=c++17 -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -w "${XRT_INC[@]}" "${XRT_DEF[@]}" \
      -c "$SRC/mayhem/$name.cpp" -o "$obj"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$obj" "$B/lsan_off.o" "${libs[@]}" "${SYSLIBS[@]}" \
      -o "$SRC/$name"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link "$obj" "$B/standalone_main.o" "$B/lsan_off.o" \
      "${libs[@]}" "${SYSLIBS[@]}" -o "$SRC/$name-standalone"
}
link_harness fuzz_xclbin "$B/san/libxrt.a" "$B/san/libaiebu.a"
link_harness fuzz_firmware_image "$B/san/libfw.a" "$B/san/libxrt.a" "$B/san/libaiebu.a"

# --- 2) known-answer probe, normal flags (no sanitizers, no fuzzer instrumentation) -------------
build_lib plain -O1 $COVERAGE_FLAGS
$CXX -std=c++17 -O1 $COVERAGE_FLAGS -w "${XRT_INC[@]}" "${XRT_DEF[@]}" "$SRC/mayhem/kat_probe.cpp" \
    "$B/plain/libfw.a" "$B/plain/libxrt.a" "$B/plain/libaiebu.a" "${SYSLIBS[@]}" $COVERAGE_FLAGS -o "$SRC/kat_probe"

# --- 3) upstream's own test suite, normal flags ------------------------------------------------
# xclbinutil's standalone CMake project (what `build/build.sh -xclbinutil` configures) registers 18
# Python tests and the xclbintest gtest binary. Every ctest wrapper sources
# ${XRT_BUILD_INSTALL_DIR}/setup.sh, so it is installed into the build tree (DESTDIR) as upstream's
# build/build.sh does before `ctest`. No sanitizers, no fuzzer instrumentation.
T="$B/tests"
mkdir -p "$T"
CFLAGS="$COVERAGE_FLAGS" CXXFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" \
  cmake -S "$SRC/src/runtime_src/tools/xclbinutil" -B "$T" -DXRT_SOURCE_DIR="$SRC/src" \
    -DLINUX_FLAVOR=ubuntu -DCMAKE_INSTALL_PREFIX=/opt/xilinx/xrt -DXRT_BASE=1 -DCMAKE_BUILD_TYPE=Release
cmake --build "$T" -j "$MAYHEM_JOBS"
DESTDIR="$T" cmake --install "$T" >/dev/null
