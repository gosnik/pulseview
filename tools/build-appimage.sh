#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_DIR="$(cd -- "$ROOT_DIR/.." && pwd)"
SIGROK_PREFIX="${SIGROK_PREFIX:-$WORKSPACE_DIR/.sigrok-local}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build-local}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build/appimage}"
APPDIR="${APPDIR:-$BUILD_ROOT/PulseView.AppDir}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
TOOLS_DIR="${TOOLS_DIR:-$BUILD_ROOT/tools}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
ARCH_NAME="${ARCH_NAME:-x86_64}"
GIT_VERSION="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf 'local')"
OUTPUT_NAME="${OUTPUT_NAME:-PulseView-ALIENTEK-DL16-${GIT_VERSION}-${ARCH_NAME}.AppImage}"

LINUXDEPLOY_URL="${LINUXDEPLOY_URL:-https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${ARCH_NAME}.AppImage}"
QT_PLUGIN_URL="${QT_PLUGIN_URL:-https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-${ARCH_NAME}.AppImage}"

export APPIMAGE_EXTRACT_AND_RUN="${APPIMAGE_EXTRACT_AND_RUN:-1}"
export PKG_CONFIG_PATH="$SIGROK_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="$SIGROK_PREFIX/lib:/usr/local/lib:${LD_LIBRARY_PATH:-}"

download_tool() {
  local url="$1"
  local output="$2"

  if [[ -x "$output" ]]; then
    return
  fi

  mkdir -p "$(dirname -- "$output")"
  echo "[tools] downloading $(basename -- "$output")"
  curl -L --fail --retry 3 --output "$output" "$url"
  chmod +x "$output"
}

configure_pulseview() {
  echo "[build] configuring PulseView in $BUILD_DIR"
  cmake -S "$ROOT_DIR" -B "$BUILD_DIR" \
    -DCMAKE_PREFIX_PATH="$SIGROK_PREFIX" \
    -DPKG_CONFIG_USE_CMAKE_PREFIX_PATH=ON \
    -DCMAKE_BUILD_RPATH="$SIGROK_PREFIX/lib" \
    -DCMAKE_INSTALL_RPATH='$ORIGIN/../lib'
}

build_pulseview() {
  if [[ ! -d "$SIGROK_PREFIX/lib/pkgconfig" ]]; then
    echo "Local sigrok prefix not found at $SIGROK_PREFIX. Run ../tools/build-pulseview-local.sh first." >&2
    exit 1
  fi

  if [[ ! -f "$BUILD_DIR/CMakeCache.txt" ]]; then
    configure_pulseview
  fi

  echo "[build] building PulseView"
  cmake --build "$BUILD_DIR" -j"$BUILD_JOBS"
}

