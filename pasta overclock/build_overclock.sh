#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ARTIFACT_DIR="${ROOT_DIR}/artifacts"
readonly OC_DIR="${ROOT_DIR}/pasta overclock"

# Default overclock values - override with env vars
readonly GPU_MHZ="${GPU_MHZ:-700}"
readonly CPU_MHZ="${CPU_MHZ:-2300}"

note() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

sha256_of() {
  local value _
  read -r value _ < <(sha256sum "$1")
  printf '%s' "$value"
}

check_sha256() {
  local expected="$1"
  local file="$2"
  local actual
  actual="$(sha256_of "$file")"
  [[ "$actual" == "$expected" ]] || die "SHA-256 mismatch for $file: expected $expected, got $actual"
}

readonly TWRP_FILE="twrp-3.5.0_9-0-albus.img"
readonly TWRP_PAGE="https://dl.twrp.me/albus/${TWRP_FILE}.html"
readonly TWRP_URL="https://dl.twrp.me/albus/${TWRP_FILE}"
readonly TWRP_SHA256="4c42bfee165ea99e2663284a3634135786e157bd6cc492fcbe0d9bd3430e9261"
readonly TWRP_SIZE=18933760
readonly TWRP_KERNEL_SHA256="2c17c2ab3e7e614b4acdc65b8fba612aba81ca4d3b6d662b42522aa525844a6d"
readonly TWRP_RAMDISK_SHA256="400d33b3a5ef212287bcd1f1cb8327edb76ae5b1cca73e592ea6b7d73fee32ea"
readonly TWRP_DT_SHA256="f7ebb32c62805a0e2e58e0ff7bf6f0f13085dd85b0a86a623e951426ac63d15b"

readonly MAGISK_VERSION="30.7"
readonly MAGISK_URL="https://github.com/topjohnwu/Magisk/releases/download/v${MAGISK_VERSION}/Magisk-v${MAGISK_VERSION}.apk"
readonly MAGISK_APK_SHA256="e0d32d2123532860f97123d927b1bb86c4e08e6fd8a48bfc6b5bee0afae9ebd5"
readonly MAGISKBOOT_SHA256="a18ecbd7981179494b7d281453d6c4e25b5c719e7d2ef7f6eba3c6be3043c58e"

readonly RECOVERY_PARTITION_SIZE=21073920

TEMP_ROOT="${RUNNER_TEMP:-/tmp}"
WORK_DIR="$(mktemp -d "${TEMP_ROOT}/albus-overclock.XXXXXX")"
readonly WORK_DIR

mkdir -p "$ARTIFACT_DIR"
mkdir -p "$WORK_DIR/tools"

note "=== OVERCLOCK RECOVERY: GPU=${GPU_MHZ} MHz, CPU=${CPU_MHZ} MHz ==="

note "Download and verify magiskboot"
readonly MAGISK_APK="${WORK_DIR}/Magisk-v${MAGISK_VERSION}.apk"
readonly MAGISKBOOT="${WORK_DIR}/tools/magiskboot"
curl \
  --fail \
  --location \
  --retry 5 \
  --retry-all-errors \
  --connect-timeout 30 \
  "$MAGISK_URL" \
  --output "$MAGISK_APK"
check_sha256 "$MAGISK_APK_SHA256" "$MAGISK_APK"
unzip -p "$MAGISK_APK" lib/x86_64/libmagiskboot.so > "$MAGISKBOOT"
check_sha256 "$MAGISKBOOT_SHA256" "$MAGISKBOOT"
chmod 0755 "$MAGISKBOOT"

note "Download and verify the official TWRP recovery"
curl \
  --fail \
  --location \
  --retry 5 \
  --retry-all-errors \
  --connect-timeout 30 \
  --user-agent "Mozilla/5.0" \
  --referer "$TWRP_PAGE" \
  "$TWRP_URL" \
  --output "${WORK_DIR}/${TWRP_FILE}"
check_sha256 "$TWRP_SHA256" "${WORK_DIR}/${TWRP_FILE}"
check_size "$TWRP_SIZE" "${WORK_DIR}/${TWRP_FILE}"

note "Unpack the official TWRP recovery"
readonly REPACK_DIR="${WORK_DIR}/repack"
mkdir "$REPACK_DIR"
(
  cd "$REPACK_DIR"
  "$MAGISKBOOT" unpack -n "${WORK_DIR}/${TWRP_FILE}"
)

