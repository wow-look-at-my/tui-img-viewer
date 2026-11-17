#!/usr/bin/env bash
# Runs a script with the shell and the tools under test. IMGV_SH names the bash, and IMGV_PATH the tool directories.
exec env PATH="${IMGV_PATH:-$PATH}" "${IMGV_SH:-bash}" "$@"
