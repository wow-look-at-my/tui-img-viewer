# The kitty graphics protocol and the paced transfer of image data.
#
# An image is sent as a virtual placement. The screen then shows it through
# placeholder cells, which are ordinary text for tmux. The data goes out in
# windows. After each window the program asks the terminal for a status
# report and waits for the answer. The link never holds more than one
# window of image data in front of a screen update.

# The combining marks that number the rows and columns of a placeholder cell.
# This is the table of the kitty graphics protocol, in its order.
readonly DIA_HEX='
0305 030D 030E 0310 0312 033D 033E 033F 0346 034A 034B 034C 0350 0351 0352 0357 035B 0363 0364 0365 0366 0367
0368 0369 036A 036B 036C 036D 036E 036F 0483 0484 0485 0486 0487 0592 0593 0594 0595 0597 0598 0599 059C 059D
059E 059F 05A0 05A1 05A8 05A9 05AB 05AC 05AF 05C4 0610 0611 0612 0613 0614 0615 0616 0617 0657 0658 0659 065A
065B 065D 065E 06D6 06D7 06D8 06D9 06DA 06DB 06DC 06DF 06E0 06E1 06E2 06E4 06E7 06E8 06EB 06EC 0730 0732 0733
0735 0736 073A 073D 073F 0740 0741 0743 0745 0747 0749 074A 07EB 07EC 07ED 07EE 07EF 07F0 07F1 07F3 0816 0817
0818 0819 081B 081C 081D 081E 081F 0820 0821 0822 0823 0825 0826 0827 0829 082A 082B 082C 082D 0951 0953 0954
0F82 0F83 0F86 0F87 135D 135E 135F 17DD 193A 1A17 1A75 1A76 1A77 1A78 1A79 1A7A 1A7B 1A7C 1B6B 1B6D 1B6E 1B6F
1B70 1B71 1B72 1B73 1CD0 1CD1 1CD2 1CDA 1CDB 1CE0 1DC0 1DC1 1DC3 1DC4 1DC5 1DC6 1DC7 1DC8 1DC9 1DCB 1DCC 1DD1
1DD2 1DD3 1DD4 1DD5 1DD6 1DD7 1DD8 1DD9 1DDA 1DDB 1DDC 1DDD 1DDE 1DDF 1DE0 1DE1 1DE2 1DE3 1DE4 1DE5 1DE6 1DFE
20D0 20D1 20D4 20D5 20D6 20D7 20DB 20DC 20E1 20E7 20E9 20F0 2CEF 2CF0 2CF1 2DE0 2DE1 2DE2 2DE3 2DE4 2DE5 2DE6
2DE7 2DE8 2DE9 2DEA 2DEB 2DEC 2DED 2DEE 2DEF 2DF0 2DF1 2DF2 2DF3 2DF4 2DF5 2DF6 2DF7 2DF8 2DF9 2DFA 2DFB 2DFC
2DFD 2DFE 2DFF A66F A67C A67D A6F0 A6F1 A8E0 A8E1 A8E2 A8E3 A8E4 A8E5 A8E6 A8E7 A8E8 A8E9 A8EA A8EB A8EC A8ED
A8EE A8EF A8F0 A8F1 AAB0 AAB2 AAB3 AAB7 AAB8 AABE AABF AAC1 FE20 FE21 FE22 FE23 FE24 FE25 FE26 10A0F 10A38
1D185 1D186 1D187 1D188 1D189 1D1AA 1D1AB 1D1AC 1D1AD 1D242 1D243 1D244
'

gfx_init() {
	if (( IN_TMUX )); then
		GFX_PRE=$'\ePtmux;\e\e_G' GFX_SUF=$'\e\e\\\e\\'
		DSR=$'\ePtmux;\e\e[5n\e\\'
	else
		GFX_PRE=$'\e_G' GFX_SUF=$'\e\\'
		DSR=$'\e[5n'
	fi
	local hex
	utf8_char 0x10EEEE
	PH=$REPLY
	DIA=()
	for hex in $DIA_HEX; do
		utf8_char "0x$hex"
		DIA+=("$REPLY")
	done
	# The low byte of an image id travels in a color of the base palette,
	# which every terminal setup keeps intact. The process id spreads the ids
	# of two programs in one terminal. The high byte is a slot, see slot_new.
	ID_LO=$(( 16 + $$ % 240 ))
}

