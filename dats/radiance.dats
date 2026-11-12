# Tests of the bash decoder for Radiance pictures, src/radiance.bash. The
# decoder writes raw planes: green, blue, red, then the exponent.
shared:
	files:
		decode.sh: |
			set -o nounset
			source src/radiance.bash
			out=$(mktemp)
			radiance_planes "$1" "$2" "$3" "$4" "$5" "$out"
			echo "rc=$? rows=$RAD_ROWS format=$RAD_FORMAT bytes=$(stat -c %s "$out")"
			if [[ ${6-} == hex ]]; then
				od -An -v -tx1 -w8 "$out"
			else
				sha256sum < "$out"
			fi

# A file with a couple of lines of several pixels. The red channel of each
# line holds the bytes of a line marker, so a cut at the markers finds too
# many lines. A file with no run-length coding: a couple of lines of a couple of pixels.
setup:
	- printf '#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 8\n\x02\x02\x00\x08\x08\x02\x02\x00\x08\x01\x01\x01\x01\x88\x10\x88\x20\x88\x80\x02\x02\x00\x08\x08\x02\x02\x00\x08\x03\x03\x03\x03\x88\x11\x88\x21\x88\x81' > {shared.marker.hdr}
	- printf '#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 2\n\x01\x02\x03\x80\x04\x05\x06\x81\x07\x08\x09\x82\x0a\x0b\x0c\x83' > {shared.flat.hdr}

tests:
	- desc: every scan line of the fixture decodes to the planes that ffmpeg reads
	  cmd: bash {shared.decode.sh} dats/fixtures/browse/scene.hdr 82 320 240 1
	  outputs:
		stdout:
			0: '^rc=0 rows=240 format=gbrap bytes=307200$'
			1: '^01588fa429316307457bc6860ded88b64034159167d19142a999fd04b8c7653e  -$'

	- desc: a step of three decodes every third scan line
	  cmd: bash {shared.decode.sh} dats/fixtures/browse/scene.hdr 82 320 240 3
	  outputs:
		stdout:
			0: '^rc=0 rows=80 format=gbrap bytes=102400$'
			1: '^f38ed9e5e69cf7cfeb076ce58648b1ca35bc9901363a86e3d615fe79c79ce13d  -$'

	- desc: marker bytes inside the pixel data do not break the decoder
	  cmd: bash {shared.decode.sh} {shared.marker.hdr} 45 8 2 1 hex
	  outputs:
		stdout:
			0: '^rc=0 rows=2 format=gbrap bytes=64$'
			1: '^ 10 10 10 10 10 10 10 10$'
			2: '^ 11 11 11 11 11 11 11 11$'
			3: '^ 20 20 20 20 20 20 20 20$'
			4: '^ 21 21 21 21 21 21 21 21$'
			5: '^ 02 02 00 08 01 01 01 01$'
			6: '^ 02 02 00 08 03 03 03 03$'
			7: '^ 80 80 80 80 80 80 80 80$'
			8: '^ 81 81 81 81 81 81 81 81$'

	- desc: a step skips lines in a file with marker bytes in its data
	  cmd: bash {shared.decode.sh} {shared.marker.hdr} 45 8 2 2 hex
	  outputs:
		stdout:
			0: '^rc=0 rows=1 format=gbrap bytes=32$'
			1: '^ 10 10 10 10 10 10 10 10$'
			2: '^ 20 20 20 20 20 20 20 20$'
			3: '^ 02 02 00 08 01 01 01 01$'
			4: '^ 80 80 80 80 80 80 80 80$'

	- desc: a file with no run-length coding passes through as packed pixels
	  cmd: bash {shared.decode.sh} {shared.flat.hdr} 45 2 2 1 hex
	  outputs:
		stdout:
			0: '^rc=0 rows=2 format=rgba bytes=16$'
			1: '^ 01 02 03 80 04 05 06 81$'
			2: '^ 07 08 09 82 0a 0b 0c 83$'

	- desc: pixel data that ends early is an error
	  cmd: head -c 2000 dats/fixtures/browse/scene.hdr > {outputs.cut.hdr}; bash {shared.decode.sh} {outputs.cut.hdr} 82 320 240 1
	  outputs:
		stdout:
			0: '^rc=1 '
