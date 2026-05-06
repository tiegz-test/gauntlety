#!/bin/bash
#
# watch-folder-eslogger.sh - subscribe to Endpoint Security events via
# /usr/bin/eslogger, filter to a target folder, append to a log file, and
# post a macOS notification per event.
#
# Usage:
#   sudo ./watch-folder-eslogger.sh <folder> [log-file] [notify-user]
#
# Tunables (via environment):
#   ES_EVENTS  Space-separated ES event types to subscribe to.
#              Default: "open close create rename unlink"
#              For lower overhead (writes only, no read events):
#                ES_EVENTS="close create rename unlink"
#
# Requires:
#   - macOS 13+ (eslogger ships with the OS)
#   - Run as root; the executing binary needs Full Disk Access
#   - jq on PATH (preinstall or `brew install jq`)

set -euo pipefail

WATCH_DIR="${1:?folder to watch is required}"
LOG_FILE="${2:-/var/log/folder-watch.log}"
NOTIFY_USER="${3:-${SUDO_USER:-${USER}}}"
ES_EVENTS="${ES_EVENTS:-open close create rename unlink}"

if [[ ! -d "$WATCH_DIR" ]]; then
    echo "watch-folder-eslogger: '$WATCH_DIR' is not a directory" >&2
    exit 1
fi
WATCH_DIR="$(cd "$WATCH_DIR" && pwd -P)"

NOTIFY_UID="$(id -u "$NOTIFY_USER" 2>/dev/null || true)"
if [[ -z "$NOTIFY_UID" ]]; then
    echo "watch-folder-eslogger: unknown user '$NOTIFY_USER'" >&2
    exit 1
fi

JQ="$(command -v jq || true)"
if [[ -z "$JQ" ]]; then
    echo "watch-folder-eslogger: jq not found on PATH" >&2
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

log "eslogger watcher started; folder=$WATCH_DIR events='$ES_EVENTS' user=$NOTIFY_USER"

# Trailing slash so prefix match doesn't catch /Users/foo/Watched-evil when
# watching /Users/foo/Watched.
DIR_PREFIX="${WATCH_DIR%/}/"

# eslogger emits one JSON object per line. We use jq to:
#   1. Pick the event type (the single key under .event)
#   2. Extract the primary path for that event type
#   3. For "open" events, decode O_RDONLY/O_WRONLY/O_RDWR from fflag so the
#      message reads "open(r)" / "open(w)" / "open(rw)"
#   4. Drop anything outside the watched folder
exec /usr/bin/eslogger $ES_EVENTS 2>/dev/null \
| "$JQ" --unbuffered -rc --arg dir "$DIR_PREFIX" '
    (.event | keys[0]) as $type
    | (
        .event.open.file.path //
        .event.close.target.path //
        .event.create.destination.existing_file.path //
        ((.event.create.destination.new_path.dir.path // "")
            + "/" + (.event.create.destination.new_path.filename // "")) //
        .event.rename.source.path //
        .event.unlink.target.path //
        empty
      ) as $p
    | select($p | startswith($dir))
    | (if $type == "open" then
          ((.event.open.fflag // 0) % 4) as $rw
          | (if   $rw == 0 then "open(r)"
             elif $rw == 1 then "open(w)"
             else               "open(rw)" end)
        else $type end) as $kind
    | "\($kind)\t\($p)\t\(.process.executable.path // "?")"
' \
| while IFS=$'\t' read -r kind path exe; do
    log "$kind path=$path by=$exe"
    notify "Folder Watch" "$kind $path"
done
