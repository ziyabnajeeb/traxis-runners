#!/bin/sh
# Build Wine from the CodeWeavers sources into runners/build/ (git-ignored).
# Usage: runners/scripts/build-wine.sh [deps|gstreamer|vulkan|source|configure|build|install|addons|components|dxvk|all]   (default: all)
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
CXX="$(xcrun -f clang++) -arch x86_64" # for GStreamer's meson checks
OBJC=$CC
# The /usr/bin shims normally set these; calling clang directly needs them explicit.
SDKROOT=$(xcrun --show-sdk-path)
MACOSX_DEPLOYMENT_TARGET=14.0 # PRD §4 minimum
export CC CXX OBJC SDKROOT MACOSX_DEPLOYMENT_TARGET
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

# GStreamer, for Media Foundation video and audio (winegstreamer): games play
# their videos through it (CrossOver bundles it too). Only what Wine's
# decoders need, all LGPL: GLib, GStreamer core and base, good's MP4/Matroska/AVI
# demuxers and audio parsers, bad's video parsers, ugly's ASF demuxer (WMV and
# WMA files; gst-libav leaves FFmpeg's out), and gst-libav over an
# FFmpeg with decoders only (no GPL or nonfree parts). Checksums are the
# publishers' (.sha256sum files); FFmpeg publishes only a GPG signature, so
# its is the file as first downloaded over HTTPS from ffmpeg.org.
GLIB=2.82.5
GLIB_SHA256=05c2031f9bdf6b5aba7a06ca84f0b4aced28b19bf1b50c6ab25cc675277cbc3f
# GLib's dependencies (its meson wraps download from wrapdb, which isn't always
# reachable; these are the same projects' releases, checksums from their
# release notes; proxy-libintl publishes none).
PCRE2=10.44
PCRE2_SHA256=d34f02e113cf7193a1ebf2770d3ac527088d485d4e047ed10e5d217c6ef5de96
LIBFFI=3.4.6
LIBFFI_SHA256=b0dea9df23c863a7a50e825440f3ebffabd65df1497108e5d437747843895a4e
PROXY_LIBINTL=0.4
PROXY_LIBINTL_SHA256=13ef3eea0a3bc0df55293be368dfbcff5a8dd5f4759280f28e030d1494a5dffb
GST=1.24.12
GST_SHA256=b3522d1b4fe174fff3b3c7f0603493e2367bd1c43f5804df15b634bd22b1036f
GST_BASE_SHA256=f6efbaa8fea8d00bc380bccca76a530527b1f083e8523eafb3e9b1e18bc653d3
GST_GOOD_SHA256=d0e66e2f935d1575f6adbef7d0a2b3faba7360344383c51bf0233b39e0489a64
GST_BAD_SHA256=3d386af3d1dbd1a06c74a6251250c269b481e703f0e3255ba89ef6c1e063afea
GST_UGLY_SHA256=19ed6eef4ea1a742234fb35e2cdb107168595a4dd409a9fac0b7a16543eee78b
GST_LIBAV_SHA256=ef72c1c70a17b3c0bb283d16d09aba496d3401c927dcf5392a8a7866d9336379
FFMPEG=7.1.1
FFMPEG_SHA256=733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1

# Download (once, checked) and unpack into build/src/. Prints the source folder.
fetch_source() { # <url> <sha256> [file name, if the URL's isn't one]
  file=$RUNNERS/toolchain/downloads/${3:-$(basename "$1")}
  if [ ! -f "$file" ]; then
    curl -fsSL --retry 3 "$1" -o "$file.part" && mv "$file.part" "$file"
  fi
  echo "$2  $file" | shasum -a 256 -c - >/dev/null || {
    echo "checksum mismatch for $file; delete it and retry" >&2
    exit 1
  }
  src=$RUNNERS/build/src/$(basename "$file" | sed 's/\.tar\..*$//')
  rm -rf "$src" && mkdir -p "$src"
  tar xf "$file" -C "$src" --strip-components=1
  echo "$src"
}

