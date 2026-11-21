#!/usr/bin/env bash
# ================================================================
#  s5relay：把 VPS 搭成前置代理，加速 SOCKS5，带网页后台管理 S5
#
#  伪装模式（填宝塔里 WordPress 网站的域名）：
#   - Reality 伪装成你自己的网站：探测者看到的是你真实的 WordPress + 正规证书
#   - Hysteria2 用网站的正规证书，被探测时也返回你的网站；证书续期自动同步
#   - 后台和订阅挂在 https://你的域名/隐藏路径/ 下，不用额外开端口
#   - 不改网站本身的 443 监听，宝塔照常管理网站
#  普通模式（不填域名）：伪装成微软，后台用自签名证书单独开端口
#
#  通用：前置默认 Reality；后台要密码，错 5 次锁 15 分钟；防 DNS 泄露；
#        fail2ban 防 SSH 暴力破解；开启 BBR
#
#  安装：bash <(curl -fsSL https://raw.githubusercontent.com/8820387-byte/s5relay/main/install.sh)
#  家里电脑节点：... install.sh) home         （关闭：home-off）
#  重置后台密码：... install.sh) reset-pass
#  关闭网页后台：... install.sh) web-off        （重新运行安装即可再打开）
#  卸载：         ... install.sh) uninstall
# ================================================================
set -euo pipefail

CONF_DIR=/etc/sing-box
DATA=/etc/s5relay
APP=/usr/local/lib/s5relay/app.py
RAW="https://raw.githubusercontent.com/8820387-byte/s5relay/main/install.sh"
BT_NGINX=/www/server/nginx/sbin/nginx
INC=/www/server/nginx/conf/s5relay.inc

die() { echo; echo "!! $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "请用 root 运行"

unhook_nginx() {   # 从宝塔网站配置里去掉后台入口
  local changed=n f
  for f in /www/server/panel/vhost/nginx/*.conf; do
    if [ -f "$f" ] && grep -q '# s5relay$' "$f"; then sed -i '/# s5relay$/d' "$f"; changed=y; fi
  done
  rm -f "$INC"
  if [ "$changed" = y ] && [ -x "$BT_NGINX" ] && "$BT_NGINX" -t >/dev/null 2>&1; then
    "$BT_NGINX" -s reload || true
  fi
}

remove_web() {   # 包括旧版本留下的订阅服务
  for s in clash-sub s5relay-sub s5relay-web; do
    systemctl disable --now "$s" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$s.service"
  done
  rm -rf /var/lib/clash-sub /etc/s5relay-sub /usr/local/bin/s5relay-sub.py
  systemctl daemon-reload 2>/dev/null || true
  unhook_nginx
}

# ---------------------------------------------------------------- 家里电脑节点（frp）
FRPS=/usr/local/bin/s5relay-frps

remove_home() {
  systemctl disable --now s5relay-frps >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/s5relay-frps.service "$FRPS" "$DATA/frps.toml" "$DATA/home.json" "$DATA/frpc_windows_amd64.zip"
  systemctl daemon-reload 2>/dev/null || true
  if [ -f "$APP" ] && [ -f "$DATA/base.json" ]; then
    S5R_DIR=$DATA python3 "$APP" del-local || true
    systemctl restart s5relay-web >/dev/null 2>&1 || true
  fi
}

setup_home() {
  [ -f "$APP" ] && [ -f "$DATA/base.json" ] || die "请先运行一次安装命令，再开启家里电脑节点"
  local arch tag ver tmp p port
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;;
    *) die "不支持的服务器架构 $(uname -m)" ;;
  esac
  echo ">>> [1/4] 下载 frp"
  tag=$(curl -fsSL --max-time 20 https://api.github.com/repos/fatedier/frp/releases/latest 2>/dev/null \
        | python3 -c "import json,sys;print(json.load(sys.stdin)['tag_name'])" 2>/dev/null || true)
  if [ -z "$tag" ]; then   # API 被限流时，从发布页跳转地址取版本号
    tag=$(curl -fsSI --max-time 20 https://github.com/fatedier/frp/releases/latest 2>/dev/null \
          | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}' | awk -F/ '{print $NF}')
  fi
  case "$tag" in v[0-9]*) ;; *) die "获取 frp 版本失败（服务器连不上 GitHub）" ;; esac
  ver=${tag#v}
  tmp=$(mktemp -d)
  curl -fsSL --max-time 120 -o "$tmp/frp.tgz" \
    "https://github.com/fatedier/frp/releases/download/${tag}/frp_${ver}_linux_${arch}.tar.gz" || die "下载 frps 失败"
  tar -xzf "$tmp/frp.tgz" -C "$tmp"
  systemctl stop s5relay-frps >/dev/null 2>&1 || true
  install -m 755 "$tmp"/frp_*/frps "$FRPS"
  if curl -fsSL --max-time 120 -o "$DATA/frpc_windows_amd64.zip" \
       "https://github.com/fatedier/frp/releases/download/${tag}/frp_${ver}_windows_amd64.zip"; then
    chmod 600 "$DATA/frpc_windows_amd64.zip"
  else
    rm -f "$DATA/frpc_windows_amd64.zip"
    echo "    Windows 版预下载失败，家里电脑会改从 GitHub 下载"
  fi
  rm -rf "$tmp"

  echo ">>> [2/4] 生成配置"
  port=""
  for p in ${HOME_PORT:-7000} 7443 17000 27000; do
    ss -ltnH | awk '{print $4}' | grep -qE "[:.]$p\$" || { port=$p; break; }
  done
  [ -n "$port" ] || die "端口 7000 / 7443 / 17000 / 27000 都被占用了"
  eval "$(python3 - "$DATA/home.json" "$port" <<'PYEOF'
import json, os, secrets, sys
p, port = sys.argv[1], int(sys.argv[2])
try:
    h = json.load(open(p))
except Exception:
    h = {}
h.setdefault("token", secrets.token_hex(24))
h.setdefault("s5_user", "home")
h.setdefault("s5_pass", secrets.token_hex(12))
h.setdefault("dl_token", secrets.token_hex(16))
h.setdefault("remote_port", 10800)
h["bind_port"] = port
with open(p + ".tmp", "w") as f:
    json.dump(h, f, indent=2)
os.chmod(p + ".tmp", 0o600)
os.replace(p + ".tmp", p)
print(f"H_TOKEN={h['token']} H_USER={h['s5_user']} H_PASS={h['s5_pass']} H_RPORT={h['remote_port']}")
PYEOF
)"
  cat > "$DATA/frps.toml" <<EOF
bindAddr = "0.0.0.0"
bindPort = ${port}
proxyBindAddr = "127.0.0.1"
auth.method = "token"
auth.token = "${H_TOKEN}"
transport.tls.force = true
transport.maxPoolCount = 10
allowPorts = [ { single = ${H_RPORT} } ]
log.to = "console"
log.level = "warn"
EOF
  chmod 600 "$DATA/frps.toml"
  "$FRPS" verify -c "$DATA/frps.toml" >/dev/null || die "frps 配置校验失败"

  cat > /etc/systemd/system/s5relay-frps.service <<EOF
[Unit]
Description=s5relay home PC tunnel (frps)
After=network.target

[Service]
ExecStart=${FRPS} -c ${DATA}/frps.toml
Restart=always
RestartSec=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now s5relay-frps >/dev/null 2>&1
  sleep 1
  systemctl is-active --quiet s5relay-frps || { journalctl -u s5relay-frps -n 20 --no-pager; die "frps 启动失败"; }

  echo ">>> [3/4] 放行端口 TCP ${port}"
  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then ufw allow "${port}/tcp" >/dev/null; fi
  if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null; firewall-cmd --reload >/dev/null
  fi

  echo ">>> [4/4] 加入 S5 列表"
  S5R_DIR=$DATA python3 "$APP" add "家里电脑" 127.0.0.1 "$H_RPORT" "$H_USER" "$H_PASS" noudp
  systemctl restart s5relay-web >/dev/null 2>&1 || true

  local DOMAIN_ PANEL_ DL_
  DOMAIN_=$(python3 -c "import json;print(json.load(open('$DATA/base.json')).get('domain') or '')")
  PANEL_=$(python3 -c "import json;print(json.load(open('$DATA/base.json'))['panel_path'])")
  DL_=$(python3 -c "import json;print(json.load(open('$DATA/home.json'))['dl_token'])")
  echo
  echo "======================= 家里电脑节点已开启 ======================="
  echo
  echo " 1) 云服务器安全组 和 宝塔「安全」页 放行：TCP ${port}"
  echo
  echo " 2) 在【家里的 Windows 电脑】上打开 PowerShell，粘贴运行："
  if [ -n "$DOMAIN_" ]; then
    echo
    echo "    irm https://${DOMAIN_}${PANEL_}/h/${DL_}/setup.ps1 | iex"
    echo
    echo "    （或者：网页后台 →「家里电脑节点」→ 下载脚本 → 右键「使用 PowerShell 运行」）"
  else
    echo "    网页后台 →「家里电脑节点」→ 下载脚本 → 右键「使用 PowerShell 运行」"
  fi
  echo
  echo " 3) 网页后台对「家里电脑」点「测试」，显示出口 IP 即成功"
  echo "    Clash 里更新订阅，选「家里电脑-加速」就是用家里的网络上网"
  echo
  echo " 关闭：bash <(curl -fsSL ${RAW}) home-off"
  echo "================================================================="
}

