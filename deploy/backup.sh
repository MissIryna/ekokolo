#!/bin/bash
# Щоденна копія бази Коло добрих екосправ.
#
# Crontab користувача deploy (crontab -e):
#     15 3 * * * /home/deploy/ekokolo/deploy/backup.sh >> /home/deploy/backups/ekokolo/backup.log 2>&1
#
# Відновлення:
#     pg_restore --clean --no-owner --dbname="$DATABASE_URL" ekokolo-РРРР-ММ-ДД.dump

set -euo pipefail

APP=/home/deploy/ekokolo
DIR=/home/deploy/backups/ekokolo
KEEP_DAYS=14

set -a
. "$APP/.env"
set +a

umask 077
mkdir -p "$DIR"

# Спершу в .tmp, потім mv: обірваний дамп не прикинеться цілим.
FILE="$DIR/ekokolo-$(date +%F).dump"
pg_dump --format=custom --no-owner --dbname="$DATABASE_URL" --file="$FILE.tmp"
mv "$FILE.tmp" "$FILE"

find "$DIR" -name 'ekokolo-*.dump' -mtime +"$KEEP_DAYS" -delete

echo "$(date '+%F %T') ok $(du -h "$FILE" | cut -f1)"
