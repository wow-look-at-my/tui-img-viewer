#!/usr/bin/env bash
# Regenerates every fixture in dats/fixtures/meta/ for dats/metadata.dats.
# Needs ImageMagick convert. The output is deterministic for one tool version.
set -o errexit -o nounset -o pipefail

out=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/meta
mkdir -p "$out"
rm -f "$out"/*

im() {
	convert "$@"
}
src=(-size 40x30 gradient:red-blue)
alphasrc=(-size 40x30 gradient:red-blue -alpha set -channel A -fx 'i/w' +channel)
# Without these, PNG output carries the current time and is not deterministic.
nodate=(-strip -define png:exclude-chunks=date,time)

# --- byte helpers: values become hex text, hexbin writes the bytes ---
order=II
h16() {
	local v=$1
	if [[ $order == II ]]; then
		printf '%02x%02x' $((v & 255)) $((v >> 8 & 255))
	else
		printf '%02x%02x' $((v >> 8 & 255)) $((v & 255))
	fi
}
h32() {
	local v=$1
	if [[ $order == II ]]; then
		printf '%02x%02x%02x%02x' $((v & 255)) $((v >> 8 & 255)) $((v >> 16 & 255)) $((v >> 24 & 255))
	else
		printf '%02x%02x%02x%02x' $((v >> 24 & 255)) $((v >> 16 & 255)) $((v >> 8 & 255)) $((v & 255))
	fi
}
be32() {
	printf '%02x%02x%02x%02x' $(($1 >> 24 & 255)) $(($1 >> 16 & 255)) $(($1 >> 8 & 255)) $(($1 & 255))
}
le32() {
	printf '%02x%02x%02x%02x' $(($1 & 255)) $(($1 >> 8 & 255)) $(($1 >> 16 & 255)) $(($1 >> 24 & 255))
}
# ASCII text plus the NUL terminator.
asc() {
	local s=$1 i
	for ((i = 0; i < ${#s}; i++)); do
		printf '%02x' "'${s:i:1}"
	done
	printf '00'
}
rat() {
	h32 "$1"
	h32 "$2"
}
hexbin() {
	local hex=$1 i esc=""
	for ((i = 0; i < ${#hex}; i += 2)); do
		esc+="\\x${hex:i:2}"
	done
	printf '%b' "$esc"
}

# ifd START "TAG TYPE COUNT HEXDATA"... prints one IFD plus its value area. START
# is the IFD offset from the TIFF header; values a bounded number of bytes stay inline.
ifd() {
	local start=$1 spec tag type count data dlen ent dat="" doff
	shift
	doff=$((start + 2 + $# * 12 + 4))
	ent=$(h16 $#)
	for spec in "$@"; do
		read -r tag type count data <<<"$spec"
		dlen=$((${#data} / 2))
		ent+=$(h16 "$tag")$(h16 "$type")$(h32 "$count")
		if ((dlen <= 4)); then
			ent+=$data
			while ((${#data} < 8)); do
				data+=00
				ent+=00
			done
		else
			ent+=$(h32 "$doff")
			dat+=$data
			doff=$((doff + dlen))
		fi
	done
	printf '%s' "${ent}00000000$dat"
}

# tiffblock "IFD0 ENTRY"... -- "EXIF ENTRY"... prints a TIFF header, IFD0 with an
# Exif pointer (tag 0x8769) and the Exif sub-IFD.
tiffblock() {
	local -a ifd0=() exif=()
	local hdr ifd0hex exifoff
	while (($# > 0)) && [[ $1 != -- ]]; do
		ifd0+=("$1")
		shift
	done
	shift
	exif=("$@")
	if [[ $order == II ]]; then hdr=49492a0008000000; else hdr=4d4d002a00000008; fi
	ifd0hex=$(ifd 8 "${ifd0[@]}" "34665 4 1 $(h32 0)")
	exifoff=$((8 + ${#ifd0hex} / 2))
	ifd0hex=$(ifd 8 "${ifd0[@]}" "34665 4 1 $(h32 "$exifoff")")
	printf '%s%s%s' "$hdr" "$ifd0hex" "$(ifd "$exifoff" "${exif[@]}")"
}

# CRC-32 (IEEE) of hex text, for PNG chunks.
crc32() {
	local hex=$1 i k c=0xffffffff
	for ((i = 0; i < ${#hex}; i += 2)); do
		c=$((c ^ 0x${hex:i:2}))
		for ((k = 0; k < 8; k++)); do
			if ((c & 1)); then c=$(((c >> 1) ^ 0xedb88320)); else c=$((c >> 1)); fi
		done
	done
	be32 $((c ^ 0xffffffff))
}

# insert_after FILE OFFSET HEX OUT writes FILE with HEX inserted after OFFSET bytes.
insert_after() {
	{
		head -c "$2" "$1"
		hexbin "$3"
		tail -c +$(($2 + 1)) "$1"
	} >"$4"
}

# --- PNG ---
im "${src[@]}" "${nodate[@]}" PNG24:"$out/png-rgb.png"
im "${alphasrc[@]}" "${nodate[@]}" PNG32:"$out/png-rgba.png"
im -size 40x30 gradient:black-white -colorspace Gray -depth 16 "${nodate[@]}" \
	-define png:color-type=0 -define png:bit-depth=16 PNG:"$out/png-gray16.png"
im "${src[@]}" -colors 16 "${nodate[@]}" PNG8:"$out/png-palette.png"
im "${src[@]}" -interlace PNG "${nodate[@]}" PNG24:"$out/png-interlaced.png"
# PNG8 keeps binary transparency as a tRNS chunk next to the palette.
im "${src[@]}" -colors 8 -fill none -draw 'rectangle 0,0 9,9' "${nodate[@]}" PNG8:"$out/png-trns.png"
im -delay 10 "${src[@]}" -size 40x30 gradient:blue-red -loop 0 "${nodate[@]}" APNG:"$out/png-animated.png"
order=MM
exifhex=$(tiffblock "272 2 8 $(asc 'PNG Cam')" "274 3 1 $(h16 8)" -- "34855 3 1 $(h16 100)")
chunk=$(be32 $((${#exifhex} / 2)))65584966$exifhex
chunk+=$(crc32 "65584966$exifhex")
insert_after "$out/png-rgb.png" 33 "$chunk" "$out/png-exif.png"

# --- JPEG ---
im "${src[@]}" -strip -quality 80 JPEG:"$out/jpeg-baseline.jpg"
im "${src[@]}" -strip -quality 80 -interlace JPEG JPEG:"$out/jpeg-progressive.jpg"
im "${src[@]}" -strip -colorspace Gray -type Grayscale -quality 80 JPEG:"$out/jpeg-gray.jpg"

order=II
exifhex=$(tiffblock \
	"271 2 9 $(asc TestMake)" \
	"272 2 13 $(asc 'TestModel X1')" \
	"274 3 1 $(h16 6)" \
	-- \
	"33434 5 1 $(rat 1 120)" \
	"33437 5 1 $(rat 18 10)" \
	"34855 3 1 $(h16 64)" \
	"36867 2 20 $(asc '2025:08:01 10:22:11')" \
	"37386 5 1 $(rat 68 10)" \
	"42036 2 15 $(asc 'Test Lens 24mm')")
app1=ffe1$(printf '%04x' $((${#exifhex} / 2 + 8)))457869660000$exifhex
insert_after "$out/jpeg-baseline.jpg" 2 "$app1" "$out/jpeg-exif-le.jpg"

# Big endian: DateTime (0x0132) only, so the parser must fall back to it.
order=MM
exifhex=$(tiffblock \
	"271 2 8 $(asc 'BE Make')" \
	"274 3 1 $(h16 3)" \
	"306 2 20 $(asc '2024:02:29 23:59:58')" \
	-- \
	"33434 5 1 $(rat 5 2)" \
	"33437 5 1 $(rat 8 1)" \
	"34855 3 1 $(h16 200)" \
	"37386 5 1 $(rat 50 1)")
app1=ffe1$(printf '%04x' $((${#exifhex} / 2 + 8)))457869660000$exifhex
insert_after "$out/jpeg-baseline.jpg" 2 "$app1" "$out/jpeg-exif-be.jpg"

# The payload repeats FF D9 (EOI), so a byte scanner stops early and fails.
filler=""
for ((i = 0; i < 65533 / 2; i++)); do
	filler+='\xff\xd9'
done
filler+='\xff'
{
	head -c 2 "$out/jpeg-baseline.jpg"
	for ((i = 0; i < 4; i++)); do
		printf '\xff\xe2\xff\xff'
		printf '%b' "$filler"
	done
	tail -c +3 "$out/jpeg-baseline.jpg"
} >"$out/jpeg-big-app2.jpg"

# --- GIF, BMP ---
im "${src[@]}" -colors 16 GIF:"$out/gif89a.gif"
im "${src[@]}" -colors 4 GIF87:"$out/gif87a.gif"
im "${src[@]}" -type TrueColor BMP3:"$out/bmp-24.bmp"
im "${alphasrc[@]}" -define bmp:format=bmp4 BMP:"$out/bmp-32-topdown.bmp"
# IM writes bottom-up rows only; a negative height (a later offset) marks top-down.
printf '\xe2\xff\xff\xff' | dd of="$out/bmp-32-topdown.bmp" bs=1 seek=22 conv=notrunc status=none
im "${src[@]}" -colors 16 -type Palette BMP2:"$out/bmp-core.bmp"

# --- WebP ---
im "${src[@]}" -quality 80 WEBP:"$out/webp-lossy.webp"
im "${alphasrc[@]}" -define webp:lossless=true WEBP:"$out/webp-lossless-alpha.webp"
im "${alphasrc[@]}" -quality 80 WEBP:"$out/webp-vp8x-alpha.webp"
im -delay 10 "${src[@]}" -size 40x30 gradient:blue-red -loop 0 WEBP:"$out/webp-animated.webp"

# VP8X around the lossless bitstream plus an EXIF chunk (flags: EXIF 0x08, alpha 0x10).
order=II
exifhex=$(tiffblock "271 2 9 $(asc WebPMake)" "274 3 1 $(h16 5)" -- "34855 3 1 $(h16 400)")
vp8l=$(tail -c +13 "$out/webp-lossless-alpha.webp" | od -An -v -tx1 | tr -d ' \n')
body=57454250565038580a000000180000002700001d0000$vp8l
body+=45584946$(le32 $((${#exifhex} / 2)))$exifhex
(((${#exifhex} / 2) % 2)) && body+=00
hexbin "52494646$(le32 $((${#body} / 2)))$body" >"$out/webp-vp8x-exif.webp"

# --- TIFF ---
im "${src[@]}" -strip -compress LZW TIFF:"$out/tiff-le.tif"
im "${alphasrc[@]}" -strip -endian MSB -compress None TIFF:"$out/tiff-be-rgba.tif"
im -size 40x30 gradient:black-white -strip -colorspace Gray -depth 8 -compress Zip TIFF:"$out/tiff-gray-zip.tif"

# --- Negative cases ---
: >"$out/bad-empty.bin"
printf 'This is a plain text file, not an image.\n' >"$out/bad-text.txt"
head -c 20 "$out/png-rgb.png" >"$out/bad-png-trunc.png"
# Cut inside the EXIF APP1 segment, before any SOF.
head -c 120 "$out/jpeg-exif-le.jpg" >"$out/bad-jpeg-trunc.jpg"
printf '\xff\xd8' >"$out/bad-soi-only.jpg"
