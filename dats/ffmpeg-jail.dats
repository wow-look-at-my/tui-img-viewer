# Tests with an ffmpeg that a sandbox keeps out of the work directory, even for
# root. Dats/lib/ffmpeg-jail/ffmpeg fails on each path there. imgv must then
# give ffmpeg its data through pipes.
tests:
	- desc: the status line says that previews go through pipes
	  timeout: 60s
	  cmd: IMGV_PATH=$PWD/dats/lib/ffmpeg-jail:${IMGV_PATH:-$PATH} IMGV_ARGS=--no-preload bash dats/lib/drive.sh dats/fixtures/browse w:1 shot:start
	  outputs:
		stdout:
			- "ffmpeg may not open the files in "
			- ": previews go through pipes, with no draft stage"

	- desc: a PNG file that needs scaling has a preview with one stage
	  timeout: 60s
	  cmd: IMGV_PATH=$PWD/dats/lib/ffmpeg-jail:${IMGV_PATH:-$PATH} IMGV_ARGS=--no-preload bash dats/lib/drive.sh dats/fixtures/browse w:1 k:/ k:small $'k:\r' w:3 shot:png
	  outputs:
		stdout:
			- "Preview  normal 586×440"
			- "image 1: 586x440 complete"
			- "images: 1"
		!stdout:
			- "Permission denied"
			- "Preview  failed"

	- desc: a JPEG file with EXIF rotation has a preview through a pipe
	  timeout: 60s
	  cmd: IMGV_PATH=$PWD/dats/lib/ffmpeg-jail:${IMGV_PATH:-$PATH} IMGV_ARGS=--no-preload bash dats/lib/drive.sh dats/fixtures/browse w:1 k:/ k:rotated $'k:\r' w:3 shot:jpeg
	  outputs:
		stdout:
			- "Preview  normal 30×40"
			- "image 1: 30x40 complete"

	- desc: an OpenEXR file goes through the pipe as one packet
	  timeout: 60s
	  cmd: IMGV_PATH=$PWD/dats/lib/ffmpeg-jail:${IMGV_PATH:-$PATH} IMGV_ARGS=--no-preload bash dats/lib/drive.sh dats/fixtures/browse w:1 k:/ k:scene.exr $'k:\r' w:3 shot:exr
	  outputs:
		stdout:
			- "Preview  normal 320×240"
			- "image 1: 320x240 complete"
		!stdout:
			- "Preview  failed"

	- desc: a Radiance file has a preview through a pipe
	  timeout: 60s
	  cmd: IMGV_PATH=$PWD/dats/lib/ffmpeg-jail:${IMGV_PATH:-$PATH} IMGV_ARGS=--no-preload bash dats/lib/drive.sh dats/fixtures/browse w:1 k:/ k:scene.hdr $'k:\r' w:3 shot:hdr
	  outputs:
		stdout:
			- "Preview  normal 320×240"
			- "image 1: 320x240 complete"

	- desc: quick moves over the images in pipe mode end on a full preview
	  timeout: 60s
	  cmd: IMGV_PATH=$PWD/dats/lib/ffmpeg-jail:${IMGV_PATH:-$PATH} IMGV_ARGS=--no-preload bash dats/lib/drive.sh dats/fixtures/browse w:1 k:jj k:j k:j k:j k:j k:j k:j k:j k:j w:3 shot:end
	  outputs:
		stdout:
			- "Name     small.png"
			- "last image: 586x440 complete"
