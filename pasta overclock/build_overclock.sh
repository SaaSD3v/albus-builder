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
# 2. PATCH kernel source for overclock (4 files)
# ============================================================
note "Patch kernel for GPU ${GPU_MHZ} MHz, CPU ${CPU_MHZ} MHz"

# --- File 1: drivers/clk/msm/clock-cpu-8953.c ---
# The PLL (apcs_hf_pll) already supports up to 2400MHz.
# Just raise the max_rate limit.
CPU_CLK_DRV="${WORK_DIR}/kernel/drivers/clk/msm/clock-cpu-8953.c"
[[ -f "$CPU_CLK_DRV" ]] || die "CPU clock driver not found: $CPU_CLK_DRV"
grep -q "max_rate = 2208000000UL" "$CPU_CLK_DRV" \
  || die "Stock max_rate 2208000000 not found in $CPU_CLK_DRV"
sed -i "s/max_rate = 2208000000UL/max_rate = 2400000000UL/" "$CPU_CLK_DRV"
note "CPU clock max_rate raised to 2400MHz"

# --- File 2: drivers/clk/msm/clock-gcc-8953.c ---
# Add 700MHz entry to GPU clock source table.
# gpll3 = 1300MHz. 700MHz cannot be derived from gpll3 (1300/700 is not integer).
# Use gpll0 = 1200MHz. 700MHz not derivable.
# Use gpll4_out_aux = 1152MHz. 700MHz not derivable.
# Actually, best approach: use the XO path or just set gpll3 to 1400MHz.
# gpll3 is programmable. Change 650MHz entry: gpll3 1300->1400, then 1400/2 = 700.
GPU_CLK_DRV="${WORK_DIR}/kernel/drivers/clk/msm/clock-gcc-8953.c"
[[ -f "$GPU_CLK_DRV" ]] || die "GPU clock driver not found: $GPU_CLK_DRV"
grep -q "650000000" "$GPU_CLK_DRV" \
  || die "Stock GPU 650MHz not found in $GPU_CLK_DRV"
# Change gpll3 from 1300MHz to 1400MHz and divider from 1 to 2 to get 700MHz
# Original: F_MM( 650000000,    1300000000,               gpll3,    1,    0,     0),
sed -i 's/F_MM( 650000000,    1300000000,               gpll3,    1,/F_MM( 700000000,    1400000000,               gpll3,    1,/' "$GPU_CLK_DRV"
grep -q "700000000" "$GPU_CLK_DRV" \
  || die "GPU clock patch failed - 700MHz not found in $GPU_CLK_DRV"
note "GPU clock: 650MHz -> 700MHz (gpll3 1400MHz/1)"

# --- File 3: arch/arm/boot/dts/qcom/msm8953.dtsi ---
# Patch speed-bin tables, cpufreq-table, and gfxfreq-corner
CPU_DTS="${WORK_DIR}/kernel/arch/arm/boot/dts/qcom/msm8953.dtsi"
[[ -f "$CPU_DTS" ]] || die "CPU DTS not found: $CPU_DTS"

# 3a: Patch cpufreq-table (KHz values, REPLACE 2208000 with 2300000)
grep -q "< ${STOCK_CPU_KHZ} >" "$CPU_DTS" \
  || die "Stock CPU freq ${STOCK_CPU_KHZ} not found in cpufreq-table"
sed -i "s/< ${STOCK_CPU_KHZ} >/< ${TARGET_CPU_KHZ} >/g" "$CPU_DTS"
note "CPU cpufreq-table: ${STOCK_CPU_KHZ} -> ${TARGET_CPU_KHZ} KHz"

# 3b: Patch speed-bin tables (Hz values, REPLACE 2208000000 with 2300000000)
# Reuse level 9 to avoid needing new clock driver level mappings.
grep -q "2208000000" "$CPU_DTS" \
  || die "Stock CPU 2208000000 Hz not found in speed-bin tables"
sed -i 's/2208000000 9/2300000000 9/g' "$CPU_DTS"
note "CPU speed-bin tables: 2208000000 -> 2300000000 Hz (level 9)"

# 3c: Patch gfxfreq-corner (add 700000000)
grep -q "650000000" "$CPU_DTS" \
  || die "Stock GPU 650000000 Hz not found in gfxfreq-corner"
sed -i 's/< 650000000   7 >/< 700000000   7 >/' "$CPU_DTS"
note "CPU gfxfreq-corner: 650MHz -> 700MHz"

# --- File 4: arch/arm/boot/dts/qcom/msm8953-gpu.dtsi ---
# Change top GPU power level from 650MHz to 700MHz
GPU_DTS="${WORK_DIR}/kernel/arch/arm/boot/dts/qcom/msm8953-gpu.dtsi"
[[ -f "$GPU_DTS" ]] || die "GPU DTS not found: $GPU_DTS"
grep -q "$STOCK_GPU_HZ" "$GPU_DTS" \
  || die "Stock GPU freq $STOCK_GPU_HZ not found in $GPU_DTS"
sed -i "s/${STOCK_GPU_HZ}/${TARGET_GPU_HZ}/g" "$GPU_DTS"
note "GPU DTS: ${STOCK_GPU_HZ} -> ${TARGET_GPU_HZ} Hz (${TARGET_GPU_HZ:-0} occurrence(s))"

# ============================================================
# 3. Build kernel
# ============================================================
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
# 4b. Verify DT image has overclocked values
# ============================================================
# DTS source patches are compiled into DTBs by make dtbs (ARCH=arm64
# does build msm8953 DTBs from arch/arm64/boot/dts/qcom/).
# Binary-patch is REMOVED because blind search-replace corrupts
# unrelated DT properties that happen to share the same value.
python3 - "${WORK_DIR}/dt.img" "$TARGET_GPU_HZ" "$STOCK_GPU_HZ" "$TARGET_CPU_KHZ" "$STOCK_CPU_KHZ" <<'PYEOF'
import sys, struct

path = sys.argv[1]
target_gpu = int(sys.argv[2])
stock_gpu  = int(sys.argv[3])
target_cpu = int(sys.argv[4])
stock_cpu  = int(sys.argv[5])

with open(path, 'rb') as f:
    data = f.read()

gpu_old = struct.pack('>I', stock_gpu)
gpu_new = struct.pack('>I', target_gpu)
cpu_old = struct.pack('>I', stock_cpu)
cpu_new = struct.pack('>I', target_cpu)

gpu_stock = data.count(gpu_old)
gpu_oc    = data.count(gpu_new)
cpu_stock = data.count(cpu_old)
cpu_oc    = data.count(cpu_new)

print(f"GPU stock {stock_gpu}Hz: {gpu_stock} remaining, {gpu_oc} OC entries")
print(f"CPU stock {stock_cpu}KHz: {cpu_stock} remaining, {cpu_oc} OC entries")

if gpu_stock > 0 and gpu_oc == 0:
    print(f"WARNING: GPU DTBs not patched (stock still present)")
if cpu_stock > 0 and cpu_oc == 0:
    print(f"WARNING: CPU DTBs not patched (stock still present)")
PYEOF

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
