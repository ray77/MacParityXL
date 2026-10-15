#!/bin/bash
# Downloads, verifies and builds the third-party engines MacParityXL depends on.
#
#   Vendor/build/bin/par2            universal par2cmdline-turbo executable (GPL-2.0, run as subprocess)
#   Vendor/build/lib/libunrar.a      universal RARLAB UnRAR static library (UnRAR license)
#   Vendor/build/include/unrar/      UnRAR public header (dll.hpp)
#
# Re-running is cheap: finished steps are skipped. Pass --clean to rebuild from scratch.
set -euo pipefail

PAR2_VERSION=1.5.0
PAR2_SHA256=035584144d3ac3b08fb5d7d4b844f60cf97404b6469f6aed7d9b9430a25bef0e
PAR2_URL="https://github.com/animetosho/par2cmdline-turbo/releases/download/v${PAR2_VERSION}/par2cmdline-turbo-${PAR2_VERSION}.tar.xz"

UNRAR_VERSION=7.3.1
UNRAR_SHA256=634900842a3737d9cc15bbcc71d4c74cc713437e0bca296a573424fe5f2660ab
UNRAR_URL="https://www.rarlab.com/rar/unrarsrc-${UNRAR_VERSION}.tar.gz"

ARCHS=(arm64 x86_64)
MACOSX_DEPLOYMENT_TARGET=14.0
export MACOSX_DEPLOYMENT_TARGET

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
DOWNLOADS="$VENDOR/downloads"
SRC="$VENDOR/src"
OUT="$VENDOR/build"
JOBS="$(sysctl -n hw.ncpu)"

if [[ "${1:-}" == "--clean" ]]; then
  rm -rf "$SRC" "$OUT"
fi
mkdir -p "$DOWNLOADS" "$SRC" "$OUT/bin" "$OUT/lib" "$OUT/include/unrar" "$OUT/licenses"

fetch() { # url sha256 dest
  local url=$1 sha=$2 dest=$3
  if [[ ! -f "$dest" ]]; then
    echo "==> Downloading $url"
    curl -fsSL -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi
  echo "$sha  $dest" | shasum -a 256 -c - >/dev/null || {
    echo "Checksum mismatch for $dest" >&2
    rm -f "$dest"
    exit 1
  }
}

build_par2() {
  if [[ -x "$OUT/bin/par2" ]]; then
    echo "==> par2 already built"
    return
  fi
  local tarball="$DOWNLOADS/par2cmdline-turbo-$PAR2_VERSION.tar.xz"
  fetch "$PAR2_URL" "$PAR2_SHA256" "$tarball"

  local slices=()
  for arch in "${ARCHS[@]}"; do
    local dir="$SRC/par2-$arch"
    rm -rf "$dir" && mkdir -p "$dir"
    tar xJf "$tarball" -C "$dir" --strip-components 1
    echo "==> Building par2cmdline-turbo ($arch)"
    (
      cd "$dir"
      ./configure --quiet \
        --host="${arch/arm64/aarch64}-apple-darwin" \
        CC="clang -arch $arch" CXX="clang++ -arch $arch" \
        CXXFLAGS="-O3 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
      make -j"$JOBS" par2 >/dev/null
    )
    slices+=("$dir/par2")
  done
  lipo -create "${slices[@]}" -output "$OUT/bin/par2"
  strip "$OUT/bin/par2"
  cp "$SRC/par2-${ARCHS[0]}/COPYING" "$OUT/licenses/par2cmdline-turbo-COPYING.txt"
}

build_unrar() {
  if [[ -f "$OUT/lib/libunrar.a" ]]; then
    echo "==> libunrar already built"
    return
  fi
  local tarball="$DOWNLOADS/unrarsrc-$UNRAR_VERSION.tar.gz"
  fetch "$UNRAR_URL" "$UNRAR_SHA256" "$tarball"

  local dir="$SRC/unrar"
  rm -rf "$dir" && mkdir -p "$dir"
  tar xzf "$tarball" -C "$dir" --strip-components 1
  echo "==> Building libunrar (${ARCHS[*]})"
  local arch_flags=""
  for arch in "${ARCHS[@]}"; do arch_flags+=" -arch $arch"; done
  (
    cd "$dir"
    make -j"$JOBS" lib \
      CXX=clang++ \
      CXXFLAGS="-O2 -std=c++11 -Wno-logical-op-parentheses -Wno-switch -Wno-dangling-else$arch_flags -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
      LDFLAGS="-pthread$arch_flags" >/dev/null
  )
  cp "$dir/libunrar.a" "$OUT/lib/libunrar.a"
  cp "$dir/dll.hpp" "$OUT/include/unrar/dll.hpp"
  cp "$dir/license.txt" "$OUT/licenses/unrar-license.txt"
}

build_par2
build_unrar

echo "==> Done"
lipo -info "$OUT/bin/par2" "$OUT/lib/libunrar.a"
