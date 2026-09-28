#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR_PRE="$(cd -- "$SCRIPT_DIR/.." && pwd)"

echo "==> Build pinned static Wi-Fi client userspace"
bash "$ROOT_DIR_PRE/recovery-wifi/build-userspace.sh"

# Build the exact known-good bare recovery first. Source it so the pinned
# WORK_DIR, MAGISKBOOT, FINAL_IMAGE and verification state remain available.
# shellcheck disable=SC1091
source "$ROOT_DIR_PRE/scripts/build-bare.sh"

note "Inject complete Albus recovery Wi-Fi client overlay"

readonly WIFI_BASE_IMAGE="${WORK_DIR}/recovery-bare-before-wifi.img"
readonly WIFI_REPACK_DIR="${WORK_DIR}/wifi-repack"
readonly WIFI_VERIFY_DIR="${WORK_DIR}/wifi-verify"
readonly WIFI_BASE_RAMDISK="${WORK_DIR}/ramdisk-bare.lzma"
readonly WIFI_OVERLAY_RAMDISK="${WORK_DIR}/ramdisk-wifi-overlay.lzma"
readonly WIFI_OUT="$ROOT_DIR/recovery-wifi/out"

cp "$FINAL_IMAGE" "$WIFI_BASE_IMAGE"
mkdir -p "$WIFI_REPACK_DIR"

(
  cd "$WIFI_REPACK_DIR"
  "$MAGISKBOOT" unpack -n "$WIFI_BASE_IMAGE"

  [[ -f ramdisk.cpio ]] ||
    die "magiskboot did not extract ramdisk.cpio for Wi-Fi overlay"

  cp ramdisk.cpio "$WIFI_BASE_RAMDISK"

  python3 "$ROOT_DIR/recovery-wifi/build-overlay.py" build \
    --base "$WIFI_BASE_RAMDISK" \
    --wifi "$ROOT_DIR/recovery-wifi/wifi" \
    --config "$ROOT_DIR/recovery-wifi/WCNSS_qcom_cfg.ini" \
    --wpa "$WIFI_OUT/wpa_supplicant.albus" \
    --wpacli "$WIFI_OUT/wpa_cli.albus" \
    --hostapd "$WIFI_OUT/hostapd.albus" \
    --iw "$WIFI_OUT/iw.albus" \
    --wcnss "$WIFI_OUT/wcnss-recovery-albus" \
    --busybox "$WIFI_OUT/busybox.albus" \
    --iptables "$WIFI_OUT/iptables.albus" \
    --udhcpc-script "$WIFI_OUT/wifi-udhcpc.script" \
    --output "$WIFI_OVERLAY_RAMDISK"

  cat "$WIFI_OVERLAY_RAMDISK" >> ramdisk.cpio

  python3 "$ROOT_DIR/recovery-wifi/build-overlay.py" verify \
    --base "$WIFI_BASE_RAMDISK" \
    --combined ramdisk.cpio

  "$MAGISKBOOT" repack -n "$WIFI_BASE_IMAGE" "$FINAL_IMAGE"
)

[[ -s "$FINAL_IMAGE" ]] || die "Wi-Fi recovery image was not produced"

note "Verify complete Wi-Fi overlay and preserve bare kernel/DT"

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

for cmd in prepare up start scan connect connect-sae connect-open hotspot dhcp status ping disconnect down stop logs test; do
  grep -Fq "$cmd" "$ROOT_DIR/recovery-wifi/wifi" ||
    die "missing Wi-Fi command in controller: $cmd"
done

for hotspot_cmd in probe-vif start-vif status clients stop; do
  grep -Fq "$hotspot_cmd" "$ROOT_DIR/recovery-wifi/wifi" ||
    die "missing hotspot subcommand in controller: $hotspot_cmd"
done

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
  -e 's|^build_type=.*|build_type=bare-plus-complete-recovery-wifi-client|' \
  "$ARTIFACT_DIR/build-info.txt"

{
  printf 'bare_recovery_before_wifi_sha256=%s\n' "$BARE_WIFI_BASE_SHA256"
  printf 'wifi_overlay=channel-style-client-v2-second-lzma-initramfs\n'
  printf 'wifi_commands=prepare,up,start,scan,connect,connect-sae,connect-open,hotspot-probe-vif,hotspot-start-vif,hotspot-status,hotspot-clients,hotspot-stop,dhcp,status,ping,disconnect,down,stop,logs,test\n'
  printf 'wifi_userspace=static-wpa-supplicant-2.9-plus-static-hostapd-2.9-plus-static-iw-plus-static-busybox-udhcpd-plus-static-legacy-iptables-plus-static-albus-wcnss-helper\n'
  printf 'droidspaces_iptables=legacy-static-multicall-with-iptables-save-restore-aliases\n'
  printf 'wifi_system_mount=not-required\n'
  printf 'wifi_vendor_service=not-used\n'
  printf 'wifi_hotspot=ap0-vif-repeater-with-ipv4-nat\n'
  printf 'wifi_hotspot_address=192.168.43.1/24\n'
  printf 'wifi_hotspot_persistence=tmpfs-only\n'
  printf 'wifi_hotspot_nat=ap0-to-wlan0-masquerade-with-private-chains\n'
  printf 'wifi_overlay_size=%s\n' "$(stat -c '%s' "$WIFI_OVERLAY_RAMDISK")"
} >> "$ARTIFACT_DIR/build-info.txt"

cp "$ROOT_DIR/recovery-wifi/wifi" "$ARTIFACT_DIR/wifi"
cp "$ROOT_DIR/recovery-wifi/WCNSS_qcom_cfg.ini" "$ARTIFACT_DIR/WCNSS_qcom_cfg.ini"
cp "$WIFI_OUT/wpa_supplicant.albus" "$ARTIFACT_DIR/"
cp "$WIFI_OUT/wpa_cli.albus" "$ARTIFACT_DIR/"
cp "$WIFI_OUT/hostapd.albus" "$ARTIFACT_DIR/"
cp "$WIFI_OUT/iw.albus" "$ARTIFACT_DIR/"
cp "$WIFI_OUT/wcnss-recovery-albus" "$ARTIFACT_DIR/"
cp "$WIFI_OUT/busybox.albus" "$ARTIFACT_DIR/"
cp "$WIFI_OUT/iptables.albus" "$ARTIFACT_DIR/"
cp "$WIFI_OUT/wifi-udhcpc.script" "$ARTIFACT_DIR/"

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
    wpa_supplicant.albus \
    wpa_cli.albus \
    hostapd.albus \
    iw.albus \
    wcnss-recovery-albus \
    busybox.albus \
    iptables.albus \
    wifi-udhcpc.script \
    > SHA256SUMS
)

printf '\nComplete Albus recovery Wi-Fi client image built successfully.\n'
printf 'recovery.img: %s bytes\n' "$WIFI_FINAL_SIZE"
printf 'SHA-256: %s\n' "$WIFI_FINAL_SHA256"
printf 'Wi-Fi overlay: %s bytes\n' "$(stat -c '%s' "$WIFI_OVERLAY_RAMDISK")"