[[ -f "${REPACK_DIR}/kernel" ]] || die "magiskboot did not extract the kernel"
[[ -f "${REPACK_DIR}/ramdisk.cpio" ]] || die "magiskboot did not extract the ramdisk"
[[ -f "${REPACK_DIR}/extra" ]] || die "magiskboot did not extract the DT (extra)"

check_sha256 "$TWRP_KERNEL_SHA256" "${REPACK_DIR}/kernel"
check_sha256 "$TWRP_RAMDISK_SHA256" "${REPACK_DIR}/ramdisk.cpio"
check_sha256 "$TWRP_DT_SHA256" "${REPACK_DIR}/extra"

note "=== PATCH DT WITH OVERCLOCK ==="
note "GPU: 650 MHz -> ${GPU_MHZ} MHz"
note "CPU: 2208 MHz -> ${CPU_MHZ} MHz"

python3 "${OC_DIR}/overclock_dt.py" \
  "${REPACK_DIR}/extra" \
  "${WORK_DIR}/dt_oc.img" \
  --gpu-mhz "$GPU_MHZ" \
  --cpu-mhz "$CPU_MHZ"

[[ -s "${WORK_DIR}/dt_oc.img" ]] || die "Patched DT was not produced"

note "Repack recovery.img with overclocked DT"
cp "${WORK_DIR}/dt_oc.img" "${REPACK_DIR}/extra"

(
  cd "$REPACK_DIR"
  "$MAGISKBOOT" repack -n "${WORK_DIR}/${TWRP_FILE}" "${ARTIFACT_DIR}/recovery.img"
)
[[ -s "${ARTIFACT_DIR}/recovery.img" ]] || die "recovery.img was not produced"

note "Verify the repacked recovery"
readonly VERIFY_DIR="${WORK_DIR}/verify"
mkdir "$VERIFY_DIR"
(
  cd "$VERIFY_DIR"
  "$MAGISKBOOT" unpack -n "${ARTIFACT_DIR}/recovery.img"
)

cmp -s "${REPACK_DIR}/kernel" "${VERIFY_DIR}/kernel" \
  || die "kernel was modified during repack"
cmp -s "${WORK_DIR}/dt_oc.img" "${VERIFY_DIR}/extra" \
  || die "DT was modified during repack"
check_sha256 "$TWRP_RAMDISK_SHA256" "${VERIFY_DIR}/ramdisk.cpio"

FINAL_SIZE="$(stat -c '%s' "${ARTIFACT_DIR}/recovery.img")"
readonly FINAL_SIZE
(( FINAL_SIZE <= RECOVERY_PARTITION_SIZE )) \
  || die "recovery.img is ${FINAL_SIZE} bytes; partition limit is ${RECOVERY_PARTITION_SIZE}"

note "Prepare build artifacts"
cp "${REPACK_DIR}/kernel" "${ARTIFACT_DIR}/Image.gz"
cp "${WORK_DIR}/dt_oc.img" "${ARTIFACT_DIR}/dt.img"

FINAL_SHA256="$(sha256_of "${ARTIFACT_DIR}/recovery.img")"
readonly FINAL_SHA256
KERNEL_SHA256="$(sha256_of "${REPACK_DIR}/kernel")"
DT_SHA256="$(sha256_of "${WORK_DIR}/dt_oc.img")"

{
  printf 'twrp_base=%s\n' "$TWRP_FILE"
  printf 'twrp_base_sha256=%s\n' "$TWRP_SHA256"
  printf 'recovery_size=%s\n' "$FINAL_SIZE"
  printf 'recovery_partition_limit=%s\n' "$RECOVERY_PARTITION_SIZE"
  printf 'recovery_sha256=%s\n' "$FINAL_SHA256"
  printf 'kernel_sha256=%s\n' "$KERNEL_SHA256"
  printf 'dt_sha256=%s\n' "$DT_SHA256"
  printf 'overclock_gpu_mhz=%s\n' "$GPU_MHZ"
  printf 'overclock_cpu_mhz=%s\n' "$CPU_MHZ"
} > "${ARTIFACT_DIR}/build-info.txt"

(
  cd "$ARTIFACT_DIR"
  sha256sum \
    recovery.img \
    Image.gz \
    dt.img \
    build-info.txt \
    > SHA256SUMS
)

note "=== OVERCLOCK BUILD COMPLETE ==="
printf 'recovery.img: %s bytes\n' "$FINAL_SIZE"
printf 'SHA-256: %s\n' "$FINAL_SHA256"
printf 'GPU: %s MHz (stock: 650)\n' "$GPU_MHZ"
printf 'CPU: %s MHz (stock: 2208)\n' "$CPU_MHZ"
