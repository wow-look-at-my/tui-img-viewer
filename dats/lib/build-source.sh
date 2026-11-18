#!/usr/bin/env bash
# The download and build of a source archive, for the scripts that make test environments.

# build_source URL SHA256 FUNCTION downloads the archive, checks it, and runs
# FUNCTION in its top directory. FUNCTION gets the path of a scratch directory.
# A failed build prints the lines around the error and stops the script.
build_source() {
	local url=$1 sha256=$2 build=$3 src top
	src=$(mktemp -d)
	curl -fsSL -o "$src/archive" "$url"
	echo "$sha256  $src/archive" | sha256sum -c - > /dev/null
	mkdir "$src/tree"
	tar -xf "$src/archive" -C "$src/tree"
	top=$(cd "$src/tree" && echo */)
	if ! (cd "$src/tree/$top" && "$build" "$src") > "$src/build.log" 2>&1; then
		# The parallel build writes much after the error, so the error lines come first.
		grep -i -B 3 -A 8 'error' "$src/build.log" | tail -n 60 >&2 || true
		tail -n 5 "$src/build.log" >&2
		exit 1
	fi
	rm -rf -- "$src"
}
