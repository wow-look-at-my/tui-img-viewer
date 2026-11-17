# Tests of the browser on a fake terminal. dats/lib/drive.sh runs imgv in
# tmux, prints the screen for each shot step, and prints a summary of what
# the terminal received. An image cell shows as "#" on a printed screen.
shared:
	files:
		cover.sh: |
			rc=0
			while IFS= read -r -d '' f; do
				if ! grep -qF -- "${f##*/}" dats/tui.dats; then
					echo "no test names $f"
					rc=1
				fi
			done < <(find dats/fixtures/browse -type f -print0)
			exit "$rc"
		xargs: |
			#!/bin/sh
			echo 'xargs: broken on purpose' >&2
			exit 1
		od: |
			#!/bin/sh
			echo 'od: this one knows no options' >&2
			exit 1

# An image with much detail: its preview is too large for the buffers
# between tmux and a slow terminal.
setup: ffmpeg -nostdin -v error -f lavfi -i mandelbrot=size=1200x800:rate=1 -frames:v 1 -q:v 3 {shared.detail.jpg}

tests:
	- desc: every file in the browse fixtures is named by a test
	  cmd: bash {shared.cover.sh}

	- desc: the first screen shows the list, the details and a directory preview
	  timeout: 60s
	  cmd: bash dats/lib/drive.sh dats/fixtures/browse w:1.5 shot:start
	  outputs:
		stdout:
			- " sub/"
			- " big.jpg"
			- " small.png"
			- " notes.txt"
			- "Name     sub"
			- "Type     directory"
			- "Items    1, images: 1"
			- "inner.png"
			- "1/11  name  normal"
			- "? help  q quit"
			- "images: 0"
		!stdout:
			- ".hidden-note.txt"

	- desc: a listing that fails shows the reason in the footer
	  timeout: 60s
	  cmd: mkdir -p {outputs.bin} && cp {shared.xargs} {outputs.bin}/xargs && chmod +x {outputs.bin}/xargs && IMGV_PATH={outputs.bin}:${IMGV_PATH:-$PATH} bash dats/lib/drive.sh dats/fixtures/browse w:1.5 shot:broken
	  outputs:
		stdout:
			- " (empty)"
			- "cannot list this directory: xargs: broken on purpose"
			- "0/0  name  normal"

	- desc: a host whose od cannot read bytes says so in the footer
	  timeout: 60s
	  cmd: mkdir -p {outputs.bin} && cp {shared.od} {outputs.bin}/od && chmod +x {outputs.bin}/od && IMGV_PATH={outputs.bin}:${IMGV_PATH:-$PATH} bash dats/lib/drive.sh dats/fixtures/browse w:1.5 shot:od
	  outputs:
		stdout:
			- "the od of this host cannot read bytes: images show no details and no preview"

	- desc: a name with accents and wide characters keeps the columns in line, and the file time shows
	  timeout: 60s
	  cmd: mkdir -p {outputs.d} && printf 'hello' > {outputs.d}/Ünï-写真.txt && touch -d @1700000000 {outputs.d}/Ünï-写真.txt && TZ=UTC bash dats/lib/drive.sh {outputs.d} w:1.5 shot:names k:/ k:写 w:1 shot:search $'k:\r'
	  outputs:
		stdout:
			- " Ünï-写真.txt                   5 B"
			- "Name     Ünï-写真.txt"
			- "File     5 B · 2023-11-14 22:13"
			- "/写"

	- desc: the arrow keys and the Home and End keys move the selection, and a lone escape key ends a search
	  timeout: 60s
	  cmd: bash dats/lib/drive.sh dats/fixtures/browse w:1 $'k:\e[B' w:0.3 $'k:\e[B' w:1.5 shot:arrows $'k:\e[F' w:1.5 shot:end $'k:\eOH' w:0.5 k:/ k:tall w:0.5 $'k:\e' w:1.5 shot:escape
	  outputs:
		stdout:
			- "Name     broken.jpg"
			- "Name     tall.webp"
			- "Name     sub"

	- desc: a large image arrives through tmux as a draft and then in full
	  timeout: 60s
	  cmd: bash dats/lib/drive.sh dats/fixtures/browse w:1.5 k:j w:4 shot:image
	  outputs:
		stdout:
			- "Name     big.jpg"
			- "Type     JPEG · YCbCr 8-bit · baseline"
			- "Image    1600×1200 · 1.9 MP · 4:3"
			- "Preview  normal 586×440"
			- "################"
			- "image 1: 256x192 complete"
			- "image 2: 586x440 complete"
			- "images: 2"
			- "graphics query: yes"
			- "windows over the limit: 0"
			- "image cells on the terminal: yes"

	- desc: the same image arrives without tmux
	  timeout: 60s
	  cmd: MODE=direct bash dats/lib/drive.sh dats/fixtures/browse w:1.5 k:j w:4
	  outputs:
		stdout:
			- "image 1: 256x192 complete"
			- "image 2: 613x460 complete"
			- "images: 2"
			- "graphics query: yes"
			- "image cells on the terminal: yes"

	- desc: a tmux client that is not in UTF-8 mode gets a clear message and no image
	  timeout: 60s
	  cmd: CLIENT_LOCALE=C bash dats/lib/drive.sh dats/fixtures/browse w:1.5 k:j w:2 shot:plain
	  outputs:
		stdout:
			- 'tmux is not in UTF-8 mode: attach with "tmux -u", then press i'
			- "images: 0"
			- "image cells on the terminal: no"

	- desc: on a slow link through tmux a key stops the transfer at once
	  timeout: 90s
	  cmd: RATE=20000 bash dats/lib/drive.sh dats/fixtures/browse w:1.5 k:j w:3.5 k:j w:3 shot:after
	  outputs:
		stdout:
			- "image 1: 256x192 complete"
			- "image 2: stopped soon after a key"
			- "images: 2"
			- "windows over the limit: 0"
			- "Name     broken.jpg"
			- "this image format is not recognized"

	- desc: on a slow link without tmux a key stops the transfer at once
	  timeout: 90s
	  cmd: MODE=direct RATE=20000 bash dats/lib/drive.sh dats/fixtures/browse w:1.5 k:j w:3.5 k:j w:3
	  outputs:
		stdout:
			- "image 1: 256x192 complete"
			- "image 2: stopped soon after a key"
			- "images: 2"

	- desc: an image with an EXIF rotation is turned, and its camera data shows
	  timeout: 60s
	  cmd: bash dats/lib/drive.sh dats/fixtures/browse w:1.5 k:jjjjj w:3 shot:rotated
	  outputs:
		stdout:
			- "Name     rotated.jpg"
			- "Image    30×40 · 0.0 MP · 3:4 · EXIF rotation 6"
			- "Camera   TestMake TestModel X1"
			- "Shot     f/1.8 · 1/120 s · ISO 64 · 6.8 mm"
			- "Taken    2025:08:01 10:22:11"
			- "Lens     Test Lens 24mm"
			- "image 1: 30x40 complete"
			- "images: 1"

	- desc: a small PNG file goes to the terminal as it is
	  timeout: 60s
	  cmd: bash dats/lib/drive.sh dats/fixtures/browse w:1 k:l w:2.5 shot:png
	  outputs:
		stdout:
			- "Name     inner.png"
			- "Type     PNG · RGBA 8-bit"
			- "image 1: 64x64 complete"
			- "images: 1"

	- desc: an OpenEXR picture shows its details and a preview
	  timeout: 60s
	  cmd: bash dats/lib/drive.sh dats/fixtures/browse w:1 k:/ k:scene.exr $'k:\r' w:4 shot:exr
	  outputs:
		stdout:
			- "Name     scene.exr"
			- "Type     EXR · RGB 16-bit · ZIP, half"
			- "Image    320×240"
			- "image 1: 320x240 complete"
			- "images: 1"

	- desc: a Radiance HDR picture shows its details and a preview
	  timeout: 60s
	  cmd: bash dats/lib/drive.sh dats/fixtures/browse w:1 k:/ k:scene.hdr $'k:\r' w:5 shot:hdr
	  outputs:
		stdout:
			- "Name     scene.hdr"
			- "Type     HDR · RGB · RGBE"
			- "Image    320×240"
			- "image 1: 320x240 complete"
			- "images: 1"

	- desc: a tall image keeps its shape
	  timeout: 60s
	  cmd: bash dats/lib/drive.sh dats/fixtures/browse w:1.5 k:G w:3 shot:tall
	  outputs:
		stdout:
			- "Name     tall.webp"
			- "Type     WebP · YCbCr 8-bit · lossy"
			- "Image    320×900"
			- "image 1: 91x256 complete"
			- "image 2: 156x440 complete"

	- desc: a terminal without graphics support gets no image data
	  timeout: 60s
	  cmd: FAKE_NO_GRAPHICS=1 bash dats/lib/drive.sh dats/fixtures/browse w:1 k:j w:2 shot:plain
	  outputs:
		stdout:
			- "Image    1600×1200"
			- "no graphics support in this terminal"
			- "images: 0"
			- "graphics query: yes"

	# tmux also gets no answer from this terminal. It then draws the whole screen
	# again one time, and it drops image data that waits behind that drawing.
	# The byte counts of tmux do not show such a loss, so the key comes later.
	- desc: a terminal that answers nothing still gets the image, at a fixed rate
	  timeout: 90s
	  cmd: FAKE_MUTE=1 bash dats/lib/drive.sh dats/fixtures/browse w:5.5 shot:mute k:j w:6
	  outputs:
		stdout:
			- "the terminal does not answer: no flow control"
			- "image 2: 586x440 complete"
			- "images: 2"

	- desc: a terminal that answers nothing gets a whole image on a slow link through tmux
	  timeout: 150s
	  cmd: FAKE_MUTE=1 RATE=20000 bash dats/lib/drive.sh {shared.detail.jpg} w:60
	  outputs:
		stdout:
			- "last image: 660x440 complete"

	- desc: the option --no-images sends no graphics at all
	  timeout: 60s
	  cmd: IMGV_ARGS=--no-images bash dats/lib/drive.sh dats/fixtures/browse w:1 k:j w:1.5 shot:off
	  outputs:
		stdout:
			- "Image    1600×1200"
			- "Preview  off (press i)"
			- "images: 0"
			- "graphics query: no"

	- desc: a text file shows its first lines
	  timeout: 60s
	  cmd: bash dats/lib/drive.sh dats/fixtures/browse w:1 k:/ k:settings $'k:\r' w:1.5 shot:text
	  outputs:
		stdout:
			- "Name     settings.conf"
			- "[viewer]"
			- "quality = normal"
			- "    indented = with a tab"
			- "last = line"

	- desc: a binary file and a broken image say what they are
	  timeout: 60s
	  cmd: bash dats/lib/drive.sh dats/fixtures/browse w:1 k:jjj w:1.5 shot:binary k:k w:1.5 shot:broken
	  outputs:
		stdout:
			- "Name     data.bin"
			- "(binary file)"
			- "Name     broken.jpg"
			- "this image format is not recognized"

	- desc: a narrow window stacks the list above the preview
	  timeout: 60s
	  cmd: COLS=60 ROWS=30 bash dats/lib/drive.sh dats/fixtures/browse w:1.5 k:j w:4 shot:narrow
	  outputs:
		stdout:
			- "────────────────────────────────────────────────────────────"
			- " big.jpg"
			- "########"
			- "Name     big.jpg"
			- "image 1: 266x200 complete"
			- "windows over the limit: 0"

	- desc: a window that is too small says so
	  timeout: 60s
	  cmd: COLS=18 ROWS=5 bash dats/lib/drive.sh dats/fixtures/browse w:1 shot:tiny
	  outputs:
		stdout:
			- "window too small"

	- desc: zoom hides the list and keeps the image
	  timeout: 60s
	  cmd: bash dats/lib/drive.sh dats/fixtures/browse w:1.5 k:j w:3 k:z w:3 shot:zoom
	  outputs:
		stdout:
			- "Name     big.jpg"
			- "################"
		!stdout:
			- " sub/"

	- desc: search moves the selection to the match
	  timeout: 60s
	  cmd: bash dats/lib/drive.sh dats/fixtures/browse w:1 k:/ k:tall $'k:\r' w:1.5 shot:search
	  outputs:
		stdout:
			- "Name     tall.webp"
			- "11/11  name  normal"

	- desc: the dot key shows hidden files and the s key changes the sort order
	  timeout: 60s
	  cmd: bash dats/lib/drive.sh dats/fixtures/browse w:1 k:. w:1 k:s w:1 shot:hidden
	  outputs:
		stdout:
			- ".hidden-note.txt"
			- "/12  time  normal"

	- desc: a directory opens and the parent comes back with the same selection
	  timeout: 60s
	  cmd: bash dats/lib/drive.sh dats/fixtures/browse w:1 k:l w:1.5 shot:inside k:h w:1.5 shot:back
	  outputs:
		stdout:
			- "Name     inner.png"
			- "1/1  name  normal"
			- "Name     sub"
			- "1/11  name  normal"

	- desc: the help key lists the keys, and the next key closes the list
	  timeout: 60s
	  cmd: bash dats/lib/drive.sh dats/fixtures/browse w:1 'k:?' w:1 shot:help k:x w:0.5
	  outputs:
		stdout:
			- "imgv 0.1.0: keys"
			- "press a key to close"
