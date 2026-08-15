#!/usr/bin/env bash
set -Eeuo pipefail

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

require_config() {
  local expected_line="$1"
  grep -Fqx "$expected_line" "$KERNEL_CONFIG" \
    || die "required kernel configuration is missing: $expected_line"
}

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly TEMP_ROOT="${RUNNER_TEMP:-/tmp}"
WORK_DIR="$(mktemp -d "${TEMP_ROOT}/albus-recovery.XXXXXX")"
readonly WORK_DIR
readonly ARTIFACT_DIR="${ROOT_DIR}/artifacts"
readonly KERNEL_DIR="${WORK_DIR}/kernel"
readonly KERNEL_OUT="${WORK_DIR}/kernel-out"
readonly AARCH64_TOOLCHAIN_DIR="${WORK_DIR}/aarch64-toolchain"
readonly ARM_TOOLCHAIN_DIR="${WORK_DIR}/arm-toolchain"
readonly DTBTOOL_DIR="${WORK_DIR}/dtbtool"
readonly TOOLS_DIR="${WORK_DIR}/tools"
readonly BASE_IMAGE="${WORK_DIR}/${TWRP_FILE}"
readonly DT_IMAGE="${WORK_DIR}/dt.img"
readonly FINAL_IMAGE="${ARTIFACT_DIR}/recovery.img"

mkdir -p "$ARTIFACT_DIR" "$TOOLS_DIR"
rm -f \
  "$ARTIFACT_DIR/recovery.img" \
  "$ARTIFACT_DIR/Image.gz" \
  "$ARTIFACT_DIR/dt.img" \
  "$ARTIFACT_DIR/kernel.config" \
  "$ARTIFACT_DIR/build-info.txt" \
  "$ARTIFACT_DIR/SHA256SUMS"

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
  --output "$BASE_IMAGE"
check_sha256 "$TWRP_SHA256" "$BASE_IMAGE"
check_size "$TWRP_SIZE" "$BASE_IMAGE"
[[ "$(dd if="$BASE_IMAGE" bs=1 count=8 status=none)" == "ANDROID!" ]] \
  || die "the recovery base is not an Android boot image"

note "Clone the pinned kernel and toolchains"
clone_commit "$KERNEL_REPO" "$KERNEL_COMMIT" "$KERNEL_DIR"
[[ ! -e "${KERNEL_DIR}/drivers/kernelsu" ]] \
  || die "the pinned kernel source unexpectedly contains KernelSU"
if grep -Fq 'drivers/kernelsu/Kconfig' "${KERNEL_DIR}/drivers/Kconfig" \
  || grep -Eq 'CONFIG_KSU|kernelsu/' "${KERNEL_DIR}/drivers/Makefile"; then
  die "the pinned kernel source contains KernelSU integration hooks"
fi
clone_tag "$AARCH64_TOOLCHAIN_REPO" "$TOOLCHAIN_TAG" "$AARCH64_TOOLCHAIN_TAG_OBJECT" "$AARCH64_TOOLCHAIN_COMMIT" "$AARCH64_TOOLCHAIN_DIR"
clone_tag "$ARM_TOOLCHAIN_REPO" "$TOOLCHAIN_TAG" "$ARM_TOOLCHAIN_TAG_OBJECT" "$ARM_TOOLCHAIN_COMMIT" "$ARM_TOOLCHAIN_DIR"
clone_commit "$DTBTOOL_REPO" "$DTBTOOL_COMMIT" "$DTBTOOL_DIR"

export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE="${AARCH64_TOOLCHAIN_DIR}/bin/aarch64-linux-android-"
export CROSS_COMPILE_ARM32="${ARM_TOOLCHAIN_DIR}/bin/arm-linux-androideabi-"
export PATH="${AARCH64_TOOLCHAIN_DIR}/bin:${ARM_TOOLCHAIN_DIR}/bin:${PATH}"

python --version
"${CROSS_COMPILE}gcc" --version
"${CROSS_COMPILE_ARM32}gcc" --version
"${CROSS_COMPILE}gcc" -E -mno-android -x c /dev/null -o /dev/null \
  || die "the ARM64 compiler does not support -mno-android"

readonly -a MAKE_ARGS=(
  -C "$KERNEL_DIR"
  "O=$KERNEL_OUT"
  "ARCH=$ARCH"
  "SUBARCH=$SUBARCH"
  "CROSS_COMPILE=$CROSS_COMPILE"
  "CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32"
)

note "Configure the bare kernel for recovery (no DroidSpaces flags)"
make "${MAKE_ARGS[@]}" albus_defconfig
readonly KERNEL_CONFIG="${KERNEL_OUT}/.config"
readonly CONFIG_BEFORE_OVERRIDES="${WORK_DIR}/config-before-overrides"
cp "$KERNEL_CONFIG" "$CONFIG_BEFORE_OVERRIDES"

"${KERNEL_DIR}/scripts/config" --file "$KERNEL_CONFIG" --enable RD_LZMA
make "${MAKE_ARGS[@]}" olddefconfig

