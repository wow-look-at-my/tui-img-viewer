# Keyboard input. The answers of the terminal arrive on the same stream.
#
# The terminal is in a mode where a read never blocks. One plain read then
# takes every byte that waits, on each bash version. INBUF collects the
# bytes, and input_dispatch takes whole keys and whole sequences from it.

# Appends the bytes that wait on the terminal to INBUF.
input_poll() {
	local part
	while IFS= read -r part; do
		# A line feed ended this read, and it is input too.
		INBUF+=$part$'\n'
	done
	INBUF+=$part
}

# Sleeps for one busy tick. Only a bash with no short read timeout calls it.
nap() {
	"${NAP[@]}"
}

# Collects input. $1 says how long to wait for the first byte: "none",
# "busy" for one short tick, or "idle" for a long one.
input_wait() {
	local wait=$1 before=${#INBUF} c rc
	input_poll
	if (( ${#INBUF} == before )) && [[ $wait != none ]]; then
		if (( READ_FRAC )); then
			local t=$TICK_IDLE_S
			[[ $wait == busy ]] && t=$TICK_BUSY_S
			# bash makes this read wait for one byte. A byte that arrives at
			# the end of the time is in c, and the status says: timeout.
			c=
			IFS= read -r -n 1 -d '' -t "$t" c
			rc=$?
			if [[ -n $c ]]; then
				INBUF+=$c
				input_poll
			elif (( rc > 0 && rc <= 128 )); then
				# End of input: the terminal is gone.
				RUNNING=0
			fi
		elif [[ $wait == busy ]]; then
			nap
			input_poll
		else
			now_ms
			local t0=$NOW
			c=
			IFS= read -r -n 1 -d '' -t 1 c
			rc=$?
			if [[ -n $c ]]; then
				INBUF+=$c
				input_poll
			elif (( rc == 0 || rc > 128 )); then
				EARLY_FAILS=0
			else
				# The oldest bash gives one status for a timeout and for the
				# end of input. A read that fails early saw the end of input.
				now_ms
				if (( NOW - t0 < 500 )); then
					(( ++EARLY_FAILS >= 3 )) && RUNNING=0
				else
					EARLY_FAILS=0
				fi
			fi
		fi
	fi
	if (( ${#INBUF} != before )); then
		now_ms
		INBUF_AT=$NOW
		[[ -n ${IMGV_DEBUG-} ]] && printf '%s wait=%s rc=%s mode=%s buf=%q\n' "$NOW" "$wait" "${rc-}" "$MODE" "$INBUF" >> "$IMGV_DEBUG"
	fi
	return 0
}

# Handles every whole key and answer in INBUF. A sequence that is not whole
# stays there for the next call. NOW must be current.
input_dispatch() {
	local buf=$INBUF pos=0 c
	local len=${#buf}
	while (( pos < len && RUNNING )); do
		c=${buf:pos:1}
		KEY=
		if [[ $c == $'\e' ]]; then
			input_escape || break
		else
			(( pos++ ))
			case $c in
				$'\n' | $'\r') KEY=ENTER ;;
				$'\x7f' | $'\b') KEY=BS ;;
				$'\t') KEY=TAB ;;
				*) KEY=$c ;;
			esac
		fi
		[[ -n $KEY ]] && handle_key "$KEY"
	done
	INBUF=${buf:pos}
}

# Takes the escape sequence at pos in buf, and moves pos behind it. Fails
# when the end of the sequence did not arrive yet. A sequence that stays
# open too long is dropped, and an escape byte with nothing after it is a key.
input_escape() {
	local c=${buf:pos + 1:1} i final=''
	local late=$(( NOW - INBUF_AT >= ESC_WAIT_MS ))
	case $c in
		'')
			(( late )) || return 1
			KEY=ESC
			(( pos++ ))
			;;
		'[')
			# A control sequence ends at the first byte from "@" to "~".
			for (( i = pos + 2; i < len && i < pos + 36; i++ )); do
				final=${buf:i:1}
				[[ $final == [@-~] ]] && break
				final=
			done
			if [[ -n $final ]]; then
				csi_dispatch "${buf:pos + 2:i - pos - 2}" "$final"
				pos=$(( i + 1 ))
			elif (( i < len || late )); then
				pos=$i
			else
				return 1
			fi
			;;
		O)
			if (( pos + 2 < len )); then
				csi_dispatch '' "${buf:pos + 2:1}"
				(( pos += 3 ))
			elif (( late )); then
				pos=$len
			else
				return 1
			fi
			;;
		_ | P | ']' | '^')
			# A string sequence ends with a bell or with the string terminator.
			local rest=${buf:pos + 2} st=$'\e\\'
			local a=${rest%%$'\a'*} b=${rest%%"$st"*}
			if (( ${#a} < ${#b} )); then
				pos=$(( pos + 2 + ${#a} + 1 ))
				b=$a
			elif (( ${#b} < ${#rest} )); then
				pos=$(( pos + 2 + ${#b} + 2 ))
			elif (( late || ${#rest} > 256 )); then
				pos=$len
				return 0
			else
				return 1
			fi
			[[ $c == _ ]] && gfx_reply "$b"
			;;
		*)
			(( pos += 2 ))
			;;
	esac
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
				# One character can hold several bytes. Its first byte goes last.
				local b=128
				while [[ -n $SEARCH ]] && (( (b & 0xC0) == 0x80 )); do
					printf -v b '%d' "'${SEARCH: -1}"
					SEARCH=${SEARCH%?}
				done
				search_jump 1 "$SEARCH_FROM"
			fi
			;;
		?)
			SEARCH+=$1
			# A character that is not ASCII arrives as several keys.
			U_S=$SEARCH
			local i=0
			while (( i < ${#SEARCH} )); do
				utf8_at "$i"
				(( U_CP < 0 )) && break
				(( i += U_LEN ))
			done
			if (( i == ${#SEARCH} )); then
				search_jump 1 "$SEARCH_FROM" || status "no match for: $SEARCH"
			fi
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
		noutf8)
			if ! tmux_utf8; then
				status 'tmux is still not in UTF-8 mode: attach with "tmux -u"'
				return 0
			fi
			# The terminal is asked again, since the first answers were not kept.
			GFX=unknown
			handshake_send
			status 'image previews: on'
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
