# Tests for src/metadata.bash. Run dats/fixtures/make-meta-fixtures.sh to
# rebuild the fixtures. dats/lib/run.sh runs each probe with the shell and
# the tools under test. A bash that accepts an empty array under nounset
# runs every probe under nounset.
shared:
	files:
		lib.sh: |
			if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
				set -o nounset
			fi
			source src/metadata.bash
			# Prints each result that is known, in the order of the key names.
			meta_dump() {
				local k v
				for k in $META_KEYS; do
					v=META_$k
					[[ -n ${!v} ]] && printf '%s=%s\n' "$k" "${!v}"
				done
				return 0
			}
		probe.sh: |
			source {shared.lib.sh}
			if ! meta_probe "$1"; then
				echo "meta_probe failed on $1"
				exit 1
			fi
			meta_dump
		neg.sh: |
			source {shared.lib.sh}
			meta_probe "$1"
			echo "rc=$? keys=$(( $(meta_dump | wc -l) ))"
		twice.sh: |
			source {shared.lib.sh}
			meta_probe dats/fixtures/meta/jpeg-exif-le.jpg
			meta_probe dats/fixtures/meta/png-rgb.png
			echo "${META_make:-unset} $(( $(meta_dump | wc -l) ))"
		options.sh: |
			o1=$(set -o)
			source src/metadata.bash
			meta_probe dats/fixtures/meta/jpeg-exif-le.jpg
			o2=$(set -o)
			[[ $o1 == "$o2" ]] && echo same
		cover.sh: |
			mapfile -t lines < dats/metadata.dats
			rc=0
			for f in dats/fixtures/meta/*; do
				found=0
				for l in "${lines[@]}"; do
					[[ $l == *"cmd: "*" ${f}" ]] && found=1 && break
				done
				if ((!found)); then
					echo "no test names $f"
					rc=1
				fi
			done
			exit "$rc"
		timing.sh: |
			start=${EPOCHREALTIME/./}
			out=$(dats/lib/run.sh {shared.probe.sh} "$1") || exit 1
			ms=$(((${EPOCHREALTIME/./} - start) / 1000))
			if ((ms < 2000)); then echo "fast $(printf '%s\n' "$out" | grep '^width=')"; else echo "slow: $ms ms"; fi

tests:
	- desc: every fixture file has a test
	  cmd: bash {shared.cover.sh}
	  outputs:
		!stdout:
			0: ''
	- desc: the big APP2 JPEG probe finishes within 2 seconds
	  timeout: 10s
	  cmd: bash {shared.timing.sh} dats/fixtures/meta/jpeg-big-app2.jpg
	  outputs:
		stdout:
			0: '^fast width=40$'
	- desc: a FIFO is rejected without a read
	  timeout: 5s
	  cmd: mkfifo {outputs.fifo} && dats/lib/run.sh {shared.neg.sh} {outputs.fifo}
	  outputs:
		stdout:
			0: '^rc=1 keys=0$'
	- desc: a missing file is rejected
	  cmd: dats/lib/run.sh {shared.neg.sh} {outputs.missing.png}
	  outputs:
		stdout:
			0: '^rc=1 keys=0$'
		!stderr:
			0: ''
	- desc: META loses the keys of the previous probe
	  cmd: dats/lib/run.sh {shared.twice.sh}
	  outputs:
		stdout:
			0: '^unset 6$'
	- desc: sourcing the file runs nothing and keeps the shell options
	  cmd: dats/lib/run.sh {shared.options.sh}
	  outputs:
		stdout:
			0: '^same$'
	- desc: gif87a.gif
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/gif87a.gif
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=2$'
			2: '^color=Palette$'
			3: '^detail=GIF87a$'
			4: '^format=GIF$'
			5: '^height=30$'
			6: '^width=40$'
		!stdout:
			7: ''
		!stderr:
			0: ''
	- desc: gif89a.gif
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/gif89a.gif
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=4$'
			2: '^color=Palette$'
			3: '^detail=GIF89a$'
			4: '^format=GIF$'
			5: '^height=30$'
			6: '^width=40$'
		!stdout:
			7: ''
		!stderr:
			0: ''
	- desc: jpeg-baseline.jpg
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/jpeg-baseline.jpg
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=8$'
			2: '^color=YCbCr$'
			3: '^detail=baseline$'
			4: '^format=JPEG$'
			5: '^height=30$'
			6: '^width=40$'
		!stdout:
			7: ''
		!stderr:
			0: ''
	- desc: jpeg-big-app2.jpg
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/jpeg-big-app2.jpg
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=8$'
			2: '^color=YCbCr$'
			3: '^detail=baseline$'
			4: '^format=JPEG$'
			5: '^height=30$'
			6: '^width=40$'
		!stdout:
			7: ''
		!stderr:
			0: ''
	- desc: jpeg-exif-be.jpg
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/jpeg-exif-be.jpg
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=8$'
			2: '^color=YCbCr$'
			3: '^datetime=2024:02:29 23:59:58$'
			4: '^detail=baseline$'
			5: '^exposure=2\.5$'
			6: '^fnumber=8$'
			7: '^focal=50$'
			8: '^format=JPEG$'
			9: '^height=30$'
			10: '^iso=200$'
			11: '^make=BE Make$'
			12: '^orientation=3$'
			13: '^width=40$'
		!stdout:
			14: ''
		!stderr:
			0: ''
	- desc: jpeg-exif-le.jpg
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/jpeg-exif-le.jpg
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=8$'
			2: '^color=YCbCr$'
			3: '^datetime=2025:08:01 10:22:11$'
			4: '^detail=baseline$'
			5: '^exposure=1/120$'
			6: '^fnumber=1\.8$'
			7: '^focal=6\.8$'
			8: '^format=JPEG$'
			9: '^height=30$'
			10: '^iso=64$'
			11: '^lens=Test Lens 24mm$'
			12: '^make=TestMake$'
			13: '^model=TestModel X1$'
			14: '^orientation=6$'
			15: '^width=40$'
		!stdout:
			16: ''
		!stderr:
			0: ''
	- desc: jpeg-gray.jpg
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/jpeg-gray.jpg
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=8$'
			2: '^color=Gray$'
			3: '^detail=baseline$'
			4: '^format=JPEG$'
			5: '^height=30$'
			6: '^width=40$'
		!stdout:
			7: ''
		!stderr:
			0: ''
	- desc: jpeg-progressive.jpg
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/jpeg-progressive.jpg
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=8$'
			2: '^color=YCbCr$'
			3: '^detail=progressive$'
			4: '^format=JPEG$'
			5: '^height=30$'
			6: '^width=40$'
		!stdout:
			7: ''
		!stderr:
			0: ''
	- desc: png-animated.png
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/png-animated.png
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=8$'
			2: '^color=RGB$'
			3: '^detail=animated$'
			4: '^format=PNG$'
			5: '^height=30$'
			6: '^width=40$'
		!stdout:
			7: ''
		!stderr:
			0: ''
	- desc: png-exif.png
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/png-exif.png
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=8$'
			2: '^color=RGB$'
			3: '^format=PNG$'
			4: '^height=30$'
			5: '^iso=100$'
			6: '^model=PNG Cam$'
			7: '^orientation=8$'
			8: '^width=40$'
		!stdout:
			9: ''
		!stderr:
			0: ''
	- desc: png-gray16.png
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/png-gray16.png
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=16$'
			2: '^color=Gray$'
			3: '^format=PNG$'
			4: '^height=30$'
			5: '^width=40$'
		!stdout:
			6: ''
		!stderr:
			0: ''
	- desc: png-interlaced.png
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/png-interlaced.png
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=8$'
			2: '^color=RGB$'
			3: '^detail=interlaced$'
			4: '^format=PNG$'
			5: '^height=30$'
			6: '^width=40$'
		!stdout:
			7: ''
		!stderr:
			0: ''
	- desc: png-palette.png
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/png-palette.png
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=8$'
			2: '^color=Palette$'
			3: '^format=PNG$'
			4: '^height=30$'
			5: '^width=40$'
		!stdout:
			6: ''
		!stderr:
			0: ''
	- desc: png-rgb.png
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/png-rgb.png
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=8$'
			2: '^color=RGB$'
			3: '^format=PNG$'
			4: '^height=30$'
			5: '^width=40$'
		!stdout:
			6: ''
		!stderr:
			0: ''
	- desc: png-rgba.png
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/png-rgba.png
	  outputs:
		stdout:
			0: '^alpha=1$'
			1: '^bits=8$'
			2: '^color=RGBA$'
			3: '^format=PNG$'
			4: '^height=30$'
			5: '^width=40$'
		!stdout:
			6: ''
		!stderr:
			0: ''
	- desc: png-trns.png
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/png-trns.png
	  outputs:
		stdout:
			0: '^alpha=1$'
			1: '^bits=8$'
			2: '^color=Palette$'
			3: '^format=PNG$'
			4: '^height=30$'
			5: '^width=40$'
		!stdout:
			6: ''
		!stderr:
			0: ''
	- desc: tiff-be-rgba.tif
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/tiff-be-rgba.tif
	  outputs:
		stdout:
			0: '^alpha=1$'
			1: '^bits=8$'
			2: '^color=RGBA$'
			3: '^detail=None$'
			4: '^format=TIFF$'
			5: '^height=30$'
			6: '^orientation=1$'
			7: '^width=40$'
		!stdout:
			8: ''
		!stderr:
			0: ''
	- desc: tiff-exif-be.tif
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/tiff-exif-be.tif
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=8$'
			2: '^color=RGB$'
			3: '^datetime=2021:06:15 12:30:45$'
			4: '^detail=None$'
			5: '^format=TIFF$'
			6: '^height=3$'
			7: '^iso=800$'
			8: '^make=TiffMake$'
			9: '^orientation=2$'
			10: '^width=4$'
		!stdout:
			11: ''
		!stderr:
			0: ''
	- desc: tiff-gray-zip.tif
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/tiff-gray-zip.tif
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=8$'
			2: '^color=Gray$'
			3: '^detail=Deflate$'
			4: '^format=TIFF$'
			5: '^height=30$'
			6: '^orientation=1$'
			7: '^width=40$'
		!stdout:
			8: ''
		!stderr:
			0: ''
	- desc: tiff-le.tif
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/tiff-le.tif
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=8$'
			2: '^color=RGB$'
			3: '^detail=LZW$'
			4: '^format=TIFF$'
			5: '^height=30$'
			6: '^orientation=1$'
			7: '^width=40$'
		!stdout:
			8: ''
		!stderr:
			0: ''
	- desc: webp-animated.webp
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/webp-animated.webp
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=8$'
			2: '^color=YCbCr$'
			3: '^detail=lossy,animated$'
			4: '^format=WebP$'
			5: '^height=30$'
			6: '^width=40$'
		!stdout:
			7: ''
		!stderr:
			0: ''
	- desc: webp-lossless-alpha.webp
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/webp-lossless-alpha.webp
	  outputs:
		stdout:
			0: '^alpha=1$'
			1: '^bits=8$'
			2: '^color=RGBA$'
			3: '^detail=lossless$'
			4: '^format=WebP$'
			5: '^height=30$'
			6: '^width=40$'
		!stdout:
			7: ''
		!stderr:
			0: ''
	- desc: webp-lossy.webp
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/webp-lossy.webp
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=8$'
			2: '^color=YCbCr$'
			3: '^detail=lossy$'
			4: '^format=WebP$'
			5: '^height=30$'
			6: '^width=40$'
		!stdout:
			7: ''
		!stderr:
			0: ''
	- desc: webp-vp8x-alpha.webp
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/webp-vp8x-alpha.webp
	  outputs:
		stdout:
			0: '^alpha=1$'
			1: '^bits=8$'
			2: '^color=RGBA$'
			3: '^detail=lossy$'
			4: '^format=WebP$'
			5: '^height=30$'
			6: '^width=40$'
		!stdout:
			7: ''
		!stderr:
			0: ''
	- desc: webp-vp8x-exif.webp
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/webp-vp8x-exif.webp
	  outputs:
		stdout:
			0: '^alpha=1$'
			1: '^bits=8$'
			2: '^color=RGBA$'
			3: '^detail=lossless$'
			4: '^format=WebP$'
			5: '^height=30$'
			6: '^iso=400$'
			7: '^make=WebPMake$'
			8: '^orientation=5$'
			9: '^width=40$'
		!stdout:
			10: ''
		!stderr:
			0: ''
	- desc: bmp-24.bmp
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/bmp-24.bmp
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=8$'
			2: '^color=RGB$'
			3: '^format=BMP$'
			4: '^height=30$'
			5: '^width=40$'
		!stdout:
			6: ''
		!stderr:
			0: ''
	- desc: bmp-32-topdown.bmp
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/bmp-32-topdown.bmp
	  outputs:
		stdout:
			0: '^alpha=1$'
			1: '^bits=8$'
			2: '^color=RGBA$'
			3: '^detail=BI_BITFIELDS$'
			4: '^format=BMP$'
			5: '^height=30$'
			6: '^width=40$'
		!stdout:
			7: ''
		!stderr:
			0: ''
	- desc: bmp-core.bmp
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/bmp-core.bmp
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=4$'
			2: '^color=Palette$'
			3: '^format=BMP$'
			4: '^height=30$'
			5: '^width=40$'
		!stdout:
			6: ''
		!stderr:
			0: ''
	- desc: exr-gray.exr
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/exr-gray.exr
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=32$'
			2: '^color=Gray$'
			3: '^detail=none, float$'
			4: '^format=EXR$'
			5: '^height=30$'
			6: '^width=40$'
		!stdout:
			7: ''
		!stderr:
			0: ''
	- desc: exr-rgb-half.exr
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/exr-rgb-half.exr
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^bits=16$'
			2: '^color=RGB$'
			3: '^detail=ZIP, half$'
			4: '^format=EXR$'
			5: '^height=30$'
			6: '^width=40$'
		!stdout:
			7: ''
		!stderr:
			0: ''
	- desc: exr-rgba.exr
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/exr-rgba.exr
	  outputs:
		stdout:
			0: '^alpha=1$'
			1: '^bits=32$'
			2: '^color=RGBA$'
			3: '^detail=RLE, float$'
			4: '^format=EXR$'
			5: '^height=30$'
			6: '^width=40$'
		!stdout:
			7: ''
		!stderr:
			0: ''
	- desc: hdr-ffmpeg.hdr
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/hdr-ffmpeg.hdr
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^color=RGB$'
			2: '^data_offset=80$'
			3: '^detail=RGBE$'
			4: '^format=HDR$'
			5: '^height=30$'
			6: '^scan_order=-Y \+X$'
			7: '^width=40$'
		!stdout:
			8: ''
		!stderr:
			0: ''
	- desc: hdr-xyze.hdr
	  cmd: dats/lib/run.sh {shared.probe.sh} dats/fixtures/meta/hdr-xyze.hdr
	  outputs:
		stdout:
			0: '^alpha=0$'
			1: '^color=RGB$'
			2: '^data_offset=65$'
			3: '^detail=XYZE, exposure 1\.5$'
			4: '^format=HDR$'
			5: '^height=2$'
			6: '^scan_order=\+Y \+X$'
			7: '^width=3$'
		!stdout:
			8: ''
		!stderr:
			0: ''
	- desc: bad-empty.bin is rejected
	  cmd: dats/lib/run.sh {shared.neg.sh} dats/fixtures/meta/bad-empty.bin
	  outputs:
		stdout:
			0: '^rc=1 keys=0$'
		!stderr:
			0: ''
	- desc: bad-text.txt is rejected
	  cmd: dats/lib/run.sh {shared.neg.sh} dats/fixtures/meta/bad-text.txt
	  outputs:
		stdout:
			0: '^rc=1 keys=0$'
		!stderr:
			0: ''
	- desc: bad-png-trunc.png is rejected
	  cmd: dats/lib/run.sh {shared.neg.sh} dats/fixtures/meta/bad-png-trunc.png
	  outputs:
		stdout:
			0: '^rc=1 keys=0$'
		!stderr:
			0: ''
	- desc: bad-jpeg-trunc.jpg is rejected
	  cmd: dats/lib/run.sh {shared.neg.sh} dats/fixtures/meta/bad-jpeg-trunc.jpg
	  outputs:
		stdout:
			0: '^rc=1 keys=0$'
		!stderr:
			0: ''
	- desc: bad-soi-only.jpg is rejected
	  cmd: dats/lib/run.sh {shared.neg.sh} dats/fixtures/meta/bad-soi-only.jpg
	  outputs:
		stdout:
			0: '^rc=1 keys=0$'
		!stderr:
			0: ''
	- desc: bad-exr-trunc.exr is rejected
	  cmd: dats/lib/run.sh {shared.neg.sh} dats/fixtures/meta/bad-exr-trunc.exr
	  outputs:
		stdout:
			0: '^rc=1 keys=0$'
		!stderr:
			0: ''
	- desc: bad-hdr-nores.hdr is rejected
	  cmd: dats/lib/run.sh {shared.neg.sh} dats/fixtures/meta/bad-hdr-nores.hdr
	  outputs:
		stdout:
			0: '^rc=1 keys=0$'
		!stderr:
			0: ''
	- desc: bad-hdr-zero.hdr is rejected
	  cmd: dats/lib/run.sh {shared.neg.sh} dats/fixtures/meta/bad-hdr-zero.hdr
	  outputs:
		stdout:
			0: '^rc=1 keys=0$'
		!stderr:
			0: ''
