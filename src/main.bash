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

# Finds what this bash and the tools of this host can do. A host with
# busybox tools and an old bash has less than a GNU system.
probe_host() {
	local major=${BASH_VERSINFO[0]} minor=${BASH_VERSINFO[1]} out
	# An older bash can drop the byte that arrives at the end of a read timeout.
	(( major >= 5 )) && READ_FRAC=1
	(( major > 4 || (major == 4 && minor >= 2) )) && TIME_BUILTIN=1
	if (( ! READ_FRAC )); then
		if sleep "$TICK_BUSY_S" 2>/dev/null; then
			NAP=(sleep "$TICK_BUSY_S") NAP_IDLE=(sleep "$TICK_IDLE_S")
		elif command -v usleep >/dev/null; then
			NAP=(usleep 20000) NAP_IDLE=(usleep 250000)
		else
			NAP=(sleep 1) NAP_IDLE=(sleep 1)
			status 'this host has no short sleep: the screen follows slowly'
		fi
	fi
	# GNU and busybox date take the time after "-d @", BSD date after "-r".
	date -d @0 +%s >/dev/null 2>&1 || DATE_OPT=-r DATE_PRE=''

	command -v ffmpeg >/dev/null && HAVE_FFMPEG=1
	command -v ffprobe >/dev/null && HAVE_FFPROBE=1
	command -v file >/dev/null && HAVE_FILE=1
	# GNU and busybox stat take the format after -c, BSD stat after -f.
	if stat -c %s . >/dev/null 2>&1; then
		STAT_LIST=(-c '%s/%Y') STAT_MODE=(-c '%A  %U:%G')
		# Not every stat knows the time with a fraction.
		out=$(stat -c '%s/%.9Y' . 2>/dev/null) || out=
		[[ $out == +([0-9])/+([0-9])?(.+([0-9])) ]] && STAT_LIST=(-c '%s/%.9Y')
	else
		STAT_LIST=(-f '%z/%Fm') STAT_MODE=(-f '%Sp  %Su:%Sg')
	fi
	# Not every sort knows the order of version numbers.
	SORT_NAME=(-t/ -k5 -f)
	sort -V < /dev/null > /dev/null 2>&1 && SORT_NAME+=(-V)

	# The image details and the previews read bytes with od and write them with base64.
	out=$(printf 'A' | od -An -v -tu1 -j 0 -N 1 2>/dev/null) || out=
	if [[ $out != *65* ]]; then
		status 'the od of this host cannot read bytes: images show no details and no preview'
	elif [[ $(printf 'A' | base64 2>/dev/null) != QQ== ]]; then
		status 'base64 is not installed: images have no preview'
	fi
}

main() {
	(( BASH_VERSINFO[0] > 3 || (BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] >= 2) )) || die 'bash 3.2 or later is needed'
	[[ -n ${EPOCHREALTIME-} || -r /proc/uptime ]] || die 'this bash has no clock: use bash 5, or a host with /proc/uptime'
	# The program handles text as bytes and reads UTF-8 with its own code.
	export LC_ALL=C
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

	probe_host
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
	if (( IN_TMUX )) && [[ $GFX != off ]] && ! tmux_utf8; then
		GFX=noutf8
		status 'tmux is not in UTF-8 mode, so images cannot show: attach with "tmux -u"'
	fi
	preview_reset
	render

	while (( RUNNING )); do
		preview_timeout
		# A sequence that is not whole yet needs a look soon.
		[[ -n $INBUF && $REPLY == idle ]] && REPLY=busy
		input_wait "$REPLY"
		now_ms
		# All keys that wait are handled before one redraw.
		input_dispatch
		now_ms
		(( RESIZED )) && on_resize
		if [[ -n $STATUS ]] && (( NOW - STATUS_AT > STATUS_MS )); then
			STATUS='' D_FOOTER=1
		fi
		preview_tick
		render
	done
}
