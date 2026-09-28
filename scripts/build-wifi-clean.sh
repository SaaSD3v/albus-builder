#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR_PRE="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# Build the exact known-good bare recovery first. Source it so the pinned
# WORK_DIR, MAGISKBOOT, FINAL_IMAGE and verification state remain available.
# shellcheck disable=SC1091
source "$ROOT_DIR_PRE/scripts/build-bare.sh"

note "Inject clean Albus recovery Wi-Fi overlay"

readonly WIFI_BASE_IMAGE="${WORK_DIR}/recovery-bare-before-wifi.img"
readonly WIFI_REPACK_DIR="${WORK_DIR}/wifi-repack"
readonly WIFI_VERIFY_DIR="${WORK_DIR}/wifi-verify"
readonly WIFI_BASE_RAMDISK="${WORK_DIR}/ramdisk-bare.lzma"
readonly WIFI_OVERLAY_RAMDISK="${WORK_DIR}/ramdisk-wifi-overlay.lzma"

cp "$FINAL_IMAGE" "$WIFI_BASE_IMAGE"
mkdir -p "$WIFI_REPACK_DIR"

(
  cd "$WIFI_REPACK_DIR"
  "$MAGISKBOOT" unpack -n "$WIFI_BASE_IMAGE"

  [[ -f ramdisk.cpio ]] ||
    die "magiskboot did not extract ramdisk.cpio for Wi-Fi overlay"

  # Keep the TeamWin LZMA ramdisk byte-for-byte. Build a second standalone
  # newc archive using the SAME LZMA-alone parameters and append it. This is
  # the same multi-member initramfs strategy used by the working Channel path.
  cp ramdisk.cpio "$WIFI_BASE_RAMDISK"

  python3 "$ROOT_DIR/recovery-wifi/build-overlay.py" build \
    --base "$WIFI_BASE_RAMDISK" \
    --wifi "$ROOT_DIR/recovery-wifi/wifi" \
    --config "$ROOT_DIR/recovery-wifi/WCNSS_qcom_cfg.ini" \
    --output "$WIFI_OVERLAY_RAMDISK"

  cat "$WIFI_OVERLAY_RAMDISK" >> ramdisk.cpio

  python3 "$ROOT_DIR/recovery-wifi/build-overlay.py" verify \
    --base "$WIFI_BASE_RAMDISK" \
    --combined ramdisk.cpio

  "$MAGISKBOOT" repack -n "$WIFI_BASE_IMAGE" "$FINAL_IMAGE"
)

[[ -s "$FINAL_IMAGE" ]] || die "Wi-Fi recovery image was not produced"

note "Verify clean Wi-Fi overlay and preserve bare kernel/DT"

mkdir -p "$WIFI_VERIFY_DIR"
(
  cd "$WIFI_VERIFY_DIR"
  "$MAGISKBOOT" unpack -n "$FINAL_IMAGE"

  [[ -f kernel ]] || die "final Wi-Fi recovery has no kernel"
  [[ -f ramdisk.cpio ]] || die "final Wi-Fi recovery has no ramdisk.cpio"
  [[ -f extra ]] || die "final Wi-Fi recovery has no separated DT"

  cmp -s "$KERNEL_IMAGE" kernel ||
    die "kernel changed while injecting the Wi-Fi overlay"
  cmp -s "$DT_IMAGE" extra ||
    die "DT changed while injecting the Wi-Fi overlay"

  python3 "$ROOT_DIR/recovery-wifi/build-overlay.py" verify \
    --base "$WIFI_BASE_RAMDISK" \
    --combined ramdisk.cpio
)

grep -Fq 'wifi prepare' "$ROOT_DIR/recovery-wifi/wifi" ||
  die "unexpected /sbin/wifi payload"

# A vendor LD_LIBRARY_PATH is allowed only on the one wcnss_service invocation,
# never as an exported recovery-wide environment variable.
if grep -Eq '^[[:space:]]*export[[:space:]]+LD_LIBRARY_PATH' "$ROOT_DIR/recovery-wifi/wifi"; then
  die "Wi-Fi script exports LD_LIBRARY_PATH globally"
fi

WIFI_FINAL_SIZE="$(stat -c '%s' "$FINAL_IMAGE")"
readonly WIFI_FINAL_SIZE
(( WIFI_FINAL_SIZE <= RECOVERY_PARTITION_SIZE )) ||
  die "Wi-Fi recovery is ${WIFI_FINAL_SIZE} bytes; partition limit is ${RECOVERY_PARTITION_SIZE}"

BARE_WIFI_BASE_SHA256="$(sha256_of "$WIFI_BASE_IMAGE")"
readonly BARE_WIFI_BASE_SHA256
WIFI_FINAL_SHA256="$(sha256_of "$FINAL_IMAGE")"
readonly WIFI_FINAL_SHA256

sed -i \
  -e "s|^recovery_sha256=.*|recovery_sha256=${WIFI_FINAL_SHA256}|" \
  -e 's|^build_type=.*|build_type=bare-plus-clean-recovery-wifi|' \
  "$ARTIFACT_DIR/build-info.txt"

{
  printf 'bare_recovery_before_wifi_sha256=%s\n' "$BARE_WIFI_BASE_SHA256"
  printf 'wifi_overlay=clean-v2-second-lzma-initramfs\n'
  printf 'wifi_commands=help,test,prepare,up,status,down,logs\n'
  printf 'wifi_userspace=stock-recovery-tools-plus-stock-vendor-wcnss\n'
  printf 'wifi_hotspot=not-included\n'
} >> "$ARTIFACT_DIR/build-info.txt"

cp "$ROOT_DIR/recovery-wifi/wifi" "$ARTIFACT_DIR/wifi"
cp "$ROOT_DIR/recovery-wifi/WCNSS_qcom_cfg.ini" "$ARTIFACT_DIR/WCNSS_qcom_cfg.ini"

(
  cd "$ARTIFACT_DIR"
  sha256sum \
    recovery.img \
    Image.gz \
    dt.img \
    kernel.config \
    build-info.txt \
    wifi \
    WCNSS_qcom_cfg.ini \
    > SHA256SUMS
)

printf '\nClean Albus recovery Wi-Fi image completed successfully.\n'
printf 'recovery.img: %s bytes\n' "$WIFI_FINAL_SIZE"
printf 'SHA-256: %s\n' "$WIFI_FINAL_SHA256"
