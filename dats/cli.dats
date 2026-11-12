# Tests of the command line, and of the single script as a build product.
tests:
	- desc: --version prints the version
	  cmd: ./imgv --version
	  outputs:
		stdout:
			0: '^imgv 0\.1\.0$'

	- desc: --help prints the usage
	  cmd: ./imgv --help
	  outputs:
		stdout:
			- "Usage: imgv [options] [directory | file]"
			- "--no-images"
			- "--quality LEVEL"

	- desc: an unknown option is an error
	  cmd: ./imgv --bogus
	  exit: 1
	  outputs:
		stderr:
			- "imgv: unknown option: --bogus"

	- desc: an unknown quality level is an error
	  cmd: ./imgv --quality nope
	  exit: 1
	  outputs:
		stderr:
			- "imgv: unknown quality: nope"

	- desc: a rate of zero is an error
	  cmd: ./imgv --rate 0
	  exit: 1
	  outputs:
		stderr:
			- "--rate needs a positive number"

	- desc: a path that does not exist is an error
	  cmd: ./imgv dats/fixtures/browse/missing
	  exit: 1
	  outputs:
		stderr:
			- "imgv: no such file or directory: dats/fixtures/browse/missing"

	- desc: without a terminal the program stops and says why
	  cmd: ./imgv dats/fixtures/browse < /dev/null
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
			0: '^12$'
			1: '^0$'
			2: '^0$'

	- desc: shellcheck finds nothing in the single script with every rule on
	  cmd: shellcheck --norc -s bash imgv

	- desc: shellcheck finds nothing in the build and test scripts
	  cmd: shellcheck -s bash build.sh dats/lib/drive.sh dats/lib/fake-term.sh dats/fixtures/make-browse-fixtures.sh
