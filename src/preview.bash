# The preview pipeline: selection, then job, then transfer, then picture.
# A finished image stays in the terminal, so a return to it shows it at once.
# When the selection is done, the images near it load ahead.

# The selection changed. Stops the work for the entry and starts the rest
# timer for the new entry. A finished job of the new entry shows at once.
preview_reset() {
	local key=
	if (( N > 0 )); then
		job_args "$CUR"
		key=$JA_KEY
	fi
	# A preload of the new entry continues as its own job.
	[[ -n $PF_KEY && $PF_KEY == "$key" ]] || pf_stop
	(( TX_ACTIVE )) && [[ $TX_OWNER == cur ]] && tx_abort
	job_kill
	image_hide
	JOB_INFO=() PV_TEXT=() PV_KIND=none PV_MSG=
	GOT_INFO=0 GOT_TEXT=0 GOT_ERR=0 GOT_GEOM=0
	STAGES=0 STAGE_DONE=0 TX_STAGE=0
	CUR_KEY=$key PF_NONE=0
	now_ms
	PENDING=1 PENDING_AT=$NOW
	D_DETAILS=1 D_PREVIEW=1
	[[ -n $key ]] || return 0
	if (( ! HS_PENDING && NOW >= CELL_WAIT_UNTIL )) && { [[ $PF_KEY == "$key" ]] || cache_find "$key"; }; then
		job_start
		job_poll
	fi
}

# Starts the preview of the same entry again, for example after a resize.
preview_restart() {
	preview_reset
}

job_kill() {
	if (( JOB_PID && ! JOB_FINISHED )); then
		kill "$JOB_PID" 2>/dev/null
	fi
	JOB_DIR='' JOB_PID=0 JOB_KEY='' JOB_FINISHED=0
}

# The key names everything that the result depends on.
job_args() {
	local i=$1
	JA_PATH=${PWD%/}/${E_NAME[i]} JA_KIND=other JA_ARGS=()
	case ${E_KIND[i]} in
		d) JA_KIND='dir' ;;
		f) JA_KIND='file' ;;
	esac
	if (( E_IMG[i] )); then
		JA_KIND=image
		local max_w=0 max_h=0
		if [[ $GFX == on ]] && (( P_H > 0 )); then
			stage_limit
			max_w=$FIT_W max_h=$FIT_H
		fi
		JA_ARGS=("$max_w" "$max_h" "${E_SIZE[i]}")
	fi
	JA_KEY="$JA_KIND|$JA_PATH|${E_MTIME[i]}|${E_SIZE[i]}|${JA_ARGS[*]}|$SHOW_HIDDEN|$P_W $P_H $CELL_W $CELL_H $FILTER"
}

# Starts the job for the selected entry. A finished job comes from the cache,
# and a preload of the entry becomes its job.
job_start() {
	PENDING=0
	(( N > 0 )) || return 0
	job_args "$CUR"
	CUR_KEY=$JA_KEY
	JOB_FINISHED=0 JOB_PID=0 JOB_KEY=
	if cache_find "$JA_KEY"; then
		JOB_DIR=$REPLY
		[[ $PF_KEY == "$JA_KEY" ]] && (( ! TX_ACTIVE )) && pf_clear
		return 0
	fi
	if [[ -n $PF_DIR && $PF_KEY == "$JA_KEY" ]]; then
		JOB_DIR=$PF_DIR JOB_PID=$PF_PID JOB_KEY=$PF_KEY
		pf_clear
	else
		JOB_DIR=$RUN_DIR/job$(( ++JOB_SEQ )) JOB_KEY=$JA_KEY
		mkdir -p -- "$JOB_DIR" || { status 'cannot create a work directory'; JOB_DIR=; return 0; }
		job_spawn "$JA_KIND" "$JA_PATH" "$JOB_DIR" "${JA_ARGS[@]}"
		JOB_PID=$REPLY
	fi
	if [[ $JA_KIND == image ]] && (( JA_ARGS[0] > 0 )); then
		PV_KIND=msg PV_MSG='loading…' D_PREVIEW=1
	fi
}

