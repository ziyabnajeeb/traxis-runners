#!/bin/sh
# Build Wine from the CodeWeavers sources into runners/build/ (git-ignored).
# Usage: runners/scripts/build-wine.sh [deps|source|configure|build|install|addons|components|all]   (default: all)
# Requires runners/scripts/toolchain.sh to have run once.
set -eu
# Build natively, even when started from a shell running under Rosetta: Apple's
# command-line tools (m4, ar, nm via xcrun) are arm64-only on Apple Silicon
# and fail to load as x86_64 ("libxcrun ... need 'x86_64'").
if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
  exec arch -arm64 /bin/sh "$0" "$@"
fi
cd "$(dirname "$0")/.."
RUNNERS=$(pwd)
. "$RUNNERS/scripts/version.sh"
CX_SRC=$RUNNERS/../third_party/codeweavers/crossover-sources-$CX_VERSION
# Patched copy of $CX_SRC/wine; the archive itself stays read-only.
SRC=$RUNNERS/build/src/wine
BUILD=$RUNNERS/build/wine-x86_64
DIST=$RUNNERS/build/dist/$ID
DEPS=$RUNNERS/build/deps # libraries Wine depends on, with headers; build-only
JOBS=$(sysctl -n hw.ncpu)
STEP=${1:-all}

[ -d "$CX_SRC/wine" ] || { echo "missing $CX_SRC; run scripts/fetch-third-party.sh" >&2; exit 1; }
. "$RUNNERS/toolchain/env.sh"

# Runners are x86_64 (PRD §4). On Apple Silicon the build runs natively and only
# the compiler targets x86_64; test programs and Wine's own build tools come out
# x86_64 and run under Rosetta automatically, so configure scripts still work.
# Xcode's clang for the Mac side, by full path (llvm-mingw has its own `clang`).
CC="$(xcrun -f clang) -arch x86_64"
OBJC=$CC
# The /usr/bin shims normally set these; calling clang directly needs them explicit.
SDKROOT=$(xcrun --show-sdk-path)
MACOSX_DEPLOYMENT_TARGET=14.0 # PRD §4 minimum
export CC OBJC SDKROOT MACOSX_DEPLOYMENT_TARGET
run() { "$@"; }

# Libraries Wine loads at runtime. Each one is built into $DEPS (with headers
# for Wine's configure), then bundle_libs copies the shared libraries into the
# runner and rewrites their links to @loader_path, so the runner is relocatable.

# GNU nettle 3.10. The archive's gnutls/nettle is the same 3.10 code (every
# shared file is identical) but lacks configure/Makefile.in, so it can't be
# built as shipped; the GNU release adds only those generated files.
NETTLE=3.10
NETTLE_SHA256=b4c518adb174e484cb4acea54118f02380c7133771e7e9beb98a0787194ee47c

# FreeType is compiled from a fixed file list (freetype/docs/INSTALL.ANY), because
# its configure wrapper writes into the source tree, which stays read-only.
# The list matches the modules in include/freetype/config/ftmodule.h; zlib is
# FreeType's bundled copy, and PNG/HarfBuzz/Brotli/bzip2 are off (ftoption.h defaults).
FREETYPE_SOURCES="
  base/ftsystem.c base/ftinit.c base/ftdebug.c base/ftbase.c base/ftbbox.c
  base/ftglyph.c base/ftbdf.c base/ftbitmap.c base/ftcid.c base/ftfstype.c
  base/ftgasp.c base/ftgxval.c base/ftmm.c base/ftotval.c base/ftpatent.c
  base/ftpfr.c base/ftstroke.c base/ftsynth.c base/fttype1.c base/ftwinfnt.c
  autofit/autofit.c truetype/truetype.c type1/type1.c cff/cff.c cid/type1cid.c
  pfr/pfr.c type42/type42.c winfonts/winfnt.c pcf/pcf.c bdf/bdf.c psaux/psaux.c
  psnames/psnames.c pshinter/pshinter.c sfnt/sfnt.c smooth/smooth.c
  raster/raster.c sdf/sdf.c svg/svg.c cache/ftcache.c gzip/ftgzip.c lzw/ftlzw.c
"

