# Screen layout. All values are in cells, and positions start at one.
#
#   wide                               narrow (stacked)
#   +--------------------------+       +-----------------+
#   | header                   |       | header          |
#   | list  | preview          |       | list            |
#   |       |                  |       |-----------------|
#   |       | details          |       | preview         |
#   | footer                   |       | details         |
#   +--------------------------+       | footer          |
#                                      +-----------------+

layout() {
	term_size
	tmux_window_cap
	TOO_SMALL=0 SEP_COL=0 SEP_ROW=0
	L_W=0 L_H=0 P_W=0 P_H=0 D_W=0 D_H=0
	if (( COLS < 20 || ROWS < 6 )); then
		TOO_SMALL=1
		return
	fi
	local body_y=2 body_h=$(( ROWS - 2 ))
	# The right-hand region holds the preview and, below it, the details.
	local r_x=1 r_y=$body_y r_w=$COLS r_h=$body_h
	if (( ZOOM )); then
		:
	elif (( COLS >= WIDE_MIN_COLS )); then
		L_X=1 L_Y=$body_y L_H=$body_h
		L_W=$(( COLS * 30 / 100 ))
		(( L_W < 26 )) && L_W=26
		(( L_W > 46 )) && L_W=46
		SEP_COL=$(( L_W + 1 ))
		r_x=$(( SEP_COL + 2 ))
		r_w=$(( COLS - r_x + 1 ))
	else
		L_X=1 L_Y=$body_y L_W=$COLS
		L_H=$(( body_h * 30 / 100 ))
		(( L_H < 3 )) && L_H=3
		SEP_ROW=$(( body_y + L_H ))
		r_y=$(( SEP_ROW + 1 ))
		r_h=$(( body_h - L_H - 1 ))
	fi

	D_X=$r_x D_W=$r_w
	D_H=$(( r_h * 2 / 5 ))
	(( D_H > DETAIL_ROWS )) && D_H=$DETAIL_ROWS
	(( r_h < 5 || D_W < 16 )) && D_H=0
	P_X=$r_x P_Y=$r_y P_W=$r_w
	P_H=$(( D_H ? r_h - D_H - 1 : r_h ))
	(( P_H < 1 )) && P_H=0
	D_Y=$(( P_Y + P_H + 1 ))
	(( P_W > ${#DIA[@]} )) && P_W=${#DIA[@]}
	return 0
}

# Sets CELLS_C x CELLS_R to the cells that an image of $1 x $2 pixels covers in
# the preview pane. The image keeps its aspect ratio.
box_cells() {
	local pw=$(( P_W * CELL_W )) ph=$(( P_H * CELL_H ))
	local scale=$(( pw * 1000 / $1 )) other=$(( ph * 1000 / $2 ))
	(( other < scale )) && scale=$other
	(( scale > MAX_UPSCALE * 1000 )) && scale=$(( MAX_UPSCALE * 1000 ))
	local dw=$(( $1 * scale / 1000 )) dh=$(( $2 * scale / 1000 ))
	CELLS_C=$(( (dw + CELL_W - 1) / CELL_W ))
	CELLS_R=$(( (dh + CELL_H - 1) / CELL_H ))
	(( CELLS_C < 1 )) && CELLS_C=1
	(( CELLS_R < 1 )) && CELLS_R=1
	(( CELLS_C > P_W )) && CELLS_C=$P_W
	(( CELLS_R > P_H )) && CELLS_R=$P_H
	return 0
}

# Computes the cells that the image covers: BOX_C x BOX_R at BOX_X, BOX_Y.
# The image sits in the center of the preview pane.
box_compute() {
	box_cells "$IMG_W" "$IMG_H"
	BOX_C=$CELLS_C BOX_R=$CELLS_R
	BOX_X=$(( P_X + (P_W - BOX_C) / 2 ))
	BOX_Y=$(( P_Y + (P_H - BOX_R) / 2 ))
}

# Sets FIT_W and FIT_H to the largest pixel size that the last stage can use.
stage_limit() {
	local pw=$(( P_W * CELL_W )) ph=$(( P_H * CELL_H )) edge=${QUALITY_EDGE[QUALITY]}
	FIT_W=$pw FIT_H=$ph
	(( edge == 0 )) && return 0
	(( FIT_W > edge )) && FIT_W=$edge
	(( FIT_H > edge )) && FIT_H=$edge
	return 0
}
