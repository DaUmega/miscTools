#!/bin/sh
# hostwatch.sh: minimalist host persistence monitor.
# Watches what hackers touch on compromise (users, sudo, SSH, cron,
# systemd, shell startups, autostart, SUID) and posts one alert per
# run to an RSS notifier feed when anything changes.
#
# Usage: hostwatch.sh [--init]
#   (no args)  check, alert, update baseline
#   --init     (re)create the baseline, no alerts (first run, or
#              after approved changes)
# Run as root. Cron hourly:
#   0 * * * * /usr/local/bin/hostwatch.sh
# one liner, every minute with token and logs:
#   printf '%s\n' '* * * * * NOTIFY_URL=https://daumega.duckdns.org/notifier/alert NOTIFY_TOKEN=<token> NOTIFY_TOPIC=tony /home/daumega/Downloads/miscTools/hostwatch.sh >> /var/log/hostwatch.log 2>&1' | sudo crontab -
#
# Config (edit once, or pass as env):
#   NOTIFY_URL    full alert URL, e.g. https://domain/notifier/alert
#   NOTIFY_TOKEN  token for NOTIFY_TOPIC (mint with add-token)
#   NOTIFY_TOPIC  feed topic (no default: set it here or pass as env)
#   STATE_DIR     baseline dir (default /var/lib/hostwatch)
# Leave NOTIFY_URL empty to print alerts to stdout only.

set -u

NOTIFY_URL=${NOTIFY_URL:-}
NOTIFY_TOKEN=${NOTIFY_TOKEN:-}
NOTIFY_TOPIC=${NOTIFY_TOPIC:-}
STATE_DIR=${STATE_DIR:-/var/lib/hostwatch}
BASE=$STATE_DIR/baseline.txt

[ "$(id -u)" -eq 0 ] || { echo "hostwatch: run as root" >&2; exit 1; }

# Files and dirs to watch. Missing paths are skipped, so this covers
# Debian, RHEL, Arch, Alpine, and friends with no distro detection.
WATCH='
/etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/sudoers /etc/hosts
/etc/ld.so.preload /etc/crontab /etc/cron.allow /etc/cron.deny
/etc/at.allow /etc/at.deny /etc/rc.local /etc/profile
/etc/bash.bashrc /etc/bashrc /etc/zsh/zshrc
/etc/ssh /etc/sudoers.d /etc/cron.d /etc/cron.daily /etc/cron.hourly
/etc/cron.weekly /etc/cron.monthly /etc/systemd/system /etc/profile.d
/etc/pam.d /etc/modules-load.d /etc/modprobe.d /etc/xdg/autostart
/etc/init.d /etc/rc.d /var/spool/cron /var/spool/at
/usr/local/bin /usr/local/sbin'

# SUID/SGID binary dirs (metadata only, no content hash).
SUID_DIRS='/bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin /opt'

# One manifest line per file: "hash perms owner path" (path last, so
# spaces in names survive). SUID lines use "suid" as the hash.
hashfile() {
  h=$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1) || return 1
  m=$(stat -c '%a %U' "$1" 2>/dev/null) || return 1
  printf '%s %s %s\n' "$h" "$m" "$1"
}

hashdir() {
  [ -d "$1" ] || return 0
  find "$1" -type f 2>/dev/null | LC_ALL=C sort | while read -r f; do
    hashfile "$f" || continue
  done
}

