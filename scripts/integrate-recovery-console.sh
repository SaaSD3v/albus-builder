#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 5 ]] || {
  echo "usage: $0 <ramdisk.cpio> <magiskboot> <Magisk.apk> <work-dir> <output-binary>" >&2
  exit 2
}

readonly RAMDISK_CPIO="$1"
readonly MAGISKBOOT="$2"
readonly MAGISK_APK="$3"
readonly WORK_DIR="$4"
readonly OUTPUT_BINARY="$5"

readonly RECOVERY_CONSOLE_REPO="https://github.com/SaaSD3v/recovery-console.git"
readonly RECOVERY_CONSOLE_COMMIT="0be3707df843664cbb69323c954c34c1d41ed7c3"
readonly MUSL_ARCHIVE="aarch64-linux-musl-cross.tar.gz"
readonly MUSL_URL="https://github.com/ravindu644/Droidspaces-OSS/releases/download/compilers/${MUSL_ARCHIVE}"
readonly MUSL_SHA256="a1d74ccae5b7ee7c42bcbdf46c7da34c81514380f05c5ddef93d37a6ec5f3a31"

note() {
  printf '\n==> [recovery-console] %s\n' "$*"
}

die() {
  printf 'error: [recovery-console] %s\n' "$*" >&2
  exit 1
}

sha256_of() {
  local value _
  read -r value _ < <(sha256sum "$1")
  printf '%s' "$value"
}

[[ -f "$RAMDISK_CPIO" ]] || die "ramdisk not found: $RAMDISK_CPIO"
[[ -x "$MAGISKBOOT" ]] || die "magiskboot is not executable: $MAGISKBOOT"
[[ -f "$MAGISK_APK" ]] || die "Magisk APK not found: $MAGISK_APK"

readonly RC_DIR="${WORK_DIR}/recovery-console-src"
readonly RC_HOME="${WORK_DIR}/recovery-console-home"
readonly RC_TOOLCHAIN_ARCHIVE="${WORK_DIR}/${MUSL_ARCHIVE}"
readonly RC_PATCH_DIR="${WORK_DIR}/recovery-console-ramdisk"
readonly RC_VERIFY_DIR="${WORK_DIR}/recovery-console-verify"
readonly RAMDISK_RAW="${WORK_DIR}/ramdisk.recovery-console.raw.cpio"
readonly RAMDISK_RECOMPRESSED="${WORK_DIR}/ramdisk.recovery-console.lzma"
readonly RAMDISK_ROUNDTRIP="${WORK_DIR}/ramdisk.recovery-console.roundtrip.cpio"
readonly MAGISKPOLICY="${WORK_DIR}/magiskpolicy"

note "Clone pinned recovery-console source"
git init --quiet "$RC_DIR"
git -C "$RC_DIR" remote add origin "$RECOVERY_CONSOLE_REPO"
git -C "$RC_DIR" fetch --quiet --depth=1 origin "$RECOVERY_CONSOLE_COMMIT"
git -C "$RC_DIR" checkout --quiet --detach FETCH_HEAD
[[ "$(git -C "$RC_DIR" rev-parse HEAD)" == "$RECOVERY_CONSOLE_COMMIT" ]] \
  || die "failed to checkout pinned recovery-console commit"

note "Apply an Albus/TWRP-only device profile"
python3 - "$RC_DIR/include/config.h" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

replacements = [
    (r'(#define MARGIN_TOP\s+)\d+', r'\g<1>10'),
    (r'(#define MARGIN_BOTTOM\s+)\d+', r'\g<1>10'),
    (r'(#define MARGIN_LEFT\s+)\d+', r'\g<1>10'),
    (r'(#define MARGIN_RIGHT\s+)\d+', r'\g<1>10'),
    (r'(#define ROTATION\s+)\d+', r'\g<1>0'),
    (r'(#define COLOR_BGR\s+)\d+', r'\g<1>0'),
    (r'(#define USE_SHADOW_BUFFER\s+)\d+', r'\g<1>0'),
    (r'(#define USE_CRTC_BLANK\s+)\d+', r'\g<1>0'),
    (r'(#define DEFAULT_SHELL\s+)"[^"]+"', r'\g<1>"/sbin/sh"'),
    (r'#define BACKLIGHT_PATH\s+\\\n\s+"[^"]+"', '#define BACKLIGHT_PATH \\\n  "/sys/class/leds/lcd-backlight/brightness"'),
]

for pattern, replacement in replacements:
    text, count = re.subn(pattern, replacement, text, count=1)
    if count != 1:
        raise SystemExit(f"config.h: expected one match for {pattern!r}, got {count}")

path.write_text(text)
PY

grep -Fqx '#define DEFAULT_SHELL "/sbin/sh"' "$RC_DIR/include/config.h" \
  || die "Albus shell profile was not applied"
grep -Fq '"/sys/class/leds/lcd-backlight/brightness"' "$RC_DIR/include/config.h" \
  || die "Albus backlight profile was not applied"
