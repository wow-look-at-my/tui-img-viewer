# Background preview jobs. One job reads one file and writes its results into
# its own directory.

# Starts a job in the background. Sets JOB_PID.
job_spawn() {
	job_main "$@" </dev/null >/dev/null 2>&1 &
	JOB_PID=$!
}

job_main() {
	local kind=$1
	JOB_OUT=$3 JOB_CHILD=0
	trap job_abort TERM
	case $kind in
		image) job_image "${@:2}" ;;
		dir) job_dir "$2" ;;
		file) job_file "$2" ;;
		*) job_other "$2" ;;
	esac
	: > "$JOB_OUT/done"
}

# The main loop stops a job with TERM. The job removes its own directory.
job_abort() {
	(( JOB_CHILD )) && kill "$JOB_CHILD" 2>/dev/null
	rm -rf -- "$JOB_OUT"
	exit 143
}

# Runs a command so that TERM can interrupt it. A trap does not run while
# the shell waits for a foreground command.
job_run() {
	"$@" &
	JOB_CHILD=$!
	wait "$JOB_CHILD"
	local rc=$?
	JOB_CHILD=0
	return "$rc"
}

# Writes the remaining arguments as lines to the result file $1.
job_write() {
	local name=$1
	shift
	printf '%s\n' "$@" > "$JOB_OUT/.$name" && mv -- "$JOB_OUT/.$name" "$JOB_OUT/$name"
}

# Appends the mode, the owner and the link target of $1 to INFO.
job_stat_lines() {
	local path=$1 text
	text=$(stat "${STAT_MODE[@]}" -- "$path" 2>/dev/null) && INFO+=("Mode"$'\t'"$text")
	if [[ -L $path ]]; then
		text=$(readlink -- "$path") && INFO+=("Link"$'\t'"→ $text")
	fi
	return 0
}

job_dir() {
	local path=$1 entry name count=0 images=0
	local -a INFO=() text=()
	shopt -s nullglob
	(( SHOW_HIDDEN )) && shopt -s dotglob
	for entry in "$path"/*; do
		(( count++ ))
		name=${entry##*/}
		is_image "$name" && (( images++ ))
		(( count > TEXT_LINES )) && continue
		[[ -d $entry ]] && name+=/
		text+=("${name//[[:cntrl:]]/?}")
	done
	INFO+=("Type"$'\t'"directory" "Items"$'\t'"$count, images: $images")
	job_stat_lines "$path"
	job_write info "${INFO[@]}"
	(( count == 0 )) && text=('(empty directory)')
	job_write text "${text[@]}"
}

