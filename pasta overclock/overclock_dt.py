#!/usr/bin/env python3
"""
Binary-patch GPU and CPU frequency values in a device-tree image.

Works on both standalone DTB files and QCDT v3 Motorola containers.
Does NOT use dtc - performs direct byte replacement of known stock
frequency values to preserve all Qualcomm-specific properties.

Usage:
    python3 overclock_dt.py <input> <output> [--gpu-mhz 700] [--cpu-mhz 2300]
"""

import argparse
import struct
import sys

QCDT_MAGIC = b"QCDT"
ENTRY_SIZE_MOTO_V3 = 72
FDT_MAGIC = b"\xd0\x0d\xfe\xed"

# Known stock frequencies (Hz for GPU, KHz for CPU table entries)
# These are the raw u32 values as they appear in the compiled DTB binary.
# Snapdragon 626 / msm8953 stock OPPs:
#   GPU: 200 320 400 480 520 560 580 600 620 640 650 MHz
#   CPU: 300 400 500 600 700 800 900 1000 1200 1400 1600 1800 2000 2208 MHz
#
# qcom,gpu-freq uses Hz: 650000000 = 0x26BE3680
# qcom,cpufreq-table uses KHz: 2208000 = 0x0021B100
STOCK_GPU_HZ = 650_000_000
STOCK_CPU_KHZ = 2_208_000

STOCK_GPU_LE = struct.pack("<I", STOCK_GPU_HZ)
STOCK_CPU_LE = struct.pack("<I", STOCK_CPU_KHZ)


def read_u32_le(data, offset):
    return struct.unpack("<I", data[offset : offset + 4])[0]


def write_u32_le(value):
    return struct.pack("<I", value & 0xFFFFFFFF)


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
    """Patch stock freq values in a DTB blob. Returns (gpu_patched, cpu_patched)."""
    target_gpu_hz = target_gpu_mhz * 1_000_000
    target_cpu_khz = target_cpu_mhz * 1_000

    gpu_le = struct.pack("<I", target_gpu_hz)
    cpu_le = struct.pack("<I", target_cpu_khz)

    gpu_count = 0
    for pos in find_all(dtb, STOCK_GPU_LE):
        dtb[pos : pos + 4] = gpu_le
        gpu_count += 1

    cpu_count = 0
    for pos in find_all(dtb, STOCK_CPU_LE):
        dtb[pos : pos + 4] = cpu_le
        cpu_count += 1

    return gpu_count, cpu_count


def is_qcdt(data):
    return data[:4] == QCDT_MAGIC


def is_fdt(data):
    return data[:4] == FDT_MAGIC


def process_qcdt(data, target_gpu_mhz, target_cpu_mhz):
    """Process a QCDT v3 Motorola container."""
    hdr_version = read_u32_le(data, 4)
    num_entries = read_u32_le(data, 8)
    mtor_version = (hdr_version >> 8) & 0xFF
    qcdt_version = hdr_version & 0xFF

    print(f"  QCDT version: {qcdt_version}, Motorola version: {mtor_version}")
    print(f"  Number of entries: {num_entries}")

    total_gpu = 0
    total_cpu = 0

    for i in range(num_entries):
        offset = 12 + i * ENTRY_SIZE_MOTO_V3
        entry_data = data[offset : offset + ENTRY_SIZE_MOTO_V3]

        chipset = read_u32_le(entry_data, 0)
        platform = read_u32_le(entry_data, 4)
        subtype = read_u32_le(entry_data, 8)
        soc_rev = read_u32_le(entry_data, 12)
        dtb_offset = read_u32_le(entry_data, 32)
        dtb_size = read_u32_le(entry_data, 36)
        model = entry_data[40:72].split(b"\x00")[0].decode("ascii", errors="replace")

        if dtb_offset <= 0 or dtb_size <= 0:
            print(f"  Entry {i}: no DTB, skipping")
            continue

        dtb_raw = bytearray(data[dtb_offset : dtb_offset + dtb_size])

        gpu, cpu = patch_binary_freqs(dtb_raw, target_gpu_mhz, target_cpu_mhz)
        total_gpu += gpu
        total_cpu += cpu

        status = "OK" if (gpu > 0 or cpu > 0) else "NO MATCHES"
        print(
            f"  Entry {i}: model={model!r} chip=0x{chipset:x} "
            f"gpu_patched={gpu} cpu_patched={cpu} [{status}]"
        )

        data[dtb_offset : dtb_offset + dtb_size] = dtb_raw

    return total_gpu, total_cpu


def process_fdt(data, target_gpu_mhz, target_cpu_mhz):
    """Process a standalone FDT/DTB blob."""
    dtb = bytearray(data)
    gpu, cpu = patch_binary_freqs(dtb, target_gpu_mhz, target_cpu_mhz)
    print(f"  FDT: gpu_patched={gpu} cpu_patched={cpu}")
    return bytes(dtb), gpu, cpu


def main():
    parser = argparse.ArgumentParser(
        description="Binary-patch GPU/CPU freq in DT image"
    )
    parser.add_argument("input", help="Input image (QCDT or DTB)")
    parser.add_argument("output", help="Output image")
    parser.add_argument(
        "--gpu-mhz", type=int, default=700, help="Target GPU MHz (default: 700)"
    )
    parser.add_argument(
        "--cpu-mhz", type=int, default=2300, help="Target CPU MHz (default: 2300)"
    )
    args = parser.parse_args()

    with open(args.input, "rb") as f:
        data = bytearray(f.read())

    print(f"Input: {args.input} ({len(data)} bytes)")

    if is_qcdt(data):
        print("Format: QCDT v3 Motorola container")
        gpu_total, cpu_total = process_qcdt(data, args.gpu_mhz, args.cpu_mhz)
        output = bytes(data)
    elif is_fdt(data):
        print("Format: Standalone FDT/DTB")
        output, gpu_total, cpu_total = process_fdt(data, args.gpu_mhz, args.cpu_mhz)
    else:
        # Could be a QCDT where FDT magic is at an offset
        fdt_pos = data.find(FDT_MAGIC)
        if fdt_pos >= 0:
            print(f"Format: Unknown header, FDT found at offset {fdt_pos}")
            print("  Attempting QCDT parse...")
            try:
                gpu_total, cpu_total = process_qcdt(
                    data, args.gpu_mhz, args.cpu_mhz
                )
                output = bytes(data)
            except Exception:
                print("  QCDT parse failed, trying raw FDT patch...")
                dtb = bytearray(data[fdt_pos:])
                gpu_total, cpu_total = patch_binary_freqs(
                    dtb, args.gpu_mhz, args.cpu_mhz
                )
                output = data[:fdt_pos] + bytes(dtb)
        else:
            print("ERROR: unrecognized image format (no QCDT or FDT magic found)")
            sys.exit(1)

    print(f"\nResults: GPU patched={gpu_total}, CPU patched={cpu_total}")

    if gpu_total == 0 and cpu_total == 0:
        print("\nWARNING: No stock frequency values were found!")
        print("  The image may use different frequency values than expected.")
        print("  Output file will be identical to input.")
        sys.exit(1)

    with open(args.output, "wb") as f:
        f.write(output)

    print(f"Output: {args.output} ({len(output)} bytes)")


if __name__ == "__main__":
    main()
