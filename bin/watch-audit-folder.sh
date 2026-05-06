#!/bin/bash
#
# watch-audit-folder.sh - tail /dev/auditpipe, filter for a target folder,
# append to a log file, and post a macOS notification per event.
#
# Usage:
#   sudo ./watch-audit-folder.sh <folder> [log-file] [notify-user]
#
# Example:
#   sudo ./watch-audit-folder.sh "$HOME/Documents/Watched" \
#        /var/log/folder-watch.log "$USER"
#
# Notes:
# - /dev/auditpipe is root-only, so this must run as root (the LaunchDaemon
#   plist takes care of that).
# - Notifications are dispatched into the target user's GUI session via
#   `launchctl asuser`, otherwise osascript can't reach the user's
#   NotificationCenter when invoked from a system daemon.

set -euo pipefail

WATCH_DIR="${1:?folder to watch is required}"
LOG_FILE="${2:-/var/log/folder-watch.log}"
NOTIFY_USER="${3:-${SUDO_USER:-${USER}}}"

if [[ ! -d "$WATCH_DIR" ]]; then
    echo "watch-audit-folder: '$WATCH_DIR' is not a directory" >&2
    exit 1
fi

WATCH_DIR="$(cd "$WATCH_DIR" && pwd -P)"

NOTIFY_UID="$(id -u "$NOTIFY_USER" 2>/dev/null || true)"
if [[ -z "$NOTIFY_UID" ]]; then
    echo "watch-audit-folder: unknown user '$NOTIFY_USER'" >&2
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

notify() {
    local title="$1" message="$2"
    title="${title//\"/\\\"}"
    message="${message//\"/\\\"}"
    launchctl asuser "$NOTIFY_UID" sudo -u "$NOTIFY_USER" \
        /usr/bin/osascript -e \
        "display notification \"${message}\" with title \"${title}\"" \
        >/dev/null 2>&1 || true
}

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$LOG_FILE"
}

log "watcher started; folder=$WATCH_DIR user=$NOTIFY_USER"

# praudit -x emits one <record>...</record> XML blob per audit event.
# We accumulate lines until we see </record>, then inspect the record for a
# <path> element under our target directory.
exec /usr/sbin/praudit -xl /dev/auditpipe 2>/dev/null \
| /usr/bin/awk -v watch="$WATCH_DIR" -v logfile="$LOG_FILE" '
    function shellesc(s) { gsub(/'\''/, "'\''\\'\'\''", s); return "'\''" s "'\''" }
    /<record/ { rec = $0; next }
    rec != ""  { rec = rec "\n" $0 }
    /<\/record>/ {
        # Extract event name from <record ... event="...">
        event = ""
        if (match(rec, /event="[^"]*"/)) {
            event = substr(rec, RSTART+7, RLENGTH-8)
        }
        # First <path>...</path> is the primary target on macOS BSM events
        path = ""
        if (match(rec, /<path>[^<]*<\/path>/)) {
            path = substr(rec, RSTART+6, RLENGTH-13)
        }
        if (path != "" && index(path, watch) == 1) {
            # Build a one-line summary and hand it to a helper via printf
            line = sprintf("event=%s path=%s", event, path)
            printf("%s\n", line)
            fflush()
        }
        rec = ""
    }
' \
| while IFS= read -r summary; do
    log "$summary"
    notify "Folder Watch" "$summary"
done