# Sets REPLY to an image id that no image of this program uses.
slot_new() {
	local n id
	for (( n = 0; n < SLOT_MAX; n++ )); do
		SLOT=$(( SLOT % SLOT_MAX + 1 ))
		id=$(( SLOT << 24 | ID_LO ))
		(( id == SHOWN_ID || (TX_ACTIVE && id == TX_ID) )) && continue
		[[ " $OLD_IDS " == *" $id "* ]] && continue
		res_has_id "$id" && continue
		REPLY=$id
		return 0
	done
	# RES_MAX keeps slots free, so this point is not reached.
	REPLY=$id
}

# Appends one graphics command to the frame.
gfx_cmd() {
	FRAME+="$GFX_PRE$1$GFX_SUF"
}

# Sets REPLY to the placeholder cells of image $1 at column $2, row $3,
# for a box of $4 columns and $5 rows.
placeholder_block() {
	local id=$1 x=$2 y=$3 cols=$4 rows=$5 row tail='' high=''
	local out=''
	# The third mark holds the high byte of the id.
	(( id >> 24 )) && high=${DIA[id >> 24]}
	# Only the first cell of a row carries its row and column. A cell with
	# no marks continues the cell on its left, which halves the bytes.
	repeat $(( cols - 1 )) "$PH"
	tail=$REPLY
	for (( row = 0; row < rows; row++ )); do
		out+=$'\e['"$(( y + row ));${x}H$PH${DIA[row]}${DIA[0]}$high$tail"
	done
	REPLY=$'\e[38;5;'"$(( id & 255 ))m$out"$'\e[39m'
}

# Handles one answer to a graphics command.
gfx_reply() {
	[[ $1 == Gi=1\;OK* ]] || return 0
	[[ $GFX == unknown || $GFX == unsupported ]] || return 0
	GFX=on
	D_DETAILS=1
	(( HS_PENDING )) || preview_restart
}

# Handles one status report from the terminal.
ack_received() {
	(( ACKS < PROBES )) && (( ACKS++ ))
	ACK_SEEN=1 ACK_MISSES=0
	if [[ $ACK_MODE == off ]] && (( ! HS_PENDING )); then
		ACK_MODE=on ACKS=$PROBES TX_WIN=$WIN_START
		(( TX_WIN > WIN_CAP )) && TX_WIN=$WIN_CAP
		status 'the terminal answers again: flow control is on'
	fi
	return 0
}

# Without answers the program cannot see the link. It then sends at a fixed rate.
ack_mode_off() {
	ACK_MODE=off
	(( RATE_NOW )) || RATE_NOW=$RATE_BPS
	rate_window
	human_size "$RATE_NOW"
	status "the terminal does not answer: no flow control, sending $REPLY/s (--rate)"
}

# Sets the window of the fixed-rate mode: a tenth of a second of data.
rate_window() {
	TX_WIN=$(( RATE_NOW / 10 ))
	(( TX_WIN < CHUNK )) && TX_WIN=$CHUNK
	(( TX_WIN > WIN_CAP )) && TX_WIN=$WIN_CAP
}