diff -u \
  <(grep -vE '^(# )?CONFIG_(RD_LZMA|DECOMPRESS_LZMA)([= ]|$)' "$CONFIG_BEFORE_OVERRIDES") \
  <(grep -vE '^(# )?CONFIG_(RD_LZMA|DECOMPRESS_LZMA)([= ]|$)' "$KERNEL_CONFIG") \
  || die "an unexpected kernel configuration changed"

if grep -Eq '^(# )?CONFIG_KSU([_= ]|$)' "$KERNEL_CONFIG"; then
  die "KernelSU configuration symbols unexpectedly exist"
fi
require_config 'CONFIG_RD_LZMA=y'
require_config 'CONFIG_DECOMPRESS_LZMA=y'

note "Build Image.gz and device trees"
make \
  --jobs="${JOBS:-$(nproc)}" \
  "${MAKE_ARGS[@]}" \
  KCFLAGS=-mno-android \
  Image.gz \
  dtbs

readonly KERNEL_IMAGE="${KERNEL_OUT}/arch/arm64/boot/Image.gz"
readonly VMLINUX="${KERNEL_OUT}/vmlinux"
[[ -s "$KERNEL_IMAGE" ]] || die "Image.gz was not produced"
[[ -s "$VMLINUX" ]] || die "vmlinux was not produced"
gzip --test "$KERNEL_IMAGE"
[[ ! -e "${KERNEL_OUT}/drivers/kernelsu/ksu.o" ]] \
  || die "KernelSU object was compiled"

"${CROSS_COMPILE}nm" "$VMLINUX" > "${WORK_DIR}/vmlinux.nm"
if grep -Eiq '(^|[[:space:]])ksu_[[:alnum:]_]*$' "${WORK_DIR}/vmlinux.nm"; then
  die "KernelSU symbols were linked into vmlinux"
fi

note "Build the Motorola QCDT v3 image"
cc \
  -O2 \
  -Wall \
  "${DTBTOOL_DIR}/dtbtool/dtbtool.c" \
  -o "${TOOLS_DIR}/dtbTool_custom"

"${TOOLS_DIR}/dtbTool_custom" \
  --force-v3 \
  --motorola 1 \
  -o "$DT_IMAGE" \
  -s 2048 \
  -p "${KERNEL_OUT}/scripts/dtc/" \
  "${KERNEL_OUT}/arch/arm64/boot/"

[[ "$(dd if="$DT_IMAGE" bs=1 count=4 status=none)" == "QCDT" ]] \
  || die "dt.img does not contain the QCDT magic"
[[ "$(read_u32_le "$DT_IMAGE" 4)" == "259" ]] \
  || die "dt.img is not Motorola QCDT v3"
[[ "$(read_u32_le "$DT_IMAGE" 8)" == "7" ]] \
  || die "dt.img does not contain the expected seven entries"
check_size "$EXPECTED_DT_SIZE" "$DT_IMAGE"
check_sha256 "$REFERENCE_DT_SHA256" "$DT_IMAGE"

DT_SHA256="$(sha256_of "$DT_IMAGE")"
readonly DT_SHA256

note "Download and verify magiskboot"
readonly MAGISK_APK="${WORK_DIR}/Magisk-v${MAGISK_VERSION}.apk"
readonly MAGISKBOOT="${TOOLS_DIR}/magiskboot"
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

note "Unpack the official recovery without changing compression"
readonly REPACK_DIR="${WORK_DIR}/repack"
mkdir "$REPACK_DIR"
(
  cd "$REPACK_DIR"
  "$MAGISKBOOT" unpack -n "$BASE_IMAGE"
)

[[ -f "${REPACK_DIR}/kernel" ]] || die "magiskboot did not extract the base kernel"
[[ -f "${REPACK_DIR}/ramdisk.cpio" ]] || die "magiskboot did not extract the base ramdisk"
[[ -f "${REPACK_DIR}/extra" ]] || die "magiskboot did not extract the separated DT image"
check_sha256 "$TWRP_KERNEL_SHA256" "${REPACK_DIR}/kernel"
check_sha256 "$TWRP_RAMDISK_SHA256" "${REPACK_DIR}/ramdisk.cpio"
check_sha256 "$TWRP_DT_SHA256" "${REPACK_DIR}/extra"

cp "$KERNEL_IMAGE" "${REPACK_DIR}/kernel"
cp "$DT_IMAGE" "${REPACK_DIR}/extra"

note "Repack recovery.img with the new kernel and matching DT"
(
  cd "$REPACK_DIR"
  "$MAGISKBOOT" repack -n "$BASE_IMAGE" "$FINAL_IMAGE"
)
[[ -s "$FINAL_IMAGE" ]] || die "recovery.img was not produced"

note "Verify every component of recovery.img"
readonly VERIFY_DIR="${WORK_DIR}/verify"
mkdir "$VERIFY_DIR"
(
  cd "$VERIFY_DIR"
  "$MAGISKBOOT" unpack -n "$FINAL_IMAGE"
)

