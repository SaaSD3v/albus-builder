#!/usr/bin/env python3
"""
Patch GPU and CPU frequency tables in a Motorola QCDT v3 dt.img.

Extracts each DTB, decompiles with dtc, patches frequency tables,
recompiles, and rebuilds the QCDT image.

Usage:
    python3 overclock_dt.py <input_dt.img> <output_dt.img> [--gpu-mhz 700] [--cpu-mhz 2300]
"""

import argparse
import io
import os
import struct
import subprocess
import sys
import tempfile

QCDT_MAGIC = b"QCDT"
ENTRY_SIZE_MOTO_V3 = 72  # 40 (v3 base) + 32 (motorola model)


def read_u32_le(data, offset):
    return struct.unpack("<I", data[offset : offset + 4])[0]


def write_u32_le(value):
    return struct.pack("<I", value & 0xFFFFFFFF)


def parse_qcdt(data):
    """Parse QCDT v3 Motorola image, return (header_info, entries, dtb_data)."""
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
            }
        )

        if dtb_offset > 0 and dtb_size > 0:
            dtb_raw = data[dtb_offset : dtb_offset + dtb_size]
            dtb_magic_pos = dtb_raw.find(b"\xd0\x0d\xfe\xed")
            if dtb_magic_pos >= 0:
                entries[-1]["dtb_data"] = dtb_raw[dtb_magic_pos:]
            else:
                entries[-1]["dtb_data"] = dtb_raw
        else:
            entries[-1]["dtb_data"] = b""

        print(
            f"  Entry {i}: chip=0x{chipset:x} plat=0x{platform:x} "
            f"sub=0x{subtype:x} rev=0x{soc_rev:x} model={model!r} "
            f"dtb_size={dtb_size}"
        )

    return {
        "hdr_version": hdr_version,
        "num_entries": num_entries,
        "entries": entries,
    }


def decompile_dtb(dtb_data, dtc_path="dtc"):
    """Decompile DTB to DTS text using dtc."""
    with tempfile.NamedTemporaryFile(suffix=".dtb", delete=False) as f:
        f.write(dtb_data)
        dtb_path = f.name

    try:
        result = subprocess.run(
            [dtc_path, "-I", "dtb", "-O", "dts", "-q", dtb_path],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"  WARNING: dtc decompile failed: {result.stderr}", file=sys.stderr)
            return None
        return result.stdout
    finally:
        os.unlink(dtb_path)


def recompile_dts(dts_text, dtc_path="dtc"):
    """Compile DTS text back to DTB using dtc."""
    with tempfile.NamedTemporaryFile(suffix=".dts", mode="w", delete=False) as f:
        f.write(dts_text)
        dts_path = f.name

    dtb_path = dts_path.replace(".dts", ".dtb")
    try:
        result = subprocess.run(
            [dtc_path, "-I", "dts", "-O", "dtb", "-q", "-o", dtb_path, dts_path],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            print(f"  WARNING: dtc compile failed: {result.stderr}", file=sys.stderr)
            return None

        with open(dtb_path, "rb") as f:
            return f.read()
    finally:
        for p in [dts_path, dtb_path]:
            if os.path.exists(p):
                os.unlink(p)


def patch_gpu_freq_table(dts, target_gpu_mhz):
    """Patch GPU frequency table to reach target_gpu_mhz as max."""
    target_hz = target_gpu_mhz * 1000000
    target_hex = f"<0x{target_hz:08x}>"

    lines = dts.split("\n")
    new_lines = []
    patched = False

    for i, line in enumerate(lines):
        if "qcom,gpu-pwrlevel@0 {" in line:
            new_lines.append(line)
            continue

        if patched is False and "qcom,gpu-freq = <0x" in line:
            old_val = line.strip()
            indent = line[: len(line) - len(line.lstrip())]
            new_lines.append(f"{indent}qcom,gpu-freq = {target_hex};")
            print(f"  GPU: patched max freq to {target_gpu_mhz} MHz (was in original)")
            patched = True
            continue

        new_lines.append(line)

    return "\n".join(new_lines)


def patch_cpu_freq_table(dts, target_cpu_mhz):
    """Patch CPU cpufreq table to add target_cpu_mhz as max entry."""
    target_khz = target_cpu_mhz * 1000
    target_hex = f"0x{target_khz:08x}"

    lines = dts.split("\n")
    new_lines = []
    patched = False

    for i, line in enumerate(lines):
        if "qcom,cpufreq-table" in line and not patched:
            indent = line[: len(line) - len(line.lstrip())]
            stripped = line.strip()

            old_start = stripped.index("<")
            old_end = stripped.index(">") + 1
            old_entries = stripped[old_start + 1 : old_end - 1].strip()

            if old_entries.endswith(";"):
                old_entries = old_entries[:-1].strip()

            entries = [e.strip() for e in old_entries.split() if e.strip()]

            entries.append(target_hex)

            new_table = f"{indent}qcom,cpufreq-table = <{' '.join(entries)}>;"
            new_lines.append(new_table)
            print(
                f"  CPU: added {target_cpu_mhz} MHz OPP to cpufreq table"
            )
            patched = True
            continue

        new_lines.append(line)

    return "\n".join(new_lines)


def build_qcdt(image_info, page_size=2048):
    """Rebuild QCDT v3 Motorola image from modified entries."""
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
    parser = argparse.ArgumentParser(description="Patch GPU/CPU freq in QCDT dt.img")
    parser.add_argument("input", help="Input dt.img path")
    parser.add_argument("output", help="Output dt.img path")
    parser.add_argument("--gpu-mhz", type=int, default=700, help="Target GPU MHz (default: 700)")
    parser.add_argument("--cpu-mhz", type=int, default=2300, help="Target CPU MHz (default: 2300)")
    parser.add_argument("--dtc", default="dtc", help="Path to dtc binary")
    args = parser.parse_args()

    with open(args.input, "rb") as f:
        data = f.read()

    print(f"Input: {args.input} ({len(data)} bytes)")
    image_info = parse_qcdt(data)

    print(f"\nPatching to GPU={args.gpu_mhz} MHz, CPU={args.cpu_mhz} MHz")
    dtc_path = args.dtc

    for i, entry in enumerate(image_info["entries"]):
        if not entry["dtb_data"]:
            print(f"  Entry {i}: no DTB data, skipping")
            continue

        print(f"\n  Processing entry {i} ({entry['model']!r})...")

        dts = decompile_dtb(entry["dtb_data"], dtc_path)
        if dts is None:
            print(f"  Entry {i}: decompile failed, skipping")
            continue

        dts = patch_gpu_freq_table(dts, args.gpu_mhz)
        dts = patch_cpu_freq_table(dts, args.cpu_mhz)

        new_dtb = recompile_dts(dts, dtc_path)
        if new_dtb is None:
            print(f"  Entry {i}: recompile failed, skipping")
            continue

        entry["dtb_data"] = new_dtb
        print(f"  Entry {i}: patched OK ({len(new_dtb)} bytes)")

    print("\nRebuilding QCDT image...")
    output = build_qcdt(image_info)

    with open(args.output, "wb") as f:
        f.write(output)

    print(f"Output: {args.output} ({len(output)} bytes)")


if __name__ == "__main__":
    main()
