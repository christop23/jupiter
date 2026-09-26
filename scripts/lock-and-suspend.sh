#!/usr/bin/env bash
# Lock the screen, wait for it, then suspend.
#
# Suspending first and locking after resumes to an unlocked session, and
# systemctl suspend returns as soon as the machine is on its way down rather than
# once it is asleep, so a backgrounded lock screen loses the race and the sleep
# happens with nothing in front of it.
#
# The wait is the point. gtklock exits when it is dismissed, which is the signal
# that the lock screen is up and the machine is safe to put to sleep.
#
# The power menu, reached from MOD+P and from the waybar module.
#
# A missing gtklock warns and suspends anyway: not locking is a risk, refusing to
# suspend is a bug.

if ! command -v gtklock > /dev/null 2>&1; then
    printf 'gtklock not found, suspending without locking.\n' >&2
    exec systemctl suspend
fi

gtklock &
lock_pid=$!

# Waited on with the status discarded: gtklock exits non-zero when dismissed with
# Escape, and that is not an error here.
wait "${lock_pid}" 2> /dev/null || true

exec systemctl suspend
