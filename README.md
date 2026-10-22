# webtrees-docker

[![build](https://github.com/asbiin/webtrees-docker/actions/workflows/build.yml/badge.svg)](https://github.com/asbiin/webtrees-docker/actions/workflows/build.yml)

Docker image for [webtrees](https://webtrees.net/), the free and open source web application for collaborative genealogy.

- Built on the official `php:8.4-apache` image, with every PHP extension webtrees uses, plus APCu and OPcache.
- Ships the latest webtrees release and is rebuilt every week to pick up security fixes from the base image.
- Runs as an unprivileged user (`webtrees`, UID/GID 1000).
- Configures itself on the first start from environment variables: no setup wizard to click through.
- Works with MySQL/MariaDB, PostgreSQL and SQLite.
- Available for `linux/amd64` and `linux/arm64`.

## Contents

- [Quick start](#quick-start)
- [Image tags](#image-tags)
- [Examples](#examples)
- [How the first start works](#how-the-first-start-works)
- [Configuration](#configuration)
- [Behind a reverse proxy](#behind-a-reverse-proxy)
- [Command line](#command-line)
- [Backup and restore](#backup-and-restore)
- [Upgrading](#upgrading)
- [Building the image](#building-the-image)

## Quick start

```bash
docker run -d --name webtrees -p 8080:80 \
  -v webtrees-data:/var/www/html/data \
  -e BASE_URL=http://localhost:8080 \
  -e DB_TYPE=sqlite \
  -e WT_USER=admin -e WT_NAME=Administrator -e WT_PASS=changeme -e WT_EMAIL=admin@example.com \
  ghcr.io/asbiin/webtrees:latest
```

Open <http://localhost:8080> and log in as `admin` / `changeme`.

That is enough to try webtrees. For a real site, start from one of the [examples](#examples).

## Image tags

The image is published as `ghcr.io/asbiin/webtrees`.

| Tag | Content |
|---|---|
| `latest` | The latest webtrees release. |
| `2.2.6`, … | A given webtrees release. |

The tag of the current webtrees release is rebuilt every week; the tags of older releases stop being updated. Pin a version tag on a production site and [upgrade](#upgrading) when you decide to.

## Examples

The [`examples`](examples) folder holds three ready-to-run Docker Compose setups. Each one is a starting point: copy the folder and adapt it.

| Example | Best for | Services |
|---|---|---|
| [`sqlite`](examples/sqlite) | Trying webtrees, a small private family tree | webtrees |
| [`mariadb`](examples/mariadb) | A home server or a NAS, a site behind a reverse proxy you already run | webtrees, MariaDB |
| [`traefik`](examples/traefik) | A public site over HTTPS | Traefik, webtrees, MariaDB |

### 1. Single container with SQLite

```bash
cd examples/sqlite
docker compose up -d
```

The database is the file `data/webtrees.sqlite`, in the same volume as the media files: one volume to back up and nothing else to run. webtrees recommends MySQL/MariaDB for larger trees, as some features (such as sorting names by the rules of each language) rely on MySQL collations.

### 2. With MariaDB

```bash
cd examples/mariadb
cp .env.example .env   # then set the passwords
docker compose up -d
```

webtrees is served over plain HTTP on port 8080. This suits a local network, or a reverse proxy that already runs on the host and forwards to that port (see [Behind a reverse proxy](#behind-a-reverse-proxy)).

The webtrees service waits for the database health check, as the first start needs a database that accepts connections. Compose refuses to start until both passwords are set in `.env`.

<details>
<summary>Using PostgreSQL instead of MariaDB</summary>

Replace the `db` service, and change the database settings of the `webtrees` service. `DB_PORT` must be set: the image defaults to the MySQL port.

```yaml
services:
  webtrees:
    environment:
      DB_TYPE: "pgsql"
      DB_HOST: "db"
      DB_PORT: "5432"
      DB_USER: "webtrees"
      DB_PASS: "${DB_PASSWORD:?}"
      DB_NAME: "webtrees"
      # ...

  db:
    image: postgres:18
    environment:
      POSTGRES_DB: "webtrees"
      POSTGRES_USER: "webtrees"
      POSTGRES_PASSWORD: "${DB_PASSWORD}"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U webtrees -d webtrees"]
      interval: 10s
      timeout: 5s
      retries: 5
    volumes:
      - db-data:/var/lib/postgresql
    restart: unless-stopped
```

</details>

### 3. Public site over HTTPS with Traefik

```bash
cd examples/traefik
cp .env.example .env   # then fill in every value
docker compose up -d
```

[Traefik](https://traefik.io/traefik/) obtains a Let's Encrypt certificate for `WEBTREES_DOMAIN`, redirects HTTP to HTTPS and forwards requests to webtrees. Before starting, make sure the DNS record of the domain points to the server and that ports 80 and 443 are reachable from the Internet. Compose refuses to start while a required value of `.env` is missing.

<details>
<summary>Joining a Traefik instance you already run</summary>

Remove the `traefik` service and connect webtrees to the network your Traefik watches (here, an external network named `proxy`):

```yaml
services:
  webtrees:
    networks:
      - default
      - proxy
    labels:
      - traefik.enable=true
      - traefik.docker.network=proxy
      - traefik.http.routers.webtrees.rule=Host(`tree.example.com`)
      - traefik.http.routers.webtrees.entrypoints=websecure
      - traefik.http.routers.webtrees.tls.certresolver=letsencrypt
      - traefik.http.services.webtrees.loadbalancer.server.port=80

networks:
  proxy:
    external: true
```

Keep the database on the `default` network only, so that it is not reachable from the proxy network. Adjust the entry point and certificate resolver names to those of your Traefik configuration.

</details>

## How the first start works

Each time the container starts Apache, its entrypoint:

1. Checks for `data/config.ini.php`. When it is missing, webtrees is not installed yet, so the entrypoint:
   - writes `config.ini.php` from `BASE_URL`, `PRETTY_URLS` and the `DB_*` variables, waiting up to a minute for the database server to accept connections (with SQLite, it creates the database file);
   - creates the database tables;
   - creates the administrator account, when `WT_USER`, `WT_NAME`, `WT_PASS` and `WT_EMAIL` are all set.

   When a step fails, the entrypoint removes `config.ini.php` and stops the container: the next start tries again from the beginning.
2. Sets the default language of the site, when `LANG` is set.
3. Starts Apache.

As a result:

- `BASE_URL`, `PRETTY_URLS`, `DB_*` and `WT_*` are only read on the very first start. Changing them later has no effect: see [Changing the configuration](#changing-the-configuration).
- Once the site is installed, you can remove `WT_PASS` from your configuration. Change the administrator password from the webtrees interface.
- The data volume and the database go together. If you lose `config.ini.php` but keep the database, the next start installs webtrees again over the existing tables: they are kept, and the `WT_USER` account gets its administrator rights back, with `WT_PASS` as its password.

## Configuration

### Environment variables

Read on the first start only:

| Variable | Default | Description |
|---|---|---|
| `BASE_URL` | *(empty)* | Public address of the site, such as `https://tree.example.com`. webtrees builds every link from it, so use the address visitors type, not the address of the container. |
| `PRETTY_URLS` | *(off)* | `1` or `true` for URLs such as `/tree/smith/individual/I1` instead of `/index.php?route=…`. |
| `DB_TYPE` | `mysql` | `mysql` (MySQL and MariaDB), `pgsql` (PostgreSQL) or `sqlite`. |
| `DB_HOST` | *(empty)* | Host name of the database server. Not used with SQLite. |
| `DB_PORT` | `3306` | Port of the database server. **Set it to `5432` for PostgreSQL.** |
| `DB_USER` | `webtrees` | Database user. Falls back to `MYSQL_USER`, `MARIADB_USER` or `POSTGRES_USER`. |
| `DB_PASS` | *(empty)* | Password of the database user. Falls back to `MYSQL_PASSWORD`, `MARIADB_PASSWORD` or `POSTGRES_PASSWORD`. |
| `DB_NAME` | `webtrees` | Database name. Falls back to `MYSQL_DATABASE`, `MARIADB_DATABASE` or `POSTGRES_DB`. With SQLite, the database is the file `data/<DB_NAME>.sqlite`. |
| `DB_PREFIX` | `wt_` | Prefix of the table names, which lets several webtrees sites share a database. |
| `WT_USER` | | User name of the administrator account to create. |
| `WT_NAME` | | Real name of the administrator. |
| `WT_PASS` | | Password of the administrator. |
| `WT_EMAIL` | | Email address of the administrator. |

The fallbacks let the webtrees and database services share a single `env_file` that sets `MARIADB_USER`, `MARIADB_PASSWORD` and `MARIADB_DATABASE`.

Read on every start:

| Variable | Default | Description |
|---|---|---|
| `LANG` | *(unchanged)* | Default language of the site, as a webtrees language code: `en-US`, `en-GB`, `fr`, `de`, `nl`, `pt-BR`, `zh-Hans`… ([full list](https://github.com/fisharebest/webtrees/tree/main/resources/lang)). Each user can still pick their own language. |
| `PHP_MEMORY_LIMIT` | `512M` | PHP `memory_limit`. |
| `PHP_UPLOAD_LIMIT` | `512M` | PHP `upload_max_filesize` and `post_max_size`: the largest media file or GEDCOM file you can upload. |
| `APACHE_BODY_LIMIT` | `1073741824` | Apache `LimitRequestBody`, in bytes (1 GiB). |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS` | `0` | With `0`, PHP files stay cached until the container restarts. Set `1` while you develop a module. |
| `PHP_OPCACHE_MAX_ACCELERATED_FILES` | `20000` | OPcache `max_accelerated_files`. |
| `PHP_OPCACHE_MEMORY_CONSUMPTION` | `192` | OPcache `memory_consumption`, in MB. |
| `PHP_OPCACHE_MAX_WASTED_PERCENTAGE` | `10` | OPcache `max_wasted_percentage`. |

### Volumes

| Path | Content |
|---|---|
| `/var/www/html/data` | **Must be persisted.** `config.ini.php`, media files (`media/`), the SQLite database, the cache. |
| `/var/www/html/modules_v4` | Optional. [Third-party modules](https://webtrees.net/download/modules). |

Named volumes, as in the examples, are the simplest: Docker fills them with the content of the image and gives them the right owner. A bind mount works too, as long as the host directory belongs to UID 1000:

```bash
mkdir -p data && sudo chown 1000:1000 data
```

OPcache does not check PHP files for changes, so restart the container after adding or updating a module:

```bash
docker compose restart webtrees
```

### Changing the configuration

The settings written on the first start live in `data/config.ini.php`. The `config-ini` command updates the options you pass and keeps the others, then checks the database connection:

```bash
docker compose exec webtrees php index.php config-ini --base-url=https://tree.example.com
docker compose exec webtrees php index.php config-ini --rewrite-urls      # or --no-rewrite-urls
docker compose exec webtrees php index.php config-ini --dbpass=new-password
```

Run `docker compose exec webtrees php index.php config-ini --help` for the full list of options.

### User and group

Apache runs as the user `webtrees` (UID 1000, GID 1000) and listens on port 80 inside the container. To run with another UID/GID, for instance to match the owner of a bind-mounted directory, build the image yourself (see [Building the image](#building-the-image)) with `--build-arg UID=… --build-arg GID=…`.

## Behind a reverse proxy

The container serves plain HTTP on port 80: terminate HTTPS in a reverse proxy in front of it.

- Set `BASE_URL` to the public `https://` address.
- webtrees records the IP address of visitors in its logs and uses it to block abusive robots. Apache takes the visitor address from the `X-Real-IP` header, and only trusts it from private networks (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), which include Docker networks. Traefik sends this header by default; other proxies must be told to.
- Raise the request size limit of the proxy to match `PHP_UPLOAD_LIMIT`.
- When the proxy runs on the host, publish the port on the loopback interface only, so that webtrees cannot be reached around the proxy: `"127.0.0.1:8080:80"`.

nginx:

```nginx
server {
    listen 443 ssl;
    server_name tree.example.com;
    # ssl_certificate ...

    client_max_body_size 512M;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Caddy:

```caddyfile
tree.example.com {
    reverse_proxy 127.0.0.1:8080 {
        header_up X-Real-IP {remote_host}
    }
}
```

## Command line

webtrees comes with command line tools. List them with:

```bash
docker compose exec webtrees php index.php list
```

### Import a GEDCOM file

```bash
docker compose cp family.ged webtrees:/var/www/html/data/family.ged
docker compose exec webtrees php index.php tree --create --title="Smith family" smith
docker compose exec webtrees php index.php tree-import smith data/family.ged
docker compose exec webtrees rm data/family.ged
```

### Export a tree

```bash
docker compose exec -w /var/www/html/data webtrees php ../index.php tree-export smith
docker compose cp webtrees:/var/www/html/data/smith.ged .
docker compose exec webtrees rm data/smith.ged
```

> [!WARNING]
> `tree-export` writes the file into the current directory. Always run it from `data/`, as above: the default directory is the web root, where anyone could download the file.

`--format` selects `gedcom` (default), `gedzip`, `zip` or `zipmedia` (with the media files), and `--privacy` applies the privacy rules of `none` (default), `manager`, `member` or `visitor`.

### Other tasks

```bash
# List the users, reset a password
docker compose exec webtrees php index.php user-list
docker compose exec webtrees php index.php user --password='new password' admin

# Show a maintenance page to visitors, then reopen the site
docker compose exec webtrees php index.php site-offline "Back in a few minutes"
docker compose exec webtrees php index.php site-online
```

## Backup and restore

A webtrees site is made of its database and of its data volume: back up both, at the same time.

With MariaDB:

```bash
docker compose exec -T db sh -c 'mariadb-dump -u webtrees -p"$MARIADB_PASSWORD" webtrees' > webtrees.sql
docker compose cp webtrees:/var/www/html/data ./data-backup
```

To restore the database:

```bash
docker compose exec -T db sh -c 'mariadb -u webtrees -p"$MARIADB_PASSWORD" webtrees' < webtrees.sql
```

With SQLite, the database is in the data volume: stop the container before copying it, so that the file is consistent.

```bash
docker compose stop webtrees
docker compose cp webtrees:/var/www/html/data ./data-backup
docker compose start webtrees
```

## Upgrading

The webtrees code lives in the image; your data lives in the database and in the data volume. To upgrade:

1. [Back up](#backup-and-restore) the database and the data volume.
2. Check that your third-party modules support the new webtrees version.
3. Change the image tag in `docker-compose.yml` (or keep `latest`), then:

   ```bash
   docker compose pull
   docker compose up -d
   ```

webtrees upgrades the database schema by itself on the first page request after the upgrade.

## Building the image

```bash
docker build -t webtrees .
```

| Build argument | Default | Description |
|---|---|---|
| `WEBTREES_VERSION` | `2.2.6` | webtrees release to install. The CI passes the latest release. |
| `UID` | `1000` | UID of the `webtrees` user. |
| `GID` | `1000` | GID of the `webtrees` user. |

```bash
docker build --build-arg WEBTREES_VERSION=2.2.6 --build-arg UID=1001 --build-arg GID=1001 -t webtrees:2.2.6 .
```

To run a local build from one of the examples, replace its `image:` line with `build: ../..`.

## License

This repository is released under the [MIT license](LICENSE). webtrees itself is released under the [GPL-3.0 license](https://github.com/fisharebest/webtrees/blob/main/LICENSE.md).
