#!/bin/bash
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "root"; exit 1; fi
umask 077
MODE="${1:-}"
SITE=""
if [ -f /etc/nginx/conf.d/didar.conf ]; then
 SITE=/etc/nginx/conf.d/didar.conf
elif [ -f /etc/nginx/sites-available/didar ]; then
 SITE=/etc/nginx/sites-available/didar
fi
AUTO=/etc/didar/ssl-auto.conf
MODEFILE=/etc/didar/ssl-mode
if [ -z "$SITE" ] || [ ! -f "$SITE" ]; then echo "site"; exit 1; fi

write_hook(){
 local d=/etc/letsencrypt/renewal-hooks/deploy
 if [ ! -d "$d" ]; then return 0; fi
 cat > "$d/didar.sh" <<'EOF'
#!/bin/bash
set -e
if [ -f /etc/didar/ssl-mode ] && grep -qx manual /etc/didar/ssl-mode; then
 exit 0
fi
DOM="$(tr -d '\r\n' < /etc/didar/domain)"
cp "/etc/letsencrypt/live/${DOM}/fullchain.pem" /etc/coturn/certs/fullchain.pem
cp "/etc/letsencrypt/live/${DOM}/privkey.pem" /etc/coturn/certs/privkey.pem
chown turnserver:turnserver /etc/coturn/certs/fullchain.pem /etc/coturn/certs/privkey.pem
chmod 640 /etc/coturn/certs/fullchain.pem /etc/coturn/certs/privkey.pem
systemctl restart coturn
EOF
 chmod 755 "$d/didar.sh"
}

cert_line(){ awk '/^[[:space:]]*ssl_certificate[[:space:]]/{print $2; exit}' "$SITE" | tr -d ';'; }
key_line(){ awk '/^[[:space:]]*ssl_certificate_key[[:space:]]/{print $2; exit}' "$SITE" | tr -d ';'; }