case "${1:-}" in
  home)
    setup_home; exit 0 ;;
  home-off)
    remove_home
    echo "家里电脑节点已关闭。家里电脑上删除「启动」文件夹里的 s5relay-home.vbs 并结束 frpc 进程即可"; exit 0 ;;
  uninstall)
    remove_home
    remove_web
    systemctl disable --now sing-box >/dev/null 2>&1 || true
    rm -rf "$CONF_DIR" "$DATA" /usr/local/lib/s5relay /root/clash.yaml /etc/cron.daily/s5relay-cert
    echo "已卸载（你的网站没有受影响）"; exit 0 ;;
  web-off|sub-off)
    remove_web
    echo "网页后台和订阅已关闭（Clash 里已导入的配置照常能用）"
    echo "S5 列表还保留着，重新运行安装命令就能再打开"; exit 0 ;;
  reset-pass)
    [ -f "$APP" ] || die "还没安装"
    NEWPW=$(S5R_DIR=$DATA python3 "$APP" passwd)
    echo "后台新密码：$NEWPW"; exit 0 ;;
esac

# ---------------------------------------------------------------- 收集信息
S5_SERVER="${1:-${S5_SERVER:-}}"
S5_PORT="${2:-${S5_PORT:-}}"
S5_USER="${3:-${S5_USER:-}}"
S5_PASS="${4:-${S5_PASS:-}}"
if [ -z "$S5_SERVER" ] && [ -r /dev/tty ]; then
  echo "先添加一个 S5（直接回车跳过，装好后在网页后台添加）"
  read -rp "S5 地址: " S5_SERVER </dev/tty || true
  if [ -n "$S5_SERVER" ]; then
    read -rp "S5 端口: " S5_PORT </dev/tty
    read -rp "S5 账号（没有直接回车）: " S5_USER </dev/tty
    if [ -n "$S5_USER" ]; then read -rsp "S5 密码（输入时不显示）: " S5_PASS </dev/tty; echo; fi
  fi
fi
if [ -n "$S5_SERVER" ] && [ -z "$S5_PORT" ]; then die "S5 端口不能为空"; fi

DOMAIN="${DOMAIN:-}"
if [ -z "$DOMAIN" ] && [ -r /dev/tty ]; then
  read -rp "宝塔里 WordPress 网站的域名，用来伪装（没有就直接回车）: " DOMAIN </dev/tty || true
fi
DOMAIN=$(printf '%s' "$DOMAIN" | tr -d ' ' | sed -E 's#^https?://##; s#/.*$##' | tr 'A-Z' 'a-z')

WEB="${WEB:-}"
if [ -z "$WEB" ] && [ -r /dev/tty ]; then
  read -rp "开启网页后台和订阅链接？[Y/n]: " WEB </dev/tty || true
fi
case "${WEB:-y}" in [nN]*) WEB=n ;; *) WEB=y ;; esac

# ---------------------------------------------------------------- 检查宝塔网站
if [ -n "$DOMAIN" ]; then
  echo ">>> 检查宝塔网站 $DOMAIN"
  BT_CONF="/www/server/panel/vhost/nginx/${DOMAIN}.conf"
  BT_CERT="/www/server/panel/vhost/cert/${DOMAIN}"
  [ -x "$BT_NGINX" ] || die "没找到宝塔的 nginx（$BT_NGINX）。请先在宝塔「软件商店」安装 Nginx"
  [ -f "$BT_CONF" ] || die "宝塔里没有 $DOMAIN 这个网站（找不到 $BT_CONF），请确认和宝塔「网站」列表里的域名一致"
  if [ ! -s "$BT_CERT/fullchain.pem" ] || [ ! -s "$BT_CERT/privkey.pem" ]; then
    die "网站还没开 HTTPS：宝塔 → 网站 → $DOMAIN 设置 → SSL → Let's Encrypt → 申请，再重新运行本脚本"
  fi
  openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" -tls1_3 </dev/null >/dev/null 2>&1 \
    || die "网站不支持 TLS1.3：宝塔 → 网站 → $DOMAIN 设置 → SSL，TLS 版本里勾上 TLSv1.3 保存，再重新运行"
  echo "    网站 HTTPS 正常，支持 TLS1.3"
fi

REALITY_PORT="${REALITY_PORT:-443}"
HY2_PORT="${HY2_PORT:-8443}"
if [ -n "$DOMAIN" ]; then
  WEB_PORT="${WEB_PORT:-18080}"          # 只监听本机，由网站 nginx 转发
  SNI="$DOMAIN"; HS_HOST=127.0.0.1; HS_PORT=443
else
  WEB_PORT="${WEB_PORT:-8443}"
  SNI="${SNI:-www.microsoft.com}"; HS_HOST="$SNI"; HS_PORT=443
fi

# ---------------------------------------------------------------- 安装
echo ">>> [1/6] 安装依赖"
apt-get update -y >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl ca-certificates iproute2 python3 cron qrencode >/dev/null

echo ">>> [2/6] 安装 sing-box"
if ! command -v sing-box >/dev/null; then
  curl -fsSL https://sing-box.app/install.sh | sh >/dev/null
fi
command -v sing-box >/dev/null || die "sing-box 安装失败"
systemctl stop sing-box 2>/dev/null || true
remove_web

tcp_busy() { ss -ltnH | awk '{print $4}' | grep -qE "[:.]$1\$"; }
udp_busy() { ss -lunH | awk '{print $4}' | grep -qE "[:.]$1\$"; }
pick_port() {   # pick_port tcp|udp 首选 备选...
  local proto=$1; shift
  for p in "$@"; do
    if [ "$proto" = tcp ]; then tcp_busy "$p" || { echo "$p"; return; }
    else udp_busy "$p" || { echo "$p"; return; }; fi
  done
  echo "端口 $* 全被占用" >&2; exit 1
}
OLD=$REALITY_PORT
REALITY_PORT=$(pick_port tcp "$REALITY_PORT" 2443 2053 2083 2087 2096 9443)
[ "$OLD" = "$REALITY_PORT" ] || echo "    TCP $OLD 已被网站使用，Reality 用 $REALITY_PORT"
OLD=$HY2_PORT
HY2_PORT=$(pick_port udp "$HY2_PORT" 18443 28443 38443)
[ "$OLD" = "$HY2_PORT" ] || echo "    UDP $OLD 被占用，Hysteria2 自动改用 $HY2_PORT"
if [ "$WEB" = y ]; then
  WEB_PORT=$(pick_port tcp "$WEB_PORT" 18080 28080 38080 18443 28443)
fi

echo ">>> [3/6] 生成新密钥和服务端配置"
UUID=$(sing-box generate uuid)
KEYPAIR=$(sing-box generate reality-keypair)
PRIV_KEY=$(echo "$KEYPAIR" | awk '/PrivateKey/{print $2}')
PUB_KEY=$(echo "$KEYPAIR"  | awk '/PublicKey/{print $2}')
SHORT_ID=$(sing-box generate rand --hex 8)
HY2_PASS=$(sing-box generate rand --hex 16)

mkdir -p "$CONF_DIR"
if [ -n "$DOMAIN" ]; then
  install -m 600 "$BT_CERT/fullchain.pem" "$CONF_DIR/cert.pem"
  install -m 600 "$BT_CERT/privkey.pem" "$CONF_DIR/key.pem"
  # 宝塔续期证书后，每天自动同步给 Hysteria2
  cat > /etc/cron.daily/s5relay-cert <<EOF
#!/bin/sh
S=/www/server/panel/vhost/cert/${DOMAIN}
[ -s "\$S/fullchain.pem" ] || exit 0
cmp -s "\$S/fullchain.pem" ${CONF_DIR}/cert.pem && exit 0
install -m 600 "\$S/fullchain.pem" ${CONF_DIR}/cert.pem
install -m 600 "\$S/privkey.pem" ${CONF_DIR}/key.pem
chown sing-box:sing-box ${CONF_DIR}/cert.pem ${CONF_DIR}/key.pem 2>/dev/null
systemctl restart sing-box
EOF
  chmod 755 /etc/cron.daily/s5relay-cert
else
  rm -f /etc/cron.daily/s5relay-cert
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$CONF_DIR/key.pem" -out "$CONF_DIR/cert.pem" \
    -subj "/CN=bing.com" -days 36500 >/dev/null 2>&1
fi

