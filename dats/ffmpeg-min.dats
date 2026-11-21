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
			- "Preview  normal 586×440"
			- "image 1: 256x192 complete"
			- "image 2: 586x440 complete"
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

	- desc: with a sandbox, a PNG file goes as a mov file through pipes that ffmpeg opens in /proc
	  timeout: 60s
	  cmd: IMGV_PATH=$PWD/dats/lib/ffmpeg-jail:$PWD/.ffmpeg-min/bin:${IMGV_PATH:-$PATH} IMGV_ARGS=--no-preload bash dats/lib/drive.sh dats/fixtures/browse w:1 k:/ k:small $'k:\r' w:4 shot:png
	  outputs:
		stdout:
			- "Preview  normal 586×440"
			- "image 1: 586x440 complete"
			- "images: 1"
		!stdout:
			- "Permission denied"
			- "Preview  failed"

	- desc: an ffmpeg that runs as another user opens the pipes in /proc, and a PNG file is scaled
	  timeout: 60s
	  cmd: JAIL_PIPES=user IMGV_PATH=$PWD/dats/lib/ffmpeg-jail:$PWD/.ffmpeg-min/bin:${IMGV_PATH:-$PATH} IMGV_ARGS=--no-preload bash dats/lib/drive.sh dats/fixtures/browse w:1 k:/ k:small $'k:\r' w:4 shot:png
	  outputs:
		stdout:
			- "Preview  normal 586×440"
			- "image 1: 586x440 complete"
		!stdout:
			- "may open neither"
			- "Preview  failed"

	- desc: a JPEG file says that this ffmpeg has no decoder for it
	  timeout: 60s
	  cmd: IMGV_PATH=$PWD/.ffmpeg-min/bin:${IMGV_PATH:-$PATH} IMGV_ARGS=--no-preload bash dats/lib/drive.sh dats/fixtures/browse w:1.5 k:jj w:2 shot:jpeg
	  outputs:
		stdout:
			- "Name     big.jpg"
			- "this ffmpeg has no mjpeg decoder"
			- "images: 0"
