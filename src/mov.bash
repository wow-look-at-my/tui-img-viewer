# A small ffmpeg build can have no image2 demuxer or muxer, but the mov format
# and the PNG codec.

# Appends the bytes of the 32-bit value $1 to MOV_E, as escapes for printf.
mov_u32() {
	printf -v REPLY '\\x%02x\\x%02x\\x%02x\\x%02x' \
		$(( $1 >> 24 & 255 )) $(( $1 >> 16 & 255 )) $(( $1 >> 8 & 255 )) $(( $1 & 255 ))
	MOV_E+=$REPLY
}

mov_u16() {
	printf -v REPLY '\\x%02x\\x%02x' $(( $1 >> 8 & 255 )) $(( $1 & 255 ))
	MOV_E+=$REPLY
}

# Appends $1 zero bytes.
mov_zero() {
	repeat "$1" '\x00'
	MOV_E+=$REPLY
}

# Appends those characters of the box type $1.
mov_type() {
	local i c
	for (( i = 0; i < 4; i++ )); do
		printf -v c '%d' "'${1:i:1}"
		printf -v REPLY '\\x%02x' "$c"
		MOV_E+=$REPLY
	done
}

# Puts MOV_E into a box of the type $1. Each byte in MOV_E is one escape of a few characters.
mov_box() {
	local body=$MOV_E
	MOV_E=
	mov_u32 $(( ${#body} / 4 + 8 ))
	mov_type "$1"
	MOV_E+=$body
}

# mov_wrap PNG WIDTH HEIGHT OUT writes a mov file with the PNG file as its one frame.
mov_wrap() {
	local png=$1 w=$2 h=$3 out=$4 size head stbl moov
	size=$(wc -c < "$png") || return 1
	size=${size//[!0-9]/}
	[[ -n $size ]] || return 1

	MOV_E=
	mov_type 'qt  '
	mov_u32 0x200
	mov_type 'qt  '
	mov_box ftyp
	# The data of the frame starts at a later byte: behind the bytes of ftyp and the head of mdat.
	mov_u32 $(( size + 8 ))
	mov_type mdat
	head=$MOV_E

	MOV_E=
	mov_zero 6
	mov_u16 1
	mov_zero 16
	mov_u16 "$w"
	mov_u16 "$h"
	mov_u32 0x480000
	mov_u32 0x480000
	mov_u32 0
	mov_u16 1
	mov_zero 32
	mov_u16 24
	mov_u16 0xffff
	mov_box 'png '
	local entry=$MOV_E
	MOV_E=
	mov_u32 0
	mov_u32 1
	MOV_E+=$entry
	mov_box stsd
	stbl=$MOV_E
	MOV_E=
	mov_u32 0
	mov_u32 1
	mov_u32 1
	mov_u32 1000
	mov_box stts
	stbl+=$MOV_E
	MOV_E=
	mov_u32 0
	mov_u32 1
	mov_u32 1
	mov_u32 1
	mov_u32 1
	mov_box stsc
	stbl+=$MOV_E
	MOV_E=
	mov_u32 0
	mov_u32 0
	mov_u32 1
	mov_u32 "$size"
	mov_box stsz
	stbl+=$MOV_E
	MOV_E=
	mov_u32 0
	mov_u32 1
	mov_u32 28
	mov_box stco
	stbl+=$MOV_E
	MOV_E=$stbl
	mov_box stbl
	stbl=$MOV_E

	MOV_E=
	mov_u32 1
	mov_u16 0x40
	mov_u16 0x8000
	mov_u16 0x8000
	mov_u16 0x8000
	mov_box vmhd
	local minf=$MOV_E
	MOV_E=
	mov_u32 1
	mov_box 'url '
	local url=$MOV_E
	MOV_E=
	mov_u32 0
	mov_u32 1
	MOV_E+=$url
	mov_box dref
	mov_box dinf
	minf+=$MOV_E$stbl
	MOV_E=$minf
	mov_box minf
	minf=$MOV_E

	MOV_E=
	mov_zero 12
	mov_u32 1000
	mov_u32 1000
	mov_u32 0
	mov_box mdhd
	local mdia=$MOV_E
	MOV_E=
	mov_u32 0
	mov_type mhlr
	mov_type vide
	mov_zero 13
	mov_box hdlr
	mdia+=$MOV_E$minf
	MOV_E=$mdia
	mov_box mdia
	mdia=$MOV_E

	# The matrix of a picture that is not turned.
	local matrix
	MOV_E=
	mov_u32 0x10000
	mov_zero 12
	mov_u32 0x10000
	mov_zero 12
	mov_u32 0x40000000
	matrix=$MOV_E

	MOV_E=
	mov_u32 3
	mov_zero 8
	mov_u32 1
	mov_zero 4
	mov_u32 1000
	mov_zero 16
	MOV_E+=$matrix
	mov_u32 $(( w << 16 ))
	mov_u32 $(( h << 16 ))
	mov_box tkhd
	MOV_E+=$mdia
	mov_box trak
	local trak=$MOV_E

	MOV_E=
	mov_zero 12
	mov_u32 1000
	mov_u32 1000
	mov_u32 0x10000
	mov_u16 0x100
	mov_zero 10
	MOV_E+=$matrix
	mov_zero 24
	mov_u32 2
	mov_box mvhd
	MOV_E+=$trak
	mov_box moov
	moov=$MOV_E

	{
		# shellcheck disable=SC2059 # the text holds only byte escapes
		printf "$head"
		cat -- "$png"
		# shellcheck disable=SC2059
		printf "$moov"
	} > "$out"
}

# mov_extract MOV OUT copies the data of the mdat box to OUT. ffmpeg writes
# one PNG frame there and nothing else.
mov_extract() {
	local file=$1 out=$2 off=0 end size hdr
	end=$(wc -c < "$file") || return 1
	end=${end//[!0-9]/}
	[[ -n $end ]] || return 1
	while (( off + 8 <= end )); do
		meta_read "$file" "$off" 16 || return 1
		meta_be32 0
		size=$META_N hdr=8
		if (( size == 1 )); then
			meta_be32 8
			(( META_N == 0 )) || return 1
			meta_be32 12
			size=$META_N hdr=16
		elif (( size == 0 )); then
			size=$(( end - off ))
		fi
		(( size >= hdr )) || return 1
		if (( META_B[4] == 109 && META_B[5] == 100 && META_B[6] == 97 && META_B[7] == 116 )); then
			tail -c +$(( off + hdr + 1 )) -- "$file" | head -c $(( size - hdr )) > "$out"
			return
		fi
		(( off += size ))
	done
	return 1
}
