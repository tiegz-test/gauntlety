# macOS folder-watch via BSM auditd

Watch reads and writes against a specific folder, append every event to a log
file, and post a macOS notification when one happens.

macOS uses the BSM (Basic Security Module) audit subsystem rather than Linux's
`auditd`. BSM filters by audit *class*, not by path, so the policy below
enables the file-read (`fr`) and file-write (`fw`) classes globally and the
companion script narrows events down to the folder you care about.

## Files

| Path | Purpose |
| --- | --- |
| `audit/audit_control` | BSM policy enabling `fr,fw` audit classes |
| `bin/watch-audit-folder.sh` | Tails `/dev/auditpipe`, filters, logs, notifies |
| `launchd/com.user.auditfolderwatcher.plist` | Keeps the watcher running at boot |

## Install

```sh
# 1. Drop the audit policy in place and reload auditd
sudo cp audit/audit_control /etc/security/audit_control
sudo chown root:wheel /etc/security/audit_control
sudo chmod 600        /etc/security/audit_control
sudo launchctl kickstart -k system/com.apple.auditd
sudo audit -s

# 2. Install the watcher script
sudo cp bin/watch-audit-folder.sh /usr/local/bin/watch-audit-folder.sh
sudo chown root:wheel /usr/local/bin/watch-audit-folder.sh
sudo chmod 755        /usr/local/bin/watch-audit-folder.sh

# 3. Edit the LaunchDaemon plist:
#      - the folder to watch
#      - the log file path
#      - the username that should receive the notification
$EDITOR launchd/com.user.auditfolderwatcher.plist

# 4. Install and start the LaunchDaemon
sudo cp launchd/com.user.auditfolderwatcher.plist \
        /Library/LaunchDaemons/com.user.auditfolderwatcher.plist
sudo chown root:wheel /Library/LaunchDaemons/com.user.auditfolderwatcher.plist
sudo chmod 644        /Library/LaunchDaemons/com.user.auditfolderwatcher.plist
sudo launchctl bootstrap system \
        /Library/LaunchDaemons/com.user.auditfolderwatcher.plist
```

The first time a notification fires, macOS will ask whether
`osascript` may post notifications — approve it in *System Settings →
Notifications*. The Terminal/launchd context that delivers the notification
also needs **Full Disk Access** so the watcher can read `/dev/auditpipe`.

## Verify

```sh
# Trigger a read
cat /Users/you/Documents/Watched/anything.txt >/dev/null

# Trigger a write
date >> /Users/you/Documents/Watched/test.log

tail -f /var/log/folder-watch.log
```

A notification should appear within a second or two of each event.

## Uninstall

```sh
sudo launchctl bootout system/com.user.auditfolderwatcher
sudo rm /Library/LaunchDaemons/com.user.auditfolderwatcher.plist
sudo rm /usr/local/bin/watch-audit-folder.sh

# Optional: revert audit_control to the macOS default flags
sudo sed -i '' 's/^flags:.*/flags:lo,aa/' /etc/security/audit_control
sudo audit -s
```

## Caveats

- BSM auditd is deprecated by Apple in favor of the Endpoint Security
  framework, but still ships and works as of macOS 14. If you'd rather use
  Endpoint Security, swap `praudit -xl /dev/auditpipe` for
  `eslogger open close create write rename unlink` in the watcher script and
  parse the JSON output instead.
- Enabling `fr,fw` system-wide produces a lot of audit traffic. The
  `filesz:2M` and `expire-after:10M` settings in `audit_control` keep
  `/var/audit` from growing without bound.
- Full Disk Access is required for the LaunchDaemon binary
  (`/bin/bash` or, more precisely, the script) to read `/dev/auditpipe`.
