# Traxis runners

Wine builds for [Traxis](https://github.com/ziyabnajeeb), a Mac app for running Windows programs.
Traxis downloads these itself and checks each file against a SHA-256 checksum built into the app.

| Runner | Archive SHA-256 |
|---|---|
| `cx-26.3.0-r2` | `a62ddbed4287f85d38c47f006259b1f0f9f18897ad82671a7447cd0ce6ab9af0` |

## Sources (LGPL)

Wine is licensed under the GNU LGPL 2.1 or later. Each runner is built from:

- CodeWeavers' CrossOver 26.3.0 source archive:
  https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz
  (SHA-256 `ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872`)
- The patches in [`patches/`](patches/), applied in order.
- nettle 3.10 (GNU): https://ftp.gnu.org/gnu/nettle/nettle-3.10.tar.gz (SHA-256 `b4c518adb174e484cb4acea54118f02380c7133771e7e9beb98a0787194ee47c`);
  FreeType, gnutls and GMP from the CrossOver source archive.
- DXMT v0.80 (MIT), the author's release build:
  https://github.com/3Shain/dxmt/releases/tag/v0.80 (SHA-256 `8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d`)
- Bundled add-ons, from WineHQ (https://dl.winehq.org/wine/):
- wine-gecko-2.47.4-x86.msi
- wine-gecko-2.47.4-x86_64.msi
- wine-mono-10.4.1-x86.msi

Build it yourself with the scripts in [`scripts/`](scripts/): `toolchain.sh`, then
`build-wine.sh`, `smoke-test.sh` and `package.sh`. They come from the Traxis source
tree and expect its layout: the CrossOver archive unpacked in `third_party/codeweavers/` and
these files in `runners/`.
