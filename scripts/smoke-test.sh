#!/bin/sh
# Smoke-test a built runner: create a fresh prefix with wineboot, then run a
# 64-bit and a 32-bit console .exe and check their output and exit code.
# Usage: runners/scripts/smoke-test.sh [runner-dir]   (default: the build output)
set -eu
cd "$(dirname "$0")/.."
RUNNERS=$(pwd)
. "$RUNNERS/scripts/version.sh"
RUNNER=${1:-$RUNNERS/build/dist/$ID}
. "$RUNNERS/toolchain/env.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/traxis-smoke.XXXXXX")
trap 'WINEPREFIX=$WORK/prefix "$RUNNER/bin/wineserver" -k 2>/dev/null || true; rm -rf "$WORK"' EXIT

for arch in x86_64 i686; do
  "$arch-w64-mingw32-clang" -O2 -o "$WORK/hello-$arch.exe" tests/hello.c
  "$arch-w64-mingw32-clang" -O2 -o "$WORK/schannel-$arch.exe" tests/schannel.c -lsecur32
  "$arch-w64-mingw32-clang" -O2 -o "$WORK/d3d11-$arch.exe" tests/d3d11-info.c -ld3d11 -ldxgi -luuid
done

export WINEPREFIX=$WORK/prefix WINEDEBUG=-all
# Same as the [env] in runner.toml.in.
export DYLD_FALLBACK_LIBRARY_PATH="$RUNNER/lib:/usr/local/lib:/usr/lib"
# No `arch -x86_64` wrapper: wine is x86_64-only, so macOS runs it under Rosetta
# by itself, and /usr/bin/arch (a protected binary) would strip DYLD_* variables.
run() { "$@"; }

echo "== wineboot --init"
start=$(date +%s)
# wineboot installs the bundled wine-mono and wine-gecko silently. If one is
# missing, Wine shows a download prompt and waits forever, so time out instead.
# (Polls in 1 s steps so that killing it leaves no long-lived `sleep` behind.)
(
  i=0
  while [ $i -lt 300 ]; do sleep 1; i=$((i + 1)); done
  echo "FAIL: wineboot took over 5 minutes (download prompt?)" >&2
  "$RUNNER/bin/wineserver" -k
) &
watchdog=$!
run "$RUNNER/bin/wine" wineboot --init > "$WORK/boot.log" 2>&1
run "$RUNNER/bin/wineserver" -w
kill $watchdog 2>/dev/null || true
wait $watchdog 2>/dev/null || true
echo "   prefix created in $(( $(date +%s) - start ))s"
[ -f "$WINEPREFIX/system.reg" ] || { echo "FAIL: no system.reg" >&2; exit 1; }
if grep -q "cannot find the FreeType" "$WORK/boot.log"; then
  echo "FAIL: Wine could not load FreeType" >&2
  exit 1
fi
for dir in windows/mono windows/system32/gecko; do
  [ -d "$WINEPREFIX/drive_c/$dir" ] || { echo "FAIL: C:/$dir missing (add-on not installed)" >&2; exit 1; }
done
echo "   wine-mono and wine-gecko installed"

fail=0
for arch in x86_64 i686; do
  echo "== hello-$arch.exe"
  set +e
  out=$(run "$RUNNER/bin/wine" "$WORK/hello-$arch.exe" 2>&1)
  code=$?
  set -e
  echo "   $out"
  bits=$([ $arch = x86_64 ] && echo 64 || echo 32)
  if [ $code -ne 42 ] || ! echo "$out" | grep -q "hello from a $bits-bit"; then
    echo "FAIL: hello-$arch.exe (exit $code)" >&2
    fail=1
  fi
done
for arch in x86_64 i686; do
  echo "== schannel-$arch.exe"
  set +e
  out=$(run "$RUNNER/bin/wine" "$WORK/schannel-$arch.exe" 2>&1)
  code=$?
  set -e
  echo "   $out"
  [ $code -eq 0 ] || { echo "FAIL: schannel-$arch.exe (is gnutls bundled?)" >&2; fail=1; }
done

# DXMT (D3D11 -> Metal) if the runner bundles it; needs a Metal GPU.
if [ -d "$RUNNER/lib/dxmt" ]; then
  for arch in x86_64 i686; do
    echo "== d3d11-$arch.exe with DXMT"
    set +e
    out=$(WINEDLLPATH_PREPEND="$RUNNER/lib/dxmt" DXMT_LOG_PATH=none run "$RUNNER/bin/wine" \
      "$WORK/d3d11-$arch.exe" 2>&1 | grep -E "^(adapter|feature level|D3D11)")
    set -e
    echo "$out" | sed 's/^/   /'
    echo "$out" | grep -q "feature level: 11" || { echo "FAIL: DXMT did not give D3D11 (d3d11-$arch.exe)" >&2; fail=1; }
  done
fi

[ $fail -eq 0 ] && echo "PASS"
exit $fail
