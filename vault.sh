#!/usr/bin/env bash
# vault: encrypted restic vault shared between your linux nodes over tor+ssh.
#
# Needs tor + ssh first (one-time, per machine):
#   curl -fsSL https://raw.githubusercontent.com/DaUmega/miscTools/refs/heads/main/torSSH.sh | bash -s -- install
#   (full docs: https://github.com/DaUmega/miscTools/blob/main/torSSH.sh)
#
# Direct run not recommended, usage:
#   wget https://raw.githubusercontent.com/DaUmega/miscTools/refs/heads/main/vault.sh && chmod +x vault.sh
#   ./vault.sh <command>
#
#   install             fetch restic + rsync + torsocks via your package manager
#   init                first machine only: create vault + node list
#   join user@onion     new machine: copy the vault from a seed node (never re-init)
#   backup <paths...>   snapshot paths into the local vault (prompts for password)
#   sync                union-copy vault with every node in nodes.txt (no password needed)
#   autosync            install hourly systemd user timer (sync only)
#   snapshots           list snapshots (prompts for password)
#   restore <dir>       restore latest snapshot into <dir> (prompts for password)
#   prune [flags]       coordinated forget --prune on all reachable nodes
#                       (default --keep-last 100; any restic forget flags pass through)
#   purge --yes         delete the vault + timer here and on every reachable node
#
# Examples:
#   vault backup ~/work ~/notes           back up two directories at once
#   vault restore /tmp/r                  full restore of the latest snapshot
#   vault restore /tmp/r --include ~/work restore just one directory
#
# The password is NEVER stored anywhere: restic prompts for it at your TTY
# whenever an operation needs it. Nodes sync encrypted blobs hourly without it.
#
# Machines never use your Bitwarden key: the timer runs as the machine with its
# own passphrase-less key (torSSH.sh keygen), authorized per node via your key.
#
# env: VAULT_HOME (local vault dir only; peers are always at ~/vault)
set -euo pipefail

VH=${VAULT_HOME:-$HOME/vault}
export RESTIC_REPOSITORY=$VH/repo

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "need $1 installed"; }
need_tty() { [ -t 0 ] || die "no TTY: run this interactively so restic can prompt for the password"; }
me() { echo "$(id -un)@$(sudo cat /var/lib/tor/ssh_hidden/hostname 2>/dev/null || hostname)"; }
rsh() { echo "torsocks ssh -o BatchMode=yes -o IdentitiesOnly=yes -i $HOME/.ssh/id_ed25519"; }
xfer() { rsync -a --exclude locks -e "$(rsh)" "$1" "$2"; } # xfer from to

cmd_install() { # install restic + rsync + torsocks; refuses restic < 0.14 (can't read current repo format)
  if command -v apt-get >/dev/null; then
    sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq restic rsync torsocks
  elif command -v dnf >/dev/null; then sudo dnf install -y -q restic rsync torsocks
  elif command -v pacman >/dev/null; then sudo pacman -Sy --noconfirm restic rsync torsocks
  else die "unsupported distro; install manually: restic rsync torsocks"; fi
  local ver; ver=$(restic version 2>/dev/null | awk '{print $2}')
  [ "0.14.0" = "$(printf '0.14.0\n%s\n' "$ver" | sort -V | head -1)" ] \
    || die "restic $ver too old (need >= 0.14): use the static binary from https://github.com/restic/restic/releases"
  echo "restic $ver ready"
}

cmd_init() {
  need restic; need rsync; need_tty
  [ -e "$VH/repo" ] && die "vault exists; use join on new machines, never re-init"
  mkdir -p "$VH"
  restic init # prompts for the new password itself; it is never written to disk
  me > "$VH/self"
  { echo "# full nodes, one per line: user@xxxx.onion"; me; } > "$VH/nodes.txt"
  echo "vault ready at $VH/repo"
}

cmd_join() { # join user@onion
  need restic; need rsync; need torsocks
  local seed=${1:?usage: vault join user@onion}
  [ -e "$VH/repo" ] && die "vault already here; refusing to overwrite"
  mkdir -p "$VH/repo"
  local pubkey; pubkey=$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || echo PASTE-KEY-HERE)
  xfer "$seed:~/vault/repo/" "$VH/repo/" \
    || die "cannot reach $seed; on $seed run: torSSH.sh auth '$pubkey'"
  xfer "$seed:~/vault/nodes.txt" "$VH/nodes.txt"
  grep -qxF "$(me)" "$VH/nodes.txt" || me >> "$VH/nodes.txt"
  if [ -t 0 ]; then restic snapshots >/dev/null && echo "joined; vault readable, password ok"
  else echo "joined; no TTY to verify the password, sync-only for now"; fi
}

cmd_backup() {
  need restic; need_tty
  local excl=()
  [ -f "$VH/exclude" ] && excl=(--exclude-file="$VH/exclude")
  restic backup "${excl[@]}" "$@"
}

