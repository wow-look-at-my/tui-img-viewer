# Tests with a small ffmpeg like the one of an embedded system: it has no
# image2 demuxer or muxer. PNG is its only image decoder. The setup builds it
# in .ffmpeg-min the first time, which takes some minutes.
setup: bash dats/lib/ffmpeg-min.sh .ffmpeg-min

tests:
	- desc: a PNG file that needs scaling goes through the mov format
	  timeout: 60s
	  cmd: IMGV_PATH=$PWD/.ffmpeg-min/bin:${IMGV_PATH:-$PATH} IMGV_ARGS=--no-preload bash dats/lib/drive.sh dats/fixtures/browse w:1 k:/ k:small $'k:\r' w:4 shot:png
	  outputs:
		stdout:
			- "Name     small.png"
			- "Preview  normal 613×460"
			- "image 1: 256x192 complete"
			- "image 2: 613x460 complete"
			- "images: 2"
		!stdout:
			- "Option not found"

	- desc: nearest scaling of a small PNG file goes through the mov format
	  timeout: 60s
	  cmd: IMGV_PATH=$PWD/.ffmpeg-min/bin:${IMGV_PATH:-$PATH} IMGV_ARGS='--no-preload --filter nearest' bash dats/lib/drive.sh dats/fixtures/browse w:1 k:l w:2.5
	  outputs:
		stdout:
			- "image 1: 260x260 complete"
			- "images: 1"

	- desc: a JPEG file says that this ffmpeg has no decoder for it
	  timeout: 60s
	  cmd: IMGV_PATH=$PWD/.ffmpeg-min/bin:${IMGV_PATH:-$PATH} IMGV_ARGS=--no-preload bash dats/lib/drive.sh dats/fixtures/browse w:1.5 k:jj w:2 shot:jpeg
	  outputs:
		stdout:
			- "Name     big.jpg"
			- "this ffmpeg has no mjpeg decoder"
			- "images: 0"
