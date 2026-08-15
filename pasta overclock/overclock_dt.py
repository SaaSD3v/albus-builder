#!/usr/bin/env python3
"""
Binary-patch GPU and CPU frequency values in a device-tree image.

Works on QCDT v2, QCDT v3 Motorola, and standalone FDT/DTB files.
Does NOT use dtc - performs direct byte replacement of known stock
frequency values to preserve all Qualcomm-specific properties.

IMPORTANT: DTB property values are stored in big-endian (FDT spec),
while the QCDT container header is little-endian (Qualcomm format).

Usage:
    python3 overclock_dt.py <input> <output> [--gpu-mhz 700] [--cpu-mhz 2300]
"""

import argparse
import struct
import sys

QCDT_MAGIC = b"QCDT"
FDT_MAGIC = b"\xd0\x0d\xfe\xed"

# Known stock frequencies for Snapdragon 626 / msm8953
# qcom,gpu-freq stores Hz as big-endian u32: 650000000 = 0x26BE3680
# qcom,cpufreq-table stores KHz as big-endian u32: 2208000 = 0x0021B100
STOCK_GPU_HZ = 650_000_000
STOCK_CPU_KHZ = 2_208_000

# BIG-ENDIAN byte patterns (FDT spec)
STOCK_GPU_BE = struct.pack(">I", STOCK_GPU_HZ)
STOCK_CPU_BE = struct.pack(">I", STOCK_CPU_KHZ)


def read_u32_le(data, offset):
    return struct.unpack("<I", data[offset : offset + 4])[0]


def find_all(data, needle):
    results = []
    start = 0
    while True:
        pos = data.find(needle, start)
        if pos < 0:
            break
        results.append(pos)
        start = pos + 1
    return results


def patch_binary_freqs(dtb, target_gpu_mhz, target_cpu_mhz):
    """Patch stock freq values in a DTB blob (big-endian values)."""
    target_gpu_hz = target_gpu_mhz * 1_000_000
    target_cpu_khz = target_cpu_mhz * 1_000

    gpu_be = struct.pack(">I", target_gpu_hz)
    cpu_be = struct.pack(">I", target_cpu_khz)

    gpu_count = 0
    for pos in find_all(dtb, STOCK_GPU_BE):
        dtb[pos : pos + 4] = gpu_be
        gpu_count += 1

    cpu_count = 0
    for pos in find_all(dtb, STOCK_CPU_BE):
        dtb[pos : pos + 4] = cpu_be
        cpu_count += 1

    return gpu_count, cpu_count


def process_qcdt_v2(data, target_gpu_mhz, target_cpu_mhz):
    """Process QCDT v2 image (24-byte entries, LE header)."""
    hdr_version = read_u32_le(data, 4)
    num_entries = read_u32_le(data, 8)

    print(f"  QCDT version: {hdr_version}")
    print(f"  Number of entries: {num_entries}")

    ENTRY_SIZE_V2 = 24
    total_gpu = 0
    total_cpu = 0

    for i in range(num_entries):
        offset = 12 + i * ENTRY_SIZE_V2
        entry = data[offset : offset + ENTRY_SIZE_V2]

        chipset = read_u32_le(entry, 0)
        platform = read_u32_le(entry, 4)
        subtype = read_u32_le(entry, 8)
        soc_rev = read_u32_le(entry, 12)
        dtb_offset = read_u32_le(entry, 16)
        dtb_size = read_u32_le(entry, 20)

        if dtb_offset <= 0 or dtb_size <= 0:
            print(f"  Entry {i}: chip=0x{chipset:x} plat=0x{platform:x} sub=0x{subtype:x} rev=0x{soc_rev:x} - no DTB, skipping")
            continue

        dtb_raw = bytearray(data[dtb_offset : dtb_offset + dtb_size])
        gpu, cpu = patch_binary_freqs(dtb_raw, target_gpu_mhz, target_cpu_mhz)
        total_gpu += gpu
        total_cpu += cpu

        status = "OK" if (gpu > 0 or cpu > 0) else "NO MATCHES"
        print(f"  Entry {i}: chip=0x{chipset:x} plat=0x{platform:x} sub=0x{subtype:x} rev=0x{soc_rev:x} gpu={gpu} cpu={cpu} [{status}]")
        data[dtb_offset : dtb_offset + dtb_size] = dtb_raw

    return total_gpu, total_cpu


