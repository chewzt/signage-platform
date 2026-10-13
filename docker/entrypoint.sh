#!/bin/sh
set -e

cd /var/www/html

# Shell inherits ECS task environment; PHP/Apache often do not.
set_env_var() {
    key="$1"
    eval "val=\$$key"
    [ -z "$val" ] && return 0

    if [ ! -f .env ]; then
        touch .env
    fi

    if grep -q "^${key}=" .env 2>/dev/null; then
        awk -v k="$key" -v v="$val" '
            BEGIN { found = 0 }
            $0 ~ "^" k "=" { print k "=" v; found = 1; next }
            { print }
            END { if (!found) print k "=" v }
        ' .env > .env.tmp && mv .env.tmp .env
    else
        printf '%s=%s\n' "$key" "$val" >> .env
    fi
}

if [ -z "$APP_KEY" ]; then
    echo "ERROR: APP_KEY is not set in the task environment." >&2
    echo "Generate one with 'php artisan key:generate --show' and add it to env/<environment>." >&2
    exit 1
fi

for key in \
    APP_NAME APP_ENV APP_KEY APP_DEBUG APP_URL \
    LOG_CHANNEL LOG_STACK LOG_LEVEL \
    DB_CONNECTION DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD \
    SESSION_DRIVER SESSION_LIFETIME SESSION_ENCRYPT SESSION_DOMAIN \
    CACHE_STORE QUEUE_CONNECTION DB_QUEUE_RETRY_AFTER \
    FILESYSTEM_DISK MEDIA_DISK \
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_BUCKET AWS_URL AWS_USE_PATH_STYLE_ENDPOINT \
    MAIL_MAILER MAIL_HOST MAIL_PORT MAIL_USERNAME MAIL_PASSWORD MAIL_FROM_ADDRESS \
    JWT_SECRET
do
    set_env_var "$key"
done

php artisan config:clear 2>/dev/null || true
rm -f bootstrap/cache/config.php \
      bootstrap/cache/routes-v7.php \
      bootstrap/cache/routes.php

# Do not run config:cache — it can freeze build-time .env values and ignore ECS env at runtime.
php artisan route:cache 2>/dev/null || true
php artisan view:cache 2>/dev/null || true

# Fail the task rather than serve a schema the code doesn't match.
# Set RUN_MIGRATIONS=false on extra replicas if concurrent starts become a problem.
if [ "${RUN_MIGRATIONS:-true}" = "true" ]; then
    php artisan migrate --force --no-interaction
fi

chown -R www-data:www-data bootstrap/cache storage .env
chmod 640 .env

umask "${UMASK:-0027}"
exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord.conf
