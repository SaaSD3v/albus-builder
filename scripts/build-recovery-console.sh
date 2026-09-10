#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly BASE_BUILDER="${ROOT_DIR}/scripts/build.sh"
readonly GENERATED_BUILDER="${ROOT_DIR}/scripts/.build-recovery-console.generated.sh"
readonly RECOVERY_CONSOLE_COMMIT="0be3707df843664cbb69323c954c34c1d41ed7c3"

cleanup() {
  rm -f "$GENERATED_BUILDER" "${ROOT_DIR}/scripts/.build-recovery-console.generated.sh.current-tree.tmp"
}
trap cleanup EXIT

[[ -f "$BASE_BUILDER" ]] || {
  echo "error: base builder not found: $BASE_BUILDER" >&2
  exit 1
}
[[ -x "${ROOT_DIR}/scripts/integrate-recovery-console.sh" ]] || {
  echo "error: recovery-console integration helper is missing or not executable" >&2
  exit 1
}

python3 - "$BASE_BUILDER" "$GENERATED_BUILDER" "$RECOVERY_CONSOLE_COMMIT" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1])
out = Path(sys.argv[2])
console_commit = sys.argv[3]
text = source.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{source}: expected exactly one {label}, found {count}")
    text = text.replace(old, new, 1)

replace_once(
    '''  "$ARTIFACT_DIR/recovery.img" \\
  "$ARTIFACT_DIR/Image.gz" \\
''',
    '''  "$ARTIFACT_DIR/recovery.img" \\
  "$ARTIFACT_DIR/recovery-console-aarch64" \\
  "$ARTIFACT_DIR/Image.gz" \\
''',
    'artifact cleanup anchor',
)

replace_once(
    '''cp "$KERNEL_IMAGE" "${REPACK_DIR}/kernel"
cp "$DT_IMAGE" "${REPACK_DIR}/extra"

note "Repack recovery.img with the new kernel and matching DT"
''',
    '''cp "$KERNEL_IMAGE" "${REPACK_DIR}/kernel"
cp "$DT_IMAGE" "${REPACK_DIR}/extra"

note "Integrate recovery-console into the TWRP ramdisk"
readonly RECOVERY_CONSOLE_BINARY="${WORK_DIR}/recovery-console-aarch64"
"${ROOT_DIR}/scripts/integrate-recovery-console.sh" \\
  "${REPACK_DIR}/ramdisk.cpio" \\
  "$MAGISKBOOT" \\
  "$MAGISK_APK" \\
  "$WORK_DIR" \\
  "$RECOVERY_CONSOLE_BINARY"
[[ -x "$RECOVERY_CONSOLE_BINARY" ]] || die "recovery-console binary was not produced"
RECOVERY_CONSOLE_SHA256="$(sha256_of "$RECOVERY_CONSOLE_BINARY")"
readonly RECOVERY_CONSOLE_SHA256
PATCHED_RAMDISK_SHA256="$(sha256_of "${REPACK_DIR}/ramdisk.cpio")"
readonly PATCHED_RAMDISK_SHA256
[[ "$PATCHED_RAMDISK_SHA256" != "$TWRP_RAMDISK_SHA256" ]] \\
  || die "recovery-console integration did not modify the ramdisk"

note "Repack recovery.img with the new kernel, matching DT and recovery-console ramdisk"
''',
    'kernel/DT repack anchor',
)

replace_once(
    '''check_sha256 "$TWRP_RAMDISK_SHA256" "${VERIFY_DIR}/ramdisk.cpio"
''',
    '''check_sha256 "$PATCHED_RAMDISK_SHA256" "${VERIFY_DIR}/ramdisk.cpio"
cmp -s "${REPACK_DIR}/ramdisk.cpio" "${VERIFY_DIR}/ramdisk.cpio" \\
  || die "the recovery-console ramdisk changed during final repack"
''',
    'final ramdisk verification',
)

replace_once(
    '''note "Prepare the standard build artifacts"
cp "$KERNEL_IMAGE" "${ARTIFACT_DIR}/Image.gz"
''',
    '''note "Prepare the standard build artifacts"
cp "$RECOVERY_CONSOLE_BINARY" "${ARTIFACT_DIR}/recovery-console-aarch64"
cp "$KERNEL_IMAGE" "${ARTIFACT_DIR}/Image.gz"
''',
    'artifact copy anchor',
)

replace_once(
    "  printf 'ramdisk_lzma=enabled\\n'\n",
    "  printf 'ramdisk_lzma=enabled\\n'\n"
    f"  printf 'recovery_console_commit=%s\\n' '{console_commit}'\n"
    "  printf 'recovery_console_sha256=%s\\n' \"$RECOVERY_CONSOLE_SHA256\"\n"
    "  printf 'recovery_console_path=/system/bin/recovery-console\\n'\n"
    "  printf 'recovery_console_boot=init-service\\n'\n"
    "  printf 'overclock=disabled\\n'\n",
    'build-info recovery-console anchor',
)

replace_once(
    '''    recovery.img \\
    Image.gz \\
''',
    '''    recovery.img \\
    recovery-console-aarch64 \\
    Image.gz \\
''',
    'SHA256SUMS anchor',
)

out.write_text(text)
out.chmod(0o755)
PY

printf 'Recovery Console branch build\n'
printf 'Base recipe: scripts/build.sh + current lineage-15.1 kernel wrapper\n'
printf 'Recovery Console commit: %s\n' "$RECOVERY_CONSOLE_COMMIT"
printf 'Overclock: disabled / not used\n\n'

python3 "${ROOT_DIR}/scripts/run-current-kernel-builder.py" "$GENERATED_BUILDER"
