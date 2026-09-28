#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
OUT="$ROOT/recovery-wifi/out"
SRC="$ROOT/recovery-wifi/src"
PREFIX="$ROOT/recovery-wifi/prefix"

CROSS=aarch64-linux-gnu-
CC=${CROSS}gcc
STRIP=${CROSS}strip

WPA_TAG=hostap_2_9
OPENSSL_TAG=OpenSSL_1_1_1w
LIBNL_TAG=libnl3_2_25
BUSYBOX_COMMIT=1a64f6a20aaf6ea4dbba68bbfa8cc1ab7e5c57c4
IPTABLES_COMMIT=c16bdec15137b241586310d0e61bc88cc3726004 # iptables 1.6.2 legacy
IW_COMMIT=8934cc42695817d63b00507c20eaefa98174e0a9 # iw v5.9

rm -rf "$OUT" "$SRC" "$PREFIX"
mkdir -p "$OUT" "$SRC" "$PREFIX"

echo "==> libnl"
git clone --depth=1 --branch "$LIBNL_TAG" https://github.com/thom311/libnl.git "$SRC/libnl"
pushd "$SRC/libnl" >/dev/null
autoreconf -fi
./configure \
  --host=aarch64-linux-gnu \
  --prefix="$PREFIX" \
  --enable-static \
  --disable-shared \
  --disable-cli
make -j"$(nproc)"
make install
popd >/dev/null

echo "==> OpenSSL"
git init "$SRC/openssl"
git -C "$SRC/openssl" remote add origin https://github.com/openssl/openssl.git
git -C "$SRC/openssl" fetch --depth=1 origin "refs/tags/$OPENSSL_TAG"
git -C "$SRC/openssl" checkout --detach FETCH_HEAD
pushd "$SRC/openssl" >/dev/null
./Configure linux-aarch64 \
  --cross-compile-prefix="$CROSS" \
  no-shared \
  no-tests
make -j"$(nproc)" build_libs
popd >/dev/null

echo "==> wpa_supplicant"
git init "$SRC/wpa"
git -C "$SRC/wpa" remote add origin https://git.w1.fi/hostap.git
git -C "$SRC/wpa" fetch --depth=1 origin "refs/tags/$WPA_TAG"
git -C "$SRC/wpa" checkout --detach FETCH_HEAD
cp "$ROOT/recovery-wifi/wpa_supplicant.config" "$SRC/wpa/wpa_supplicant/.config"
cat >> "$SRC/wpa/wpa_supplicant/.config" <<EOF
CFLAGS += -Os -ffunction-sections -fdata-sections -I$PREFIX/include/libnl3 -I$SRC/openssl/include
LIBS += -L$PREFIX/lib -L$SRC/openssl
LIBS_p += -L$SRC/openssl
LIBS_c += -L$PREFIX/lib
EOF

pushd "$SRC/wpa/wpa_supplicant" >/dev/null
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
make clean || true
make -j"$(nproc)" \
  CC="$CC" \
  PKG_CONFIG="pkg-config --static" \
  LDFLAGS='-static -Wl,--gc-sections' \
  wpa_supplicant wpa_cli
cp wpa_supplicant "$OUT/wpa_supplicant.albus"
cp wpa_cli "$OUT/wpa_cli.albus"
popd >/dev/null

echo "==> hostapd"
cp "$ROOT/recovery-wifi/hostapd.config" "$SRC/wpa/hostapd/.config"
cat >> "$SRC/wpa/hostapd/.config" <<EOF
CFLAGS += -Os -ffunction-sections -fdata-sections -I$PREFIX/include/libnl3
LIBS += -L$PREFIX/lib
EOF

pushd "$SRC/wpa/hostapd" >/dev/null
make clean || true
make -j"$(nproc)" \
  CC="$CC" \
  PKG_CONFIG="pkg-config --static" \
  LDFLAGS='-static -Wl,--gc-sections' \
  hostapd
cp hostapd "$OUT/hostapd.albus"
popd >/dev/null

echo "==> iw"
git init "$SRC/iw"
git -C "$SRC/iw" remote add origin https://github.com/Droidspaces/iw-vap.git
git -C "$SRC/iw" fetch --depth=1 origin "$IW_COMMIT"
git -C "$SRC/iw" checkout --detach FETCH_HEAD
pushd "$SRC/iw" >/dev/null
make clean || true
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export CFLAGS="-Os -ffunction-sections -fdata-sections -I$PREFIX/include/libnl3"
export LDFLAGS='-static -Wl,--gc-sections'
export PKG_CONFIG="pkg-config --static"
make -j"$(nproc)" CC="$CC" V=1
unset CFLAGS LDFLAGS PKG_CONFIG
cp iw "$OUT/iw.albus"
popd >/dev/null

