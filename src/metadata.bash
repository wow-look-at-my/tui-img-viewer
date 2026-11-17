# Image header parser: reads the format, size and EXIF tags of an image file without decoding pixels.

# The results. Each key K has a variable META_K, and an empty one means: not known.
META_KEYS='alpha bits color data_offset datetime detail exposure fnumber focal format height iso lens make model orientation scan_order width'
# Bytes of the last read, its file offset, and scratch results of the helpers.
META_B=()
META_BOFF=0 META_EOF=0 META_I=0 META_N=0 META_D=0 META_LE=0 META_XPTR=0
META_S=""
# TIFF image tags, kept until meta_tiff derives color and alpha from them.
META_TPHOTO=-1 META_TSPP=-1 META_TEXTRA=0 META_TCOMP=-1

# Empties every result.
meta_clear() {
	local key
	for key in $META_KEYS; do
		printf -v "META_$key" ''
	done
}
meta_clear

# meta_read FILE OFFSET COUNT loads up to COUNT bytes into META_B.
meta_read() {
	local out
	META_B=()
	META_BOFF=$2
	META_EOF=1
	out=$(od -An -v -tu1 -j "$2" -N "$3" -- "$1" 2>/dev/null) || return 1
	IFS=$' \t\n' read -r -d '' -a META_B <<<"$out" || true
	((${#META_B[@]} == $3)) && META_EOF=0
	((${#META_B[@]} > 0))
}

# meta_need FILE OFFSET COUNT makes sure META_B holds the file bytes
# [OFFSET, OFFSET+COUNT) and sets META_I to the index of OFFSET.
meta_need() {
	local off=$2 cnt=$3 len
	if ((off < META_BOFF || off + cnt > META_BOFF + ${#META_B[@]})); then
		((off >= META_BOFF && META_EOF)) && return 1
		len=$cnt
		((len < 4096)) && len=4096
		meta_read "$1" "$off" "$len" || return 1
	fi
	((off + cnt <= META_BOFF + ${#META_B[@]})) || return 1
	META_I=$((off - META_BOFF))
}

# Integer readers on META_B indexes; the result goes to META_N.
meta_be16() {
	META_N=$((META_B[$1] << 8 | META_B[$1 + 1]))
}
meta_le16() {
	META_N=$((META_B[$1] | META_B[$1 + 1] << 8))
}
meta_be32() {
	META_N=$((META_B[$1] << 24 | META_B[$1 + 1] << 16 | META_B[$1 + 2] << 8 | META_B[$1 + 3]))
}
meta_le32() {
	META_N=$((META_B[$1] | META_B[$1 + 1] << 8 | META_B[$1 + 2] << 16 | META_B[$1 + 3] << 24))
}
meta_sle32() {
	meta_le32 "$1"
	((META_N < 0x80000000)) || META_N=$((META_N - 0x100000000))
}
# Readers in the TIFF byte order (META_LE).
meta_u16() {
	if ((META_LE)); then meta_le16 "$1"; else meta_be16 "$1"; fi
}
meta_u32() {
	if ((META_LE)); then meta_le32 "$1"; else meta_be32 "$1"; fi
}

# meta_str INDEX COUNT puts printable text from META_B into META_S. It stops at
# the first NUL, drops control bytes and trims trailing spaces.
meta_str() {
	local i=$1 end=$(($1 + $2)) b o c s=""
	for ((; i < end; i++)); do
		b=${META_B[i]}
		((b == 0)) && break
		((b < 32 || b == 127)) && continue
		printf -v o '%03o' "$b"
		printf -v c '%b' "\\0$o"
		s+=$c
	done
	META_S=${s%"${s##*[! ]}"}
}

# meta_find FILE OFFSET MAX BYTE puts the offset of the next BYTE into META_N.
# BYTE must come within MAX bytes.
meta_find() {
	local p=$2 end=$(($2 + $3)) i stop
	while ((p < end)); do
		meta_need "$1" "$p" 1 || return 1
		stop=$((META_BOFF + ${#META_B[@]}))
		((stop > end)) && stop=$end
		for ((i = META_I; p < stop; p++, i++)); do
			if ((META_B[i] == $4)); then
				META_N=$p
				return 0
			fi
		done
	done
	return 1
}

# meta_cstr FILE OFFSET MAX TERM is meta_find, and it also puts the text up to
# TERM into META_S. META_N gets the offset after TERM.
meta_cstr() {
	local p
	meta_find "$@" || return 1
	p=$META_N
	META_S=""
	if ((p > $2)); then
		meta_need "$1" "$2" $((p - $2)) || return 1
		meta_str "$META_I" $((p - $2))
	fi
	META_N=$((p + 1))
}

# meta_dec1 NUM DEN puts NUM/DEN with at most one fraction digit into META_S.
meta_dec1() {
	local t
	(($2 > 0)) || return 1
	t=$((($1 * 10 + $2 / 2) / $2))
	if ((t % 10)); then META_S=$((t / 10)).$((t % 10)); else META_S=$((t / 10)); fi
}

meta_detail() {
	META_detail=${META_detail:+${META_detail},}$1
}

# meta_num FILE OFFSET TYPE reads the first value of a TIFF field. A RATIONAL
# goes to META_N / META_D.
meta_num() {
	local n
	case $3 in
	1 | 7)
		meta_need "$1" "$2" 1 || return 1
		META_N=${META_B[META_I]}
		;;
	3)
		meta_need "$1" "$2" 2 || return 1
		meta_u16 "$META_I"
		;;
	4)
		meta_need "$1" "$2" 4 || return 1
		meta_u32 "$META_I"
		;;
	5)
		meta_need "$1" "$2" 8 || return 1
		meta_u32 $((META_I + 4))
		n=$META_N
		meta_u32 "$META_I"
		META_D=$n
		;;
	*) return 1 ;;
	esac
}

# meta_ascii FILE OFFSET COUNT reads the start of an ASCII field into META_S.
meta_ascii() {
	local cnt=$3
	((cnt > 255)) && cnt=255
	meta_need "$1" "$2" "$cnt" || return 1
	meta_str "$META_I" "$cnt"
	[[ -n $META_S ]]
}

# meta_tag FILE BASE TAG TYPE VOFF TIFF stores one IFD field in META. VOFF is
# relative to BASE. TIFF=1 also accepts the image structure tags.
meta_tag() {
	local f=$1 at=$(($2 + $5)) tag=$3 type=$4 tiff=$6
	case $tag in
	256 | 257 | 258 | 259 | 262 | 277)
		((tiff)) || return 0
		meta_num "$f" "$at" "$type" || return 0
		case $tag in
		256) ((META_N > 0)) && META_width=$META_N ;;
		257) ((META_N > 0)) && META_height=$META_N ;;
		258) ((META_N > 0)) && META_bits=$META_N ;;
		259) META_TCOMP=$META_N ;;
		262) META_TPHOTO=$META_N ;;
		277) META_TSPP=$META_N ;;
		esac
		;;
	338) ((tiff)) && META_TEXTRA=1 ;;
	271) [[ $type == 2 ]] && meta_ascii "$f" "$at" "$7" && META_make=$META_S ;;
	272) [[ $type == 2 ]] && meta_ascii "$f" "$at" "$7" && META_model=$META_S ;;
	42036) [[ $type == 2 ]] && meta_ascii "$f" "$at" "$7" && META_lens=$META_S ;;
	306)
		[[ $type == 2 && -z ${META_datetime-} ]] && meta_ascii "$f" "$at" "$7" && META_datetime=$META_S
		;;
	36867) [[ $type == 2 ]] && meta_ascii "$f" "$at" "$7" && META_datetime=$META_S ;;
	274)
		meta_num "$f" "$at" "$type" || return 0
		((META_N >= 1 && META_N <= 8)) && META_orientation=$META_N
		;;
	34855)
		meta_num "$f" "$at" "$type" || return 0
		((META_N > 0)) && META_iso=$META_N
		;;
	34665)
		meta_num "$f" "$at" "$type" || return 0
		META_XPTR=$META_N
		;;
	33434)
		[[ $type == 5 ]] && meta_num "$f" "$at" 5 || return 0
		((META_N > 0 && META_D > 0)) || return 0
		if ((META_N < META_D)); then
			META_exposure=1/$(((META_D + META_N / 2) / META_N))
		else
			meta_dec1 "$META_N" "$META_D" && META_exposure=$META_S
		fi
		;;
	33437 | 37386)
		[[ $type == 5 ]] && meta_num "$f" "$at" 5 || return 0
		((META_N > 0)) && meta_dec1 "$META_N" "$META_D" || return 0
		if ((tag == 33437)); then META_fnumber=$META_S; else META_focal=$META_S; fi
		;;
	esac
	return 0
}

