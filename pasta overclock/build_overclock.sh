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

check_size() {
  local expected="$1"
  local file="$2"
  local actual
  actual="$(stat -c '%s' "$file")"
  [[ "$actual" == "$expected" ]] || die "size mismatch for $file: expected $expected, got $actual"
}

read_u32_le() {
  od -An -tu4 -j "$2" -N4 "$1" | tr -d '[:space:]'
}

compare_range() {
  local original="$1"
  local rebuilt="$2"
  local offset="$3"
  local length="$4"
  local description="$5"

  cmp -s \
    <(dd if="$original" bs=1 skip="$offset" count="$length" status=none) \
    <(dd if="$rebuilt" bs=1 skip="$offset" count="$length" status=none) \
    || die "$description changed during repack"
}

clone_commit() {
  local repo="$1"
  local commit="$2"
  local destination="$3"

  git init --quiet "$destination"
  git -C "$destination" remote add origin "$repo"
  git -C "$destination" fetch --quiet --depth=1 origin "$commit"
  git -C "$destination" checkout --quiet --detach FETCH_HEAD
  [[ "$(git -C "$destination" rev-parse HEAD)" == "$commit" ]] \
    || die "failed to checkout $commit from $repo"
}

clone_tag() {
  local repo="$1"
  local tag="$2"
  local expected_tag_object="$3"
  local expected_commit="$4"
  local destination="$5"

  git -c advice.detachedHead=false clone --quiet --depth=1 --branch "$tag" "$repo" "$destination"
  [[ "$(git -C "$destination" rev-parse "refs/tags/$tag")" == "$expected_tag_object" ]] \
    || die "unexpected tag object for $repo tag $tag"
  [[ "$(git -C "$destination" rev-parse HEAD)" == "$expected_commit" ]] \
    || die "unexpected commit for $repo tag $tag"
}

readonly KERNEL_REPO="https://github.com/SaaSD3v/android_kernel_motorola_msm8996.git"
readonly KERNEL_COMMIT="516086ce0637a9e820793695a4dd8e3ff43e055b"

readonly TOOLCHAIN_TAG="android-8.1.0_r52"
readonly AARCH64_TOOLCHAIN_REPO="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9"
readonly AARCH64_TOOLCHAIN_TAG_OBJECT="01a44495e0d50ba06b0b43ebc94a00bdaa4240bb"
readonly AARCH64_TOOLCHAIN_COMMIT="7a28c220c2e9001825328dca6188ef0077a80a88"
readonly ARM_TOOLCHAIN_REPO="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9"
readonly ARM_TOOLCHAIN_TAG_OBJECT="8467f03d870283b5b494b9b0b52b3cb19eb8f2df"
readonly ARM_TOOLCHAIN_COMMIT="c348b64ea1e2015a576485aa787dc70dda9ef396"

readonly DTBTOOL_REPO="https://github.com/LineageOS/android_device_motorola_potter.git"
readonly DTBTOOL_COMMIT="ad60ebfd1f623cc55b962b98d5b57758124edb74"
readonly REFERENCE_DT_SHA256="7074cd910d736a09a402531d62c5601c7dbfb99be6345515c3a4d06d9e06f145"
readonly EXPECTED_DT_SIZE=1765376

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

note "=== BUILD OVERCLOCK: GPU=${GPU_MHZ} MHz, CPU=${CPU_MHZ} MHz ==="

note "Clone the pinned kernel and toolchains"
clone_commit "$KERNEL_REPO" "$KERNEL_COMMIT" "${WORK_DIR}/kernel"
clone_tag "$AARCH64_TOOLCHAIN_REPO" "$TOOLCHAIN_TAG" "$AARCH64_TOOLCHAIN_TAG_OBJECT" "$AARCH64_TOOLCHAIN_COMMIT" "${WORK_DIR}/aarch64-toolchain"
clone_tag "$ARM_TOOLCHAIN_REPO" "$TOOLCHAIN_TAG" "$ARM_TOOLCHAIN_TAG_OBJECT" "$ARM_TOOLCHAIN_COMMIT" "${WORK_DIR}/arm-toolchain"
clone_commit "$DTBTOOL_REPO" "$DTBTOOL_COMMIT" "${WORK_DIR}/dtbtool"

export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE="${WORK_DIR}/aarch64-toolchain/bin/aarch64-linux-android-"
export CROSS_COMPILE_ARM32="${WORK_DIR}/arm-toolchain/bin/arm-linux-androideabi-"
export PATH="${WORK_DIR}/aarch64-toolchain/bin:${WORK_DIR}/arm-toolchain/bin:${PATH}"

