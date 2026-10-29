#!/usr/bin/env bash
# Regression test for audit finding S-03 (no security headers, nginx version shown).
#
# Starts the real nginx config from this repo in Docker, with a stand-in backend that sends the same two headers the
# Spring backend sends (so a duplicate would show), then checks the headers on every kind of answer. Nothing leaves this
# machine and nothing is deployed.
#
#   tests/nginx-security-headers.sh                         test the live HTTPS template and its snippet
#   tests/nginx-security-headers.sh <template> <snippet>    test another pair (for example an older copy, to see it fail)
#
# Needs: docker, openssl, curl.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TEMPLATE="${1:-$REPO/production-9vm/app/nginx-https.conf.template}"
SNIPPET="${2:-$REPO/production-9vm/app/security-headers.conf}"
# whatever the caller passed, work with absolute paths
absolute() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
TEMPLATE="$(absolute "$TEMPLATE")"
SNIPPET="$(absolute "$SNIPPET")"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"
PORT="${PORT:-18443}"
NET=pf-hdr-test
TMP="$(mktemp -d)"
FAILED=0

# Docker on Windows wants Windows-style paths for mounts.
if command -v cygpath >/dev/null 2>&1; then P() { cygpath -m "$1"; }; else P() { echo "$1"; }; fi
# Only docker needs paths left alone (setting this for the whole script would break curl writing to /dev/null on Windows).
docker() { MSYS_NO_PATHCONV=1 command docker "$@"; }

cleanup() {
  docker rm -f pf-hdr-nginx pf-hdr-backend >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  rm -rf "$TMP"
}
[ -n "${KEEP:-}" ] || trap cleanup EXIT
cleanup_early() { docker rm -f pf-hdr-nginx pf-hdr-backend >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
cleanup_early

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILED=$((FAILED + 1)); }

mkdir -p "$TMP/certs" "$TMP/dist"
MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" -keyout "$(P "$TMP/certs/privkey.pem")" -out "$(P "$TMP/certs/fullchain.pem")" >/dev/null 2>&1 \
  || { echo "openssl could not make a test certificate"; exit 2; }
echo '<!doctype html><title>test</title><div id="root"></div>' > "$TMP/dist/index.html"

# the site config exactly as enable-https.sh makes it, pointed at the stand-in backend
sed -e 's/__DOMAIN__/localhost/g' -e 's#http://127.0.0.1:8080#http://pf-hdr-backend:8080#g' "$TEMPLATE" > "$TMP/site.conf"

# stand-in backend: answers with the two headers Spring Security adds to every response
cat > "$TMP/backend.conf" <<'EOF'
server {
    listen 8080;
    location / {
        default_type application/json;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "DENY" always;
        return 200 '{}';
    }
}
EOF

docker network create "$NET" >/dev/null
docker run -d --name pf-hdr-backend --network "$NET" -v "$(P "$TMP/backend.conf"):/etc/nginx/conf.d/default.conf:ro" "$NGINX_IMAGE" >/dev/null
docker run -d --name pf-hdr-nginx --network "$NET" -p "$PORT:443" \
  -v "$(P "$TMP/site.conf"):/etc/nginx/conf.d/default.conf:ro" \
  -v "$(P "$SNIPPET"):/etc/nginx/snippets/postafly-security-headers.conf:ro" \
  -v "$(P "$TMP/certs/fullchain.pem"):/etc/letsencrypt/live/localhost/fullchain.pem:ro" \
  -v "$(P "$TMP/certs/privkey.pem"):/etc/letsencrypt/live/localhost/privkey.pem:ro" \
  -v "$(P "$TMP/dist"):/opt/sengrid/frontend/dist:ro" \
  "$NGINX_IMAGE" >/dev/null

for _ in $(seq 1 30); do
  curl -sk -o /dev/null "https://localhost:$PORT/" && break
  sleep 1
done
if ! curl -sk -o /dev/null "https://localhost:$PORT/"; then
  echo "nginx did not start; its log:"; docker logs pf-hdr-nginx 2>&1 | tail -15; exit 2
fi

count() { printf '%s\n' "$1" | tr -d '\r' | grep -ci "^$2:"; }
value() { printf '%s\n' "$1" | tr -d '\r' | grep -i "^$2:" | head -1; }

check_path() {
  local path="$1" label="$2"
  local headers
  headers="$(curl -sk -D - -o /dev/null "https://localhost:$PORT$path")"
  echo "== $label  ($path)  $(printf '%s\n' "$headers" | head -1 | tr -d '\r')"

  for name in X-Content-Type-Options X-Frame-Options Referrer-Policy Permissions-Policy Strict-Transport-Security Content-Security-Policy-Report-Only; do
    local n; n="$(count "$headers" "$name")"
    if [ "$n" = "1" ]; then pass "$name sent once"; else fail "$name sent $n times (want exactly 1)"; fi
  done

  value "$headers" "X-Content-Type-Options" | grep -qi "nosniff" && pass "nosniff" || fail "X-Content-Type-Options is not nosniff"
  value "$headers" "X-Frame-Options" | grep -qi "DENY" && pass "frames refused" || fail "X-Frame-Options is not DENY"
  value "$headers" "Strict-Transport-Security" | grep -qi "max-age=" && pass "HSTS has a max-age" || fail "HSTS missing a max-age"
  value "$headers" "Strict-Transport-Security" | grep -qi "includeSubDomains\|preload" && fail "HSTS must not name subdomains or preload yet" || pass "HSTS has no includeSubDomains/preload"

  local server; server="$(value "$headers" "Server")"
  if printf '%s' "$server" | grep -q "[0-9]"; then fail "Server header shows a version: $server"; else pass "Server header shows no version (${server:-absent})"; fi
}

check_csp() {
  local headers csp
  headers="$(curl -sk -D - -o /dev/null "https://localhost:$PORT/")"
  csp="$(value "$headers" "Content-Security-Policy-Report-Only")"
  [ -z "$csp" ] && csp="$(value "$headers" "Content-Security-Policy")"
  echo "== the content security policy itself"
  for directive in "default-src 'self'" "script-src 'self' https://accounts.google.com/gsi/client" "object-src 'none'" "base-uri 'self'" "form-action 'self'" "frame-ancestors 'none'"; do
    printf '%s' "$csp" | grep -qF "$directive" && pass "has: $directive" || fail "missing: $directive"
  done
  # the script rule is what stops injected code, so it must never allow inline code or eval
  local scripts; scripts="$(printf '%s' "$csp" | tr ';' '\n' | grep -i "script-src" | head -1)"
  if printf '%s' "$scripts" | grep -qi "unsafe-inline\|unsafe-eval\|data:\|\*"; then fail "script-src allows inline code, eval, data: or a wildcard: $scripts"; else pass "script-src allows no inline code, eval, data: or wildcard"; fi
}

check_path "/" "the web page"
check_path "/assets/index-abc123.js" "an asset path (falls back to the page)"
check_path "/api/v1/templates" "an API answer proxied from the backend"
check_path "/track/open/abc" "a tracking link proxied from the backend"
check_path "/unsubscribe/abc" "an unsubscribe link proxied from the backend"
check_path "/api/v1/internal/anything" "a refusal made by nginx itself"
check_csp

echo
if [ "$FAILED" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "$FAILED CHECK(S) FAILED"; fi
exit "$FAILED"