job_file() {
	local path=$1 line
	local -a INFO=() text=() raw=()
	if (( HAVE_FILE )); then
		line=$(file -b -- "$path" 2>/dev/null) && INFO+=("Type"$'\t'"$line")
	fi
	job_stat_lines "$path"
	job_write info "${INFO[@]}"
	if [[ ! -r $path ]]; then
		text=('(not readable)')
	elif [[ ! -s $path ]]; then
		text=('(empty file)')
	elif grep -Iq '' -- "$path" 2>/dev/null; then
		mapfile -t -n "$TEXT_LINES" raw < <(head -c 65536 -- "$path")
		for line in "${raw[@]}"; do
			line=${line//$'\t'/    }
			text+=("${line//[[:cntrl:]]/}")
		done
	else
		text=('(binary file)')
	fi
	job_write text "${text[@]}"
}

job_other() {
	local -a INFO=()
	job_stat_lines "$1"
	(( ${#INFO[@]} )) && job_write info "${INFO[@]}"
	job_write text '(not a regular file)'
}

# Appends the detail lines of the probed image to INFO. $1 and $2 are the
# size after rotation.
job_meta_lines() {
	local w=$1 h=$2 line
	line=${META[format]-image}
	[[ -n ${META[color]-} ]] && line+=" · ${META[color]}"
	[[ -n ${META[bits]-} ]] && line+=" ${META[bits]}-bit"
	[[ -n ${META[detail]-} ]] && line+=" · ${META[detail]}"
	INFO+=("Type"$'\t'"$line")

	local a=$w b=$h t
	while (( b )); do
		t=$(( a % b )) a=$b b=$t
	done
	line="${w}×${h} · $(( w * h / 1000000 )).$(( w * h % 1000000 / 100000 )) MP"
	if (( w / a <= 32 && h / a <= 32 )); then
		line+=" · $(( w / a )):$(( h / a ))"
	else
		line+=" · $(( w / h )).$(( w * 100 / h % 100 / 10 ))$(( w * 100 / h % 10 )):1"
	fi
	(( ${META[orientation]:-1} > 1 )) && line+=" · EXIF rotation ${META[orientation]}"
	INFO+=("Image"$'\t'"$line")

	line=${META[make]-}
	if [[ -n ${META[model]-} ]]; then
		# Many cameras repeat the maker name in the model name.
		[[ -n $line && ${META[model]} != "$line"* ]] && line+=" ${META[model]}" || line=${META[model]}
	fi
	[[ -n $line ]] && INFO+=("Camera"$'\t'"$line")

	line=
	[[ -n ${META[fnumber]-} ]] && line+="f/${META[fnumber]} · "
	[[ -n ${META[exposure]-} ]] && line+="${META[exposure]} s · "
	[[ -n ${META[iso]-} ]] && line+="ISO ${META[iso]} · "
	[[ -n ${META[focal]-} ]] && line+="${META[focal]} mm · "
	[[ -n $line ]] && INFO+=("Shot"$'\t'"${line% · }")
	[[ -n ${META[datetime]-} ]] && INFO+=("Taken"$'\t'"${META[datetime]}")
	[[ -n ${META[lens]-} ]] && INFO+=("Lens"$'\t'"${META[lens]}")
	return 0
}

# Publishes the PNG file $2 as stage $1 with the pixel size $3 x $4.
job_stage() {
	local n=$1 png=$2 bytes
	# GNU base64 breaks its output into lines. The transfer needs one line.
	( set -o pipefail; base64 < "$png" | tr -d '\n' ) > "$JOB_OUT/.s$n.b64" || return 1
	bytes=$(wc -c < "$JOB_OUT/.s$n.b64") || return 1
	# BSD wc puts spaces before the count.
	job_write "s$n.dim" "$3 $4 $(( bytes ))"
	mv -- "$JOB_OUT/.s$n.b64" "$JOB_OUT/s$n.b64"
}

# job_image PATH OUT MAX_W MAX_H FILE_SIZE
# MAX_W x MAX_H is the pixel limit of the last stage. Zero means: details only.
job_image() {
	local path=$1 max_w=$3 max_h=$4 fsize=$5
	local -a INFO=()
	local w=0 h=0 orient=1 format=
	if meta_probe "$path"; then
		w=${META[width]} h=${META[height]} orient=${META[orientation]:-1} format=${META[format]}
		if (( orient >= 5 )); then
			local t=$w
			w=$h h=$t
		fi
		job_meta_lines "$w" "$h"
	elif (( HAVE_FFPROBE )) && job_ffprobe "$path"; then
		w=$PROBE_W h=$PROBE_H
		declare -A META=([format]=$PROBE_CODEC)
		job_meta_lines "$w" "$h"
	fi
	job_stat_lines "$path"
	job_write info "${INFO[@]}"
	if (( w < 1 || h < 1 )); then
		job_write err 'this image format is not recognized'
		return
	fi
	(( max_w > 0 )) || return 0

	# A PNG file that is small enough needs no decoder.
	local direct=0
	if [[ $format == PNG ]] && (( orient == 1 )); then
		(( w <= max_w && h <= max_h && fsize <= DIRECT_PNG_MAX )) && direct=1
		(( HAVE_FFMPEG )) || direct=1
	fi
	if (( direct )); then
		job_write geom "$w $h 1"
		job_stage 1 "$path" "$w" "$h" || job_write err 'cannot read the file'
		return
	fi
	if (( ! HAVE_FFMPEG )); then
		job_write err 'ffmpeg is not installed: only PNG files have a preview'
		return
	fi

	fit_px "$w" "$h" "$max_w" "$max_h"
	local out_w=$FIT_W out_h=$FIT_H
	fit_px "$w" "$h" "$THUMB_EDGE" "$THUMB_EDGE"
	local thumb_w=$FIT_W thumb_h=$FIT_H stages=1
	# A draft stage is useful only when the last stage is larger.
	(( out_w * 2 > thumb_w * 3 )) && stages=2
	job_write geom "$w $h $stages"

	local turn=
	case $orient in
		2) turn=hflip, ;;
		3) turn=hflip,vflip, ;;
		4) turn=vflip, ;;
		5) turn=transpose=0, ;;
		6) turn=transpose=1, ;;
		7) turn=transpose=3, ;;
		8) turn=transpose=2, ;;
	esac
	# ffmpeg reads the file through a link, so no file name can look like an option or a sequence pattern.
	ln -s -- "$path" "$JOB_OUT/src"
	local -a input=(-noautorotate -i "$JOB_OUT/src")
	case $format in
		EXR)
			# The picture holds linear light. The decoder applies the sRGB curve.
			input=(-apply_trc iec61966_2_1 -i "$JOB_OUT/src")
			;;
		HDR)
			if [[ ${META[scan_order]-} == '-Y +X' && $(ffmpeg -hide_banner -decoders 2>/dev/null) == *' hdr '* ]]; then
				# This ffmpeg reads the format. Its output is linear light, so the sRGB curve follows here.
				local curve='if(lte(val/maxval,0.0031308),12.92*val,(1.055*pow(val/maxval,1/2.4)-0.055)*maxval)'
				input=(-i "$JOB_OUT/src")
				turn="format=gbrp16le,lutrgb=r='$curve':g='$curve':b='$curve',"
			elif job_radiance "$path" "$w" "$h" "$out_w" "$out_h"; then
				input=(-f rawvideo -pixel_format "$RAD_FORMAT" -video_size "${w}x$RAD_ROWS" -i "$JOB_OUT/planes")
				turn=$RAD_FILTER
			else
				job_write err 'this Radiance file has a layout that the decoder does not know'
				return
			fi
			;;
	esac
	local pix='format=pix_fmts=rgb24|rgba|gray|ya8' graph
	local -a enc=(-frames:v 1 -c:v png -pred mixed -f image2 -update 1) outs
	if (( stages == 2 )); then
		graph="[0:v]${turn}split=2[a][b];"
		graph+="[a]scale=${thumb_w}:${thumb_h}:flags=bilinear,${pix}[t];"
		graph+="[b]scale=${out_w}:${out_h}:flags=lanczos,${pix}[f]"
		outs=(-map '[t]' "${enc[@]}" "$JOB_OUT/1.png" -map '[f]' "${enc[@]}" "$JOB_OUT/2.png")
	else
		graph="[0:v]${turn}scale=${out_w}:${out_h}:flags=lanczos,${pix}[f]"
		outs=(-map '[f]' "${enc[@]}" "$JOB_OUT/1.png")
	fi
	if ! job_run ffmpeg -nostdin -y -v error "${input[@]}" \
		-filter_complex "$graph" "${outs[@]}" 2> "$JOB_OUT/log"; then
		local reason=
		[[ -s $JOB_OUT/log ]] && reason=$(tail -n 1 -- "$JOB_OUT/log")
		job_write err "ffmpeg cannot decode this file: ${reason:-no message}"
		return
	fi
	if (( stages == 2 )); then
		job_stage 1 "$JOB_OUT/1.png" "$thumb_w" "$thumb_h" &&
			job_stage 2 "$JOB_OUT/2.png" "$out_w" "$out_h"
	else
		job_stage 1 "$JOB_OUT/1.png" "$out_w" "$out_h"
	fi || job_write err 'cannot encode the preview'
}

