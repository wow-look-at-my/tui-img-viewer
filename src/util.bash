# Small helpers with no terminal or file-system state.

die() {
	printf '%s: %s\n' "$PROG" "$*" >&2
	exit 1
}

# Sets NOW to the wall clock in milliseconds. It does not fork.
now_ms() {
	local t=$EPOCHREALTIME
	NOW=$(( ${t%[.,]*} * 1000 + 10#${t#*[.,]} / 1000 ))
}

# Shows a message in the footer for a short time.
status() {
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
	local out= used=0 i ch cp cw
	for (( i = 0; i < n; i++ )); do
		ch=${s:i:1}
		printf -v cp '%d' "'$ch"
		char_width "$cp"
		cw=$REPLY
		if (( cw == 0 )); then
			out+=$ch
			continue
		fi
		# The last character can use the cell that the ellipsis needs.
		if (( used + cw > w )) || (( used + cw == w && i < n - 1 )); then
			out+=…
			(( used++ ))
			break
		fi
		out+=$ch
		(( used += cw ))
	done
	printf -v REPLY '%s%*s' "$out" $(( w - used )) ''
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
	printf -v REPLY '%*s' "$1" ''
	REPLY=${REPLY// /$2}
}
