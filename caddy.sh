#!/bin/bash
# caddy.sh: generic Caddy reverse-proxy manager, bash + coreutils only.
# One domain per VPS. Subpaths proxy to local ports or serve local
# directories, and the root path / has its own slot: a local port, a
# static directory, or (by default) a plain 404 for unmatched paths.
#
# Setup (on the VPS, under sudo; no Go, no build step, just run it):
#
#	./caddy.sh setup yourname.duckdns.org
#
# Installs Caddy (if missing), creates the caddy system user, writes
# the site block and the Caddy unit, and starts Caddy. Re-running
# setup is safe and keeps existing endpoints; it also changes the
# domain when given a new one. Then add endpoints for whatever
# already listens locally:
#
#	./caddy.sh add /notify 47124        # proxy to a local port
#	./caddy.sh add /docs /var/www/docs  # serve a static directory
#	./caddy.sh add / 8080               # root app on a local port
#	./caddy.sh add / /var/www/html      # root static site (index.html)
#	./caddy.sh list
#	./caddy.sh remove /docs
#	./caddy.sh remove /                 # root back to the default 404
#
# Reverse with:
#
#	./caddy.sh purge         (prints the plan, changes nothing)
#	./caddy.sh purge --yes    (executes the purge)
#
# Notes, all measured against real Caddy on 2026-10-30:
# - No root handler and no fallback means Caddy answers unmatched
#   paths with an EMPTY 200, not a 404. This script's site block
#   therefore always carries an explicit root slot, defaulting to
#   `respond "Not found" 404`, so "nothing here" really is a 404.
# - A dead proxy backend answers 502, not 404. A missing static file
#   answers a real 404. A root proxy or root static directory is a
#   bare fallback, so subpath handles still win over it.
# - Endpoints are NOT sorted: Caddy matches the most specific path
#   first regardless of file order (verified both orders live).
# - Same markers and state file as caddy.go, so this script can take
#   over a caddy.go-managed block (it adds the root slot on first
#   rewrite). The reverse is lossy: caddy.go rebuilds the site block
#   without the root slot, so it drops a root setting if run after.
#
# CADDY_PREFIX prefixes all system paths (testing, custom installs).
# CADDY_VERSION pins the Caddy release (e.g. 2.10.2); without it the
# latest release is fetched from the GitHub API.
set -euo pipefail

PREFIX="${CADDY_PREFIX:-}"
CADDY_DIR="$PREFIX/etc/caddy"
CADDYFILE="$PREFIX/etc/caddy/Caddyfile"
CADDY_BIN="$PREFIX/usr/local/bin/caddy"
CADDY_DATA="$PREFIX/var/lib/caddy"
CADDY_SERVICE="$PREFIX/etc/systemd/system/caddy.service"
STATE_FILE="$PREFIX/etc/caddy/.proxy-state"

SITE_BEGIN="# BEGIN proxy-site (managed by caddy setup)"
SITE_END="# END proxy-site"
REGION_BEGIN=$'\t# BEGIN proxy-endpoints (managed by caddy add/remove)'
REGION_END=$'\t# END proxy-endpoints'
ROOT_BEGIN=$'\t# BEGIN proxy-root (managed by caddy add/remove)'
ROOT_END=$'\t# END proxy-root'
ROOT_DEFAULT=$'\trespond "Not found" 404'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

die() { echo "error: $*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "$1 needs root: re-run under sudo"
}

valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