# Decodes a Radiance picture into raw planes for ffmpeg. Sets RAD_FILTER to
# the filters that turn the planes into a normal picture.
job_radiance() {
	local path=$1 w=$2 h=$3 out_w=$4 out_h=$5 flips=''
	case ${META[scan_order]-} in
		'-Y +X') ;;
		'+Y +X') flips=vflip, ;;
		'-Y -X') flips=hflip, ;;
		'+Y -X') flips=hflip,vflip, ;;
		*) return 1 ;;
	esac
	# Scan lines that the preview cannot show are not decoded.
	local step=$(( h / out_h ))
	(( step < 1 )) && step=1
	radiance_planes "$path" "${META[data_offset]}" "$w" "$h" "$step" "$JOB_OUT/planes" || return 1
	# Mantissa and exponent cannot be averaged, so the first cut in width takes whole pixels.
	local near_w=$(( out_w * 2 ))
	(( near_w > w )) && near_w=$w
	radiance_filter
	RAD_FILTER="scale=${near_w}:${RAD_ROWS}:flags=neighbor,format=gbrap,${REPLY},format=gbrp,${flips}"
}

# Reads the size of a file that the header parser does not know.
job_ffprobe() {
	local line
	ln -s -- "$1" "$JOB_OUT/probe"
	line=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height \
		-of csv=p=0 "$JOB_OUT/probe" 2>/dev/null) || return 1
	IFS=, read -r PROBE_CODEC PROBE_W PROBE_H _ <<< "$line"
	[[ ${PROBE_W-} == +([0-9]) && ${PROBE_H-} == +([0-9]) ]]
}
