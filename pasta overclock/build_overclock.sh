#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ARTIFACT_DIR="${ROOT_DIR}/artifacts"

# Overclock values
readonly GPU_MHZ="${GPU_MHZ:-700}"
readonly CPU_MHZ="${CPU_MHZ:-2300}"

# Stock frequencies
readonly STOCK_GPU_HZ=650000000
readonly STOCK_CPU_KHZ=2208000

# Target frequencies
readonly TARGET_GPU_HZ=$((GPU_MHZ * 1000000))
readonly TARGET_CPU_KHZ=$((CPU_MHZ * 1000))

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

readonly TWRP_FILE="twrp-3.5.0_9-0-albus.img"
readonly TWRP_PAGE="https://dl.twrp.me/albus/${TWRP_FILE}.html"
readonly TWRP_URL="https://dl.twrp.me/albus/${TWRP_FILE}"
readonly TWRP_SHA256="4c42bfee165ea99e2663284a3634135786e157bd6cc492fcbe0d9bd3430e9261"
readonly TWRP_SIZE=18933760

readonly MAGISK_VERSION="30.7"
readonly MAGISK_URL="https://github.com/topjohnwu/Magisk/releases/download/v${MAGISK_VERSION}/Magisk-v${MAGISK_VERSION}.apk"
readonly MAGISK_APK_SHA256="e0d32d2123532860f97123d927b1bb86c4e08e6fd8a48bfc6b5bee0afae9ebd5"
readonly MAGISKBOOT_SHA256="a18ecbd7981179494b7d281453d6c4e25b5c719e7d2ef7f6eba3c6be3043c58e"

readonly RECOVERY_PARTITION_SIZE=21073920

TEMP_ROOT="${RUNNER_TEMP:-/tmp}"
WORK_DIR="$(mktemp -d "${TEMP_ROOT}/albus-overclock.XXXXXX")"
readonly WORK_DIR

mkdir -p "$ARTIFACT_DIR" "${WORK_DIR}/tools"

note "=== OVERCLOCK BUILD: GPU=${GPU_MHZ} MHz, CPU=${CPU_MHZ} MHz ==="

# ============================================================
# 1. Clone kernel source, toolchains, dtbtool
# ============================================================
note "Clone kernel and toolchains"
clone_commit "$KERNEL_REPO" "$KERNEL_COMMIT" "${WORK_DIR}/kernel"
clone_tag "$AARCH64_TOOLCHAIN_REPO" "$TOOLCHAIN_TAG" "$AARCH64_TOOLCHAIN_TAG_OBJECT" "$AARCH64_TOOLCHAIN_COMMIT" "${WORK_DIR}/aarch64-toolchain"
clone_tag "$ARM_TOOLCHAIN_REPO" "$TOOLCHAIN_TAG" "$ARM_TOOLCHAIN_TAG_OBJECT" "$ARM_TOOLCHAIN_COMMIT" "${WORK_DIR}/arm-toolchain"
clone_commit "$DTBTOOL_REPO" "$DTBTOOL_COMMIT" "${WORK_DIR}/dtbtool"

# ============================================================
# 2. PATCH the DTS files BEFORE compilation
# ============================================================
note "Patch DTS: GPU ${STOCK_GPU_HZ} Hz -> ${TARGET_GPU_HZ} Hz, CPU ${STOCK_CPU_KHZ} KHz -> ${TARGET_CPU_KHZ} KHz"

GPU_DTS="${WORK_DIR}/kernel/arch/arm/boot/dts/qcom/msm8953-gpu.dtsi"
CPU_DTS="${WORK_DIR}/kernel/arch/arm/boot/dts/qcom/msm8953.dtsi"

[[ -f "$GPU_DTS" ]] || die "GPU DTS not found: $GPU_DTS"
[[ -f "$CPU_DTS" ]] || die "CPU DTS not found: $CPU_DTS"

# Patch GPU: replace 650000000 with TARGET_GPU_HZ
grep -q "$STOCK_GPU_HZ" "$GPU_DTS" || die "Stock GPU freq $STOCK_GPU_HZ not found in $GPU_DTS"
sed -i "s/${STOCK_GPU_HZ}/${TARGET_GPU_HZ}/g" "$GPU_DTS"
note "GPU patched: $(grep -c "$TARGET_GPU_HZ" "$GPU_DTS") occurrence(s) of $TARGET_GPU_HZ"

# Patch CPU: replace last cpufreq-table entry 2208000 with TARGET_CPU_KHZ
grep -q "$STOCK_CPU_KHZ" "$CPU_DTS" || die "Stock CPU freq $STOCK_CPU_KHZ not found in $CPU_DTS"
sed -i "s/< ${STOCK_CPU_KHZ} >/< ${TARGET_CPU_KHZ} >/g" "$CPU_DTS"
note "CPU patched: $(grep -c "$TARGET_CPU_KHZ" "$CPU_DTS") occurrence(s) of $TARGET_CPU_KHZ"

# ============================================================
# 3. Build kernel
# ============================================================
export ARCH=arm
export SUBARCH=arm
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
[[ -s "$KERNEL_IMAGE" ]] || die "Image.gz was not produced"

# ============================================================
# 4. Build QCDT v3 Motorola image
# ============================================================
note "Build QCDT v3 image"
cc \
  -O2 \
  -Wall \
  "${WORK_DIR}/dtbtool/dtbtool/dtbtool.c" \
  -o "${WORK_DIR}/tools/dtbTool_custom"

