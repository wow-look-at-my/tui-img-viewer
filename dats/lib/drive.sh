#!/usr/bin/env bash
# Runs imgv on the fake terminal, plays a list of steps, and prints the facts that a test asserts on.
set -o nounset

here=$(cd "${BASH_SOURCE%/*}" && pwd)
root=$(cd "$here/../.." && pwd)
target=$1
shift
mode=${MODE:-tmux} rate=${RATE:-0} cols=${COLS:-120} rows=${ROWS:-36}

work=$(mktemp -d)
export TMUX_TMPDIR=$work
unset TMUX TMUX_PANE
socket=imgv-test

printf -v command 'LC_ALL=C.UTF-8 TERM=xterm-256color %q %s %q' "$root/imgv" "${IMGV_ARGS-}" "$target"
if [[ $mode == tmux ]]; then
	# The locale of the tmux client decides whether tmux writes UTF-8 to the terminal.
	printf -v command 'LC_ALL=%q TERM=xterm-256color tmux -L %s -f /dev/null new-session %q' \
		"${CLIENT_LOCALE:-C.UTF-8}" "$socket" "$command"
fi

now() {
	local t=${EPOCHREALTIME/[.,]/}
	REPLY=$(( t / 1000 ))
}

# Prints the tmux pane as text. A placeholder cell of an image shows as "#".
screen() {
	printf '== screen %s ==\n' "$1"
	tmux -L "$socket" capture-pane -p |
		LC_ALL=C sed -e $'s/\xf4\x8e\xbb\xae[\x80-\xf3]*/#/g' -e 's/ *$//'
}

bash "$here/fake-term.sh" "$work" "$rate" "$cols" "$rows" "$command" &
terminal=$!
while [[ ! -p $work/in ]]; do
	sleep 0.05
done
exec 9> "$work/in"
for step in "$@"; do
	case $step in
		k:*)
			now
			printf '%s key\n' "$REPLY" >> "$work/events"
			printf '%s' "${step#k:}" >&9
			;;
		w:*) sleep "${step#w:}" ;;
		shot:*) screen "${step#shot:}" ;;
		*)
			echo "drive.sh: unknown step: $step" >&2
			exit 2
			;;
	esac
done
printf 'q' >&9
# A program that stays after the q key is a failure. The report shows what stayed.
mkfifo "$work/hold"
(
	# A read with a timeout waits with no child process, so a kill of
	# this subshell leaves nothing behind.
	read -r -t 15 _ <> "$work/hold"
	: > "$work/stuck"
	echo 'drive.sh: the program did not stop after the q key' >&2
	ps -eo pid,ppid,stat,etime,args >&2
	[[ $mode == tmux ]] && screen stuck >&2
	[[ $mode == tmux ]] && tmux -L "$socket" kill-server 2>/dev/null
	kill "$terminal" 2>/dev/null
) &
watchdog=$!
exec 9>&-
wait "$terminal"
kill "$watchdog" 2>/dev/null
wait "$watchdog" 2>/dev/null
[[ -e $work/stuck ]] && exit 1
[[ $mode == tmux ]] && tmux -L "$socket" kill-server 2>/dev/null

# The summary. Every line is a fact with no timing in it, so a test can
# assert the exact text.
# shellcheck source=/dev/null
source "$root/src/metadata.bash"
echo '== summary =='
limit=524288
[[ $mode == tmux ]] && limit=$(( cols * rows * 4 ))
images=0 window=0 over=0 queried=no last_key=0 open=0 last=none
while read -r ms kind detail size; do
	case $kind in
		key) last_key=$ms ;;
		probe)
			(( window > limit )) && (( over++ ))
			window=0
			;;
		gfx)
			(( window += ${size:-0} ))
			[[ $detail == *a=q* ]] && queried=yes
			if [[ $detail == *a=T* ]]; then
				# The end of the image before never came: tmux dropped it.
				(( open )) && echo "image $images: lost on the way"
				(( images++ ))
				open=1
			fi
			# An empty last chunk closes a transfer that the program stopped.
			if (( open )) && [[ $detail == *m=0* ]]; then
				open=0
				png=$work/img.$images.png
				if [[ ${size:-0} != 0 || -s $png ]] && ffmpeg -nostdin -v error -i "$png" -f null - 2>/dev/null && meta_probe "$png"; then
					last="${META[width]}x${META[height]} complete"
				elif (( last_key && ms - last_key < 1500 )); then
					last='stopped soon after a key'
				else
					last="damaged or stopped, $(( ms - last_key )) ms after the last key"
				fi
				echo "image $images: $last"
			fi
			;;
	esac
done < "$work/events"
echo "images: $images"
echo "last image: $last"
echo "graphics query: $queried"
echo "windows over the limit: $over"
# tmux writes "_" in place of an image cell for a client that is not in
# UTF-8 mode. The cells must show in what the terminal received.
if LC_ALL=C grep -q $'\xf4\x8e\xbb\xae' "$work/stream"; then
	echo 'image cells on the terminal: yes'
else
	echo 'image cells on the terminal: no'
fi
rm -rf -- "$work"
