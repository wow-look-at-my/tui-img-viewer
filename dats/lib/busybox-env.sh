#!/usr/bin/env bash
# Builds the second test environment in the directory $1: the oldest bash that imgv supports, and the tools of busybox.
set -o errexit -o nounset -o pipefail

version=3.2.57
sha256=3fa9daf85ebf35068f090ce51283ddeeb3c75eb5bc70b1a4a7cb05868bfe06a4

mkdir -p "$1"
dir=$(cd "$1" && pwd)

rm -rf -- "${dir:?}/bin"
mkdir "$dir/bin"
busybox --install -s "$dir/bin"
# busybox has no tmux and no ffmpeg, so imgv runs those of the host.
for tool in tmux ffmpeg ffprobe; do
	ln -s "$(command -v "$tool")" "$dir/bin/$tool"
done

if [[ ! -x $dir/bash ]]; then
	src=$(mktemp -d)
	curl -fsSL -o "$src/bash.tar.gz" "https://ftp.gnu.org/gnu/bash/bash-$version.tar.gz"
	echo "$sha256  $src/bash.tar.gz" | sha256sum -c - > /dev/null
	tar -xzf "$src/bash.tar.gz" -C "$src"
	if ! (
		cd "$src/bash-$version"
		# The source is older than the C standard of a current compiler.
		# The archive holds the generated parser. It must look newer than
		# its source, or make asks for yacc.
		touch y.tab.c y.tab.h
		ac_cv_func_working_mktime=yes ./configure --without-bash-malloc --disable-nls CFLAGS='-O1 -std=gnu89 -w'
		make -j "$(nproc)"
	) > "$src/build.log" 2>&1; then
		tail -n 40 "$src/build.log" >&2
		exit 1
	fi
	cp "$src/bash-$version/bash" "$dir/bash"
	rm -rf -- "$src"
fi
"$dir/bash" --version | head -n 1
busybox | head -n 1
