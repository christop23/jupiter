#!/usr/bin/env bash

set -Eeuo pipefail

WALL_DIR="${WALL_DIR:-${HOME}/Pictures/Wallpapers}"
THEME_SYNC_SCRIPT="${THEME_SYNC_SCRIPT:-${HOME}/.config/scripts/theme-sync.sh}"

if [[ ! -d "${WALL_DIR}" ]]; then
    printf 'Wallpaper directory not found: %s\n' "${WALL_DIR}" >&2
    exit 1
fi

if ! command -v vicinae >/dev/null 2>&1; then
    printf 'Vicinae is required to select a wallpaper.\n' >&2
    exit 1
fi

# Vicinae's dmenu mode provides native quick look for absolute file paths.
wallpapers=()
while IFS= read -r -d '' wallpaper; do
    wallpapers+=("${wallpaper}")
done < <(
    find "${WALL_DIR}" -type f \( \
        -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o \
        -iname '*.webp' -o -iname '*.gif' -o -iname '*.bmp' -o \
        -iname '*.tiff' -o -iname '*.avif' \
    \) -print0
)

if (( ${#wallpapers[@]} == 0 )); then
    printf 'No wallpapers found in %s\n' "${WALL_DIR}" >&2
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

awww img "${selected}" -t fade --transition-duration 2 --transition-fps 30 &
awww_pid=$!
sleep 0.2
"${THEME_SYNC_SCRIPT}" &
theme_sync_pid=$!
wait "${awww_pid}"
wait "${theme_sync_pid}"