# meta_ifd FILE BASE LIMIT OFFSET TIFF walks one IFD. BASE is the file offset of
# the TIFF header; OFFSET and every value offset must stay below LIMIT.
meta_ifd() {
	local f=$1 base=$2 lim=$3 off=$4 tiff=$5
	local n i e tag type cnt size voff
	((off >= 8 && off + 2 <= lim)) || return 1
	meta_need "$f" $((base + off)) 2 || return 1
	meta_u16 "$META_I"
	n=$META_N
	((n > 0 && n <= 1024 && off + 2 + n * 12 <= lim)) || return 1
	for ((i = 0; i < n; i++)); do
		meta_need "$f" $((base + off + 2 + i * 12)) 12 || return 1
		e=$META_I
		meta_u16 "$e"
		tag=$META_N
		meta_u16 $((e + 2))
		type=$META_N
		meta_u32 $((e + 4))
		cnt=$META_N
		case $type in
		1 | 2 | 6 | 7) size=1 ;;
		3 | 8) size=2 ;;
		4 | 9 | 11) size=4 ;;
		5 | 10 | 12) size=8 ;;
		*) continue ;;
		esac
		((cnt > 0 && cnt <= 1048576)) || continue
		size=$((size * cnt))
		if ((size <= 4)); then
			voff=$((off + 2 + i * 12 + 8))
		else
			meta_u32 $((e + 8))
			voff=$META_N
		fi
		((voff + size <= lim)) || continue
		meta_tag "$f" "$base" "$tag" "$type" "$voff" "$tiff" "$cnt"
	done
}

