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
    raw = lzma.decompress(data, format=lzma.FORMAT_ALONE)
    if not raw.startswith((b"070701", b"070702")):
        raise SystemExit("decompressed base ramdisk is not newc CPIO")
    return dict_size, lc, lp, pb

def build_overlay(args):
    base_data = args.base.read_bytes()
    dict_size, lc, lp, pb = parse_lzma_alone_header(base_data)

    entries = [
        ("sbin/wifi", args.wifi.read_bytes(), stat.S_IFREG | 0o755),
        ("sbin/albus-WCNSS_qcom_cfg.ini", args.config.read_bytes(), stat.S_IFREG | 0o644),
        ("sbin/wpa_supplicant.albus", args.wpa.read_bytes(), stat.S_IFREG | 0o755),
        ("sbin/wpa_cli.albus", args.wpacli.read_bytes(), stat.S_IFREG | 0o755),
        ("sbin/hostapd.albus", args.hostapd.read_bytes(), stat.S_IFREG | 0o755),
        ("sbin/iw.albus", args.iw.read_bytes(), stat.S_IFREG | 0o755),
        ("sbin/wcnss-recovery-albus", args.wcnss.read_bytes(), stat.S_IFREG | 0o755),
        ("sbin/busybox.albus", args.busybox.read_bytes(), stat.S_IFREG | 0o755),
        ("sbin/iptables.albus", args.iptables.read_bytes(), stat.S_IFREG | 0o755),
        ("sbin/iptables", b"iptables.albus", stat.S_IFLNK | 0o777),
        ("sbin/iptables-save", b"iptables.albus", stat.S_IFLNK | 0o777),
        ("sbin/iptables-restore", b"iptables.albus", stat.S_IFLNK | 0o777),
        ("sbin/wifi-udhcpc.script", args.udhcpc_script.read_bytes(), stat.S_IFREG | 0o755),
        ("sbin/recovery-time-sync-albus", args.time_sync.read_bytes(), stat.S_IFREG | 0o755),
    ]

    raw = bytearray()
    ino = 0x7000
    for name, data, mode in entries:
        raw += newc_entry(name, data, ino, mode)
        ino += 1
    raw += newc_entry("TRAILER!!!", b"", ino, 0)

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
        raise SystemExit("overlay LZMA parameters changed")

    check = lzma.decompress(packed, format=lzma.FORMAT_ALONE)
    required = (
        b"sbin/wifi\0",
        b"sbin/albus-WCNSS_qcom_cfg.ini\0",
        b"sbin/wpa_supplicant.albus\0",
        b"sbin/wpa_cli.albus\0",
        b"sbin/hostapd.albus\0",
        b"sbin/iw.albus\0",
        b"sbin/wcnss-recovery-albus\0",
        b"sbin/busybox.albus\0",
        b"sbin/iptables.albus\0",
        b"sbin/iptables\0",
        b"sbin/iptables-save\0",
        b"sbin/iptables-restore\0",
        b"sbin/wifi-udhcpc.script\0",
        b"sbin/recovery-time-sync-albus\0",
    )
    for marker in required:
        if marker not in check:
            raise SystemExit(f"overlay verification failed: missing {marker!r}")

    args.output.write_bytes(packed)

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
        raise SystemExit("Wi-Fi overlay is missing")

    raw = lzma.decompress(tail, format=lzma.FORMAT_ALONE)
    required = (
        b"sbin/wifi\0",
        b"sbin/wpa_supplicant.albus\0",
        b"sbin/wpa_cli.albus\0",
        b"sbin/hostapd.albus\0",
        b"sbin/iw.albus\0",
        b"sbin/wcnss-recovery-albus\0",
        b"sbin/busybox.albus\0",
        b"sbin/iptables.albus\0",
        b"sbin/iptables\0",
        b"sbin/iptables-save\0",
        b"sbin/iptables-restore\0",
        b"sbin/wifi-udhcpc.script\0",
        b"sbin/recovery-time-sync-albus\0",
        b"TRAILER!!!\0",
    )
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
    b.add_argument("--wpa", type=Path, required=True)
    b.add_argument("--wpacli", type=Path, required=True)
    b.add_argument("--hostapd", type=Path, required=True)
    b.add_argument("--iw", type=Path, required=True)
    b.add_argument("--wcnss", type=Path, required=True)
    b.add_argument("--busybox", type=Path, required=True)
    b.add_argument("--iptables", type=Path, required=True)
    b.add_argument("--udhcpc-script", type=Path, required=True)
    b.add_argument("--time-sync", type=Path, required=True)
    b.add_argument("--output", type=Path, required=True)

    v = sub.add_parser("verify")
    v.add_argument("--base", type=Path, required=True)
    v.add_argument("--combined", type=Path, required=True)

    args = ap.parse_args()
    if args.cmd == "build":
        build_overlay(args)
    else:
        verify_combined(args.base, args.combined)

if __name__ == "__main__":
    main()
