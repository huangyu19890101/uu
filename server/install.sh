#!/usr/bin/env bash
# homeuu 服务端一键部署：安装 RustDesk 开源服务端 hbbs/hbbr，并注册为 systemd 服务。
#
# 用法（在云服务器上以 root 执行）：
#   HOMEUU_PUBLIC_HOST=<服务器公网IP或域名> bash install.sh
#
# 可选环境变量：
#   HOMEUU_PORT        hbbs 主端口，默认 31116（同时占用 PORT-1 和 PORT+2）
#   HOMEUU_RELAY_PORT  hbbr 端口，默认 31117（同时占用 RELAY_PORT+2）
#   HOMEUU_ZIP         本地 rustdesk-server zip 路径。服务器访问不了 GitHub 时，先手动上传 zip 再指定
#
# 卸载（保留 /var/lib/homeuu-server 里的密钥）：
#   bash install.sh --uninstall
set -euo pipefail

VERSION="1.1.16"
INSTALL_DIR="/opt/homeuu-server"
DATA_DIR="/var/lib/homeuu-server"
SERVICE_USER="homeuu"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"

PORT="${HOMEUU_PORT:-31116}"
RELAY_PORT="${HOMEUU_RELAY_PORT:-31117}"

log() { printf '\033[1;32m[homeuu]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[homeuu] 错误：\033[0m%s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行（sudo bash install.sh）"

if [ "${1:-}" = "--uninstall" ]; then
    for s in homeuu-hbbs homeuu-hbbr; do
        "$SYSTEMCTL" disable --now "$s" 2>/dev/null || true
        rm -f "$UNIT_DIR/$s.service"
    done
    "$SYSTEMCTL" daemon-reload || true
    rm -rf "$INSTALL_DIR"
    log "已卸载。密钥和数据保留在 $DATA_DIR，确认不再需要后可手动删除。"
    exit 0
fi

PUBLIC_HOST="${HOMEUU_PUBLIC_HOST:-}"
[ -n "$PUBLIC_HOST" ] || die "请设置 HOMEUU_PUBLIC_HOST，例如：HOMEUU_PUBLIC_HOST=1.2.3.4 bash install.sh"
for p in "$PORT" "$RELAY_PORT"; do
    [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1026 ] && [ "$p" -le 65533 ] || die "端口 $p 不合法（需在 1026–65533 之间）"
done
# hbbs 占用 PORT-1、PORT、PORT+2；hbbr 占用 RELAY_PORT、RELAY_PORT+2，不能重叠
for a in $((PORT - 1)) "$PORT" $((PORT + 2)); do
    for b in "$RELAY_PORT" $((RELAY_PORT + 2)); do
        [ "$a" -ne "$b" ] || die "hbbs 端口（$((PORT - 1)) $PORT $((PORT + 2))）与 hbbr 端口（$RELAY_PORT $((RELAY_PORT + 2))）冲突"
    done
done
command -v python3 >/dev/null || die "需要 python3 来解压安装包（Ubuntu/Debian：apt install -y python3）"

case "$(uname -m)" in
    x86_64|amd64)
        ZIP_NAME="rustdesk-server-linux-amd64.zip"; ZIP_DIR="amd64"
        ZIP_SHA256="0565c41affe6c3f409b0bddfaf5a24ccbf3f64f5f8e3fec250b69a0d5f6bdbcf" ;;
    aarch64|arm64)
        ZIP_NAME="rustdesk-server-linux-arm64v8.zip"; ZIP_DIR="arm64v8"
        ZIP_SHA256="6a4ae3c5ca257a4278ded72fd17eb2ca4eeb0356a5425e63a3e7fcb0ec6c155c" ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -n "${HOMEUU_ZIP:-}" ]; then
    cp "$HOMEUU_ZIP" "$WORK/server.zip"
else
    URL="https://github.com/rustdesk/rustdesk-server/releases/download/$VERSION/$ZIP_NAME"
    log "下载 $URL"
    curl -fSL --retry 3 --connect-timeout 20 -o "$WORK/server.zip" "$URL" \
        || die "下载失败。可以在本机下载 $ZIP_NAME，上传到服务器后用 HOMEUU_ZIP=<路径> 重新运行"
