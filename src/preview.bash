# The preview pipeline: selection, then job, then transfer, then picture.

# The selection changed. Stops all work for the entry and starts the rest
# timer for the new entry.
preview_reset() {
	tx_abort
	job_kill
	image_hide
	JOB_INFO=() PV_TEXT=() PV_KIND=none PV_MSG=
	GOT_INFO=0 GOT_TEXT=0 GOT_ERR=0 GOT_GEOM=0
	STAGES=0 STAGE_DONE=0 TX_STAGE=0
	now_ms
	PENDING=1 PENDING_AT=$NOW
	D_DETAILS=1 D_PREVIEW=1
}

# Starts the preview of the same entry again, for example after a resize.
preview_restart() {
	preview_reset
}

job_kill() {
	if (( JOB_PID && ! JOB_FINISHED )); then
		kill "$JOB_PID" 2>/dev/null
	fi
	JOB_DIR= JOB_PID=0 JOB_KEY= JOB_FINISHED=0
}

# Starts the job for the selected entry, or takes a finished job from the cache.
job_start() {
	PENDING=0
	(( N > 0 )) || return 0
	local name=${E_NAME[CUR]} kind=other
	local path=${PWD%/}/$name
	local -a args=()
	case ${E_KIND[CUR]} in
		d) kind=dir ;;
		f) kind=file ;;
	esac
	if (( E_IMG[CUR] )); then
		kind=image
		local max_w=0 max_h=0
		if [[ $GFX == on ]] && (( P_H > 0 )); then
			stage_limit
			max_w=$FIT_W max_h=$FIT_H
		fi
		args=("$max_w" "$max_h" "${E_SIZE[CUR]}")
	fi

	local key="$kind|$path|${E_MTIME[CUR]}|${E_SIZE[CUR]}|${args[*]}|$SHOW_HIDDEN"
	JOB_FINISHED=0 JOB_PID=0
	if [[ -n ${CACHE[$key]-} && -e ${CACHE[$key]}/done ]]; then
		JOB_DIR=${CACHE[$key]} JOB_KEY=
		return 0
	fi
	JOB_DIR=$RUN_DIR/job$(( ++JOB_SEQ )) JOB_KEY=$key
	mkdir -p -- "$JOB_DIR" || { status 'cannot create a work directory'; JOB_DIR=; return 0; }
	job_spawn "$kind" "$path" "$JOB_DIR" "${args[@]}"
	if [[ $kind == image ]] && (( max_w > 0 )); then
		PV_KIND=msg PV_MSG='loading…' D_PREVIEW=1
	fi
}

# Keeps a finished job for the session. The oldest job leaves the cache first.
cache_add() {
	[[ -n $JOB_KEY ]] || return 0
	CACHE[$JOB_KEY]=$JOB_DIR
	CACHE_ORDER+=("$JOB_KEY")
	JOB_KEY=
	(( ${#CACHE_ORDER[@]} > CACHE_MAX )) || return 0
	local old=${CACHE_ORDER[0]}
	CACHE_ORDER=("${CACHE_ORDER[@]:1}")
	rm -rf -- "${CACHE[$old]}"
	unset 'CACHE[$old]'
}

# Picks up the result files that the job has published since the last look.
job_poll() {
	[[ -n $JOB_DIR ]] || return 0
	local dir=$JOB_DIR
	if (( ! GOT_INFO )) && [[ -e $dir/info ]]; then
		mapfile -t JOB_INFO < "$dir/info"
		GOT_INFO=1 D_DETAILS=1
	fi
	if (( ! GOT_TEXT )) && [[ -e $dir/text ]]; then
		mapfile -t PV_TEXT < "$dir/text"
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
	if (( GOT_GEOM && ! TX_ACTIVE && STAGE_DONE < STAGES )) && [[ $GFX == on ]]; then
		stage_send
	fi
	if (( ! JOB_FINISHED )) && [[ -e $dir/done ]]; then
		JOB_FINISHED=1
		cache_add
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
	tx_begin "$dir/s$stage.b64" "$STAGE_BYTES"
}

# Sets REPLY to the text of the Preview line in the details.
preview_status() {
	REPLY=
	(( N > 0 && E_IMG[CUR] )) || return 0
	case $GFX in
		off) REPLY='off (press i)'; return ;;
		unsupported) REPLY='no graphics support in this terminal (press i to force)'; return ;;
		unknown) REPLY='asking the terminal…'; return ;;
	esac
	if [[ $PV_KIND == error ]]; then
		REPLY='failed'
		return
	fi
	local label=draft size
	(( TX_STAGE >= STAGES )) && label=${QUALITY_NAME[QUALITY]}
	if (( TX_ACTIVE )); then
		human_size "$TX_TOTAL"
		size=$REPLY
		REPLY="$label ${STAGE_W}×${STAGE_H} · $(( TX_TOTAL ? TX_SENT * 100 / TX_TOTAL : 0 ))% of $size"
		(( TX_PAUSED )) && REPLY+=' · paused, pane not focused'
		return
	fi
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
	job_poll
}

# Returns the read timeout for the main loop: zero while data can go out,
# short while something is pending, long when idle.
preview_timeout() {
	if (( TX_ACTIVE && ! TX_WAIT && ! TX_PAUSED )); then
		REPLY=0
	elif (( PENDING || HS_PENDING || TX_PAUSED )) || { [[ -n $JOB_DIR ]] && (( ! JOB_FINISHED )); }; then
		REPLY=$TICK_BUSY_S
	elif (( TX_WAIT )) && [[ $ACK_MODE != on ]]; then
		REPLY=$TICK_BUSY_S
	else
		REPLY=$TICK_IDLE_S
	fi
}
