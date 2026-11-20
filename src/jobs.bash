# Background preview jobs. One job reads one file and writes its results into
# its own directory.

# Starts a job in the background. Sets REPLY to its process id. A subshell
# starts the job and ends at once, so the job is not a child of this shell.
job_spawn() {
	local dir=$3
	(
		job_main "$@" </dev/null >/dev/null 2>&1 &
		echo "$!" > "$dir/pid"
	)
	read -r REPLY < "$dir/pid" || REPLY=0
}

# Finds what the installed ffmpeg can read and write. A small build can have
# no image2 formats and only a few decoders. Sets FF_HAS to words such as
# "dx:image2", "mx:mov", "dec:png" and "enc:png", and FF_OUT to the format of
# the preview files: image2, mov. It empty when ffmpeg cannot write PNG files.
ff_caps() {
	local kind flag list names name
	FF_HAS=' ' FF_OUT=
	for kind in dx:demuxers mx:muxers dec:decoders enc:encoders; do
		list=$(ffmpeg -hide_banner "-${kind#*:}" 2>/dev/null) || list=
		while read -r flag names _; do
			[[ $flag == [A-Z.]* && -n ${names-} ]] || continue
			# shellcheck disable=SC2086 # the split makes one word of each name
			for name in ${names//,/ }; do
				FF_HAS+="${kind%%:*}:$name "
			done
		done <<< "$list"
	done
	ff_has enc png || return 0
	if ff_has mx image2; then
		FF_OUT=image2
	elif ff_has mx mov; then
		FF_OUT=mov
	fi
}

# Some hosts let ffmpeg open no file in the work directory, not even as root: a
# sandbox can keep it out. ffmpeg then reads and writes pipes that cat feeds
# and empties. Sets FF_PIPE to `FF_PIPE` and FF_PIPE_OUT to the muxer for the
# pipe. The file protocol opens a pipe through /proc when the build has no pipe protocol.
ff_check_dir() {
	local probe=$RUN_DIR/probe out
	printf 'imgv' > "$probe" || return 0
	out=$(ffmpeg -nostdin -hide_banner -v error -i "$probe" 2>&1 < /dev/null)
	rm -f -- "$probe"
	[[ $out == *'Permission denied'* || $out == *'Operation not permitted'* ]] || return 0
	FF_PIPE=1 FF_IN=/proc/self/fd/0 FF_OUTPUT=/proc/self/fd/1
	if [[ $(ffmpeg -hide_banner -protocols 2>/dev/null) == *[[:space:]]pipe[[:space:]]* ]]; then
		FF_IN=pipe:0 FF_OUTPUT=pipe:1
	fi
	if ff_has mx image2pipe; then
		FF_PIPE_OUT=image2pipe
	elif ff_has mx mov; then
		FF_PIPE_OUT=mov
	else
		status "ffmpeg may not open the files in $RUN_DIR, and it has no muxer for a pipe: only PNG files have a preview"
		return 0
	fi
	status "ffmpeg may not open the files in $RUN_DIR: previews go through pipes, with no draft stage"
}

# Succeeds when ffmpeg has the part $2 of the kind $1: dx, mx, dec or enc.
ff_has() {
	[[ $FF_HAS == *" $1:$2 "* ]]
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
	[[ -s $JOB_OUT/pipe.pid ]] && kill "$(< "$JOB_OUT/pipe.pid")" 2>/dev/null
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

# job_pipe IN OUT COMMAND... feeds the file IN to the input of the command and
# writes its output to the file OUT. cat opens both files, the command none.
job_pipe() {
	local in=$1 out=$2 rc
	shift 2
	cat -- "$in" | {
		"$@" <&0 &
		echo "$!" > "$JOB_OUT/pipe.pid"
		wait "$!"
	} | cat > "$out"
	rc=${PIPESTATUS[1]}
	rm -f -- "$JOB_OUT/pipe.pid"
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
	elif ! head -c 65536 -- "$path" > "$JOB_OUT/head" 2>/dev/null; then
		text=('(not readable)')
	elif (( $(tr -d '\0' < "$JOB_OUT/head" | wc -c) == $(wc -c < "$JOB_OUT/head") )); then
		# A text file holds no NUL byte.
		read_lines raw "$JOB_OUT/head"
		for line in "${raw[@]:0:TEXT_LINES}"; do
			# The pane shows the start of a line. An old bash needs seconds to replace text in a long one.
			line=${line:0:1024}
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
	line=${META_format:-image}
	[[ -n ${META_color-} ]] && line+=" · ${META_color}"
	[[ -n ${META_bits-} ]] && line+=" ${META_bits}-bit"
	[[ -n ${META_detail-} ]] && line+=" · ${META_detail}"
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
	(( ${META_orientation:-1} > 1 )) && line+=" · EXIF rotation ${META_orientation}"
	INFO+=("Image"$'\t'"$line")

	line=${META_make-}
	if [[ -n ${META_model-} ]]; then
		# Many cameras repeat the maker name in the model name.
		[[ -n $line && ${META_model} != "$line"* ]] && line+=" ${META_model}" || line=${META_model}
	fi
	[[ -n $line ]] && INFO+=("Camera"$'\t'"$line")

	line=
	[[ -n ${META_fnumber-} ]] && line+="f/${META_fnumber} · "
	[[ -n ${META_exposure-} ]] && line+="${META_exposure} s · "
	[[ -n ${META_iso-} ]] && line+="ISO ${META_iso} · "
	[[ -n ${META_focal-} ]] && line+="${META_focal} mm · "
	[[ -n $line ]] && INFO+=("Shot"$'\t'"${line% · }")
	[[ -n ${META_datetime-} ]] && INFO+=("Taken"$'\t'"${META_datetime}")
	[[ -n ${META_lens-} ]] && INFO+=("Lens"$'\t'"${META_lens}")
	return 0
}

# Publishes the PNG file $2 as stage $1 with the pixel size $3 x $4.
job_stage() {
	local n=$1 png=$2 data i
	data=$(set -o pipefail; base64 < "$png" | tr -d '\n') || return 1
	local bytes=${#data}
	(( bytes > 0 )) || return 1
	# The file holds one line for each graphics command of the transfer.
	for (( i = 0; i < bytes; i += CHUNK )); do
		printf '%s\n' "${data:i:CHUNK}"
	done > "$JOB_OUT/.s$n.b64" || return 1
	job_write "s$n.dim" "$3 $4 $bytes"
	mv -- "$JOB_OUT/.s$n.b64" "$JOB_OUT/s$n.b64"
}

# job_image PATH OUT MAX_W MAX_H FILE_SIZE
# MAX_W x MAX_H is the pixel limit of the last stage. Zero means: details only.
job_image() {
	local path=$1 max_w=$3 max_h=$4 fsize=$5
	local -a INFO=()
	local w=0 h=0 orient=1 format=
	if meta_probe "$path"; then
		w=${META_width} h=${META_height} orient=${META_orientation:-1} format=${META_format}
		if (( orient >= 5 )); then
			local t=$w
			w=$h h=$t
		fi
		job_meta_lines "$w" "$h"
	elif (( HAVE_FFPROBE )) && job_ffprobe "$path"; then
		w=$PROBE_W h=$PROBE_H
		META_format=$PROBE_CODEC
		job_meta_lines "$w" "$h"
	fi
	job_stat_lines "$path"
	if (( w < 1 || h < 1 )); then
		job_write info "${INFO[@]}"
		job_write err 'this image format is not recognized'
		return
	fi
	if (( max_w < 1 )); then
		job_write info "${INFO[@]}"
		return
	fi

	# why names what this ffmpeg lacks for the file. pd is the demuxer that reads the format from a pipe.
	local dec='' pd='' why=''
	case $format in
		PNG) dec=png pd=png_pipe ;;
		JPEG) dec=mjpeg pd=jpeg_pipe ;;
		GIF) dec=gif pd=gif ;;
		BMP) dec=bmp pd=bmp_pipe ;;
		WebP) dec=webp pd=webp_pipe ;;
		TIFF) dec=tiff pd=tiff_pipe ;;
		EXR) dec=exr pd=exr_pipe ;;
	esac
	if (( ! HAVE_FFMPEG )); then
		why='ffmpeg is not installed'
	elif [[ -z $FF_OUT ]]; then
		why='this ffmpeg cannot write PNG files'
	elif (( FF_PIPE )) && [[ -z $FF_PIPE_OUT ]]; then
		why='ffmpeg may not open the work files, and it has no muxer for a pipe'
	elif [[ -n $dec ]] && ! ff_has dec "$dec"; then
		why="this ffmpeg has no $dec decoder"
	elif [[ $format == PNG ]] && ff_has dx mov; then
		:
	elif (( FF_PIPE )) && [[ -n $dec ]] && ! ff_has dx "$pd"; then
		why="this ffmpeg cannot read $format files from a pipe: it has no $pd demuxer"
	elif [[ -n $dec ]] && ! ff_has dx image2 && ! ff_has dx "$pd" && ! ff_has dx "${dec}_pipe" && ! ff_has dx "$dec"; then
		why="this ffmpeg cannot read $format files"
	fi

	# Nearest scaling enlarges a small picture to the cells that it covers, so the terminal does not smooth it.
	local direct=0 up=0 flt=lanczos draft=bilinear
	box_cells "$w" "$h"
	if [[ $FILTER == nearest ]]; then
		flt=neighbor draft=neighbor
		(( CELLS_C * CELL_W > w )) && up=1
	fi
	if [[ $format == PNG ]] && (( orient == 1 )); then
		(( w <= max_w && h <= max_h && fsize <= DIRECT_PNG_MAX && ! up )) && direct=1
		[[ -n $why ]] && direct=1
	fi
	if (( direct )); then
		[[ -n $why ]] && INFO+=("Note"$'\t'"sent as is: $why")
		job_write info "${INFO[@]}"
		job_write geom "$w $h 1"
		job_stage 1 "$path" "$w" "$h" || job_write err 'cannot read the file'
		return
	fi
	job_write info "${INFO[@]}"
	if [[ -n $why ]]; then
		job_write err "$why"
		return
	fi

	fit_px "$w" "$h" "$max_w" "$max_h"
	local out_w=$FIT_W out_h=$FIT_H
	if (( up && out_w == w && out_h == h )); then
		out_w=$(( CELLS_C * CELL_W )) out_h=$(( CELLS_R * CELL_H ))
	fi
	fit_px "$w" "$h" "$THUMB_EDGE" "$THUMB_EDGE"
	local thumb_w=$FIT_W thumb_h=$FIT_H stages=1
	# A draft helps only when the last stage holds more detail. A pipe carries one picture.
	(( ! up && ! FF_PIPE && out_w * 2 > thumb_w * 3 )) && stages=2
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
	# ffmpeg reads feed under the name src: a link, so no name looks like an option or a sequence pattern.
	local feed=$path src=$JOB_OUT/src
	[[ $format == HDR ]] && pd=hdr_pipe
	local -a inp=(-i "$src")
	if (( FF_PIPE )); then
		src=$FF_IN inp=(-i "$FF_IN")
		[[ $pd == *_pipe ]] && inp=(-f "$pd" -frame_size "$fsize" -i "$FF_IN")
	elif ! ln -s -- "$path" "$src"; then
		job_write err "cannot make a link in $JOB_OUT"
		return
	fi
	local -a input=(-noautorotate "${inp[@]}")
	if [[ $format == PNG ]] && ! ff_has dx png_pipe && { (( FF_PIPE )) || ! ff_has dx image2; }; then
		feed=$JOB_OUT/src.mov
		if ! mov_wrap "$path" "$META_width" "$META_height" "$feed"; then
			job_write err 'cannot read the file'
			return
		fi
		(( FF_PIPE )) || src=$feed
		input=(-noautorotate -f mov -i "$src")
	fi
	# The filter that puts the sRGB curve on a picture that holds linear light.
	local curve='if(lte(val/maxval,0.0031308),12.92*val,(1.055*pow(val/maxval,1/2.4)-0.055)*maxval)'
	local srgb="lutrgb=r='$curve':g='$curve':b='$curve',"
	case $format in
		EXR)
			input=("${inp[@]}")
			if [[ $(ffmpeg -hide_banner -h decoder=exr 2>/dev/null) == *apply_trc* ]]; then
				# This decoder applies the curve.
				input=(-apply_trc iec61966_2_1 "${inp[@]}")
			elif [[ ${META_color-} == @(RGBA|Gray+Alpha) ]]; then
				turn="format=gbrap16le,$srgb"
			else
				turn="format=gbrp16le,$srgb"
			fi
			;;
		HDR)
			if [[ ${META_scan_order-} == '-Y +X' ]] && ff_has dec hdr && { ff_has dx hdr_pipe || { (( ! FF_PIPE )) && ff_has dx image2; }; }; then
				# This ffmpeg reads the format. Its output is linear light, so the sRGB curve follows here.
				input=("${inp[@]}")
				turn="format=gbrp16le,$srgb"
			elif ! ff_has dx rawvideo; then
				job_write err 'this ffmpeg cannot read Radiance files: it has no hdr decoder and no rawvideo demuxer'
				return
			elif job_radiance "$path" "$w" "$h" "$out_w" "$out_h"; then
				feed=$JOB_OUT/planes
				(( FF_PIPE )) || src=$feed
				input=(-f rawvideo -pixel_format "$RAD_FORMAT" -video_size "${w}x$RAD_ROWS" -i "$src")
				turn=$RAD_FILTER
			else
				job_write err 'this Radiance file has a layout that the decoder does not know'
				return
			fi
			;;
	esac
	local pix='format=pix_fmts=rgb24|rgba|gray|ya8' graph
	local -a enc=(-frames:v 1 -c:v png -pred mixed -f image2 -update 1) outs
	local ext=png n out=$JOB_OUT/1.png
	local -a run=(job_run)
	if (( FF_PIPE )); then
		# A mov file on a pipe must be fragmented: the muxer cannot go back to write the index.
		if [[ $FF_PIPE_OUT == mov ]]; then
			enc=(-frames:v 1 -c:v png -pred mixed -f mov -movflags frag_keyframe+empty_moov)
			ext=mov
		else
			enc=(-frames:v 1 -c:v png -pred mixed -f image2pipe)
		fi
		out=$FF_OUTPUT
		run=(job_run job_pipe "$feed" "$JOB_OUT/1.$ext")
	elif [[ $FF_OUT == mov ]]; then
		enc=(-frames:v 1 -c:v png -pred mixed -f mov)
		ext=mov out=$JOB_OUT/1.mov
	fi
	if (( stages == 2 )); then
		graph="[0:v]${turn}split=2[a][b];"
		graph+="[a]scale=${thumb_w}:${thumb_h}:flags=${draft},${pix}[t];"
		graph+="[b]scale=${out_w}:${out_h}:flags=${flt},${pix}[f]"
		outs=(-map '[t]' "${enc[@]}" "$out" -map '[f]' "${enc[@]}" "$JOB_OUT/2.$ext")
	else
		graph="[0:v]${turn}scale=${out_w}:${out_h}:flags=${flt},${pix}[f]"
		outs=(-map '[f]' "${enc[@]}" "$out")
	fi
	if ! "${run[@]}" ffmpeg -nostdin -y -v error "${input[@]}" \
		-filter_complex "$graph" "${outs[@]}" 2> "$JOB_OUT/log"; then
		local reason=
		[[ -s $JOB_OUT/log ]] && reason=$(tail -n 1 -- "$JOB_OUT/log")
		job_write err "ffmpeg cannot decode this file: ${reason:-no message}"
		return
	fi
	if [[ $ext == mov ]]; then
		for (( n = 1; n <= stages; n++ )); do
			if ! mov_extract "$JOB_OUT/$n.mov" "$JOB_OUT/$n.png"; then
				job_write err 'cannot read the preview that ffmpeg wrote'
				return
			fi
		done
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
	case ${META_scan_order-} in
		'-Y +X') ;;
		'+Y +X') flips=vflip, ;;
		'-Y -X') flips=hflip, ;;
		'+Y -X') flips=hflip,vflip, ;;
		*) return 1 ;;
	esac
	# Scan lines that the preview cannot show are not decoded.
	local step=$(( h / out_h ))
	(( step < 1 )) && step=1
	radiance_planes "$path" "${META_data_offset}" "$w" "$h" "$step" "$JOB_OUT/planes" || return 1
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
