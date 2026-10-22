#!/usr/bin/env bash

## TheHive <-> TheHive Flow connection test, run from the testing directory.
## Checks that TheHive loads the TheHive Flow connector, that TheHive Flow rejects
## unsigned requests, and that TheHive authenticates to TheHive Flow with the
## shared JWT signing key (thehive/config/flow.conf and .env, written by init.sh).

set -uo pipefail

BASE_URL="${BASE_URL:-https://127.0.0.1/thehive}"
CURL_OPTS="${CURL_OPTS:--sk}"
ADMIN_USER="${ADMIN_USER:-admin@thehive.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-secret}"
TIMEOUT="${TIMEOUT:-180}"

info()    { echo "[INFO] $1" >&2; }
success() { echo "[SUCCESS] $1" >&2; }
error()   { echo "[ERROR] $1" >&2; }

# shellcheck disable=SC2086
curl_api() { curl $CURL_OPTS "$@"; }

check_prerequisites() {
  for cmd in curl jq docker; do
    command -v "$cmd" >/dev/null 2>&1 || { error "$cmd not found"; exit 1; }
  done
}

## features.Orchestrator.enabled from flow.conf is applied
check_feature() {
  info "Checking the Orchestrator feature in TheHive status..."
  if curl_api -u "${ADMIN_USER}:${ADMIN_PASSWORD}" "${BASE_URL}/api/v1/status" \
    | jq -e '.features | index("Orchestrator")' >/dev/null 2>&1; then
    success "TheHive reports the Orchestrator feature"
  else
    error "TheHive does not report the Orchestrator feature: check thehive/config/flow.conf"
    return 1
  fi
}

## Without a JWT, TheHive Flow refuses its configuration endpoint
check_unsigned_rejected() {
  info "Checking that TheHive Flow rejects requests without a JWT..."
  local code
  code=$(docker compose exec -T nginx curl -s -o /dev/null -w '%{http_code}' \
    -X PUT -H 'Content-Type: application/json' -d '{}' \
    http://thehive-flow:8081/api/v1/config/llm-providers 2>/dev/null || echo 000)
  if [ "$code" = "401" ]; then
    success "TheHive Flow rejects unsigned requests (HTTP 401)"
  else
    error "Unsigned request to TheHive Flow returned HTTP ${code} (expected 401)"
    return 1
  fi
}

## TheHive pushes its configuration to TheHive Flow with a JWT signed with the shared key
check_thehive_authenticated() {
  info "Waiting for TheHive to authenticate to TheHive Flow (up to ${TIMEOUT}s)..."
  local deadline=$(( $(date +%s) + TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if docker compose logs --no-log-prefix thehive-flow 2>/dev/null \
      | jq -Rce 'fromjson? | select(.msg == "HTTP request handled" and .url_path == "/api/v1/config/llm-providers" and .http_status_code == 204)' \
      >/dev/null 2>&1; then
      success "TheHive configuration accepted by TheHive Flow (signed request, HTTP 204)"
      return 0
    fi
    sleep 5
  done
  error "No signed request from TheHive accepted by TheHive Flow: check flow.url and flow.jwt_signing_key"
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
  if [ "$failed" -eq 0 ]; then
    success "=== TheHive Flow connection test PASSED ==="
    exit 0
  else
    error "=== TheHive Flow connection test FAILED ==="
    exit 1
  fi
}

main
