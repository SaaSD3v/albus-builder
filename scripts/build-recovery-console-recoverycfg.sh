#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly SOURCE="${ROOT_DIR}/scripts/build-recovery-console.sh"
readonly GENERATED="${ROOT_DIR}/scripts/.build-recovery-console-recoverycfg.generated.sh"

cleanup() { rm -f "$GENERATED"; }
trap cleanup EXIT

python3 - "$SOURCE" "$GENERATED" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1])
out = Path(sys.argv[2])
text = src.read_text()

replacements = {
    'readonly KERNEL_COMMIT_49="a9572cf3d93be15565ba24c163e3333971927f70"':
        'readonly KERNEL_COMMIT_49="b9f0de7ad9a80a66bf0a7a1a166a06ba9f22d568"',
    'readonly KERNEL_TREE_49="343f9d8d670495b28fd8f949cd66e982fea4ff58"':
        'readonly KERNEL_TREE_49="2d23153884afe8ee51af10de71f68eb56b7f129a"',
}
for old, new in replacements.items():
    if text.count(old) != 1:
        raise SystemExit(f'expected exactly one occurrence of: {old}')
    text = text.replace(old, new, 1)

# The upstream Albus device tree is LineageOS 18.1. Its kernel build path uses
# Clang for C while keeping the GNU cross toolchains/binutils. Keep only source
# compatibility fixes that are independent of the old LLVM-IAS experiments.
check_anchor = '[[ -f "${ROOT_DIR}/patches/4.9/0002-android-preserve-network-AID-capabilities.patch" ]] || { echo "error: Android network AID patch is missing" >&2; exit 1; }'
check_extra = check_anchor + '\n[[ -f "${ROOT_DIR}/patches/4.9/0003-nfc-nq-nci-pass-device-context-to-hardware-check.patch" ]] || { echo "error: NQ-NCI 4.9 compile fix is missing" >&2; exit 1; }\n[[ -f "${ROOT_DIR}/patches/4.9/0004-power-supply-fix-smbchg-null-return.patch" ]] || { echo "error: SMB charger Clang 11 compile fix is missing" >&2; exit 1; }'
if text.count(check_anchor) != 1:
    raise SystemExit('failed to find 0002 patch presence check')
text = text.replace(check_anchor, check_extra, 1)

# These strings live inside an f-string in build-recovery-console.sh, so the
# source form intentionally contains doubled braces around ROOT_DIR.
apply_anchor = 'git -C "$KERNEL_DIR" apply "${{ROOT_DIR}}/patches/4.9/0002-android-preserve-network-AID-capabilities.patch"'
apply_extra = apply_anchor + '\ngit -C "$KERNEL_DIR" apply --check "${{ROOT_DIR}}/patches/4.9/0003-nfc-nq-nci-pass-device-context-to-hardware-check.patch"\ngit -C "$KERNEL_DIR" apply "${{ROOT_DIR}}/patches/4.9/0003-nfc-nq-nci-pass-device-context-to-hardware-check.patch"\ngit -C "$KERNEL_DIR" apply --check "${{ROOT_DIR}}/patches/4.9/0004-power-supply-fix-smbchg-null-return.patch"\ngit -C "$KERNEL_DIR" apply "${{ROOT_DIR}}/patches/4.9/0004-power-supply-fix-smbchg-null-return.patch"'
if text.count(apply_anchor) != 1:
    raise SystemExit('failed to find 0002 patch apply anchor')
text = text.replace(apply_anchor, apply_extra, 1)