readonly MAKE_ARGS=(
  -C "${WORK_DIR}/kernel"
  "O=${WORK_DIR}/kernel-out"
  "ARCH=$ARCH"
  "SUBARCH=$SUBARCH"
  "CROSS_COMPILE=$CROSS_COMPILE"
  "CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32"
)

note "Configure kernel"
make "${MAKE_ARGS[@]}" albus_defconfig

readonly KERNEL_CONFIG="${WORK_DIR}/kernel-out/.config"
"${WORK_DIR}/kernel/scripts/config" --file "$KERNEL_CONFIG" --enable RD_LZMA
make "${MAKE_ARGS[@]}" olddefconfig

note "Build Image.gz and device trees"
make \
  --jobs="${JOBS:-$(nproc)}" \
  "${MAKE_ARGS[@]}" \
  KCFLAGS=-mno-android \
  Image.gz \
  dtbs

readonly KERNEL_IMAGE="${WORK_DIR}/kernel-out/arch/arm64/boot/Image.gz"
readonly VMLINUX="${WORK_DIR}/kernel-out/vmlinux"
[[ -s "$KERNEL_IMAGE" ]] || die "Image.gz was not produced"
[[ -s "$VMLINUX" ]] || die "vmlinux was not produced"

note "Build the Motorola QCDT v3 image"
cc \
  -O2 \
  -Wall \
  "${WORK_DIR}/dtbtool/dtbtool/dtbtool.c" \
  -o "${WORK_DIR}/tools/dtbTool_custom"

"${WORK_DIR}/tools/dtbTool_custom" \
  --force-v3 \
  --motorola 1 \
  -o "${WORK_DIR}/dt_orig.img" \
  -s 2048 \
  -p "${WORK_DIR}/kernel-out/scripts/dtc/" \
  "${WORK_DIR}/kernel-out/arch/arm64/boot/"

[[ "$(dd if="${WORK_DIR}/dt_orig.img" bs=1 count=4 status=none)" == "QCDT" ]] \
  || die "dt_orig.img does not contain the QCDT magic"
check_size "$EXPECTED_DT_SIZE" "${WORK_DIR}/dt_orig.img"

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

note "Download and verify the official recovery base"
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

note "Unpack the official recovery"
readonly REPACK_DIR="${WORK_DIR}/repack"
mkdir "$REPACK_DIR"
(
  cd "$REPACK_DIR"
  "$MAGISKBOOT" unpack -n "${WORK_DIR}/${TWRP_FILE}"
)

[[ -f "${REPACK_DIR}/kernel" ]] || die "magiskboot did not extract the base kernel"
[[ -f "${REPACK_DIR}/ramdisk.cpio" ]] || die "magiskboot did not extract the base ramdisk"
[[ -f "${REPACK_DIR}/extra" ]] || die "magiskboot did not extract the separated DT image"

note "=== PATCH DT.img WITH OVERCLOCK ==="
python3 "${OC_DIR}/overclock_dt.py" \
  "${WORK_DIR}/dt_orig.img" \
  "${WORK_DIR}/dt_oc.img" \
  --gpu-mhz "$GPU_MHZ" \
  --cpu-mhz "$CPU_MHZ"

[[ -s "${WORK_DIR}/dt_oc.img" ]] || die "Patched dt.img was not produced"

note "Repack recovery.img with overclocked DT"
cp "$KERNEL_IMAGE" "${REPACK_DIR}/kernel"
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

cmp -s "$KERNEL_IMAGE" "${VERIFY_DIR}/kernel" \
  || die "the repacked kernel differs from Image.gz"
cmp -s "${WORK_DIR}/dt_oc.img" "${VERIFY_DIR}/extra" \
  || die "the repacked DT differs from patched dt.img"
check_sha256 "$TWRP_RAMDISK_SHA256" "${VERIFY_DIR}/ramdisk.cpio"