# Meson build into $DEPS; dependencies come from $DEPS only, never downloaded.
meson_build() { # <name> <srcdir> [meson options]
  name=$1 src=$2
  shift 2
  obj=$RUNNERS/build/$name-x86_64
  rm -rf "$obj" "$obj.log"
  PKG_CONFIG_PATH=$DEPS/lib/pkgconfig run meson setup "$obj" "$src" --prefix="$DEPS" \
    --libdir=lib --buildtype=release -Ddefault_library=shared --wrap-mode=nofallback \
    -Dc_args="-arch x86_64 -I$DEPS/include" -Dc_link_args="-arch x86_64 -L$DEPS/lib" \
    -Dobjc_args="-arch x86_64 -I$DEPS/include" -Dobjc_link_args="-arch x86_64 -L$DEPS/lib" \
    -Dcpp_args="-arch x86_64 -I$DEPS/include" -Dcpp_link_args="-arch x86_64 -L$DEPS/lib" "$@" >"$obj.log" 2>&1 &&
    run ninja -C "$obj" install >>"$obj.log" 2>&1 || {
    tail -30 "$obj.log" >&2
    echo "$name failed; full log: $obj.log" >&2
    exit 1
  }
  echo "built $name"
}

deps_glib() {
  autotools_build pcre2 "$(fetch_source "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2/pcre2-$PCRE2.tar.bz2" "$PCRE2_SHA256")" \
    --disable-pcre2grep-jit --enable-jit
  autotools_build libffi "$(fetch_source "https://github.com/libffi/libffi/releases/download/v$LIBFFI/libffi-$LIBFFI.tar.gz" "$LIBFFI_SHA256")" \
    --disable-docs
  meson_build proxy-libintl "$(fetch_source "https://github.com/frida/proxy-libintl/archive/refs/tags/$PROXY_LIBINTL.tar.gz" "$PROXY_LIBINTL_SHA256" "proxy-libintl-$PROXY_LIBINTL.tar.gz")"
  meson_build glib "$(fetch_source "https://download.gnome.org/sources/glib/${GLIB%.*}/glib-$GLIB.tar.xz" "$GLIB_SHA256")" \
    -Dtests=false -Dintrospection=disabled -Dnls=disabled -Dlibmount=disabled \
    -Dselinux=disabled -Dxattr=false -Dman-pages=disabled -Ddocumentation=false \
    -Dsysprof=disabled -Dglib_debug=disabled
}

gst_url() { echo "https://gstreamer.freedesktop.org/src/$1/$1-$GST.tar.xz"; }

deps_gstreamer() {
  # Its tools include gst-plugin-scanner, which loads plugins in a separate
  # process (the runner bundles only that one).
  meson_build gstreamer "$(fetch_source "$(gst_url gstreamer)" "$GST_SHA256")" \
    -Dtests=disabled -Dexamples=disabled -Ddoc=disabled \
    -Dintrospection=disabled -Dnls=disabled -Dbash-completion=disabled \
    -Dlibunwind=disabled -Dlibdw=disabled -Dptp-helper=disabled -Dcheck=disabled \
    -Dbenchmarks=disabled
  # auto_features=disabled: only the plugins named here.
  meson_build gst-plugins-base "$(fetch_source "$(gst_url gst-plugins-base)" "$GST_BASE_SHA256")" \
    -Dauto_features=disabled -Dtests=disabled -Dexamples=disabled -Dtools=disabled \
    -Ddoc=disabled -Dintrospection=disabled -Dnls=disabled \
    -Dapp=enabled -Daudioconvert=enabled -Daudioresample=enabled -Dplayback=enabled \
    -Dtypefind=enabled -Dvideoconvertscale=enabled -Dvolume=enabled \
    -Doverlaycomposition=enabled
  meson_build gst-plugins-good "$(fetch_source "$(gst_url gst-plugins-good)" "$GST_GOOD_SHA256")" \
    -Dauto_features=disabled -Dtests=disabled -Dexamples=disabled -Ddoc=disabled -Dnls=disabled \
    -Disomp4=enabled -Dmatroska=enabled -Davi=enabled -Daudioparsers=enabled -Dwavparse=enabled \
    -Dautodetect=enabled -Dvideofilter=enabled -Ddeinterlace=enabled -Did3demux=enabled
  meson_build gst-plugins-bad "$(fetch_source "$(gst_url gst-plugins-bad)" "$GST_BAD_SHA256")" \
    -Dauto_features=disabled -Dtests=disabled -Dexamples=disabled -Ddoc=disabled -Dnls=disabled \
    -Dtools=disabled -Dintrospection=disabled -Dgpl=disabled -Dvideoparsers=enabled
  meson_build gst-plugins-ugly "$(fetch_source "$(gst_url gst-plugins-ugly)" "$GST_UGLY_SHA256")" \
    -Dauto_features=disabled -Dtests=disabled -Ddoc=disabled -Dnls=disabled \
    -Dgpl=disabled -Dasfdemux=enabled
}