echo "==> BusyBox"
git init "$SRC/busybox"
git -C "$SRC/busybox" remote add origin https://github.com/mirror/busybox.git
git -C "$SRC/busybox" fetch --depth=1 origin "$BUSYBOX_COMMIT"
git -C "$SRC/busybox" checkout --detach FETCH_HEAD
pushd "$SRC/busybox" >/dev/null
make ARCH=arm64 CROSS_COMPILE="$CROSS" defconfig

if grep -q '^# CONFIG_UDHCPD is not set$' .config; then
  sed -i 's/^# CONFIG_UDHCPD is not set$/CONFIG_UDHCPD=y/' .config
elif ! grep -q '^CONFIG_UDHCPD=y$' .config; then
  echo 'CONFIG_UDHCPD=y' >> .config
fi

sed -i 's/^# CONFIG_STATIC is not set$/CONFIG_STATIC=y/' .config
sed -i 's/^CONFIG_TC=y$/# CONFIG_TC is not set/' .config || true
make ARCH=arm64 CROSS_COMPILE="$CROSS" silentoldconfig >/dev/null
make -j"$(nproc)" ARCH=arm64 CROSS_COMPILE="$CROSS"

for symbol in \
  CONFIG_UDHCPC CONFIG_UDHCPD CONFIG_IP CONFIG_IFCONFIG CONFIG_PING CONFIG_GREP CONFIG_SED \
  CONFIG_TAIL CONFIG_PKILL CONFIG_SLEEP CONFIG_CAT CONFIG_CHMOD CONFIG_MKDIR CONFIG_AWK \
  CONFIG_RM CONFIG_READLINK
do
  grep -qx "$symbol=y" .config || {
    echo "Missing required BusyBox setting: $symbol=y" >&2
    exit 1
  }
done

cp busybox "$OUT/busybox.albus"
cp .config "$OUT/busybox.config"
popd >/dev/null

echo "==> static legacy iptables for DroidSpaces"
# Same recovery-side fix proven on Channel: explicit DroidSpaces port forwards
# call iptables(8), iptables-save and iptables-restore. Build the legacy
# multi-call binary statically so recovery does not depend on Android /system.
git init "$SRC/iptables"
git -C "$SRC/iptables" remote add origin https://github.com/PKRoma/iptables.git
git -C "$SRC/iptables" fetch --depth=1 origin "$IPTABLES_COMMIT"
git -C "$SRC/iptables" checkout --detach FETCH_HEAD
pushd "$SRC/iptables" >/dev/null
./autogen.sh
PKG_CONFIG_LIBDIR=/nonexistent ./configure \
  --host=aarch64-linux-gnu \
  --prefix="$PREFIX/iptables" \
  --disable-shared \
  --enable-static \
  --disable-nftables \
  --disable-ipv6 \
  --disable-devel \
  --disable-libipq \
  --disable-bpf-compiler \
  --disable-nfsynproxy \
  --disable-connlabel \
  --with-xt-lock-name=/tmp/xtables.lock \
  CC="$CC" \
  CFLAGS='-Os -ffunction-sections -fdata-sections' \
  LDFLAGS='-Wl,--gc-sections'
# libtool treats -static as library selection and can still emit a dynamic PIE.
# Channel's validated recovery build uses -all-static at the program link step.
make -j"$(nproc)" LDFLAGS='-all-static -Wl,--gc-sections'
cp iptables/xtables-multi "$OUT/iptables.albus"
popd >/dev/null

echo "==> static Albus WCNSS helper"
"$CC" -static -Os -ffunction-sections -fdata-sections \
  -Wl,--gc-sections \
  "$ROOT/recovery-wifi/wcnss-recovery-albus.c" \
  -o "$OUT/wcnss-recovery-albus"

cp "$ROOT/recovery-wifi/wifi-udhcpc.script" "$OUT/wifi-udhcpc.script"

chmod 0755 \
  "$OUT/wpa_supplicant.albus" \
  "$OUT/wpa_cli.albus" \
  "$OUT/busybox.albus" \
  "$OUT/hostapd.albus" \
  "$OUT/iw.albus" \
  "$OUT/iptables.albus" \
  "$OUT/wcnss-recovery-albus" \
  "$OUT/wifi-udhcpc.script"

for f in \
  "$OUT/wpa_supplicant.albus" \
  "$OUT/wpa_cli.albus" \
  "$OUT/busybox.albus" \
  "$OUT/hostapd.albus" \
  "$OUT/iw.albus" \
  "$OUT/iptables.albus" \
  "$OUT/wcnss-recovery-albus"
do
  "$STRIP" --strip-all "$f"
  file "$f"
  file "$f" | grep -q 'statically linked'
done

sha256sum "$OUT"/* | tee "$OUT/SHA256SUMS"
du -h "$OUT"/*