manifest() {
  for p in $WATCH; do
    [ -e "$p" ] || continue
    if [ -f "$p" ]; then hashfile "$p" || continue
    elif [ -d "$p" ]; then hashdir "$p"; fi
  done
  { cut -d: -f6 /etc/passwd 2>/dev/null
    for d in /home/*; do [ -d "$d" ] && printf '%s\n' "$d"; done
  } | LC_ALL=C sort -u | while read -r home; do
    [ -n "$home" ] && [ -d "$home" ] || continue
    for f in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2" \
             "$home/.ssh/config" "$home/.bashrc" "$home/.bash_profile" \
             "$home/.profile" "$home/.zshrc" "$home/.zprofile" \
             "$home/.bash_login"; do
      [ -f "$f" ] && hashfile "$f"
    done
    hashdir "$home/.config/autostart"
    hashdir "$home/.config/systemd/user"
  done
  for d in $SUID_DIRS; do
    [ -d "$d" ] || continue
    find "$d" -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null |
    while read -r f; do
      m=$(stat -c '%a %U' "$f" 2>/dev/null) || continue
      printf 'suid %s %s\n' "$m" "$f"
    done
  done
}

jsonesc() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    -e ':a;N;$!ba;s/\n/\\n/g'
}

case "${1:-}" in
  --init) INIT=1 ;;
  --help|-h) echo "usage: hostwatch.sh [--init]"; exit 0 ;;
  "") INIT=0 ;;
  *) echo "usage: hostwatch.sh [--init]" >&2; exit 1 ;;
esac

mkdir -p "$STATE_DIR" || { echo "hostwatch: cannot create $STATE_DIR" >&2; exit 1; }
chmod 700 "$STATE_DIR" 2>/dev/null || true
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
NEW=$TMP/new.txt
manifest | LC_ALL=C sort > "$NEW"

if [ "$INIT" -eq 1 ]; then
  mv "$NEW" "$BASE"
  echo "hostwatch: baseline created ($BASE, $(wc -l < "$BASE" | tr -d ' ') files)"
  exit 0
fi

if [ ! -f "$BASE" ]; then
  mv "$NEW" "$BASE"
  echo "hostwatch: first run, baseline created (no alerts)"
  exit 0
fi

DIFF=$TMP/diff.txt
diff "$BASE" "$NEW" > "$DIFF" || true
if [ ! -s "$DIFF" ]; then
  echo "hostwatch: no changes"
  exit 0
fi

grep '^>' "$DIFF" | cut -d' ' -f5- | LC_ALL=C sort -u > "$TMP/newpaths"
grep '^<' "$DIFF" | cut -d' ' -f5- | LC_ALL=C sort -u > "$TMP/oldpaths"
REPORT=$TMP/report.txt
{ CHANGED=$(comm -12 "$TMP/oldpaths" "$TMP/newpaths")
  ADDED=$(comm -13 "$TMP/oldpaths" "$TMP/newpaths")
  REMOVED=$(comm -23 "$TMP/oldpaths" "$TMP/newpaths")
  [ -n "$CHANGED" ] && printf 'changed:\n%s\n' "$CHANGED"
  [ -n "$ADDED" ] && printf 'added:\n%s\n' "$ADDED"
  [ -n "$REMOVED" ] && printf 'removed:\n%s\n' "$REMOVED"
} > "$REPORT"

HOST=$(hostname 2>/dev/null || uname -n)
TITLE="Security: changes on $HOST"
RUNUSER=$(id -un 2>/dev/null || echo unknown)
NOW=$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo unknown)
HEADER="Host: $HOST
User: $RUNUSER
Time: $NOW"
N=$(wc -l < "$REPORT" | tr -d ' ')
BODY="$HEADER

$(head -50 "$REPORT")"
if [ "$N" -gt 50 ]; then
  BODY="$BODY
... and $((N - 50)) more lines"
fi
printf '%s\n%s\n\n%s\n' "$TITLE" "$HEADER" "$(cat "$REPORT")"

if [ -n "$NOTIFY_URL" ] && [ -n "$NOTIFY_TOKEN" ]; then
  if [ -z "$NOTIFY_TOPIC" ]; then
    echo "hostwatch: NOTIFY_TOPIC not set, notify skipped" >&2
  elif command -v curl >/dev/null 2>&1; then
    curl -s -X POST "$NOTIFY_URL" -H "X-Token: $NOTIFY_TOKEN" \
      -d "{\"title\":\"$(jsonesc "$TITLE")\",\"message\":\"$(jsonesc "$BODY")\",\"topic\":\"$(jsonesc "$NOTIFY_TOPIC")\"}" \
      >/dev/null 2>&1 || echo "hostwatch: notify failed" >&2
  else
    echo "hostwatch: curl not found, notify skipped" >&2
  fi
fi

# Accept the new state so the next run is quiet (the alert already fired).
mv "$NEW" "$BASE"
