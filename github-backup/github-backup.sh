#!/usr/bin/env bash
#
# github-backup.sh — Mirror-clone every repo across one or more GitHub
# organizations or users to a local directory. Designed to run on a
# Synology NAS via DSM Task Scheduler, but works on any *nix host with
# bash, git, curl, and python3.
#
# All dependencies are available from Synology's first-party Package
# Center (Git Server, Python 3) — no third-party package repositories
# (Entware/Homebrew/etc.) required.
#
# Configuration is loaded from (in order of precedence):
#   1. Environment variables already set in the calling shell
#   2. The file pointed to by $GITHUB_BACKUP_CONFIG
#   3. <script-dir>/config.env
#
# See config.example.env for all available settings.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${GITHUB_BACKUP_CONFIG:-$SCRIPT_DIR/config.env}"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# ---------- defaults ----------
GITHUB_ACCOUNTS="${GITHUB_ACCOUNTS:-stanasiukcom defuseddata marchemycom scrapply}"
BACKUP_ROOT="${BACKUP_ROOT:-/volume1/backups/github}"
LOG_DIR="${LOG_DIR:-$BACKUP_ROOT/logs}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
INCLUDE_PRIVATE="${INCLUDE_PRIVATE:-true}"
INCLUDE_FORKS="${INCLUDE_FORKS:-true}"
INCLUDE_ARCHIVED="${INCLUDE_ARCHIVED:-true}"
GIT_BIN="${GIT_BIN:-git}"
CURL_BIN="${CURL_BIN:-curl}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"

mkdir -p "$BACKUP_ROOT" "$LOG_DIR"

LOG_FILE="$LOG_DIR/backup-$(date +%Y%m%d-%H%M%S).log"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

err() {
    log "ERROR: $*" >&2
}

# ---------- preflight ----------
for cmd in "$GIT_BIN" "$CURL_BIN" "$PYTHON_BIN"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        err "required command not found: $cmd"
        exit 1
    fi
done

if [[ -z "$GITHUB_TOKEN" ]]; then
    err "GITHUB_TOKEN is empty. Set it in $CONFIG_FILE or the environment."
    exit 1
fi

# ---------- helpers ----------
github_api() {
    "$CURL_BIN" -fsSL \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$@"
}

# Reads a JSON object from stdin and prints the value at the given
# top-level key, or the empty string if the key is missing.
json_str_field() {
    "$PYTHON_BIN" -c '
import json, sys
key = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)
if not isinstance(data, dict):
    sys.exit(0)
val = data.get(key)
print("" if val is None else val)
' "$1"
}

# Reads a JSON array of repo objects from stdin and emits, on stdout:
#   __COUNT__\t<unfiltered length>
#   REPO\t<name>\t<clone_url>     (one per repo that passes filters)
parse_repos_page() {
    INCLUDE_FORKS="$INCLUDE_FORKS" INCLUDE_ARCHIVED="$INCLUDE_ARCHIVED" \
    "$PYTHON_BIN" -c '
import json, sys, os
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)
if not isinstance(data, list):
    sys.exit(2)
forks = os.environ.get("INCLUDE_FORKS", "true") == "true"
archived = os.environ.get("INCLUDE_ARCHIVED", "true") == "true"
print(f"__COUNT__\t{len(data)}")
for r in data:
    if not isinstance(r, dict):
        continue
    if not forks and r.get("fork"):
        continue
    if not archived and r.get("archived"):
        continue
    name = r.get("name", "")
    url = r.get("clone_url", "")
    if not name or not url:
        continue
    if "\t" in name or "\t" in url or "\n" in name or "\n" in url:
        continue
    print(f"REPO\t{name}\t{url}")
'
}

# Returns "Organization" or "User" for a given account name.
detect_account_type() {
    local name="$1"
    github_api "$GITHUB_API_URL/users/$name" | json_str_field "type"
}