cmp -s "$KERNEL_IMAGE" "${VERIFY_DIR}/kernel" \
  || die "the repacked kernel differs from Image.gz"
cmp -s "$DT_IMAGE" "${VERIFY_DIR}/extra" \
  || die "the repacked DT differs from dt.img"
check_sha256 "$TWRP_RAMDISK_SHA256" "${VERIFY_DIR}/ramdisk.cpio"

compare_range "$BASE_IMAGE" "$FINAL_IMAGE" 12 4 "kernel address"
compare_range "$BASE_IMAGE" "$FINAL_IMAGE" 20 4 "ramdisk address"
compare_range "$BASE_IMAGE" "$FINAL_IMAGE" 24 4 "second-stage size"
compare_range "$BASE_IMAGE" "$FINAL_IMAGE" 28 4 "second-stage address"
compare_range "$BASE_IMAGE" "$FINAL_IMAGE" 32 4 "tags address"
compare_range "$BASE_IMAGE" "$FINAL_IMAGE" 36 4 "page size"
compare_range "$BASE_IMAGE" "$FINAL_IMAGE" 44 4 "legacy header flags"
compare_range "$BASE_IMAGE" "$FINAL_IMAGE" 48 16 "board name"
compare_range "$BASE_IMAGE" "$FINAL_IMAGE" 64 512 "kernel command line"
compare_range "$BASE_IMAGE" "$FINAL_IMAGE" 608 1024 "extra kernel command line"

KERNEL_SIZE="$(stat -c '%s' "$KERNEL_IMAGE")"
readonly KERNEL_SIZE
RAMDISK_SIZE="$(stat -c '%s' "${VERIFY_DIR}/ramdisk.cpio")"
readonly RAMDISK_SIZE
FINAL_DT_SIZE="$(stat -c '%s' "$DT_IMAGE")"
readonly FINAL_DT_SIZE
[[ "$(read_u32_le "$FINAL_IMAGE" 8)" == "$KERNEL_SIZE" ]] \
  || die "kernel size in the boot header is incorrect"
[[ "$(read_u32_le "$FINAL_IMAGE" 16)" == "$RAMDISK_SIZE" ]] \
  || die "ramdisk size in the boot header is incorrect"
[[ "$(read_u32_le "$FINAL_IMAGE" 40)" == "$FINAL_DT_SIZE" ]] \
  || die "DT size in the boot header is incorrect"

FINAL_SIZE="$(stat -c '%s' "$FINAL_IMAGE")"
readonly FINAL_SIZE
(( FINAL_SIZE <= RECOVERY_PARTITION_SIZE )) \
  || die "recovery.img is ${FINAL_SIZE} bytes; partition limit is ${RECOVERY_PARTITION_SIZE}"

note "Prepare the standard build artifacts"
cp "$KERNEL_IMAGE" "${ARTIFACT_DIR}/Image.gz"
cp "$DT_IMAGE" "${ARTIFACT_DIR}/dt.img"
cp "$KERNEL_CONFIG" "${ARTIFACT_DIR}/kernel.config"

FINAL_SHA256="$(sha256_of "$FINAL_IMAGE")"
readonly FINAL_SHA256
KERNEL_SHA256="$(sha256_of "$KERNEL_IMAGE")"
readonly KERNEL_SHA256
CONFIG_SHA256="$(sha256_of "$KERNEL_CONFIG")"
readonly CONFIG_SHA256

{
  printf 'kernel_repository=%s\n' "$KERNEL_REPO"
  printf 'kernel_commit=%s\n' "$KERNEL_COMMIT"
  printf 'aarch64_toolchain_tag_object=%s\n' "$AARCH64_TOOLCHAIN_TAG_OBJECT"
  printf 'aarch64_toolchain_commit=%s\n' "$AARCH64_TOOLCHAIN_COMMIT"
  printf 'arm_toolchain_tag_object=%s\n' "$ARM_TOOLCHAIN_TAG_OBJECT"
  printf 'arm_toolchain_commit=%s\n' "$ARM_TOOLCHAIN_COMMIT"
  printf 'twrp_base=%s\n' "$TWRP_FILE"
  printf 'twrp_base_sha256=%s\n' "$TWRP_SHA256"
  printf 'recovery_size=%s\n' "$FINAL_SIZE"
  printf 'recovery_partition_limit=%s\n' "$RECOVERY_PARTITION_SIZE"
  printf 'recovery_sha256=%s\n' "$FINAL_SHA256"
  printf 'kernel_sha256=%s\n' "$KERNEL_SHA256"
  printf 'dt_sha256=%s\n' "$DT_SHA256"
  printf 'config_sha256=%s\n' "$CONFIG_SHA256"
  printf 'kernelsu=absent-from-source\n'
  printf 'build_type=bare-no-droidspaces\n'
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

printf '\nBuild completed successfully.\n'
printf 'recovery.img: %s bytes\n' "$FINAL_SIZE"
printf 'SHA-256: %s\n' "$FINAL_SHA256"
