#!/usr/bin/env bash
#
# vpn-setup — свой VPN на чистом сервере одной командой.
#
#   Hysteria2 (UDP 443) + VLESS XHTTP и VLESS Vision (REALITY, TCP 443) на Xray,
#   сайт-прикрытие с настоящим сертификатом, подписка для Happ с маршрутизацией
#   «российское — напрямую», полоска расхода трафика, страница «Добавить в Happ»,
#   файрвол, fail2ban, SSH на высоком порту, автообновления.
#
# Запуск под root на Ubuntu 22.04/24.04 или Debian 12/13:
#   curl -fsSL https://raw.githubusercontent.com/reme3/vpn-setup/main/install.sh | sudo bash
#
# Необязательные настройки (пример):
#   curl -fsSL .../install.sh | sudo VPN_NAME="Petya" TRAFFIC_LIMIT_GB=2000 bash
#
#   VPN_NAME          имя в Happ                                  (по умолчанию VPN)
#   TRAFFIC_LIMIT_GB  месячный лимит трафика тарифа, ГБ; 0 — безлимит (1000)
#   TRAFFIC_COUNT     out — считать исходящий трафик, both — весь  (out)
#   STOP_AT_LIMIT     1 — выключать VPN до конца месяца при исчерпании лимита (0)
#   SSH_PORT          random — случайный высокий, keep — не менять, или номер (random)
#   DOMAIN            свой домен, A-запись которого уже указывает на сервер (сам найдёт имя)
#   TZ_NAME           часовой пояс сервера                         (Europe/Moscow)
#   XRAY_VERSION      версия Xray: проверенная или latest          (v26.10.31)
#   ROTATE_KEYS=1     разово сменить все ключи и ссылки (если ссылка утекла)
#
# Повторный запуск безопасен: ключи, ссылки и выбранные настройки сохраняются.
# Показать ссылки ещё раз: sudo vpn-info

set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
REPO_RAW="https://raw.githubusercontent.com/reme3/vpn-setup/main/install.sh"
XRAY_INSTALLER="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"
DEFAULT_XRAY_VERSION="v26.10.31"

ETC=/etc/vpn
LIB=/usr/local/lib/vpn
WWW=/var/www/vpn
SUBDIR=/var/www/vpn-sub
CERTBOT_VENV=/opt/vpn/certbot
CERTBOT="$CERTBOT_VENV/bin/certbot"
XRAY_DIR=/usr/local/etc/xray
LOG=/var/log/vpn-setup.log

STEP="подготовка"
TOTAL_STEPS=10
STEP_N=0

# ─────────────────────────── вывод ───────────────────────────
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'; else B=; G=; Y=; R=; C=; N=; fi
step() { STEP_N=$((STEP_N + 1)); STEP="$1"; printf '\n%s[%d/%d] %s%s\n' "$B$C" "$STEP_N" "$TOTAL_STEPS" "$1" "$N"; }
info() { printf '      %s\n' "$*"; }
ok()   { printf '      %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '      %s! %s%s\n' "$Y" "$*" "$N"; }
die()  {
  printf '\n%s✗ Ошибка на шаге «%s»: %s%s\n' "$R$B" "$STEP" "$*" "$N"
  printf '  Полный журнал: %s\n  Последние строки: tail -n 60 %s\n' "$LOG" "$LOG"
  printf '  Скрипт можно спокойно запустить ещё раз — он продолжит с того же места.\n'
  exit 1
}
on_err() {
  local code=$? line=${1:-?}
  printf '\n%s✗ Непредвиденная ошибка на шаге «%s» (строка %s, код %s).%s\n' "$R$B" "$STEP" "$line" "$code" "$N"
  printf '  Полный журнал: %s\n  Последние строки: tail -n 60 %s\n' "$LOG" "$LOG"
  printf '  Скрипт можно спокойно запустить ещё раз — он продолжит с того же места.\n'
  exit "$code"
}

# ───────────────────────── утилиты ──────────────────────────
apt_get() {
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 \
    apt-get -y -q -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}
env_get() { # env_get FILE KEY
  [[ -f "$1" ]] || return 0
  sed -n "s/^$2=//p" "$1" | tail -n1 | sed -e "s/^'//" -e "s/'$//"
}
env_set() { # env_set FILE KEY VALUE — значение без одинарных кавычек
  local f=$1 k=$2 v=$3
  touch "$f"; chmod 600 "$f"
  { grep -v "^$k=" "$f" || true; printf "%s='%s'\n" "$k" "$v"; } >"$f.tmp"
  chmod 600 "$f.tmp"; mv -f "$f.tmp" "$f"
}
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
resolve_a() { # публичный DNS, а не /etc/hosts
  { dig +short +time=3 +tries=2 A "$1" @1.1.1.1 2>/dev/null; dig +short +time=3 +tries=2 A "$1" @8.8.8.8 2>/dev/null; } | grep -E '^[0-9.]+$' | sort -u
}
# в конвейерах не используем head/grep -q/exit в awk: с pipefail ранний выход даёт SIGPIPE (код 141)
ptr_of() { dig +short +time=3 +tries=2 -x "$1" @1.1.1.1 2>/dev/null | awk 'NR==1{sub(/\.$/,""); print}'; }
port_in_use() { [[ -n "$(ss -Htln "sport = :$1" 2>/dev/null)" ]]; }

# ───────────────────────── шаги ─────────────────────────────
preflight() {
  STEP="проверка сервера"
  [[ $EUID -eq 0 ]] || die "нужны права root. Запустите так: curl -fsSL $REPO_RAW | sudo bash"
  [[ -r /etc/os-release ]] || die "не удалось определить систему"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:22.04|ubuntu:24.04|ubuntu:26.04|debian:12|debian:13) ;;
    *) die "поддерживаются Ubuntu 22.04/24.04 и Debian 12/13, а здесь ${PRETTY_NAME:-неизвестно}. Переустановите сервер на Ubuntu 24.04 в панели хостера." ;;
  esac
  case "$(uname -m)" in x86_64|aarch64) ;; *) die "неподдерживаемый процессор $(uname -m)";; esac
  command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || die "нужен systemd (обычный VPS, не контейнер OpenVZ/LXC без systemd)"
  local mem; mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  (( mem >= 450 )) || die "слишком мало памяти: ${mem} МБ, нужно от 512 МБ"
  if [[ -f "$ETC/state.env" ]]; then info "Найдена прежняя установка — обновляю, ключи и ссылки сохранятся."; fi
  ok "${PRETTY_NAME}, $(uname -m), ${mem} МБ памяти"
}

