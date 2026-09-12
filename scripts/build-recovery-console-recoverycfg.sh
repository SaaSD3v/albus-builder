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

# The newer upstream recovery config exposes the NQ-NCI build bug that was
# already fixed during the earlier Albus 4.9 validation. Reuse that exact,
# attributed fix instead of changing the kernel logic here.
check_anchor = '[[ -f "${ROOT_DIR}/patches/4.9/0002-android-preserve-network-AID-capabilities.patch" ]] || { echo "error: Android network AID patch is missing" >&2; exit 1; }'
check_extra = check_anchor + '\n[[ -f "${ROOT_DIR}/patches/4.9/0003-nfc-nq-nci-pass-device-context-to-hardware-check.patch" ]] || { echo "error: NQ-NCI 4.9 compile fix is missing" >&2; exit 1; }'
if text.count(check_anchor) != 1:
    raise SystemExit('failed to find 0002 patch presence check')
text = text.replace(check_anchor, check_extra, 1)

apply_anchor = 'git -C "$KERNEL_DIR" apply "${ROOT_DIR}/patches/4.9/0002-android-preserve-network-AID-capabilities.patch"'
apply_extra = apply_anchor + '\ngit -C "$KERNEL_DIR" apply --check "${ROOT_DIR}/patches/4.9/0003-nfc-nq-nci-pass-device-context-to-hardware-check.patch"\ngit -C "$KERNEL_DIR" apply "${ROOT_DIR}/patches/4.9/0003-nfc-nq-nci-pass-device-context-to-hardware-check.patch"'
if text.count(apply_anchor) != 1:
    raise SystemExit('failed to find 0002 patch apply anchor')
text = text.replace(apply_anchor, apply_extra, 1)

anchor = "config_pattern=re.compile("
injection = "replace_once('make \\\"${MAKE_ARGS[@]}\\\" albus_defconfig','make \\\"${MAKE_ARGS[@]}\\\" recovery_albus_defconfig','4.9 recovery defconfig target')\n"
if text.count(anchor) != 1:
    raise SystemExit('failed to find config_pattern anchor')
text = text.replace(anchor, injection + anchor, 1)

banner = "printf 'Kernel commit: %s\\n' \"$KERNEL_COMMIT_49\"\n"
extra = "printf 'Kernel config: recovery_albus_defconfig (upstream Marcost2)\\n'\n"
if text.count(banner) != 1:
    raise SystemExit('failed to find banner anchor')
text = text.replace(banner, banner + extra, 1)

out.write_text(text)
out.chmod(0o755)
PY

bash "$GENERATED"