# Sets REPLY to the directory of the finished job with the key $1.
cache_find() {
	local i
	for (( i = 0; i < ${#CACHE_KEY[@]}; i++ )); do
		if [[ ${CACHE_KEY[i]} == "$1" && -e ${CACHE_DIR[i]}/done ]]; then
			REPLY=${CACHE_DIR[i]}
			return 0
		fi
	done
	return 1
}

# Keeps the finished job with the key $1 in the directory $2 for the session.
# The oldest job leaves the cache first.
cache_add() {
	CACHE_KEY+=("$1") CACHE_DIR+=("$2")
	(( ${#CACHE_KEY[@]} > CACHE_MAX )) || return 0
	rm -rf -- "${CACHE_DIR[0]}"
	CACHE_KEY=("${CACHE_KEY[@]:1}") CACHE_DIR=("${CACHE_DIR[@]:1}")
}

# Picks up the result files that the job has published since the last look.
job_poll() {
	[[ -n $JOB_DIR ]] || return 0
	local dir=$JOB_DIR
	if (( ! GOT_INFO )) && [[ -e $dir/info ]]; then
		read_lines JOB_INFO "$dir/info"
		GOT_INFO=1 D_DETAILS=1
	fi
	if (( ! GOT_TEXT )) && [[ -e $dir/text ]]; then
		read_lines PV_TEXT "$dir/text"
		GOT_TEXT=1 PV_KIND=text D_PREVIEW=1
	fi
	if (( ! GOT_ERR )) && [[ -e $dir/err ]]; then
		IFS= read -r PV_MSG < "$dir/err"
		GOT_ERR=1 PV_KIND=error D_PREVIEW=1 D_DETAILS=1
	fi
	if (( ! GOT_GEOM )) && [[ -e $dir/geom ]]; then
		read -r IMG_W IMG_H STAGES < "$dir/geom"
		GOT_GEOM=1
		box_compute
	fi
	if (( GOT_GEOM && STAGE_DONE < STAGES )) && [[ $GFX == on ]]; then
		if res_find "$CUR_KEY"; then
			res_show "$REPLY"
		elif (( ! TX_ACTIVE && NOW >= TX_RETRY_AT )); then
			stage_send
		fi
	fi
	if (( ! JOB_FINISHED )) && [[ -e $dir/done ]]; then
		JOB_FINISHED=1
		[[ -n $JOB_KEY ]] && cache_add "$JOB_KEY" "$dir"
		JOB_KEY=
	fi
	return 0
}

# Starts the transfer of the next stage that is ready.
stage_send() {
	local dir=$JOB_DIR stage=$(( STAGE_DONE + 1 ))
	# The draft stage only helps when the last stage needs a long time.
	if (( stage < STAGES )) && [[ -e $dir/s$STAGES.b64 ]] && (( LINK_BPS > 0 )); then
		local w h bytes
		read -r w h bytes < "$dir/s$STAGES.dim"
		(( bytes * 1000 / LINK_BPS < WIN_TARGET_MS * 2 )) && stage=$STAGES
	fi
	[[ -e $dir/s$stage.b64 ]] || return 0
	read -r STAGE_W STAGE_H STAGE_BYTES < "$dir/s$stage.dim"
	TX_STAGE=$stage
	# A later stage of the shown image keeps its id. The terminal then
	# replaces the picture in place, and the cells stay as they are.
	if (( SHOWN_ID && STAGE_DONE > 0 )); then
		TX_ID=$SHOWN_ID
	else
		slot_new
		TX_ID=$REPLY
	fi
	TX_OWNER=cur TX_C=$BOX_C TX_R=$BOX_R TX_W=$STAGE_W TX_H=$STAGE_H
	TX_FINAL=$(( stage == STAGES )) TX_RKEY=$CUR_KEY
	tx_begin "$dir/s$stage.b64" "$STAGE_BYTES"
}

# Stops the preload: its transfer and its job.
pf_stop() {
	[[ -n $PF_KEY ]] || return 0
	(( TX_ACTIVE )) && [[ $TX_OWNER == pf ]] && tx_abort
	if (( PF_PID && ! PF_FINISHED )); then
		if [[ -e $PF_DIR/done ]]; then
			cache_add "$PF_KEY" "$PF_DIR"
		else
			kill "$PF_PID" 2>/dev/null
		fi
	fi
	pf_clear
}

pf_clear() {
	PF_KEY='' PF_DIR='' PF_PID=0 PF_FINISHED=0
}

# Starts the preload of the next image near the selection that the terminal
# does not have yet. Images in the direction of the last move come first.
pf_pick() {
	local d s i
	for (( d = 1; d <= PRELOAD_RADIUS; d++ )); do
		for s in "$MOVE_DIR" $(( -MOVE_DIR )); do
			i=$(( CUR + s * d ))
			(( i >= 0 && i < N )) || continue
			(( E_IMG[i] )) || continue
			job_args "$i"
			res_find "$JA_KEY" && continue
			[[ $PF_SKIP == *$'\n'"$JA_KEY"$'\n'* ]] && continue
			PF_KEY=$JA_KEY PF_PID=0 PF_FINISHED=0
			if cache_find "$JA_KEY"; then
				PF_DIR=$REPLY PF_FINISHED=1
				return 0
			fi
			PF_DIR=$RUN_DIR/job$(( ++JOB_SEQ ))
			if ! mkdir -p -- "$PF_DIR"; then
				pf_clear
				return 1
			fi
			job_spawn "$JA_KIND" "$JA_PATH" "$PF_DIR" "${JA_ARGS[@]}"
			PF_PID=$REPLY
			return 0
		done
	done
	PF_NONE=1
	return 1
}

# One step of the preload. It waits until the selection has its whole preview.
preload_tick() {
	(( PRELOAD && N > 0 )) && [[ $GFX == on ]] || return 0
	(( ! PENDING && ! HS_PENDING && NOW >= CELL_WAIT_UNTIL && NOW - PENDING_AT >= DEBOUNCE_MS )) || return 0
	[[ -z $JOB_DIR ]] || (( JOB_FINISHED )) || return 0
	if (( E_IMG[CUR] )) && [[ $PV_KIND != error ]]; then
		(( GOT_GEOM && STAGE_DONE >= STAGES )) || return 0
	fi
	(( TX_ACTIVE )) && [[ $TX_OWNER == cur ]] && return 0
	if [[ -z $PF_KEY ]]; then
		(( PF_NONE )) && return 0
		pf_pick || return 0
	fi
	if (( ! PF_FINISHED )); then
		[[ -e $PF_DIR/done ]] || return 0
		PF_FINISHED=1
		cache_add "$PF_KEY" "$PF_DIR"
	fi
	(( TX_ACTIVE || TX_CHECK_UNTIL || NOW < TX_RETRY_AT )) && return 0
	local w h stages bytes
	if [[ ! -e $PF_DIR/geom ]]; then
		# This image has no preview, for example a damaged file.
		PF_SKIP+="$PF_KEY"$'\n'
		pf_clear
		return 0
	fi
	read -r w h stages < "$PF_DIR/geom"
	if [[ ! -e $PF_DIR/s$stages.dim ]]; then
		PF_SKIP+="$PF_KEY"$'\n'
		pf_clear
		return 0
	fi
	box_cells "$w" "$h"
	slot_new
	TX_ID=$REPLY TX_OWNER=pf TX_C=$CELLS_C TX_R=$CELLS_R TX_FINAL=1 TX_RKEY=$PF_KEY
	read -r TX_W TX_H bytes < "$PF_DIR/s$stages.dim"
	tx_begin "$PF_DIR/s$stages.b64" "$bytes" || pf_clear
}

# Sets REPLY to the text of the Preview line in the details.
preview_status() {
	REPLY=
	(( N > 0 && E_IMG[CUR] )) || return 0
	case $GFX in
		off) REPLY='off (press i)'; return ;;
		unsupported) REPLY='no graphics support in this terminal (press i to force)'; return ;;
		unknown) REPLY='asking the terminal…'; return ;;
		noutf8) REPLY='tmux is not in UTF-8 mode: attach with "tmux -u", then press i'; return ;;
	esac
	if [[ $PV_KIND == error ]]; then
		REPLY='failed'
		return
	fi
	local label=draft size
	if (( TX_ACTIVE )) && [[ $TX_RKEY == "$CUR_KEY" ]]; then
		(( TX_FINAL )) && label=${QUALITY_NAME[QUALITY]}
		human_size "$TX_TOTAL"
		size=$REPLY
		if [[ $ACK_MODE == on ]]; then
			REPLY="$label ${TX_W}×${TX_H} · $(( TX_TOTAL ? TX_SENT * 100 / TX_TOTAL : 0 ))% of $size"
		else
			REPLY="$label ${TX_W}×${TX_H} · sending $size, no flow control"
		fi
		(( TX_PAUSED )) && REPLY+=' · paused, pane not focused'
		return
	fi
	(( TX_STAGE >= STAGES )) && label=${QUALITY_NAME[QUALITY]}
	if (( STAGE_DONE > 0 )); then
		human_size "$STAGE_BYTES"
		REPLY="$label ${STAGE_W}×${STAGE_H} · $REPLY"
		(( STAGE_DONE < STAGES )) && REPLY+=' · refining…'
		return
	fi
	(( PENDING )) || REPLY='rendering…'
}

# One step of the pipeline. The main loop calls it on every pass.
preview_tick() {
	handshake_tick
	if (( PENDING )) && (( NOW - PENDING_AT >= DEBOUNCE_MS )); then
		# An image job needs the answers of the terminal: graphics support and cell size.
		if (( ! HS_PENDING && NOW >= CELL_WAIT_UNTIL )); then
			job_start
		fi
	fi
	tx_pump
	tx_check
	job_poll
	preload_tick
}

# Sets REPLY to the wait of the main loop for input: "none" while data can go
# out, "busy". This happens while something is pending, "idle" for the rest.
preview_timeout() {
	if (( TX_ACTIVE && ! TX_WAIT && ! TX_PAUSED )); then
		REPLY=none
	elif (( PENDING || HS_PENDING || TX_PAUSED )) || { [[ -n $JOB_DIR ]] && (( ! JOB_FINISHED )); }; then
		REPLY=busy
	elif (( TX_WAIT )) && [[ $ACK_MODE != on ]]; then
		REPLY=busy
	elif (( TX_CHECK_UNTIL || TX_RETRY_AT > NOW )); then
		REPLY=busy
	elif [[ -n $PF_KEY ]] && (( ! PF_FINISHED || ! TX_ACTIVE )); then
		REPLY=busy
	else
		REPLY=idle
	fi
}