# valid_subpath: /seg/seg, segments of [A-Za-z0-9._-], no empty, . or ..
valid_subpath() {
  local p="$1" seg
  [ "${#p}" -ge 2 ] || return 1
  [ "${p#/}" != "$p" ] || return 1
  IFS='/' read -ra segs <<< "${p#/}"
  for seg in "${segs[@]}"; do
    [ -n "$seg" ] || return 1
    [ "$seg" != "." ] && [ "$seg" != ".." ] || return 1
    [[ "$seg" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  done
  return 0
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# classify_target: sets KIND (port|dir) or dies. Ports are digits,
# directories are absolute paths; existence is not required, so a
# site can be added before its directory is created.
classify_target() {
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    valid_port "$1" || die "invalid port: $1"
    KIND=port
  elif [ "${1#/}" != "$1" ]; then
    KIND=dir
  else
    die "invalid target: $1 (want a port number or an absolute directory)"
  fi
}

# state: same keys and format as caddy.go (key=true/false, mode 0600).
STATE_KEYS="caddy_installed caddy_user_created caddy_service_created caddyfile_created var_lib_created"
declare -A ST
load_state() {
  local k line key val
  for k in $STATE_KEYS; do ST[$k]=false; done
  [ -f "$STATE_FILE" ] || return 0
  while IFS='=' read -r key val; do
    for k in $STATE_KEYS; do
      [ "$key" = "$k" ] && ST[$k]="$val"
    done
  done < "$STATE_FILE"
}
save_state() {
  local k
  { for k in $STATE_KEYS; do echo "$k=${ST[$k]}"; done; } > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

# line_exists: exact full-line match (no regex, so / and . are literal).
line_exists() {
  awk -v want="$2" '$0 == want { found = 1 } END { exit !found }' "$1"
}

# region_content: lines between two markers, exclusive; empty when absent.
region_content() {
  awk -v b="$2" -v e="$3" '$0 == b { f = 1; next } $0 == e { f = 0 } f' "$1"
}

# edit_caddyfile: one awk pass from infile to outfile.
# Modes: replace_block (newfile replaces the whole site block),
# delete_block (drop the whole site block), replace_region,
# replace_root, insert_ep (newfile before the region end marker),
# delete_ep (drop one endpoint block by path), insert_root
# (newfile before the site block closing brace).
edit_caddyfile() {
  local mode="$1" path="$2" newfile="$3" infile="$4" out="$5"
  awk -v mode="$mode" -v path="$path" -v newfile="$newfile" \
      -v siteBegin="$SITE_BEGIN" -v siteEnd="$SITE_END" \
      -v regionBegin="$REGION_BEGIN" -v regionEnd="$REGION_END" \
      -v rootBegin="$ROOT_BEGIN" -v rootEnd="$ROOT_END" '
    BEGIN {
      n = 0
      if (newfile != "") {
        while ((getline line < newfile) > 0) { n++; lines[n] = line }
        close(newfile)
      }
      in_site = 0; in_region = 0; in_root = 0
      skip_region = 0; skip_root = 0; skip_ep = 0; skip_block = 0; inserted = 0
    }
    mode == "replace_block" && $0 == siteBegin {
      for (i = 1; i <= n; i++) print lines[i]
      skip_block = 1; next
    }
    skip_block {
      if ($0 == siteEnd) skip_block = 0
      next
    }
    mode == "delete_block" && $0 == siteBegin { skip_block = 1; next }
    $0 == siteBegin { in_site = 1; print; next }
    $0 == siteEnd { in_site = 0; print; next }
    in_site && $0 == regionBegin {
      print
      if (mode == "replace_region") {
        for (i = 1; i <= n; i++) print lines[i]
        skip_region = 1
      }
      in_region = 1; next
    }
    in_site && $0 == regionEnd {
      if (mode == "insert_ep") { for (i = 1; i <= n; i++) print lines[i] }
      in_region = 0; skip_region = 0; print; next
    }
    skip_region { next }
    in_site && $0 == rootBegin {
      print
      if (mode == "replace_root") {
        for (i = 1; i <= n; i++) print lines[i]
        skip_root = 1
      }
      in_root = 1; next
    }
    in_site && $0 == rootEnd { in_root = 0; skip_root = 0; print; next }
    skip_root { next }
    in_region && mode == "delete_ep" && $0 == ("\t# BEGIN endpoint " path) { skip_ep = 1; next }
    skip_ep {
      if ($0 == ("\t# END endpoint " path)) skip_ep = 0
      next
    }
    in_site && mode == "insert_root" && !inserted && $0 == "}" {
      for (i = 1; i <= n; i++) print lines[i]
      inserted = 1; print; next
    }
    { print }
  ' "$infile" > "$out"
}

# site_block_file: assemble a full site block from a domain, a region
# file (endpoint blocks, may be empty) and a root file (root lines).
site_block_file() {
  local domain="$1" region="$2" root="$3" out="$4"
  {
    echo "$SITE_BEGIN"
    echo "$domain {"
    echo "$REGION_BEGIN"
    cat "$region"
    echo "$REGION_END"
    echo "$ROOT_BEGIN"
    cat "$root"
    echo "$ROOT_END"
    echo "}"
    echo "$SITE_END"
  } > "$out"
}

# endpoint_block_file: one endpoint block. handle_path strips the
# prefix before proxying or serving, plus a bare-path redirect.
endpoint_block_file() {
  local path="$1" kind="$2" val="$3" out="$4"
  {
    echo -e "\t# BEGIN endpoint $path"
    echo -e "\thandle_path $path/* {"
    if [ "$kind" = port ]; then
      echo -e "\t\treverse_proxy localhost:$val"
    else
      echo -e "\t\troot * $val"
      echo -e "\t\tfile_server"
    fi
    echo -e "\t}"
    echo -e "\tredir $path $path/"
    echo -e "\t# END endpoint $path"
  } > "$out"
}

# root_lines_file: root slot content for a port, a directory, or default.
root_lines_file() {
  local kind="$1" val="$2" out="$3"
  if [ "$kind" = port ]; then
    echo -e "\treverse_proxy localhost:$val" > "$out"
  elif [ "$kind" = dir ]; then
    { echo -e "\troot * $val"; echo -e "\tfile_server"; } > "$out"
  else
    echo "$ROOT_DEFAULT" > "$out"
  fi
}

# root_region_file: a full root region (markers + content lines).
root_region_file() {
  local kind="$1" val="$2" out="$3"
  root_lines_file "$kind" "$val" "$WORK/root-lines"
  {
    echo "$ROOT_BEGIN"
    cat "$WORK/root-lines"
    echo "$ROOT_END"
  } > "$out"
}

# resolve_caddy: prefer the managed binary, else one already on PATH.
resolve_caddy() {
  if [ -x "$CADDY_BIN" ]; then return 0; fi
  if command -v caddy >/dev/null 2>&1; then
    CADDY_BIN="$(command -v caddy)"
    return 0
  fi
  die "caddy not found, run setup <domain> first"
}

# write_validated: write the new Caddyfile, validate it, restore the
# previous content when validation fails so a bad change never stays.
write_validated() {
  local new="$1" out had_prev=0
  if [ -f "$CADDYFILE" ]; then cp "$CADDYFILE" "$WORK/prev"; had_prev=1; fi
  cp "$new" "$CADDYFILE"
  chmod 644 "$CADDYFILE"
  if ! out=$("$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile 2>&1); then
    if [ "$had_prev" -eq 1 ]; then cp "$WORK/prev" "$CADDYFILE"; chmod 644 "$CADDYFILE";
    else rm -f "$CADDYFILE"; fi
    die "caddy validate: $out"
  fi
}

reload_caddy() {
  local out
  if ! out=$(systemctl reload-or-restart caddy 2>&1); then
    die "systemctl reload caddy: $out"
  fi
}

caddy_unit() {
  cat <<EOF
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=$CADDY_BIN run --environ --config $CADDYFILE
ExecReload=$CADDY_BIN reload --config $CADDYFILE --adapter caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
}

# download_caddy: fetch the release (pinned version or latest via the
# GitHub API), retrying once on transient failure, then install.
download_caddy() {
  local arch tag ver url tmpdir api
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) die "unsupported architecture $(uname -m)" ;;
  esac
  if [ -n "${CADDY_VERSION:-}" ]; then
    tag="v$CADDY_VERSION"
    ver="$CADDY_VERSION"
  else
    api=""
    for _ in 1 2; do
      if api=$(curl -fsSL https://api.github.com/repos/caddyserver/caddy/releases/latest 2>/dev/null); then break; fi
      sleep 2
    done
    tag=$(echo "$api" | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
    [ -n "$tag" ] || die "could not fetch latest Caddy release (set CADDY_VERSION or install caddy manually to $CADDY_BIN and re-run setup)"
    ver="${tag#v}"
  fi
  url="https://github.com/caddyserver/caddy/releases/download/$tag/caddy_${ver}_linux_${arch}.tar.gz"
  tmpdir="$(mktemp -d)"
  for _ in 1 2; do
    if curl -fsSL -o "$tmpdir/caddy.tar.gz" "$url" 2>/dev/null && [ -s "$tmpdir/caddy.tar.gz" ]; then break; fi
    sleep 2
  done
  [ -s "$tmpdir/caddy.tar.gz" ] || { rm -rf "$tmpdir"; die "download $url failed"; }
  tar -xzf "$tmpdir/caddy.tar.gz" -C "$tmpdir" caddy 2>/dev/null || { rm -rf "$tmpdir"; die "caddy binary not found in release archive"; }
  install -m 755 "$tmpdir/caddy" "$CADDY_BIN"
  rm -rf "$tmpdir"
  "$CADDY_BIN" version >/dev/null 2>&1 || die "caddy version check failed"
}

# require_site: die unless the managed site block exists.
require_site() {
  [ -f "$CADDYFILE" ] || die "no proxy site block, run setup <domain> first"
  grep -q -F -x "$SITE_BEGIN" "$CADDYFILE" || die "no proxy site block, run setup <domain> first"
}

# require_region: die unless the endpoints region markers exist.
require_region() {
  grep -q -F -x "$REGION_BEGIN" "$CADDYFILE" || die "site block damaged: run purge --yes, then setup again"
  grep -q -F -x "$REGION_END" "$CADDYFILE" || die "site block damaged: run purge --yes, then setup again"
}

setup_cmd() {
  local domain="$1" out data_new=0 file_existed=0
  need_root setup
  valid_domain "$domain" || die "invalid domain: $domain"
  load_state
  echo "setting up caddy for $domain"
  [ -d "$CADDY_DATA" ] || data_new=1
  mkdir -p "$CADDY_DIR" "$CADDY_DATA" "$(dirname "$CADDY_BIN")" "$(dirname "$CADDY_SERVICE")"
  if [ "$data_new" -eq 1 ]; then ST[var_lib_created]=true; save_state; fi
  if ! id caddy >/dev/null 2>&1; then
    if ! out=$(useradd --system --home-dir "$CADDY_DATA" --no-create-home --shell /usr/sbin/nologin caddy 2>&1); then
      die "create user caddy: $out"
    fi
    ST[caddy_user_created]=true; save_state
  fi
  if ! out=$(chown caddy:caddy "$CADDY_DATA" 2>&1); then die "chown $CADDY_DATA: $out"; fi
  chmod 750 "$CADDY_DATA"
  if ! out=$(chown caddy:caddy "$CADDY_DIR" 2>&1); then die "chown $CADDY_DIR: $out"; fi
  chmod 750 "$CADDY_DIR"
  if [ ! -x "$CADDY_BIN" ]; then
    if command -v caddy >/dev/null 2>&1; then
      CADDY_BIN="$(command -v caddy)"
    else
      echo "downloading caddy..."
      download_caddy
      ST[caddy_installed]=true; save_state
    fi
  fi
  [ -f "$CADDYFILE" ] && file_existed=1
  if grep -q -F -x "$SITE_BEGIN" "$CADDYFILE" 2>/dev/null; then
    require_region
    region_content "$CADDYFILE" "$REGION_BEGIN" "$REGION_END" > "$WORK/region"
    if grep -q -F -x "$ROOT_BEGIN" "$CADDYFILE"; then
      region_content "$CADDYFILE" "$ROOT_BEGIN" "$ROOT_END" > "$WORK/root"
    else
      echo "$ROOT_DEFAULT" > "$WORK/root"
    fi
    site_block_file "$domain" "$WORK/region" "$WORK/root" "$WORK/block"
    edit_caddyfile replace_block "" "$WORK/block" "$CADDYFILE" "$WORK/new"
    write_validated "$WORK/new"
  else
    : > "$WORK/region"
    echo "$ROOT_DEFAULT" > "$WORK/root"
    site_block_file "$domain" "$WORK/region" "$WORK/root" "$WORK/block"
    if [ -f "$CADDYFILE" ]; then
      cp "$CADDYFILE" "$WORK/new"
      [ -n "$(tail -c 1 "$CADDYFILE" | tr -d '\n')" ] && echo >> "$WORK/new"
      cat "$WORK/block" >> "$WORK/new"
    else
      cp "$WORK/block" "$WORK/new"
    fi
    write_validated "$WORK/new"
  fi
  if [ "$file_existed" -eq 0 ]; then ST[caddyfile_created]=true; save_state; fi
  if [ ! -f "$CADDY_SERVICE" ]; then
    caddy_unit > "$CADDY_SERVICE"
    chmod 644 "$CADDY_SERVICE"
    ST[caddy_service_created]=true; save_state
  fi
  if ! out=$(systemctl daemon-reload 2>&1); then die "systemctl daemon-reload: $out"; fi
  if ! out=$(systemctl enable --now caddy 2>&1); then die "systemctl enable: $out"; fi
  reload_caddy
  echo "done. add endpoints with: ./caddy.sh add /name <port>"
}

# describe_target: "localhost:PORT" or "file_server DIR" for messages.
describe_target() {
  if [ "$1" = port ]; then echo "localhost:$2"; else echo "file_server $2"; fi
}

add_cmd() {
  local path="$1" target="$2" kind val existed=0
  need_root add
  if [ "$path" = "/" ]; then
    classify_target "$target"; kind="$KIND"; val="$target"
    require_site
    resolve_caddy
    if grep -q -F -x "$ROOT_BEGIN" "$CADDYFILE"; then
      region_content "$CADDYFILE" "$ROOT_BEGIN" "$ROOT_END" > "$WORK/cur-root"
      if grep -q -F -x "$ROOT_DEFAULT" "$WORK/cur-root"; then existed=0; else existed=1; fi
      root_lines_file "$kind" "$val" "$WORK/new-root"
      edit_caddyfile replace_root "" "$WORK/new-root" "$CADDYFILE" "$WORK/new"
    else
      root_region_file "$kind" "$val" "$WORK/new-root-region"
      edit_caddyfile insert_root "" "$WORK/new-root-region" "$CADDYFILE" "$WORK/new"
      grep -q -F -x "$ROOT_BEGIN" "$WORK/new" || die "could not insert root region, site block damaged"
    fi
    write_validated "$WORK/new"
    reload_caddy
    if [ "$existed" -eq 1 ]; then echo "updated / -> $(describe_target "$kind" "$val")";
    else echo "added / -> $(describe_target "$kind" "$val")"; fi
    return 0
  fi
  path="$(echo "$path" | sed 's:/*$::')"
  valid_subpath "$path" || die "invalid path: $1 (want a subpath like /notify, or / for the root)"
  classify_target "$target"; kind="$KIND"; val="$target"
  require_site
  require_region
  resolve_caddy
  endpoint_block_file "$path" "$kind" "$val" "$WORK/block"
  if line_exists "$CADDYFILE" "$(printf '\t# BEGIN endpoint %s' "$path")"; then
    existed=1
    edit_caddyfile delete_ep "$path" "" "$CADDYFILE" "$WORK/step1"
    edit_caddyfile insert_ep "" "$WORK/block" "$WORK/step1" "$WORK/new"
  else
    edit_caddyfile insert_ep "" "$WORK/block" "$CADDYFILE" "$WORK/new"
  fi
  write_validated "$WORK/new"
  reload_caddy
  if [ "$existed" -eq 1 ]; then echo "updated $path -> $(describe_target "$kind" "$val")";
  else echo "added $path -> $(describe_target "$kind" "$val")"; fi
}

remove_cmd() {
  local path="$1"
  need_root remove
  if [ "$path" = "/" ]; then
    require_site
    resolve_caddy
    if grep -q -F -x "$ROOT_BEGIN" "$CADDYFILE"; then
      echo "$ROOT_DEFAULT" > "$WORK/new-root"
      edit_caddyfile replace_root "" "$WORK/new-root" "$CADDYFILE" "$WORK/new"
    else
      root_region_file default "" "$WORK/new-root-region"
      edit_caddyfile insert_root "" "$WORK/new-root-region" "$CADDYFILE" "$WORK/new"
      grep -q -F -x "$ROOT_BEGIN" "$WORK/new" || die "could not insert root region, site block damaged"
    fi
    write_validated "$WORK/new"
    reload_caddy
    echo "root reset to default 404"
    return 0
  fi
  path="$(echo "$path" | sed 's:/*$::')"
  valid_subpath "$path" || die "invalid path: $1"
  require_site
  require_region
  resolve_caddy
  line_exists "$CADDYFILE" "$(printf '\t# BEGIN endpoint %s' "$path")" || die "endpoint $path not found"
  edit_caddyfile delete_ep "$path" "" "$CADDYFILE" "$WORK/new"
  write_validated "$WORK/new"
  reload_caddy
  echo "removed $path"
}

list_cmd() {
  local cur_path cur_kind cur_val line rest
  require_site
  require_region
  awk -v regionBegin="$REGION_BEGIN" -v regionEnd="$REGION_END" '
    $0 == regionBegin { f = 1; next }
    $0 == regionEnd { f = 0; next }
    !f { next }
    {
      t = $0
      sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
      if (t ~ /^# BEGIN endpoint /) {
        cur = substr(t, length("# BEGIN endpoint ") + 1)
      } else if (t ~ /^reverse_proxy localhost:/) {
        port = substr(t, length("reverse_proxy localhost:") + 1)
        printf "%s -> localhost:%s\n", cur, port
      } else if (t ~ /^root \*/) {
        split(t, a, " ")
        printf "%s -> file_server %s\n", cur, a[3]
      }
    }
  ' "$CADDYFILE"
  if grep -q -F -x "$ROOT_BEGIN" "$CADDYFILE"; then
    rest="$(region_content "$CADDYFILE" "$ROOT_BEGIN" "$ROOT_END")"
    if echo "$rest" | grep -q 'reverse_proxy localhost:'; then
      echo "/ -> localhost:$(echo "$rest" | sed -n 's/.*reverse_proxy localhost:\([0-9]*\).*/\1/p' | head -1)"
    elif echo "$rest" | grep -q 'file_server'; then
      echo "/ -> file_server $(echo "$rest" | sed -n 's/^[ \t]*root \* \(.*\)/\1/p' | head -1)"
    elif echo "$rest" | grep -q -F "$ROOT_DEFAULT"; then
      echo "/ -> 404 (default)"
    else
      echo "/ -> (custom)"
    fi
  else
    echo "/ -> (none, unmatched paths get an empty 200)"
  fi
}

purge_cmd() {
  local yes=0 p
  for p in "$@"; do [ "$p" = "--yes" ] && yes=1; done
  need_root purge
  load_state
  local -a plan=()
  if [ "${ST[caddy_service_created]}" = true ] && [ -f "$CADDY_SERVICE" ]; then
    plan+=("stop and disable caddy service, remove $CADDY_SERVICE")
  fi
  if [ -f "$CADDYFILE" ] && grep -q -F -x "$SITE_BEGIN" "$CADDYFILE"; then
    plan+=("remove proxy site block (all endpoints) from $CADDYFILE")
  fi
  [ -f "$STATE_FILE" ] && plan+=("remove $STATE_FILE")
  if [ "${ST[var_lib_created]}" = true ] && [ -d "$CADDY_DATA" ]; then
    plan+=("remove $CADDY_DATA")
  fi
  if [ "${ST[caddy_installed]}" = true ] && [ -f "$CADDY_BIN" ]; then
    plan+=("remove $CADDY_BIN")
  fi
  if [ "${ST[caddy_user_created]}" = true ] && id caddy >/dev/null 2>&1; then
    plan+=("remove user caddy")
  fi
  if [ "${#plan[@]}" -eq 0 ]; then echo "nothing to purge"; return 0; fi
  if [ "$yes" -eq 0 ]; then
    echo "purge plan (nothing changed):"
    for p in "${plan[@]}"; do echo " - $p"; done
    echo "re-run with --yes to execute"
    return 0
  fi
  if [ "${ST[caddy_service_created]}" = true ]; then
    systemctl stop caddy 2>/dev/null || true
    systemctl disable caddy 2>/dev/null || true
    rm -f "$CADDY_SERVICE"
  fi
  if [ -f "$CADDYFILE" ] && grep -q -F -x "$SITE_BEGIN" "$CADDYFILE" && grep -q -F -x "$SITE_END" "$CADDYFILE"; then
    edit_caddyfile delete_block "" "" "$CADDYFILE" "$WORK/new"
    rest="$(cat "$WORK/new")"
    if [ -z "$(echo "$rest" | tr -d '[:space:]')" ] && [ "${ST[caddyfile_created]}" = true ]; then
      rm -f "$CADDYFILE"
    else
      cp "$WORK/new" "$CADDYFILE"
      chmod 644 "$CADDYFILE"
    fi
    if [ "${ST[caddy_service_created]}" != true ] && [ -f "$CADDY_BIN" ] && [ -n "$(echo "$rest" | tr -d '[:space:]')" ]; then
      systemctl reload-or-restart caddy 2>/dev/null || true
    fi
  fi
  rm -f "$STATE_FILE"
  if [ "${ST[var_lib_created]}" = true ]; then rm -rf "$CADDY_DATA"; fi
  if [ "${ST[caddy_installed]}" = true ]; then rm -f "$CADDY_BIN"; fi
  if [ "${ST[caddy_user_created]}" = true ] && id caddy >/dev/null 2>&1; then
    userdel caddy 2>/dev/null || true
  fi
  systemctl daemon-reload 2>/dev/null || true
  echo "purge complete"
}

usage() {
  cat >&2 <<EOF
usage: ./caddy.sh <command> [args]
  setup <domain>           install Caddy and create the site block (sudo)
  add <path> <port|dir>    add or update an endpoint, e.g. add /notify 47124,
                           add /docs /var/www/docs, add / 8080 (sudo)
  remove <path>            remove an endpoint; remove / resets root to 404 (sudo)
  list                     show current endpoints and the root slot
  purge [--yes]            dry-run, or with --yes remove everything setup created (sudo)
EOF
  exit 1
}

main() {
  [ $# -ge 1 ] || usage
  case "$1" in
    setup) [ $# -ge 2 ] || usage; setup_cmd "$2" ;;
    add) [ $# -ge 3 ] || usage; add_cmd "$2" "$3" ;;
    remove) [ $# -ge 2 ] || usage; remove_cmd "$2" ;;
    list) list_cmd ;;
    purge) shift; purge_cmd "$@" ;;
    *) echo "unknown command: $1" >&2; usage ;;
  esac
}

main "$@"