grep -Fqx '#define USE_SHADOW_BUFFER 0' "$RC_DIR/include/config.h" \
  || die "AMOLED shadow-buffer profile was not applied"

note "Download and verify the pinned AArch64 musl toolchain"
curl \
  --fail \
  --location \
  --retry 5 \
  --retry-all-errors \
  --connect-timeout 30 \
  "$MUSL_URL" \
  --output "$RC_TOOLCHAIN_ARCHIVE"
[[ "$(sha256_of "$RC_TOOLCHAIN_ARCHIVE")" == "$MUSL_SHA256" ]] \
  || die "AArch64 musl toolchain SHA-256 mismatch"

mkdir -p "$RC_HOME/toolchains"
tar -xzf "$RC_TOOLCHAIN_ARCHIVE" -C "$RC_HOME/toolchains"
[[ -x "$RC_HOME/toolchains/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc" ]] \
  || die "AArch64 musl compiler was not extracted"

note "Build a static AArch64 recovery-console"
HOME="$RC_HOME" make -C "$RC_DIR" clean
HOME="$RC_HOME" make -C "$RC_DIR" aarch64
readonly BUILT_BINARY="$RC_DIR/output/recovery-console-aarch64"
[[ -s "$BUILT_BINARY" ]] || die "recovery-console AArch64 binary was not produced"
file "$BUILT_BINARY" | grep -Eq 'ELF 64-bit.*(ARM aarch64|AArch64)' \
  || die "recovery-console is not an AArch64 ELF"
if readelf -l "$BUILT_BINARY" | grep -q 'Requesting program interpreter'; then
  die "recovery-console is dynamically linked; a static recovery binary is required"
fi
install -m 0755 "$BUILT_BINARY" "$OUTPUT_BINARY"

note "Decompress the preserved LZMA TWRP ramdisk before CPIO patching"
rm -f "$RAMDISK_RAW" "$RAMDISK_RECOMPRESSED" "$RAMDISK_ROUNDTRIP"
"$MAGISKBOOT" decompress "$RAMDISK_CPIO" "$RAMDISK_RAW"
[[ -s "$RAMDISK_RAW" ]] || die "magiskboot did not decompress the TWRP ramdisk"

note "Extract the TWRP ramdisk for deterministic init.rc patching"
rm -rf "$RC_PATCH_DIR" "$RC_VERIFY_DIR"
mkdir -p "$RC_PATCH_DIR" "$RC_VERIFY_DIR"
(
  cd "$RC_PATCH_DIR"
  "$MAGISKBOOT" cpio "$RAMDISK_RAW" "extract"
)

python3 - "$RC_PATCH_DIR" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
service_re = re.compile(r'^service[ \t]+recovery[ \t]+\S+.*$')
matched = []
modified = []

for path in sorted(root.rglob('*.rc')):
    try:
        lines = path.read_text().splitlines()
    except UnicodeDecodeError:
        continue

    changed = False
    i = 0
    while i < len(lines):
        if not service_re.match(lines[i]):
            i += 1
            continue
        matched.append(path)
        j = i + 1
        while j < len(lines):
            line = lines[j]
            if line and not line[0].isspace() and not line.lstrip().startswith('#'):
                break
            j += 1
        block = lines[i:j]
        if not any(x.strip() == 'disabled' for x in block):
            lines.insert(j, '    disabled')
            changed = True
            j += 1
        i = j

    if changed:
        path.write_text('\n'.join(lines) + '\n')
        modified.append(path)

if not matched:
    raise SystemExit('no Android init service named recovery was found in the TWRP ramdisk')

host = matched[0]
text = host.read_text()
if 'service recovery-console /system/bin/recovery-console' not in text:
    with host.open('a') as f:
        if text and not text.endswith('\n'):
            f.write('\n')
        f.write('''\n# Recovery Console permanent integration\nservice recovery-console /system/bin/recovery-console\n    user root\n    group root\n    oneshot\n    disabled\n    seclabel u:r:recovery:s0\n\non boot\n    start recovery-console\n''')
    if host not in modified:
        modified.append(host)

list_file = root / '.recovery-console-modified-rc'
list_file.write_text('\n'.join(str(p.relative_to(root)) for p in modified) + '\n')
PY

[[ -s "$RC_PATCH_DIR/.recovery-console-modified-rc" ]] \
  || die "no init rc file was patched"

note "Patch recovery SELinux policy when a ramdisk sepolicy is present"
POLICY_PATCHED=0
if [[ -f "$RC_PATCH_DIR/sepolicy" ]]; then
  unzip -p "$MAGISK_APK" lib/x86_64/libmagiskpolicy.so > "$MAGISKPOLICY"
  chmod 0755 "$MAGISKPOLICY"
  [[ -s "$MAGISKPOLICY" ]] || die "magiskpolicy could not be extracted"

  "$MAGISKPOLICY" \
    --load "$RC_PATCH_DIR/sepolicy" \
    --save "$RC_PATCH_DIR/sepolicy.patched" \
    $'allow adbd adbd process setcurrent\nallow adbd su process dyntransition\npermissive { adbd }\npermissive { su }\npermissive { recovery }'
  [[ -s "$RC_PATCH_DIR/sepolicy.patched" ]] || die "magiskpolicy did not produce a patched policy"
  mv "$RC_PATCH_DIR/sepolicy.patched" "$RC_PATCH_DIR/sepolicy"
  POLICY_PATCHED=1