# meta_exif FILE BASE LIMIT TIFF parses a TIFF structure (an EXIF block or a
# whole TIFF file) that starts at BASE and is LIMIT bytes long.
meta_exif() {
	local f=$1 base=$2 lim=$3 tiff=$4 ifd0
	((lim >= 8)) || return 1
	meta_need "$f" "$base" 8 || return 1
	if ((META_B[META_I] == 73 && META_B[META_I + 1] == 73 && META_B[META_I + 2] == 42 && META_B[META_I + 3] == 0)); then
		META_LE=1
	elif ((META_B[META_I] == 77 && META_B[META_I + 1] == 77 && META_B[META_I + 2] == 0 && META_B[META_I + 3] == 42)); then
		META_LE=0
	else
		return 1
	fi
	meta_u32 $((META_I + 4))
	ifd0=$META_N
	META_XPTR=0
	meta_ifd "$f" "$base" "$lim" "$ifd0" "$tiff" || return 1
	((META_XPTR && META_XPTR != ifd0)) || return 0
	meta_ifd "$f" "$base" "$lim" "$META_XPTR" 0
	return 0
}

meta_png() {
	local f=$1 pos=33 i len type trns=0 actl=0
	meta_need "$f" 0 33 || return 1
	meta_be32 12
	((META_N == 0x49484452)) || return 1
	meta_be32 16
	META_width=$META_N
	meta_be32 20
	META_height=$META_N
	META_bits=${META_B[24]}
	case ${META_B[25]} in
	0) META_color=Gray ;;
	2) META_color=RGB ;;
	3) META_color=Palette ;;
	4) META_color=Gray+Alpha ;;
	6) META_color=RGBA ;;
	esac
	[[ ${META_B[25]} == [46] ]] && trns=1
	((META_B[28] == 1)) && meta_detail interlaced
	for ((i = 0; i < 1024; i++)); do
		meta_need "$f" "$pos" 8 || break
		meta_be32 "$META_I"
		len=$META_N
		meta_be32 $((META_I + 4))
		type=$META_N
		case $type in
		$((0x49444154)) | $((0x49454e44))) break ;;
		$((0x74524e53))) trns=1 ;;
		$((0x6163544c))) actl=1 ;;
		$((0x65584966))) meta_exif "$f" $((pos + 8)) "$len" 0 ;;
		esac
		pos=$((pos + 12 + len))
	done
	((actl)) && meta_detail animated
	META_alpha=$trns
	return 0
}

