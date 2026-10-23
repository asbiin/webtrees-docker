ARG PHP_VERSION=8.4
# apache: Apache and mod_php, serves HTTP on port 80.
# fpm: PHP-FPM only, serves FastCGI on port 9000 to a web server in another container.
ARG VARIANT=apache

FROM php:${PHP_VERSION}-${VARIANT} AS base

# entrypoint.sh dependencies
RUN set -ex; \
    \
    apt-get update --quiet; \
    apt-get install --yes --quiet --no-install-recommends \
        bash \
        busybox-static \
        unzip \
    ; \
    rm -rf /var/lib/apt/lists/*

# gd needs the image libraries, intl needs ICU, zip needs libzip. git and unzip are what Composer
# reads a package from a dist archive with.
RUN set -ex; \
    \
    savedAptMark="$(apt-mark showmanual)"; \
    \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libicu-dev \
        zlib1g-dev \
        libzip-dev \
        libpng-dev \
        libpq-dev \
        libxml2-dev \
        libgmp-dev \
        libssl-dev \
        libwebp-dev \
        libcurl4-openssl-dev \
    ; \
    \
    debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"; \
    if [ ! -e /usr/include/gmp.h ]; then ln -s /usr/include/$debMultiarch/gmp.h /usr/include/gmp.h; fi;\
    docker-php-ext-configure intl; \
    docker-php-ext-install --jobs "$(nproc)" \
        intl \
        zip \
        bcmath \
        gd \
        gmp \
        pdo_mysql \
        mysqli \
        pdo_pgsql \
        soap \
    ; \
    \
# pecl will claim success even if one install fails, so we need to perform each install separately
    pecl install APCu; \
    \
    docker-php-ext-enable \
        apcu \
    ; \
    \
# reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark; \
    ldd "$(php -r 'echo ini_get("extension_dir");')"/*.so \
        | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); print so }' \
        | sort -u \
        | xargs -r dpkg-query -S \
        | cut -d: -f1 \
        | sort -u \
        | xargs -rt apt-mark manual; \
    \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists/*

# Opcache
ENV PHP_OPCACHE_VALIDATE_TIMESTAMPS="0" \
    PHP_OPCACHE_MAX_ACCELERATED_FILES="20000" \
    PHP_OPCACHE_MEMORY_CONSUMPTION="192" \
    PHP_OPCACHE_MAX_WASTED_PERCENTAGE="10"
# Limits
ENV PHP_MEMORY_LIMIT="512M" \
    PHP_UPLOAD_LIMIT="512M"
RUN set -ex; \
    \
    # OPcache is built into PHP from 8.5 on, and an extension to enable before
    if ! php -r 'exit(extension_loaded("Zend OPcache") ? 0 : 1);'; then \
        docker-php-ext-enable opcache; \
    fi; \
    { \
        echo '[opcache]'; \
        echo 'opcache.enable=1'; \
        echo 'opcache.revalidate_freq=0'; \
        echo 'opcache.validate_timestamps=${PHP_OPCACHE_VALIDATE_TIMESTAMPS}'; \
        echo 'opcache.max_accelerated_files=${PHP_OPCACHE_MAX_ACCELERATED_FILES}'; \
        echo 'opcache.memory_consumption=${PHP_OPCACHE_MEMORY_CONSUMPTION}'; \
        echo 'opcache.max_wasted_percentage=${PHP_OPCACHE_MAX_WASTED_PERCENTAGE}'; \
        echo 'opcache.interned_strings_buffer=16'; \
        echo 'opcache.fast_shutdown=1'; \
    } > $PHP_INI_DIR/conf.d/opcache-recommended.ini; \
    \
    echo 'apc.enable_cli=1' >> $PHP_INI_DIR/conf.d/docker-php-ext-apcu.ini; \
    \
    { \
        echo 'memory_limit=${PHP_MEMORY_LIMIT}'; \
        echo 'upload_max_filesize=${PHP_UPLOAD_LIMIT}'; \
        echo 'post_max_size=${PHP_UPLOAD_LIMIT}'; \
    } > $PHP_INI_DIR/conf.d/limits.ini;

# Fails the build when an extension webtrees needs did not make it into the image.
RUN set -e; \
    for ext in apcu bcmath curl gd gmp iconv intl mbstring mysqli pdo_mysql pdo_pgsql pdo_sqlite \
        simplexml soap xml zip 'Zend OPcache'; do \
        php -r "exit(extension_loaded('$ext') ? 0 : 1);" || { echo "Missing PHP extension: $ext" >&2; exit 1; }; \
    done

ARG UID=1000
ARG GID=1000
RUN set -ex; \
    \
    groupadd --gid "${GID}" webtrees || true; \
    useradd --uid "${UID}" --gid "${GID}" --create-home webtrees; \
    mkdir --parents /var/www/html; \
    chown webtrees:webtrees /var/www/html

ENV HOME=/home/webtrees
WORKDIR /var/www/html
USER webtrees

ARG WEBTREES_VERSION=2.2.6
ENV WEBTREES_VERSION="${WEBTREES_VERSION}"
LABEL org.opencontainers.image.version="v${WEBTREES_VERSION}"
RUN set -ex; \
    \
    cd /var/www/html; \
    curl -fsSL -o webtrees.zip "https://github.com/fisharebest/webtrees/releases/download/${WEBTREES_VERSION}/webtrees-${WEBTREES_VERSION}.zip"; \
    unzip webtrees.zip; \
    rm webtrees.zip; \
    mv webtrees/* .; \
    rmdir webtrees; \
    test -f index.php

COPY entrypoint.sh /usr/local/bin/
COPY install.php /usr/local/lib/webtrees/

ENTRYPOINT ["entrypoint.sh"]


FROM base AS variant-apache

USER root

RUN set -ex; \
    \
    a2enmod headers rewrite remoteip; \
    { \
        echo RemoteIPHeader X-Real-IP; \
        echo RemoteIPTrustedProxy 10.0.0.0/8; \
        echo RemoteIPTrustedProxy 172.16.0.0/12; \
        echo RemoteIPTrustedProxy 192.168.0.0/16; \
    } > $APACHE_CONFDIR/conf-available/remoteip.conf; \
    a2enconf remoteip

# set apache config LimitRequestBody
ENV APACHE_BODY_LIMIT=1073741824
RUN set -ex; \
    \
    { \
        echo 'LimitRequestBody ${APACHE_BODY_LIMIT}'; \
    } > $APACHE_CONFDIR/conf-available/apache-limits.conf; \
    a2enconf apache-limits

RUN mkdir --parents /var/run/apache2 /var/lock/apache2 \
    && chown --recursive webtrees:webtrees /var/run/apache2 /var/lock/apache2 /var/log/apache2

# envvars reads the two below with := , so an environment already carrying them wins. Apache cannot
# change user once it has started as one, and telling it which user that is keeps it from warning.
ENV APACHE_RUN_USER=webtrees
ENV APACHE_RUN_GROUP=webtrees

COPY --chown=webtrees:webtrees .htaccess /var/www/html/.htaccess

USER webtrees

# Fails the build on an invalid Apache configuration.
RUN apache2ctl -t

CMD ["apache2-foreground"]


FROM base AS variant-fpm

USER root

# The pool runs as the user that starts PHP-FPM: user and group can only be set when starting as
# root, and FPM warns about them otherwise.
RUN set -ex; \
    \
    sed -i -E 's/^(user|group) = /;\1 = /' /usr/local/etc/php-fpm.d/www.conf

# The web server serves public/ itself, from a volume it shares with this container. The entrypoint
# fills that volume from this copy whenever it holds another webtrees version.
RUN set -ex; \
    \
    echo "${WEBTREES_VERSION}" > /var/www/html/public/.webtrees-version; \
    chown webtrees:webtrees /var/www/html/public/.webtrees-version; \
    mkdir --parents /usr/src/webtrees; \
    cp -a /var/www/html/public /usr/src/webtrees/public

USER webtrees

# Fails the build on an invalid PHP-FPM configuration.
RUN php-fpm --test

CMD ["php-fpm"]


FROM variant-${VARIANT}
