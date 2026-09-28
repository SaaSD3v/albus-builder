#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR_PRE="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# Build the exact known-good bare recovery first. This script is sourced so
# its pinned WORK_DIR, MAGISKBOOT, FINAL_IMAGE and verification state remain
# available for the Wi-Fi overlay step.
# shellcheck disable=SC1091
source "$ROOT_DIR_PRE/scripts/build-bare.sh"

note "Inject clean Albus recovery Wi-Fi overlay"

readonly WIFI_BASE_IMAGE="${WORK_DIR}/recovery-bare-before-wifi.img"
readonly WIFI_REPACK_DIR="${WORK_DIR}/wifi-repack"
readonly WIFI_VERIFY_DIR="${WORK_DIR}/wifi-verify"

cp "$FINAL_IMAGE" "$WIFI_BASE_IMAGE"
mkdir -p "$WIFI_REPACK_DIR"

(
  cd "$WIFI_REPACK_DIR"
  "$MAGISKBOOT" unpack -n "$WIFI_BASE_IMAGE"

  [[ -f ramdisk.cpio ]] || die "magiskboot did not extract ramdisk.cpio for Wi-Fi overlay"

  # -n keeps every boot component byte-for-byte as stored. The Albus TeamWin
  # ramdisk is LZMA, so decompress only that component before cpio editing.
  # Keep the already-compressed kernel untouched; magiskboot repack detects it
  # as compressed and does not recompress that component.
  mv ramdisk.cpio ramdisk.cpio.lzma
  "$MAGISKBOOT" decompress ramdisk.cpio.lzma ramdisk.cpio
  rm -f ramdisk.cpio.lzma

  "$MAGISKBOOT" cpio ramdisk.cpio \
    "add 0755 sbin/wifi $ROOT_DIR/recovery-wifi/wifi" \
    "add 0644 sbin/albus-WCNSS_qcom_cfg.ini $ROOT_DIR/recovery-wifi/WCNSS_qcom_cfg.ini"

  "$MAGISKBOOT" repack "$WIFI_BASE_IMAGE" "$FINAL_IMAGE"
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

  mv ramdisk.cpio ramdisk.cpio.lzma
  "$MAGISKBOOT" decompress ramdisk.cpio.lzma ramdisk.cpio
  rm -f ramdisk.cpio.lzma

  mkdir extracted
  (
    cd extracted
    "$MAGISKBOOT" cpio ../ramdisk.cpio "extract"

    [[ -x sbin/wifi ]] || die "/sbin/wifi is missing or not executable"
    [[ -s sbin/albus-WCNSS_qcom_cfg.ini ]] ||
      die "Albus WCNSS fallback config is missing"

    grep -Fq 'wifi prepare' sbin/wifi ||
      die "unexpected /sbin/wifi payload"
    ! grep -Fq 'LD_LIBRARY_PATH=' sbin/wifi ||
      grep -Fq 'LD_LIBRARY_PATH=/vendor/lib64:/vendor/lib:/system/lib64:/system/lib \\' sbin/wifi ||
      die "Wi-Fi script contains an unexpected global LD_LIBRARY_PATH"
  )
)

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
  printf 'wifi_overlay=clean-v1\n'
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
