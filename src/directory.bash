# The directory listing and the selection.

# Prints one record for each entry of the current directory: the type of the
# target, the type of the entry and the size. This also covers the time and
# the name. A NUL ends each record. The output of stat names no file, so its
# lines pair with the names by position.
dir_scan() {
	shopt -s nullglob
	(( SHOW_HIDDEN )) && shopt -s dotglob
	local -a entries=() meta=()
	local name target type try i=0 out
	# An entry can go away between both reads. The scan then starts again.
	for (( try = 0; try < 3; try++ )); do
		entries=(*)
		(( ${#entries[@]} )) || return 0
		out=$(printf './%s\0' "${entries[@]}" | xargs -0 stat "${STAT_LIST[@]}")
		meta=()
		IFS=$'\n' read -r -d '' -a meta <<< "$out"
		(( ${#meta[@]} == ${#entries[@]} )) && break
	done
	(( ${#meta[@]} == ${#entries[@]} )) || return 1
	for name in "${entries[@]}"; do
		target=o type=f
		[[ -L $name ]] && type=l
		if [[ -d $name ]]; then
			target=d
		elif [[ -f $name ]]; then
			target=f
		fi
		printf '%s/%s/%s/%s\0' "$target" "$type" "${meta[i++]}" "$name"
	done
}

# Reads the current directory into the E_* arrays. Directories come first.
dir_load() {
	local -a sort_args
	case $SORT in
		time) sort_args=(-t/ '-k4,4nr') ;;
		size) sort_args=(-t/ '-k3,3nr') ;;
		*) sort_args=("${SORT_NAME[@]}") ;;
	esac

	local -a dn=() dl=() ds=() dm=() fn=() fk=() fl=() fs=() fm=() fimg=()
	local target type size mtime name reason='' failed=0
	# The messages of the tools would damage the screen, so they go to a file.
	(
		set -o pipefail
		dir_scan | sort -z "${sort_args[@]}"
	) > "$RUN_DIR/list" 2> "$RUN_DIR/list.err" || failed=1
	# A name cannot hold a slash, so the slash is a safe field separator.
	while IFS=/ read -r -d '' target type size mtime name; do
		if [[ $target == d ]]; then
			dn+=("$name") ds+=("$size") dm+=("${mtime%.*}")
			[[ $type == l ]] && dl+=(1) || dl+=(0)
			continue
		fi
		fn+=("$name") fs+=("$size") fm+=("${mtime%.*}")
		[[ $type == l ]] && fl+=(1) || fl+=(0)
		if [[ $target != f ]]; then
			fk+=(o) fimg+=(0)
			continue
		fi
		fk+=(f)
		if is_image "$name"; then
			fimg+=(1)
		else
			fimg+=(0)
		fi
	done < "$RUN_DIR/list"
	# The footer shows the first message of the tools.
	if (( failed )); then
		IFS= read -r reason < "$RUN_DIR/list.err"
		status "cannot list this directory: ${reason:-no message}"
	fi

	local -a dk=() di=()
	local i
	for (( i = 0; i < ${#dn[@]}; i++ )); do
		dk+=(d) di+=(0)
	done
	E_NAME=("${dn[@]}" "${fn[@]}")
	E_KIND=("${dk[@]}" "${fk[@]}")
	E_LINK=("${dl[@]}" "${fl[@]}")
	E_SIZE=("${ds[@]}" "${fs[@]}")
	E_MTIME=("${dm[@]}" "${fm[@]}")
	E_IMG=("${di[@]}" "${fimg[@]}")
	N=${#E_NAME[@]}
	[[ -r . && -x . ]] || status "cannot read $PWD"
}

# Sets REPLY to the index of the entry named $1, or to zero.
dir_find() {
	local i
	REPLY=0
	[[ -n $1 ]] || return 0
	for (( i = 0; i < N; i++ )); do
		if [[ ${E_NAME[i]} == "$1" ]]; then
			REPLY=$i
			return 0
		fi
	done
}

# Sets REPLY to the index of the directory $1 in SEL_DIR. An unknown
# directory gives the index of the next free place.
sel_index() {
	for (( REPLY = 0; REPLY < ${#SEL_DIR[@]}; REPLY++ )); do
		[[ ${SEL_DIR[REPLY]} == "$1" ]] && return 0
	done
	return 0
}

# Enters the directory $1 and selects the entry named $2 when it exists.
dir_change() {
	if (( N > 0 )); then
		sel_index "$PWD"
		SEL_DIR[REPLY]=$PWD SEL_NAME[REPLY]=${E_NAME[CUR]}
	fi
	if ! cd -- "$1" 2>/dev/null; then
		status "cannot open $1"
		return 1
	fi
	dir_load
	sel_index "$PWD"
	dir_find "${2:-${SEL_NAME[REPLY]-}}"
	CUR=$REPLY TOP=0
	scroll_fix
	D_ALL=1
	preview_reset
}

# Loads the directory again and keeps the selection on the same name.
dir_reload() {
	local name=
	(( N > 0 )) && name=${E_NAME[CUR]}
	dir_load
	dir_find "$name"
	CUR=$REPLY TOP=0
	scroll_fix
	D_ALL=1
	preview_reset
}

# Moves the top of the list so that the selection is visible.
# The list moves by half a page, which costs fewer redraws on a slow link.
# Returns success when the top moved.
scroll_fix() {
	local top=$TOP h=$L_H
	(( h < 1 )) && h=1
	if (( CUR < TOP )); then
		TOP=$(( CUR - h / 2 ))
	elif (( CUR >= TOP + h )); then
		TOP=$(( CUR - h + 1 + h / 2 ))
	fi
	(( TOP > N - h )) && TOP=$(( N - h ))
	(( TOP < 0 )) && TOP=0
	(( TOP != top ))
}

select_index() {
	local i=$1 old=$CUR
	(( i >= N )) && i=$(( N - 1 ))
	(( i < 0 )) && i=0
	(( i == CUR )) && return 0
	CUR=$i
	if scroll_fix; then
		D_LIST=1
	else
		DIRTY_ROWS+=("$old" "$CUR")
	fi
	D_FOOTER=1
	preview_reset
}

# Opens the selection: a directory is entered, an image is zoomed.
open_selection() {
	(( N > 0 )) || return 0
	case ${E_KIND[CUR]} in
		d) dir_change "${E_NAME[CUR]}" ;;
		f) (( E_IMG[CUR] )) && zoom_toggle ;;
	esac
}

zoom_toggle() {
	ZOOM=$(( ! ZOOM ))
	layout
	scroll_fix
	D_ALL=1
	preview_restart
}

# Selects the next entry whose name holds the search text. $1 is the direction.
search_jump() {
	local step=$1 start=$2 i k found=-1
	[[ -n $SEARCH ]] || return 1
	# The match ignores the case of the letters a to z.
	shopt -s nocasematch
	for (( k = 0; k < N; k++ )); do
		i=$(( (start + k * step % N + N) % N ))
		if [[ ${E_NAME[i]} == *"$SEARCH"* ]]; then
			found=$i
			break
		fi
	done
	shopt -u nocasematch
	(( found >= 0 )) || return 1
	select_index "$found"
	return 0
}
