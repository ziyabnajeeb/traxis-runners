# Traxis runners

Wine builds for [Traxis](https://github.com/ziyabnajeeb), a Mac app for running Windows programs.
Traxis downloads these itself and checks each file against a SHA-256 checksum built into the app.

| Runner | Archive SHA-256 |
|---|---|
| `cx-26.3.0-r5` | `9354e617782bd8020bc6af19c09ed4d538cee2684f109e4b0ab2ad5187a4e62d` |

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
- GStreamer 1.24.12 for video and audio (Media Foundation), all built from these release
  archives; GLib, GStreamer and FFmpeg are LGPL 2.1 or later (FFmpeg without its GPL parts),
  PCRE2 is BSD, libffi MIT, proxy-libintl LGPL:
  - GLib 2.82.5: https://download.gnome.org/sources/glib/2.82/glib-2.82.5.tar.xz (SHA-256 `05c2031f9bdf6b5aba7a06ca84f0b4aced28b19bf1b50c6ab25cc675277cbc3f`)
  - PCRE2 10.44: https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.bz2 (SHA-256 `d34f02e113cf7193a1ebf2770d3ac527088d485d4e047ed10e5d217c6ef5de96`)
  - libffi 3.4.6: https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz (SHA-256 `b0dea9df23c863a7a50e825440f3ebffabd65df1497108e5d437747843895a4e`)
  - proxy-libintl 0.4: https://github.com/frida/proxy-libintl/archive/refs/tags/0.4.tar.gz (SHA-256 `13ef3eea0a3bc0df55293be368dfbcff5a8dd5f4759280f28e030d1494a5dffb`)
  - gstreamer 1.24.12: https://gstreamer.freedesktop.org/src/gstreamer/gstreamer-1.24.12.tar.xz (SHA-256 `b3522d1b4fe174fff3b3c7f0603493e2367bd1c43f5804df15b634bd22b1036f`)
  - gst-plugins-base 1.24.12: https://gstreamer.freedesktop.org/src/gst-plugins-base/gst-plugins-base-1.24.12.tar.xz (SHA-256 `f6efbaa8fea8d00bc380bccca76a530527b1f083e8523eafb3e9b1e18bc653d3`)
  - gst-plugins-good 1.24.12: https://gstreamer.freedesktop.org/src/gst-plugins-good/gst-plugins-good-1.24.12.tar.xz (SHA-256 `d0e66e2f935d1575f6adbef7d0a2b3faba7360344383c51bf0233b39e0489a64`)
  - gst-plugins-bad 1.24.12: https://gstreamer.freedesktop.org/src/gst-plugins-bad/gst-plugins-bad-1.24.12.tar.xz (SHA-256 `3d386af3d1dbd1a06c74a6251250c269b481e703f0e3255ba89ef6c1e063afea`)
  - gst-plugins-ugly 1.24.12: https://gstreamer.freedesktop.org/src/gst-plugins-ugly/gst-plugins-ugly-1.24.12.tar.xz (SHA-256 `19ed6eef4ea1a742234fb35e2cdb107168595a4dd409a9fac0b7a16543eee78b`)
  - gst-libav 1.24.12: https://gstreamer.freedesktop.org/src/gst-libav/gst-libav-1.24.12.tar.xz (SHA-256 `ef72c1c70a17b3c0bb283d16d09aba496d3401c927dcf5392a8a7866d9336379`)
  - FFmpeg 7.1.1: https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz (SHA-256 `733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1`)
- MoltenVK (Apache 2.0) and its SPIRV-Cross (Apache 2.0), from the CrossOver source archive
  (`moltenvk/`), with the patches in [`patches/moltenvk/`](patches/moltenvk/) and
  [`patches/spirv-cross/`](patches/spirv-cross/). Built with Xcode; its build fetches, at the
  revisions pinned in `moltenvk/ExternalRevisions`:
  - Vulkan-Headers (Apache 2.0): https://github.com/KhronosGroup/Vulkan-Headers at `fc6c06ac529e4b4b6e34c17cc650a8f62dee2eb0`
  - glslang (BSD and others): https://github.com/KhronosGroup/glslang at `fa9c3deb49e035a8abcabe366f26aac010f6cbfb`
  - Vulkan-Tools (Apache 2.0): https://github.com/KhronosGroup/Vulkan-Tools at `b47676a03827fc0c287409b243b1fd62886e79c0`
  - Volk (MIT): https://github.com/zeux/volk at `466085407d5d2f50583fd663c1d65f93a7709d3e`
  - cereal (BSD): https://github.com/USCiLab/cereal at `51cbda5f30e56c801c07fe3d3aba5d7fb9e6cca4`
- DXVK v1.10.3 (zlib), from the CrossOver source archive (`dxvk/`), with the patches in
  [`patches/dxvk/`](patches/dxvk/); its shaders compiled by glslang (above).
- Bundled add-ons, from WineHQ (https://dl.winehq.org/wine/):
- wine-gecko-2.47.4-x86.msi
- wine-gecko-2.47.4-x86_64.msi
- wine-mono-10.4.1-x86.msi

Build it yourself with the scripts in [`scripts/`](scripts/): `toolchain.sh`, then
`build-wine.sh`, `smoke-test.sh` and `package.sh`. They come from the Traxis source
tree and expect its layout: the CrossOver archive unpacked in `third_party/codeweavers/` and
these files in `runners/`.
