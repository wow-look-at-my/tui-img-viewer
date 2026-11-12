#!/usr/bin/env bash
# Regenerates the image files in dats/fixtures/browse/ for dats/tui.dats.
set -o errexit -o nounset -o pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out=$here/browse
mkdir -p "$out/sub"

render() {
	ffmpeg -nostdin -y -v error -f lavfi -i "$1" -frames:v 1 "${@:2}"
}

# Large enough that the last stage needs several windows on a slow link.
render testsrc2=size=1600x1200:rate=1 -q:v 4 "$out/big.jpg"
render testsrc=size=640x480:rate=1 "$out/small.png"
render smptebars=size=320x900:rate=1 "$out/tall.webp"
render rgbtestsrc=size=64x64:rate=1 "$out/sub/inner.png"
# This file carries camera data and an EXIF rotation.
cp "$here/meta/jpeg-exif-le.jpg" "$out/rotated.jpg"
dd if=/dev/zero of="$out/data.bin" bs=512 count=1 status=none
