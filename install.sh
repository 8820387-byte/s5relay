#!/usr/bin/env bash
# ================================================================
#  s5relay：把 VPS 搭成前置代理，加速 SOCKS5，输出 Clash 订阅链接
#  用法（交互输入 S5 信息）：
#    bash <(curl -fsSL https://raw.githubusercontent.com/<用户名>/s5relay/main/install.sh)
#  用法（直接带参数）：
#    bash <(curl -fsSL .../install.sh) S5地址 端口 [账号] [密码]
#  卸载：
#    bash <(curl -fsSL .../install.sh) uninstall
# ================================================================
set -euo pipefail

if [ "${1:-}" = "uninstall" ]; then
  systemctl disable --now sing-box clash-sub 2>/dev/null || true
  rm -rf /etc/sing-box /var/lib/clash-sub /etc/systemd/system/clash-sub.service
  systemctl daemon-reload
  echo "已卸载"; exit 0
fi

S5_SERVER="${1:-${S5_SERVER:-}}"
S5_PORT="${2:-${S5_PORT:-}}"
S5_USER="${3:-${S5_USER:-}}"
S5_PASS="${4:-${S5_PASS:-}}"
if [ -z "$S5_SERVER" ]; then
  read -rp "S5 地址: " S5_SERVER </dev/tty
  read -rp "S5 端口: " S5_PORT </dev/tty
  read -rp "S5 账号（没有直接回车）: " S5_USER </dev/tty
  if [ -n "$S5_USER" ]; then read -rp "S5 密码: " S5_PASS </dev/tty; fi
fi
[ -n "$S5_SERVER" ] && [ -n "$S5_PORT" ] || { echo "S5 地址和端口不能为空"; exit 1; }

REALITY_PORT="${REALITY_PORT:-443}"   # 被占用时会自动换
HY2_PORT="${HY2_PORT:-8443}"           # Hysteria2 用 UDP
SUB_PORT="${SUB_PORT:-8443}"           # 订阅链接用 TCP
SNI=www.microsoft.com
CONF_DIR=/etc/sing-box
SUB_DIR=/var/lib/clash-sub

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }

echo ">>> [1/5] 安装依赖"
apt-get update -y >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl ca-certificates python3 iproute2 >/dev/null

echo ">>> [2/5] 安装 sing-box"
if ! command -v sing-box >/dev/null; then
  curl -fsSL https://sing-box.app/install.sh | sh >/dev/null
fi
command -v sing-box >/dev/null || { echo "sing-box 安装失败"; exit 1; }
systemctl stop sing-box clash-sub 2>/dev/null || true

