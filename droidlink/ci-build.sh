#!/bin/sh
set -eux

apk add --no-cache \
  build-base pkgconf file pax-utils coreutils \
  libx11-dev libxext-dev libxdamage-dev libxfixes-dev libxtst-dev

OUT=dist/droidlink-probe-aarch64-alpine
rm -rf "$OUT" \
  dist/droidlink-probe-aarch64-alpine.tar.gz \
  dist/droidlink-probe-aarch64-alpine.tar.gz.b64
mkdir -p "$OUT/lib"

cc -O2 -pipe -Wall -Wextra \
  $(pkg-config --cflags x11 xext xdamage xfixes xtst) \
  droidlink/droidlink-probe.c \
  -o "$OUT/droidlink-probe" \
  $(pkg-config --libs x11 xext xdamage xfixes xtst)

chmod 0755 "$OUT/droidlink-probe"
file "$OUT/droidlink-probe" | tee "$OUT/BUILD-INFO.txt"
printf '\n== ldd ==\n' >> "$OUT/BUILD-INFO.txt"
ldd "$OUT/droidlink-probe" | tee -a "$OUT/BUILD-INFO.txt"

ldd "$OUT/droidlink-probe" \
  | awk '{ for (i=1; i<=NF; i++) if ($i ~ /^\//) print $i }' \
  | sort -u \
  | while IFS= read -r lib; do
      [ -f "$lib" ] || continue
      case "$lib" in /lib/ld-musl-*) continue ;; esac
      cp -L "$lib" "$OUT/lib/"
    done

cat > "$OUT/run-probe.sh" <<'EOF'
#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export LD_LIBRARY_PATH="$HERE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
: "${DISPLAY:=:2}"
export DISPLAY
exec "$HERE/droidlink-probe" "$@"
EOF
chmod 0755 "$OUT/run-probe.sh"

sha256sum "$OUT/droidlink-probe" > "$OUT/SHA256SUMS"
tar -C dist -czf dist/droidlink-probe-aarch64-alpine.tar.gz \
  droidlink-probe-aarch64-alpine
base64 dist/droidlink-probe-aarch64-alpine.tar.gz \
  > dist/droidlink-probe-aarch64-alpine.tar.gz.b64
sha256sum dist/droidlink-probe-aarch64-alpine.tar.gz \
  >> "$OUT/SHA256SUMS"

file "$OUT/droidlink-probe"
cat "$OUT/BUILD-INFO.txt"
cat "$OUT/SHA256SUMS"