# FFmpeg with decoders and parsers only, as shared libraries for gst-libav.
deps_ffmpeg() {
  src=$(fetch_source "https://ffmpeg.org/releases/ffmpeg-$FFMPEG.tar.xz" "$FFMPEG_SHA256")
  obj=$RUNNERS/build/ffmpeg-x86_64
  rm -rf "$obj" && mkdir -p "$obj"
  (cd "$obj" &&
    run "$src/configure" --prefix="$DEPS" --cc="$CC" --arch=x86_64 --enable-shared \
      --disable-static --disable-programs --disable-doc --disable-network --disable-autodetect \
      --disable-everything --disable-iconv --disable-securetransport \
      --disable-avdevice --disable-swscale \
      --enable-decoder=h264,hevc,mpeg1video,mpeg2video,mpeg4,msmpeg4v3,vp8,vp9,theora,wmv1,wmv2,wmv3,vc1 \
      --enable-decoder=aac,mp3,mp3float,mp2,vorbis,opus,flac,wmav1,wmav2,wmapro,adpcm_ms,adpcm_ima_wav \
      --enable-decoder='pcm_*' \
      --enable-parser=h264,hevc,mpegvideo,mpeg4video,vp8,vp9,vc1,aac,mpegaudio,vorbis,opus,flac \
      --enable-filter=aresample,format,null,anull >"$obj.log" 2>&1 &&
    run make -s -j"$JOBS" >>"$obj.log" 2>&1 &&
    run make -s install >>"$obj.log" 2>&1) || {
    tail -30 "$obj.log" >&2
    echo "ffmpeg failed; full log: $obj.log" >&2
    exit 1
  }
  echo "built ffmpeg"
  meson_build gst-libav "$(fetch_source "$(gst_url gst-libav)" "$GST_LIBAV_SHA256")" \
    -Dtests=disabled -Ddoc=disabled
}

