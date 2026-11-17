# Drawing. Every function appends to FRAME, and flush writes the frame once.

flush() {
	[[ -n $FRAME ]] || return 0
	# The terminal shows a synchronized update in one step.
	printf '\e[?2026h%s\e[?2026l' "$FRAME"
	FRAME=
}

# Appends a cursor move to row $1, column $2.
at() {
	FRAME+=$'\e['"$1;$2H"
}

# Erases the rectangle at column $1, row $2 with $3 columns and $4 rows.
clear_rect() {
	local row
	for (( row = $2; row < $2 + $4; row++ )); do
		FRAME+=$'\e['"$row;$1H"$'\e['"$3X"
	done
}

draw_header() {
	local path=$PWD width=$(( COLS - 2 ))
	[[ $path == "$HOME" || $path == "$HOME"/* ]] && path="~${path#"$HOME"}"
	fit_tail "$path" "$width"
	fit "$REPLY" "$width"
	at 1 1
	FRAME+="$S_BAR $REPLY $S_RESET"
}

draw_footer() {
	local left right style=$S_DIM
	if [[ $MODE == search ]]; then
		left="/$SEARCH" style=
	elif [[ -n $STATUS ]]; then
		left=$STATUS style=$S_BOLD
	else
		left='j/k move  h/l dir  z zoom  +/- quality  / search  ? help  q quit'
	fi
	right="$(( N ? CUR + 1 : 0 ))/$N  $SORT  ${QUALITY_NAME[QUALITY]}"
	if (( LINK_BPS )); then
		human_size "$LINK_BPS"
		right+="  $REPLY/s"
	fi
	(( ${#right} + 12 > COLS )) && right=
	fit " $left" $(( COLS - ${#right} - 1 ))
	at "$ROWS" 1
	FRAME+="$style$REPLY$S_RESET$S_DIM$right $S_RESET"
}

# Draws the list row of entry $1 when that row is on the screen.
draw_list_row() {
	local i=$1
	(( L_H > 0 && i >= TOP && i < TOP + L_H )) || return 0
	at $(( L_Y + i - TOP )) "$L_X"
	if (( i >= N )); then
		fit '' "$L_W"
		(( i == 0 )) && fit ' (empty)' "$L_W"
		FRAME+="$S_DIM$REPLY$S_RESET"
		return 0
	fi
	local name=${E_NAME[i]} style='' size='' line
	case ${E_KIND[i]} in
		d) name+=/ style=$S_DIR ;;
		f)
			(( E_IMG[i] )) || style=$S_DIM
			human_size "${E_SIZE[i]}"
			size=$REPLY
			;;
		*) style=$S_DIM ;;
	esac
	(( E_LINK[i] )) && style=$S_LINK
	(( i == CUR )) && style=$S_SEL
	if (( L_W >= 34 )); then
		fit "$name" $(( L_W - 12 ))
		printf -v line ' %s %9s ' "$REPLY" "$size"
	else
		fit "$name" $(( L_W - 2 ))
		line=" $REPLY "
	fi
	FRAME+="$style$line$S_RESET"
}

draw_list() {
	local i
	for (( i = TOP; i < TOP + L_H; i++ )); do
		draw_list_row "$i"
	done
}

draw_separators() {
	local row
	FRAME+=$S_DIM
	if (( SEP_COL )); then
		for (( row = 2; row < ROWS; row++ )); do
			at "$row" "$SEP_COL"
			FRAME+='│'
		done
	fi
	if (( SEP_ROW )); then
		repeat "$COLS" '─'
		at "$SEP_ROW" 1
		FRAME+=$REPLY
	fi
	FRAME+=$S_RESET
}

# Builds DET, the lines of the details pane, as "Label<TAB>value".
details_compose() {
	DET=()
	(( N > 0 )) || return 0
	# The time text can need the date program, so it is kept for the next draw.
	if [[ $WHEN_FOR != "${E_MTIME[CUR]}" ]]; then
		time_text "${E_MTIME[CUR]}"
		WHEN_FOR=${E_MTIME[CUR]} WHEN_TEXT=$REPLY
	fi
	human_size "${E_SIZE[CUR]}"
	DET+=("Name"$'\t'"${E_NAME[CUR]}" "File"$'\t'"$REPLY · $WHEN_TEXT")
	(( ${#JOB_INFO[@]} )) && DET+=("${JOB_INFO[@]}")
	preview_status
	[[ -n $REPLY ]] || return 0
	# The Preview line always shows. It takes the last row when the pane is full.
	(( ${#DET[@]} >= D_H )) && DET=("${DET[@]:0:D_H-1}")
	DET+=("Preview"$'\t'"$REPLY")
}

draw_details() {
	(( D_H > 0 )) || return 0
	details_compose
	local i label
	for (( i = 0; i < D_H; i++ )); do
		at $(( D_Y + i )) "$D_X"
		if (( i >= ${#DET[@]} )); then
			FRAME+=$'\e['"${D_W}X"
			continue
		fi
		printf -v label '%-8s' "${DET[i]%%$'\t'*}"
		fit "${DET[i]#*$'\t'}" $(( D_W - 9 ))
		FRAME+="$S_DIM$label$S_RESET $REPLY"
	done
}

# Draws the preview pane. PV_PAINTED remembers what is on the screen. An empty
# pane is not erased again and a new stage of an image replaces the stage
# without a blank moment.
draw_preview() {
	(( P_H > 0 )) || return 0
	local want=$PV_KIND
	[[ $want == image ]] && want="image $BOX_X $BOX_Y $BOX_C $BOX_R"
	if [[ -n $PV_PAINTED && $PV_PAINTED != "$want" ]]; then
		clear_rect "$P_X" "$P_Y" "$P_W" "$P_H"
	fi
	PV_PAINTED=
	local i
	case $PV_KIND in
		text)
			for (( i = 0; i < P_H && i < ${#PV_TEXT[@]}; i++ )); do
				fit "${PV_TEXT[i]}" "$P_W"
				at $(( P_Y + i )) "$P_X"
				FRAME+="$S_DIM$REPLY$S_RESET"
			done
			PV_PAINTED=text
			;;
		msg | error)
			local style=$S_DIM msg=$PV_MSG
			[[ $PV_KIND == error ]] && style=$S_ERR
			text_width "$msg"
			local cells=$REPLY
			if (( cells > P_W )); then
				fit "$msg" "$P_W"
				msg=$REPLY cells=$P_W
			fi
			at $(( P_Y + P_H / 2 )) $(( P_X + (P_W - cells) / 2 ))
			FRAME+="$style$msg$S_RESET"
			PV_PAINTED=$PV_KIND
			;;
		image)
			if (( SHOWN_ID )); then
				FRAME+=$SHOWN_PH
				PV_PAINTED=$want
			fi
			;;
	esac
	if (( OLD_ID )); then
		gfx_cmd "q=2,a=d,d=I,i=$OLD_ID"
		OLD_ID=0
	fi
}

draw_help() {
	local -a lines=(
		'j k  ↓ ↑        move the selection'
		'g G  Home End   first, last entry'
		'PgDn PgUp  ^D ^U  page, half page'
		'l →  Enter      open a directory, zoom an image'
		'h ←  Backspace  parent directory'
		'~               home directory'
		'z  Tab          zoom: the preview fills the window'
		'+ -             preview quality (draft, normal, fine, full)'
		'i               image previews on or off'
		'/  n N          search, next match, previous match'
		's               sort by name, time, size'
		'.               show hidden files'
		'r  ^L           load again, draw again'
		'q               quit'
	)
	local width=58 height=$(( ${#lines[@]} + 2 )) i
	(( width > COLS - 2 )) && width=$(( COLS - 2 ))
	local x=$(( (COLS - width) / 2 + 1 )) y=$(( (ROWS - height) / 2 + 1 ))
	(( y < 1 )) && y=1
	for (( i = 0; i < height && y + i <= ROWS; i++ )); do
		at $(( y + i )) "$x"
		if (( i == 0 )); then
			fit " $PROG $VERSION: keys" "$width"
			FRAME+="$S_BAR$REPLY$S_RESET"
		elif (( i == height - 1 )); then
			fit ' press a key to close' "$width"
			FRAME+="$S_BAR$REPLY$S_RESET"
		else
			fit "  ${lines[i-1]}" "$width"
			FRAME+=$REPLY
		fi
	done
}

# Draws what the dirty flags name, then writes the frame.
render() {
	if (( TOO_SMALL )); then
		if (( D_ALL )); then
			fit 'window too small' "$COLS"
			FRAME+=$'\e[2J\e[1;1H'"$REPLY"
			D_ALL=0
		fi
		flush
		return
	fi
	if (( D_ALL )); then
		FRAME+=$'\e[0m\e[2J'
		PV_PAINTED=
		D_HEADER=1 D_LIST=1 D_DETAILS=1 D_PREVIEW=1 D_FOOTER=1
		draw_separators
	fi
	(( D_HEADER )) && draw_header
	if (( D_LIST )); then
		draw_list
	else
		local row
		for row in "${DIRTY_ROWS[@]}"; do
			draw_list_row "$row"
		done
	fi
	(( D_DETAILS )) && draw_details
	(( D_PREVIEW )) && draw_preview
	(( D_FOOTER )) && draw_footer
	if (( D_ALL )) && [[ $MODE == help ]]; then
		draw_help
	fi
	D_ALL=0 D_HEADER=0 D_LIST=0 D_DETAILS=0 D_PREVIEW=0 D_FOOTER=0
	DIRTY_ROWS=()
	flush
}
