#!/usr/bin/env python3
"""
Binary-patch GPU and CPU frequency tables in a Motorola QCDT v3 dt.img.

NO dtc needed. Direct binary replacement of known frequency values
in each DTB blob inside the QCDT image.

Usage:
    python3 overclock_dt.py <input_dt.img> <output_dt.img> [--gpu-mhz 700] [--cpu-mhz 2300]
"""

import argparse
import struct
import sys

QCDT_MAGIC = b"QCDT"
ENTRY_SIZE_MOTO_V3 = 72

# Stock GPU max freq in Hz (little-endian 4 bytes)
STOCK_GPU_HZ = 650_000_000
STOCK_GPU_BYTES = struct.pack("<I", STOCK_GPU_HZ)

# Stock CPU max freq in KHz (little-endian 4 bytes)
STOCK_CPU_KHZ = 2_208_000
STOCK_CPU_BYTES = struct.pack("<I", STOCK_CPU_KHZ)


def read_u32_le(data, offset):
    return struct.unpack("<I", data[offset : offset + 4])[0]


def write_u32_le(value):
    return struct.pack("<I", value & 0xFFFFFFFF)


def parse_qcdt(data):
    if data[:4] != QCDT_MAGIC:
        raise ValueError("Not a QCDT image")

    hdr_version = read_u32_le(data, 4)
    num_entries = read_u32_le(data, 8)
    mtor_version = (hdr_version >> 8) & 0xFF
    qcdt_version = hdr_version & 0xFF

    print(f"  QCDT version: {qcdt_version}, Motorola version: {mtor_version}")
    print(f"  Number of entries: {num_entries}")

    entries = []
    for i in range(num_entries):
        offset = 12 + i * ENTRY_SIZE_MOTO_V3
        entry_data = data[offset : offset + ENTRY_SIZE_MOTO_V3]

        chipset = read_u32_le(entry_data, 0)
        platform = read_u32_le(entry_data, 4)
        subtype = read_u32_le(entry_data, 8)
        soc_rev = read_u32_le(entry_data, 12)
        pmic0 = read_u32_le(entry_data, 16)
        pmic1 = read_u32_le(entry_data, 20)
        pmic2 = read_u32_le(entry_data, 24)
        pmic3 = read_u32_le(entry_data, 28)
        dtb_offset = read_u32_le(entry_data, 32)
        dtb_size = read_u32_le(entry_data, 36)
        model = entry_data[40:72].split(b"\x00")[0].decode("ascii", errors="replace")

        entries.append(
            {
                "chipset": chipset,
                "platform": platform,
                "subtype": subtype,
                "soc_rev": soc_rev,
                "pmic": [pmic0, pmic1, pmic2, pmic3],
                "dtb_offset": dtb_offset,
                "dtb_size": dtb_size,
                "model": model,
                "dtb_data": b"",
            }
        )

        if dtb_offset > 0 and dtb_size > 0:
            dtb_raw = data[dtb_offset : dtb_offset + dtb_size]
            dtb_magic_pos = dtb_raw.find(b"\xd0\x0d\xfe\xed")
            if dtb_magic_pos >= 0:
                entries[-1]["dtb_data"] = bytearray(dtb_raw[dtb_magic_pos:])
            else:
                entries[-1]["dtb_data"] = bytearray(dtb_raw)

        print(
            f"  Entry {i}: chip=0x{chipset:x} plat=0x{platform:x} "
            f"sub=0x{subtype:x} rev=0x{soc_rev:x} model={model!r} "
            f"dtb_size={dtb_size}"
        )

    return {"hdr_version": hdr_version, "num_entries": num_entries, "entries": entries}


def find_all(dtb, needle):
    """Find all offsets of needle in dtb."""
    results = []
    start = 0
    while True:
        pos = dtb.find(needle, start)
        if pos < 0:
            break
        results.append(pos)
        start = pos + 1
    return results


def patch_gpu_freq(dtb, target_mhz):
    """Replace the GPU max freq (650 MHz) with target. Binary search+replace."""
    target_hz = target_mhz * 1_000_000
    target_bytes = struct.pack("<I", target_hz)

    occurrences = find_all(dtb, STOCK_GPU_BYTES)
    patched = 0
    for pos in occurrences:
        dtb[pos : pos + 4] = target_bytes
        patched += 1

    return patched


