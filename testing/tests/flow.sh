#!/usr/bin/env bash

## TheHive <-> TheHive Flow connection test, run from the testing directory.
## Checks that TheHive loads the TheHive Flow connector, that TheHive Flow rejects
## unsigned requests, and that TheHive authenticates to TheHive Flow with the
## shared JWT signing key (thehive/config/flow.conf and .env, written by init.sh).

set -uo pipefail

BASE_URL="${BASE_URL:-https://127.0.0.1/thehive}"
CURL_OPTS="${CURL_OPTS:--sk --connect-timeout 5 --max-time 15}"
ADMIN_USER="${ADMIN_USER:-admin@thehive.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-secret}"
TIMEOUT="${TIMEOUT:-180}"
CONFIG_PATH="/api/v1/config/llm-providers"

info()    { echo "[INFO] $1" >&2; }
success() { echo "[SUCCESS] $1" >&2; }
error()   { echo "[ERROR] $1" >&2; }

# shellcheck disable=SC2086
curl_api() { curl $CURL_OPTS "$@"; }

check_prerequisites() {
  for cmd in curl jq docker; do
    command -v "$cmd" >/dev/null 2>&1 || { error "$cmd not found"; exit 1; }
  done
  docker compose ps --status running -q thehive-flow 2>/dev/null | grep -q . \
    || { error "thehive-flow is not running (run from the testing directory, after docker compose up)"; exit 1; }
}

## features.Orchestrator.enabled from flow.conf is applied
check_feature() {
  info "Checking the Orchestrator feature in TheHive status..."
  local body code
  body=$(curl_api -w '\n%{http_code}' -u "${ADMIN_USER}:${ADMIN_PASSWORD}" "${BASE_URL}/api/v1/status" 2>/dev/null) || true
  code=${body##*$'\n'}
  body=${body%$'\n'*}
  if [ "${code}" != "200" ]; then
    error "TheHive status returned HTTP ${code:-000} (expected 200)"
    return 1
  fi
  if echo "${body}" | jq -e '.features | type == "array" and index("Orchestrator") != null' >/dev/null 2>&1; then
    success "TheHive reports the Orchestrator feature"
  else
    error "Orchestrator absent from TheHive features $(echo "${body}" | jq -c '.features' 2>/dev/null): check thehive/config/flow.conf"
    return 1
  fi
}

## Without a JWT, TheHive Flow refuses its configuration endpoint.
## The probe uses GET, so it is never mistaken for TheHive configuration push (PUT).
check_unsigned_rejected() {
  info "Checking that TheHive Flow rejects requests without a JWT..."
  local code
  code=$(docker compose exec -T nginx curl -s --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' \
    "http://thehive-flow:8081${CONFIG_PATH}" 2>/dev/null) || true
  code=${code:-000}
  if [ "${code}" = "401" ]; then
    success "TheHive Flow rejects unsigned requests (HTTP 401)"
  else
    error "Unsigned request to TheHive Flow returned HTTP ${code} (expected 401)"
    return 1
  fi
}

## TheHive signs its requests to TheHive Flow with the shared key: its health probe every minute
## (GET /api/v1/version) and its configuration push (PUT). Only requests since TheHive's last start
## count, so a stack reused after a key change is judged on its current key.
check_thehive_authenticated() {
  info "Waiting for TheHive to authenticate to TheHive Flow (up to ${TIMEOUT}s)..."
  local deadline=$(( $(date +%s) + TIMEOUT )) since requests
  since=$(docker inspect --format '{{.State.StartedAt}}' "$(docker compose ps -q thehive)" 2>/dev/null)
  [ -n "${since}" ] || { error "Cannot read TheHive container start time"; return 1; }
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    requests=$(docker compose logs --no-log-prefix --since "${since}" thehive-flow 2>/dev/null \
      | jq -Rrc --arg path "${CONFIG_PATH}" 'fromjson? | select(.msg == "HTTP request handled")
          | select((.http_method == "GET" and .url_path == "/api/v1/version") or (.http_method == "PUT" and .url_path == $path))
          | "\(.http_method) \(.url_path) \(.http_status_code)"' 2>/dev/null)
    if grep -qE ' (401|403)$' <<< "${requests}"; then
      error "TheHive signed request rejected by TheHive Flow ($(grep -E ' (401|403)$' <<< "${requests}" | tail -n 1)): flow.jwt_signing_key in thehive/config/flow.conf does not match jwt_signing_key in .env"
      return 1
    fi
    if grep -q "^PUT ${CONFIG_PATH} 204$" <<< "${requests}"; then
      success "TheHive configuration accepted by TheHive Flow (signed request, HTTP 204)"
      return 0
    fi
    sleep 5
  done
  error "No signed request from TheHive accepted by TheHive Flow since TheHive start (seen: ${requests:-none}): check flow.url and the connector"
  return 1
}

main() {
  info "=== TheHive Flow connection test ==="
  check_prerequisites
  local failed=0
  check_feature || failed=1
  check_unsigned_rejected || failed=1
  check_thehive_authenticated || failed=1
  echo "" >&2
  if [ "${failed}" -eq 0 ]; then
    success "=== TheHive Flow connection test PASSED ==="
    exit 0
  else
    error "=== TheHive Flow connection test FAILED ==="
    exit 1
  fi
}

main