snapshot(){
 if [ -f "$AUTO" ]; then return 0; fi
 local c k
 c="$(cert_line || true)"
 k="$(key_line || true)"
 case "$c" in
  /etc/didar/ssl/*|"") return 0;;
 esac
 if [ ! -f "$c" ] || [ ! -f "$k" ]; then return 0; fi
 openssl x509 -in "$c" -noout >/dev/null 2>&1 || return 0
 openssl pkey -in "$k" -noout >/dev/null 2>&1 || return 0
 printf 'cert=%s\nkey=%s\n' "$c" "$k" > "$AUTO"
 chmod 644 "$AUTO"
}

point_nginx(){
 local cert="$1" key="$2"
 cp -f "$SITE" "$SITE.didar-bak"
 sed -i -E "s#^([[:space:]]*)ssl_certificate_key[[:space:]]+[^;]+;#\1ssl_certificate_key ${key};#" "$SITE"
 sed -i -E "s#^([[:space:]]*)ssl_certificate[[:space:]]+[^;]+;#\1ssl_certificate ${cert};#" "$SITE"
}

write_https_conf(){
 local cert="$1" key="$2" app="" dom="" ngxver="" http2=""
 if [ -f /etc/didar/appdir ]; then app="$(tr -d '\r\n' < /etc/didar/appdir)"; fi
 if [ -f /etc/didar/domain ]; then dom="$(tr -d '\r\n' < /etc/didar/domain)"; fi
 [ -n "$app" ] && [ -d "$app" ] && [ -n "$dom" ] || { echo "site"; exit 1; }
 ngxver="$(nginx -v 2>&1 | awk -F/ '{print $2; exit}')"
 http2="    listen 443 ssl http2;"
 if [ "$(printf '%s\n%s\n' "$ngxver" "1.25.1" | sort -V | head -n 1)" = "1.25.1" ]; then
  http2=$'    listen 443 ssl;\n    http2 on;'
 fi
 cp -f "$SITE" "$SITE.didar-bak"
 cat > "$SITE" <<EOF
server {
    listen 80;
    server_name ${dom};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type text/plain;
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
${http2}
    server_name ${dom};

    server_tokens off;

    ssl_certificate ${cert};
    ssl_certificate_key ${key};

    root ${app};
    index index.php;

    client_max_body_size 64m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ^~ /rtc {
        proxy_pass http://127.0.0.1:7880;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 3600s;
    }

    location ^~ /twirp {
        proxy_pass http://127.0.0.1:7880;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 60s;
    }

    location ~ \.php\$ {
        try_files \$uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:/run/php/didar.sock;
        fastcgi_read_timeout 600s;
    }

    location = /schema.sql { deny all; }
    location ^~ /install/ { deny all; }
    location = /didar-install.sh { deny all; }
    location = /didar-update.sh { deny all; }
    location = /didar-reinstall.sh { deny all; }
    location = /didar-renew.sh { deny all; }
    location = /didar-ssl.sh { deny all; }
    location = /didar-uninstall.sh { deny all; }
    location = /install.php { deny all; }

    location ~ ^/(storage|lib)/ { deny all; }
    location ~ /(config\.php|config\.local\.php)\$ {
        deny all;
    }
    location ~ /\. {
        deny all;
    }
}
EOF
}

ensure_turn_tls(){
 local conf=/etc/turnserver.conf
 [ -f "$conf" ] || return 0
 grep -q '^tls-listening-port=' "$conf" || printf '\ntls-listening-port=5349\n' >> "$conf"
 grep -q '^cert=' "$conf" || printf 'cert=/etc/coturn/certs/fullchain.pem\n' >> "$conf"
 grep -q '^pkey=' "$conf" || printf 'pkey=/etc/coturn/certs/privkey.pem\n' >> "$conf"
}

restore_site(){
 if [ -f "$SITE.didar-bak" ]; then cp -f "$SITE.didar-bak" "$SITE"; rm -f "$SITE.didar-bak"; fi
}

apply_turn(){
 local cert="$1" key="$2"
 if [ ! -d /etc/coturn/certs ]; then return 0; fi
 cp -f "$cert" /etc/coturn/certs/fullchain.pem
 cp -f "$key" /etc/coturn/certs/privkey.pem
 chown turnserver:turnserver /etc/coturn/certs/fullchain.pem /etc/coturn/certs/privkey.pem 2>/dev/null || true
 chmod 640 /etc/coturn/certs/fullchain.pem /etc/coturn/certs/privkey.pem || true
 systemctl restart coturn >/dev/null 2>&1 || true
}

restart_web(){
 nohup bash -c "sleep 2; systemctl restart nginx" >/dev/null 2>&1 &
}

pub_of_key(){ openssl pkey -in "$1" -pubout 2>/dev/null | tr -d '\r' | sed '/^$/d' || true; }
pub_of_cert(){ openssl x509 -in "$1" -pubkey -noout 2>/dev/null | tr -d '\r' | sed '/^$/d' || true; }
pub_of_file(){ openssl pkey -pubin -in "$1" -pubout 2>/dev/null | tr -d '\r' | sed '/^$/d' || true; }

if [ "$MODE" = "manual" ]; then
 SRC="${2:-}"
 SRC="$(readlink -f "$SRC" 2>/dev/null || true)"
 bn="$(basename "$SRC")"
 printf '%s' "$bn" | grep -Eq '^[a-f0-9]{16}$' || { echo "stage"; exit 1; }
 ok=0
 APP=""
 if [ -f /etc/didar/appdir ]; then APP="$(tr -d '\r\n' < /etc/didar/appdir)"; fi
 for base in "$APP" /var/www/didar; do
  [ -n "$base" ] || continue
  stage="$(readlink -f "$base/storage/ssl-stage" 2>/dev/null || true)"
  [ -n "$stage" ] || continue
  if [ "$(dirname "$SRC")" = "$stage" ]; then ok=1; fi
 done
 [ "$ok" = 1 ] || { echo "stage"; exit 1; }
 for f in privkey.pem cert.pem; do
  [ -f "$SRC/$f" ] || { echo "file"; exit 1; }
 done
 openssl pkey -in "$SRC/privkey.pem" -noout >/dev/null 2>&1 || { echo "key"; exit 1; }
 A="$(pub_of_key "$SRC/privkey.pem")"
 [ -n "$A" ] || { echo "key"; exit 1; }
 if [ -s "$SRC/pubkey.pem" ] && grep -qE 'BEGIN (RSA )?PUBLIC KEY' "$SRC/pubkey.pem"; then
  C="$(pub_of_file "$SRC/pubkey.pem")"
  [ -n "$C" ] && [ "$A" = "$C" ] || { echo "match"; exit 1; }
 fi
 tmpd="$(mktemp -d)"
 : > "$tmpd/all.pem"
 [ -s "$SRC/cert.pem" ] && cat "$SRC/cert.pem" >> "$tmpd/all.pem"
 if [ -s "$SRC/bundle.pem" ]; then printf '\n' >> "$tmpd/all.pem"; cat "$SRC/bundle.pem" >> "$tmpd/all.pem"; fi
 if [ -s "$SRC/pubkey.pem" ] && grep -q 'BEGIN CERTIFICATE' "$SRC/pubkey.pem"; then
  printf '\n' >> "$tmpd/all.pem"
  cat "$SRC/pubkey.pem" >> "$tmpd/all.pem"
 fi
 awk -v d="$tmpd" 'BEGIN{n=0; open=0} /BEGIN CERTIFICATE/{n++; fn=sprintf("%s/%04d.pem",d,n); open=1} open{print > (fn)} /END CERTIFICATE/{close(fn); open=0}' "$tmpd/all.pem"
 leaf=""
 found=0
 for c in "$tmpd"/[0-9][0-9][0-9][0-9].pem; do
  [ -f "$c" ] || continue
  found=1
  openssl x509 -in "$c" -noout >/dev/null 2>&1 || { rm -rf "$tmpd"; echo "bundle"; exit 1; }
  if [ -z "$leaf" ] && [ "$(pub_of_cert "$c")" = "$A" ]; then leaf="$c"; fi
 done
 [ "$found" = 1 ] || { rm -rf "$tmpd"; echo "cert"; exit 1; }
 [ -n "$leaf" ] || { rm -rf "$tmpd"; echo "match"; exit 1; }
 leaf_fp="$(openssl x509 -in "$leaf" -noout -fingerprint -sha256 2>/dev/null || true)"
 FULL="$(mktemp)"
 cat "$leaf" > "$FULL"
 for c in "$tmpd"/[0-9][0-9][0-9][0-9].pem; do
  [ -f "$c" ] || continue
  fp="$(openssl x509 -in "$c" -noout -fingerprint -sha256 2>/dev/null || true)"
  [ -n "$leaf_fp" ] && [ "$fp" = "$leaf_fp" ] && continue
  cat "$c" >> "$FULL"
 done
 rm -rf "$tmpd"
 snapshot
 prev=0
 if [ -d /etc/didar/ssl ]; then rm -rf /etc/didar/ssl-prev; cp -a /etc/didar/ssl /etc/didar/ssl-prev; prev=1; fi
 install -d -o root -g www-data -m 750 /etc/didar/ssl
 install -m 640 -o root -g www-data "$FULL" /etc/didar/ssl/fullchain.pem
 install -m 640 -o root -g www-data "$SRC/privkey.pem" /etc/didar/ssl/privkey.pem
 rm -f "$FULL"
 if grep -Eq '^[[:space:]]*ssl_certificate[[:space:]]' "$SITE"; then
  point_nginx /etc/didar/ssl/fullchain.pem /etc/didar/ssl/privkey.pem
 else
  write_https_conf /etc/didar/ssl/fullchain.pem /etc/didar/ssl/privkey.pem
 fi
 if ! nginx -t >/dev/null 2>&1; then
  restore_site
  rm -rf /etc/didar/ssl
  if [ "$prev" = 1 ]; then mv /etc/didar/ssl-prev /etc/didar/ssl; fi
  echo "nginx"
  exit 1
 fi
 rm -rf /etc/didar/ssl-prev
 rm -f "$SITE.didar-bak"
 printf 'manual\n' > "$MODEFILE"
 chmod 644 "$MODEFILE"
 ensure_turn_tls
 apply_turn /etc/didar/ssl/fullchain.pem /etc/didar/ssl/privkey.pem
 write_hook
 restart_web
 exit 0
fi

if [ "$MODE" = "auto" ]; then
 c=""
 k=""
 if [ -f "$AUTO" ]; then
  c="$(sed -n 's/^cert=//p' "$AUTO" | head -1 | tr -d '\r')"
  k="$(sed -n 's/^key=//p' "$AUTO" | head -1 | tr -d '\r')"
 fi
 if [ ! -f "${c:-}" ] || [ ! -f "${k:-}" ]; then
  DOM=""
  if [ -f /etc/didar/domain ]; then DOM="$(tr -d '\r\n' < /etc/didar/domain)"; fi
  c="/etc/letsencrypt/live/${DOM}/fullchain.pem"
  k="/etc/letsencrypt/live/${DOM}/privkey.pem"
 fi
 if [ ! -f "$c" ] || [ ! -f "$k" ]; then echo "keep"; exit 2; fi
 openssl x509 -in "$c" -noout >/dev/null 2>&1 || { echo "keep"; exit 2; }
 openssl pkey -in "$k" -noout >/dev/null 2>&1 || { echo "keep"; exit 2; }
 point_nginx "$c" "$k"
 if ! nginx -t >/dev/null 2>&1; then restore_site; echo "nginx"; exit 1; fi
 rm -f "$SITE.didar-bak"
 printf 'auto\n' > "$MODEFILE"
 chmod 644 "$MODEFILE"
 ensure_turn_tls
 apply_turn "$c" "$k"
 case "$c" in
  /etc/didar/ssl/*) ;;
  *) rm -f /etc/didar/ssl/fullchain.pem /etc/didar/ssl/privkey.pem; rmdir /etc/didar/ssl 2>/dev/null || true;;
 esac
 write_hook
 restart_web
 exit 0
fi
echo "mode"
exit 1
