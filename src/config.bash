# Constants and the mutable state of the program.

readonly VERSION=0.1.0
readonly PROG=imgv

# Timing. Names that end in _S hold seconds, names that end in _MS hold milliseconds.
readonly TICK_IDLE_S=0.25     # loop period when nothing is pending
readonly TICK_BUSY_S=0.02     # loop period while a job or a timer is pending
readonly ESC_WAIT_MS=50       # an escape sequence that stays open this long is dropped
readonly DEBOUNCE_MS=120      # the selection must rest this long before a job starts
readonly HANDSHAKE_MS=3000    # wait this long for the terminal to answer the first queries
readonly ACK_TIMEOUT_MS=4000  # wait this long for one acknowledgement
readonly RETRY_MS=1000        # pause before an image that tmux dropped goes out again
readonly CHECK_MS=1500        # watch tmux for a loss this long after the last byte of an image
readonly STATUS_MS=5000      # a status message stays this long in the footer
readonly FOCUS_CACHE_MS=300   # ask tmux about the pane focus at most this often

# Transfer of image data.
readonly CHUNK=4096           # protocol limit: base64 characters in one graphics command
readonly BURST=65536          # bytes written between looks at the keyboard
readonly WIN_START=16384      # first window size
readonly WIN_MIN=4096
readonly WIN_MAX=524288
readonly WIN_TARGET_MS=250    # one window must drain in about this time

# Rendering.
readonly THUMB_EDGE=256                        # long edge of the draft stage, in pixels
readonly -a QUALITY_EDGE=(0 384 768 1280 0)
readonly -a QUALITY_NAME=('' draft normal fine full)
readonly DIRECT_PNG_MAX=196608   # a PNG file below this size goes to the terminal.
readonly MAX_UPSCALE=4           # a small image grows by this factor at most
readonly CACHE_MAX=48            # finished preview jobs kept for the session
readonly TEXT_LINES=200          # lines of a text or directory preview
readonly WIDE_MIN_COLS=72        # below this width the panes stack
readonly DETAIL_ROWS=10

# Styles. Only attributes and the base colors, so the terminal theme decides the look.
readonly S_RESET=$'\e[0m'
readonly S_BOLD=$'\e[1m'
readonly S_DIM=$'\e[2m'
readonly S_SEL=$'\e[7m'
readonly S_BAR=$'\e[7m'
readonly S_DIR=$'\e[1;34m'
readonly S_LINK=$'\e[36m'
readonly S_ERR=$'\e[31m'

# Sets every global that the program changes while it runs.
state_init() {
	RUNNING=1 MODE=normal NOW=0
	FRAME=
	STATUS='' STATUS_AT=0
	RUN_DIR='' TERM_READY=0 STTY_SAVED='' TMUX_RESTORE=0 IN_TMUX=0
	HAVE_FFMPEG=0 HAVE_FFPROBE=0 HAVE_FILE=0
	# The stat options that print the size and time of an entry, and its mode and owner.
	STAT_LIST=() STAT_MODE=()
	# What this bash and the tools of this host can do.
	READ_FRAC=0 NAP=() SORT_NAME=() TIME_BUILTIN=0 DATE_AT=()

	# Options.
	QUALITY=2 SHOW_HIDDEN=0 SORT=name RATE_BPS=131072 START_PATH=.

	# Screen geometry, in cells. L = list, P = preview, D = details.
	ROWS=24 COLS=80 TOO_SMALL=0 ZOOM=0 RESIZED=0
	L_X=1 L_Y=2 L_W=0 L_H=0 P_X=1 P_Y=2 P_W=0 P_H=0 D_X=1 D_Y=2 D_W=0 D_H=0
	SEP_COL=0 SEP_ROW=0
	CELL_W=10 CELL_H=20 CELL_KNOWN=0 CELL_WAIT_UNTIL=0

	# What must be drawn again.
	D_ALL=1 D_HEADER=0 D_LIST=0 D_DETAILS=0 D_PREVIEW=0 D_FOOTER=0
	DIRTY_ROWS=()

	# Directory listing.
	N=0 CUR=0 TOP=0
	E_NAME=() E_KIND=() E_LINK=() E_SIZE=() E_MTIME=() E_IMG=()
	SEL_DIR=() SEL_NAME=()
	WHEN_FOR='' WHEN_TEXT=''
	SEARCH='' SEARCH_FROM=0

	# Bytes from the terminal that are not handled yet.
	INBUF='' INBUF_AT=0 KEY='' EARLY_FAILS=0

	# Preview pipeline.
	PENDING=0 PENDING_AT=0
	JOB_DIR='' JOB_PID=0 JOB_KEY='' JOB_FINISHED=0 JOB_SEQ=0
	GOT_INFO=0 GOT_TEXT=0 GOT_ERR=0 GOT_GEOM=0
	JOB_INFO=() DET=()
	PV_KIND=none PV_MSG='' PV_TEXT=() PV_PAINTED=''
	IMG_W=0 IMG_H=0 STAGES=0 STAGE_DONE=0 TX_STAGE=0 STAGE_W=0 STAGE_H=0 STAGE_BYTES=0
	BOX_X=0 BOX_Y=0 BOX_C=0 BOX_R=0
	CACHE_KEY=() CACHE_DIR=()

	# Graphics and link state.
	GFX=unknown ACK_MODE=unknown
	GFX_PRE='' GFX_SUF='' DSR='' PH='' DIA=() ID_A=0 ID_B=0
	SHOWN_ID=0 SHOWN_PH='' OLD_ID=0
	HS_PENDING=0 HS_NEED=0 HS_AT=0
	PROBES=0 ACKS=0 ACK_SEEN=0 ACK_MISSES=0
	RTT_MS=0 LINK_BPS=0 WIN_CAP=$WIN_MAX
	FOCUS_AT=-100000 FOCUS_OK=0
	TX_ACTIVE=0 TX_NEXT='' TX_ID=0 TX_STARTED=0 TX_EOF=0 TX_WAIT=0 TX_PAUSED=0
	TX_TOTAL=0 TX_SENT=0 TX_WIN=$WIN_START
	RATE_NOW=0 TX_DISCARDED=0 TX_CHECK_UNTIL=0 TX_CHECK_AT=0 TMUX_TAKEN=0 TMUX_DISCARDED=0
	TX_BASE=-1 TX_LOST=0 TX_RETRY_AT=0 TX_WIN_SENT=0 TX_WIN_AT=0 TX_PROBE_AT=0 TX_NEED=0
}