# The libraries in $DEPS/lib something in the runner loads, starting from
# what Wine loads by name or links (FreeType, GnuTLS, winegstreamer's
# GStreamer libraries) and GStreamer's plugins, plus all they link in turn.
# Prints their file names.
# MoltenVK (Vulkan on Metal), from the archive's moltenvk/: Wine's
# winevulkan loads it at runtime, and DXVK and vkd3d run on it. Needs full
# Xcode (see docs/xcode-commands.md) and the network once: its own
# fetchDependencies clones the Khronos libraries at the revisions pinned in
# ExternalRevisions. SPIRV-Cross comes from the archive instead, because the
# script would look for it next to the git repo it sits in (ours), with
# patches/spirv-cross/ applied (and patches/moltenvk/ to MoltenVK). Kept out
# of $DEPS/lib so pointing configure at it changes nothing else.
MOLTENVK=$RUNNERS/build/deps-moltenvk
deps_moltenvk() {
  src=$RUNNERS/build/src/moltenvk
  built=$src/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib
  if [ ! -f "$built" ]; then
    rm -rf "$src" "$RUNNERS/build/src/spirv-cross"
    cp -R "$CX_SRC/moltenvk" "$src"
    for p in "$RUNNERS"/patches/moltenvk/*.patch; do
      echo "applying moltenvk/$(basename "$p")"
      patch -d "$src" -p1 --forward --quiet < "$p"
    done
    mv "$src/External/SPIRV-Cross" "$RUNNERS/build/src/spirv-cross"
    for p in "$RUNNERS"/patches/spirv-cross/*.patch; do
      echo "applying spirv-cross/$(basename "$p")"
      patch -d "$RUNNERS/build/src/spirv-cross" -p1 --forward --quiet < "$p"
    done
    log=$RUNNERS/build/moltenvk.log
    echo "building MoltenVK (log: $log)"
    if ! (cd "$src" && unset CC CXX OBJC &&
      ./fetchDependencies --macos --spirv-cross-root "$RUNNERS/build/src/spirv-cross" &&
      make macos) >"$log" 2>&1; then
      tail -20 "$log" >&2
      exit 1
    fi
  fi
  mkdir -p "$MOLTENVK/lib"
  # Runners are x86_64 (Apple Silicon runs them under Rosetta).
  lipo -thin x86_64 "$built" -output "$MOLTENVK/lib/libMoltenVK.dylib"
  install_name_tool -id "$MOLTENVK/lib/libMoltenVK.dylib" "$MOLTENVK/lib/libMoltenVK.dylib"
  # Xcode signed it; the changes above break that, and macOS refuses to
  # load a library with a broken signature. Sign it again (ad hoc).
  codesign -f -s - "$MOLTENVK/lib/libMoltenVK.dylib"
}
bundle_moltenvk() {
  out=$DIST/lib/libMoltenVK.dylib
  mkdir -p "$DIST/lib"
  cp "$MOLTENVK/lib/libMoltenVK.dylib" "$out" && chmod u+w "$out"
  install_name_tool -id "@loader_path/libMoltenVK.dylib" "$out"
  codesign -f -s - "$out"
  echo "bundled libMoltenVK.dylib"
}

needed_libs() {
  todo="$DEPS/lib/libfreetype.6.dylib $DEPS/lib/libgnutls.30.dylib"
  for lib in $(PKG_CONFIG_PATH=$DEPS/lib/pkgconfig pkg-config --libs-only-l $GST_WINE_PACKAGES); do
    todo="$todo $(ls "$DEPS"/lib/lib"${lib#-l}".*dylib | head -1)"
  done
  todo="$todo $(ls "$DEPS"/lib/gstreamer-1.0/*.dylib) $DEPS/libexec/gstreamer-1.0/gst-plugin-scanner"
  seen=""
  for f in $todo; do
    case $f in
      "$DEPS"/lib/gstreamer-1.0/*) ;;
      "$DEPS"/lib/*.dylib) seen="$seen $(basename "$(otool -D "$f" | tail -1)")" ;;
    esac
  done
  while [ -n "$todo" ]; do
    set -- $todo
    f=$1
    shift
    todo="$*"
    for dep in $(otool -L "$f" | awk 'NR > 1 { print $1 }' | grep "^$DEPS/lib/"); do
      case " $seen " in
        *" $(basename "$dep") "*) ;;
        *) seen="$seen $(basename "$dep")" todo="$todo $dep" ;;
      esac
    done
  done
  echo $seen | tr ' ' '\n' | sort -u
}
GST_WINE_PACKAGES="gstreamer-1.0 gstreamer-video-1.0 gstreamer-audio-1.0 gstreamer-tag-1.0"

# Copy those libraries into the runner, named and linked by @loader_path, so
# nothing points back into runners/build/.
bundle_libs() {
  mkdir -p "$DIST/lib"
  for leaf in $(needed_libs); do
    out=$DIST/lib/$leaf
    cp "$DEPS/lib/$leaf" "$out" && chmod u+w "$out"
    install_name_tool -id "@loader_path/$leaf" "$out"
    relink "$out" @loader_path
    echo "bundled $leaf"
  done
}

# GStreamer's plugins and plugin scanner, linked to the libraries bundle_libs
# put in lib/. runner.toml's [env] tells GStreamer where they are.
bundle_gstreamer() {
  rm -rf "$DIST/lib/gstreamer-1.0" "$DIST/libexec/gstreamer-1.0"
  mkdir -p "$DIST/lib/gstreamer-1.0" "$DIST/libexec/gstreamer-1.0"
  for f in "$DEPS"/lib/gstreamer-1.0/*.dylib "$DEPS/libexec/gstreamer-1.0/gst-plugin-scanner"; do
    case $f in
      *.dylib) out=$DIST/lib/gstreamer-1.0/$(basename "$f") to=@loader_path/.. ;;
      *) out=$DIST/libexec/gstreamer-1.0/$(basename "$f") to=@executable_path/../../lib ;;
    esac
    cp "$f" "$out" && chmod u+w "$out"
    case $f in *.dylib) install_name_tool -id "@loader_path/$(basename "$f")" "$out" ;; esac
    relink "$out" "$to"
  done
  echo "bundled GStreamer $GST ($(ls "$DIST/lib/gstreamer-1.0" | wc -l | tr -d ' ') plugins)"
}

# Points `file`'s links to $DEPS/lib at `to` (e.g. @loader_path/..) instead.
relink() { # <file> <to>
  otool -L "$1" | awk 'NR > 1 { print $1 }' | grep "^$DEPS/lib/" | while read -r dep; do
    install_name_tool -change "$dep" "$2/$(basename "$dep")" "$1"
  done
  # pkg-config's -rpath to $DEPS/lib means nothing on other Macs.
  otool -l "$1" | grep -q "path $DEPS/lib " && install_name_tool -delete_rpath "$DEPS/lib" "$1"
  codesign --force --sign - "$1" 2>/dev/null
}

deps() {
  deps_freetype && deps_gnutls && deps_glib && deps_gstreamer && deps_ffmpeg &&
    deps_moltenvk && bundle_libs && bundle_gstreamer && bundle_moltenvk
}


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

# DXVK (D3D9/10/11 on Vulkan, so on MoltenVK), from the archive's dxvk/:
# 1.10.3, the last line that runs on MoltenVK's Vulkan 1.2. Built for both
# Windows architectures with llvm-mingw, from a copy with patches/dxvk/
# applied. Its shaders are compiled by glslangValidator, built here from
# the glslang that deps_moltenvk fetched (cmake from the toolchain).
dxvk() {
  src=$RUNNERS/build/src/dxvk
  rm -rf "$src" && cp -R "$CX_SRC/dxvk" "$src"
  for p in "$RUNNERS"/patches/dxvk/*.patch; do
    echo "applying dxvk/$(basename "$p")"
    patch -d "$src" -p1 --forward --quiet < "$p"
  done
  glslang=$RUNNERS/build/glslang-host
  if [ ! -x "$glslang/bin/glslangValidator" ]; then
    [ -d "$RUNNERS/build/src/moltenvk/External/glslang" ] || deps_moltenvk
    (unset CC CXX OBJC &&
      cmake -S "$RUNNERS/build/src/moltenvk/External/glslang" -B "$glslang" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF \
        -DGLSLANG_ENABLE_INSTALL=OFF -DBUILD_SHARED_LIBS=OFF >/dev/null &&
      ninja -C "$glslang" glslang-standalone >/dev/null)
    # DXVK 1.10 looks for glslang's old name.
    mkdir -p "$glslang/bin" && ln -sf ../StandAlone/glslang "$glslang/bin/glslangValidator"
  fi
  rm -rf "$DIST/lib/dxvk"
  for arch in x86_64 i386; do
    case $arch in
      x86_64) triple=x86_64-w64-mingw32 family=x86_64 cpu=x86_64 ;;
      i386) triple=i686-w64-mingw32 family=x86 cpu=i686 ;;
    esac
    out=$RUNNERS/build/dxvk/$arch
    mkdir -p "$RUNNERS/build/dxvk"
    cat > "$RUNNERS/build/dxvk/cross-$arch.txt" <<CROSS
[binaries]
c = '$triple-clang'
cpp = '$triple-clang++'
ar = 'llvm-ar'
strip = 'llvm-strip'
windres = '$triple-windres'

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'windows'
cpu_family = '$family'
cpu = '$cpu'
endian = 'little'

[built-in options]
# DXVK 1.10.3 uses std::transform without <algorithm>, which older C++
# libraries included indirectly.
cpp_args = ['-include', 'algorithm']
CROSS
    log=$RUNNERS/build/dxvk/$arch.log
    echo "building DXVK $arch (log: $log)"
    if ! (unset CC CXX OBJC && export PATH="$glslang/bin:$PATH" &&
      { [ -f "$out/build.ninja" ] || meson setup "$out" "$src" --buildtype release \
          --cross-file "$RUNNERS/build/dxvk/cross-$arch.txt"; } &&
      meson setup --reconfigure "$out" "$src" >/dev/null && ninja -C "$out") >"$log" 2>&1; then
      tail -20 "$log" >&2
      exit 1
    fi
    mkdir -p "$DIST/lib/dxvk/$arch-windows"
    for dll in d3d9 d3d10 d3d10_1 d3d10core d3d11 dxgi; do
      cp "$(find "$out/src" -name "$dll.dll" | head -1)" "$DIST/lib/dxvk/$arch-windows/"
      # Wine only loads DLLs from its search path (patches/0002) if they are
      # marked as Wine builtins, as DXMT's are; Proton marks DXVK the same way.
      "$BUILD/tools/winebuild/winebuild" --builtin "$DIST/lib/dxvk/$arch-windows/$dll.dll"
    done
  done
  echo "bundled DXVK $(sed -n "s/.*version : '\(v[^']*\)'.*/\1/p" "$src/meson.build")"
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
    GSTREAMER_CFLAGS="$(PKG_CONFIG_PATH=$DEPS/lib/pkgconfig pkg-config --cflags $GST_WINE_PACKAGES)" \
    GSTREAMER_LIBS="$(PKG_CONFIG_PATH=$DEPS/lib/pkgconfig pkg-config --libs $GST_WINE_PACKAGES)" \
    LDFLAGS="-L$MOLTENVK/lib" \
    --prefix="$DIST" \
    --with-vulkan \
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
# Wine's Unix libraries that link bundled libraries (winegstreamer.so) find
# them in lib/, two folders up.
install() {
  cd "$BUILD" && run make install
  for so in "$DIST"/lib/wine/x86_64-unix/*.so; do
    otool -L "$so" | grep -q "$DEPS/lib/" && relink "$so" @loader_path/../..
  done
  return 0
}

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
  gstreamer) deps_glib && deps_gstreamer && deps_ffmpeg && bundle_libs && bundle_gstreamer ;;
  vulkan) deps_moltenvk && bundle_moltenvk ;;
  bundle) bundle_libs && bundle_gstreamer && bundle_moltenvk ;;
  source) patch_source ;;
  configure) shift || true; configure "$@" ;;
  build) build ;;
  install) install ;;
  addons) addons ;;
  components) components && dxvk ;;
  dxvk) dxvk ;;
  all) deps && patch_source && configure && build && install && addons && components && dxvk ;;
  *) echo "unknown step: $STEP" >&2; exit 2 ;;
esac