"${WORK_DIR}/tools/dtbTool_custom" \
  --force-v3 \
  --motorola 1 \
  -o "${WORK_DIR}/dt.img" \
  -s 2048 \
  -p "${WORK_DIR}/kernel-out/scripts/dtc/" \
  "${WORK_DIR}/kernel-out/arch/arm64/boot/"

[[ "$(dd if="${WORK_DIR}/dt.img" bs=1 count=4 status=none)" == "QCDT" ]] \
  || die "dt.img does not contain the QCDT magic"

# ============================================================
# 5. Download magiskboot and TWRP
# ============================================================
note "Download magiskboot"
readonly MAGISK_APK="${WORK_DIR}/Magisk-v${MAGISK_VERSION}.apk"
readonly MAGISKBOOT="${WORK_DIR}/tools/magiskboot"
curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 \
  "$MAGISK_URL" --output "$MAGISK_APK"
check_sha256 "$MAGISK_APK_SHA256" "$MAGISK_APK"
unzip -p "$MAGISK_APK" lib/x86_64/libmagiskboot.so > "$MAGISKBOOT"
check_sha256 "$MAGISKBOOT_SHA256" "$MAGISKBOOT"
chmod 0755 "$MAGISKBOOT"

note "Download TWRP base"
curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 \
  --user-agent "Mozilla/5.0" --referer "$TWRP_PAGE" \
  "$TWRP_URL" --output "${WORK_DIR}/${TWRP_FILE}"
check_sha256 "$TWRP_SHA256" "${WORK_DIR}/${TWRP_FILE}"
check_size "$TWRP_SIZE" "${WORK_DIR}/${TWRP_FILE}"

# ============================================================
# 6. Unpack TWRP, replace kernel+DT, repack
# ============================================================
note "Unpack TWRP"
readonly REPACK_DIR="${WORK_DIR}/repack"
mkdir "$REPACK_DIR"
(cd "$REPACK_DIR" && "$MAGISKBOOT" unpack -n "${WORK_DIR}/${TWRP_FILE}")

[[ -f "${REPACK_DIR}/kernel" ]] || die "kernel not extracted"
[[ -f "${REPACK_DIR}/ramdisk.cpio" ]] || die "ramdisk not extracted"
[[ -f "${REPACK_DIR}/extra" ]] || die "DT not extracted"

note "Replace kernel and DT with overclocked versions"
cp "$KERNEL_IMAGE" "${REPACK_DIR}/kernel"
cp "${WORK_DIR}/dt.img" "${REPACK_DIR}/extra"

note "Repack recovery.img"
(cd "$REPACK_DIR" && "$MAGISKBOOT" repack -n "${WORK_DIR}/${TWRP_FILE}" "${ARTIFACT_DIR}/recovery.img")
[[ -s "${ARTIFACT_DIR}/recovery.img" ]] || die "recovery.img was not produced"

# ============================================================
# 7. Verify
# ============================================================
note "Verify"
readonly VERIFY_DIR="${WORK_DIR}/verify"
mkdir "$VERIFY_DIR"
(cd "$VERIFY_DIR" && "$MAGISKBOOT" unpack -n "${ARTIFACT_DIR}/recovery.img")

cmp -s "$KERNEL_IMAGE" "${VERIFY_DIR}/kernel" \
  || die "kernel mismatch"
cmp -s "${WORK_DIR}/dt.img" "${VERIFY_DIR}/extra" \
  || die "DT mismatch"

FINAL_SIZE="$(stat -c '%s' "${ARTIFACT_DIR}/recovery.img")"
(( FINAL_SIZE <= RECOVERY_PARTITION_SIZE )) \
  || die "recovery.img too large: ${FINAL_SIZE} > ${RECOVERY_PARTITION_SIZE}"

# ============================================================
# 8. Prepare artifacts
# ============================================================
cp "$KERNEL_IMAGE" "${ARTIFACT_DIR}/Image.gz"
cp "${WORK_DIR}/dt.img" "${ARTIFACT_DIR}/dt.img"

FINAL_SHA256="$(sha256_of "${ARTIFACT_DIR}/recovery.img")"

{
  printf 'kernel_repository=%s\n' "$KERNEL_REPO"
  printf 'kernel_commit=%s\n' "$KERNEL_COMMIT"
  printf 'twrp_base=%s\n' "$TWRP_FILE"
  printf 'recovery_size=%s\n' "$FINAL_SIZE"
  printf 'recovery_sha256=%s\n' "$FINAL_SHA256"
  printf 'overclock_gpu_mhz=%s\n' "$GPU_MHZ"
  printf 'overclock_cpu_mhz=%s\n' "$CPU_MHZ"
  printf 'gpu_dts_change=%s -> %s Hz\n' "$STOCK_GPU_HZ" "$TARGET_GPU_HZ"
  printf 'cpu_dts_change=%s -> %s KHz\n' "$STOCK_CPU_KHZ" "$TARGET_CPU_KHZ"
} > "${ARTIFACT_DIR}/build-info.txt"

(
  cd "$ARTIFACT_DIR"
  sha256sum recovery.img Image.gz dt.img build-info.txt > SHA256SUMS
)

note "=== OVERCLOCK BUILD COMPLETE ==="
printf 'recovery.img: %s bytes\n' "$FINAL_SIZE"
printf 'SHA-256: %s\n' "$FINAL_SHA256"
printf 'GPU: %s MHz (stock: 650)\n' "$GPU_MHZ"
printf 'CPU: %s MHz (stock: 2208)\n' "$CPU_MHZ"
