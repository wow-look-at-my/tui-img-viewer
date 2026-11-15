#!/usr/bin/env bash
# A fake terminal for the test suite.
set -o nounset
export LC_ALL=C

dir=$1 rate=$2 cols=$3 rows=$4 command=$5

# Appends an event with the wall clock in milliseconds.
stamp() {
	local now=${EPOCHREALTIME/[.,]/}
	printf '%d %s\n' $(( now / 1000 )) "$*" >> "$dir/events"
}

# Copies standard input to standard output at the rate limit.
throttle() {
	if (( rate == 0 )); then
		cat
		return
	fi
	local slice=$(( rate / 20 )) chunk rc
	(( slice < 1 )) && slice=1
	while :; do
		IFS= read -r -N "$slice" -t 0.05 chunk
		rc=$?
		printf '%s' "$chunk"
		(( rc == 1 )) && [[ -z $chunk ]] && return
		[[ -n $chunk ]] && sleep 0.05
	done
}

image=0 open=0

# Handles one escape sequence, given without its first byte.
sequence() {
	local line=$1 ctrl payload
	case $line in
		'[5n'*)
			stamp probe
			[[ -n ${FAKE_MUTE-} ]] || printf '\e[0n'
			;;
		'[16t'*)
			[[ -n ${FAKE_MUTE-} ]] || printf '\e[6;20;10t'
			;;
		# tmux asks for the device attributes when a client attaches.
		'[c'*)
			[[ -n ${FAKE_MUTE-} ]] || printf '\e[?62;22c'
			;;
		'[>c'*)
			[[ -n ${FAKE_MUTE-} ]] || printf '\e[>1;10;0c'
			;;
		_G*)
			ctrl=${line%%;*} payload=
			[[ $line == *';'* ]] && payload=${line#*;}
			ctrl=${ctrl#_G}
			stamp gfx "$ctrl" "${#payload}"
			if [[ $ctrl == *a=q* ]]; then
				[[ -n ${FAKE_MUTE-}${FAKE_NO_GRAPHICS-} ]] || printf '\033_Gi=1;OK\033\134'
			elif [[ $ctrl == *a=T* ]]; then
				(( image++ ))
				open=1
				printf '%s' "$payload" > "$dir/img.$image.b64"
			elif (( open )) && [[ $ctrl != *a=* ]]; then
				printf '%s' "$payload" >> "$dir/img.$image.b64"
			fi
			if (( open )) && [[ $ctrl == *m=0* ]]; then
				open=0
				if base64 -d "$dir/img.$image.b64" > "$dir/img.$image.png" 2>/dev/null; then
					stamp image "$image" complete
				else
					stamp image "$image" broken
				fi
			fi
			;;
	esac
}

# Reads the stream as one line per escape sequence and answers the queries. A
# query can be the last thing in the stream. That query is with no line end
# after it, so a short read timeout hands over a line that is still open.
respond() {
	local line pending='' rc
	while :; do
		IFS= read -r -t 0.02 line
		rc=$?
		pending+=$line
		if (( rc == 0 )); then
			sequence "$pending"
			pending=
		elif (( rc > 128 )); then
			if [[ $pending == '[5n'* || $pending == '[16t'* || $pending == '[c'* || $pending == '[>c'* ]]; then
				sequence "$pending"
				pending=
			fi
		else
			sequence "$pending"
			return
		fi
	done
}

mkfifo "$dir/in"
: > "$dir/events"
# The pseudo terminal starts with no size, so the command sets one first.
inner="stty rows $rows cols $cols; $command"
# The script program of util-linux takes the command after -c. The BSD one takes it after the file name.
if script --version > /dev/null 2>&1; then
	pty=(script -qfec "$inner" /dev/null)
else
	pty=(script -qeF /dev/null sh -c "$inner")
fi
# The named pipe carries the answers back to the command on purpose.
# BSD script stops when its input is a named pipe, so cat stands between them.
# shellcheck disable=SC2094
cat "$dir/in" |
	"${pty[@]}" |
	throttle |
	tee "$dir/stream" |
	stdbuf -o0 tr '\033' '\n' |
	respond > "$dir/in"