find_decoder_dir() {
  local dir

  for dir in \
    "${SIGROKDECODE_DIR:-}" \
    "/usr/local/share/libsigrokdecode/decoders" \
    "/usr/share/libsigrokdecode/decoders"; do
    if [[ -n "$dir" && -d "$dir" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
}

copy_tree() {
  local src="$1"
  local dst="$2"

  rm -rf "$dst"
  mkdir -p "$(dirname -- "$dst")"

  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude='__pycache__/' --exclude='*.pyc' "$src/" "$dst/"
  else
    cp -a "$src" "$dst"
    find "$dst" \( -type d -name __pycache__ -o -type f -name '*.pyc' \) -prune -exec rm -rf {} +
  fi
}

find_linked_library() {
  local binary="$1"
  local soname="$2"

  ldd "$binary" | awk -v name="$soname" '$1 == name && $3 ~ /^\// { print $3; exit }'
}

prepare_appdir() {
  local decoder_dir

  echo "[appdir] installing PulseView into $APPDIR"
  rm -rf "$APPDIR"
  cmake --install "$BUILD_DIR" --prefix "$APPDIR/usr"

  if [[ ! -x "$APPDIR/usr/bin/pulseview" ]]; then
    echo "PulseView install did not create $APPDIR/usr/bin/pulseview." >&2
    exit 1
  fi

  mv "$APPDIR/usr/bin/pulseview" "$APPDIR/usr/bin/pulseview.real"
  cat >"$APPDIR/usr/bin/pulseview" <<'EOF_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -x "$HERE/pulseview.real" ]]; then
  APPDIR="$(cd -- "$HERE/../.." && pwd)"
  REAL_BINARY="$HERE/pulseview.real"
elif [[ -x "$HERE/usr/bin/pulseview.real" ]]; then
  APPDIR="$HERE"
  REAL_BINARY="$APPDIR/usr/bin/pulseview.real"
else
  echo "Unable to locate pulseview.real from $HERE." >&2
  exit 127
fi

export SIGROKDECODE_DIR="$APPDIR/usr/share/libsigrokdecode/decoders${SIGROKDECODE_DIR:+:$SIGROKDECODE_DIR}"
export LD_LIBRARY_PATH="$APPDIR/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

exec "$REAL_BINARY" "$@"
EOF_WRAPPER
  chmod +x "$APPDIR/usr/bin/pulseview"

  # Upstream AppStream metadata currently fails appstreamcli validation because
  # of stale sigrok URLs. Metadata is optional for this local driver AppImage.
  rm -f "$APPDIR/usr/share/metainfo/org.sigrok.PulseView.appdata.xml"

  decoder_dir="$(find_decoder_dir || true)"
  if [[ -z "$decoder_dir" ]]; then
    echo "No libsigrokdecode decoder directory found. Set SIGROKDECODE_DIR to bundle one." >&2
    exit 1
  fi

  echo "[appdir] bundling decoders from $decoder_dir"
  copy_tree "$decoder_dir" "$APPDIR/usr/share/libsigrokdecode/decoders"
}

build_appimage() {
  local linuxdeploy="$TOOLS_DIR/linuxdeploy-${ARCH_NAME}.AppImage"
  local qt_plugin="$TOOLS_DIR/linuxdeploy-plugin-qt-${ARCH_NAME}.AppImage"
  local executable="$APPDIR/usr/bin/pulseview.real"
  local desktop="$APPDIR/usr/share/applications/org.sigrok.PulseView.desktop"
  local icon="$APPDIR/usr/share/icons/hicolor/48x48/apps/pulseview.png"
  local sigrok_lib
  local sigrokcxx_lib
  local sigrokdecode_lib
  local library_args=()

  download_tool "$LINUXDEPLOY_URL" "$linuxdeploy"
  download_tool "$QT_PLUGIN_URL" "$qt_plugin"

  sigrok_lib="$(find_linked_library "$executable" libsigrok.so.4 || true)"
  sigrokcxx_lib="$(find_linked_library "$executable" libsigrokcxx.so.4 || true)"
  sigrokdecode_lib="$(find_linked_library "$executable" libsigrokdecode.so.4 || true)"

  for lib in "$sigrok_lib" "$sigrokcxx_lib" "$sigrokdecode_lib"; do
    if [[ -n "$lib" && -f "$lib" ]]; then
      library_args+=(--library "$lib")
    fi
  done

  rm -f "$ROOT_DIR/$OUTPUT_NAME" "$DIST_DIR/$OUTPUT_NAME"
  mkdir -p "$DIST_DIR"

  echo "[appimage] building $OUTPUT_NAME"
  export LDAI_OUTPUT="$OUTPUT_NAME"
  export EXTRA_QT_PLUGINS="${EXTRA_QT_PLUGINS:-platformthemes/libqgtk3.so}"

  pushd "$ROOT_DIR" >/dev/null
  "$linuxdeploy" \
    --appdir "$APPDIR" \
    --executable "$executable" \
    --desktop-file "$desktop" \
    --icon-file "$icon" \
    "${library_args[@]}" \
    --plugin qt \
    --output appimage
  popd >/dev/null

  mv "$ROOT_DIR/$OUTPUT_NAME" "$DIST_DIR/$OUTPUT_NAME"
  echo "[appimage] wrote $DIST_DIR/$OUTPUT_NAME"
}

build_pulseview
prepare_appdir
build_appimage
