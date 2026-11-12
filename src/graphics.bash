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
	local hex code mark
	printf -v PH '\U0010EEEE'
	DIA=()
	for hex in $DIA_HEX; do
		printf -v code '%08X' "0x$hex"
		printf -v mark '%b' "\\U$code"
		DIA+=("$mark")
	done
	# The image id travels in a color of the base palette, which every
	# terminal setup keeps intact. The process id spreads the ids of two
	# programs in one terminal.
	ID_A=$(( 16 + $$ % 119 * 2 ))
	ID_B=$(( ID_A + 1 ))
}

# Appends one graphics command to the frame.
gfx_cmd() {
	FRAME+="$GFX_PRE$1$GFX_SUF"
}

# Sets REPLY to the placeholder cells of image $1 at column $2, row $3,
# for a box of $4 columns and $5 rows.
placeholder_block() {
	local id=$1 x=$2 y=$3 cols=$4 rows=$5 row tail=''
	local out=''
	# Only the first cell of a row carries its row and column. A cell with
	# no marks continues the cell on its left, which halves the bytes.
	repeat $(( cols - 1 )) "$PH"
	tail=$REPLY
	for (( row = 0; row < rows; row++ )); do
		out+=$'\e['"$(( y + row ));${x}H$PH${DIA[row]}${DIA[0]}$tail"
	done
	REPLY=$'\e[38;5;'"${id}m$out"$'\e[39m'
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
	TX_WIN=$(( RATE_BPS / 10 ))
	(( TX_WIN < CHUNK )) && TX_WIN=$CHUNK
	(( TX_WIN > WIN_CAP )) && TX_WIN=$WIN_CAP
	human_size "$RATE_BPS"
	status "the terminal does not answer: no flow control, sending $REPLY/s (--rate)"
}

# Adapts the window to the time that the last window needed.
link_update() {
	local dt=$1 drain next bps
	(( dt < 1 )) && dt=1
	(( RTT_MS == 0 || dt < RTT_MS )) && RTT_MS=$dt
	bps=$(( TX_WIN_SENT * 1000 / dt ))
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

# Starts the transfer of the base64 file $1, which holds $2 bytes.
tx_begin() {
	tx_abort
	[[ -r $1 ]] || return 1
	exec {TX_FD}< "$1"
	# A later stage of the shown image keeps its id. The terminal then
	# replaces the picture in place, and the cells stay as they are.
	if (( SHOWN_ID && STAGE_DONE > 0 )); then
		TX_ID=$SHOWN_ID
	elif (( SHOWN_ID == ID_A )); then
		TX_ID=$ID_B
	else
		TX_ID=$ID_A
	fi
	TX_ACTIVE=1 TX_STARTED=0 TX_EOF=0 TX_WAIT=0 TX_PAUSED=0
	TX_TOTAL=$2 TX_SENT=0 TX_WIN_SENT=0
	# In fixed-rate mode one question at the start finds a terminal that answers again.
	if [[ $ACK_MODE == off ]] && pane_focused; then
		printf '%s' "$DSR"
		(( PROBES++ ))
	fi
	D_DETAILS=1
}

# Stops the transfer. An empty last chunk ends the open command, so the
# terminal drops the partial image.
tx_abort() {
	(( TX_ACTIVE )) || return 0
	exec {TX_FD}<&-
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
	elif (( (NOW - TX_WIN_AT) * RATE_BPS < TX_WIN_SENT * 1000 )); then
		return 1
	fi
	TX_WAIT=0 TX_WIN_SENT=0 D_DETAILS=1
	return 0
}

# Sends the next part of the image. It returns after one burst at most.
tx_pump() {
	(( TX_ACTIVE )) || return 0
	if (( TX_WAIT )); then
		tx_window_released || return 0
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
		IFS= read -r -N "$CHUNK" -u "$TX_FD" chunk || TX_EOF=1
		more=$(( ! TX_EOF ))
		if (( TX_STARTED )); then
			ctrl="q=2,m=$more"
		else
			ctrl="q=2,a=T,U=1,f=100,i=$TX_ID,c=$BOX_C,r=$BOX_R,m=$more"
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

# The whole image is in the terminal: show it.
tx_done() {
	exec {TX_FD}<&-
	TX_ACTIVE=0
	STAGE_DONE=$TX_STAGE
	D_DETAILS=1
	(( TX_ID == SHOWN_ID )) && return 0
	placeholder_block "$TX_ID" "$BOX_X" "$BOX_Y" "$BOX_C" "$BOX_R"
	OLD_ID=$SHOWN_ID
	SHOWN_ID=$TX_ID SHOWN_PH=$REPLY
	PV_KIND=image
	D_PREVIEW=1
}

# Removes the shown image from the terminal.
image_hide() {
	(( SHOWN_ID )) || return 0
	gfx_cmd "q=2,a=d,d=I,i=$SHOWN_ID"
	SHOWN_ID=0 SHOWN_PH=
}
