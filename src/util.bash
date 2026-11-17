# Small helpers with no terminal or file-system state.

die() {
	printf '%s: %s\n' "$PROG" "$*" >&2
	exit 1
}

# now_ms sets NOW to a clock in milliseconds. It does not fork.
if [[ -n ${EPOCHREALTIME-} ]]; then
	now_ms() {
		local t=$EPOCHREALTIME
		NOW=$(( ${t%[.,]*} * 1000 + 10#${t#*[.,]} / 1000 ))
	}
else
	# An older bash has no clock. Linux gives the uptime in hundredths of a second.
	now_ms() {
		local t
		read -r t _ < /proc/uptime
		NOW=$(( 10#${t%.*} * 1000 + 10#${t#*.} * 10 ))
	}
fi

# Shows a message in the footer for a short time.
status() {
	# A message can come before the loop runs, when NOW still holds its start value.
	now_ms
	STATUS=$1 STATUS_AT=$NOW D_FOOTER=1
}

# Sets REPLY to a byte count in a short form, for example "3.4 MiB".
human_size() {
	local n=$1 unit
	if (( n < 1024 )); then
		REPLY="$n B"
		return
	fi
	for unit in KiB MiB GiB TiB; do
		if (( n < 1048576 )) || [[ $unit == TiB ]]; then
			REPLY="$(( n / 1024 )).$(( n % 1024 * 10 / 1024 )) $unit"
			return
		fi
		(( n /= 1024 ))
	done
}

# Succeeds when the file name $1 has the extension of an image format.
is_image() {
	local rc=1
	shopt -s nocasematch
	case $1 in
		*.png | *.jpg | *.jpeg | *.jpe | *.jfif | *.gif | *.webp | *.bmp | *.tif | *.tiff) rc=0 ;;
		*.exr | *.hdr | *.avif | *.heic | *.heif | *.jxl | *.ico | *.tga | *.ppm | *.pgm | *.pbm | *.pnm | *.qoi | *.svg) rc=0 ;;
	esac
	shopt -u nocasematch
	return "$rc"
}

# Reads the lines of the file $2 into the array with the name $1.
read_lines() {
	local line
	local -a lines=()
	while IFS= read -r line || [[ -n $line ]]; do
		lines+=("$line")
	done < "$2"
	eval "$1=(\"\${lines[@]}\")"
}

# Sets REPLY to the local date and time of the time stamp $1.
time_text() {
	if (( TIME_BUILTIN )); then
		printf -v REPLY '%(%Y-%m-%d %H:%M)T' "$1"
	else
		REPLY=$(date "$DATE_OPT" "$DATE_PRE$1" '+%Y-%m-%d %H:%M' 2>/dev/null) || REPLY='?'
	fi
}

# The program runs in the C locale, so a string is a row of bytes on every
# host. These helpers read the UTF-8 code in those bytes.

# Sets U_CP to the code point at byte $1 of U_S, and U_LEN to its byte count.
# A byte that is not UTF-8 gives a negative code point.
utf8_at() {
	local i=$1 b n k
	printf -v b '%d' "'${U_S:i:1}"
	(( b &= 255 ))
	U_LEN=1
	if (( b < 0x80 )); then
		U_CP=$b
		return
	elif (( b >= 0xC2 && b < 0xE0 )); then
		n=1 U_CP=$(( b & 0x1F ))
	elif (( b >= 0xE0 && b < 0xF0 )); then
		n=2 U_CP=$(( b & 0x0F ))
	elif (( b >= 0xF0 && b < 0xF5 )); then
		n=3 U_CP=$(( b & 0x07 ))
	else
		U_CP=-1
		return
	fi
	for (( k = 1; k <= n; k++ )); do
		printf -v b '%d' "'${U_S:i + k:1}"
		if (( (b & 0xC0) != 0x80 )); then
			U_CP=-1
			return
		fi
		U_CP=$(( U_CP << 6 | b & 0x3F ))
	done
	U_LEN=$(( n + 1 ))
}

# Sets REPLY to the UTF-8 bytes of the code point $1.
utf8_char() {
	local cp=$1 esc
	if (( cp < 0x80 )); then
		printf -v esc '\\x%02x' "$cp"
	elif (( cp < 0x800 )); then
		printf -v esc '\\x%02x\\x%02x' $(( 0xC0 | cp >> 6 )) $(( 0x80 | cp & 0x3F ))
	elif (( cp < 0x10000 )); then
		printf -v esc '\\x%02x\\x%02x\\x%02x' $(( 0xE0 | cp >> 12 )) $(( 0x80 | cp >> 6 & 0x3F )) $(( 0x80 | cp & 0x3F ))
	else
		printf -v esc '\\x%02x\\x%02x\\x%02x\\x%02x' $(( 0xF0 | cp >> 18 )) $(( 0x80 | cp >> 12 & 0x3F )) \
			$(( 0x80 | cp >> 6 & 0x3F )) $(( 0x80 | cp & 0x3F ))
	fi
	printf -v REPLY '%b' "$esc"
}

# Sets REPLY to the cell width of the code point in $1.
char_width() {
	local cp=$1
	REPLY=1
	(( cp < 0x300 )) && return
	if (( (cp >= 0x300 && cp <= 0x36F) || (cp >= 0x1AB0 && cp <= 0x1AFF) ||
		(cp >= 0x200B && cp <= 0x200F) || (cp >= 0x20D0 && cp <= 0x20FF) ||
		(cp >= 0xFE00 && cp <= 0xFE0F) )); then
		REPLY=0
	elif (( (cp >= 0x1100 && cp <= 0x115F) || (cp >= 0x2E80 && cp <= 0xA4CF) ||
		(cp >= 0xAC00 && cp <= 0xD7A3) || (cp >= 0xF900 && cp <= 0xFAFF) ||
		(cp >= 0xFE30 && cp <= 0xFE6F) || (cp >= 0xFF00 && cp <= 0xFF60) ||
		(cp >= 0xFFE0 && cp <= 0xFFE6) || (cp >= 0x1F300 && cp <= 0x1FAFF) ||
		(cp >= 0x20000 && cp <= 0x3FFFD) )); then
		REPLY=2
	fi
}

# Sets REPLY to $1 cut or padded to exactly $2 cells. A cut ends in an ellipsis.
fit() {
	local s=${1//[[:cntrl:]]/?} w=$2
	if (( w <= 0 )); then
		REPLY=
		return
	fi
	local n=${#s}
	if [[ $s != *[!\ -~]* ]]; then
		if (( n > w )); then
			REPLY="${s:0:w-1}…"
		else
			printf -v REPLY '%-*s' "$w" "$s"
		fi
		return
	fi
	local out='' used=0 i=0 ch cw
	U_S=$s
	while (( i < n )); do
		utf8_at "$i"
		ch=${s:i:U_LEN}
		(( i += U_LEN ))
		# A broken byte and a control code of the upper range show as "?".
		if (( U_CP < 0 || (U_CP >= 0x80 && U_CP < 0xA0) )); then
			ch='?' cw=1
		else
			char_width "$U_CP"
			cw=$REPLY
		fi
		if (( cw == 0 )); then
			out+=$ch
			continue
		fi
		# The last character can use the cell that the ellipsis needs.
		if (( used + cw > w )) || (( used + cw == w && i < n )); then
			out+=…
			(( used++ ))
			break
		fi
		out+=$ch
		(( used += cw ))
	done
	printf -v REPLY '%s%*s' "$out" $(( w - used )) ''
}

# Sets REPLY to the count of cells that the text $1 covers.
text_width() {
	REPLY=${#1}
	[[ $1 != *[!\ -~]* ]] && return
	local i=0 n=${#1} cells=0
	U_S=$1
	while (( i < n )); do
		utf8_at "$i"
		(( i += U_LEN ))
		REPLY=1
		(( U_CP >= 0x300 )) && char_width "$U_CP"
		(( cells += REPLY ))
	done
	REPLY=$cells
}

# Sets REPLY to the end of $1 that fits $2 cells. A cut starts with an ellipsis.
fit_tail() {
	local s=$1 w=$2 i=0
	text_width "$s"
	local cells=$REPLY
	REPLY=$s
	(( cells > w && w > 1 )) || return 0
	U_S=$s
	while (( cells > w - 1 && i < ${#s} )); do
		utf8_at "$i"
		(( i += U_LEN ))
		REPLY=1
		(( U_CP >= 0x300 )) && char_width "$U_CP"
		(( cells -= REPLY ))
	done
	REPLY="…${s:i}"
}

# Sets FIT_W and FIT_H to the size of $1 x $2 shrunk into $3 x $4. It never enlarges.
fit_px() {
	local w=$1 h=$2 bw=$3 bh=$4
	FIT_W=$w FIT_H=$h
	if (( w > bw || h > bh )); then
		if (( w * bh > h * bw )); then
			FIT_W=$bw FIT_H=$(( h * bw / w ))
		else
			FIT_H=$bh FIT_W=$(( w * bh / h ))
		fi
	fi
	(( FIT_W < 1 )) && FIT_W=1
	(( FIT_H < 1 )) && FIT_H=1
	return 0
}

# Sets REPLY to a line of $1 copies of the string $2.
repeat() {
	# An old bash keeps the value when printf -v writes an empty text.
	REPLY=
	printf -v REPLY '%*s' "$1" ''
	REPLY=${REPLY// /$2}
}
