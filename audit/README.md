# macOS folder-watch with notifications

Watch reads and writes against a specific folder, append every event to a log
file, and post a macOS notification when one happens.

Two implementations are provided. **Endpoint Security (`eslogger`) is the
recommended path on macOS 13+.** BSM auditd is kept around for older systems
or environments where you can't grant Full Disk Access to a custom binary.

| Implementation | Source of events | Persistent log on disk? | Notes |
| --- | --- | --- | --- |
| `eslogger` (recommended) | Endpoint Security framework | No (only your log file) | Modern, supported, easy to scope |
| BSM auditd (legacy) | `/dev/auditpipe` | Yes (`/var/audit`) | Apple-deprecated; system-wide policy change |

## Files

| Path | Purpose |
| --- | --- |
| `bin/watch-folder-eslogger.sh` | Endpoint Security watcher |
| `launchd/com.user.eslogger-folderwatcher.plist` | LaunchDaemon for the ES watcher |
| `bin/watch-audit-folder.sh` | BSM auditd watcher (legacy) |
| `launchd/com.user.auditfolderwatcher.plist` | LaunchDaemon for the BSM watcher (legacy) |
| `audit/audit_control` | BSM policy enabling `fr,fw` audit classes (legacy) |

---

## Recommended: Endpoint Security (`eslogger`)

`eslogger` ships with macOS 13+ and lets you subscribe to specific Endpoint
Security event types. The watcher subscribes to the events below, parses the
JSON output with `jq`, filters to your folder, logs, and notifies.

| Event | What it tells you |
| --- | --- |
| `open` | A file was opened. The script decodes `fflag` into `open(r)`, `open(w)`, or `open(rw)`. |
| `close` | A file handle was closed (use this with the `modified` flag for "write completed"). |
| `create` | A new file was created. |
| `rename` | A file was renamed (source path inside the watched dir). |
| `unlink` | A file was deleted. |

### Install

```sh
# 1. Install jq if you don't have it (the script needs it)
brew install jq

# 2. Install the watcher script
sudo cp bin/watch-folder-eslogger.sh /usr/local/bin/watch-folder-eslogger.sh
sudo chown root:wheel /usr/local/bin/watch-folder-eslogger.sh
sudo chmod 755        /usr/local/bin/watch-folder-eslogger.sh

# 3. Edit the LaunchDaemon plist (folder, log file, username, ES_EVENTS)
$EDITOR launchd/com.user.eslogger-folderwatcher.plist

# 4. Install and start the LaunchDaemon
sudo cp launchd/com.user.eslogger-folderwatcher.plist \
        /Library/LaunchDaemons/com.user.eslogger-folderwatcher.plist
sudo chown root:wheel /Library/LaunchDaemons/com.user.eslogger-folderwatcher.plist
sudo chmod 644        /Library/LaunchDaemons/com.user.eslogger-folderwatcher.plist
sudo launchctl bootstrap system \
        /Library/LaunchDaemons/com.user.eslogger-folderwatcher.plist
```

### Required permissions

- **Full Disk Access** for `/usr/bin/eslogger`. Open *System Settings →
  Privacy & Security → Full Disk Access*, click `+`, press `Cmd+Shift+G`,
  type `/usr/bin/eslogger`, add it, and toggle it on. Without this the
  daemon will start but receive no events.
- The first notification will trigger a Notification permission prompt for
  `Script Editor` / `osascript`; approve it.

### Verify

```sh
cat ~/Documents/Watched/anything.txt >/dev/null   # read
date >> ~/Documents/Watched/test.log              # write
tail -f /var/log/folder-watch.log
```

### Tuning overhead

The biggest cost knob is the `ES_EVENTS` env var in the plist:

| `ES_EVENTS` value | Approx. cost | Coverage |
| --- | --- | --- |
| `close create rename unlink` | low | All writes/structural changes; no read events |
| `open close create rename unlink` *(default)* | medium | Reads + writes |
| `open close create rename unlink write` | high | Adds raw `write` syscalls — only useful for forensics |

Even after subscribing only to specific event types, eslogger still receives
every matching event system-wide; the path filter happens in the script.
On a typical desktop with the default events you should expect a small
fraction of one CPU core — much less than the BSM `fr,fw` policy.

### Uninstall

```sh
sudo launchctl bootout system/com.user.eslogger-folderwatcher
sudo rm /Library/LaunchDaemons/com.user.eslogger-folderwatcher.plist
sudo rm /usr/local/bin/watch-folder-eslogger.sh
```

---

## Legacy: BSM auditd

Use this only if you're on a macOS version that lacks `eslogger`, or you
specifically want a kernel-level audit trail in `/var/audit`.

macOS uses BSM (Basic Security Module) audit, configured in
`/etc/security/audit_control`. BSM filters by audit *class*, not by path,
so `audit/audit_control` enables file-read (`fr`) and file-write (`fw`)
globally and the watcher narrows events to your folder.

### Install

```sh
sudo cp audit/audit_control /etc/security/audit_control
sudo chown root:wheel /etc/security/audit_control
sudo chmod 600        /etc/security/audit_control
sudo launchctl kickstart -k system/com.apple.auditd
sudo audit -s

sudo cp bin/watch-audit-folder.sh /usr/local/bin/watch-audit-folder.sh
sudo chown root:wheel /usr/local/bin/watch-audit-folder.sh
sudo chmod 755        /usr/local/bin/watch-audit-folder.sh

$EDITOR launchd/com.user.auditfolderwatcher.plist
sudo cp launchd/com.user.auditfolderwatcher.plist \
        /Library/LaunchDaemons/com.user.auditfolderwatcher.plist
sudo chown root:wheel /Library/LaunchDaemons/com.user.auditfolderwatcher.plist
sudo chmod 644        /Library/LaunchDaemons/com.user.auditfolderwatcher.plist
sudo launchctl bootstrap system \
        /Library/LaunchDaemons/com.user.auditfolderwatcher.plist
```

### Caveats

- `fr,fw` is the chattiest pair of BSM audit classes. `/var/audit` will see
  steady traffic; the `filesz:2M` and `expire-after:10M` settings keep it
  bounded.
- BSM auditd is deprecated by Apple in favor of Endpoint Security.
- The daemon needs Full Disk Access to read `/dev/auditpipe`.

### Uninstall

```sh
sudo launchctl bootout system/com.user.auditfolderwatcher
sudo rm /Library/LaunchDaemons/com.user.auditfolderwatcher.plist
sudo rm /usr/local/bin/watch-audit-folder.sh
sudo sed -i '' 's/^flags:.*/flags:lo,aa/' /etc/security/audit_control
sudo audit -s
```