# Sets TMUX_TAKEN and TMUX_DISCARDED to two byte counts of the tmux client.
# tmux counts a byte as taken when it queues it, not when the client reads
# it. It counts a byte as discarded when it empties a queue that grew too long.
tmux_counters() {
	(( IN_TMUX )) || return 1
	local reply
	reply=$(tmux display-message -p -t "$TMUX_PANE" '#{client_written}:#{client_discarded}' 2>/dev/null) || return 1
	[[ $reply == +([0-9]):+([0-9]) ]] || return 1
	TMUX_TAKEN=${reply%:*} TMUX_DISCARDED=${reply#*:}
}

# tmux loses image data in two ways, and reports neither to the program.
# It empties its queue when the link is slower than the send rate. It also
# drops data while a redraw of the pane waits behind queued output.
# Succeeds when the counters show a loss. The first kind sets TX_LOST at once.
tmux_dropped() {
	(( TX_BASE >= 0 )) || return 1
	tmux_counters || return 1
	if (( TMUX_DISCARDED > TX_DISCARDED )); then
		TX_LOST=1
		return 0
	fi
	(( TMUX_TAKEN - TX_BASE < TX_SENT ))
}

# After a loss the whole image goes out again, at half the rate. A loss after
# the end damages an image that is already kept in the terminal.
tx_lost() {
	local active=$TX_ACTIVE
	tx_abort
	res_drop_id "$TX_ID"
	if [[ $TX_OWNER == cur ]]; then
		STAGE_DONE=0
	elif (( active )); then
		pf_clear
	fi
	(( RATE_NOW /= 2 ))
	(( RATE_NOW < WIN_MIN )) && RATE_NOW=$WIN_MIN
	rate_window
	now_ms
	TX_LOST=0 TX_CHECK_UNTIL=0
	TX_RETRY_AT=$(( NOW + RETRY_MS ))
	human_size "$RATE_NOW"
	status "tmux dropped image data: sending the image again at $REPLY/s"
}

# The queue of tmux can still overflow a moment after the last byte went
# out. This check finds that loss.
tx_check() {
	(( TX_CHECK_UNTIL )) || return 0
	(( NOW - TX_CHECK_AT >= 200 )) || return 0
	TX_CHECK_AT=$NOW
	(( NOW >= TX_CHECK_UNTIL )) && TX_CHECK_UNTIL=0
	tmux_dropped && (( TX_LOST )) && tx_lost
	return 0
}

# Adapts the window to the time that the last window needed.
link_update() {
	local dt=$1 drain next bps
	(( dt < 1 )) && dt=1
	(( RTT_MS == 0 || dt < RTT_MS )) && RTT_MS=$dt
	bps=$(( TX_WIN_SENT * 1000 / dt ))
	# A small window can pass in one burst of the link. One sample
	# therefore counts as the double of the estimate at most.
	(( LINK_BPS && bps > LINK_BPS * 2 )) && bps=$(( LINK_BPS * 2 ))
	LINK_BPS=$(( LINK_BPS ? (LINK_BPS * 3 + bps) / 4 : bps ))
	# A short last window says little about the link.
	(( TX_WIN_SENT * 2 < TX_WIN )) && return 0
	drain=$(( dt - RTT_MS ))
	(( drain < 1 )) && drain=1
	next=$(( TX_WIN_SENT * WIN_TARGET_MS / drain ))
	(( next > TX_WIN * 2 )) && next=$(( TX_WIN * 2 ))
	(( next < TX_WIN / 2 )) && next=$(( TX_WIN / 2 ))
	(( next < WIN_MIN )) && next=$WIN_MIN
	(( next > WIN_CAP )) && next=$WIN_CAP
	TX_WIN=$next
	D_FOOTER=1
}

# Starts the transfer of the base64 file $1, which holds $2 bytes. No other
# transfer may be active. The caller sets TX_ID, TX_OWNER, TX_C x TX_R (the
# cells), TX_W x TX_H (the pixels), TX_FINAL and TX_RKEY (the key to keep a
# final image under).
tx_begin() {
	[[ -r $1 ]] || return 1
	# The file holds one line for each graphics command. TX_NEXT is one line
	# ahead, so the last line is known as the last.
	exec 8< "$1"
	TX_NEXT=
	IFS= read -r -u 8 TX_NEXT
	TX_ACTIVE=1 TX_STARTED=0 TX_EOF=0 TX_WAIT=0 TX_PAUSED=0
	TX_TOTAL=$2 TX_SENT=0 TX_WIN_SENT=0
	# In fixed-rate mode one question at the start finds a terminal that answers again.
	if [[ $ACK_MODE == off ]] && pane_focused; then
		printf '%s' "$DSR"
		(( PROBES++ ))
	fi
	TX_BASE=-1 TX_LOST=0 TX_CHECK_UNTIL=0
	if [[ $ACK_MODE == off ]] && tmux_counters; then
		TX_BASE=$TMUX_TAKEN
		# A later stage keeps the count of the first one, so a loss
		# between two stages still shows.
		[[ $TX_OWNER == cur ]] && (( STAGE_DONE > 0 )) || TX_DISCARDED=$TMUX_DISCARDED
	fi
	D_DETAILS=1
}

# Stops the transfer. An empty last chunk ends the open command, so the
# terminal drops the partial image.
tx_abort() {
	(( TX_ACTIVE )) || return 0
	exec 8<&-
	local out=
	(( TX_STARTED && ! TX_EOF )) && out+="${GFX_PRE}q=2,m=0;${GFX_SUF}"
	(( TX_STARTED && TX_ID != SHOWN_ID )) && out+="${GFX_PRE}q=2,a=d,d=I,i=${TX_ID}${GFX_SUF}"
	printf '%s' "$out"
	TX_ACTIVE=0 TX_WAIT=0 TX_PAUSED=0
	D_DETAILS=1
}

# Returns success when the window in flight has left the link.
tx_window_released() {
	now_ms
	if [[ $ACK_MODE == on ]]; then
		if (( ACKS >= TX_NEED )); then
			link_update $(( NOW - TX_WIN_AT ))
		elif (( NOW - TX_PROBE_AT < ACK_TIMEOUT_MS )); then
			return 1
		else
			# The answer is lost. Count it as received so the next wait starts clean.
			ACKS=$PROBES
			(( ! ACK_SEEN || ++ACK_MISSES >= 3 )) && ack_mode_off
		fi
	elif (( (NOW - TX_WIN_AT) * RATE_NOW < TX_WIN_SENT * 1000 )); then
		return 1
	elif tmux_dropped; then
		# tmux can be a moment behind with its count of taken bytes, so
		# that verdict waits a little.
		(( NOW - TX_PROBE_AT > 500 )) && TX_LOST=1
		return 1
	fi
	TX_WAIT=0 TX_WIN_SENT=0
	# Fixed-rate mode counts the bytes of tmux, so it must not add screen
	# updates of its own between two windows.
	[[ $ACK_MODE == on ]] && D_DETAILS=1
	return 0
}

# Sends the next part of the image. It returns after one burst at most.
tx_pump() {
	(( TX_ACTIVE )) || return 0
	if (( TX_WAIT )); then
		if ! tx_window_released; then
			(( TX_LOST )) && tx_lost
			return 0
		fi
	fi
	if (( TX_EOF )); then
		tx_done
		return 0
	fi
	if ! pane_focused; then
		(( TX_PAUSED )) || D_DETAILS=1
		TX_PAUSED=1
		return 0
	fi
	(( TX_PAUSED )) && D_DETAILS=1
	TX_PAUSED=0

	local burst=$BURST chunk ctrl more out='' n
	if (( TX_WIN_SENT == 0 )); then
		now_ms
		TX_WIN_AT=$NOW
	fi
	# A window holds whole chunks and never more bytes than TX_WIN.
	while (( burst > 0 && ! TX_EOF && (TX_WIN_SENT == 0 || TX_WIN_SENT + CHUNK <= TX_WIN) )); do
		chunk=$TX_NEXT TX_NEXT=
		IFS= read -r -u 8 TX_NEXT
		[[ -n $TX_NEXT ]] || TX_EOF=1
		more=$(( ! TX_EOF ))
		if (( TX_STARTED )); then
			ctrl="q=2,m=$more"
		else
			ctrl="q=2,a=T,U=1,f=100,i=$TX_ID,c=$TX_C,r=$TX_R,m=$more"
			TX_STARTED=1
		fi
		out+="$GFX_PRE$ctrl;$chunk$GFX_SUF"
		n=${#chunk}
		(( burst -= n, TX_SENT += n, TX_WIN_SENT += n ))
	done
	if (( TX_EOF || TX_WIN_SENT + CHUNK > TX_WIN )); then
		if [[ $ACK_MODE == on ]]; then
			out+=$DSR
			(( PROBES++ ))
			TX_NEED=$PROBES
		fi
		TX_WAIT=1
		now_ms
		TX_PROBE_AT=$NOW
	fi
	printf '%s' "$out"
}

# The whole image is in the terminal. A final image stays there. The image
# of the selection shows, and a preloaded image waits for its turn.
tx_done() {
	exec 8<&-
	TX_ACTIVE=0
	D_DETAILS=1
	if (( TX_BASE >= 0 )); then
		TX_CHECK_UNTIL=$(( NOW + CHECK_MS ))
		# tmux took every byte, so the next image goes out faster. A loss halves the rate again.
		if (( RATE_NOW < RATE_MAX )) && ! tmux_dropped; then
			(( RATE_NOW = RATE_NOW * 3 / 2 ))
			(( RATE_NOW > RATE_MAX )) && RATE_NOW=$RATE_MAX
			rate_window
		fi
	fi
	(( TX_FINAL )) && res_add "$TX_RKEY" "$TX_ID" "$TX_W $TX_H $TX_TOTAL" $(( TX_W * TX_H * 4 ))
	if [[ $TX_OWNER == pf ]]; then
		pf_clear
		return 0
	fi
	STAGE_DONE=$TX_STAGE
	(( TX_ID == SHOWN_ID )) && return 0
	placeholder_block "$TX_ID" "$BOX_X" "$BOX_Y" "$BOX_C" "$BOX_R"
	(( SHOWN_ID )) && OLD_IDS+=" $SHOWN_ID"
	SHOWN_ID=$TX_ID SHOWN_PH=$REPLY
	PV_KIND=image
	D_PREVIEW=1
}

# Takes the shown image off the screen. An image that the terminal keeps
# stays in the terminal.
image_hide() {
	(( SHOWN_ID )) || return 0
	res_has_id "$SHOWN_ID" || gfx_cmd "q=2,a=d,d=I,i=$SHOWN_ID"
	SHOWN_ID=0 SHOWN_PH=
}

# Images that stay in the terminal. Each one is the last stage of a preview,
# kept under the key of its job, so a return to the entry shows it at once.

# Sets REPLY to the index of the kept image with the key $1.
res_find() {
	local i
	for (( i = ${#RES_KEY[@]} - 1; i >= 0; i-- )); do
		if [[ ${RES_KEY[i]} == "$1" ]]; then
			REPLY=$i
			return 0
		fi
	done
	return 1
}

# Succeeds when the image id $1 is kept. Sets REPLY to its index.
res_has_id() {
	local i
	for (( i = 0; i < ${#RES_ID[@]}; i++ )); do
		if (( RES_ID[i] == $1 )); then
			REPLY=$i
			return 0
		fi
	done
	return 1
}

# res_add KEY ID DIM PIXEL_BYTES keeps a finished image. DIM is "w h bytes".
# The oldest images leave the terminal when there are too many or too large.
res_add() {
	res_find "$1" && res_remove "$REPLY"
	RES_KEY+=("$1") RES_ID+=("$2") RES_DIM+=("$3") RES_PX+=("$4")
	(( RES_TOTAL += $4 ))
	local i=0
	while (( ${#RES_KEY[@]} > RES_MAX || RES_TOTAL > RES_BUDGET )) && (( i < ${#RES_KEY[@]} - 1 )); do
		if (( RES_ID[i] == SHOWN_ID )); then
			(( i++ ))
			continue
		fi
		res_remove "$i"
	done
}

# Removes the kept image at index $1. The terminal frees it unless it shows.
res_remove() {
	local i=$1 id=${RES_ID[$1]}
	(( id == SHOWN_ID )) || gfx_cmd "q=2,a=d,d=I,i=$id"
	(( RES_TOTAL -= RES_PX[i] ))
	RES_KEY=("${RES_KEY[@]:0:i}" "${RES_KEY[@]:i+1}")
	RES_ID=("${RES_ID[@]:0:i}" "${RES_ID[@]:i+1}")
	RES_DIM=("${RES_DIM[@]:0:i}" "${RES_DIM[@]:i+1}")
	RES_PX=("${RES_PX[@]:0:i}" "${RES_PX[@]:i+1}")
}

res_drop_id() {
	res_has_id "$1" && res_remove "$REPLY"
	return 0
}

# Shows the kept image at index $1 as the image of the selection.
res_show() {
	local i=$1 id=${RES_ID[$1]} dim=${RES_DIM[$1]}
	(( TX_ACTIVE )) && [[ $TX_OWNER == cur ]] && tx_abort
	STAGE_W=${dim%% *} dim=${dim#* }
	STAGE_H=${dim%% *} STAGE_BYTES=${dim#* }
	STAGE_DONE=$STAGES TX_STAGE=$STAGES
	# The image moves to the end, as the one with the latest use.
	RES_KEY+=("${RES_KEY[i]}") RES_ID+=("$id") RES_DIM+=("${RES_DIM[i]}") RES_PX+=("${RES_PX[i]}")
	(( RES_TOTAL += RES_PX[i] ))
	(( SHOWN_ID && SHOWN_ID != id )) && OLD_IDS+=" $SHOWN_ID"
	SHOWN_ID=$id
	res_remove "$i"
	placeholder_block "$id" "$BOX_X" "$BOX_Y" "$BOX_C" "$BOX_R"
	SHOWN_PH=$REPLY PV_KIND=image
	D_PREVIEW=1 D_DETAILS=1
}