cmd_sync() {
  need torsocks
  need rsync
  local n
  while read -r n; do
    case "$n" in ''|'#'*) continue;; esac
    [ "$n" = "$(cat "$VH/self")" ] && continue
    echo "== $n"
    xfer "$n:~/vault/repo/" "$VH/repo/" || { echo "  unreachable, skipped"; continue; }
    xfer "$n:~/vault/nodes.txt" "$VH/nodes.remote" 2>/dev/null \
      && sort -u "$VH/nodes.txt" "$VH/nodes.remote" > "$VH/nodes.all" && mv "$VH/nodes.all" "$VH/nodes.txt"
    xfer "$VH/repo/" "$n:~/vault/repo/" || echo "  push failed, will retry next run"
    xfer "$VH/nodes.txt" "$n:~/vault/nodes.txt" || true
  done < "$VH/nodes.txt"
}

cmd_autosync() {
  local dir=$HOME/.config/systemd/user self; self=$(readlink -f "$0")
  grep -q "cmd_autosync" "$self" 2>/dev/null \
    || die "cannot locate vault.sh (are you piping from curl? save it to a file and run ./vault.sh autosync)"
  mkdir -p "$dir"
  cat > "$dir/vault-sync.service" <<EOF
[Unit]
Description=vault hourly sync
[Service]
ExecStart=$self sync
EOF
  cat > "$dir/vault-sync.timer" <<'EOF'
[Unit]
Description=hourly vault sync
[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload && systemctl --user enable --now vault-sync.timer
  echo "autosync on: syncs hourly; backups are manual (vault backup <paths>)"
}

cmd_prune() { # prune [flags]: same forget --prune policy on every reachable node
  need torsocks
  need restic; need_tty; need timeout
  local policy=("$@") qpol n self failed=0
  [ ${#policy[@]} -eq 0 ] && policy=(--keep-last 100)
  qpol=$(printf ' %q' "${policy[@]}")
  self=$(cat "$VH/self" 2>/dev/null || me)
  echo "== $self (local)"
  restic forget "${policy[@]}" --prune || failed=1
  while read -r n; do
    case "$n" in ''|'#'*) continue;; esac
    [ "$n" = "$self" ] && continue
    echo "== $n"
    if timeout 300 torsocks ssh -t -o ConnectTimeout=60 "$n" \
        "v=\${VAULT_HOME:-\$HOME/vault}; RESTIC_REPOSITORY=\$v/repo restic forget$qpol --prune"; then
      echo "  pruned"
    else
      echo "  FAILED/unreachable: rerun prune when it is back, or its old snapshots resurrect on next sync"
      failed=1
    fi
  done < "$VH/nodes.txt"
  [ $failed -eq 0 ] || die "prune incomplete: rerun once every node is reachable"
  echo "pruned everywhere; next sync converges the replicas"
}

cmd_purge() { # purge --yes: disable timer and delete the vault here and on every reachable node
  need torsocks
  need timeout
  [ "${1:-}" = "--yes" ] || die "this deletes the vault ($VH) and its timer here and on every node in nodes.txt; rerun as 'vault purge --yes'"
  [ -f "$VH/nodes.txt" ] || die "no $VH/nodes.txt; nothing to purge"
  local n self failed=0 nodes
  self=$(cat "$VH/self" 2>/dev/null || me)
  nodes=$(grep -vE '^(#|$)' "$VH/nodes.txt")
  while read -r n; do # remotes first: local nodes.txt is needed for the list
    [ "$n" = "$self" ] && continue
    echo "== $n"
    if timeout 120 torsocks ssh -o ConnectTimeout=60 "$n" \
        "systemctl --user disable --now vault-sync.timer 2>/dev/null; rm -rf \${VAULT_HOME:-\$HOME/vault}"; then
      echo "  purged"
    else
      echo "  FAILED/unreachable: purge it manually when it is back"
      failed=1
    fi
  done <<< "$nodes"
  echo "== $self (local)"
  systemctl --user disable --now vault-sync.timer 2>/dev/null || true
  rm -rf "$VH" && echo "  purged"
  [ $failed -eq 0 ] || die "purge incomplete: unreachable nodes were skipped"
  echo "vault purged everywhere reachable"
}

cmd_snapshots() { need restic; need_tty; restic snapshots; }
cmd_restore() { # restore <dir> [--include path ...]: restore latest snapshot (or just paths)
  need restic; need_tty
  local target=${1:?usage: vault restore <dir> [--include path ...]}; shift
  restic restore latest --target "$target" "$@"
}
usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

case "${1:-}" in
  install|init|join|backup|sync|autosync|snapshots|restore|prune|purge) "cmd_$1" "${@:2}" ;;
  *) usage ;;
esac
