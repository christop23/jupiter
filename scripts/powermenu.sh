#!/usr/bin/env bash

set -Eeuo pipefail

if ! command -v vicinae >/dev/null 2>&1; then
    printf 'Vicinae is required for the power menu.\n' >&2
    exit 1
fi

choose() {
    local placeholder="$1"
    shift

    local selection
    if ! selection="$(printf '%s\n' "$@" | vicinae dmenu --placeholder "${placeholder}")"; then
        return 1
    fi

    printf '%s\n' "${selection}"
}

confirm() {
    local action="$1"
    local answer

    if ! answer="$(choose "Confirm ${action}?" "Cancel" "Confirm")"; then
        return 1
    fi

    [[ "${answer}" == "Confirm" ]]
}

if ! action="$(choose "Power menu" "Lock screen" "Suspend" "Log out" "Restart" "Shut down")"; then
    # Closing dmenu is a normal way to cancel the menu.
    exit 0
fi

case "${action}" in
    "Lock screen")
        exec gtklock
        ;;
    "Suspend")
        if confirm "suspend"; then
            systemctl suspend
        fi
        ;;
    "Log out")
        if confirm "log out"; then
            niri msg action quit --skip-confirmation
        fi
        ;;
    "Restart")
        if confirm "restart"; then
            systemctl reboot
        fi
        ;;
    "Shut down")
        if confirm "shut down"; then
            systemctl poweroff
        fi
        ;;
esac