load_settings() {
  mkdir -p "$ETC"; chmod 700 "$ETC"
  local f="$ETC/settings.env" k v
  declare -gA DEF=([VPN_NAME]=VPN [TRAFFIC_LIMIT_GB]=1000 [TRAFFIC_COUNT]=out [STOP_AT_LIMIT]=0
                   [SSH_PORT]=random [DOMAIN]="" [TZ_NAME]=Europe/Moscow [XRAY_VERSION]="$DEFAULT_XRAY_VERSION"
                   [SUB_UPDATE_HOURS]=1)
  for k in "${!DEF[@]}"; do
    if [[ -n "${!k+x}" ]]; then v=${!k}                       # из окружения
    elif grep -q "^$k=" "$f" 2>/dev/null; then v=$(env_get "$f" "$k")  # из прошлой установки
    else v=${DEF[$k]}; fi
    v=${v//\'/}; v=${v//$'\n'/}
    printf -v "$k" '%s' "$v"
    env_set "$f" "$k" "$v"
  done
  [[ "$TRAFFIC_LIMIT_GB" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "TRAFFIC_LIMIT_GB должен быть числом, например 1000"
  [[ "$TRAFFIC_COUNT" == out || "$TRAFFIC_COUNT" == both ]] || die "TRAFFIC_COUNT: out или both"
  [[ "$STOP_AT_LIMIT" == 0 || "$STOP_AT_LIMIT" == 1 ]] || die "STOP_AT_LIMIT: 0 или 1"
  [[ "$SUB_UPDATE_HOURS" =~ ^[0-9]+$ ]] || die "SUB_UPDATE_HOURS должен быть целым числом часов"
  [[ -z "$DOMAIN" || "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "DOMAIN выглядит неправильно: $DOMAIN"
}

install_packages() {
  step "Обновляю систему и ставлю пакеты (2–5 минут)"
  apt_get update >/dev/null || die "apt-get update не прошёл — проверьте интернет на сервере"
  apt_get upgrade >/dev/null || warn "часть обновлений не встала, продолжаю"
  apt_get install curl ca-certificates openssl unzip gzip jq python3 python3-venv \
    nginx ufw fail2ban python3-systemd vnstat qrencode unattended-upgrades \
    bind9-dnsutils iproute2 logrotate tzdata >/dev/null || die "не удалось установить пакеты"
  ok "пакеты установлены"
}

base_system() {
  step "Базовые настройки системы"
  # своп — чтобы маленький сервер не падал по памяти
  if [[ -z "$(swapon --show --noheadings 2>/dev/null)" ]] && (( $(awk '/MemTotal/{print $2}' /proc/meminfo) < 3500000 )); then
    if [[ ! -f /swapfile ]]; then
      { fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none; } && chmod 600 /swapfile && mkswap /swapfile >/dev/null
    fi
    if swapon /swapfile 2>/dev/null; then
      grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
      ok "своп 1 ГБ"
    else warn "своп включить не удалось (на этом хостинге, видимо, нельзя) — не страшно"; fi
  fi
  printf 'vm.swappiness=10\n' >/etc/sysctl.d/90-vpn-swap.conf
  # BBR ускоряет TCP на плохих каналах
  modprobe tcp_bbr 2>/dev/null || true
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >/etc/sysctl.d/90-vpn-bbr.conf
  fi
  sysctl -q --system >/dev/null 2>&1 || true
  # часовой пояс — чтобы ночные перезагрузки были ночью
  if [[ -e "/usr/share/zoneinfo/$TZ_NAME" ]]; then
    ln -sf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime; echo "$TZ_NAME" >/etc/timezone   # без timedatectl: часы не трогаем
    ok "часовой пояс $TZ_NAME"
  else warn "часовой пояс $TZ_NAME не найден, оставляю $(cat /etc/timezone 2>/dev/null || echo текущий)"; fi
  # автообновления безопасности с перезагрузкой в 04:30
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  cat >/etc/apt/apt.conf.d/52vpn-auto-reboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  ok "автообновления безопасности, перезагрузка при необходимости в 04:30"
}

detect_network() {
  step "Определяю адрес сервера"
  local ip="" u
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip https://checkip.amazonaws.com; do
    ip=$(curl -4 -fsS --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]') || true
    is_ipv4 "$ip" && break; ip=""
  done
  [[ -n "${PUBLIC_IP_OVERRIDE:-}" ]] && ip=$PUBLIC_IP_OVERRIDE
  is_ipv4 "$ip" || die "не удалось узнать внешний IPv4 сервера (нет интернета или нет IPv4)"
  PUBLIC_IP=$ip
  IFACE=$(ip -4 route show default 2>/dev/null | awk '!f{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); f=1; break}}')
  [[ -n "$IFACE" ]] || IFACE=$(ip -o link show | awk -F': ' '!f && $2!="lo"{print $2; f=1}')
  if [[ -e /proc/net/if_inet6 ]] && [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" == 0 ]]; then HAS_V6=1; else HAS_V6=0; fi
  FLAG=$(env_get "$ETC/state.env" FLAG)
  if [[ -z "$FLAG" ]]; then
    local cc; cc=$(curl -fsS --max-time 6 "https://ipinfo.io/$PUBLIC_IP/country" 2>/dev/null | tr -dc 'A-Z' | head -c2) || true
    if [[ ${#cc} == 2 ]]; then FLAG=$(python3 -c "import sys;print(''.join(chr(0x1F1E6+ord(c)-65) for c in sys.argv[1]))" "$cc"); else FLAG="🌐"; fi
  fi
  env_set "$ETC/state.env" PUBLIC_IP "$PUBLIC_IP"
  env_set "$ETC/state.env" IFACE "$IFACE"
  env_set "$ETC/state.env" HAS_V6 "$HAS_V6"
  env_set "$ETC/state.env" FLAG "$FLAG"
  ok "IP $PUBLIC_IP $FLAG, сеть $IFACE, IPv6: $([[ $HAS_V6 == 1 ]] && echo есть || echo нет)"
}

setup_nginx_http() {
  step "Сайт-прикрытие (nginx)"
  systemctl disable --now apache2 >/dev/null 2>&1 || true
  mkdir -p "$WWW" "$SUBDIR"
  if [[ ! -f "$WWW/index.html" ]]; then
    local titles=("Field notes" "Workbench" "Sketchbook" "Small tools" "Notebook" "Scratchpad") t
    t=${titles[RANDOM % ${#titles[@]}]}
    cat >"$WWW/index.html" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$t</title>
<style>body{font:16px/1.6 system-ui,sans-serif;max-width:40rem;margin:4rem auto;padding:0 1rem;color:#222}h1{font-weight:600}footer{margin-top:3rem;color:#888;font-size:.85rem}</style>
</head><body><h1>$t</h1><p>Personal notes and small experiments. Nothing to see here yet.</p><footer>&copy; $(date +%Y)</footer></body></html>
EOF
  fi
  chown -R www-data:www-data "$WWW"; chmod 755 "$WWW"
  chown root:www-data "$SUBDIR"; chmod 750 "$SUBDIR"
  sed -i 's/^\s*#\s*server_tokens off;/\tserver_tokens off;/' /etc/nginx/nginx.conf
  rm -f /etc/nginx/sites-enabled/default
  local v6listen=""; [[ $HAS_V6 == 1 ]] && v6listen="    listen [::]:80 default_server;"
  cat >/etc/nginx/sites-available/vpn <<EOF
# vpn-setup: порт 80 — проверка Let's Encrypt и переадресация на https
server {
    listen 80 default_server;
$v6listen
    server_name _;
    access_log off;
    location ^~ /.well-known/acme-challenge/ { root $WWW; default_type text/plain; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
  # TLS-часть (127.0.0.1:8443) допишется после сертификата; на повторном запуске она уже есть
  [[ -f /etc/nginx/sites-available/vpn-tls ]] && [[ -f /etc/letsencrypt/live/vpn/fullchain.pem ]] && ln -sf /etc/nginx/sites-available/vpn-tls /etc/nginx/sites-enabled/vpn-tls
  ln -sf /etc/nginx/sites-available/vpn /etc/nginx/sites-enabled/vpn
  nginx -t >/dev/null 2>&1 || { nginx -t; die "ошибка в настройках nginx"; }
  systemctl enable nginx >/dev/null 2>&1; systemctl restart nginx || die "nginx не запустился"
  # порт 80 должен быть открыт для проверки Let's Encrypt
  if ufw status 2>/dev/null | grep "Status: active" >/dev/null; then ufw allow 80/tcp >/dev/null; fi
  ok "nginx отвечает на порту 80"
}

install_certbot() {
  if [[ -x "$CERTBOT" ]] && "$CERTBOT_VENV/bin/python" -c 'import sys,certbot; sys.exit(0 if tuple(map(int, certbot.__version__.split(".")[:2])) >= (5, 4) else 1)' 2>/dev/null; then
    return 0
  fi
  info "ставлю certbot (около минуты)…"
  rm -rf "$CERTBOT_VENV"; mkdir -p "$(dirname "$CERTBOT_VENV")"
  python3 -m venv "$CERTBOT_VENV" || die "не удалось создать окружение Python для certbot"
  "$CERTBOT_VENV/bin/pip" install -q --disable-pip-version-check 'certbot>=5.4,<6' >/dev/null 2>&1 || die "не удалось установить certbot из PyPI"
}

cert_matches() { # cert_matches dns|ip NAME — подходит ли уже выпущенный сертификат
  local pem=/etc/letsencrypt/live/vpn/cert.pem
  [[ -f "$pem" ]] || return 1
  openssl x509 -in "$pem" -noout -checkend 86400 >/dev/null 2>&1 || return 1
  local san; san=$(openssl x509 -in "$pem" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' | sed 's/^ *//')
  if [[ $1 == dns ]]; then grep -qx "DNS:$2" <<<"$san"; else grep -qx "IP Address:$2" <<<"$san"; fi
}

issue_cert() { # issue_cert dns|ip NAME
  local kind=$1 name=$2 args
  cert_matches "$kind" "$name" && return 0
  [[ -d /etc/letsencrypt/live/vpn ]] && "$CERTBOT" delete --cert-name vpn -n >/dev/null 2>&1 || true
  args=(certonly --webroot -w "$WWW" --cert-name vpn -n --agree-tos --register-unsafely-without-email --key-type ecdsa)
  if [[ $kind == dns ]]; then args+=(-d "$name"); else args+=(--ip-address "$name" --preferred-profile shortlived); fi
  [[ -n "${VPN_TEST_ACME_SERVER:-}" ]] && args+=(--server "$VPN_TEST_ACME_SERVER")   # только для автотестов
  "$CERTBOT" "${args[@]}" >>"$LOG" 2>&1
}

test_selfsigned_cert() { # только для автотестов: самоподписанный сертификат вместо Let's Encrypt
  local d=/etc/letsencrypt/live/vpn
  mkdir -p "$d"
  [[ -f "$d/fullchain.pem" ]] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
    -subj "/CN=$PUBLIC_IP" -addext "subjectAltName=IP:$PUBLIC_IP,IP:127.0.0.1" -addext "basicConstraints=critical,CA:TRUE" \
    -keyout "$d/privkey.pem" -out "$d/fullchain.pem" 2>/dev/null
  cp "$d/fullchain.pem" "$d/cert.pem"
  CERT_MODE=ip; CERT_NAME=$PUBLIC_IP; SNI="$(tr . - <<<"$PUBLIC_IP").sslip.io"
}

obtain_cert() {
  if [[ -n "${VPN_TEST_SELFSIGNED:-}" ]]; then test_selfsigned_cert; else obtain_le_cert; fi
  write_cert_hooks
  env_set "$ETC/state.env" CERT_MODE "$CERT_MODE"
  env_set "$ETC/state.env" CERT_NAME "$CERT_NAME"
  env_set "$ETC/state.env" SNI "$SNI"
  if [[ $CERT_MODE == dns ]]; then ok "сертификат Let's Encrypt для $CERT_NAME"
  else ok "сертификат Let's Encrypt для IP $CERT_NAME (короткий, продлевается сам каждые ~3 дня)"; fi
}

obtain_le_cert() {
  install_certbot
  local cands=() c seen=" "
  if [[ -n "$DOMAIN" ]]; then cands=("$DOMAIN")
  else
    for c in "$(hostname -f 2>/dev/null || true)" "$(ptr_of "$PUBLIC_IP")"; do
      c=${c,,}; c=${c%.}
      [[ "$c" == *.* && "$c" != localhost* && "$seen" != *" $c "* ]] || continue
      seen+="$c "
      if resolve_a "$c" | grep -x "$PUBLIC_IP" >/dev/null; then cands+=("$c"); fi
    done
  fi
  CERT_MODE=""; CERT_NAME=""; SNI=""
  for c in "${cands[@]}"; do
    info "пробую сертификат для имени $c"
    if issue_cert dns "$c"; then CERT_MODE=dns; CERT_NAME=$c; SNI=$c; break; fi
    warn "для $c не вышло (подробности в $LOG)"
  done
  if [[ -z "$CERT_MODE" ]]; then
    [[ -n "$DOMAIN" ]] && warn "домен $DOMAIN не подошёл — проверьте, что его A-запись указывает на $PUBLIC_IP. Пока беру сертификат на IP."
    info "беру сертификат на IP-адрес $PUBLIC_IP"
    issue_cert ip "$PUBLIC_IP" || die "Let's Encrypt не выдал сертификат. Чаще всего порт 80 закрыт файрволом в панели хостера — откройте входящие 80/tcp, 443/tcp и 443/udp и запустите скрипт ещё раз."
    CERT_MODE=ip; CERT_NAME=$PUBLIC_IP
    SNI=${cands[0]:-$(tr . - <<<"$PUBLIC_IP").sslip.io}
  fi
}

write_cert_hooks() {
  # копия для Xray (Hysteria2) и перезапуск после каждого продления
  install -d -o root -g xray -m 750 "$XRAY_DIR/tls"
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/vpn.sh <<EOF
#!/bin/sh
# vpn-setup: новый сертификат — в nginx и Xray
install -o root -g xray -m 640 /etc/letsencrypt/live/vpn/fullchain.pem $XRAY_DIR/tls/fullchain.pem
install -o root -g xray -m 640 /etc/letsencrypt/live/vpn/privkey.pem $XRAY_DIR/tls/privkey.pem
systemctl reload nginx
systemctl try-restart xray
EOF
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/vpn.sh
  cat >/etc/systemd/system/vpn-certbot.service <<EOF
[Unit]
Description=vpn-setup: renew Let's Encrypt certificate
After=network-online.target
[Service]
Type=oneshot
ExecStart=$CERTBOT renew -q
EOF
  cat >/etc/systemd/system/vpn-certbot.timer <<'EOF'
[Unit]
Description=vpn-setup: renew certificate daily at night
[Timer]
OnCalendar=*-*-* 04:10:00
RandomizedDelaySec=20min
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  if [[ -x "$CERTBOT" ]]; then systemctl enable --now vpn-certbot.timer >/dev/null 2>&1; fi
}

setup_nginx_tls() {
  local SUBSEC; SUBSEC=$(env_get "$ETC/secrets.env" SUBSEC)
  local sname=$CERT_NAME; [[ $CERT_MODE == ip ]] && sname=_
  cat >/etc/nginx/sites-available/vpn-tls <<EOF
# vpn-setup: сайт-прикрытие за Xray (REALITY пересылает сюда всех посторонних)
server {
    listen 127.0.0.1:8443 ssl http2 default_server;
    server_name $sname;
    access_log off;
    ssl_certificate /etc/letsencrypt/live/vpn/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/vpn/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    add_header Strict-Transport-Security "max-age=31536000" always;
    root $WWW;
    index index.html;
    location = /$SUBSEC/sub {
        default_type text/plain;
        charset utf-8;
        add_header Cache-Control "no-store" always;
        alias $SUBDIR/sub.txt;
    }
    location = /$SUBSEC/add {
        default_type text/html;
        charset utf-8;
        add_header Cache-Control "no-store" always;
        add_header Referrer-Policy "no-referrer" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        alias $SUBDIR/add.html;
    }
    location / { try_files \$uri \$uri/ =404; }
}
EOF
  ln -sf /etc/nginx/sites-available/vpn-tls /etc/nginx/sites-enabled/vpn-tls
  nginx -t >/dev/null 2>&1 || { nginx -t; die "ошибка в настройках nginx (TLS)"; }
  systemctl reload nginx
}

install_xray() {
  step "Устанавливаю Xray ($XRAY_VERSION)"
  local tmp; tmp=$(mktemp)
  curl -fsSL --max-time 60 -o "$tmp" "$XRAY_INSTALLER" || die "не удалось скачать установщик Xray с GitHub"
  local args=(install --logrotate 00:00:00)
  [[ "$XRAY_VERSION" != latest ]] && args+=(--version "$XRAY_VERSION")
  [[ -n "${XRAY_INSTALL_PROXY:-}" ]] && args+=(--proxy "$XRAY_INSTALL_PROXY")
  if [[ -x /usr/local/bin/xray ]] && [[ "$(/usr/local/bin/xray version 2>/dev/null | awk 'NR==1{print $2}')" == "${XRAY_VERSION#v}" ]]; then
    ok "Xray ${XRAY_VERSION#v} уже установлен"
  else
    bash "$tmp" "${args[@]}" >>"$LOG" 2>&1 || die "установщик Xray завершился с ошибкой"
    ok "$(/usr/local/bin/xray version | awk 'NR==1{print $1, $2}')"
  fi
  rm -f "$tmp"
  id xray >/dev/null 2>&1 || die "после установки нет пользователя xray"
}

gen_secrets() {
  local f="$ETC/secrets.env" X=/usr/local/bin/xray kp
  if [[ "${ROTATE_KEYS:-0}" == 1 && -f "$f" ]]; then
    mv -f "$f" "$f.old"; info "ROTATE_KEYS=1: все ключи и ссылки будут новыми — подписку в Happ нужно добавить заново"
  fi
  if [[ -z "$(env_get "$f" UUID)" ]]; then
    kp=$($X x25519)
    env_set "$f" UUID "$($X uuid)"
    env_set "$f" REALITY_PRIV "$(awk -F': ' '/^PrivateKey/{print $2}' <<<"$kp")"
    env_set "$f" REALITY_PUB "$(awk -F': ' '!f && /Password|Public ?[Kk]ey/{print $2; f=1}' <<<"$kp")"
    env_set "$f" SID_V "$(openssl rand -hex 8)"
    env_set "$f" SID_X "$(openssl rand -hex 8)"
    env_set "$f" XPATH "/$(openssl rand -hex 6)"
    env_set "$f" HY2_AUTH "$(openssl rand -hex 16)"
    env_set "$f" SUBSEC "$(openssl rand -hex 16)"
  fi
  local priv pub; priv=$(env_get "$f" REALITY_PRIV); pub=$(env_get "$f" REALITY_PUB)
  [[ -n "$priv" && -n "$pub" ]] || die "не удалось сгенерировать ключи REALITY"
  [[ "$($X x25519 -i "$priv" | awk -F': ' '!f && /Password|Public ?[Kk]ey/{print $2; f=1}')" == "$pub" ]] || die "ключи REALITY не сходятся"
}

write_xray_config() {
  step "Настраиваю VPN: Hysteria2, XHTTP, Vision"
  install -o root -g xray -m 640 /etc/letsencrypt/live/vpn/fullchain.pem "$XRAY_DIR/tls/fullchain.pem"
  install -o root -g xray -m 640 /etc/letsencrypt/live/vpn/privkey.pem "$XRAY_DIR/tls/privkey.pem"
  python3 "$LIB/gen.py" xray-config >"$XRAY_DIR/config.new.json"
  chown root:xray "$XRAY_DIR/config.new.json"; chmod 640 "$XRAY_DIR/config.new.json"
  if ! runuser -u xray -- /usr/local/bin/xray run -test -c "$XRAY_DIR/config.new.json" >>"$LOG" 2>&1; then
    die "Xray не принял настройки (подробности в $LOG)"
  fi
  mv -f "$XRAY_DIR/config.new.json" "$XRAY_DIR/config.json"
  setup_nginx_tls
  local holder; holder=$(ss -Htlnp 'sport = :443' 2>/dev/null | grep -v '"xray"' || true)
  if [[ -n "$holder" ]]; then
    die "порт 443 занят другой программой: $(sed -E 's/.*users:\(\("([^"]+)".*/\1/' <<<"$holder" | sort -u | tr '\n' ' ')— похоже, сервер ставили с готовым веб-сервером. Переустановите его в панели хостера с чистым образом Ubuntu 24.04."
  fi
  systemctl enable xray >/dev/null 2>&1
  systemctl restart xray
  sleep 2
  systemctl is-active --quiet xray || { journalctl -u xray -n 20 --no-pager >>"$LOG"; die "Xray не запустился (подробности в $LOG)"; }
  ok "Xray слушает 443/tcp (VLESS REALITY: Vision и XHTTP) и 443/udp (Hysteria2)"
  # ежемесячное обновление баз «российское/нероссийское» на сервере, с откатом при ошибке
  cat >"$LIB/update-geodata.sh" <<EOF
#!/bin/bash
# vpn-setup: обновить geoip/geosite для Xray; если Xray их не примет — вернуть старые
set -u
D=/usr/local/share/xray; B=\$(mktemp -d)
cp -a "\$D"/geoip.dat "\$D"/geosite.dat "\$B"/ 2>/dev/null
T=\$(mktemp); curl -fsSL --max-time 60 -o "\$T" "$XRAY_INSTALLER" && bash "\$T" update-geodata >/dev/null 2>&1
rm -f "\$T"
if ! runuser -u xray -- /usr/local/bin/xray run -test -c $XRAY_DIR/config.json >/dev/null 2>&1; then
  cp -a "\$B"/geoip.dat "\$B"/geosite.dat "\$D"/
fi
rm -rf "\$B"
systemctl try-restart xray
EOF
  chmod 755 "$LIB/update-geodata.sh"
  cat >/etc/systemd/system/vpn-geodata.service <<EOF
[Unit]
Description=vpn-setup: update Xray geodata
After=network-online.target
[Service]
Type=oneshot
ExecStart=$LIB/update-geodata.sh
EOF
  cat >/etc/systemd/system/vpn-geodata.timer <<'EOF'
[Unit]
Description=vpn-setup: update Xray geodata monthly
[Timer]
OnCalendar=*-*-03 04:40:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload; systemctl enable --now vpn-geodata.timer >/dev/null 2>&1
}

setup_subscription() {
  step "Подписка для Happ и полоска трафика"
  # счётчик трафика: vnStat по UTC-месяцам; трафик с момента загрузки сервера засчитываем, если загрузка была в этом месяце
  sed -i -E "s/^;?\s*Interface .*/Interface \"$IFACE\"/; s/^;?\s*UseUTC .*/UseUTC 1/" /etc/vnstat.conf
  grep -q '^UseUTC ' /etc/vnstat.conf || echo 'UseUTC 1' >>/etc/vnstat.conf
  systemctl enable vnstat >/dev/null 2>&1; systemctl restart vnstat; sleep 1
  vnstat --add -i "$IFACE" >/dev/null 2>&1 || true
  systemctl restart vnstat
  if [[ ! -f "$ETC/traffic-seed.env" ]]; then
    # чистый старт счётчика + засчитать трафик с момента загрузки (если загрузка была в этом месяце)
    local boot_month now_month
    systemctl stop vnstat; rm -f /var/lib/vnstat/vnstat.db
    boot_month=$(date -u -d "$(uptime -s)" +%Y-%m 2>/dev/null || echo none); now_month=$(date -u +%Y-%m)
    if [[ "$boot_month" == "$now_month" ]]; then
      env_set "$ETC/traffic-seed.env" MONTH "$now_month"
      env_set "$ETC/traffic-seed.env" TX "$(cat "/sys/class/net/$IFACE/statistics/tx_bytes" 2>/dev/null || echo 0)"
      env_set "$ETC/traffic-seed.env" RX "$(cat "/sys/class/net/$IFACE/statistics/rx_bytes" 2>/dev/null || echo 0)"
    else env_set "$ETC/traffic-seed.env" MONTH none; fi
    systemctl start vnstat; sleep 1; vnstat --add -i "$IFACE" >/dev/null 2>&1 || true; systemctl restart vnstat
  fi
  python3 "$LIB/gen.py" links || die "не удалось собрать подписку"
  cat >/etc/systemd/system/vpn-sub-update.service <<EOF
[Unit]
Description=vpn-setup: refresh Happ subscription (traffic bar)
After=vnstat.service
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 $LIB/gen.py update
EOF
  cat >/etc/systemd/system/vpn-sub-update.timer <<'EOF'
[Unit]
Description=vpn-setup: refresh Happ subscription every 5 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload; systemctl enable --now vpn-sub-update.timer >/dev/null 2>&1
  python3 "$LIB/gen.py" update || die "не удалось обновить подписку"
  local limit_txt="без лимита"; [[ "$TRAFFIC_LIMIT_GB" != 0 ]] && limit_txt="лимит $TRAFFIC_LIMIT_GB ГБ/мес ($([[ $TRAFFIC_COUNT == out ]] && echo исходящий || echo весь) трафик)"
  ok "подписка готова, полоска трафика: $limit_txt"
  [[ "$STOP_AT_LIMIT" == 1 ]] && ok "при исчерпании лимита VPN выключится до 1-го числа"
  return 0
}

ssh_unit_restart() {
  systemctl daemon-reload
  if systemctl is-enabled ssh.socket >/dev/null 2>&1 || systemctl is-active ssh.socket >/dev/null 2>&1; then
    systemctl restart ssh.socket
    systemctl is-active --quiet ssh.service && systemctl restart ssh.service || true
  elif systemctl list-unit-files ssh.service >/dev/null 2>&1; then systemctl restart ssh.service
  else systemctl restart sshd.service; fi
}

setup_firewall_ssh() {
  step "Файрвол, SSH и fail2ban"
  local cur port key_user home has_keys=0 conf=/etc/ssh/sshd_config.d/01-vpn.conf
  if ! command -v sshd >/dev/null; then
    warn "SSH-сервер не найден — настраиваю только файрвол"
    ufw --force reset >/dev/null; ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
    ufw allow 443/tcp >/dev/null; ufw allow 443/udp >/dev/null; ufw allow 80/tcp >/dev/null; ufw --force enable >/dev/null
    SSH_PORT_FINAL="нет"; return 0
  fi
  mkdir -p /run/sshd
  cur=$(sshd -T 2>/dev/null | awk '!f && /^port /{print $2; f=1}') || true; cur=${cur:-22}
  case "$SSH_PORT" in
    keep) port=$cur ;;
    random)
      port=$(env_get "$ETC/state.env" SSH_PORT_CHOSEN)
      if [[ -z "$port" ]]; then
        if (( cur >= 1024 )); then port=$cur
        else
          while :; do port=$((40000 + RANDOM % 20000)); port_in_use "$port" || break; done
        fi
      fi ;;
    *) [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "SSH_PORT должен быть числом 1–65535, keep или random"
       port=$SSH_PORT ;;
  esac
  [[ $port == 80 || $port == 443 || $port == 8443 ]] && die "SSH_PORT не может быть $port — он занят VPN"

  # входить по паролю оставляем, если у пользователя нет ключа — иначе можно запереть себя снаружи
  key_user=${SUDO_USER:-root}; home=$(getent passwd "$key_user" | cut -d: -f6)
  if [[ -n "$home" ]] && grep -qsE '^(ssh-(ed25519|rsa)|ecdsa-sha2-|sk-ssh-ed25519|sk-ecdsa)' "$home/.ssh/authorized_keys"; then has_keys=1; fi

  # файрвол: сначала разрешить, потом включать
  if [[ $HAS_V6 == 1 ]]; then sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw; else sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw; fi
  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
  ufw allow 443/tcp comment 'vpn: xray reality' >/dev/null
  ufw allow 443/udp comment 'vpn: hysteria2' >/dev/null
  ufw allow 80/tcp comment 'vpn: letsencrypt' >/dev/null
  ufw limit "$port/tcp" comment 'ssh' >/dev/null
  [[ "$cur" != "$port" ]] && ufw allow "$cur/tcp" comment 'ssh (temporary)' >/dev/null
  ufw --force enable >/dev/null || die "ufw не включился"

  # SSH
  {
    echo "# vpn-setup"
    echo "Port $port"
    echo "MaxAuthTries 3"
    echo "LoginGraceTime 30"
    echo "X11Forwarding no"
    if [[ $has_keys == 1 ]]; then
      echo "PasswordAuthentication no"
      echo "KbdInteractiveAuthentication no"
      [[ $key_user == root ]] && echo "PermitRootLogin prohibit-password"
    fi
  } >"$conf.new"
  [[ -f "$conf" ]] && cp -a "$conf" "$conf.bak" || true
  mv -f "$conf.new" "$conf"
  grep -qiE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
    || sed -i.vpn-bak '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  if grep -qE '^\s*Port\s' /etc/ssh/sshd_config; then
    [[ -f /etc/ssh/sshd_config.vpn-bak ]] || cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.vpn-bak
    sed -i -E 's/^(\s*Port\s)/# vpn-setup: \1/' /etc/ssh/sshd_config
  fi
  if ! sshd -t 2>>"$LOG"; then
    if [[ -f "$conf.bak" ]]; then mv -f "$conf.bak" "$conf"; else rm -f "$conf"; fi
    [[ -f /etc/ssh/sshd_config.vpn-bak ]] && mv -f /etc/ssh/sshd_config.vpn-bak /etc/ssh/sshd_config
    die "sshd не принял настройки — вернул как было"
  fi
  ssh_unit_restart; sleep 2
  if port_in_use "$port"; then
    if [[ "$cur" != "$port" ]]; then ufw delete allow "$cur/tcp" >/dev/null 2>&1 || true; fi
    env_set "$ETC/state.env" SSH_PORT_CHOSEN "$port"
    if [[ "$cur" != "$port" ]]; then ok "SSH перенесён с порта $cur на $port"; else ok "SSH на порту $port"; fi
  else
    warn "SSH не поднялся на порту $port — возвращаю $cur"
    sed -i "s/^Port .*/Port $cur/" "$conf"; ssh_unit_restart; port=$cur
    env_set "$ETC/state.env" SSH_PORT_CHOSEN "$cur"
  fi
  if [[ $has_keys == 1 ]]; then ok "вход по SSH только по ключу"
  else warn "вход по SSH по паролю оставлен (ключа у $key_user нет). Пароль должен быть длинным."; fi
  SSH_PORT_FINAL=$port
  env_set "$ETC/state.env" SSH_KEY_ONLY "$has_keys"
  env_set "$ETC/state.env" SSH_USER "$key_user"

  # fail2ban: банит перебор паролей по SSH
  cat >/etc/fail2ban/jail.d/vpn.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = $port
mode = aggressive
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _SYSTEMD_UNIT=sshd.service + _COMM=sshd + _COMM=sshd-session
EOF
  systemctl enable fail2ban >/dev/null 2>&1; systemctl restart fail2ban
  sleep 2; systemctl is-active --quiet fail2ban && ok "fail2ban следит за SSH" || warn "fail2ban не запустился (VPN это не мешает)"
}

self_test() {
  step "Проверяю все три варианта подключения"
  local tmp; tmp=$(mktemp -d)
  python3 "$LIB/gen.py" selftest "$tmp" "$PUBLIC_IP" || { warn "не удалось подготовить проверку"; return 0; }
  local name port pid code exitip fails=0 target url=${SELFTEST_URL:-https://www.cloudflare.com/cdn-cgi/trace}
  local -a RESULTS=()
  for target in "$PUBLIC_IP" 127.0.0.1; do
    fails=0; RESULTS=()
    [[ $target != "$PUBLIC_IP" ]] && python3 "$LIB/gen.py" selftest "$tmp" 127.0.0.1 >/dev/null
    for name in hy2 xhttp vision; do
      port=$(cat "$tmp/$name.port")
      /usr/local/bin/xray run -c "$tmp/$name.json" >"$tmp/$name.log" 2>&1 & pid=$!
      sleep 2
      code=$(curl -sS --max-time 15 -o "$tmp/$name.out" -w '%{http_code}' -x "socks5h://127.0.0.1:$port" "$url" 2>>"$tmp/$name.log") || code=000
      exitip=$(sed -n '/^ip=/{s/^ip=//p;q}' "$tmp/$name.out" 2>/dev/null) || true
      kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
      if [[ "$code" =~ ^[23] ]]; then RESULTS+=("$name|ok|$exitip")
      else RESULTS+=("$name|fail|"); fails=$((fails + 1)); { echo "--- selftest $name via $target: HTTP $code"; cat "$tmp/$name.log"; } >>"$LOG"; fi
    done
    (( fails < 3 )) && break
  done
  rm -rf "$tmp"
  local r n s ip label
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r n s ip <<<"$r"
    case $n in hy2) label="Hysteria2";; xhttp) label="XHTTP";; *) label="Vision";; esac
    if [[ $s == ok ]]; then ok "$label работает${ip:+, выход в интернет с адреса $ip}"; else warn "$label не прошёл проверку на самом сервере (подробности в $LOG)"; fi
  done
  [[ $target == 127.0.0.1 ]] && warn "с внешнего адреса сервер сам до себя не достучался (так бывает у хостеров с NAT) — проверьте с телефона"
  return 0
}

write_tools() {
  mkdir -p "$LIB"
  cat >/usr/local/bin/vpn-info <<'EOF'
#!/bin/bash
# vpn-setup: показать ссылки, QR-код и состояние VPN
[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"
cat /etc/vpn/info.txt 2>/dev/null || { echo "VPN не установлен"; exit 1; }
ADD=$(sed -n 's/^ADD_URL=//p' /etc/vpn/state.env | tr -d "'")
[[ -n "$ADD" ]] && { echo; echo "QR-код — наведите камеру телефона:"; qrencode -t ANSIUTF8 -m 2 "$ADD"; }
echo
printf 'Службы: '; for s in xray nginx fail2ban; do printf '%s=%s ' "$s" "$(systemctl is-active $s)"; done; echo
PORT=$(sed -n 's/^SSH_PORT_CHOSEN=//p' /etc/vpn/state.env | tr -d "'"); [[ -n "$PORT" ]] && echo "SSH: порт $PORT"
python3 /usr/local/lib/vpn/gen.py usage 2>/dev/null
EOF
  chmod 755 /usr/local/bin/vpn-info
  cat >"$LIB/gen.py" <<'PYGEN'
#!/usr/bin/env python3
"""vpn-setup: конфиг Xray, подписка Happ, страница «Добавить в Happ», полоска трафика, самопроверка.

Команды: xray-config | links | update | usage | selftest DIR ADDR
"""
import base64
import datetime
import grp
import html
import json
import os
import subprocess
import sys
import time
import urllib.parse

ETC = '/etc/vpn'
SUBDIR = '/var/www/vpn-sub'
TLS = '/usr/local/etc/xray/tls'
GEO_IP = 'https://github.com/XTLS/Xray-rules-dat/releases/latest/download/geoip-lite.dat'
GEO_SITE = 'https://github.com/XTLS/Xray-rules-dat/releases/latest/download/geosite.dat'
SNIFF = {"enabled": True, "destOverride": ["http", "tls", "quic"], "routeOnly": True}


def read_env(path):
    d = {}
    try:
        with open(path, encoding='utf-8') as f:
            for line in f:
                line = line.rstrip('\n')
                if not line or line.startswith('#') or '=' not in line:
                    continue
                k, v = line.split('=', 1)
                if len(v) >= 2 and v[0] == v[-1] == "'":
                    v = v[1:-1]
                d[k] = v
    except FileNotFoundError:
        pass
    return d


def set_env(path, key, value):
    d = read_env(path)
    d[key] = value
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        for k, v in d.items():
            f.write(f"{k}='{v}'\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def load():
    c = {}
    for name in ('settings.env', 'secrets.env', 'state.env'):
        c.update(read_env(os.path.join(ETC, name)))
    return c


def write(path, data, mode=0o640, group='www-data'):
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(data)
    os.chown(tmp, 0, grp.getgrnam(group).gr_gid if group else 0)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def b64(s):
    return base64.b64encode(s.encode('utf-8')).decode()


# ───────────────────────── сервер ─────────────────────────
def xray_config(c):
    listen = '::' if c.get('HAS_V6') == '1' else '0.0.0.0'
    tls = {"alpn": ["h3"], "certificates": [{"certificateFile": f"{TLS}/fullchain.pem", "keyFile": f"{TLS}/privkey.pem"}]}
    if c.get('CERT_MODE') == 'dns':
        tls = {"serverName": c['CERT_NAME'], **tls}
    return {
        "log": {"loglevel": "warning", "access": "none", "error": "/var/log/xray/error.log", "dnsLog": False},
        "routing": {
            "domainStrategy": "IPIfNonMatch",
            "rules": [
                {"ip": ["geoip:private"], "outboundTag": "block"},
                {"protocol": ["bittorrent"], "outboundTag": "block"},
                {"network": "tcp", "port": "25", "outboundTag": "block"},
                {"domain": ["geosite:category-ru", "domain:ru", "domain:su", "domain:xn--p1ai"], "outboundTag": "block"},
                {"ip": ["geoip:ru"], "outboundTag": "block"},
            ],
        },
        "inbounds": [
            {
                "tag": "vless-reality", "listen": listen, "port": 443, "protocol": "vless",
                "settings": {
                    "clients": [{"id": c['UUID'], "flow": "xtls-rprx-vision", "email": "user@vision"}],
                    "decryption": "none",
                    "fallbacks": [{"dest": "@vpn-xhttp"}],
                },
                "streamSettings": {
                    "network": "raw", "security": "reality",
                    "realitySettings": {
                        "target": "127.0.0.1:8443", "xver": 0, "serverNames": [c['SNI']],
                        "privateKey": c['REALITY_PRIV'], "shortIds": [c['SID_V'], c['SID_X']],
                    },
                },
                "sniffing": SNIFF,
            },
            {
                "tag": "vless-xhttp", "listen": "@vpn-xhttp", "protocol": "vless",
                "settings": {"clients": [{"id": c['UUID'], "email": "user@xhttp"}], "decryption": "none"},
                "streamSettings": {"network": "xhttp", "xhttpSettings": {"path": c['XPATH']}},
                "sniffing": SNIFF,
            },
            {
                "tag": "hy2", "listen": listen, "port": 443, "protocol": "hysteria",
                "settings": {"version": 2, "users": [{"auth": c['HY2_AUTH'], "email": "user@hy2"}]},
                "streamSettings": {
                    "network": "hysteria", "security": "tls", "tlsSettings": tls,
                    "hysteriaSettings": {"version": 2, "masquerade": {"type": "file", "dir": "/var/www/vpn"}},
                    "finalmask": {"quicParams": {"congestion": "bbr"}},
                },
                "sniffing": SNIFF,
            },
        ],
        "outbounds": [{"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "block"}],
    }


# ───────────────────────── клиент ─────────────────────────
def label(c, kind):
    return f"{c.get('FLAG', '🌐')} {c.get('VPN_NAME', 'VPN')} · {kind}"


def links(c):
    ip = c['PUBLIC_IP']
    q = urllib.parse.quote

    def vless(kind, sid):
        p = {'encryption': 'none', 'security': 'reality', 'sni': c['SNI'], 'fp': 'firefox',
             'pbk': c['REALITY_PUB'], 'sid': sid, 'spx': '/'}
        if kind == 'Vision':
            p.update({'flow': 'xtls-rprx-vision', 'type': 'tcp', 'headerType': 'none'})
        else:
            p.update({'type': 'xhttp', 'path': c['XPATH'], 'mode': 'auto'})
        return f"vless://{c['UUID']}@{ip}:443?{urllib.parse.urlencode(p, quote_via=q, safe='')}#{q(label(c, kind))}"

    hy2 = f"hy2://{c['HY2_AUTH']}@{ip}:443?sni={q(c['CERT_NAME'], safe='')}#{q(label(c, 'Hysteria2'))}"
    return [hy2, vless('XHTTP', c['SID_X']), vless('Vision', c['SID_V'])]


def routing_link(c, ts):
    name = c.get('VPN_NAME', 'VPN')
    profile = {
        "Name": f"{name} RU-direct", "GlobalProxy": "true", "UseChunkFiles": "true",
        "RemoteDNSType": "DoH", "RemoteDNSDomain": "https://cloudflare-dns.com/dns-query", "RemoteDNSIP": "1.1.1.1",
        "DomesticDNSType": "DoH", "DomesticDNSDomain": "https://common.dot.dns.yandex.net/dns-query",
        "DomesticDNSIP": "77.88.8.8",
        "Geoipurl": GEO_IP, "Geositeurl": GEO_SITE, "LastUpdated": ts,
        "DnsHosts": {"cloudflare-dns.com": "1.1.1.1", "common.dot.dns.yandex.net": "77.88.8.8"},
        "RouteOrder": "block-proxy-direct",
        "DirectSites": ["geosite:private", "geosite:category-ru", "domain:ru", "domain:su", "domain:xn--p1ai"],
        "DirectIp": ["geoip:private", "geoip:ru"],
        "ProxySites": [], "ProxyIp": [], "BlockSites": [], "BlockIp": [],
        "DomainStrategy": "IPIfNonMatch", "FakeDNS": "false",
    }
    raw = json.dumps(profile, ensure_ascii=False, separators=(',', ':'))
    return 'happ://routing/onadd/' + b64(raw)


ADD_HTML = r"""<!doctype html>
<html lang="ru"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="referrer" content="no-referrer">
<meta name="robots" content="noindex,nofollow">
<meta name="color-scheme" content="dark light">
<title>__NAME__ — подключение</title>
<style>
:root{--bg:#0b0d14;--card:rgba(255,255,255,.06);--line:rgba(255,255,255,.10);--fg:#eef0f6;--mut:#9aa1b5;
--a1:#7c5cff;--a2:#18c8ff;--ok:#2fd18b;--warn:#ffb648;--r:20px}
@media (prefers-color-scheme:light){:root{--bg:#f4f5fb;--card:#fff;--line:rgba(16,24,40,.09);--fg:#121521;--mut:#5b6275}}
*{box-sizing:border-box}html,body{margin:0}
body{font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Inter,system-ui,sans-serif;color:var(--fg);
background:radial-gradient(1200px 600px at 10% -10%,rgba(124,92,255,.28),transparent 60%),
radial-gradient(900px 500px at 110% 10%,rgba(24,200,255,.20),transparent 60%),var(--bg);min-height:100vh;
padding:max(20px,env(safe-area-inset-top)) 16px 40px}
.wrap{max-width:520px;margin:0 auto}
.pill{display:inline-flex;gap:8px;align-items:center;font-size:13px;color:var(--mut);border:1px solid var(--line);
padding:4px 12px;border-radius:999px;background:var(--card)}
.pill i{width:8px;height:8px;border-radius:50%;background:var(--ok);box-shadow:0 0 12px var(--ok)}
h1{font-size:34px;line-height:1.1;margin:14px 0 6px;letter-spacing:-.02em}
.sub{color:var(--mut);margin:0 0 22px}
.card{background:var(--card);border:1px solid var(--line);border-radius:var(--r);padding:18px;margin:14px 0;
backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px)}
.n{display:inline-grid;place-items:center;width:28px;height:28px;border-radius:50%;font-weight:700;font-size:14px;
color:#fff;background:linear-gradient(135deg,var(--a1),var(--a2));margin-right:10px;flex:none}
.h{display:flex;align-items:center;font-weight:650;font-size:18px;margin-bottom:10px}
p{margin:6px 0}.mut{color:var(--mut);font-size:14px}
.btn{display:flex;justify-content:center;align-items:center;gap:10px;width:100%;padding:16px 18px;border-radius:16px;
font-weight:700;font-size:18px;text-decoration:none;color:#fff;border:0;cursor:pointer;
background:linear-gradient(135deg,var(--a1),var(--a2));box-shadow:0 10px 30px -10px rgba(124,92,255,.8)}
.btn:active{transform:scale(.99)}
.btn2{display:flex;justify-content:center;align-items:center;width:100%;padding:12px 14px;margin-top:10px;border-radius:14px;
font-weight:600;font-size:15px;text-decoration:none;color:var(--fg);background:transparent;border:1px solid var(--line);cursor:pointer}
.stores{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.stores a{display:block;text-align:center;padding:12px 8px;border-radius:14px;border:1px solid var(--line);
color:var(--fg);text-decoration:none;font-weight:600;font-size:14px;background:rgba(127,127,127,.06)}
.stores a small{display:block;font-weight:400;color:var(--mut);font-size:12px}
.hide{display:none!important}
ol{margin:8px 0 0;padding-left:20px}ol li{margin:4px 0}
.tag{display:inline-block;font-size:12px;font-weight:700;padding:2px 8px;border-radius:8px;margin-left:6px;vertical-align:1px}
.t1{background:rgba(47,209,139,.15);color:var(--ok)}.t2{background:rgba(255,182,72,.15);color:var(--warn)}
code{font:13px/1.4 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;word-break:break-all;display:block;
padding:12px;border-radius:12px;background:rgba(127,127,127,.10);border:1px solid var(--line);user-select:all}
.foot{color:var(--mut);font-size:13px;text-align:center;margin-top:22px}
</style></head><body><div class="wrap">
<span class="pill"><i></i>личный VPN</span>
<h1>__FLAG__ __NAME__</h1>
<p class="sub">Три шага, около минуты. Российские сайты и приложения работают напрямую, остальное — через VPN.</p>

<div class="card">
  <div class="h"><span class="n">1</span>Установите Happ</div>
  <div class="stores">
    <a data-os="android" href="https://play.google.com/store/apps/details?id=com.happproxy">Google Play<small>Android</small></a>
    <a data-os="android" href="https://github.com/Happ-proxy/happ-android/releases/latest/download/Happ.apk">Файл APK<small>если нет Google Play</small></a>
    <a data-os="ios" href="https://apps.apple.com/ru/app/happ-proxy-utility/id6783623643">App Store<small>российский аккаунт</small></a>
    <a data-os="ios" href="https://apps.apple.com/us/app/happ-proxy-utility/id6504287215">App Store<small>другие страны</small></a>
    <a data-os="desk" href="https://github.com/Happ-proxy/happ-desktop/releases/latest/download/setup-Happ.x64.exe">Windows<small>установщик</small></a>
    <a data-os="desk" href="https://github.com/Happ-proxy/happ-desktop/releases/latest/download/Happ.macOS.universal.dmg">macOS<small>dmg</small></a>
  </div>
  <button class="btn2 hide" id="allos" type="button">Показать все платформы</button>
</div>

<div class="card">
  <div class="h"><span class="n">2</span>Добавьте подписку</div>
  <a class="btn" href="__HAPP__">Добавить в Happ</a>
  <a class="btn2 hide" id="android" href="__INTENT__">Не открылось? Вариант для Android</a>
  <p class="mut" style="margin-top:10px">Вместе с серверами добавится маршрутизация «российское — напрямую». При первом добавлении Happ минуту скачивает базы адресов.</p>
</div>

<div class="card">
  <div class="h"><span class="n">3</span>Подключитесь</div>
  <p>В Happ нажмите большую круглую кнопку. Серверы по порядку:</p>
  <ol>
    <li><b>Hysteria2</b><span class="tag t1">основной</span></li>
    <li><b>XHTTP</b> — если Hysteria2 перестал соединяться</li>
    <li><b>Vision</b><span class="tag t2">запасной</span></li>
  </ol>
  <p class="mut" style="margin-top:10px">Проверка: <b>ifconfig.me</b> покажет адрес сервера __IP__, а <b>2ip.ru</b> — ваш обычный адрес: так и должно быть.</p>
</div>

<div class="card">
  <div class="h" style="font-size:16px">Ссылка на подписку вручную</div>
  <p class="mut">Happ → «+» → «Вставить из буфера».</p>
  <code id="sub">__SUB__</code>
  <button class="btn2" id="copy" type="button">Скопировать</button>
</div>

<p class="foot">Эта страница — как пароль: не пересылайте её посторонним.<br>Трафик всех ваших устройств виден полоской в Happ.</p>
</div>
<script>
(function(){
  var ua=navigator.userAgent||"", os=/Android/i.test(ua)?"android":(/iPhone|iPad|iPod|Macintosh/i.test(ua)&&"ontouchend" in document)?"ios":"desk";
  var cards=document.querySelectorAll(".stores a"), any=false;
  for(var i=0;i<cards.length;i++){ if(cards[i].getAttribute("data-os")!==os){cards[i].classList.add("hide");} else {any=true;} }
  var all=document.getElementById("allos"); all.classList.remove("hide");
  all.onclick=function(){ for(var i=0;i<cards.length;i++){cards[i].classList.remove("hide");} all.classList.add("hide"); };
  if(os==="android"){document.getElementById("android").classList.remove("hide");}
  document.getElementById("copy").onclick=function(){
    var t=document.getElementById("sub").textContent, b=this;
    function done(){b.textContent="Скопировано";}
    function fb(){var r=document.createRange();r.selectNodeContents(document.getElementById("sub"));var s=getSelection();s.removeAllRanges();s.addRange(r);try{document.execCommand("copy");done();}catch(e){}}
    if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(t).then(done,fb);}else{fb();}
  };
})();
</script>
</body></html>
"""


def cmd_links(c):
    state = os.path.join(ETC, 'state.env')
    ts = c.get('PROFILE_TS') or str(int(time.time()))
    set_env(state, 'PROFILE_TS', ts)
    host = c['CERT_NAME']
    sub_url = f"https://{host}/{c['SUBSEC']}/sub"
    add_url = f"https://{host}/{c['SUBSEC']}/add"
    set_env(state, 'SUB_URL', sub_url)
    set_env(state, 'ADD_URL', add_url)
    body = routing_link(c, ts) + '\n' + '\n'.join(links(c)) + '\n'
    write(os.path.join(ETC, 'sub.body'), body, 0o600, None)
    happ = 'happ://add/' + sub_url
    intent = f"intent://add/{sub_url}#Intent;scheme=happ;package=com.happproxy;end"
    e = html.escape
    page = (ADD_HTML.replace('__NAME__', e(c.get('VPN_NAME', 'VPN'))).replace('__FLAG__', e(c.get('FLAG', '')))
            .replace('__HAPP__', e(happ)).replace('__INTENT__', e(intent)).replace('__SUB__', e(sub_url))
            .replace('__IP__', e(c['PUBLIC_IP'])))
    write(os.path.join(SUBDIR, 'add.html'), page)
    info = (f"VPN «{c.get('VPN_NAME', 'VPN')}» на сервере {c['PUBLIC_IP']}\n\n"
            f"Страница для телефона (Happ добавится в одно касание):\n  {add_url}\n\n"
            f"Подписка для Happ вручную (+ → «Вставить из буфера»):\n  {sub_url}\n\n"
            "Отдельные ссылки — если подписка не открывается:\n  " + '\n  '.join(links(c)) + "\n\n"
            "Ссылки работают как пароль. Не публикуйте их.\n")
    write(os.path.join(ETC, 'info.txt'), info, 0o600, None)


def month_usage(c):
    now = datetime.datetime.now(datetime.timezone.utc)
    both = c.get('TRAFFIC_COUNT', 'out') == 'both'
    used = 0
    try:
        out = subprocess.run(['vnstat', '--json', 'm', '2', '-i', c.get('IFACE', 'eth0')],
                             capture_output=True, text=True, timeout=20).stdout
        for m in json.loads(out)['interfaces'][0]['traffic']['month']:
            if (m['date']['year'], m['date']['month']) == (now.year, now.month):
                used = int(m['tx']) + (int(m['rx']) if both else 0)
    except Exception:
        pass
    seed = read_env(os.path.join(ETC, 'traffic-seed.env'))
    if seed.get('MONTH') == now.strftime('%Y-%m'):
        used += int(seed.get('TX', '0') or 0) + (int(seed.get('RX', '0') or 0) if both else 0)
    try:
        total = int(float(c.get('TRAFFIC_LIMIT_GB', '1000') or 0) * 10**9)
    except ValueError:
        total = 0
    nxt = (now.replace(day=1) + datetime.timedelta(days=32)).replace(day=1)
    return used, total, nxt


def cmd_update(c):
    used, total, nxt = month_usage(c)
    name = c.get('VPN_NAME', 'VPN')
    title = name if name.isascii() else 'base64:' + b64(name)
    head = [f"#profile-title: {title}",
            f"#profile-update-interval: {c.get('SUB_UPDATE_HOURS', '1')}",
            f"#subscription-userinfo: upload=0; download={used}; total={total}; expire=0"]
    stop = c.get('STOP_AT_LIMIT') == '1'
    flag = os.path.join(ETC, 'stopped-by-limit')
    if total and used >= total and stop:
        if not os.path.exists(flag):
            subprocess.run(['systemctl', 'stop', 'xray'], check=False)
            open(flag, 'w').write(datetime.datetime.now().isoformat())
    elif os.path.exists(flag):
        subprocess.run(['systemctl', 'start', 'xray'], check=False)
        os.remove(flag)
    if total and used >= 0.8 * total:
        pct = used * 100 / total
        if stop and used >= total:
            text = f"⛔ Месячный лимит трафика исчерпан, VPN выключен до {nxt:%d.%m}."
        else:
            text = f"⚠️ Израсходовано {pct:.0f}% месячного лимита трафика. Счётчик обнулится {nxt:%d.%m}."
        head.append(f"#announce: base64:{b64(text)}")
    body = open(os.path.join(ETC, 'sub.body'), encoding='utf-8').read()
    write(os.path.join(SUBDIR, 'sub.txt'), '\n'.join(head) + '\n' + body)


def cmd_usage(c):
    used, total, nxt = month_usage(c)
    lim = f"из {total / 1e9:g} ГБ ({used * 100 / total:.0f}%)" if total else "(без лимита)"
    print(f"Трафик за месяц: {used / 1e9:.1f} ГБ {lim}, счётчик обнулится {nxt:%d.%m}")


def cmd_selftest(c, d, addr):
    """Клиентские конфиги, повторяющие ссылки из подписки, — для проверки на самом сервере."""
    os.makedirs(d, exist_ok=True)

    def reality(sid):
        return {"fingerprint": "firefox", "serverName": c['SNI'], "password": c['REALITY_PUB'], "shortId": sid, "spiderX": "/"}

    hy_tls = {"serverName": c['CERT_NAME']}
    test_ca = os.environ.get('VPN_TEST_CA') or (f"{TLS}/fullchain.pem" if os.environ.get('VPN_TEST_SELFSIGNED') else '')
    if test_ca:  # только для автотестов: доверить тестовому центру сертификации
        hy_tls["certificates"] = [{"usage": "verify", "certificateFile": test_ca}]
    outs = {
        'hy2': {"protocol": "hysteria", "settings": {"version": 2, "address": addr, "port": 443},
                "streamSettings": {"network": "hysteria", "security": "tls", "tlsSettings": hy_tls,
                                   "hysteriaSettings": {"version": 2, "auth": c['HY2_AUTH']},
                                   "finalmask": {"quicParams": {"congestion": "bbr"}}}},
        'xhttp': {"protocol": "vless",
                  "settings": {"vnext": [{"address": addr, "port": 443, "users": [{"id": c['UUID'], "encryption": "none"}]}]},
                  "streamSettings": {"network": "xhttp", "xhttpSettings": {"path": c['XPATH'], "mode": "auto"},
                                     "security": "reality", "realitySettings": reality(c['SID_X'])}},
        'vision': {"protocol": "vless",
                   "settings": {"vnext": [{"address": addr, "port": 443,
                                           "users": [{"id": c['UUID'], "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
                   "streamSettings": {"network": "raw", "security": "reality", "realitySettings": reality(c['SID_V'])}},
    }
    for i, (name, out) in enumerate(outs.items()):
        port = 21081 + i
        conf = {"log": {"loglevel": "warning"},
                "inbounds": [{"listen": "127.0.0.1", "port": port, "protocol": "socks", "settings": {"udp": True}}],
                "outbounds": [out]}
        with open(os.path.join(d, f'{name}.json'), 'w') as f:
            json.dump(conf, f, indent=1)
        with open(os.path.join(d, f'{name}.port'), 'w') as f:
            f.write(str(port))


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    c = load()
    cmd = sys.argv[1]
    if cmd == 'xray-config':
        print(json.dumps(xray_config(c), indent=2, ensure_ascii=False))
    elif cmd == 'links':
        cmd_links(c)
    elif cmd == 'update':
        cmd_update(c)
    elif cmd == 'usage':
        cmd_usage(c)
    elif cmd == 'selftest':
        cmd_selftest(c, sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
PYGEN
  chmod 755 "$LIB/gen.py"
}

print_summary() {
  local ADD_URL SUB_URL user
  ADD_URL=$(env_get "$ETC/state.env" ADD_URL); SUB_URL=$(env_get "$ETC/state.env" SUB_URL)
  user=$(env_get "$ETC/state.env" SSH_USER)
  printf '\n%s══════════════════════════════════════════════════════════════%s\n' "$G$B" "$N"
  printf '%s  ✅ VPN готов%s\n\n' "$G$B" "$N"
  cat <<EOF
  1. Поставьте на телефон приложение Happ:
       Android — Google Play, iPhone — App Store (поиск «Happ Proxy Utility»).
  2. Откройте на телефоне ссылку или наведите камеру на QR-код ниже:

       ${B}${ADD_URL}${N}

  3. На открывшейся странице нажмите «Добавить в Happ», затем в Happ —
     большую кнопку подключения. Первым идёт сервер «Hysteria2».

  Ссылка работает как пароль: кто её получит, тот пользуется вашим VPN.
EOF
  echo
  qrencode -t ANSIUTF8 -m 2 "$ADD_URL" 2>/dev/null || true
  cat <<EOF

  Подписка для Happ вручную (+ → «Вставить из буфера»):
       $SUB_URL

  SSH теперь на порту ${B}${SSH_PORT_FINAL}${N}:  ssh -p $SSH_PORT_FINAL $user@$PUBLIC_IP
  Показать всё это ещё раз:  sudo vpn-info
EOF
  if [[ "$(env_get "$ETC/state.env" CERT_NAME)" == *.vps.webdock.cloud ]] && [[ "$SSH_PORT_FINAL" != 22 ]]; then
    printf '\n  %sWebdock:%s чтобы веб-терминал в панели работал, укажите там новый порт SSH: %s.\n' "$Y" "$N" "$SSH_PORT_FINAL"
  fi
  [[ -f /var/run/reboot-required ]] && printf '\n  Система обновилась и сама перезагрузится ночью в 04:30 — VPN поднимется автоматически.\n'
  printf '%s══════════════════════════════════════════════════════════════%s\n' "$G$B" "$N"
}

main() {
  umask 022
  trap 'on_err $LINENO' ERR
  mkdir -p "$(dirname "$LOG")"; touch "$LOG"; chmod 600 "$LOG"
  exec > >(tee -a "$LOG") 2>&1
  printf '%svpn-setup %s — %s%s\n' "$B" "$SCRIPT_VERSION" "$(date '+%F %T')" "$N"
  preflight
  load_settings
  install_packages
  write_tools
  base_system
  detect_network
  setup_nginx_http
  install_xray
  step "Ключи и сертификат"
  gen_secrets
  obtain_cert
  write_xray_config
  setup_subscription
  setup_firewall_ssh
  self_test
  STEP="итог"
  print_summary
}

main "$@" </dev/null
