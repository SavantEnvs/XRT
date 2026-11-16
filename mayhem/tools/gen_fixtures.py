#!/usr/bin/env python3
"""Derive the small seed/KAT fixtures committed under mayhem/ from upstream's own test data.

  python3 mayhem/tools/gen_fixtures.py
"""
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SAMPLE = os.path.join(ROOT, "src/runtime_src/tools/xclbinutil/unittests/test_data/sample_1_2018.2.xclbin")

HDR_LEN = 456          # offsetof(axlf, m_sections)
OFF_LENGTH = 304       # axlf.m_header.m_length
OFF_NSECT = 448        # axlf.m_header.m_numSections
SEC_FMT = "<I16s4xQQ"  # axlf_section_header, 40 bytes

BMC, PDI, PARTITION_METADATA = 13, 18, 20


def read_sections(d):
    n = struct.unpack_from("<I", d, OFF_NSECT)[0]
    out = []
    for i in range(n):
        kind, name, off, size = struct.unpack_from(SEC_FMT, d, HDR_LEN + 40 * i)
        out.append((kind, name.rstrip(b"\0"), d[off:off + size]))
    return out


def build(header, sections):
    """header: first HDR_LEN bytes of an axlf; sections: [(kind, name, payload)]"""
    n = len(sections)
    table = HDR_LEN + 40 * (n - 1) if n else HDR_LEN
    off = table + 40
    body = b""
    hdrs = b""
    for kind, name, payload in sections:
        hdrs += struct.pack(SEC_FMT, kind, name, off + len(body), len(payload))
        body += payload
    h = bytearray(header)
    struct.pack_into("<Q", h, OFF_LENGTH, HDR_LEN + len(hdrs) + len(body))
    struct.pack_into("<I", h, OFF_NSECT, n)
    return bytes(h) + hdrs + body


def dtb(logic_uuid, interface_uuid):
    strings = b"logic_uuid\0interface_uuid\0"
    so_logic, so_intf = 0, len(b"logic_uuid\0")

    def prop(name_off, val):
        v = val + b"\0"
        pad = (-len(v)) % 4
        return struct.pack(">III", 3, len(v), name_off) + v + b"\0" * pad

    st = struct.pack(">I", 1) + b"\0\0\0\0"          # BEGIN_NODE "" (padded to 4)
    st += prop(so_logic, logic_uuid) + prop(so_intf, interface_uuid)
    st += struct.pack(">II", 2, 9)                    # END_NODE, END
    off_rsv = 40
    off_struct = off_rsv + 16
    off_str = off_struct + len(st)
    total = off_str + len(strings)
    hdr = struct.pack(">10I", 0xD00DFEED, total, off_struct, off_str, off_rsv,
                      17, 16, 0, len(strings), len(st))
    return hdr + b"\0" * 16 + st + strings


def bmc_section(image):
    def s(txt, n):
        return txt.encode().ljust(n, b"\0")
    meta = struct.pack("<QQ", 248, len(image))
    meta += s("bmc_image.bin", 64) + s("u200", 64) + s("2.1.5", 64) + s("56027182079c0bd621761b7dab5a27ca", 33) + b"\0" * 7
    assert len(meta) == 248
    return meta + image


def main():
    d = open(SAMPLE, "rb").read()
    header = d[:HDR_LEN]
    secs = read_sections(d)

    nobits = [(k, n, p) for (k, n, p) in secs if k != 0]
    out = os.path.join(ROOT, "mayhem/fuzz_xclbin/testsuite/u200_nobits.xclbin")
    open(out, "wb").write(build(header, nobits))

    dt = (PARTITION_METADATA, b"partition", dtb(b"0123456789abcdef0123456789abcdef", b"fedcba9876543210fedcba9876543210"))
    bm = (BMC, b"bmc", bmc_section(b"BMCIMAGE-0123456\n"))
    pdi = (PDI, b"pdi", b"PDI-PAYLOAD-0001")

    out = os.path.join(ROOT, "mayhem/fuzz_firmware_image/testsuite/u200_bmc.xsabin")
    open(out, "wb").write(build(header, [dt, bm]))

    # Removing a section in firmwareImage(STRIPPED_FIRMWARE) memcpy()s overlapping ranges.
    out = os.path.join(ROOT, "mayhem/fuzz_firmware_image/known-findings/stripped_pdi_memcpy_overlap.xsabin")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, "wb").write(build(header, [dt, bm, pdi]))


if __name__ == "__main__":
    main()
