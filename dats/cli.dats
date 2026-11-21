# Tests of the command line, and of the single script as a build product.
# dats/lib/run.sh runs imgv with the shell and the tools under test.
tests:
	- desc: the script starts from its own first line
	  cmd: ./imgv --version
	  outputs:
		stdout:
			0: '^imgv 0\.1\.0$'

	- desc: --version prints the version, and the start prints no error
	  cmd: dats/lib/run.sh ./imgv --version
	  outputs:
		stdout:
			0: '^imgv 0\.1\.0$'
		!stderr:
			0: ''

	- desc: --help prints the usage
	  cmd: dats/lib/run.sh ./imgv --help
	  outputs:
		stdout:
			- "Usage: imgv [options] [directory | file]"
			- "--no-images"
			- "--quality LEVEL"
			- "--log FILE"

	- desc: an unknown option is an error
	  cmd: dats/lib/run.sh ./imgv --bogus
	  exit: 1
	  outputs:
		stderr:
			- "imgv: unknown option: --bogus"

	- desc: an unknown quality level is an error
	  cmd: dats/lib/run.sh ./imgv --quality nope
	  exit: 1
	  outputs:
		stderr:
			- "imgv: unknown quality: nope"

	- desc: an unknown filter is an error
	  cmd: dats/lib/run.sh ./imgv --filter blurry
	  exit: 1
	  outputs:
		stderr:
			- "imgv: unknown filter: blurry (use smooth or nearest)"

	- desc: a rate of zero is an error
	  cmd: dats/lib/run.sh ./imgv --rate 0
	  exit: 1
	  outputs:
		stderr:
			- "--rate needs a positive number"

	- desc: a log file that cannot be written is an error
	  cmd: dats/lib/run.sh ./imgv --log dats/fixtures/browse/missing/imgv.log
	  exit: 1
	  outputs:
		stderr:
			- "imgv: cannot write the log file: dats/fixtures/browse/missing/imgv.log"

	- desc: a path that does not exist is an error
	  cmd: dats/lib/run.sh ./imgv dats/fixtures/browse/missing
	  exit: 1
	  outputs:
		stderr:
			- "imgv: no such file or directory: dats/fixtures/browse/missing"

	- desc: without a terminal the program stops and says why
	  cmd: dats/lib/run.sh ./imgv dats/fixtures/browse < /dev/null
	  exit: 1
	  outputs:
		stderr:
			- "imgv: needs a terminal on standard input and output"

	- desc: the single script is what bashfs builds from imgv.sh and src
	  cmd: bashfs package --encoding plain imgv.sh 2>/dev/null | cmp - imgv

	- desc: the single script is plain text with every piece marked and no bashfs code
	  cmd: grep -c '^# bashfs. begin ' imgv; grep -c 'bashfs_' imgv; grep -c 'base64 -d' imgv; true
	  outputs:
		stdout:
			0: '^14$'
			1: '^0$'
			2: '^0$'

	- desc: shellcheck finds nothing in the single script with every rule on
	  cmd: shellcheck --norc -s bash imgv

	- desc: shellcheck finds nothing in the build and test scripts
	  cmd: shellcheck -s bash build.sh dats/lib/drive.sh dats/lib/fake-term.sh dats/lib/run.sh dats/lib/busybox-env.sh dats/lib/build-source.sh dats/lib/ffmpeg-min.sh dats/fixtures/make-browse-fixtures.sh
