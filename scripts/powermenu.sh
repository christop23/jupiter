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
        # Locked first, and waited for. Suspending without locking means the
        # machine resumes to an unlocked session, and this setup has no idle
        # lock -- niri/config.kdl only binds gtklock to a key -- so nothing else
        # would catch it.
        #
        # systemctl suspend returns once the machine is on its way down rather
        # than once it is asleep, and the lock screen has to be up before then,
        # so a bare `gtklock &` would race it. If gtklock is missing the suspend
        # still happens: not locking is a risk, refusing to suspend is a bug.
        if confirm "suspend"; then
            if command -v gtklock > /dev/null 2>&1; then
                gtklock &
                lock_pid=$!
                wait "${lock_pid}" 2> /dev/null || true
            else
                printf 'gtklock not found, suspending without locking.\n' >&2
            fi
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
    *)
        # Unreachable with the menu above as the only source, and the choose()
        # cancellation already exits earlier. Here so that adding an entry to the
        # menu and forgetting the arm is a visible line rather than a menu that
        # silently does nothing when the entry is picked.
        printf 'Unknown action: %s\n' "${action}" >&2
        exit 1
        ;;
esac
