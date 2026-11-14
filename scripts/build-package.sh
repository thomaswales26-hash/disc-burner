#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-1.1.0}"
STAGE="$ROOT/package-root"
PACKAGE="$ROOT/dist/Disc-Burner-$VERSION.pkg"
PREFIX="$(brew --prefix)"
LIBEXEC="$STAGE/usr/local/libexec/disc-burner"
LIBRARIES="$LIBEXEC/lib"
DOCS="$STAGE/usr/local/share/doc/disc-burner"
SOURCES="$DOCS/third-party-source"

for tool in cdrdao cue2toc; do
    if [[ ! -x "$PREFIX/bin/$tool" ]]; then
        echo "Missing $tool. Install cdrdao with Homebrew before packaging." >&2
        exit 1
    fi
done

mkdir -p "$STAGE/usr/local/bin" "$LIBEXEC" "$LIBRARIES" "$SOURCES" "$ROOT/dist"
chmod -R u+w "$STAGE"
cmake -S "$ROOT" -B "$ROOT/build-package" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build "$ROOT/build-package" --parallel 2
cp "$ROOT/build-package/disc-burner" "$STAGE/usr/local/bin/disc-burner"
cp -L "$PREFIX/bin/cdrdao" "$PREFIX/bin/cue2toc" "$LIBEXEC/"
cp "$ROOT/README.md" "$DOCS/README.md"
python3 "$ROOT/scripts/relocate-cdrdao.py" "$LIBEXEC" "$LIBRARIES"

download_source() {
    local url="$1"
    local destination="$2"
    local checksum="$3"
    curl --silent --show-error --fail --location --retry 3 "$url" --output "$destination"
    printf '%s  %s\n' "$checksum" "$destination" | shasum -a 256 -c -
}

download_source \
    https://github.com/cdrdao/cdrdao/archive/refs/tags/rel_1_2_6.tar.gz \
    "$SOURCES/cdrdao-1.2.6.tar.gz" \
    ba3eadcae7b62a709e9e23988d7fb41f822c408dcec9bd99ff1a343d1bcbc524
download_source \
    https://gitlab.xiph.org/xiph/libao/-/archive/1.2.2/libao-1.2.2.tar.gz \
    "$SOURCES/libao-1.2.2.tar.gz" \
    df8a6d0e238feeccb26a783e778716fb41a801536fe7b6fce068e313c0e2bf4d
download_source \
    https://ftp.osuosl.org/pub/xiph/releases/ogg/libogg-1.3.6.tar.gz \
    "$SOURCES/libogg-1.3.6.tar.gz" \
    83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638
download_source \
    https://ftp.osuosl.org/pub/xiph/releases/vorbis/libvorbis-1.3.7.tar.xz \
    "$SOURCES/libvorbis-1.3.7.tar.xz" \
    b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b
download_source \
    https://codeberg.org/tenacityteam/libmad/releases/download/0.16.5/libmad-0.16.5.tar.gz \
    "$SOURCES/libmad-0.16.5.tar.gz" \
    f401b2ccf49c26ad0c3a6ef0179b1cbbff2406338b0603bb2033e6dcaf706114

cat > "$DOCS/THIRD_PARTY_NOTICES.txt" <<'EOF'
The installer bundles cdrdao 1.2.6 and runtime libraries used by its Homebrew
build. Corresponding upstream source archives are included in
third-party-source/:

* cdrdao 1.2.6 - GPL-2.0-or-later
  https://github.com/cdrdao/cdrdao/archive/refs/tags/rel_1_2_6.tar.gz
* libao 1.2.2 - GPL-2.0-or-later
  https://gitlab.xiph.org/xiph/libao/-/archive/1.2.2/libao-1.2.2.tar.gz
* libogg 1.3.6 - BSD-3-Clause
  https://ftp.osuosl.org/pub/xiph/releases/ogg/libogg-1.3.6.tar.gz
* libvorbis 1.3.7 - BSD-3-Clause
  https://ftp.osuosl.org/pub/xiph/releases/vorbis/libvorbis-1.3.7.tar.xz
* libmad 0.16.5 - GPL-2.0-or-later
  https://codeberg.org/tenacityteam/libmad/releases/download/0.16.5/libmad-0.16.5.tar.gz

The source archives contain the respective copyright and license texts.
EOF

chmod -R u+w "$STAGE"
xattr -cr "$STAGE"
pkgbuild --root "$STAGE" --identifier com.thomaswales26.disc-burner \
    --version "$VERSION" --install-location / "$PACKAGE"
echo "Created $PACKAGE"