def process_qcdt_v3_moto(data, target_gpu_mhz, target_cpu_mhz):
    """Process QCDT v3 Motorola image (72-byte entries, LE header)."""
    hdr_version = read_u32_le(data, 4)
    num_entries = read_u32_le(data, 8)
    mtor_version = (hdr_version >> 8) & 0xFF
    qcdt_version = hdr_version & 0xFF

    print(f"  QCDT version: {qcdt_version}, Motorola version: {mtor_version}")
    print(f"  Number of entries: {num_entries}")

    ENTRY_SIZE = 72
    total_gpu = 0
    total_cpu = 0

    for i in range(num_entries):
        offset = 12 + i * ENTRY_SIZE
        entry = data[offset : offset + ENTRY_SIZE]

        chipset = read_u32_le(entry, 0)
        platform = read_u32_le(entry, 4)
        subtype = read_u32_le(entry, 8)
        soc_rev = read_u32_le(entry, 12)
        dtb_offset = read_u32_le(entry, 32)
        dtb_size = read_u32_le(entry, 36)
        model = entry[40:72].split(b"\x00")[0].decode("ascii", errors="replace")

        if dtb_offset <= 0 or dtb_size <= 0:
            print(f"  Entry {i}: model={model!r} - no DTB, skipping")
            continue

        dtb_raw = bytearray(data[dtb_offset : dtb_offset + dtb_size])
        gpu, cpu = patch_binary_freqs(dtb_raw, target_gpu_mhz, target_cpu_mhz)
        total_gpu += gpu
        total_cpu += cpu

        status = "OK" if (gpu > 0 or cpu > 0) else "NO MATCHES"
        print(f"  Entry {i}: model={model!r} gpu={gpu} cpu={cpu} [{status}]")
        data[dtb_offset : dtb_offset + dtb_size] = dtb_raw

    return total_gpu, total_cpu


def main():
    parser = argparse.ArgumentParser(description="Binary-patch GPU/CPU freq in DT image")
    parser.add_argument("input", help="Input image (QCDT or DTB)")
    parser.add_argument("output", help="Output image")
    parser.add_argument("--gpu-mhz", type=int, default=700, help="Target GPU MHz (default: 700)")
    parser.add_argument("--cpu-mhz", type=int, default=2300, help="Target CPU MHz (default: 2300)")
    args = parser.parse_args()

    with open(args.input, "rb") as f:
        data = bytearray(f.read())

    print(f"Input: {args.input} ({len(data)} bytes)")
    print(f"Stock values (big-endian):")
    print(f"  GPU: 0x{STOCK_GPU_HZ:08x} Hz -> {STOCK_GPU_BE.hex()}")
    print(f"  CPU: 0x{STOCK_CPU_KHZ:08x} KHz -> {STOCK_CPU_BE.hex()}")

    if data[:4] == QCDT_MAGIC:
        hdr_version = read_u32_le(data, 4)
        qcdt_ver = hdr_version & 0xFF
        mtor_ver = (hdr_version >> 8) & 0xFF

        if mtor_ver > 0:
            print("Format: QCDT v3 Motorola")
            gpu_total, cpu_total = process_qcdt_v3_moto(data, args.gpu_mhz, args.cpu_mhz)
        elif qcdt_ver >= 2:
            print("Format: QCDT v2")
            gpu_total, cpu_total = process_qcdt_v2(data, args.gpu_mhz, args.cpu_mhz)
        else:
            print(f"Format: QCDT v{qcdt_ver} (treating as v2)")
            gpu_total, cpu_total = process_qcdt_v2(data, args.gpu_mhz, args.cpu_mhz)
        output = bytes(data)
    elif data[:4] == FDT_MAGIC:
        print("Format: Standalone FDT/DTB")
        output = bytearray(data)
        gpu_total, cpu_total = patch_binary_freqs(output, args.gpu_mhz, args.cpu_mhz)
        output = bytes(output)
    else:
        print("Format: unknown header, scanning for FDT blobs...")
        output = bytearray(data)
        gpu_total, cpu_total = patch_binary_freqs(output, args.gpu_mhz, args.cpu_mhz)
        output = bytes(output)

    print(f"\nResults: GPU patched={gpu_total}, CPU patched={cpu_total}")

    if gpu_total == 0 and cpu_total == 0:
        print("\nERROR: No stock frequency values were found!")
        print("  Expected big-endian byte patterns:")
        print(f"    GPU: {STOCK_GPU_BE.hex()} (0x{STOCK_GPU_HZ:08x} Hz)")
        print(f"    CPU: {STOCK_CPU_BE.hex()} (0x{STOCK_CPU_KHZ:08x} KHz)")
        sys.exit(1)

    with open(args.output, "wb") as f:
        f.write(output)

    print(f"Output: {args.output} ({len(output)} bytes)")


if __name__ == "__main__":
    main()