# Emits "<name>|<clone_url>" lines for every repo in an account.
list_account_repos() {
    local account="$1"
    local kind="$2"      # Organization | User
    local endpoint
    local visibility="all"
    [[ "$INCLUDE_PRIVATE" == "true" ]] || visibility="public"

    if [[ "$kind" == "Organization" ]]; then
        endpoint="$GITHUB_API_URL/orgs/$account/repos?type=$visibility"
    else
        # /user/repos covers private repos the token has access to for
        # the authenticated user; /users/{name}/repos only sees public
        # ones. Fall back to /users/{name}/repos when listing someone
        # else's account.
        local me
        me=$(github_api "$GITHUB_API_URL/user" | json_str_field "login")
        if [[ "$me" == "$account" ]]; then
            local vis="all"
            [[ "$visibility" == "all" ]] || vis="public"
            endpoint="$GITHUB_API_URL/user/repos?affiliation=owner&visibility=$vis"
        else
            endpoint="$GITHUB_API_URL/users/$account/repos?type=owner"
        fi
    fi

    local page=1
    local per_page=100
    while :; do
        local sep="&"
        [[ "$endpoint" == *\?* ]] || sep="?"
        local url="${endpoint}${sep}per_page=${per_page}&page=${page}"
        local resp
        if ! resp=$(github_api "$url"); then
            err "GitHub API request failed: $url"
            return 1
        fi

        local parsed
        if ! parsed=$(printf '%s' "$resp" | parse_repos_page); then
            err "failed to parse repo list for $endpoint (page $page)"
            return 1
        fi

        local count
        count=$(printf '%s\n' "$parsed" | awk -F'\t' '$1=="__COUNT__"{print $2; exit}')
        count="${count:-0}"
        [[ "$count" -eq 0 ]] && break

        printf '%s\n' "$parsed" | awk -F'\t' '$1=="REPO"{print $2"|"$3}'

        [[ "$count" -lt "$per_page" ]] && break
        page=$((page + 1))
    done
}

# Mirror-clone or update a single repo. The token is passed via
# http.extraHeader so it never gets persisted into the on-disk git config.
backup_repo() {
    local account="$1"
    local name="$2"
    local clone_url="$3"
    local dest="$BACKUP_ROOT/$account/$name.git"
    local auth_header="Authorization: Bearer $GITHUB_TOKEN"

    if [[ -d "$dest" ]]; then
        log "  updating $account/$name"
        if ! "$GIT_BIN" -c "http.extraHeader=$auth_header" \
                -C "$dest" remote update --prune >>"$LOG_FILE" 2>&1; then
            err "update failed: $account/$name"
            return 1
        fi
    else
        log "  cloning  $account/$name"
        mkdir -p "$(dirname "$dest")"
        if ! "$GIT_BIN" -c "http.extraHeader=$auth_header" \
                clone --mirror "$clone_url" "$dest" >>"$LOG_FILE" 2>&1; then
            err "clone failed: $account/$name"
            rm -rf "$dest"
            return 1
        fi
    fi
}

rotate_logs() {
    find "$LOG_DIR" -maxdepth 1 -type f -name 'backup-*.log' \
        -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

# ---------- main ----------
main() {
    log "=== GitHub backup starting ==="
    log "backup root: $BACKUP_ROOT"
    log "accounts:    $GITHUB_ACCOUNTS"
    log "include private=$INCLUDE_PRIVATE forks=$INCLUDE_FORKS archived=$INCLUDE_ARCHIVED"

    local total=0 ok=0 fail=0

    for account in $GITHUB_ACCOUNTS; do
        local kind
        kind=$(detect_account_type "$account") || kind="Unknown"
        log "--- $account ($kind) ---"
        if [[ "$kind" != "Organization" && "$kind" != "User" ]]; then
            err "cannot resolve account: $account"
            fail=$((fail + 1))
            continue
        fi

        local repos
        if ! repos=$(list_account_repos "$account" "$kind"); then
            err "failed to list repos for $account"
            fail=$((fail + 1))
            continue
        fi

        while IFS='|' read -r name clone_url; do
            [[ -z "${name:-}" ]] && continue
            total=$((total + 1))
            if backup_repo "$account" "$name" "$clone_url"; then
                ok=$((ok + 1))
            else
                fail=$((fail + 1))
            fi
        done <<< "$repos"
    done

    log "=== summary: total=$total ok=$ok fail=$fail ==="
    rotate_logs

    [[ "$fail" -eq 0 ]]
}

main "$@"
