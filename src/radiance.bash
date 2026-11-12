# Decoder for Radiance HDR pictures (.hdr). Older ffmpeg versions cannot read
# them, so this piece expands the run-length data in bash. It writes planes
# (green, blue, red, exponent), which ffmpeg reads as raw video and turns
# into display colors.

# Expands the scan line that starts at RAD_POS in RAD_HEX, and moves RAD_POS
# behind it. RAD_HEX holds a few characters for each byte: a space and hex
# digits. With $2 = 1 the channels go to RAD_LINE as hex text.
radiance_row() {
	local width=$1 emit=$2 ch filled byte code n pad line
	for ch in 0 1 2 3; do
		filled=0 line=''
		while (( filled < width )); do
			byte=${RAD_HEX:RAD_POS * 3 + 1:2}
			[[ -n $byte ]] || return 1
			code=$(( 16#$byte ))
			(( RAD_POS++ ))
			if (( code > 128 )); then
				# A run: one value, repeated.
				n=$(( code - 128 ))
				if (( emit )); then
					printf -v pad '%*s' "$n" ''
					line+=${pad// /${RAD_HEX:RAD_POS * 3:3}}
				fi
				(( RAD_POS++ ))
			else
				# Literal bytes.
				n=$code
				(( n > 0 )) || return 1
				(( emit )) && line+=${RAD_HEX:RAD_POS * 3:n * 3}
				(( RAD_POS += n ))
			fi
			(( filled += n ))
		done
		(( filled == width )) || return 1
		RAD_LINE[ch]=$line
	done
	return 0
}

# radiance_planes FILE OFFSET WIDTH HEIGHT STEP OUT
# Decodes every STEP-th scan line of the pixel data at OFFSET and writes the
# planes to the file OUT. Sets RAD_ROWS to the count of lines in OUT and
# RAD_FORMAT to the ffmpeg pixel format of OUT.
radiance_planes() {
	local file=$1 offset=$2 width=$3 height=$4 step=$5 out=$6
	# Byte offsets into strings need the C locale.
	local LC_ALL=C
	local hex marker i ch
	local -a rows
	RAD_ROWS=0 RAD_FORMAT=gbrap RAD_LINE=()

	hex=$(od -An -v -tx1 -j "$offset" -- "$file") || return 1
	hex=${hex//$'\n'/}
	# A file with no run-length coding holds a few bytes for each pixel.
	if (( ${#hex} / 3 == width * height * 4 )) && [[ ${hex:0:6} != ' 02 02' ]]; then
		tail -c "+$(( offset + 1 ))" -- "$file" > "$out" || return 1
		RAD_ROWS=$height RAD_FORMAT=rgba
		return 0
	fi
	# The run-length coding has this width limit.
	(( width >= 8 && width < 32768 )) || return 1

	# Each scan line starts with a marker that holds the width. A cut at
	# the markers finds the lines without a walk through all the data.
	printf -v marker ' 02 02 %02x %02x' $(( width >> 8 )) $(( width & 255 ))
	mapfile -t rows <<< "${hex//"$marker"/$'\n'}"
	local fast=1
	(( ${#rows[@]} == height + 1 )) && [[ -z ${rows[0]} ]] || fast=0

	# Each plane collects its lines as hex text.
	local -a plane=('' '' '' '')
	if (( fast )); then
		for (( i = 0; i < height; i += step )); do
			RAD_HEX=${rows[i + 1]} RAD_POS=0
			# A marker pattern inside the data gives a line of the wrong size.
			if ! radiance_row "$width" 1 || (( RAD_POS * 3 != ${#RAD_HEX} )); then
				fast=0
				break
			fi
			for ch in 0 1 2 3; do
				plane[ch]+=${RAD_LINE[ch]}
			done
			(( RAD_ROWS++ ))
		done
	fi
	if (( ! fast )); then
		# The slow way: walk every scan line in order.
		plane=('' '' '' '')
		RAD_HEX=$hex RAD_POS=0 RAD_ROWS=0
		for (( i = 0; i < height; i++ )); do
			[[ ${RAD_HEX:RAD_POS * 3:12} == "$marker" ]] || return 1
			(( RAD_POS += 4 ))
			if (( i % step )); then
				radiance_row "$width" 0 || return 1
				continue
			fi
			radiance_row "$width" 1 || return 1
			for ch in 0 1 2 3; do
				plane[ch]+=${RAD_LINE[ch]}
			done
			(( RAD_ROWS++ ))
		done
	fi
	(( RAD_ROWS > 0 )) || return 1
	# The plane order of the pixel format: green, blue, red, then the exponent.
	for ch in 1 2 0 3; do
		printf '%b' "${plane[ch]// /\\x}"
	done > "$out"
}

# Sets REPLY to the ffmpeg filter that turns the planes into display colors:
# mantissa and exponent become a linear value, and the sRGB curve follows.
radiance_filter() {
	local ch expr=''
	for ch in r g b; do
		expr+="$ch='st(0,$ch(X,Y)*pow(2,alpha(X,Y)-136));"
		expr+="255*clip(if(lte(ld(0),0.0031308),12.92*ld(0),1.055*pow(ld(0),1/2.4)-0.055),0,1)':"
	done
	REPLY="geq=${expr}a=255"
}