tcp_busy() { ss -ltnH | awk '{print $4}' | grep -qE "[:.]$1\$"; }
udp_busy() { ss -lunH | awk '{print $4}' | grep -qE "[:.]$1\$"; }
pick_port() {   # pick_port tcp|udp 首选端口 备选...
  local proto=$1; shift
  for p in "$@"; do
    if [ "$proto" = tcp ]; then tcp_busy "$p" || { echo "$p"; return; }
    else udp_busy "$p" || { echo "$p"; return; }; fi
  done
  echo "端口 $* 全被占用" >&2; exit 1
}
OLD=$REALITY_PORT
REALITY_PORT=$(pick_port tcp "$REALITY_PORT" 2443 2053 2083 2087 2096 9443)
[ "$OLD" = "$REALITY_PORT" ] || echo "    TCP $OLD 被占用（$(ss -ltnpH "sport = :$OLD" | grep -o '"[^"]*"' | head -1 | tr -d '"')），自动改用 $REALITY_PORT"
OLD=$SUB_PORT
SUB_PORT=$(pick_port tcp "$SUB_PORT" 18443 28443 38443)
[ "$OLD" = "$SUB_PORT" ] || echo "    TCP $OLD 被占用，订阅改用 $SUB_PORT"
OLD=$HY2_PORT
HY2_PORT=$(pick_port udp "$HY2_PORT" 18443 28443 38443)
[ "$OLD" = "$HY2_PORT" ] || echo "    UDP $OLD 被占用，Hysteria2 改用 $HY2_PORT"

echo ">>> [3/5] 生成密钥和服务端配置"
UUID=$(sing-box generate uuid)
KEYPAIR=$(sing-box generate reality-keypair)
PRIV_KEY=$(echo "$KEYPAIR" | awk '/PrivateKey/{print $2}')
PUB_KEY=$(echo "$KEYPAIR"  | awk '/PublicKey/{print $2}')
SHORT_ID=$(sing-box generate rand --hex 8)
HY2_PASS=$(sing-box generate rand --hex 16)
TOKEN=$(sing-box generate rand --hex 16)

mkdir -p "$CONF_DIR" "$SUB_DIR"
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$CONF_DIR/key.pem" -out "$CONF_DIR/cert.pem" \
  -subj "/CN=bing.com" -days 36500 >/dev/null 2>&1

cat > "$CONF_DIR/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless", "tag": "vless-reality",
      "listen": "::", "listen_port": ${REALITY_PORT},
      "users": [ { "uuid": "${UUID}", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true, "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${SNI}", "server_port": 443 },
          "private_key": "${PRIV_KEY}",
          "short_id": [ "${SHORT_ID}" ]
        }
      }
    },
    {
      "type": "hysteria2", "tag": "hy2",
      "listen": "::", "listen_port": ${HY2_PORT},
      "users": [ { "password": "${HY2_PASS}" } ],
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
chown -R sing-box:sing-box "$CONF_DIR" 2>/dev/null || true
sing-box check -c "$CONF_DIR/config.json"

echo ">>> [4/5] 开启 BBR 加速"
cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
sysctl --system >/dev/null 2>&1 || true

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow ${REALITY_PORT}/tcp >/dev/null
  ufw allow ${HY2_PORT}/udp >/dev/null
  ufw allow ${SUB_PORT}/tcp >/dev/null
fi

systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box
sleep 1
systemctl is-active --quiet sing-box || { journalctl -u sing-box -n 30 --no-pager; exit 1; }

echo ">>> [5/5] 生成 Clash 订阅"
IP=$(curl -s4 --max-time 5 https://api.ipify.org || curl -s4 --max-time 5 https://ifconfig.me || true)
[ -n "$IP" ] || { echo "获取公网 IP 失败"; exit 1; }

S5_AUTH=""
if [ -n "$S5_USER" ]; then
  S5_AUTH="    username: \"${S5_USER}\"
    password: \"${S5_PASS}\""
fi

rm -f "$SUB_DIR"/*.yaml
: > "$SUB_DIR/index.html"      # 防止目录被列出来
# --gen-start
cat > "$SUB_DIR/${TOKEN}.yaml" <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
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

proxies:
  - name: "自建-Reality"
    type: vless
    server: ${IP}
    port: ${REALITY_PORT}
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUB_KEY}
      short-id: ${SHORT_ID}

  - name: "自建-Hy2"
    type: hysteria2
    server: ${IP}
    port: ${HY2_PORT}
    password: ${HY2_PASS}
    sni: bing.com
    skip-cert-verify: true
    udp: true

  - name: "S5-加速"
    type: socks5
    server: ${S5_SERVER}
    port: ${S5_PORT}
${S5_AUTH}
    udp: true
    dialer-proxy: "前置节点"

  - name: "S5-直连"
    type: socks5
    server: ${S5_SERVER}
    port: ${S5_PORT}
${S5_AUTH}
    udp: true

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "S5-加速"
      - "S5-直连"
      - "前置节点"
      - DIRECT

  - name: "前置节点"
    type: select
    proxies:
      - "前置-自动"
      - "自建-Hy2"
      - "自建-Reality"

  - name: "前置-自动"
    type: fallback
    proxies:
      - "自建-Hy2"
      - "自建-Reality"
    url: https://www.gstatic.com/generate_204
    interval: 120

rules:
  - GEOSITE,private,DIRECT
  - GEOIP,private,DIRECT,no-resolve
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,🚀 节点选择
EOF
# --gen-end

cat > /etc/systemd/system/clash-sub.service <<EOF
[Unit]
Description=Clash subscription file server
After=network.target

[Service]
ExecStart=/usr/bin/python3 -m http.server ${SUB_PORT} --bind 0.0.0.0 --directory ${SUB_DIR}
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now clash-sub >/dev/null 2>&1

echo
echo "=================== 安装完成 ==================="
echo
echo "  你的 Clash 订阅链接（复制到 Clash 里）："
echo
echo "  http://${IP}:${SUB_PORT}/${TOKEN}.yaml"
echo
echo "================================================"
echo "别忘了：云服务器控制台的安全组放行 TCP ${REALITY_PORT}、TCP ${SUB_PORT}、UDP ${HY2_PORT}"
echo "导入成功后，可以关掉订阅链接更安全：systemctl disable --now clash-sub"
echo "想换 S5：重新运行同一条安装命令即可"