write_sb() {   # write_sb 是否加 masquerade(y/n)
  local masq=""
  if [ "$1" = y ] && [ -n "$DOMAIN" ]; then masq=", \"masquerade\": \"https://${DOMAIN}\""; fi
  cat > "$CONF_DIR/config.json" <<EOF
{
  "log": { "level": "error", "timestamp": true },
  "inbounds": [
    {
      "type": "vless", "tag": "vless-reality",
      "listen": "::", "listen_port": ${REALITY_PORT},
      "users": [ { "uuid": "${UUID}", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true, "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${HS_HOST}", "server_port": ${HS_PORT} },
          "private_key": "${PRIV_KEY}",
          "short_id": [ "${SHORT_ID}" ]
        }
      }
    },
    {
      "type": "hysteria2", "tag": "hy2",
      "listen": "::", "listen_port": ${HY2_PORT},
      "users": [ { "password": "${HY2_PASS}" } ]${masq},
      "tls": {
        "enabled": true, "alpn": [ "h3" ],
        "certificate_path": "${CONF_DIR}/cert.pem",
        "key_path": "${CONF_DIR}/key.pem"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
}
write_sb y
if ! sing-box check -c "$CONF_DIR/config.json" >/dev/null 2>&1; then
  write_sb n      # 老版本 sing-box 不支持 masquerade 时退回
  sing-box check -c "$CONF_DIR/config.json"
fi
chown -R sing-box:sing-box "$CONF_DIR" 2>/dev/null || true
chmod 700 "$CONF_DIR"

echo ">>> [4/6] 开启 BBR + 防 SSH 暴力破解"
cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
sysctl --system >/dev/null 2>&1 || true
if DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban python3-systemd >/dev/null 2>&1; then
  cat > /etc/fail2ban/jail.d/sshd-s5relay.local <<EOF
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban >/dev/null 2>&1 || echo "    fail2ban 启动失败，已跳过（不影响代理）"
else
  echo "    fail2ban 安装失败，已跳过（不影响代理）"
fi

OPEN_TCP="$REALITY_PORT"
if [ "$WEB" = y ] && [ -z "$DOMAIN" ]; then OPEN_TCP="$OPEN_TCP $WEB_PORT"; fi
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  for p in $OPEN_TCP; do ufw allow "$p/tcp" >/dev/null; done
  ufw allow "$HY2_PORT/udp" >/dev/null
fi
if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  for p in $OPEN_TCP; do firewall-cmd --permanent --add-port="$p/tcp" >/dev/null; done
  firewall-cmd --permanent --add-port="$HY2_PORT/udp" >/dev/null
  firewall-cmd --reload >/dev/null
fi

systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box
sleep 1
systemctl is-active --quiet sing-box || { journalctl -u sing-box -n 30 --no-pager; exit 1; }

echo ">>> [5/6] 安装网页后台程序"
IP=$(curl -s4 --max-time 5 https://api.ipify.org || curl -s4 --max-time 5 https://ifconfig.me || true)
[ -n "$IP" ] || die "获取公网 IP 失败"

mkdir -p "$(dirname "$APP")" "$DATA"
chmod 700 "$DATA"
cat > "$APP" <<'PYEOF'
#!/usr/bin/env python3
# s5relay 网页后台：管理 S5 列表 + 生成 Clash 订阅（只用 Python 标准库）
#   serve                      启动 HTTPS 后台 + 订阅
#   render                     重新生成 clash.yaml
#   add 名称 地址 端口 [账号] [密码]
#   passwd                     重置后台密码（打印新密码）
import base64, hashlib, hmac, html, ipaddress, json, os, re, secrets, shutil, socket, ssl, struct, subprocess, sys, threading, time, uuid
from urllib.parse import quote
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.cookies import SimpleCookie

DIR = os.environ.get("S5R_DIR", "/etc/s5relay")
BASE = os.path.join(DIR, "base.json")
S5DB = os.path.join(DIR, "s5.json")
AUTH = os.path.join(DIR, "auth.json")
HOME = os.path.join(DIR, "home.json")
HOME_ZIP = os.path.join(DIR, "frpc_windows_amd64.zip")
LOCAL_HOSTS = ("127.0.0.1", "localhost")
OUT = os.path.join(DIR, "clash.yaml")
SB_CONF = os.environ.get("S5R_SB_CONF", "/etc/sing-box/config.json")
SB_BAK = os.path.join(DIR, "sb-config.bak")
LOCK = threading.RLock()
FAILS = {}  # ip -> [次数, 首次时间]


# ---------------------------------------------------------------- 存储
def load(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def save(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def q(s):  # JSON 字符串同时是合法的 YAML 双引号字符串
    return json.dumps(str(s), ensure_ascii=False)


# ---------------------------------------------------------------- 生成 Clash 配置
HEADER = """mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
ipv6: false
unified-delay: true
tcp-concurrent: true
external-controller: 127.0.0.1:9090
profile:
  store-selected: true
geodata-mode: true
geox-url:
  geoip: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat"
  geosite: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"
  mmdb: "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb"
dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "*.lan"
    - "+.local"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
  proxy-server-nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
"""

FOOTER = """  - name: "前置节点"
    type: select
    proxies:
      - "前置-自动"
      - "自建-Reality"
      - "自建-Hy2"

  - name: "前置-自动"
    type: fallback
    proxies:
      - "自建-Reality"
      - "自建-Hy2"
    url: https://www.gstatic.com/generate_204
    interval: 300

rules:
  - GEOSITE,private,DIRECT
  - GEOIP,private,DIRECT,no-resolve
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,🚀 节点选择
"""


def render():
    with LOCK:
        b = load(BASE, {})
        items = load(S5DB, [])
        L = [HEADER, "proxies:"]
        L += [
            '  - name: "自建-Reality"', "    type: vless",
            f"    server: {q(b['ip'])}", f"    port: {int(b['reality_port'])}",
            f"    uuid: {q(b['uuid'])}", "    network: tcp", "    tls: true", "    udp: true",
            "    flow: xtls-rprx-vision", f"    servername: {q(b['sni'])}",
            "    client-fingerprint: chrome", "    reality-opts:",
            f"      public-key: {q(b['pub_key'])}", f"      short-id: {q(b['short_id'])}", "",
            '  - name: "自建-Hy2"', "    type: hysteria2",
            f"    server: {q(b['ip'])}", f"    port: {int(b['hy2_port'])}",
            f"    password: {q(b['hy2_pass'])}",
        ]
        if b.get("domain"):
            L += [f"    sni: {q(b['domain'])}", "    udp: true", ""]
        else:
            L += ["    sni: bing.com", "    skip-cert-verify: true", "    udp: true", ""]
        names = []
        for kind in ("直连", "加速"):
            for it in items:
                if kind == "直连" and it["server"] in LOCAL_HOSTS:
                    continue
                name = f"{it['name']}-{kind}"
                names.append(name)
                L += [f"  - name: {q(name)}", "    type: socks5",
                      f"    server: {q(it['server'])}", f"    port: {int(it['port'])}"]
                if it.get("username"):
                    L += [f"    username: {q(it['username'])}", f"    password: {q(it.get('password', ''))}"]
                L.append(f"    udp: {'true' if it.get('udp', True) else 'false'}")
                if kind == "加速":
                    L.append('    dialer-proxy: "前置节点"')
                L.append("")
        L += ["proxy-groups:", '  - name: "🚀 节点选择"', "    type: select", "    proxies:"]
        L += [f"      - {q(n)}" for n in names]   # 前置节点只用来中转，不能当出口（出口会是服务器 IP）
        L += ["      - DIRECT", ""]
        footer = FOOTER
        if b.get("domain"):   # 自己的网站（后台/订阅）一律直连，更新订阅不绕代理
            footer = footer.replace("rules:\n", f"rules:\n  - DOMAIN,{b['domain']},DIRECT\n", 1)
        text = "\n".join(L) + "\n" + footer
        tmp = OUT + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, OUT)
        return text


# ---------------------------------------------------------------- 分享链接 / 二维码
def universal_sub(b, items):
    """通用订阅：base64 的分享链接列表，小火箭 / v2rayN / NekoBox 等直接导入全部节点。
    只提供「出口是 S5」的节点，不提供出口是服务器的节点。"""
    links = [l for _, l in share_s5(b, items)]
    return base64.b64encode("\n".join(links).encode()).decode()

def share_s5(b, items):
    """每个 S5 一组「出口 S5」专用链接：导入小火箭等客户端后，出口直接就是这个 S5。
    不依赖客户端的链式代理：服务器按用户把流量转给对应的 S5。"""
    out = []
    ip = b["ip"]
    for it in items:
        if not it.get("uid"):
            continue
        n = it["name"]
        if b.get("domain"):
            h = f"hysteria2://{it['hpass']}@{ip}:{b['hy2_port']}?sni={quote(b['domain'])}#{quote(n + '-Hy2')}"
        else:
            h = f"hysteria2://{it['hpass']}@{ip}:{b['hy2_port']}?sni=bing.com&insecure=1#{quote(n + '-Hy2')}"
        v = (f"vless://{it['uid']}@{ip}:{b['reality_port']}?encryption=none"
             f"&security=reality&sni={quote(b['sni'])}&fp=chrome&pbk={b['pub_key']}&sid={b['short_id']}"
             f"&type=tcp#{quote(n + '-Reality')}")
        out += [(f"出口 {n} · Hy2（推荐）", h), (f"出口 {n} · Reality（无流控）", v)]
    return out


def sync_singbox():
    """把每个 S5 写成 sing-box 的专用用户 + 出站（按用户路由）。成功返回 ok/unchanged，失败返回 error: ..."""
    with LOCK:
        if not os.path.exists(SB_CONF):
            return "unchanged"
        items = load(S5DB, [])
        ch = False
        for i in items:
            if not i.get("uid"):
                i["uid"], ch = str(uuid.uuid4()), True
            if not i.get("hpass"):
                i["hpass"], ch = secrets.token_hex(16), True
        if ch:
            save(S5DB, items)
        with open(SB_CONF, encoding="utf-8") as f:
            cfg = json.load(f)
        before = json.dumps(cfg, sort_keys=True)
        cfg["outbounds"] = [o for o in cfg.get("outbounds", []) if not str(o.get("tag", "")).startswith("s5-")]
        route = cfg.setdefault("route", {})
        inbs = [x for x in cfg["inbounds"] if x.get("type") in ("vless", "hysteria2")]
        tags = [x["tag"] for x in inbs]
        route["rules"] = [r for r in route.get("rules", [])
                          if not any(str(u).startswith("s5-") for u in r.get("auth_user", []))
                          and r.get("inbound") != tags]
        for ib in inbs:
            ib["users"] = [u for u in ib.get("users", []) if not str(u.get("name", "")).startswith("s5-")]
        for it in items:
            tag = "s5-" + it["id"]
            ob = {"type": "socks", "tag": tag, "server": it["server"],
                  "server_port": int(it["port"]), "version": "5"}
            if it.get("username"):
                ob["username"], ob["password"] = it["username"], it.get("password", "")
            if not it.get("udp", True):
                ob["network"] = "tcp"
            cfg["outbounds"].append(ob)
            route["rules"].append({"auth_user": [tag], "outbound": tag})
            for ib in inbs:
                if ib["type"] == "vless":
                    ib["users"].append({"name": tag, "uuid": it["uid"]})   # 不带流控，兼容小火箭
                else:
                    ib["users"].append({"name": tag, "password": it["hpass"]})
        # 前置节点（Clash 链式用的那个用户）只允许去配置好的 S5 地址，其余一律拒绝：
        # 任何人都没法把服务器本身当出口（出口永远不是服务器 IP），也碰不到服务器本机的服务
        ips, hosts, ports = [], ["www.gstatic.com"], set()   # gstatic：Clash 前置节点健康检查
        for it in items:
            ports.add(int(it["port"]))
            try:
                a = ipaddress.ip_address(it["server"])
                ips.append(f"{a}/{32 if a.version == 4 else 128}")
            except ValueError:
                hosts.append(it["server"])
        if ips and ports:
            route["rules"].append({"inbound": tags, "ip_cidr": ips, "port": sorted(ports), "outbound": "direct"})
        route["rules"].append({"inbound": tags, "domain": hosts, "outbound": "direct"})
        route["rules"].append({"inbound": tags, "action": "reject"})
        if json.dumps(cfg, sort_keys=True) == before:
            return "unchanged"
        tmp = SB_CONF + ".tmp"
        st = os.stat(SB_CONF)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
        os.chmod(tmp, st.st_mode & 0o777)
        try:
            os.chown(tmp, st.st_uid, st.st_gid)
        except (OSError, AttributeError):
            pass
        sb = shutil.which("sing-box") or "/usr/bin/sing-box"
        r = subprocess.run([sb, "check", "-c", tmp], capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            os.remove(tmp)
            return "error: sing-box 配置检查未通过 " + (r.stderr or r.stdout).strip()[:150]
        shutil.copy2(SB_CONF, SB_BAK)
        os.replace(tmp, SB_CONF)
        subprocess.run(["systemctl", "restart", "sing-box"], timeout=30)
        time.sleep(1.5)
        if subprocess.run(["systemctl", "is-active", "--quiet", "sing-box"]).returncode != 0:
            shutil.copy2(SB_BAK, SB_CONF)
            subprocess.run(["systemctl", "restart", "sing-box"], timeout=30)
            return "error: sing-box 启动失败，已还原原配置"
        return "ok"


def warn_of(r):
    return r if str(r).startswith("error") else None


def qr_data_uri(text):
    try:
        svg = subprocess.run(["qrencode", "-t", "SVG", "-m", "2", "-s", "6", "-o", "-", text],
                             capture_output=True, timeout=5, check=True).stdout
        return "data:image/svg+xml;base64," + base64.b64encode(svg).decode()
    except Exception:
        return ""


# ---------------------------------------------------------------- 家里电脑节点（frp）
def home_urls(b, h):
    if not b.get("domain"):
        return None, None
    base = f"https://{b['domain']}{b['panel_path']}/h/{h['dl_token']}"
    return base + "/setup.ps1", (base + "/frpc.zip" if os.path.exists(HOME_ZIP) else "")


def home_ps1(b, h):
    _, zip_url = home_urls(b, h)
    toml = f"""serverAddr = "{b['ip']}"
serverPort = {int(h['bind_port'])}
loginFailExit = false
auth.method = "token"
auth.token = "{h['token']}"
transport.tls.enable = true
transport.poolCount = 8
log.to = "console"
log.level = "warn"

[[proxies]]
name = "s5relay-home"
type = "tcp"
remotePort = {int(h['remote_port'])}
[proxies.plugin]
type = "socks5"
username = "{h['s5_user']}"
password = "{h['s5_pass']}"
"""
    return ('''# s5relay 家里电脑节点安装脚本（Windows）
# 用法：右键 → 使用 PowerShell 运行；或在 PowerShell 里：irm <链接> | iex
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Dir  = Join-Path $env:LOCALAPPDATA 's5relay-home'
$Exe  = Join-Path $Dir 'frpc.exe'
$Conf = Join-Path $Dir 'frpc.toml'
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Get-Process frpc -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Exe } | Stop-Process -Force

if (-not (Test-Path $Exe)) {
  Write-Host '[1/3] 下载 frpc ...'
  $zip = Join-Path $env:TEMP 's5relay-frp.zip'
  $urls = @()
  $mine = '__ZIP_URL__'
  if ($mine) { $urls += $mine }
  try {
    $rel = Invoke-RestMethod -Headers @{ 'User-Agent' = 's5relay' } 'https://api.github.com/repos/fatedier/frp/releases/latest'
    $gh = ($rel.assets | Where-Object { $_.name -like '*_windows_amd64.zip' } | Select-Object -First 1).browser_download_url
    if ($gh) { $urls += $gh; $urls += ('https://ghfast.top/' + $gh) }
  } catch {}
  $ok = $false
  foreach ($u in $urls) {
    try { Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $zip; $ok = $true; break } catch {}
  }
  if (-not $ok) { throw '下载 frpc 失败，请检查网络后重试' }
  $tmp = Join-Path $env:TEMP 's5relay-frp'
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  Expand-Archive -Force -Path $zip -DestinationPath $tmp
  $f = Get-ChildItem -Recurse -Path $tmp -Filter frpc.exe | Select-Object -First 1
  if (-not $f) { throw '压缩包里没找到 frpc.exe（可能被杀毒软件删除了）' }
  Copy-Item $f.FullName $Exe -Force
  Remove-Item -Recurse -Force $tmp, $zip -ErrorAction SilentlyContinue
} else {
  Write-Host '[1/3] frpc 已存在，跳过下载'
}

Write-Host '[2/3] 写入配置，设置开机自动运行'
$toml = @'
__TOML__'@
[IO.File]::WriteAllText($Conf, $toml, (New-Object Text.UTF8Encoding $false))
$Vbs = Join-Path ([Environment]::GetFolderPath('Startup')) 's5relay-home.vbs'
$line = 'CreateObject("WScript.Shell").Run """' + $Exe + '"" -c ""' + $Conf + '""", 0, False'
[IO.File]::WriteAllText($Vbs, $line, [Text.Encoding]::Unicode)   # 支持中文用户名路径

Write-Host '[3/3] 启动'
Start-Process -WindowStyle Hidden -FilePath $Exe -ArgumentList @('-c', $Conf)
Start-Sleep -Seconds 4
if (Get-Process frpc -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Exe }) {
  Write-Host ''
  Write-Host '完成！这台电脑已经连上服务器。' -ForegroundColor Green
  Write-Host '回到网页后台，对「家里电脑」点「测试」，看到出口 IP 就是这台电脑的网络。'
  Write-Host '以后开机登录后会自动在后台运行。停用：删除启动文件夹里的 s5relay-home.vbs 并结束 frpc 进程。'
} else {
  Write-Host 'frpc 没有运行起来：可能被 Windows 安全中心拦截了。' -ForegroundColor Yellow
  Write-Host '打开「Windows 安全中心 → 病毒和威胁防护 → 保护历史记录」，找到 frpc 选「允许」，再运行一次本脚本。'
}
'''
            .replace("__ZIP_URL__", zip_url or "")
            .replace("__TOML__", toml))


# ---------------------------------------------------------------- S5 校验 / 解析
HOST_RE = re.compile(r"^[A-Za-z0-9.\-]{1,253}$")


def clean_item(d, items):
    server = str(d.get("server", "")).strip()
    if not HOST_RE.match(server):
        raise ValueError("地址格式不对")
    try:
        port = int(str(d.get("port", "")).strip())
        assert 1 <= port <= 65535
    except Exception:
        raise ValueError("端口必须是 1-65535 的数字")
    user = str(d.get("username", "") or "").strip()
    pw = str(d.get("password", "") or "")
    if len(user) > 255 or len(pw) > 255 or "\n" in user + pw:
        raise ValueError("账号或密码太长")
    name = re.sub(r"[\r\n\t\"]", "", str(d.get("name", "") or "")).strip()[:40]
    if not name:
        name = f"S5-{len(items) + 1}"
    used = {i["name"] for i in items}
    base, n = name, 2
    while name in used:
        name, n = f"{base}-{n}", n + 1
    return {"id": secrets.token_hex(4), "name": name, "server": server, "port": port,
            "username": user, "password": pw if user else "", "udp": bool(d.get("udp", True)),
            "uid": str(uuid.uuid4()), "hpass": secrets.token_hex(16)}


def parse_line(line):
    s = line.strip()
    if not s or s.startswith("#"):
        return None
    s = re.sub(r"^socks5h?://", "", s, flags=re.I)
    user = pw = ""
    if "@" in s:
        cred, hp = s.rsplit("@", 1)
        user, _, pw = cred.partition(":")
        host, _, port = hp.rpartition(":")
    else:
        parts = re.split(r"[\s,|]+", s) if re.search(r"[\s,|]", s) else s.split(":")
        if len(parts) < 2:
            raise ValueError("格式不对")
        host, port = parts[0], parts[1]
        if len(parts) >= 3:
            user = parts[2]
        if len(parts) >= 4:
            pw = ":".join(parts[3:])
    return {"server": host, "port": port, "username": user, "password": pw}


# ---------------------------------------------------------------- 测试 S5（从服务器发起）
def recvn(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise ValueError("连接被对方关闭")
        buf += c
    return buf


def s5_test(it):
    t0 = time.time()
    try:
        s = socket.create_connection((it["server"], int(it["port"])), timeout=8)
    except Exception:
        return {"ok": False, "error": "连不上 S5 服务器（地址/端口错误或被封）"}
    try:
        s.settimeout(8)
        user = it.get("username", "").encode()
        s.sendall(b"\x05\x01\x02" if user else b"\x05\x01\x00")
        r = recvn(s, 2)
        if r[0] != 5:
            return {"ok": False, "error": "对方不是 SOCKS5"}
        if r[1] == 0xFF:
            return {"ok": False, "error": "S5 拒绝认证方式（可能需要账号密码，或只允许白名单 IP）"}
        if r[1] == 2:
            pw = it.get("password", "").encode()
            s.sendall(b"\x01" + bytes([len(user)]) + user + bytes([len(pw)]) + pw)
            if recvn(s, 2)[1] != 0:
                return {"ok": False, "error": "账号或密码错误"}
        host = b"api.ipify.org"
        s.sendall(b"\x05\x01\x00\x03" + bytes([len(host)]) + host + struct.pack(">H", 80))
        rep = recvn(s, 4)
        if rep[1] != 0:
            return {"ok": False, "error": f"S5 连接外网失败（代码 {rep[1]}）"}
        atyp = rep[3]
        recvn(s, {1: 4, 4: 16}.get(atyp) or recvn(s, 1)[0])
        recvn(s, 2)
        s.sendall(b"GET / HTTP/1.1\r\nHost: api.ipify.org\r\nConnection: close\r\n\r\n")
        data = b""
        while len(data) < 4096:
            try:
                c = s.recv(4096)
            except socket.timeout:
                if data:      # 经 frp 等隧道转发时对方可能不主动关连接，已收到数据就算完成
                    break
                raise
            if not c:
                break
            data += c
            head, sep, rest = data.partition(b"\r\n\r\n")
            if sep:           # 按 Content-Length 判断响应收完，不傻等对方关闭连接
                m = re.search(rb"(?i)content-length:\s*(\d+)", head)
                if m and len(rest) >= int(m.group(1)):
                    break
        ms = int((time.time() - t0) * 1000)
        body = data.split(b"\r\n\r\n", 1)[-1].decode(errors="ignore").strip()
        ip = body if re.match(r"^[0-9a-fA-F.:]{3,45}$", body) else ""
        return {"ok": True, "ms": ms, "ip": ip}
    except socket.timeout:
        return {"ok": False, "error": "超时"}
    except Exception as e:
        return {"ok": False, "error": str(e)[:80]}
    finally:
        s.close()


# ---------------------------------------------------------------- 登录
def hash_pw(pw, salt):
    return hashlib.pbkdf2_hmac("sha256", pw.encode(), bytes.fromhex(salt), 200_000).hex()


def set_password(pw):
    with LOCK:
        salt = secrets.token_hex(16)
        save(AUTH, {"salt": salt, "hash": hash_pw(pw, salt), "secret": secrets.token_hex(32)})


def check_pw(pw):
    a = load(AUTH, None)
    return bool(a) and hmac.compare_digest(hash_pw(pw, a["salt"]), a["hash"])


def make_session():
    a = load(AUTH, {})
    exp = str(int(time.time()) + 12 * 3600)
    return exp + "." + hmac.new(a["secret"].encode(), exp.encode(), hashlib.sha256).hexdigest()


def valid_session(tok):
    try:
        exp, sig = tok.split(".")
        a = load(AUTH, {})
        good = hmac.new(a["secret"].encode(), exp.encode(), hashlib.sha256).hexdigest()
        return hmac.compare_digest(sig, good) and int(exp) > time.time()
    except Exception:
        return False


def locked(ip):
    c = FAILS.get(ip)
    if c and time.time() - c[1] > 900:
        FAILS.pop(ip, None)
        return False
    return bool(c) and c[0] >= 5


def fail(ip):
    c = FAILS.setdefault(ip, [0, time.time()])
    c[0] += 1


# ---------------------------------------------------------------- 网页
PAGE = r"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>s5relay 后台</title>
<style>
:root{--bg:#f4f5f7;--card:#fff;--fg:#1d2129;--mut:#6b7280;--line:#e5e7eb;--pri:#2563eb;--ok:#16a34a;--bad:#dc2626;--in:#fff}
@media(prefers-color-scheme:dark){:root{--bg:#111318;--card:#1b1e25;--fg:#e6e8eb;--mut:#9aa1ab;--line:#2c313a;--pri:#4f8cff;--ok:#22c55e;--bad:#f87171;--in:#14171c}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif}
.wrap{max-width:960px;margin:0 auto;padding:16px}
header{display:flex;justify-content:space-between;align-items:center;margin:4px 0 16px}
h1{font-size:20px;margin:0}h2{font-size:15px;margin:0 0 12px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;margin-bottom:14px}
input,textarea{width:100%;padding:8px 10px;border:1px solid var(--line);border-radius:6px;background:var(--in);color:var(--fg);font:inherit}
textarea{min-height:90px;font-family:ui-monospace,Consolas,monospace;font-size:13px}
button{padding:8px 14px;border:0;border-radius:6px;background:var(--pri);color:#fff;font:inherit;cursor:pointer;white-space:nowrap}
button.g{background:transparent;color:var(--fg);border:1px solid var(--line)}button.r{background:var(--bad)}
button:disabled{opacity:.5}
.row{display:flex;gap:8px;align-items:center}.row>*{flex:1}.row>button{flex:none}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:8px;margin-bottom:8px}
label.ck{display:flex;align-items:center;gap:6px;color:var(--mut)}label.ck input{width:auto}
.mut{color:var(--mut);font-size:12px}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:8px 6px;border-bottom:1px solid var(--line);vertical-align:middle}
th{color:var(--mut);font-weight:500;font-size:12px}td.act{white-space:nowrap;text-align:right}td.act button{padding:5px 10px;margin-left:4px}
.ok{color:var(--ok)}.bad{color:var(--bad)}
.tw{overflow-x:auto}
#login{max-width:360px;margin:12vh auto}
#toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);background:#111;color:#fff;padding:8px 16px;border-radius:6px;display:none;z-index:9}
.hide{display:none}
code{background:var(--bg);padding:1px 5px;border-radius:4px;font-size:12px}
.qrs{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px;margin-bottom:8px}
.qr{border:1px solid var(--line);border-radius:8px;padding:12px;text-align:center}
.qr img{width:240px;height:240px;max-width:100%;background:#fff;border-radius:6px;image-rendering:pixelated}
.qr b{display:block;margin-bottom:8px}.qr button{margin-top:8px}
</style></head><body>
<div id="login" class="card hide">
  <h2>s5relay 后台登录</h2>
  <div class="row"><input id="pw" type="password" placeholder="后台密码" autocomplete="current-password"><button id="bLogin">登录</button></div>
  <p class="mut" id="lerr"></p>
</div>
<div id="app" class="wrap hide">
  <header><h1>s5relay 后台</h1><button class="g" id="bOut">退出</button></header>

  <div class="card">
    <h2>订阅链接</h2>
    <div class="row"><input id="sub" readonly><button id="bCopy">复制</button><button class="g" id="bRot">换新链接</button></div>
    <p class="mut" id="subHint"></p>
  </div>

  <div class="card">
    <div class="row" style="margin-bottom:8px"><h2 style="margin:0">扫码 / 分享</h2><button class="g" id="bShare">显示</button></div>
    <div id="shareBox" class="hide">
      <div class="qrs" id="qrs"></div>
      <div class="row" style="margin-bottom:8px"><span></span><button class="g" id="bMore">展开单个节点链接</button></div>
      <div class="qrs hide" id="qrs2"></div>
      <p class="mut">通用订阅：小火箭 / v2rayN / NekoBox 扫一次，导入全部「出口 S5」节点，出口是对应的 S5。<br>
      Clash 订阅：Clash 系客户端（FlClash / Stash / Clash Meta）扫码，包含全部 S5 和链式加速。<br>
      「出口 xxx」节点：服务器按用户把流量转给对应的 S5，出口一定是那个 S5，不会是服务器 IP。<br>
      ⚠ 拿到这些的人就能用你的服务器，只给自己的设备用。泄露了重新运行安装命令即可全部换新。</p>
    </div>
  </div>

  <div class="card">
    <h2>添加 S5</h2>
    <div class="grid">
      <input id="fName" placeholder="名称（可留空）"><input id="fServer" placeholder="地址 *">
      <input id="fPort" placeholder="端口 *" inputmode="numeric"><input id="fUser" placeholder="账号（可空）">
      <input id="fPass" placeholder="密码（可空）" type="password" autocomplete="new-password">
    </div>
    <div class="row"><label class="ck"><input type="checkbox" id="fUdp" checked> 支持 UDP</label><button id="bAdd">添加</button></div>
    <h2 style="margin-top:16px">批量导入</h2>
    <textarea id="bulk" placeholder="一行一个，支持这些格式：&#10;1.2.3.4:1080&#10;1.2.3.4:1080:账号:密码&#10;账号:密码@1.2.3.4:1080&#10;socks5://账号:密码@1.2.3.4:1080"></textarea>
    <div class="row" style="margin-top:8px"><span class="mut">导入后自动按 S5-序号 命名</span><button id="bBulk">导入</button></div>
  </div>

  <div class="card">
    <div class="row" style="margin-bottom:8px"><h2 style="margin:0">S5 列表（<span id="cnt">0</span>）</h2><button class="g" id="bTestAll">全部测试</button></div>
    <div class="tw"><table><thead><tr><th>名称</th><th>地址</th><th>账号</th><th>UDP</th><th>测试（从服务器）</th><th></th></tr></thead><tbody id="list"></tbody></table></div>
    <p class="mut">每个 S5 在 Clash 里会出现两个：「名称-直连」和「名称-加速」（经你的服务器中转）。</p>
  </div>

  <div class="card" id="homeCard">
    <h2>家里电脑节点</h2>
    <div id="homeOff" class="mut">还没开启。在服务器上运行安装命令后面加 <b>home</b>（例如 <code>bash &lt;(curl -fsSL …/install.sh) home</code>），刷新本页即可。</div>
    <div id="homeOn" class="hide">
      <p class="mut">在<b>家里的 Windows 电脑</b>上做下面任意一种（不需要管理员权限）：</p>
      <div id="homeCmdRow"><p style="margin:4px 0">① 打开 PowerShell，粘贴运行：</p>
        <div class="row"><input id="homeCmd" readonly><button id="bHomeCopy">复制</button></div></div>
      <p style="margin:10px 0 4px">② 下载脚本 → 右键 →「使用 PowerShell 运行」：</p>
      <button class="g" id="bHomeDl">下载 家里电脑节点.ps1</button>
      <p class="mut">运行后在上面 S5 列表里对「家里电脑」点「测试」，显示出口 IP 就成功了。Clash 里选「家里电脑-加速」即可从外面经服务器用家里的网络。这个命令里含密钥，不要发给别人。</p>
    </div>
  </div>

  <div class="card">
    <h2>修改后台密码</h2>
    <div class="grid"><input id="pOld" type="password" placeholder="原密码"><input id="pNew" type="password" placeholder="新密码（至少 8 位）" autocomplete="new-password"></div>
    <div class="row"><span></span><button id="bPw">修改</button></div>
  </div>
</div>
<div id="toast"></div>
<script nonce="__NONCE__">
const BASE = "__BASE__";
const $ = id => document.getElementById(id);
let items = [];
function toast(m){const t=$('toast');t.textContent=m;t.style.display='block';clearTimeout(t._h);t._h=setTimeout(()=>t.style.display='none',2600)}
async function api(p, body){
  const r = await fetch(BASE+'/api/'+p,{method:body?'POST':'GET',credentials:'same-origin',
    headers:{'Content-Type':'application/json','X-S5R':'1'},body:body?JSON.stringify(body):undefined});
  let j={}; try{j=await r.json()}catch(e){}
  if(r.status===401){show(false);throw new Error(j.error||'请先登录')}
  if(!r.ok) throw new Error(j.error||('出错了 '+r.status));
  if(j.warn) toast(j.warn);
  return j;
}
function show(logged){$('login').classList.toggle('hide',logged);$('app').classList.toggle('hide',!logged);if(!logged)$('pw').focus()}
function td(text,cls){const e=document.createElement('td');e.textContent=text;if(cls)e.className=cls;return e}
function btn(text,cls,fn){const b=document.createElement('button');b.textContent=text;if(cls)b.className=cls;b.onclick=fn;return b}
function draw(){
  const tb=$('list');tb.replaceChildren();$('cnt').textContent=items.length;
  if(!items.length){const tr=document.createElement('tr');const c=td('还没有 S5，在上面添加','mut');c.colSpan=6;tr.append(c);tb.append(tr);return}
  for(const it of items){
    const tr=document.createElement('tr');
    const res=td(it._t||'—',it._c||'mut');res.id='r'+it.id;
    const act=document.createElement('td');act.className='act';
    act.append(btn('测试','g',()=>test(it)),btn('删除','r',()=>del(it)));
    tr.append(td(it.name),td(it.server+':'+it.port),td(it.username||'—'),td(it.udp?'✓':'✗'),res,act);
    tb.append(tr);
  }
}
async function refresh(){const j=await api('list');items=j.items;$('sub').value=j.sub_url;
  $('homeOff').classList.toggle('hide',!!j.home);$('homeOn').classList.toggle('hide',!j.home);
  if(j.home){$('homeCmdRow').classList.toggle('hide',!j.home.cmd);$('homeCmd').value=j.home.cmd||''}
  $('subHint').textContent='Clash Verge → 订阅 → 新建 → Remote → 粘贴'+(j.domain?'':'，打开「允许危险证书」')+'。在这里改了 S5 后，Clash 里点一下「更新」就生效。链接泄露了就点「换新链接」。';
  draw();show(true)}
function qrCard(name,link,qr){
  const d=document.createElement('div');d.className='qr';
  const b=document.createElement('b');b.textContent=name;d.append(b);
  if(qr){const i=document.createElement('img');i.src=qr;i.alt=name;d.append(i)}
  else{const m=document.createElement('p');m.className='mut';m.textContent='二维码生成失败，请复制链接';d.append(m)}
  d.append(document.createElement('br'),btn('复制链接','g',async()=>{try{await navigator.clipboard.writeText(link);toast('已复制')}catch(e){prompt('手动复制：',link)}}));
  return d;
}
$('bShare').onclick=async()=>{
  const box=$('shareBox');
  if(!box.classList.contains('hide')){hideShare();return}
  try{const j=await api('share');$('qrs').replaceChildren(...j.items.map(x=>qrCard(x.name,x.link,x.qr)));
    box.classList.remove('hide');$('bShare').textContent='隐藏'}catch(e){toast(e.message)}};
function hideShare(){$('shareBox').classList.add('hide');$('qrs').replaceChildren();$('qrs2').replaceChildren();
  $('qrs2').classList.add('hide');$('bMore').textContent='展开单个节点链接';$('bShare').textContent='显示'}
$('bMore').onclick=async()=>{
  const q=$('qrs2');
  if(!q.classList.contains('hide')){q.classList.add('hide');q.replaceChildren();$('bMore').textContent='展开单个节点链接';return}
  try{const j=await api('share?more=1');q.replaceChildren(...j.items.map(x=>qrCard(x.name,x.link,x.qr)));
    q.classList.remove('hide');$('bMore').textContent='收起单个节点链接'}catch(e){toast(e.message)}};
async function test(it){
  const c=$('r'+it.id);if(c){c.textContent='测试中…';c.className='mut'}
  try{const j=await api('test',{id:it.id});
    it._t=j.ok?(j.ms+' ms'+(j.ip?'  出口 '+j.ip:'')):j.error;it._c=j.ok?'ok':'bad';
  }catch(e){it._t=e.message;it._c='bad'}
  draw();
}
async function del(it){if(!confirm('删除 '+it.name+' ？'))return;try{await api('delete',{id:it.id});toast('已删除');refresh()}catch(e){toast(e.message)}}
$('bLogin').onclick=async()=>{try{await api('login',{password:$('pw').value});$('pw').value='';$('lerr').textContent='';refresh()}catch(e){$('lerr').textContent=e.message}};
$('pw').onkeydown=e=>{if(e.key==='Enter')$('bLogin').click()};
$('bOut').onclick=async()=>{await api('logout',{}).catch(()=>{});show(false)};
$('bCopy').onclick=async()=>{try{await navigator.clipboard.writeText($('sub').value);toast('已复制')}catch(e){$('sub').select();toast('请手动复制')}};
$('bRot').onclick=async()=>{if(!confirm('换新链接后，旧链接立即失效，Clash 里要重新导入。继续？'))return;try{await api('rotate',{});toast('已换新链接');hideShare();refresh()}catch(e){toast(e.message)}};
$('bAdd').onclick=async()=>{
  try{await api('add',{name:$('fName').value,server:$('fServer').value,port:$('fPort').value,username:$('fUser').value,password:$('fPass').value,udp:$('fUdp').checked});
    for(const k of ['fName','fServer','fPort','fUser','fPass'])$(k).value='';toast('已添加');refresh()}catch(e){toast(e.message)}};
$('bBulk').onclick=async()=>{try{const j=await api('bulk',{text:$('bulk').value});$('bulk').value='';toast('导入 '+j.added+' 个'+(j.errors.length?'，失败 '+j.errors.length+' 行：'+j.errors.slice(0,3).join('；'):''));refresh()}catch(e){toast(e.message)}};
$('bTestAll').onclick=async()=>{const b=$('bTestAll');b.disabled=true;await Promise.all(items.map(test));b.disabled=false};
$('bHomeCopy').onclick=async()=>{try{await navigator.clipboard.writeText($('homeCmd').value);toast('已复制')}catch(e){$('homeCmd').select();toast('请手动复制')}};
$('bHomeDl').onclick=async()=>{try{const r=await fetch(BASE+'/api/home-script',{headers:{'X-S5R':'1'},credentials:'same-origin'});
  if(!r.ok)throw new Error('下载失败 '+r.status);const u=URL.createObjectURL(await r.blob());const a=document.createElement('a');
  a.href=u;a.download='家里电脑节点.ps1';document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(u),5000)}catch(e){toast(e.message)}};
$('bPw').onclick=async()=>{try{await api('passwd',{old:$('pOld').value,new:$('pNew').value});$('pOld').value=$('pNew').value='';toast('密码已修改，请重新登录');show(false)}catch(e){toast(e.message)}};
refresh().catch(()=>show(false));
</script></body></html>"""


class H(BaseHTTPRequestHandler):
    server_version = "nginx"
    sys_version = ""
    timeout = 20
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    # ---- 工具
    def ip(self):
        if self.client_address[0] == "127.0.0.1" and self.headers.get("X-Real-IP"):
            return self.headers["X-Real-IP"]
        return self.client_address[0]

    def send(self, code, body=b"", ctype="application/json; charset=utf-8", extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def nf(self):
        self.send(404, "404 Not Found", "text/plain")

    def authed(self):
        c = SimpleCookie(self.headers.get("Cookie", ""))
        return "s5r" in c and valid_session(c["s5r"].value)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 512 * 1024:
            raise ValueError("内容太大")
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            raise ValueError("请求格式错误")

    def sub_url(self, b):
        if b.get("domain"):
            return f"https://{b['domain']}{b['panel_path']}/s/{b['sub_token']}"
        return f"https://{b['ip']}:{b['web_port']}/{b['sub_token']}"

    def sub_url_u(self, b):   # 通用订阅（小火箭等）
        host = b["domain"] if b.get("domain") else f"{b['ip']}:{b['web_port']}"
        return f"https://{host}{b['panel_path']}/u/{b['sub_token']}"

    # ---- 路由
    def do_GET(self):
        b = load(BASE, {})
        path = self.path.split("?")[0]
        P = b.get("panel_path", "/\0")
        h = load(HOME, None)
        if h and path.startswith(P + "/h/"):     # 家里电脑脚本 / 安装包（带随机密钥）
            rest = path[len(P) + 3:]
            if hmac.compare_digest(rest, h["dl_token"] + "/setup.ps1"):
                return self.send(200, home_ps1(b, h), "text/plain; charset=utf-8")
            if hmac.compare_digest(rest, h["dl_token"] + "/frpc.zip") and os.path.exists(HOME_ZIP):
                with open(HOME_ZIP, "rb") as f:
                    return self.send(200, f.read(), "application/zip")
            return self.nf()
        tok = b.get("sub_token")
        if tok and hmac.compare_digest(path, P + "/u/" + tok):
            return self.send(200, universal_sub(b, load(S5DB, [])), "text/plain; charset=utf-8",
                             {"profile-update-interval": "24"})
        if tok and (hmac.compare_digest(path, "/" + tok) or hmac.compare_digest(path, P + "/s/" + tok)):
            text = render()
            return self.send(200, text, "text/yaml; charset=utf-8", {
                "Content-Disposition": "attachment; filename=s5relay.yaml",
                "profile-update-interval": "24"})
        if path == P:
            return self.send(302, "", "text/plain", {"Location": P + "/"})
        if path == P + "/":
            nonce = secrets.token_urlsafe(16)
            page = PAGE.replace("__NONCE__", nonce).replace("__BASE__", P)
            return self.send(200, page, "text/html; charset=utf-8", {
                "Content-Security-Policy": f"default-src 'none'; script-src 'nonce-{nonce}'; "
                f"style-src 'unsafe-inline'; img-src data:; connect-src 'self'; form-action 'none'; "
                "frame-ancestors 'none'; base-uri 'none'",
                "X-Frame-Options": "DENY"})
        if path == P + "/api/list":
            if not self.authed():
                return self.send(401, {"error": "请先登录"})
            items = [{k: v for k, v in i.items() if k != "password"} for i in load(S5DB, [])]
            h = load(HOME, None)
            home = None
            if h:
                ps1_url, _ = home_urls(b, h)
                home = {"cmd": f"irm {ps1_url} | iex" if ps1_url else ""}
            return self.send(200, {"items": items, "sub_url": self.sub_url(b),
                                   "domain": bool(b.get("domain")), "home": home})
        if path == P + "/api/home-script":
            if not self.authed():
                return self.send(401, {"error": "请先登录"})
            h = load(HOME, None)
            if not h:
                return self.nf()
            return self.send(200, home_ps1(b, h).encode("utf-8-sig"), "application/octet-stream",
                             {"Content-Disposition": "attachment; filename=s5relay-home.ps1"})
        if path == P + "/api/share":
            if not self.authed():
                return self.send(401, {"error": "请先登录"})
            if "more=1" in self.path:      # 单个节点链接（按需生成，避免一次太多二维码）
                out = share_s5(b, load(S5DB, []))
            else:                          # 默认只给两个二维码：扫一次导入全部
                out = [("通用订阅 · 小火箭 / v2rayN / NekoBox 扫这个（全部节点）", self.sub_url_u(b)),
                       ("Clash 订阅 · Clash 系客户端扫这个（链式加速）", self.sub_url(b))]
            return self.send(200, {"items": [{"name": n, "link": l, "qr": qr_data_uri(l)} for n, l in out]})
        return self.nf()

    def do_POST(self):
        b = load(BASE, {})
        P = b.get("panel_path", "/\0")
        path = self.path.split("?")[0]
        if not path.startswith(P + "/api/"):
            return self.nf()
        if self.headers.get("X-S5R") != "1":      # 防跨站伪造请求
            return self.send(403, {"error": "forbidden"})
        act = path[len(P) + 5:]
        try:
            d = self.body()
        except ValueError as e:
            return self.send(400, {"error": str(e)})

        if act == "login":
            if locked(self.ip()):
                return self.send(429, {"error": "密码错误次数太多，15 分钟后再试"})
            if not check_pw(str(d.get("password", ""))):
                fail(self.ip())
                time.sleep(1)
                return self.send(401, {"error": "密码错误"})
            FAILS.pop(self.ip(), None)
            return self.send(200, {"ok": True}, extra={
                "Set-Cookie": f"s5r={make_session()}; Path={P}; HttpOnly; Secure; SameSite=Strict; Max-Age=43200"})
        if act == "logout":
            return self.send(200, {"ok": True}, extra={
                "Set-Cookie": f"s5r=; Path={P}; HttpOnly; Secure; SameSite=Strict; Max-Age=0"})

        if not self.authed():
            return self.send(401, {"error": "请先登录"})
        try:
            with LOCK:
                items = load(S5DB, [])
                if act == "add":
                    items.append(clean_item(d, items))
                    save(S5DB, items); render()
                    return self.send(200, {"ok": True, "warn": warn_of(sync_singbox())})
                if act == "bulk":
                    added, errors = 0, []
                    for n, line in enumerate(str(d.get("text", "")).splitlines()[:2000], 1):
                        try:
                            p = parse_line(line)
                            if p:
                                items.append(clean_item(p, items)); added += 1
                        except ValueError as e:
                            errors.append(f"第{n}行{e}")
                    save(S5DB, items); render()
                    return self.send(200, {"added": added, "errors": errors, "warn": warn_of(sync_singbox())})
                if act == "delete":
                    items = [i for i in items if i["id"] != d.get("id")]
                    save(S5DB, items); render()
                    return self.send(200, {"ok": True, "warn": warn_of(sync_singbox())})
                if act == "rotate":
                    b["sub_token"] = secrets.token_hex(24)
                    save(BASE, b)
                    return self.send(200, {"ok": True})
                if act == "passwd":
                    if not check_pw(str(d.get("old", ""))):
                        return self.send(400, {"error": "原密码错误"})
                    new = str(d.get("new", ""))
                    if len(new) < 8:
                        return self.send(400, {"error": "新密码至少 8 位"})
                    set_password(new)
                    return self.send(200, {"ok": True})
            if act == "test":
                it = next((i for i in load(S5DB, []) if i["id"] == d.get("id")), None)
                if not it:
                    return self.send(404, {"error": "找不到这个 S5"})
                return self.send(200, s5_test(it))
        except ValueError as e:
            return self.send(400, {"error": str(e)})
        return self.nf()


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):  # 扫描器、坏握手：静默
        pass


def serve():
    b = load(BASE, {})
    if b.get("domain"):   # 挂在网站 nginx 后面：只监听本机，HTTPS 由 nginx 负责
        srv = Server(("127.0.0.1", int(b["web_port"])), H)
    else:
        srv = Server(("0.0.0.0", int(b["web_port"])), H)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(os.path.join(DIR, "web-cert.pem"), os.path.join(DIR, "web-key.pem"))
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True, do_handshake_on_connect=False)
    render()
    srv.serve_forever()


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "serve":
        serve()
    elif cmd == "render":
        render()
    elif cmd == "add":
        a = sys.argv[2:] + ["", "", "", "", ""]
        with LOCK:
            items = load(S5DB, [])
            new = clean_item({"name": a[0], "server": a[1], "port": a[2],
                              "username": a[3], "password": a[4],
                              "udp": a[5] != "noudp"}, items)
            same = [i for i in items if (i["server"], i["port"], i["username"]) ==
                    (new["server"], new["port"], new["username"])]
            if same:   # 重复安装时不重复添加，只更新密码
                same[0]["password"] = new["password"]
                same[0]["udp"] = new["udp"]
            else:
                items.append(new)
            save(S5DB, items)
        render()
        r = sync_singbox()
        if r.startswith("error"):
            print(r)
    elif cmd == "del-local":
        with LOCK:
            save(S5DB, [i for i in load(S5DB, []) if i["server"] not in LOCAL_HOSTS])
        render()
        r = sync_singbox()
        if r.startswith("error"):
            print(r)
    elif cmd == "sync-sb":
        r = sync_singbox()
        if r.startswith("error"):
            print(r)
    elif cmd == "passwd":
        pw = secrets.token_urlsafe(12)
        set_password(pw)
        print(pw)
    else:
        print(__doc__ or "用法: serve | render | add | passwd")
        sys.exit(1)
PYEOF
chmod 700 "$APP"

# 写入节点信息；保留已有的 S5 列表、后台密码和后台地址，订阅链接每次换新
IP="$IP" REALITY_PORT="$REALITY_PORT" HY2_PORT="$HY2_PORT" WEB_PORT="$WEB_PORT" \
UUID="$UUID" PUB_KEY="$PUB_KEY" SHORT_ID="$SHORT_ID" HY2_PASS="$HY2_PASS" SNI="$SNI" DOMAIN="$DOMAIN" \
python3 - "$DATA/base.json" <<'PYEOF'
import json, os, secrets, sys
p = sys.argv[1]
try:
    old = json.load(open(p))
except Exception:
    old = {}
e = os.environ
b = {"ip": e["IP"], "reality_port": int(e["REALITY_PORT"]), "hy2_port": int(e["HY2_PORT"]),
     "web_port": int(e["WEB_PORT"]), "uuid": e["UUID"], "pub_key": e["PUB_KEY"],
     "short_id": e["SHORT_ID"], "hy2_pass": e["HY2_PASS"], "sni": e["SNI"],
     "domain": e.get("DOMAIN") or None,
     "sub_token": secrets.token_hex(24),
     "panel_path": old.get("panel_path") or "/admin-" + secrets.token_hex(8)}
with open(p + ".tmp", "w") as f:
    json.dump(b, f, indent=2)
os.chmod(p + ".tmp", 0o600)
os.replace(p + ".tmp", p)
PYEOF

[ -f "$DATA/s5.json" ] || echo "[]" > "$DATA/s5.json"
chmod 600 "$DATA/s5.json"
if [ -n "$S5_SERVER" ]; then
  S5R_DIR=$DATA python3 "$APP" add "" "$S5_SERVER" "$S5_PORT" "$S5_USER" "$S5_PASS"
fi
NEWPW=""
if [ ! -f "$DATA/auth.json" ]; then
  NEWPW=$(S5R_DIR=$DATA python3 "$APP" passwd)
fi
S5R_DIR=$DATA python3 "$APP" render
S5R_DIR=$DATA python3 "$APP" sync-sb || true   # 每个 S5 的专用入口（给小火箭等不支持链式代理的客户端）
ln -sf "$DATA/clash.yaml" /root/clash.yaml

PANEL=$(python3 -c "import json;print(json.load(open('$DATA/base.json'))['panel_path'])")
TOKEN=$(python3 -c "import json;print(json.load(open('$DATA/base.json'))['sub_token'])")

echo ">>> [6/6] 启动网页后台"
WEB_OK=n
if [ "$WEB" = y ]; then
  if [ -z "$DOMAIN" ]; then
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$DATA/web-key.pem" -out "$DATA/web-cert.pem" \
      -subj "/CN=${IP}" -addext "subjectAltName=IP:${IP}" -days 3650 >/dev/null 2>&1
    chmod 600 "$DATA"/web-*.pem
  fi
  cat > /etc/systemd/system/s5relay-web.service <<EOF
[Unit]
Description=s5relay web panel and subscription
After=network.target

[Service]
Environment=S5R_DIR=${DATA}
ExecStart=/usr/bin/python3 ${APP} serve
Restart=always
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${DATA} ${CONF_DIR}
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now s5relay-web >/dev/null 2>&1
  sleep 1
  if systemctl is-active --quiet s5relay-web; then WEB_OK=y
  else echo "    网页后台启动失败：journalctl -u s5relay-web -n 30"; fi
fi

if [ "$WEB_OK" = y ] && [ -n "$DOMAIN" ]; then
  echo "    把后台入口挂到网站 https://${DOMAIN}${PANEL}/"
  cat > "$INC" <<EOF
location ^~ ${PANEL}/ {
    proxy_pass http://127.0.0.1:${WEB_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_http_version 1.1;
    proxy_read_timeout 60s;
    access_log off;
}
location = ${PANEL} { return 302 ${PANEL}/; }
EOF
  cp "$BT_CONF" "$DATA/site.conf.bak"
  python3 - "$BT_CONF" "$INC" <<'PYEOF'
import re, sys
path, inc = sys.argv[1], sys.argv[2]
s = open(path, encoding="utf-8").read()
if "# s5relay" not in s:
    lines = s.split("\n")
    for i, l in enumerate(lines):
        if re.match(r"\s*server_name\s", l):
            lines.insert(i + 1, f"    include {inc}; # s5relay")
            break
    else:
        sys.exit("网站配置里找不到 server_name")
    open(path, "w", encoding="utf-8").write("\n".join(lines))
PYEOF
  if "$BT_NGINX" -t >/dev/null 2>&1; then
    "$BT_NGINX" -s reload
    sleep 1
    CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}${PANEL}/" || true)
    [ "$CODE" = 200 ] || echo "    提醒：本机测试后台返回 $CODE，若打不开请看宝塔网站设置里是否开了「强制 HTTPS」以外的拦截规则"
  else
    cp "$DATA/site.conf.bak" "$BT_CONF"
    rm -f "$INC"
    WEB_OK=n
    echo "    nginx 配置测试没通过，已自动还原网站配置（网站不受影响），后台未挂载"
  fi
fi

echo
echo "========================== 安装完成 =========================="
if [ "$WEB_OK" = y ] && [ -n "$DOMAIN" ]; then
  echo
  echo " 【网页后台】"
  echo "   https://${DOMAIN}${PANEL}/"
elif [ "$WEB_OK" = y ]; then
  echo
  echo " 【网页后台】（浏览器提示不安全 → 高级 → 继续访问，是自签名证书）"
  echo "   https://${IP}:${WEB_PORT}${PANEL}/"
fi
if [ "$WEB_OK" = y ]; then
  if [ -n "$NEWPW" ]; then
    echo "   后台密码：${NEWPW}"
  else
    echo "   后台密码：沿用原来的（忘了运行：bash <(curl -fsSL ${RAW}) reset-pass）"
  fi
  echo
  echo " 【订阅链接】（不要发给别人）"
  if [ -n "$DOMAIN" ]; then
    echo "   https://${DOMAIN}${PANEL}/s/${TOKEN}"
    echo "   Clash Verge → 订阅 → 新建 → Remote → 粘贴 → 保存（正规证书，不用开「允许危险证书」）"
    SUB_SHOW="https://${DOMAIN}${PANEL}/s/${TOKEN}"
  else
    echo "   https://${IP}:${WEB_PORT}/${TOKEN}"
    echo "   Clash Verge → 订阅 → 新建 → Remote → 粘贴 → 打开「允许危险证书」→ 保存"
    SUB_SHOW="https://${IP}:${WEB_PORT}/${TOKEN}"
  fi
else
  echo
  echo " 网页后台未开启。在你自己电脑的 PowerShell / 终端运行，下载配置："
  echo "   scp root@${IP}:/root/clash.yaml ~/Desktop/clash.yaml"
fi
echo
if [ -n "$DOMAIN" ]; then
  echo " 伪装：Reality / Hysteria2 被探测时都显示你的网站 https://${DOMAIN}"
fi
if [ -n "${SUB_SHOW:-}" ] && command -v qrencode >/dev/null && [ -r /dev/tty ]; then
  read -rp " 在这里显示订阅二维码（手机扫码导入）？[y/N]: " SHOWQR </dev/tty || true
  case "${SHOWQR:-n}" in [yY]*) qrencode -t ANSIUTF8 -m 2 "$SUB_SHOW" ;; esac
  echo " （网页后台「扫码 / 分享」里也能看到订阅和前置节点的二维码）"
fi
echo " 云服务器安全组 和 宝塔「安全」页 都要放行：TCP ${OPEN_TCP// /、TCP }、UDP ${HY2_PORT}"
echo "=============================================================="