compare_range "${WORK_DIR}/${TWRP_FILE}" "${ARTIFACT_DIR}/recovery.img" 12 4 "kernel address"
compare_range "${WORK_DIR}/${TWRP_FILE}" "${ARTIFACT_DIR}/recovery.img" 20 4 "ramdisk address"
compare_range "${WORK_DIR}/${TWRP_FILE}" "${ARTIFACT_DIR}/recovery.img" 24 4 "second-stage size"
compare_range "${WORK_DIR}/${TWRP_FILE}" "${ARTIFACT_DIR}/recovery.img" 28 4 "second-stage address"
compare_range "${WORK_DIR}/${TWRP_FILE}" "${ARTIFACT_DIR}/recovery.img" 32 4 "tags address"
compare_range "${WORK_DIR}/${TWRP_FILE}" "${ARTIFACT_DIR}/recovery.img" 36 4 "page size"
compare_range "${WORK_DIR}/${TWRP_FILE}" "${ARTIFACT_DIR}/recovery.img" 44 4 "legacy header flags"
compare_range "${WORK_DIR}/${TWRP_FILE}" "${ARTIFACT_DIR}/recovery.img" 48 16 "board name"
compare_range "${WORK_DIR}/${TWRP_FILE}" "${ARTIFACT_DIR}/recovery.img" 64 512 "kernel command line"
compare_range "${WORK_DIR}/${TWRP_FILE}" "${ARTIFACT_DIR}/recovery.img" 608 1024 "extra kernel command line"

KERNEL_SIZE="$(stat -c '%s' "$KERNEL_IMAGE")"
RAMDISK_SIZE="$(stat -c '%s' "${VERIFY_DIR}/ramdisk.cpio")"
OC_DT_SIZE="$(stat -c '%s' "${WORK_DIR}/dt_oc.img")"

[[ "$(read_u32_le "${ARTIFACT_DIR}/recovery.img" 8)" == "$KERNEL_SIZE" ]] \
  || die "kernel size in the boot header is incorrect"
[[ "$(read_u32_le "${ARTIFACT_DIR}/recovery.img" 16)" == "$RAMDISK_SIZE" ]] \
  || die "ramdisk size in the boot header is incorrect"
[[ "$(read_u32_le "${ARTIFACT_DIR}/recovery.img" 40)" == "$OC_DT_SIZE" ]] \
  || die "DT size in the boot header is incorrect"

FINAL_SIZE="$(stat -c '%s' "${ARTIFACT_DIR}/recovery.img")"
readonly FINAL_SIZE
(( FINAL_SIZE <= RECOVERY_PARTITION_SIZE )) \
  || die "recovery.img is ${FINAL_SIZE} bytes; partition limit is ${RECOVERY_PARTITION_SIZE}"

note "Prepare build artifacts"
cp "$KERNEL_IMAGE" "${ARTIFACT_DIR}/Image.gz"
cp "${WORK_DIR}/dt_oc.img" "${ARTIFACT_DIR}/dt.img"
cp "$KERNEL_CONFIG" "${ARTIFACT_DIR}/kernel.config"

FINAL_SHA256="$(sha256_of "${ARTIFACT_DIR}/recovery.img")"
readonly FINAL_SHA256
KERNEL_SHA256="$(sha256_of "$KERNEL_IMAGE")"
readonly KERNEL_SHA256
DT_SHA256="$(sha256_of "${WORK_DIR}/dt_oc.img")"
readonly DT_SHA256
CONFIG_SHA256="$(sha256_of "$KERNEL_CONFIG")"
readonly CONFIG_SHA256

{
  printf 'kernel_repository=%s\n' "$KERNEL_REPO"
  printf 'kernel_commit=%s\n' "$KERNEL_COMMIT"
  printf 'twrp_base=%s\n' "$TWRP_FILE"
  printf 'twrp_base_sha256=%s\n' "$TWRP_SHA256"
  printf 'recovery_size=%s\n' "$FINAL_SIZE"
  printf 'recovery_partition_limit=%s\n' "$RECOVERY_PARTITION_SIZE"
  printf 'recovery_sha256=%s\n' "$FINAL_SHA256"
  printf 'kernel_sha256=%s\n' "$KERNEL_SHA256"
  printf 'dt_sha256=%s\n' "$DT_SHA256"
  printf 'config_sha256=%s\n' "$CONFIG_SHA256"
  printf 'kernelsu=absent-from-source\n'
  printf 'ramdisk_lzma=enabled\n'
  printf 'overclock_gpu_mhz=%s\n' "$GPU_MHZ"
  printf 'overclock_cpu_mhz=%s\n' "$CPU_MHZ"
} > "${ARTIFACT_DIR}/build-info.txt"

(
  cd "$ARTIFACT_DIR"
  sha256sum \
    recovery.img \
    Image.gz \
    dt.img \
    kernel.config \
    build-info.txt \
    > SHA256SUMS
)

note "=== OVERCLOCK BUILD COMPLETE ==="
printf 'recovery.img: %s bytes\n' "$FINAL_SIZE"
printf 'SHA-256: %s\n' "$FINAL_SHA256"
printf 'GPU: %s MHz (stock: 650)\n' "$GPU_MHZ"
printf 'CPU: %s MHz (stock: 2208)\n' "$CPU_MHZ"
