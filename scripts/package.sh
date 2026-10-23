#!/bin/sh
# Package the built runner: write runner.toml, then a .tar.xz plus its SHA-256.
# Usage: runners/scripts/package.sh   (after build-wine.sh)
set -eu
cd "$(dirname "$0")/.."
. scripts/version.sh
DIST=build/dist/$ID
[ -x "$DIST/bin/wine" ] || { echo "no runner in $DIST; run build-wine.sh" >&2; exit 1; }

# List only the add-ons actually bundled (build-wine.sh addons).
addons=""
for kind in mono gecko; do
  if ls "$DIST/share/wine/$kind"/wine-$kind-*.msi >/dev/null 2>&1; then
    addons="$addons${addons:+, }\"wine-$kind\""
  fi
done

sed -e "s|@ID@|$ID|" \
    -e "s|@ADDONS@|$addons|" \
    -e "s|@VERSION@|CrossOver sources $CX_VERSION, revision $REVISION|" \
    -e "s|@SOURCE_URL@|https://media.codeweavers.com/pub/crossover/source/crossover-sources-$CX_VERSION.tar.gz|" \
    runner.toml.in > "$DIST/runner.toml"

# Bundled graphics components (build-wine.sh components). DXMT becomes the
# runner's D3D10/11 default (PRD §6.1); a bottle can still choose wined3d.
if [ -d "$DIST/lib/dxmt" ]; then
  cat >> "$DIST/runner.toml" <<'TOML'

[defaults.graphics]
d3d11 = "dxmt"

[[components]]
id = "dxmt"
kind = "graphics"
provides = ["d3d10", "d3d11"]
min_macos = "14.0"

[components.activate]
# Searched before Wine's own d3d11/dxgi (patches/0002). Logs go to stderr,
# which Traxis keeps in the bottle's log, instead of files next to the game.
env = { WINEDLLPATH_PREPEND = "{runner}/lib/dxmt", DXMT_LOG_PATH = "none" }
TOML
fi

# Wine's own headers are only needed to build Winelib apps.
rm -rf "$DIST/include"

tar -C build/dist -cJf "build/$ID.tar.xz" "$ID"
(cd build && shasum -a 256 "$ID.tar.xz" > "$ID.tar.xz.sha256")
cat "build/$ID.tar.xz.sha256"
du -h "build/$ID.tar.xz" | cut -f1
