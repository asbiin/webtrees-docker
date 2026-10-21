#!/bin/bash
#
# Brings the application to a state it can serve from, then starts whatever the container was
# asked to run. Every step is safe to repeat, so this runs on every start.

set -Eeo pipefail

ROOT_DIR=/var/www/html


if expr "$1" : "apache" 1>/dev/null || [ "$1" = "php-fpm" ]; then

  echo "1"
  if [ ! -f "$ROOT_DIR/data/config.ini.php" ]; then
    echo "webtrees is not yet installed."

    dbtype=${DB_TYPE:-mysql}
    dbhost=${DB_HOST}
    dbport=${DB_PORT:-3306}
    dbuser=${DB_USER:-${MYSQL_USER:-${MARIADB_USER:-${POSTGRES_USER:-webtrees}}}}
    dbpass=${DB_PASS:-${MYSQL_PASSWORD:-${MARIADB_PASSWORD:-${POSTGRES_PASSWORD:-webtrees}}}}
    dbname=${DB_NAME:-${MYSQL_DATABASE:-${MARIADB_DATABASE:-${POSTGRES_DB:-webtrees}}}}
    tblpfx=${DB_PREFIX:-wt_}
    base_url=${BASE_URL}

    php index.php config-ini \
      --dbtype="$dbtype" \
      --dbhost="$dbhost" \
      --dbport="$dbport" \
      --dbuser="$dbuser" \
      --dbpass="$dbpass" \
      --dbname="$dbname" \
      --tblpfx="$tblpfx" \
      --base-url="$base_url"

    if [ "$PRETTY_URLS" = "true" -o "$PRETTY_URLS" = "1" ]; then
      php index.php config-ini --rewrite-urls
    else
      php index.php config-ini --no-rewrite-urls
    fi

    # Create the initial admin user
    if [ -n "$WT_USER" ] && [ -n "$WT_NAME" ] && [ -n "$WT_PASS" ] && [ -n "$WT_EMAIL" ]; then
      php index.php user --create \
        --real-name="$WT_NAME" \
        --password="$WT_PASS" \
        --email="$WT_EMAIL" \
        -- $WT_USER
      php index.php user-setting -- "$WT_USER" canadmin 1
    fi

  fi

  if [ -n "$LANG" ]; then
    php index.php site-setting -- LANGUAGE "$LANG"
  fi

fi

exec "$@"