def patch_cpu_freq(dtb, target_mhz):
    """Replace the CPU max freq (2208 MHz) with target. Binary search+replace."""
    target_khz = target_mhz * 1_000
    target_bytes = struct.pack("<I", target_khz)

    occurrences = find_all(dtb, STOCK_CPU_BYTES)
    patched = 0
    for pos in occurrences:
        dtb[pos : pos + 4] = target_bytes
        patched += 1

    return patched


def build_qcdt(image_info, page_size=2048):
    """Rebuild QCDT v3 Motorola image."""
    entries = image_info["entries"]

    header_size = 12
    table_size = header_size + len(entries) * ENTRY_SIZE_MOTO_V3 + 4
    padding = page_size - (table_size % page_size)
    if padding == page_size:
        padding = 0
    dtb_start = table_size + padding

    current_offset = dtb_start
    for entry in entries:
        entry["new_offset"] = current_offset
        dtb = entry["dtb_data"]
        dtb_padded_size = len(dtb) + (page_size - (len(dtb) % page_size))
        entry["new_size"] = dtb_padded_size
        current_offset += dtb_padded_size

    total_size = current_offset
    output = bytearray(total_size)

    output[0:4] = QCDT_MAGIC
    output[4:8] = write_u32_le(image_info["hdr_version"])
    output[8:12] = write_u32_le(len(entries))

    for i, entry in enumerate(entries):
        off = header_size + i * ENTRY_SIZE_MOTO_V3
        output[off : off + 4] = write_u32_le(entry["chipset"])
        output[off + 4 : off + 8] = write_u32_le(entry["platform"])
        output[off + 8 : off + 12] = write_u32_le(entry["subtype"])
        output[off + 12 : off + 16] = write_u32_le(entry["soc_rev"])
        output[off + 16 : off + 20] = write_u32_le(entry["pmic"][0])
        output[off + 20 : off + 24] = write_u32_le(entry["pmic"][1])
        output[off + 24 : off + 28] = write_u32_le(entry["pmic"][2])
        output[off + 28 : off + 32] = write_u32_le(entry["pmic"][3])
        output[off + 32 : off + 36] = write_u32_le(entry["new_offset"])
        output[off + 36 : off + 40] = write_u32_le(entry["new_size"])

        model_bytes = entry["model"].encode("ascii")[:31]
        model_bytes = model_bytes.ljust(32, b"\x00")
        output[off + 40 : off + 72] = model_bytes

    for entry in entries:
        dtb = entry["dtb_data"]
        output[entry["new_offset"] : entry["new_offset"] + len(dtb)] = dtb

    return bytes(output)


def main():
    parser = argparse.ArgumentParser(description="Binary-patch GPU/CPU freq in QCDT dt.img")
    parser.add_argument("input", help="Input dt.img path")
    parser.add_argument("output", help="Output dt.img path")
    parser.add_argument("--gpu-mhz", type=int, default=700, help="Target GPU MHz (default: 700)")
    parser.add_argument("--cpu-mhz", type=int, default=2300, help="Target CPU MHz (default: 2300)")
    args = parser.parse_args()

    with open(args.input, "rb") as f:
        data = f.read()

    print(f"Input: {args.input} ({len(data)} bytes)")
    image_info = parse_qcdt(data)

    print(f"\nPatching to GPU={args.gpu_mhz} MHz, CPU={args.cpu_mhz} MHz")

    for i, entry in enumerate(image_info["entries"]):
        if not entry["dtb_data"]:
            print(f"  Entry {i}: no DTB data, skipping")
            continue

        print(f"\n  Processing entry {i} ({entry['model']!r})...")
        dtb = entry["dtb_data"]

        gpu_count = patch_gpu_freq(dtb, args.gpu_mhz)
        print(f"  GPU: patched {gpu_count} occurrence(s) of {STOCK_GPU_HZ} Hz -> {args.gpu_mhz * 1_000_000} Hz")

        cpu_count = patch_cpu_freq(dtb, args.cpu_mhz)
        print(f"  CPU: patched {cpu_count} occurrence(s) of {STOCK_CPU_KHZ} KHz -> {args.cpu_mhz * 1_000} KHz")

        if gpu_count == 0 and cpu_count == 0:
            print(f"  WARNING: no matches found for stock frequencies in entry {i}!")

    print("\nRebuilding QCDT image...")
    output = build_qcdt(image_info)

    with open(args.output, "wb") as f:
        f.write(output)

    print(f"Output: {args.output} ({len(output)} bytes)")


if __name__ == "__main__":
    main()
