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

if ! action="$(choose "Power menu" "Lock screen" "Suspend" "Log out" "Restart" "Shut down")"; then
    # Closing dmenu is a normal way to cancel the menu.
    exit 0
fi

# No second prompt. Picking an entry is already the decision: the entries name
# what they do, and a dialog in front of one the user just chose by name is a
# step to dismiss rather than a decision to make. Lock screen never had one, so
# the two kinds of entry disagreed about whether to ask, for no reason a user
# could see. Suspending still locks first, which is an ordering concern and not
# a question.
case "${action}" in
    "Lock screen")
        exec gtklock
        ;;
    "Suspend")
        # Locked first, then suspended, by the shared script. The logic lives
        # there rather than here so the MOD+P binding in niri/config.kdl and the
        # waybar module both go through one copy of it.
        exec "${HOME}/.config/scripts/lock-and-suspend.sh"
        ;;
    "Log out")
        niri msg action quit --skip-confirmation
        ;;
    "Restart")
        systemctl reboot
        ;;
    "Shut down")
        systemctl poweroff
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
