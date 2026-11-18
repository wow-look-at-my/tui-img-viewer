#!/usr/bin/env bash
# imgv - a terminal file browser. Its main job is image previews on a slow
# link. An older bash stops at each empty array under nounset.
if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
	set -o nounset
fi
shopt -s extglob

eval "$(bashfs gen ./src)"
source <(bashfs_cat config.bash)
source <(bashfs_cat util.bash)
source <(bashfs_cat terminal.bash)
source <(bashfs_cat layout.bash)
source <(bashfs_cat directory.bash)
source <(bashfs_cat metadata.bash)
source <(bashfs_cat radiance.bash)
source <(bashfs_cat mov.bash)
source <(bashfs_cat jobs.bash)
source <(bashfs_cat graphics.bash)
source <(bashfs_cat preview.bash)
source <(bashfs_cat draw.bash)
source <(bashfs_cat input.bash)
source <(bashfs_cat main.bash)

main "$@"