fi

note "Inject recovery-console and the patched init configuration into raw ramdisk CPIO"
CPIO_COMMANDS=()
if [[ ! -e "$RC_PATCH_DIR/system" ]]; then
  CPIO_COMMANDS+=("mkdir 0755 system")
elif [[ ! -d "$RC_PATCH_DIR/system" ]]; then
  die "ramdisk /system exists but is not a directory"
fi
if [[ ! -e "$RC_PATCH_DIR/system/bin" ]]; then
  CPIO_COMMANDS+=("mkdir 0755 system/bin")
elif [[ ! -d "$RC_PATCH_DIR/system/bin" ]]; then
  die "ramdisk /system/bin exists but is not a directory"
fi
if [[ -e "$RC_PATCH_DIR/system/bin/recovery-console" ]]; then
  CPIO_COMMANDS+=("rm system/bin/recovery-console")
fi
CPIO_COMMANDS+=("add 0755 system/bin/recovery-console $OUTPUT_BINARY")

while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  mode="$(stat -c '%a' "$RC_PATCH_DIR/$rel")"
  CPIO_COMMANDS+=("rm $rel")
  CPIO_COMMANDS+=("add 0${mode} $rel $RC_PATCH_DIR/$rel")
done < "$RC_PATCH_DIR/.recovery-console-modified-rc"

if [[ "$POLICY_PATCHED" -eq 1 ]]; then
  mode="$(stat -c '%a' "$RC_PATCH_DIR/sepolicy")"
  CPIO_COMMANDS+=("rm sepolicy")
  CPIO_COMMANDS+=("add 0${mode} sepolicy $RC_PATCH_DIR/sepolicy")
fi

"$MAGISKBOOT" cpio "$RAMDISK_RAW" "${CPIO_COMMANDS[@]}"

note "Verify the modified raw ramdisk contents"
(
  cd "$RC_VERIFY_DIR"
  "$MAGISKBOOT" cpio "$RAMDISK_RAW" "extract"
)
[[ -x "$RC_VERIFY_DIR/system/bin/recovery-console" ]] \
  || die "recovery-console is missing or not executable in the final ramdisk"
cmp -s "$OUTPUT_BINARY" "$RC_VERIFY_DIR/system/bin/recovery-console" \
  || die "recovery-console changed while being added to the ramdisk"

grep -R -q '^service recovery-console /system/bin/recovery-console$' "$RC_VERIFY_DIR" --include='*.rc' \
  || die "recovery-console init service is missing"
grep -R -q '^[[:space:]]*start recovery-console$' "$RC_VERIFY_DIR" --include='*.rc' \
  || die "recovery-console boot trigger is missing"

python3 - "$RC_VERIFY_DIR" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
service_re = re.compile(r'^service[ \t]+recovery[ \t]+\S+.*$')
found = 0
for path in root.rglob('*.rc'):
    try:
        lines = path.read_text().splitlines()
    except UnicodeDecodeError:
        continue
    for i, line in enumerate(lines):
        if not service_re.match(line):
            continue
        found += 1
        j = i + 1
        block = []
        while j < len(lines):
            nxt = lines[j]
            if nxt and not nxt[0].isspace() and not nxt.lstrip().startswith('#'):
                break
            block.append(nxt)
            j += 1
        if not any(x.strip() == 'disabled' for x in block):
            raise SystemExit(f'{path}: stock recovery service is not disabled')
if not found:
    raise SystemExit('stock recovery service disappeared during verification')
PY

note "Recompress the patched ramdisk to the original LZMA format"
"$MAGISKBOOT" compress=lzma "$RAMDISK_RAW" "$RAMDISK_RECOMPRESSED"
[[ -s "$RAMDISK_RECOMPRESSED" ]] || die "magiskboot did not recompress the patched ramdisk"
"$MAGISKBOOT" decompress "$RAMDISK_RECOMPRESSED" "$RAMDISK_ROUNDTRIP"
cmp -s "$RAMDISK_RAW" "$RAMDISK_ROUNDTRIP" \
  || die "LZMA ramdisk recompression failed round-trip verification"
mv "$RAMDISK_RECOMPRESSED" "$RAMDISK_CPIO"

printf 'recovery-console commit: %s\n' "$RECOVERY_CONSOLE_COMMIT"
printf 'recovery-console sha256: %s\n' "$(sha256_of "$OUTPUT_BINARY")"
printf 'ramdisk compression: lzma (preserved)\n'
printf 'SELinux recovery policy patched: %s\n' "$POLICY_PATCHED"
