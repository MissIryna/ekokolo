# Розгортання на дроплеті

Екоколо живе на тому ж дроплеті, що й Menuger (`129.212.252.150`,
Ubuntu 24.04, Postgres 16, Ruby 3.3.6 через rbenv у `deploy`).
Усе, що тут робиться, лежить окремо від Menuger: своя база, свій
systemd-юніт, свій файл nginx.

**Єдина спільна точка — nginx.** Перед кожним `reload` — `sudo nginx -t`.
Не робити цього в пікові години Menuger.

```
/home/deploy/ekokolo/            клон репо, тут же .env і tmp/puma.sock
/home/deploy/backups/ekokolo/    щоденні дампи
/etc/systemd/system/ekokolo.service
/etc/nginx/sites-available/ekokolo.conf
```

## 1. База

Пароль — тільки літери й цифри, щоб не екранувати його в URL.

```bash
openssl rand -hex 24                       # згенерувати пароль
sudo -u postgres createuser --pwprompt ekokolo
sudo -u postgres createdb --owner ekokolo ekokolo
```

## 2. Код

```bash
cd ~
git clone https://github.com/MissIryna/ekokolo.git
cd ekokolo
bundle config set --local deployment true
~/.rbenv/bin/rbenv exec bundle install
```

`.env` (тільки на сервері, у git не потрапляє):

```bash
cat > .env <<'EOF'
DATABASE_URL=postgres://ekokolo:ПАРОЛЬ@127.0.0.1/ekokolo
DB_POOL=3
ALLOWED_ORIGINS=https://ekokolo.pp.ua
EOF
chmod 600 .env
```

Схема:

```bash
set -a; . ./.env; set +a
psql "$DATABASE_URL" -f db/schema.sql
```

## 3. Puma

```bash
sudo cp deploy/ekokolo.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ekokolo
curl --unix-socket tmp/puma.sock http://x/api/health    # {"ok":true}
```

На цьому кроці Menuger не зачеплено взагалі.

## 4. DNS і сертифікат

Поки цей крок не зроблено, сайт працює на GitHub Pages як раніше.

1. У nic.ua для `ekokolo.pp.ua`: прибрати CNAME на GitHub, додати
   A-запис `129.212.252.150`.
2. Дочекатися, поки `dig +short ekokolo.pp.ua` покаже цю адресу.
   Між цим моментом і кроком 5 сайт не відкриватиметься — catch-all
   обриває невідомі домени. Це кілька хвилин; краще ввечері.
3. Сертифікат (конфіг nginx не змінює, лише отримує файли):

   ```bash
   sudo certbot certonly --nginx -d ekokolo.pp.ua
   ```

   Продовжуватиметься сам — тим самим certbot, що й для Menuger.

## 5. nginx

```bash
sudo cp deploy/ekokolo.conf /etc/nginx/sites-available/
sudo ln -s /etc/nginx/sites-available/ekokolo.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

Перевірка:

```bash
curl -s https://ekokolo.pp.ua/api/health            # {"ok":true}
curl -s -o /dev/null -w '%{http_code}\n' https://ekokolo.pp.ua/.env      # 404
curl -s -o /dev/null -w '%{http_code}\n' https://ekokolo.pp.ua/app.rb    # 404
curl -s -o /dev/null -w '%{http_code}\n' https://menuger.me/              # як і було
```

## 6. Бекап

```bash
crontab -e
# дописати:
15 3 * * * /home/deploy/ekokolo/deploy/backup.sh >> /home/deploy/backups/ekokolo/backup.log 2>&1
```

Одразу прогнати руками: `deploy/backup.sh`.

## Оновлення

```bash
cd ~/ekokolo
git pull
~/.rbenv/bin/rbenv exec bundle install
set -a; . ./.env; set +a; psql "$DATABASE_URL" -f db/schema.sql   # ідемпотентна
sudo systemctl reload ekokolo
```

Зміни лише в `index.html` нічого з цього, крім `git pull`, не потребують.

## Відкат

Повернути в nic.ua CNAME на `MissIryna.github.io` — і через кілька
хвилин сайт знову з GitHub Pages. Поступ дітей у localStorage живе під
тим самим доменом, тож нікуди не дінеться.
