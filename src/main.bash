# Start-up, the main loop, and shutdown.

usage() {
	cat <<EOF
$PROG $VERSION - terminal file browser with image previews

Usage: $PROG [options] [directory | file]

Options:
  -a, --all            show hidden files
  -n, --no-images      start with image previews off
  -q, --quality LEVEL  preview quality: draft, normal, fine, full (default: normal)
      --rate KIB       send rate in KiB/s when the terminal gives no answers (default: 128)
  -h, --help           show this text
  -V, --version        show the version

Image previews need a terminal with the kitty graphics protocol (Ghostty, kitty).
They work inside tmux. ffmpeg decodes the images. Without ffmpeg only PNG files
have a preview. Press ? in the program for the keys.
EOF
}

parse_args() {
	local arg i
	while (( $# )); do
		arg=$1
		shift
		case $arg in
			-a | --all) SHOW_HIDDEN=1 ;;
			-n | --no-images) GFX=off ;;
			-q | --quality)
				(( $# )) || die "$arg needs a value"
				QUALITY=0
				for (( i = 1; i < ${#QUALITY_NAME[@]}; i++ )); do
					[[ $1 == "${QUALITY_NAME[i]}" || $1 == "$i" ]] && QUALITY=$i
				done
				(( QUALITY )) || die "unknown quality: $1 (use draft, normal, fine or full)"
				shift
				;;
			--rate)
				(( $# )) || die "$arg needs a value"
				if [[ $1 != +([0-9]) ]] || (( $1 < 1 )); then
					die "--rate needs a positive number of KiB/s, not: $1"
				fi
				RATE_BPS=$(( $1 * 1024 ))
				shift
				;;
			-h | --help)
				usage
				exit 0
				;;
			-V | --version)
				printf '%s %s\n' "$PROG" "$VERSION"
				exit 0
				;;
			--)
				(( $# )) && START_PATH=$1
				(( $# > 1 )) && die 'too many arguments'
				return 0
				;;
			-*) die "unknown option: $arg (see --help)" ;;
			*)
				[[ $START_PATH == . ]] || die 'too many arguments'
				START_PATH=$arg
				;;
		esac
	done
}

cleanup() {
	trap - EXIT
	if (( TERM_READY )); then
		tx_abort
		printf '%s' "${GFX_PRE}q=2,a=d,d=I,i=${ID_A}${GFX_SUF}${GFX_PRE}q=2,a=d,d=I,i=${ID_B}${GFX_SUF}"
		term_restore
	fi
	job_kill
	tmux_restore
	[[ -n $RUN_DIR ]] && rm -rf -- "$RUN_DIR"
	return 0
}

on_resize() {
	RESIZED=0
	layout
	scroll_fix
	D_ALL=1
	now_ms
	[[ $GFX == on ]] && cell_query
	preview_restart
}

main() {
	(( BASH_VERSINFO[0] >= 5 )) || die 'bash 5 or later is needed'
	state_init
	parse_args "$@"

	local start_name=
	if [[ -d $START_PATH ]]; then
		cd -- "$START_PATH" || die "cannot open $START_PATH"
	elif [[ -e $START_PATH ]]; then
		start_name=${START_PATH##*/}
		[[ $START_PATH == */* ]] && { cd -- "${START_PATH%/*}/" || die "cannot open ${START_PATH%/*}"; }
	else
		die "no such file or directory: $START_PATH"
	fi
	[[ -t 0 && -t 1 ]] || die 'needs a terminal on standard input and output'

	# Text width and the placeholder characters need a UTF-8 locale.
	case ${LC_ALL:-${LC_CTYPE:-${LANG-}}} in
		*[Uu][Tt][Ff]-8 | *[Uu][Tt][Ff]8) ;;
		*) export LC_ALL=C.UTF-8 ;;
	esac

	command -v ffmpeg >/dev/null && HAVE_FFMPEG=1
	command -v ffprobe >/dev/null && HAVE_FFPROBE=1
	command -v file >/dev/null && HAVE_FILE=1
	[[ -n ${TMUX-} && -n ${TMUX_PANE-} ]] && IN_TMUX=1

	RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/$PROG.XXXXXX") || die 'cannot create a work directory'
	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM HUP
	trap 'RESIZED=1' WINCH

	gfx_init
	if (( IN_TMUX )) && [[ $GFX != off ]]; then
		tmux_setup
	fi
	term_init
	layout
	dir_load
	dir_find "$start_name"
	CUR=$REPLY
	scroll_fix
	now_ms
	[[ $GFX == off ]] || handshake_send
	(( HAVE_FFMPEG )) || [[ $GFX == off ]] || status 'ffmpeg is not installed: only PNG files have a preview'
	preview_reset
	render

	local drained
	while (( RUNNING )); do
		preview_timeout
		if [[ $REPLY == 0 ]]; then
			read -t 0 && read_key "$ESC_WAIT_S" && [[ -n $KEY ]] && handle_key "$KEY"
		else
			read_key "$REPLY" && [[ -n $KEY ]] && handle_key "$KEY"
		fi
		# Handle all keys that wait before one redraw.
		drained=0
		while (( RUNNING && drained++ < 64 )) && read -t 0; do
			read_key "$ESC_WAIT_S" && [[ -n $KEY ]] && handle_key "$KEY"
		done
		now_ms
		(( RESIZED )) && on_resize
		if [[ -n $STATUS ]] && (( NOW - STATUS_AT > STATUS_MS )); then
			STATUS='' D_FOOTER=1
		fi
		preview_tick
		render
	done
}
