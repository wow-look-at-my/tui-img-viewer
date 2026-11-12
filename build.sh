#!/usr/bin/env bash
# Writes the script "imgv" from imgv.sh and the pieces in src/. bashfs
# includes each piece as plain text, so the result is readable.
set -o errexit -o nounset -o pipefail
cd "$(dirname "$0")"
bashfs package --encoding plain imgv.sh | dd of=imgv status=none
chmod +x imgv
