#!/bin/bash
#
# Brings the application to a state it can serve from, then starts whatever the container was
# asked to run. Every step is safe to repeat, so this runs on every start.

set -Eeo pipefail

ROOT_DIR=/var/www/html
CONFIG_FILE=$ROOT_DIR/data/config.ini.php
PUBLIC_SOURCE=/usr/src/webtrees/public

# Writes data/config.ini.php, then creates the database tables and the administrator. It runs as a
# condition, where set -e does not apply, so every step returns as soon as it fails.
install() {
  local dbtype=${DB_TYPE:-mysql}
  local dbhost=${DB_HOST}
  local dbport=${DB_PORT:-3306}
  local dbuser=${DB_USER:-${MYSQL_USER:-${MARIADB_USER:-${POSTGRES_USER:-webtrees}}}}
  local dbpass=${DB_PASS:-${MYSQL_PASSWORD:-${MARIADB_PASSWORD:-${POSTGRES_PASSWORD}}}}
  local dbname=${DB_NAME:-${MYSQL_DATABASE:-${MARIADB_DATABASE:-${POSTGRES_DB:-webtrees}}}}
  local tblpfx=${DB_PREFIX:-wt_}
  local base_url=${BASE_URL}

  local rewrite_urls=--no-rewrite-urls
  if [ "$PRETTY_URLS" = "true" ] || [ "$PRETTY_URLS" = "1" ]; then
    rewrite_urls=--rewrite-urls
  fi

  # webtrees opens an SQLite database, it does not create one.
  if [ "$dbtype" = "sqlite" ]; then
    touch "$ROOT_DIR/data/$dbname.sqlite" || return
  fi

  # config-ini checks the connection once the file is written: retry while the database server
  # starts. It prints the whole configuration, so only show its output when giving up, and without
  # the password.
  local attempt output
  for attempt in {1..30}; do
    if output=$(php index.php config-ini \
        --dbtype="$dbtype" \
        --dbhost="$dbhost" \
        --dbport="$dbport" \
        --dbuser="$dbuser" \
        --dbpass="$dbpass" \
        --dbname="$dbname" \
        --tblpfx="$tblpfx" \
        --base-url="$base_url" \
        "$rewrite_urls" 2>&1); then
      break
    fi
    if [ "$attempt" -eq 30 ]; then
      sed -E 's/^( *dbpass = ).*/\1"********"/' <<< "$output" >&2
      return 1
    fi
    echo "Waiting for the database..."
    sleep 2
  done
  echo "Configuration written to data/config.ini.php."

  if [ -z "$base_url" ]; then
    echo "Warning: BASE_URL is not set." >&2
  fi

  php /usr/local/lib/webtrees/install.php
}

if expr "$1" : "apache" 1>/dev/null || [ "$1" = "php-fpm" ]; then

  # With PHP-FPM, public/ is a volume the web server reads too: Docker only fills it when it is
  # empty, so bring it to the webtrees version of the image after an upgrade.
  if [ "$1" = "php-fpm" ] && [ -d "$PUBLIC_SOURCE" ] \
      && [ "$(cat "$ROOT_DIR/public/.webtrees-version" 2>/dev/null)" != "$WEBTREES_VERSION" ]; then
    echo "Copying the static files of webtrees $WEBTREES_VERSION to public/."
    find "$ROOT_DIR/public" -mindepth 1 -delete
    cp -a "$PUBLIC_SOURCE/." "$ROOT_DIR/public/"
  fi

  if [ ! -f "$CONFIG_FILE" ]; then
    echo "webtrees is not yet installed."

    # Without config.ini.php, the next start tries again from the beginning.
    if ! install; then
      rm -f "$CONFIG_FILE"
      echo "webtrees could not be installed." >&2
      exit 1
    fi
  fi

  if [ -n "$LANG" ]; then
    php index.php site-setting -- LANGUAGE "$LANG"
  fi

fi

exec "$@"
