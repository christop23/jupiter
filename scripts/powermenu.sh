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
        # Locked first, then suspended, by the shared script. The logic lives
        # there rather than here so the MOD+P binding in niri/config.kdl and the
        # waybar module both go through one copy of it.
        if confirm "suspend"; then
            exec "${HOME}/.config/scripts/lock-and-suspend.sh"
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
    *)
        # Unreachable with the menu above as the only source, and the choose()
        # cancellation already exits earlier. Here so that adding an entry to the
        # menu and forgetting the arm is a visible line rather than a menu that
        # silently does nothing when the entry is picked.
        printf 'Unknown action: %s\n' "${action}" >&2
        exit 1
        ;;
esac
