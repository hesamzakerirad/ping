#!/usr/bin/env bash
#
# Checks every site in sites.txt and reflects the result in GitHub issues:
#
#   - site fails and no issue is open  -> open "Down: <host>"
#   - site fails and an issue is open  -> do nothing (no duplicate mail)
#   - site passes and an issue is open -> comment and close it
#
# Certificate expiry is handled the same way under "Cert expiring: <host>".
#
# The script exits 0 when sites are down; a down site is an issue, not a
# workflow failure. A non-zero exit means the script itself broke.

set -uo pipefail

SITES_FILE="${SITES_FILE:-sites.txt}"
TRIES="${TRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-10}"
TIMEOUT="${TIMEOUT:-10}"
CERT_WARN_DAYS="${CERT_WARN_DAYS:-14}"
DRY_RUN="${DRY_RUN:-0}"

NOW="$(date -u +'%Y-%m-%d %H:%M:%SZ')"
RUN_URL=""
if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
  RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi

OPEN_ISSUES=""
FAILURES=0

log() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------- gh helpers

gh_available() {
  [[ "$DRY_RUN" == "1" ]] && return 1
  command -v gh >/dev/null 2>&1
}

load_open_issues() {
  gh_available || return 0
  OPEN_ISSUES="$(gh issue list --state open --limit 200 --json number,title 2>/dev/null)" || {
    log "WARN: could not list issues; alerts are disabled for this run"
    OPEN_ISSUES=""
  }
}

# Prints the issue number for an exact title, or nothing.
issue_number_for() {
  local title="$1"
  [[ -z "$OPEN_ISSUES" ]] && return 0
  printf '%s' "$OPEN_ISSUES" \
    | jq -r --arg t "$title" '.[] | select(.title == $t) | .number' \
    | head -n 1
}

ensure_labels() {
  gh_available || return 0
  gh label create down --color B60205 --description "Site not responding" >/dev/null 2>&1
  gh label create cert-expiry --color FBCA04 --description "TLS certificate near expiry" >/dev/null 2>&1
  return 0
}

open_issue() {
  local title="$1" body="$2" label="$3"
  if [[ -n "$(issue_number_for "$title")" ]]; then
    log "  already reported: $title"
    return 0
  fi
  if ! gh_available; then
    log "  WOULD OPEN: $title"
    return 0
  fi
  [[ -n "$RUN_URL" ]] && body="${body}"$'\n\n'"Run: ${RUN_URL}"
  if gh issue create --title "$title" --body "$body" --label "$label" >/dev/null 2>&1; then
    log "  opened issue: $title"
  else
    # Most likely the label does not exist; retry without it.
    gh issue create --title "$title" --body "$body" >/dev/null && log "  opened issue: $title"
  fi
}

close_issue() {
  local title="$1" comment="$2" number
  number="$(issue_number_for "$title")"
  [[ -z "$number" ]] && return 0
  if ! gh_available; then
    log "  WOULD CLOSE: $title"
    return 0
  fi
  [[ -n "$RUN_URL" ]] && comment="${comment}"$'\n\n'"Run: ${RUN_URL}"
  gh issue close "$number" --comment "$comment" >/dev/null && log "  closed issue #$number: $title"
}

# --------------------------------------------------------------- site checks

# Turns a sites.txt entry into a full URL.
to_url() {
  local entry="$1"
  [[ "$entry" == http://* || "$entry" == https://* ]] && { printf '%s' "$entry"; return; }
  printf 'https://%s' "$entry"
}

# Turns a sites.txt entry into a bare hostname.
to_host() {
  local entry="$1"
  entry="${entry#http://}"
  entry="${entry#https://}"
  entry="${entry%%/*}"
  entry="${entry%%\?*}"
  printf '%s' "$entry"
}

# Echoes the final HTTP status after following redirects, or a curl error.
# Returns 0 on a final 200, 1 otherwise.
http_check() {
  local url="$1" attempt code
  for ((attempt = 1; attempt <= TRIES; attempt++)); do
    code="$(curl -L -sS -o /dev/null \
      --max-time "$TIMEOUT" \
      --retry 0 \
      -w '%{http_code}' \
      -A 'ping-monitor (+github actions)' \
      "$url" 2>/dev/null)"
    if [[ "$code" == "200" ]]; then
      printf '200'
      return 0
    fi
    [[ "$attempt" -lt "$TRIES" ]] && sleep "$RETRY_DELAY"
  done
  printf '%s' "${code:-no response}"
  return 1
}

# Echoes days until the TLS certificate expires. Returns 1 if unreadable.
cert_days_left() {
  local host="$1" end exp now
  end="$(echo \
    | openssl s_client -connect "${host}:443" -servername "$host" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null \
    | cut -d= -f2)"
  [[ -z "$end" ]] && return 1

  # GNU date first, BSD/macOS date second.
  if ! exp="$(date -u -d "$end" +%s 2>/dev/null)"; then
    exp="$(date -u -j -f '%b %e %H:%M:%S %Y %Z' "$end" +%s 2>/dev/null)" || return 1
  fi
  now="$(date -u +%s)"
  printf '%s' $(( (exp - now) / 86400 ))
}

# ---------------------------------------------------------------------- main

if [[ ! -f "$SITES_FILE" ]]; then
  log "ERROR: $SITES_FILE not found"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  log "ERROR: jq is required"
  exit 1
fi

ensure_labels
load_open_issues

checked=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="$(printf '%s' "$line" | tr -d '[:space:]')"
  [[ -z "$line" ]] && continue

  checked=$((checked + 1))
  url="$(to_url "$line")"
  host="$(to_host "$line")"
  log "$host"

  # --- reachability
  if result="$(http_check "$url")"; then
    log "  up (200)"
    close_issue "Down: $host" "Recovered at ${NOW}. \`${url}\` returned 200."
  else
    FAILURES=$((FAILURES + 1))
    log "  DOWN ($result)"
    open_issue "Down: $host" \
      "\`${url}\` did not return 200.

- Result: \`${result}\`
- Attempts: ${TRIES}, ${RETRY_DELAY}s apart
- Checked at: ${NOW}

This issue closes automatically on the next run that succeeds." \
      "down"
  fi

  # --- certificate expiry
  if [[ "$url" == https://* ]]; then
    if days="$(cert_days_left "$host")"; then
      if [[ "$days" -le "$CERT_WARN_DAYS" ]]; then
        if [[ "$days" -lt 0 ]]; then
          state="expired **$(( -days )) days ago**"
          log "  cert EXPIRED $(( -days ))d ago"
        else
          state="expires in **${days} days**"
          log "  cert expires in ${days}d"
        fi
        open_issue "Cert expiring: $host" \
          "The TLS certificate for \`${host}\` ${state}.

- Threshold: ${CERT_WARN_DAYS} days
- Checked at: ${NOW}

This issue closes automatically once the certificate is renewed." \
          "cert-expiry"
      else
        log "  cert ok (${days}d)"
        close_issue "Cert expiring: $host" "Certificate renewed. It now expires in ${days} days."
      fi
    else
      log "  cert unreadable (skipped)"
    fi
  fi
done < "$SITES_FILE"

log ""
log "checked ${checked} site(s), ${FAILURES} down"
exit 0