meta_jpeg() {
	local f=$1 pos=2 seg fill m len
	META_alpha=0
	for ((seg = 0; seg < 1024; seg++)); do
		meta_need "$f" "$pos" 2 || return 1
		((META_B[META_I] == 255)) || return 1
		# A marker can follow any number of 0xFF fill bytes.
		for ((fill = 0; fill < 65536; fill++)); do
			meta_need "$f" $((pos + 1)) 1 || return 1
			((META_B[META_I] == 255)) || break
			pos=$((pos + 1))
		done
		m=${META_B[META_I]}
		pos=$((pos + 2))
		((m == 0xd9 || m == 0xda || m == 0)) && return 1
		# Standalone markers carry no length: TEM, RSTn and SOI.
		((m == 1 || (m >= 0xd0 && m <= 0xd8))) && continue
		meta_need "$f" "$pos" 2 || return 1
		meta_be16 "$META_I"
		len=$META_N
		((len >= 2)) || return 1
		if ((m >= 0xc0 && m <= 0xcf && m != 0xc4 && m != 0xc8 && m != 0xcc)); then
			((len >= 8)) || return 1
			meta_need "$f" "$pos" 8 || return 1
			META_bits=${META_B[META_I + 2]}
			meta_be16 $((META_I + 3))
			META_height=$META_N
			meta_be16 $((META_I + 5))
			META_width=$META_N
			case ${META_B[META_I + 7]} in
			1) META_color=Gray ;;
			3) META_color=YCbCr ;;
			4) META_color=CMYK ;;
			esac
			case $m in
			192) meta_detail baseline ;;
			193) meta_detail extended ;;
			194) meta_detail progressive ;;
			195) meta_detail lossless ;;
			esac
			return 0
		fi
		# APP1 with "Exif\0\0"; the whole segment is loaded with one read.
		if ((m == 0xe1 && len >= 16)) && meta_need "$f" $((pos + 2)) $((len - 2)); then
			if ((META_B[META_I] == 69 && META_B[META_I + 1] == 120 && META_B[META_I + 2] == 105 &&
				META_B[META_I + 3] == 102 && META_B[META_I + 4] == 0 && META_B[META_I + 5] == 0)); then
				meta_exif "$f" $((pos + 8)) $((len - 8)) 0
			fi
		fi
		pos=$((pos + len))
	done
	return 1
}

meta_gif() {
	meta_need "$1" 0 13 || return 1
	meta_le16 6
	META_width=$META_N
	meta_le16 8
	META_height=$META_N
	META_bits=$(((META_B[10] & 7) + 1))
	META_color=Palette
	META_alpha=0
	if ((META_B[4] == 55)); then META_detail=GIF87a; else META_detail=GIF89a; fi
}

meta_bmp() {
	local f=$1 hs w h bpp comp=0 amask=0
	meta_need "$f" 0 26 || return 1
	meta_le32 14
	hs=$META_N
	if ((hs == 12)); then
		meta_le16 18
		w=$META_N
		meta_le16 20
		h=$META_N
		meta_le16 24
		bpp=$META_N
	elif ((hs >= 40 && hs <= 124)); then
		meta_need "$f" 0 70 || meta_need "$f" 0 54 || return 1
		meta_le32 18
		w=$META_N
		meta_le32 22
		h=$META_N
		meta_le16 28
		bpp=$META_N
		meta_le32 30
		comp=$META_N
		((w < 0x80000000)) || return 1
		# A negative height means top-down rows.
		((h >= 0x80000000)) && h=$((0x100000000 - h))
		# The alpha mask is in the V3+ header, or after a plain header for BI_ALPHABITFIELDS.
		if ((${#META_B[@]} >= 70 && (hs >= 56 || comp == 6))); then
			meta_le32 66
			amask=$META_N
		fi
	else
		return 1
	fi
	META_width=$w
	META_height=$h
	case $bpp in
	1 | 2 | 4 | 8)
		META_bits=$bpp
		META_color=Palette
		;;
	16) META_color=RGB ;;
	24)
		META_bits=8
		META_color=RGB
		;;
	32)
		META_bits=8
		if ((amask)); then META_color=RGBA; else META_color=RGB; fi
		;;
	esac
	if ((bpp == 32 && amask)); then META_alpha=1; else META_alpha=0; fi
	case $comp in
	0) ;;
	1) META_detail=BI_RLE8 ;;
	2) META_detail=BI_RLE4 ;;
	3) META_detail=BI_BITFIELDS ;;
	4) META_detail=BI_JPEG ;;
	5) META_detail=BI_PNG ;;
	6) META_detail=BI_ALPHABITFIELDS ;;
	11) META_detail=BI_CMYK ;;
	12) META_detail=BI_CMYKRLE8 ;;
	13) META_detail=BI_CMYKRLE4 ;;
	*) META_detail=$comp ;;
	esac
	return 0
}