fi
echo "$ZIP_SHA256  $WORK/server.zip" | sha256sum -c --quiet - \
    || die "安装包校验失败，文件不是 rustdesk-server $VERSION 的 $ZIP_NAME"
python3 -m zipfile -e "$WORK/server.zip" "$WORK/x"

log "安装到 $INSTALL_DIR"
id "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
install -d -m 0755 "$INSTALL_DIR/bin"
install -m 0755 "$WORK/x/$ZIP_DIR/hbbs" "$WORK/x/$ZIP_DIR/hbbr" "$INSTALL_DIR/bin/"
install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$DATA_DIR"

write_unit() {
    # $1=服务名 $2=说明 $3=启动命令 $4=额外的 [Unit] 依赖
    cat > "$UNIT_DIR/$1.service" <<EOF
[Unit]
Description=$2
After=network-online.target $4
Wants=network-online.target $4

[Service]
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$DATA_DIR
ExecStart=$3
Restart=always
RestartSec=3
LimitNOFILE=1048576
UMask=0077
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
EOF
}
# -k _：只接受内置本服务器公钥的客户端。这不是设备认证，访问控制靠被控端的密码和双重认证
write_unit homeuu-hbbr "homeuu relay server (hbbr)" \
    "$INSTALL_DIR/bin/hbbr -p $RELAY_PORT -k _" ""
write_unit homeuu-hbbs "homeuu rendezvous server (hbbs)" \
    "$INSTALL_DIR/bin/hbbs -p $PORT -r $PUBLIC_HOST:$RELAY_PORT -k _" "homeuu-hbbr.service"

"$SYSTEMCTL" daemon-reload
"$SYSTEMCTL" enable homeuu-hbbr homeuu-hbbs
"$SYSTEMCTL" restart homeuu-hbbr
"$SYSTEMCTL" restart homeuu-hbbs

# 本机防火墙（云厂商的"安全组"仍需在控制台手动放行）
TCP_PORTS="$((PORT - 1)) $PORT $RELAY_PORT"
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    for p in $TCP_PORTS; do ufw allow "$p/tcp" >/dev/null; done
    ufw allow "$PORT/udp" >/dev/null
    log "已在 ufw 中放行端口"
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    for p in $TCP_PORTS; do firewall-cmd --permanent --add-port="$p/tcp" >/dev/null; done
    firewall-cmd --permanent --add-port="$PORT/udp" >/dev/null
    firewall-cmd --reload >/dev/null
    log "已在 firewalld 中放行端口"
fi

for _ in $(seq 1 20); do
    [ -s "$DATA_DIR/id_ed25519.pub" ] && break
    sleep 0.5
done
[ -s "$DATA_DIR/id_ed25519.pub" ] || die "服务没有生成密钥，请查看日志：journalctl -u homeuu-hbbs -u homeuu-hbbr"
KEY="$(cat "$DATA_DIR/id_ed25519.pub")"

cat <<EOF

========================= 部署完成 =========================
云服务器安全组需要放行（入方向）：
  TCP  $((PORT - 1)), $PORT, $RELAY_PORT
  UDP  $PORT
  （$((PORT + 2)) 和 $((RELAY_PORT + 2)) 是网页版用的 WebSocket 端口，不用放行）

客户端设置（官方客户端在"设置 → 网络 → ID/中继服务器"里填写；
定制版 homeuu 编译时写入，对应 GitHub Secrets）：
  ID 服务器      $PUBLIC_HOST:$PORT        → HOMEUU_SERVER
  中继服务器     $PUBLIC_HOST:$RELAY_PORT  → HOMEUU_RELAY
  Key            $KEY  → HOMEUU_KEY

请备份私钥 $DATA_DIR/id_ed25519（加密保存，不要外传）。
查看状态：systemctl status homeuu-hbbs homeuu-hbbr
查看日志：journalctl -u homeuu-hbbs -u homeuu-hbbr -f
============================================================
EOF
