# Keyboard input. The answers of the terminal arrive on the same stream.

# Reads one key with the timeout $1, in seconds. Sets KEY, which stays empty
# for input that is not a key. Fails when no input arrived in time.
read_key() {
	local c
	KEY=
	IFS= read -rsN1 -t "$1" c
	local rc=$?
	if (( rc > 128 )); then
		return 1
	elif (( rc != 0 )); then
		# End of input: the terminal is gone.
		RUNNING=0
		return 1
	fi
	case $c in
		$'\e') read_escape ;;
		$'\n' | $'\r') KEY=ENTER ;;
		$'\x7f' | $'\b') KEY=BS ;;
		$'\t') KEY=TAB ;;
		*) KEY=$c ;;
	esac
	return 0
}

read_escape() {
	local c seq=''
	if ! IFS= read -rsN1 -t "$ESC_WAIT_S" c; then
		KEY=ESC
		return
	fi
	case $c in
		'[')
			# A control sequence ends at the first byte from "@" to "~".
			while IFS= read -rsN1 -t "$ESC_WAIT_S" c; do
				[[ $c == [@-~] ]] && break
				seq+=$c
				(( ${#seq} > 32 )) && break
			done
			csi_dispatch "$seq" "$c"
			;;
		O)
			IFS= read -rsN1 -t "$ESC_WAIT_S" c || return
			csi_dispatch '' "$c"
			;;
		_ | P | ']' | '^')
			read_string "$c"
			;;
	esac
}

# Consumes a string sequence up to its terminator. $1 is the introducer.
read_string() {
	local c prev='' body=''
	while IFS= read -rsN1 -t "$ESC_WAIT_S" c; do
		[[ $c == $'\a' ]] && break
		if [[ $prev == $'\e' && $c == $'\\' ]]; then
			body=${body%$'\e'}
			break
		fi
		body+=$c prev=$c
		(( ${#body} > 256 )) && break
	done
	[[ $1 == _ ]] && gfx_reply "$body"
	return 0
}

# Maps a control sequence to a key name or to an answer handler.
csi_dispatch() {
	local params=$1 final=$2
	case $final in
		A) KEY=UP ;;
		B) KEY=DOWN ;;
		C) KEY=RIGHT ;;
		D) KEY=LEFT ;;
		H) KEY=HOME ;;
		F) KEY=END ;;
		'~')
			case ${params%%;*} in
				1 | 7) KEY=HOME ;;
				4 | 8) KEY=END ;;
				5) KEY=PGUP ;;
				6) KEY=PGDN ;;
			esac
			;;
		n) [[ $params == 0 ]] && ack_received ;;
		t) [[ $params == 6\;* ]] && cell_reply "$params" ;;
	esac
	return 0
}

search_key() {
	case $1 in
		ENTER)
			MODE=normal
			;;
		ESC)
			MODE=normal
			select_index "$SEARCH_FROM"
			;;
		BS)
			if [[ -z $SEARCH ]]; then
				MODE=normal
			else
				SEARCH=${SEARCH%?}
				search_jump 1 "$SEARCH_FROM"
			fi
			;;
		?)
			SEARCH+=$1
			search_jump 1 "$SEARCH_FROM" || status "no match for: $SEARCH"
			;;
	esac
	D_FOOTER=1
}

quality_step() {
	local q=$(( QUALITY + $1 ))
	(( q < 1 || q >= ${#QUALITY_NAME[@]} )) && return 0
	QUALITY=$q
	status "preview quality: ${QUALITY_NAME[QUALITY]}"
	preview_restart
}

images_toggle() {
	case $GFX in
		on)
			GFX=off
			status 'image previews: off'
			;;
		unknown)
			return 0
			;;
		*)
			# A terminal that gave no answer before is asked again.
			if [[ $GFX == off && $ACK_MODE == unknown ]]; then
				GFX=unknown
				handshake_send
			else
				GFX=on
			fi
			status 'image previews: on'
			;;
	esac
	preview_restart
}

handle_key() {
	local key=$1 page=$(( ROWS - 3 ))
	(( page < 1 )) && page=1
	case $MODE in
		help)
			MODE=normal D_ALL=1
			return
			;;
		search)
			search_key "$key"
			return
			;;
	esac
	if [[ -n $STATUS ]]; then
		STATUS='' D_FOOTER=1
	fi
	case $key in
		q) RUNNING=0 ;;
		j | DOWN) select_index $(( CUR + 1 )) ;;
		k | UP) select_index $(( CUR - 1 )) ;;
		g | HOME) select_index 0 ;;
		G | END) select_index $(( N - 1 )) ;;
		PGDN | $'\x06' | ' ') select_index $(( CUR + page )) ;;
		PGUP | $'\x02') select_index $(( CUR - page )) ;;
		$'\x04') select_index $(( CUR + page / 2 )) ;;
		$'\x15') select_index $(( CUR - page / 2 )) ;;
		l | RIGHT | ENTER) open_selection ;;
		h | LEFT | BS) dir_change .. "${PWD##*/}" ;;
		'~') dir_change "$HOME" ;;
		z | TAB) zoom_toggle ;;
		+ | =) quality_step 1 ;;
		- | _) quality_step -1 ;;
		i) images_toggle ;;
		.)
			SHOW_HIDDEN=$(( ! SHOW_HIDDEN ))
			dir_reload
			;;
		s)
			case $SORT in
				name) SORT='time' ;;
				time) SORT='size' ;;
				*) SORT='name' ;;
			esac
			dir_reload
			;;
		r) dir_reload ;;
		$'\x0c')
			D_ALL=1
			preview_restart
			;;
		/)
			MODE=search SEARCH='' SEARCH_FROM=$CUR D_FOOTER=1
			;;
		n) search_jump 1 $(( CUR + 1 )) || status 'no match' ;;
		N) search_jump -1 $(( CUR - 1 )) || status 'no match' ;;
		'?')
			MODE=help D_ALL=1
			;;
	esac
	return 0
}
