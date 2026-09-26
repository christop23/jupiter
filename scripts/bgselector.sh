#!/usr/bin/env bash

set -Eeuo pipefail

WALL_DIR="${WALL_DIR:-${HOME}/Pictures/Wallpapers}"

# Derived from this script's own location rather than hardcoded. This runs from
# ~/.config/scripts/bgselector.sh, so theme-sync.sh is a sibling; two absolute
# paths that have to agree is a failure mode with no upside, and it broke
# silently (exit 127) if either symlink chain was moved.
THEME_SYNC_SCRIPT="${THEME_SYNC_SCRIPT:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/theme-sync.sh}"

if [[ ! -d "${WALL_DIR}" ]]; then
    printf 'Wallpaper directory not found: %s\n' "${WALL_DIR}" >&2
    exit 1
fi

if ! command -v vicinae >/dev/null 2>&1; then
    printf 'Vicinae is required to select a wallpaper.\n' >&2
    exit 1
fi

if [[ ! -f "${THEME_SYNC_SCRIPT}" ]]; then
    printf 'Theme sync script not found: %s\n' "${THEME_SYNC_SCRIPT}" >&2
    exit 1
fi

# Vicinae's dmenu mode provides native quick look for absolute file paths.
#
# Only the scheme/<dark|light> layout is listed. theme-sync.sh derives the theme
# name from the grandparent directory and the variation from the parent, and
# refuses anything else, so offering a file it will reject just produces an
# error after the wallpaper has already been set. Presenting the path in the
# menu also means the scheme a wallpaper belongs to is visible before choosing
# it, which it was not when the list was a flat set of absolute paths.
wallpapers=()
while IFS= read -r -d '' wallpaper; do
    wallpapers+=("${wallpaper}")
done < <(
    find "${WALL_DIR}" -mindepth 3 -maxdepth 3 -type f \( \
        -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o \
        -iname '*.webp' -o -iname '*.gif' -o -iname '*.bmp' -o \
        -iname '*.tiff' -o -iname '*.avif' \
    \) -print0
)

if (( ${#wallpapers[@]} == 0 )); then
    printf 'No wallpapers found in %s/<scheme>/<dark|light>/\n' "${WALL_DIR}" >&2
    exit 1
fi

if ! selected="$(
    printf '%s\n' "${wallpapers[@]}" |
        vicinae dmenu --placeholder 'Select a wallpaper...'
)"; then
    # Closing dmenu is a normal way to cancel the selector.
    exit 0
fi

if [[ -z "${selected}" || ! -f "${selected}" ]]; then
    exit 0
fi

# The chosen path is passed to theme-sync.sh rather than left for it to re-derive
# from `awww query`. It used to be discarded and re-read a second later, during a
# two second fade, so picking again quickly could have it report the previous
# image and theme the wrong wallpaper.
awww img "${selected}" -t fade --transition-duration 2 --transition-fps 30 &
awww_pid=$!

# Waited on with the status captured rather than bare, so a non-zero awww exit
# does not abort before theme-sync is waited for and leave it orphaned.
if ! wait "${awww_pid}"; then
    printf 'awww failed to set the wallpaper.\n' >&2
fi

"${THEME_SYNC_SCRIPT}" "${selected}" || printf 'Theme sync reported a problem.\n' >&2