# Reproduce the LineageOS 18.1 kernel build model used by the Albus device
# tree. LineageOS 18.1 defaults to AOSP clang-r383902b1 (Clang 11.0.2), with
# CC=clang and CLANG_TRIPLE=aarch64-linux-gnu-. It does not force LLVM=1,
# LLVM_IAS=1 or LLD for this device.
anchor = "config_pattern=re.compile("
injection = r"""replace_once('make \"${MAKE_ARGS[@]}\" albus_defconfig','make \"${MAKE_ARGS[@]}\" recovery_albus_defconfig','4.9 recovery defconfig target')
replace_once('''readonly ARM_TOOLCHAIN_DIR="${WORK_DIR}/arm-toolchain"
readonly DTBTOOL_DIR="${WORK_DIR}/dtbtool"''','''readonly ARM_TOOLCHAIN_DIR="${WORK_DIR}/arm-toolchain"
readonly CLANG_TOOLCHAIN_DIR="${WORK_DIR}/clang-r383902b1"
readonly CLANG_TOOLCHAIN_ARCHIVE="${WORK_DIR}/clang-r383902b1.tar.gz"
readonly CLANG_TOOLCHAIN_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android11-qpr2-release/clang-r383902b1.tar.gz"
readonly DTBTOOL_DIR="${WORK_DIR}/dtbtool"''','LineageOS 18.1 Clang work paths')
replace_once('''clone_tag "$ARM_TOOLCHAIN_REPO" "$TOOLCHAIN_TAG" "$ARM_TOOLCHAIN_TAG_OBJECT" "$ARM_TOOLCHAIN_COMMIT" "$ARM_TOOLCHAIN_DIR"
clone_commit "$DTBTOOL_REPO" "$DTBTOOL_COMMIT" "$DTBTOOL_DIR"''','''clone_tag "$ARM_TOOLCHAIN_REPO" "$TOOLCHAIN_TAG" "$ARM_TOOLCHAIN_TAG_OBJECT" "$ARM_TOOLCHAIN_COMMIT" "$ARM_TOOLCHAIN_DIR"
mkdir -p "$CLANG_TOOLCHAIN_DIR"
curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 \
  "$CLANG_TOOLCHAIN_URL" --output "$CLANG_TOOLCHAIN_ARCHIVE"
tar -xzf "$CLANG_TOOLCHAIN_ARCHIVE" -C "$CLANG_TOOLCHAIN_DIR"
printf 'AOSP AndroidVersion: '; cat "$CLANG_TOOLCHAIN_DIR/AndroidVersion.txt"
CLANG_VERSION_OUTPUT="$("$CLANG_TOOLCHAIN_DIR/bin/clang" --version)"
printf '%s\n' "$CLANG_VERSION_OUTPUT"
grep -Fq '11.0.2' <<<"$CLANG_VERSION_OUTPUT" \
  || die "unexpected clang version in clang-r383902b1"
grep -Fq 'r383902b1' <<<"$CLANG_VERSION_OUTPUT" \
  || die "unexpected clang revision in clang-r383902b1"
clone_commit "$DTBTOOL_REPO" "$DTBTOOL_COMMIT" "$DTBTOOL_DIR"''','download official LineageOS 18.1 era Clang')
replace_once('''export PATH="${AARCH64_TOOLCHAIN_DIR}/bin:${ARM_TOOLCHAIN_DIR}/bin:${PATH}"''','''export PATH="${CLANG_TOOLCHAIN_DIR}/bin:${AARCH64_TOOLCHAIN_DIR}/bin:${ARM_TOOLCHAIN_DIR}/bin:${PATH}"''','historical Clang PATH precedence')
replace_once('''readonly -a MAKE_ARGS=(
  -C "$KERNEL_DIR"
  "O=$KERNEL_OUT"
  "ARCH=$ARCH"
  "SUBARCH=$SUBARCH"
  "CROSS_COMPILE=$CROSS_COMPILE"
  "CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32"
)''','''readonly -a MAKE_ARGS=(
  -C "$KERNEL_DIR"
  "O=$KERNEL_OUT"
  "ARCH=$ARCH"
  "SUBARCH=$SUBARCH"
  "CROSS_COMPILE=$CROSS_COMPILE"
  "CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32"
  "CC=$CLANG_TOOLCHAIN_DIR/bin/clang"
  "CLANG_TRIPLE=aarch64-linux-gnu-"
)''','LineageOS 18.1 Clang/GNU kernel toolchain')
replace_once('''python --version
"${CROSS_COMPILE}gcc" --version
''','''python --version
"$CLANG_TOOLCHAIN_DIR/bin/clang" --version
"${CROSS_COMPILE}gcc" --version
''','historical Clang toolchain version check')
if text.count('  KCFLAGS=-mno-android \\\n') != 1:
    raise SystemExit('expected exactly one legacy KCFLAGS=-mno-android build line')
text = text.replace('  KCFLAGS=-mno-android \\\n', '', 1)
"""
if text.count(anchor) != 1:
    raise SystemExit('failed to find config_pattern anchor')
text = text.replace(anchor, injection + anchor, 1)

banner = "printf 'Kernel commit: %s\\n' \"$KERNEL_COMMIT_49\"\n"
extra = "printf 'Kernel config: recovery_albus_defconfig (upstream Marcost2)\\n'\nprintf 'Kernel compiler: AOSP clang-r383902b1 / Clang 11.0.2 + GNU binutils (LineageOS 18.1 model)\\n'\n"
if text.count(banner) != 1:
    raise SystemExit('failed to find banner anchor')
text = text.replace(banner, banner + extra, 1)

out.write_text(text)
out.chmod(0o755)
PY

bash "$GENERATED"
