# Stage 1: Install PHP production dependencies only
FROM php:8.3-cli-alpine AS composer-builder
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install \
    --no-dev \
    --no-interaction \
    --prefer-dist \
    --optimize-autoloader \
    --no-scripts \
    --no-progress \
    --ignore-platform-reqs

# Stage 2: Build frontend assets
FROM node:22-alpine AS node-builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY vite.config.js ./
COPY resources/ ./resources/
COPY public/ ./public/
RUN npm run build

# Stage 3: Final runtime image — no Node.js, no Composer cache, no git
FROM php:8.3-apache

# ffmpeg/ffprobe are required by App\Transcode\FfmpegTranscoder for uploaded videos.
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
    curl \
    openssl \
    zip \
    unzip \
    supervisor \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Pinned deliberately: 'latest/download' makes BuildKit hit github.com on every
# build just to resolve the cache key and re-busts the cache on every upstream
# release. Bump manually.
ARG PHP_EXT_INSTALLER_VERSION=2.11.12
RUN curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 15 \
      -o /usr/local/bin/install-php-extensions \
      "https://github.com/mlocati/docker-php-extension-installer/releases/download/${PHP_EXT_INSTALLER_VERSION}/install-php-extensions" && \
    chmod +x /usr/local/bin/install-php-extensions && \
    install-php-extensions \
      zip \
      pdo_mysql \
      mbstring \
      intl \
      bcmath \
      opcache && \
    rm -f /usr/local/bin/install-php-extensions

# Apache configuration
COPY apache-app.conf /etc/apache2/sites-available/
RUN a2dissite 000-default.conf && \
    a2ensite apache-app.conf && \
    a2enmod rewrite && \
    a2enmod headers && \
    echo "ServerName localhost" >> /etc/apache2/apache2.conf

COPY custom.ini /usr/local/etc/php/conf.d/

RUN mkdir -p /var/log/supervisor

WORKDIR /var/www/html/

# Copy app source (.dockerignore excludes vendor/, node_modules/, public/build/, env/)
COPY . .
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY docker/entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY docker/.env.build .env

# Pull in build artifacts — only the outputs, not the toolchains
COPY --from=node-builder /app/public/build/ ./public/build/
COPY --from=composer-builder /app/vendor/ ./vendor/

RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# No key:generate here: a key baked into the image would differ per build and
# break sessions across replicas. APP_KEY must come from the task environment.
RUN php artisan package:discover --ansi

# Ensure storage directories exist (excluded from build context via .dockerignore)
RUN mkdir -p storage/framework/views \
              storage/framework/cache/data \
              storage/framework/sessions \
              storage/logs \
              storage/app/media \
              bootstrap/cache

# Never ship cached config/routes from the image; entrypoint rebuilds from ECS env at start
RUN rm -f bootstrap/cache/config.php \
          bootstrap/cache/routes-v7.php \
          bootstrap/cache/routes.php

RUN chown -R www-data:www-data storage bootstrap/cache && \
    chmod -R 775 storage bootstrap/cache

EXPOSE 80

ENV UMASK=0027
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
