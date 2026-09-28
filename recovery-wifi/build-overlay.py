#!/usr/bin/env python3
import argparse
import lzma
import stat
import struct
from pathlib import Path

CPIO_MAGIC = b"070701"

def align4(n):
    return (n + 3) & ~3

def newc_entry(name: str, data: bytes, ino: int, mode: int, nlink: int = 1) -> bytes:
    name_b = name.encode() + b"\0"
    fields = (
        ino, mode, 0, 0, nlink, 0, len(data),
        0, 0, 0, 0, len(name_b), 0,
    )
    out = bytearray(CPIO_MAGIC + b"".join(f"{x:08x}".encode() for x in fields))
    out += name_b
    out += b"\0" * (align4(len(out)) - len(out))
    out += data
    out += b"\0" * (align4(len(out)) - len(out))
    return bytes(out)

def parse_lzma_alone_header(data: bytes):
    if len(data) < 13:
        raise SystemExit("base ramdisk is too short for LZMA-alone")
    props = data[0]
    if props >= 9 * 5 * 5:
        raise SystemExit(f"invalid LZMA properties byte: {props}")
    lc = props % 9
    rest = props // 9
    lp = rest % 5
    pb = rest // 5
    dict_size = struct.unpack_from("<I", data, 1)[0]
    try:
        raw = lzma.decompress(data, format=lzma.FORMAT_ALONE)
    except lzma.LZMAError as e:
        raise SystemExit(f"base ramdisk is not valid LZMA-alone: {e}")
    if not raw.startswith((b"070701", b"070702")):
        raise SystemExit("decompressed base ramdisk is not newc CPIO")
    return dict_size, lc, lp, pb

def build_overlay(base: Path, wifi: Path, cfg: Path, output: Path):
    base_data = base.read_bytes()
    dict_size, lc, lp, pb = parse_lzma_alone_header(base_data)

    entries = [
        ("sbin/wifi", wifi.read_bytes(), stat.S_IFREG | 0o755, 1),
        ("sbin/albus-WCNSS_qcom_cfg.ini", cfg.read_bytes(), stat.S_IFREG | 0o644, 1),
    ]

    raw = bytearray()
    ino = 0x7000
    for name, data, mode, nlink in entries:
        raw += newc_entry(name, data, ino, mode, nlink)
        ino += 1
    raw += newc_entry("TRAILER!!!", b"", ino, 0, 1)

    filters = [{
        "id": lzma.FILTER_LZMA1,
        "dict_size": dict_size,
        "lc": lc,
        "lp": lp,
        "pb": pb,
        "mode": lzma.MODE_NORMAL,
        "nice_len": 64,
        "mf": lzma.MF_BT4,
    }]
    packed = lzma.compress(bytes(raw), format=lzma.FORMAT_ALONE, filters=filters)

    expected_props = bytes([((pb * 5 + lp) * 9 + lc)]) + struct.pack("<I", dict_size)
    if packed[:5] != expected_props:
        raise SystemExit(
            f"overlay LZMA parameters changed: expected={expected_props.hex()} got={packed[:5].hex()}"
        )

    check = lzma.decompress(packed, format=lzma.FORMAT_ALONE)
    if b"sbin/wifi\0" not in check or b"sbin/albus-WCNSS_qcom_cfg.ini\0" not in check:
        raise SystemExit("overlay verification failed")

    output.write_bytes(packed)

    print(f"base_ramdisk_bytes={len(base_data)}")
    print(f"overlay_raw_bytes={len(raw)}")
    print(f"overlay_packed_bytes={len(packed)}")
    print(f"lzma_dict={dict_size}")
    print(f"lzma_lc_lp_pb={lc}/{lp}/{pb}")

def verify_combined(base: Path, combined: Path):
    base_data = base.read_bytes()
    combined_data = combined.read_bytes()

    if not combined_data.startswith(base_data):
        raise SystemExit("TeamWin ramdisk prefix changed")

    tail = combined_data[len(base_data):]
    if not tail:
        raise SystemExit("Wi-Fi overlay is missing from combined ramdisk")

    raw = lzma.decompress(tail, format=lzma.FORMAT_ALONE)
    required = (b"sbin/wifi\0", b"sbin/albus-WCNSS_qcom_cfg.ini\0", b"TRAILER!!!\0")
    for marker in required:
        if marker not in raw:
            raise SystemExit(f"combined overlay missing {marker!r}")

    print(f"verified_teamwin_prefix_bytes={len(base_data)}")
    print(f"verified_overlay_bytes={len(tail)}")

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build")
    b.add_argument("--base", type=Path, required=True)
    b.add_argument("--wifi", type=Path, required=True)
    b.add_argument("--config", type=Path, required=True)
    b.add_argument("--output", type=Path, required=True)

    v = sub.add_parser("verify")
    v.add_argument("--base", type=Path, required=True)
    v.add_argument("--combined", type=Path, required=True)

    args = ap.parse_args()
    if args.cmd == "build":
        build_overlay(args.base, args.wifi, args.config, args.output)
    else:
        verify_combined(args.base, args.combined)

if __name__ == "__main__":
    main()
