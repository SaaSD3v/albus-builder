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

# Extra compatibility patches needed by the upstream recovery config and the
# LineageOS-style LLVM toolchain used for the Albus 4.9 kernel.
check_anchor = '[[ -f "${ROOT_DIR}/patches/4.9/0002-android-preserve-network-AID-capabilities.patch" ]] || { echo "error: Android network AID patch is missing" >&2; exit 1; }'
check_extra = check_anchor + '\n[[ -f "${ROOT_DIR}/patches/4.9/0003-nfc-nq-nci-pass-device-context-to-hardware-check.patch" ]] || { echo "error: NQ-NCI 4.9 compile fix is missing" >&2; exit 1; }\n[[ -f "${ROOT_DIR}/patches/4.9/0004-arm64-vdso-fix-llvm-ias-macro-call.patch" ]] || { echo "error: ARM64 VDSO LLVM IAS fix is missing" >&2; exit 1; }\n[[ -f "${ROOT_DIR}/patches/4.9/0005-arm64-fix-llvm-ias-cache-and-aes-syntax.patch" ]] || { echo "error: ARM64 cache/AES LLVM IAS fix is missing" >&2; exit 1; }'
if text.count(check_anchor) != 1:
    raise SystemExit('failed to find 0002 patch presence check')
text = text.replace(check_anchor, check_extra, 1)

# These strings live inside an f-string in build-recovery-console.sh, so the
# source form intentionally contains doubled braces around ROOT_DIR.
apply_anchor = 'git -C "$KERNEL_DIR" apply "${{ROOT_DIR}}/patches/4.9/0002-android-preserve-network-AID-capabilities.patch"'
apply_extra = apply_anchor + '\ngit -C "$KERNEL_DIR" apply --check "${{ROOT_DIR}}/patches/4.9/0003-nfc-nq-nci-pass-device-context-to-hardware-check.patch"\ngit -C "$KERNEL_DIR" apply "${{ROOT_DIR}}/patches/4.9/0003-nfc-nq-nci-pass-device-context-to-hardware-check.patch"\ngit -C "$KERNEL_DIR" apply --check "${{ROOT_DIR}}/patches/4.9/0004-arm64-vdso-fix-llvm-ias-macro-call.patch"\ngit -C "$KERNEL_DIR" apply "${{ROOT_DIR}}/patches/4.9/0004-arm64-vdso-fix-llvm-ias-macro-call.patch"\ngit -C "$KERNEL_DIR" apply --check "${{ROOT_DIR}}/patches/4.9/0005-arm64-fix-llvm-ias-cache-and-aes-syntax.patch"\ngit -C "$KERNEL_DIR" apply "${{ROOT_DIR}}/patches/4.9/0005-arm64-fix-llvm-ias-cache-and-aes-syntax.patch"'
if text.count(apply_anchor) != 1:
    raise SystemExit('failed to find 0002 patch apply anchor')
text = text.replace(apply_anchor, apply_extra, 1)

# Match the LineageOS 20 kernel build model used by the Albus device tree:
# Clang for C, LLVM integrated assembler, LLD and llvm-ar. Keep the pinned
# Android GCC 4.9 prefixes available as compatibility toolchains because this
# 4.9 tree still consumes CROSS_COMPILE/CROSS_COMPILE_ARM32 in a few places.
anchor = "config_pattern=re.compile("
injection = r"""replace_once('make \"${MAKE_ARGS[@]}\" albus_defconfig','make \"${MAKE_ARGS[@]}\" recovery_albus_defconfig','4.9 recovery defconfig target')
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
  "CC=clang-14"
  "CLANG_TRIPLE=aarch64-linux-gnu-"
  "LD=ld.lld-14"
  "AR=llvm-ar-14"
  "LLVM=1"
  "LLVM_IAS=1"
)''','LineageOS-style Clang/LLVM kernel toolchain')
if text.count('KCFLAGS=-mno-android') != 1:
    raise SystemExit('expected exactly one GCC-only KCFLAGS=-mno-android')
text = text.replace('KCFLAGS=-mno-android', 'KCFLAGS=', 1)
replace_once('''python --version
"${CROSS_COMPILE}gcc" --version
''','''python --version
command -v clang-14 >/dev/null 2>&1 || die "clang-14 is required for the Albus 4.9 kernel"
command -v ld.lld-14 >/dev/null 2>&1 || die "ld.lld-14 is required for the Albus 4.9 kernel"
command -v llvm-ar-14 >/dev/null 2>&1 || die "llvm-ar-14 is required for the Albus 4.9 kernel"
clang-14 --version
ld.lld-14 --version
llvm-ar-14 --version
"${CROSS_COMPILE}gcc" --version
''','LLVM toolchain availability check')
"""
if text.count(anchor) != 1:
    raise SystemExit('failed to find config_pattern anchor')
text = text.replace(anchor, injection + anchor, 1)

banner = "printf 'Kernel commit: %s\\n' \"$KERNEL_COMMIT_49\"\n"
extra = "printf 'Kernel config: recovery_albus_defconfig (upstream Marcost2)\\n'\nprintf 'Kernel compiler: clang-14 + LLVM IAS/LLD (LineageOS 20 model)\\n'\n"
if text.count(banner) != 1:
    raise SystemExit('failed to find banner anchor')
text = text.replace(banner, banner + extra, 1)

out.write_text(text)
out.chmod(0o755)
PY

bash "$GENERATED"
