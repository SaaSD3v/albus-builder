#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import stat
import subprocess

CURRENT_KERNEL_COMMIT = os.environ.get(
    "ALBUS_KERNEL_COMMIT",
    "9a7416218ae637c4120c417b31428bb0747fdfdf",
)

OPTIONAL_SYMBOLS = (
    "IP_SET",
    "IP_SET_HASH_IP",
    "IP_SET_HASH_NET",
    "NETFILTER_XT_SET",
    "NETFILTER_XT_MATCH_RECENT",
    "NETFILTER_XT_MATCH_OWNER",
)

KSU_SYMBOLS = (
    "KSU",
    "KSU_TAMPER_SYSCALL_TABLE",
    "KSU_THRONE_TRACKER_ALWAYS_THREADED",
    "KSU_LSM_SECURITY_HOOKS",
)


def die(message: str) -> None:
    raise SystemExit(message)


def patch_builder(path: Path, bare: bool) -> str:
    text = path.read_text()

    text, count = re.subn(
        r'readonly KERNEL_COMMIT="[0-9a-f]{40}"',
        f'readonly KERNEL_COMMIT="{CURRENT_KERNEL_COMMIT}"',
        text,
        count=1,
    )
    if count != 1:
        die(f"{path}: expected exactly one pinned KERNEL_COMMIT")

    # The current lineage-15.1 source contains KernelSU integration, but recovery
    # remains KernelSU-free by disabling CONFIG_KSU in the temporary build config.
    old_source_guard = '''[[ ! -e "${KERNEL_DIR}/drivers/kernelsu" ]] \\
  || die "the pinned kernel source unexpectedly contains KernelSU"
if grep -Fq 'drivers/kernelsu/Kconfig' "${KERNEL_DIR}/drivers/Kconfig" \\
  || grep -Eq 'CONFIG_KSU|kernelsu/' "${KERNEL_DIR}/drivers/Makefile"; then
  die "the pinned kernel source contains KernelSU integration hooks"
fi
'''
    text = text.replace(old_source_guard, "")

    clone_re = re.compile(
        r'^(?P<line>clone_commit "\$KERNEL_REPO" "\$KERNEL_COMMIT" (?P<dest>.+))$',
        re.MULTILINE,
    )
    match = clone_re.search(text)
    if not match:
        die(f"{path}: kernel clone line not found")
    dest = match.group("dest")
    source_checks = f'''{match.group("line")}
CURRENT_KERNEL_DIR={dest}
grep -Fqx 'CONFIG_ANDROID_PARANOID_NETWORK=n' "${{CURRENT_KERNEL_DIR}}/arch/arm64/configs/albus_defconfig" || die "current lineage-15.1 source is missing CONFIG_ANDROID_PARANOID_NETWORK=n"
grep -Fqx '#include <linux/android_aid.h>' "${{CURRENT_KERNEL_DIR}}/security/commoncap.c" || die "current lineage-15.1 source is missing the Android AID Wi-Fi fix"
if grep -Fq '#ifdef CONFIG_ANDROID_PARANOID_NETWORK' "${{CURRENT_KERNEL_DIR}}/security/commoncap.c"; then
  die "CONFIG_ANDROID_PARANOID_NETWORK still gates security/commoncap.c"
fi
grep -Fq 'AID_NET_RAW' "${{CURRENT_KERNEL_DIR}}/security/commoncap.c" || die "AID_NET_RAW capability mapping is missing"
grep -Fq 'AID_NET_ADMIN' "${{CURRENT_KERNEL_DIR}}/security/commoncap.c" || die "AID_NET_ADMIN capability mapping is missing"
'''
    text = clone_re.sub(source_checks.rstrip("\n"), text, count=1)

    config_re = re.compile(
        r'^(?P<prefix>.+/scripts/config" --file "\$KERNEL_CONFIG") --enable RD_LZMA$',
        re.MULTILINE,
    )
    match = config_re.search(text)
    if not match:
        die(f"{path}: scripts/config RD_LZMA line not found")

    prefix = match.group("prefix")
    config_lines = [match.group(0)]
    for symbol in KSU_SYMBOLS:
        config_lines.append(f'{prefix} --disable {symbol}')
    if bare:
        for symbol in OPTIONAL_SYMBOLS:
            config_lines.append(f'{prefix} --disable {symbol}')
    text = config_re.sub("\n".join(config_lines), text, count=1)

    olddef_re = re.compile(
        r'^(?P<line>make "\$\{MAKE_ARGS\[@\]\}" olddefconfig)$',
        re.MULTILINE,
    )
    match = olddef_re.search(text)
    if not match:
        die(f"{path}: olddefconfig line not found")

    verify = [
        match.group("line"),
        "grep -Fqx '# CONFIG_KSU is not set' \"$KERNEL_CONFIG\" || die \"KernelSU must remain disabled in recovery\"",
        "grep -Fqx '# CONFIG_ANDROID_PARANOID_NETWORK is not set' \"$KERNEL_CONFIG\" || die \"CONFIG_ANDROID_PARANOID_NETWORK must remain disabled\"",
    ]
    if bare:
        verify.extend(
            [
                "for symbol in " + " ".join(OPTIONAL_SYMBOLS) + "; do",
                "  if grep -Fqx \"CONFIG_${symbol}=y\" \"$KERNEL_CONFIG\"; then",
                "    die \"bare recovery unexpectedly enabled CONFIG_${symbol}\"",
                "  fi",
                "done",
            ]
        )
    text = olddef_re.sub("\n".join(verify), text, count=1)

    ignored = "RD_LZMA|DECOMPRESS_LZMA|KSU.*"
    if bare:
        ignored += "|IP_SET.*|NETFILTER_XT_SET|NETFILTER_XT_MATCH_RECENT|NETFILTER_XT_MATCH_OWNER"
    text = text.replace("RD_LZMA|DECOMPRESS_LZMA", ignored)

    old_ksu_guard = '''if grep -Eq '^(# )?CONFIG_KSU([_= ]|$)' "$KERNEL_CONFIG"; then
  die "KernelSU configuration symbols unexpectedly exist"
fi
'''
    text = text.replace(old_ksu_guard, "")

    text = text.replace(
        "require_config 'CONFIG_ANDROID_PARANOID_NETWORK=y'",
        "require_config '# CONFIG_ANDROID_PARANOID_NETWORK is not set'",
    )

    return text


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("builder", type=Path)
    parser.add_argument("--bare", action="store_true")
    args = parser.parse_args()

    builder = args.builder.resolve()
    if not builder.is_file():
        die(f"builder not found: {builder}")

    patched = patch_builder(builder, args.bare)
    temp = builder.with_name(f".{builder.name}.current-tree.tmp")
    temp.write_text(patched)
    temp.chmod(temp.stat().st_mode | stat.S_IXUSR)

    print(f"Using kernel commit: {CURRENT_KERNEL_COMMIT}")
    print("Recovery KSU state: disabled")
    print("ANDROID_PARANOID_NETWORK: disabled; legacy Android Wi-Fi capabilities preserved")
    if args.bare:
        print("Bare variant: optional DroidSpaces firewall/IP-set layer disabled")

    try:
        subprocess.run(["bash", str(temp)], check=True, env=os.environ.copy())
    finally:
        temp.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