meta_webp() {
	local f=$1 pos i type len flags=0 alpha=0 anim=0 exif=0 codec=""
	meta_need "$f" 0 30 || return 1
	meta_be32 12
	type=$META_N
	META_bits=8
	case $type in
	$((0x56503820)))
		((META_B[23] == 0x9d && META_B[24] == 1 && META_B[25] == 0x2a)) || return 1
		meta_le16 26
		META_width=$((META_N & 0x3fff))
		meta_le16 28
		META_height=$((META_N & 0x3fff))
		codec=lossy
		;;
	$((0x5650384c)))
		# "VP8L": the signature byte 0x2f, the sizes minus one, then the alpha bit.
		((META_B[20] == 0x2f)) || return 1
		meta_le32 21
		META_width=$(((META_N & 0x3fff) + 1))
		META_height=$((((META_N >> 14) & 0x3fff) + 1))
		alpha=$(((META_N >> 28) & 1))
		codec=lossless
		;;
	$((0x56503858)))
		# "VP8X": the flags, then the canvas size minus one.
		flags=${META_B[20]}
		alpha=$(((flags >> 4) & 1))
		anim=$(((flags >> 1) & 1))
		exif=$(((flags >> 3) & 1))
		META_width=$(((META_B[24] | META_B[25] << 8 | META_B[26] << 16) + 1))
		META_height=$(((META_B[27] | META_B[28] << 8 | META_B[29] << 16) + 1))
		pos=30
		for ((i = 0; i < 1024; i++)); do
			[[ -z $codec ]] || ((exif)) || break
			meta_need "$f" "$pos" 8 || break
			meta_be32 "$META_I"
			type=$META_N
			meta_le32 $((META_I + 4))
			len=$META_N
			case $type in
			$((0x56503820))) [[ -n $codec ]] || codec=lossy ;;
			$((0x5650384c))) [[ -n $codec ]] || codec=lossless ;;
			$((0x414e4d46)))
				# ANMF holds a frame header, then the chunks of that frame.
				pos=$((pos + 24))
				continue
				;;
			$((0x45584946)))
				exif=0
				# Some writers keep the JPEG "Exif\0\0" prefix.
				if meta_need "$f" $((pos + 8)) 6 && ((META_B[META_I] == 69 && META_B[META_I + 4] == 0)); then
					meta_exif "$f" $((pos + 14)) $((len - 6)) 0
				else
					meta_exif "$f" $((pos + 8)) "$len" 0
				fi
				;;
			esac
			pos=$((pos + 8 + len + (len & 1)))
		done
		;;
	*) return 1 ;;
	esac
	[[ -n $codec ]] && meta_detail "$codec"
	((anim)) && meta_detail animated
	META_alpha=$alpha
	if ((alpha)); then
		META_color=RGBA
	elif [[ $codec == lossy ]]; then
		META_color=YCbCr
	elif [[ $codec == lossless ]]; then
		META_color=RGB
	fi
	return 0
}

