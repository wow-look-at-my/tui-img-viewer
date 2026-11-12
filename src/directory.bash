# The directory listing and the selection.

# Reads the current directory into the E_* arrays. Directories come first.
dir_load() {
	local -a sort_args filter=()
	case $SORT in
		time) sort_args=(-t/ -k4,4nr) ;;
		size) sort_args=(-t/ -k3,3nr) ;;
		*) sort_args=(-t/ -k5 -f -V) ;;
	esac
	(( SHOW_HIDDEN )) || filter=('!' -name '.*')

	local -a dn=() dl=() ds=() dm=() fn=() fk=() fl=() fs=() fm=() fimg=()
	local target type size mtime name ext
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
		ext=${name##*.}
		[[ $name == *.* && ${ext,,} == $IMG_EXT ]] && fimg+=(1) || fimg+=(0)
	done < <(find . -mindepth 1 -maxdepth 1 "${filter[@]}" -printf '%Y/%y/%s/%T@/%f\0' 2>/dev/null |
		sort -z "${sort_args[@]}")

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

# Enters the directory $1 and selects the entry named $2 when it exists.
dir_change() {
	local from=$PWD
	(( N > 0 )) && DIR_SEL[$from]=${E_NAME[CUR]}
	if ! cd -- "$1" 2>/dev/null; then
		status "cannot open $1"
		return 1
	fi
	dir_load
	dir_find "${2:-${DIR_SEL[$PWD]-}}"
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
	local step=$1 start=$2 i k name needle=${SEARCH,,}
	[[ -n $needle ]] || return 1
	for (( k = 0; k < N; k++ )); do
		i=$(( (start + k * step % N + N) % N ))
		name=${E_NAME[i],,}
		if [[ $name == *"$needle"* ]]; then
			select_index "$i"
			return 0
		fi
	done
	return 1
}
