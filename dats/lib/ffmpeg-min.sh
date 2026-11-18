#!/usr/bin/env bash
# Builds a small ffmpeg in the directory $1 and puts it in $1/bin.
set -o errexit -o nounset -o pipefail

version=6.1.2
sha256=3b624649725ecdc565c903ca6643d41f33bd49239922e45c9b1442c63dca4e38

mkdir -p "$1"
dir=$(cd "$1" && pwd)

build_ffmpeg() {
	./configure --prefix="$1/out" --disable-doc --disable-ffplay --disable-ffprobe \
		--disable-gpl --disable-nonfree --disable-x86asm --disable-autodetect --enable-zlib \
		--disable-encoders --enable-encoder=mpeg4 --enable-encoder=png \
		--disable-decoders --enable-decoder=h264 --enable-decoder=mpeg4 --enable-decoder=png \
		--enable-decoder=aac --enable-decoder=alac --enable-decoder=mp3 --enable-decoder=mp3float \
		--disable-muxers --enable-muxer=h264 --enable-muxer=mov --enable-muxer=mp4 --enable-muxer=ogg \
		--disable-demuxers --enable-demuxer=h264 --enable-demuxer=mov \
		--disable-protocols --enable-protocol=file --disable-indevs --disable-outdevs
	make -j "$(nproc)"
	mkdir -p "$dir/bin"
	cp ffmpeg "$dir/bin/ffmpeg"
}

if [[ ! -x $dir/bin/ffmpeg ]]; then
	# shellcheck source=dats/lib/build-source.sh
	source "${BASH_SOURCE%/*}/build-source.sh"
	build_source "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz" "$sha256" build_ffmpeg
fi
# sed reads to the end, so the writer gets no broken pipe.
"$dir/bin/ffmpeg" -version | sed -n 1p