deps_freetype() {
  ft=$CX_SRC/freetype
  obj=$RUNNERS/build/freetype-x86_64
  rm -rf "$obj" && mkdir -p "$obj" "$DEPS/lib" "$DEPS/include/freetype2"
  for f in $FREETYPE_SOURCES; do
    $CC -O2 -fPIC -DFT2_BUILD_LIBRARY -I"$ft/include" -c "$ft/src/$f" \
      -o "$obj/$(echo "$f" | tr / _).o" &
  done
  wait
  $CC -dynamiclib -o "$DEPS/lib/libfreetype.6.dylib" \
    -install_name "$DEPS/lib/libfreetype.6.dylib" "$obj"/*.o
  ln -sf libfreetype.6.dylib "$DEPS/lib/libfreetype.dylib" # for -lfreetype
  cp -R "$ft/include/ft2build.h" "$ft/include/freetype" "$DEPS/include/freetype2/"
}

# Out-of-tree autotools build into $DEPS. Usage: autotools_build <name> <srcdir> [configure args]
autotools_build() {
  name=$1 src=$2
  shift 2
  echo "== $name"
  dir=$RUNNERS/build/$name-x86_64
  rm -rf "$dir" && mkdir -p "$dir"
  (cd "$dir" &&
    run "$src/configure" --quiet --prefix="$DEPS" --host=x86_64-apple-darwin \
      --enable-shared --disable-static "$@" &&
    run make -s -j"$JOBS" &&
    run make -s install)
}

deps_gnutls() {
  # --host without a CPU model keeps GMP's assembly generic x86_64, not tuned
  # to the build machine.
  autotools_build gmp "$CX_SRC/gnutls/gmp" --disable-cxx

  archive=$RUNNERS/toolchain/downloads/nettle-$NETTLE.tar.gz
  [ -f "$archive" ] || curl -fsSL --retry 3 "https://mirrors.kernel.org/gnu/nettle/nettle-$NETTLE.tar.gz" -o "$archive"
  echo "$NETTLE_SHA256  $archive" | shasum -a 256 -c - >/dev/null || {
    echo "checksum mismatch for $archive; delete it and retry" >&2
    exit 1
  }
  nettle_src=$RUNNERS/build/src/nettle-$NETTLE
  rm -rf "$nettle_src" && mkdir -p "$nettle_src"
  tar xzf "$archive" -C "$nettle_src" --strip-components=1
  autotools_build nettle "$nettle_src" --disable-documentation --disable-openssl \
    --with-include-path="$DEPS/include" --with-lib-path="$DEPS/lib"

  # Only what Wine's schannel/bcrypt need; no p11-kit, IDN, or compression.
  # Each *_LIBS must be a single word: gnutls's m4/hooks.m4 tests them unquoted
  # (`test x$NETTLE_LIBS != x`), which silently drops the nettle backend
  # otherwise. Library paths go in LDFLAGS (libtool drops bare .dylib paths).
  autotools_build gnutls "$CX_SRC/gnutls/gnutls" \
    CPPFLAGS="-I$DEPS/include" LDFLAGS="-L$DEPS/lib" \
    NETTLE_CFLAGS="-I$DEPS/include" NETTLE_LIBS=-lnettle \
    HOGWEED_CFLAGS="-I$DEPS/include" HOGWEED_LIBS=-lhogweed \
    GMP_CFLAGS="-I$DEPS/include" GMP_LIBS=-lgmp \
    --with-included-libtasn1 --with-included-unistring --without-p11-kit \
    --without-idn --without-zlib --without-brotli --without-zstd \
    --without-tpm --without-tpm2 --disable-doc --disable-manpages \
    --disable-tests --disable-tools --disable-cxx --disable-nls --disable-libdane
}

# Copy $DEPS's shared libraries into the runner, named and linked by
# @loader_path, so nothing points back into runners/build/.
bundle_libs() {
  mkdir -p "$DIST/lib"
  for lib in "$DEPS"/lib/*.dylib; do
    [ -L "$lib" ] && continue
    leaf=$(basename "$(otool -D "$lib" | tail -1)")
    out=$DIST/lib/$leaf
    cp "$lib" "$out" && chmod u+w "$out"
    install_name_tool -id "@loader_path/$leaf" "$out"
    otool -L "$out" | awk 'NR > 1 { print $1 }' | grep "^$DEPS/lib/" | while read -r dep; do
      install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$out"
    done
    codesign --force --sign - "$out" 2>/dev/null
    echo "bundled $leaf"
  done
}

deps() { deps_freetype && deps_gnutls && bundle_libs; }


# Copy the Wine sources (an instant clone on APFS) and apply patches/*.patch in order.
patch_source() {
  rm -rf "$SRC" && mkdir -p "$(dirname "$SRC")"
  cp -Rc "$CX_SRC/wine" "$SRC" 2>/dev/null || cp -R "$CX_SRC/wine" "$SRC"
  for p in "$RUNNERS"/patches/*.patch; do
    [ -f "$p" ] || continue
    echo "applying $(basename "$p")"
    patch -d "$SRC" -p1 --forward --quiet < "$p"
  done
}

configure() {
  [ -d "$SRC" ] || patch_source
  mkdir -p "$BUILD"
  cd "$BUILD"
  run "$SRC/configure" \
    FREETYPE_CFLAGS="-I$DEPS/include/freetype2" \
    FREETYPE_LIBS="-L$DEPS/lib -lfreetype" \
    GNUTLS_CFLAGS="-I$DEPS/include" \
    GNUTLS_LIBS="-L$DEPS/lib -lgnutls" \
    --prefix="$DIST" \
    --host=x86_64-apple-darwin \
    --enable-archs=i386,x86_64 \
    --with-mingw=llvm-mingw \
    --without-x \
    "$@"
}

build() { cd "$BUILD" && run make -j"$JOBS"; }

# Bundle wine-gecko and wine-mono so Wine never offers to download them at
# runtime (ADR 0008). Versions and SHA-256s come from Wine's own appwiz.cpl,
# so they always match the Wine we build. Wine finds them in share/wine/.
addons() {
  dl=$RUNNERS/toolchain/downloads
  mkdir -p "$dl"
  awk '/#define (GECKO|MONO)_ARCH "/ { gsub(/"/, "", $3); arch = $3 }
       /#define (GECKO|MONO)_VERSION "/ { gsub(/"/, "", $3); split($2, n, "_"); ver[n[1]] = $3 }
       /#define (GECKO|MONO)_SHA "[0-9a-f]/ { gsub(/"/, "", $3); split($2, n, "_"); print n[1], ver[n[1]], arch, $3 }' \
    "$CX_SRC/wine/dlls/appwiz.cpl/addons.c" |
  while read -r name version arch sha; do
    kind=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    file=wine-$kind-$version-$arch.msi
    if [ ! -f "$dl/$file" ]; then
      curl -fsSL --retry 3 "https://dl.winehq.org/wine/wine-$kind/$version/$file" -o "$dl/$file.part"
      mv "$dl/$file.part" "$dl/$file"
    fi
    echo "$sha  $dl/$file" | shasum -a 256 -c - >/dev/null || {
      echo "checksum mismatch for $file; delete it and retry" >&2
      exit 1
    }
    mkdir -p "$DIST/share/wine/$kind"
    cp "$dl/$file" "$DIST/share/wine/$kind/"
    echo "bundled $file"
  done
}
install() { cd "$BUILD" && run make install; }

# DXMT (D3D10/11 -> Metal), the upstream author's release build. Building it
# ourselves needs full Xcode with the Metal toolchain and LLVM 15
# (docs/DEVELOPMENT.md upstream). v0.80 is the last MIT release; later ones are
# LGPL, which also works for us.
DXMT=v0.80
DXMT_SHA256=8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d

# winemetal goes into Wine's own folders: winemetal.so links @rpath/winemac.so,
# and new prefixes get its system32 stub from there. d3d11/dxgi/d3d10core (and
# the nvapi/nvngx extras) go into lib/dxmt/, which a launch puts in front of
# Wine's builtins with WINEDLLPATH_PREPEND (patches/0002) when DXMT is selected.
components() {
  archive=$RUNNERS/toolchain/downloads/dxmt-$DXMT-builtin.tar.gz
  [ -f "$archive" ] ||
    curl -fsSL --retry 3 "https://github.com/3Shain/dxmt/releases/download/$DXMT/dxmt-$DXMT-builtin.tar.gz" -o "$archive"
  echo "$DXMT_SHA256  $archive" | shasum -a 256 -c - >/dev/null || {
    echo "checksum mismatch for $archive; delete it and retry" >&2
    exit 1
  }
  tmp=$RUNNERS/build/dxmt-$DXMT
  rm -rf "$tmp" && mkdir -p "$tmp" && tar xzf "$archive" -C "$tmp" --strip-components=1
  rm -rf "$DIST/lib/dxmt"
  for arch in x86_64-windows i386-windows; do
    mkdir -p "$DIST/lib/dxmt/$arch"
    for f in "$tmp/$arch"/*.dll; do
      case $(basename "$f") in
        winemetal.dll) cp "$f" "$DIST/lib/wine/$arch/" ;;
        *) cp "$f" "$DIST/lib/dxmt/$arch/" ;;
      esac
    done
  done
  cp "$tmp/x86_64-unix/winemetal.so" "$DIST/lib/wine/x86_64-unix/"
  echo "bundled DXMT $DXMT"
}

case $STEP in
  deps) deps ;;
  source) patch_source ;;
  configure) shift || true; configure "$@" ;;
  build) build ;;
  install) install ;;
  addons) addons ;;
  components) components ;;
  all) deps && patch_source && configure && build && install && addons && components ;;
  *) echo "unknown step: $STEP" >&2; exit 2 ;;
esac
