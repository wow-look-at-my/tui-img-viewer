# The terminal: modes, size, tmux, and the queries that the terminal answers.

term_init() {
	STTY_SAVED=$(stty -g) || die 'cannot read the terminal settings'
	stty -echo -icanon -ixon min 1 time 0
	# Alternate screen, hidden cursor, no automatic line wrap.
	printf '\e[?1049h\e[?25l\e[?7l'
	TERM_READY=1
}

term_restore() {
	(( TERM_READY )) || return 0
	TERM_READY=0
	printf '\e[0m\e[?7h\e[?25h\e[?1049l'
	stty "$STTY_SAVED"
}

term_size() {
	local size
	size=$(stty size 2>/dev/null) || size='24 80'
	ROWS=${size% *} COLS=${size#* }
}

# Sets REPLY to $1 in a form that reaches the outer terminal through tmux.
wrap_passthrough() {
	if (( IN_TMUX )); then
		REPLY=$'\ePtmux;'${1//$'\e'/$'\e\e'}$'\e\\'
	else
		REPLY=$1
	fi
}

# tmux drops passthrough sequences unless the pane allows them.
# tmux versions without the option always allow them.
tmux_setup() {
	local value
	value=$(tmux show-options -Apv -t "$TMUX_PANE" allow-passthrough 2>/dev/null) || return 0
	[[ $value == on || $value == all ]] && return 0
	tmux set-option -p -t "$TMUX_PANE" allow-passthrough on 2>/dev/null ||
		die 'tmux blocks image data: run "tmux set -g allow-passthrough on", or use --no-images'
	TMUX_RESTORE=1
}

tmux_restore() {
	(( TMUX_RESTORE )) || return 0
	TMUX_RESTORE=0
	tmux set-option -p -u -t "$TMUX_PANE" allow-passthrough 2>/dev/null
}

# tmux discards its whole output queue for a client when the queue grows past
# eight bytes for each cell of that client. A window must stay well below that.
tmux_window_cap() {
	WIN_CAP=$WIN_MAX
	(( IN_TMUX )) || return 0
	local size
	size=$(tmux display-message -p -t "$TMUX_PANE" '#{client_width}x#{client_height}' 2>/dev/null) || size=
	local w=${size%x*} h=${size#*x}
	[[ $w == +([0-9]) && $h == +([0-9]) ]] || { w=$COLS h=$ROWS; }
	WIN_CAP=$(( w * h * 4 ))
	(( WIN_CAP < WIN_MIN )) && WIN_CAP=$WIN_MIN
	(( WIN_CAP > WIN_MAX )) && WIN_CAP=$WIN_MAX
	(( TX_WIN > WIN_CAP )) && TX_WIN=$WIN_CAP
	return 0
}

# tmux sends an answer to the active pane, whichever pane asked.
pane_focused() {
	(( IN_TMUX )) || return 0
	if (( NOW - FOCUS_AT >= FOCUS_CACHE_MS )); then
		FOCUS_AT=$NOW
		local state
		state=$(tmux display-message -p -t "$TMUX_PANE" \
			'#{pane_active}#{window_active}#{pane_in_mode}#{session_attached}' 2>/dev/null) || state=
		[[ $state == 110[1-9]* ]]
		FOCUS_OK=$?
	fi
	return "$FOCUS_OK"
}

# Asks the terminal for the cell size in pixels. The answer arrives as input.
cell_query() {
	pane_focused || return 0
	wrap_passthrough $'\e[16t'
	printf '%s' "$REPLY"
	CELL_WAIT_UNTIL=$(( NOW + 500 ))
}

# Handles the answer to cell_query: "6;height;width".
cell_reply() {
	local rest=${1#6;} h w
	h=${rest%%;*} w=${rest#*;}
	[[ $h == +([0-9]) && $w == +([0-9]) ]] || return 0
	(( h > 0 && w > 0 )) || return 0
	CELL_WAIT_UNTIL=0
	(( CELL_KNOWN && h == CELL_H && w == CELL_W )) && return 0
	CELL_W=$w CELL_H=$h CELL_KNOWN=1
	preview_restart
}

# Sends the first queries: cell size, graphics support, and one status report.
# The terminal answers in order, so the status report closes the handshake.
handshake_send() {
	local out
	wrap_passthrough $'\e[16t'
	out=$REPLY
	out+="${GFX_PRE}i=1,s=1,v=1,a=q,t=d,f=24;AAAA${GFX_SUF}${DSR}"
	printf '%s' "$out"
	(( PROBES++ ))
	HS_NEED=$PROBES HS_AT=$NOW HS_PENDING=1
}

handshake_tick() {
	(( HS_PENDING )) || return 0
	if (( ACKS >= HS_NEED )); then
		HS_PENDING=0 ACK_MODE=on
		RTT_MS=$(( NOW - HS_AT ))
		(( RTT_MS < 1 )) && RTT_MS=1
		if [[ $GFX == unknown ]]; then
			GFX=unsupported
			status 'this terminal does not answer the kitty graphics query: previews are off'
		fi
	elif (( NOW - HS_AT > HANDSHAKE_MS )); then
		HS_PENDING=0 ACKS=$PROBES
		ack_mode_off
		[[ $GFX == unknown ]] && GFX=on
	else
		return 0
	fi
	D_DETAILS=1 D_PREVIEW=1
}
