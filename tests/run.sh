#!/bin/bash
#
# Smoke tests of a built image: checks the image itself, then installs webtrees with SQLite, serves
# it (through nginx for the fpm variant) and requests a few pages.
#
#   tests/run.sh IMAGE [apache|fpm]

set -Eeuo pipefail

IMAGE=${1:?usage: $0 IMAGE [apache|fpm]}
VARIANT=${2:-apache}
NAME=webtrees-test-$$
ROOT=$(cd "$(dirname "$0")/.." && pwd)

failures=0

pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1" >&2; failures=$((failures + 1)); }
check() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}

cleanup() {
  if [ "$failures" -gt 0 ]; then
    echo "--- logs of $NAME"
    docker logs "$NAME" 2>&1 | tail -n 50 || true
    if [ "$VARIANT" = "fpm" ]; then
      echo "--- logs of $NAME-web"
      docker logs "$NAME-web" 2>&1 | tail -n 20 || true
    fi
  fi
  docker rm --force --volumes "$NAME" "$NAME-web" >/dev/null 2>&1 || true
  docker volume rm "$NAME-data" "$NAME-public" >/dev/null 2>&1 || true
  docker network rm "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Runs a command in a throwaway container of the image, bypassing the entrypoint.
in_image() { docker run --rm --entrypoint "" "$IMAGE" "$@"; }

echo "Image $IMAGE ($VARIANT)"

check "runs as the webtrees user" test "$(in_image id -un)" = webtrees
check "ships webtrees $(in_image printenv WEBTREES_VERSION)" in_image test -f /var/www/html/index.php
check "webtrees command line runs" in_image php index.php list
case $VARIANT in
  apache)
    check "Apache configuration is valid" in_image apache2ctl -t
    check "mod_rewrite is enabled" sh -c "docker run --rm --entrypoint '' '$IMAGE' apache2ctl -M | grep -q rewrite_module"
    check "CMD starts Apache" test "$(docker image inspect --format '{{join .Config.Cmd " "}}' "$IMAGE")" = apache2-foreground
    ;;
  fpm)
    check "PHP-FPM configuration is valid" in_image php-fpm --test
    check "image keeps a copy of public/" in_image test -f /usr/src/webtrees/public/.webtrees-version
    check "CMD starts PHP-FPM" test "$(docker image inspect --format '{{join .Config.Cmd " "}}' "$IMAGE")" = php-fpm
    ;;
  *)
    echo "Unknown variant: $VARIANT" >&2
    exit 2
    ;;
esac

# Install and serve webtrees.
docker network create "$NAME" >/dev/null
run_args=(
  --detach --name "$NAME" --network "$NAME" --network-alias webtrees
  --volume "$NAME-data:/var/www/html/data"
  --env BASE_URL=http://localhost --env PRETTY_URLS=1 --env LANG=fr
  --env DB_TYPE=sqlite
  --env WT_USER=admin --env WT_NAME=Administrator --env WT_PASS=test-password
  --env WT_EMAIL=admin@example.com
)
if [ "$VARIANT" = "apache" ]; then
  docker run "${run_args[@]}" --publish 127.0.0.1::80 "$IMAGE" >/dev/null
  WEB=$NAME
else
  docker run "${run_args[@]}" --volume "$NAME-public:/var/www/html/public" "$IMAGE" >/dev/null
  docker run --detach --name "$NAME-web" --network "$NAME" --publish 127.0.0.1::80 \
    --volume "$ROOT/examples/fpm/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
    --volume "$NAME-public:/var/www/html/public:ro" \
    nginx:stable >/dev/null
  WEB=$NAME-web
fi
URL=http://$(docker port "$WEB" 80/tcp | head -n 1)

# Prints the HTTP status of a page.
status() { curl --silent --output /dev/null --max-time 10 --write-out '%{http_code}' "$URL$1"; }

# Without a tree, the home page redirects visitors to the login page.
for _ in {1..60}; do
  if [ "$(status /login || true)" = 200 ]; then break; fi
  if [ "$(docker inspect --format '{{.State.Running}}' "$NAME")" != true ]; then break; fi
  sleep 1
done

check "first start installs webtrees" docker exec "$NAME" test -f data/config.ini.php
check "first start creates the SQLite database" docker exec "$NAME" test -s data/webtrees.sqlite
check "first start creates the administrator" sh -c "docker exec '$NAME' php index.php user-list | grep -q admin"
check "home page redirects to the login page" test "$(status /)" = 302
check "login page answers 200" test "$(status /login)" = 200
check "login page is a webtrees page" sh -c "curl --silent --max-time 10 '$URL/login' | grep -qi webtrees"
check "LANG sets the site language" sh -c "curl --silent --max-time 10 '$URL/login' | grep -q 'lang=\"fr\"'"
check "static files are served" test "$(status /public/favicon.ico)" = 200
check "data/ cannot be downloaded" sh -c "! curl --silent --max-time 10 '$URL/data/config.ini.php' | grep -q dbpass"

# A second start must keep the installation.
docker restart "$NAME" >/dev/null
# A restart can publish the port on another host port.
URL=http://$(docker port "$WEB" 80/tcp | head -n 1)
for _ in {1..30}; do
  if [ "$(status /login || true)" = 200 ]; then break; fi
  sleep 1
done
check "restart answers 200" test "$(status /login)" = 200
check "restart does not install again" \
  test "$(docker logs "$NAME" 2>&1 | grep -c 'webtrees is not yet installed')" = 1

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed."
  exit 1
fi
echo "All tests passed."