meta_tiff() {
	local alpha
	META_TPHOTO=-1 META_TSPP=-1 META_TEXTRA=0 META_TCOMP=-1
	# A TIFF file is one TIFF structure; od finds the real end of the file.
	meta_exif "$1" 0 0xffffffff 1 || return 1
	# An extra sample needs a second sample to sit next to.
	alpha=0
	((META_TEXTRA && (META_TSPP == -1 || META_TSPP >= 2))) && alpha=1
	META_alpha=$alpha
	case $META_TPHOTO in
	0 | 1) if ((alpha)); then META_color=Gray+Alpha; else META_color=Gray; fi ;;
	2) if ((alpha)); then META_color=RGBA; else META_color=RGB; fi ;;
	3) META_color=Palette ;;
	5) META_color=CMYK ;;
	6) META_color=YCbCr ;;
	esac
	case $META_TCOMP in
	-1) ;;
	1) META_detail=None ;;
	5) META_detail=LZW ;;
	6 | 7) META_detail=JPEG ;;
	8 | 32946) META_detail=Deflate ;;
	32773) META_detail=PackBits ;;
	*) META_detail=$META_TCOMP ;;
	esac
	return 0
}

# meta_chlist FILE OFFSET END walks an EXR channel list. META_S gets the names,
# each with a space on both sides, and META_N the pixel type of the first channel.
meta_chlist() {
	local f=$1 p=$2 end=$3 k names=" " ptype=-1
	for ((k = 0; k < 1024; k++)); do
		meta_cstr "$f" "$p" $((end - p)) 0 || return 1
		((META_N == p + 1)) && break
		names+="$META_S "
		p=$META_N
		((p + 16 <= end)) || return 1
		if ((ptype < 0)); then
			meta_need "$f" "$p" 4 || return 1
			meta_le32 "$META_I"
			ptype=$META_N
		fi
		p=$((p + 16))
	done
	((ptype >= 0)) || return 1
	META_S=$names
	META_N=$ptype
}

