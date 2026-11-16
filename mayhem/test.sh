#!/usr/bin/env bash
#
# mayhem/test.sh — upstream's xclbinutil test suite plus a known-answer oracle for XRT's host-side
# xclbin and firmware-image parsers.
#
# 1) ctest over the xclbinutil CMake project build.sh built (and installed into its build tree) in
#    mayhem/build/tests: 18 Python tests driving xclbinutil and the xclbintest gtest binary.
# 2) /mayhem/kat_probe (built by build.sh with normal flags, dynamically linked) parses committed
# fixtures through xrt::xclbin, DSAInfo and firmwareImage and prints one fact per line; every line
# must equal the golden value in mayhem/kat_expected.txt. A build whose parsers are broken, or a
# probe that exits without parsing, fails here.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

T="$SRC/mayhem/build/tests"
PROBE="$SRC/kat_probe"
[ -x "$PROBE" ] || { echo "kat_probe missing: mayhem/build.sh did not build it" >&2; emit_ctrf cmake-ctest 0 1; exit 1; }
[ -x "$T/xclbintest" ] && [ -f "$T/CTestTestfile.cmake" ] && [ -f "$T/opt/xilinx/xrt/setup.sh" ] || {
  echo "upstream test suite missing: mayhem/build.sh did not build/install $T" >&2; emit_ctrf cmake-ctest 0 1; exit 1; }

# --- 1) upstream ctest ---------------------------------------------------------------------------
JUNIT="$(mktemp "${TMPDIR:-/tmp}/xrt-ctest.XXXXXX.xml")"
trap 'rm -f "$JUNIT"' EXIT
ctest --test-dir "$T" --output-on-failure --output-junit "$JUNIT"
read -r c_tests c_failed c_skipped < <(python3 -I - "$JUNIT" <<'PY'
import sys, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot()
s = r if r.tag == "testsuite" else r.find("testsuite")
print(int(s.get("tests", 0)), int(s.get("failures", 0)) + int(s.get("errors", 0)), int(s.get("skipped", 0) or 0))
PY
) || { c_tests=0; c_failed=1; c_skipped=0; }
c_passed=$(( c_tests - c_failed - c_skipped ))
echo "ctest: $c_passed passed, $c_failed failed, $c_skipped skipped of $c_tests"
# The suite is 19 tests (18 Python + xclbintest); fewer means part of it was not registered.
[ "$c_tests" -ge 19 ] || { echo "ctest ran only $c_tests tests, expected 19" >&2; c_failed=$((c_failed + 1)); }

# --- 2) known-answer probe -----------------------------------------------------------------------

XCLBIN=mayhem/fuzz_xclbin/testsuite/u200_nobits.xclbin
XSABIN=mayhem/fuzz_firmware_image/testsuite/u200_bmc.xsabin
XSABIN_PDI=mayhem/fuzz_firmware_image/known-findings/stripped_pdi_memcpy_overlap.xsabin
EXPECTED=mayhem/kat_expected.txt

out="$("$PROBE" "$XCLBIN" "$XSABIN" "$XSABIN_PDI" 2>/dev/null | grep -E '^(xclbin|trunc|badmagic|fw|fwpdi)\.')"

passed=0; failed=0
while IFS= read -r want; do
  if printf '%s\n' "$out" | grep -qxF -- "$want"; then
    passed=$((passed + 1))
  else
    echo "MISSING: $want" >&2
    failed=$((failed + 1))
  fi
done < "$EXPECTED"

# Nothing unexpected may appear either.
extra="$(printf '%s\n' "$out" | grep -vxFf "$EXPECTED" || true)"
if [ -n "$extra" ]; then
  echo "UNEXPECTED:" >&2; printf '%s\n' "$extra" >&2
  failed=$((failed + 1))
fi

echo "kat: $passed passed, $failed failed"
emit_ctrf cmake-ctest "$((passed + c_passed))" "$((failed + c_failed))" "$c_skipped"