meta_exr() {
	local f=$1 pos=8 i ver name type size vpos x0 y0 ptype=-1 comp=-1 chans="" d
	local -a cnames=(none RLE ZIPS ZIP PIZ PXR24 B44 B44A DWAA DWAB)
	meta_need "$f" 0 8 || return 1
	meta_le32 4
	ver=$META_N
	(((ver & 255) == 2)) || return 1
	# A multi-part file ends its first header with the same NUL, so the walk reads only that part.
	for ((i = 0; i < 256; i++)); do
		meta_need "$f" "$pos" 1 || return 1
		((META_B[META_I])) || break
		meta_cstr "$f" "$pos" 256 0 || return 1
		name=$META_S
		meta_cstr "$f" "$META_N" 256 0 || return 1
		type=$META_S
		vpos=$((META_N + 4))
		meta_need "$f" "$META_N" 4 || return 1
		meta_le32 "$META_I"
		size=$META_N
		((size < 0x80000000 && vpos + size < 1048576)) || return 1
		case $name:$type in
		dataWindow:box2i)
			((size == 16)) && meta_need "$f" "$vpos" 16 || return 1
			meta_sle32 "$META_I"
			x0=$META_N
			meta_sle32 $((META_I + 4))
			y0=$META_N
			meta_sle32 $((META_I + 8))
			META_width=$((META_N - x0 + 1))
			meta_sle32 $((META_I + 12))
			META_height=$((META_N - y0 + 1))
			;;
		channels:chlist)
			meta_chlist "$f" "$vpos" $((vpos + size)) || return 1
			chans=$META_S
			ptype=$META_N
			;;
		compression:compression)
			((size >= 1)) && meta_need "$f" "$vpos" 1 || return 1
			comp=${META_B[META_I]}
			;;
		esac
		pos=$((vpos + size))
	done
	((i < 256 && ptype >= 0 && comp >= 0)) && [[ -n ${META_width-} ]] || return 1
	case $ptype in
	0) META_bits=32 && d=uint ;;
	1) META_bits=16 && d=half ;;
	2) META_bits=32 && d=float ;;
	*) return 1 ;;
	esac
	if ((comp < ${#cnames[@]})); then d="${cnames[comp]}, $d"; else d="$comp, $d"; fi
	((ver & 0x200)) && d+=", tiled"
	((ver & 0x1000)) && d+=", multi-part"
	((ver & 0x800)) && d+=", deep"
	META_detail=$d
	if [[ $chans == *" R "* && $chans == *" G "* && $chans == *" B "* ]]; then
		if [[ $chans == *" A "* ]]; then META_color=RGBA; else META_color=RGB; fi
	elif [[ $chans == *" Y "* && $chans == *" RY "* && $chans == *" BY "* ]]; then
		META_color=YCbCr
	elif [[ $chans == *" Y "* ]]; then
		if [[ $chans == *" A "* ]]; then META_color=Gray+Alpha; else META_color=Gray; fi
	fi
	if [[ $chans == *" A "* ]]; then META_alpha=1; else META_alpha=0; fi
	return 0
}

meta_hdr() {
	local f=$1 pos next line end fmt=RGBE expo=""
	local re='^([-+][XY]) +([0-9]{1,9}) +([-+][XY]) +([0-9]{1,9})$'
	# The text header, the resolution line included, must end within this many bytes.
	end=65536
	meta_find "$f" 0 "$end" 10 || return 1
	pos=$((META_N + 1))
	while :; do
		meta_find "$f" "$pos" $((end - pos)) 10 || return 1
		((META_N == pos)) && break
		next=$((META_N + 1))
		# Only FORMAT and EXPOSURE lines matter; the text of other lines is never built.
		meta_need "$f" "$pos" 1 || return 1
		if ((META_B[META_I] != 69 && META_B[META_I] != 70)); then
			pos=$next
			continue
		fi
		meta_cstr "$f" "$pos" $((next - pos)) 10 || return 1
		pos=$next
		line=$META_S
		case $line in
		FORMAT=32-bit_rle_rgbe) fmt=RGBE ;;
		FORMAT=32-bit_rle_xyze) fmt=XYZE ;;
		FORMAT=*) return 1 ;;
		EXPOSURE=*) [[ -n $expo ]] || expo=${line#EXPOSURE=} ;;
		esac
	done
	pos=$((META_N + 1))
	meta_cstr "$f" "$pos" $((end - pos)) 10 || return 1
	[[ $META_S =~ $re ]] || return 1
	[[ ${BASH_REMATCH[1]:1} != "${BASH_REMATCH[3]:1}" ]] || return 1
	if [[ ${BASH_REMATCH[1]} == ?Y ]]; then
		META_height=$((10#${BASH_REMATCH[2]}))
		META_width=$((10#${BASH_REMATCH[4]}))
	else
		META_width=$((10#${BASH_REMATCH[2]}))
		META_height=$((10#${BASH_REMATCH[4]}))
	fi
	META_scan_order="${BASH_REMATCH[1]} ${BASH_REMATCH[3]}"
	META_data_offset=$META_N
	META_color=RGB
	META_alpha=0
	expo=${expo#"${expo%%[! ]*}"}
	META_detail=$fmt${expo:+, exposure $expo}
	return 0
}

# meta_probe FILE fills META.
meta_probe() {
	local f=${1-} sig rc=1
	meta_clear
	META_B=()
	META_BOFF=0
	[[ -f $f && -r $f ]] || return 1
	meta_read "$f" 0 4096 || return 1
	printf -v sig '%02x' "${META_B[@]:0:12}"
	case $sig in
	89504e470d0a1a0a*) META_format=PNG && meta_png "$f" && rc=0 ;;
	ffd8*) META_format=JPEG && meta_jpeg "$f" && rc=0 ;;
	474946383[79]61*) META_format=GIF && meta_gif "$f" && rc=0 ;;
	424d*) META_format=BMP && meta_bmp "$f" && rc=0 ;;
	52494646????????57454250) META_format=WebP && meta_webp "$f" && rc=0 ;;
	49492a00* | 4d4d002a*) META_format=TIFF && meta_tiff "$f" && rc=0 ;;
	762f3101*) META_format=EXR && meta_exr "$f" && rc=0 ;;
	# "#?RADIANCE" or "#?RGBE", then a newline.
	233f52414449414e43450a* | 233f524742450a*) META_format=HDR && meta_hdr "$f" && rc=0 ;;
	esac
	META_B=()
	if ((rc == 0 && ${META_width:-0} > 0 && ${META_height:-0} > 0)); then
		META_alpha=${META_alpha:-0}
		return 0
	fi
	meta_clear
	return 1
}
