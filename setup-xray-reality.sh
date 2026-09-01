#!/usr/bin/env bash
#
# Установка и настройка VLESS + XTLS-Vision + REALITY (Xray-core)
# Использование: bash setup-xray-reality.sh
#
# По умолчанию decoy-домен — store.steampowered.com (можно сменить ниже).

set -euo pipefail

# ---------- НАСТРОЙКИ (можно поменять) ----------
DEST="store.steampowered.com"
PORT=443
CONFIG_PATH="/usr/local/etc/xray/config.json"
CLIENT_LINK_NAME="MyServer"
# -------------------------------------------------

echo "==> Установка зависимостей"
apt update -y
apt install -y curl socat openssl unzip

echo "==> Установка / обновление Xray-core"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

if ! command -v xray >/dev/null 2>&1; then
    echo "ОШИБКА: xray не установился, прерываю." >&2
    exit 1
fi

echo "==> Генерация UUID, ключей и shortId"
UUID=$(xray uuid)
KEYS=$(xray x25519)

# Разные версии Xray по-разному называют поля в выводе x25519,
# поэтому пробуем оба известных формата.
PRIVATE_KEY=$(echo "$KEYS" | grep -oP '(?:Private ?[Kk]ey):\s*\K.*' | head -n1)
PUBLIC_KEY=$(echo "$KEYS"  | grep -oP '(?:Public ?[Kk]ey|Password \(PublicKey\)):\s*\K.*' | head -n1)
SHORT_ID=$(openssl rand -hex 8)

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    echo "ОШИБКА: не удалось распарсить ключи. Сырой вывод xray x25519:" >&2
    echo "$KEYS" >&2
    exit 1
fi

echo "==> Получаемый server IP"
SERVER_IP=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com || hostname -I | awk '{print $1}')

echo "==> Запись конфига в $CONFIG_PATH"
mkdir -p "$(dirname "$CONFIG_PATH")"

cat > "$CONFIG_PATH" << 'EOF'
{
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": PORT_PLACEHOLDER,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "UUID_PLACEHOLDER", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "DEST_PLACEHOLDER:443",
          "xver": 0,
          "serverNames": ["DEST_PLACEHOLDER"],
          "privateKey": "PRIVATEKEY_PLACEHOLDER",
          "shortIds": ["SHORTID_PLACEHOLDER"],
          "spiderX": "/"
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
EOF

# Используем '#' как разделитель в sed, т.к. base64-ключи могут содержать '/'
sed -i "s#PORT_PLACEHOLDER#$PORT#"                  "$CONFIG_PATH"
sed -i "s#UUID_PLACEHOLDER#$UUID#"                  "$CONFIG_PATH"
sed -i "s#DEST_PLACEHOLDER#$DEST#g"                 "$CONFIG_PATH"
sed -i "s#PRIVATEKEY_PLACEHOLDER#$PRIVATE_KEY#"     "$CONFIG_PATH"
sed -i "s#SHORTID_PLACEHOLDER#$SHORT_ID#"           "$CONFIG_PATH"

echo "==> Перезапуск Xray"
systemctl restart xray
systemctl enable xray >/dev/null 2>&1 || true

sleep 1

echo "==> Проверка статуса"
if ! systemctl is-active --quiet xray; then
    echo "ОШИБКА: xray не запустился. Лог:" >&2
    journalctl -u xray -n 30 --no-pager >&2
    exit 1
fi

if ! ss -tlnp | grep -q ":$PORT"; then
    echo "ПРЕДУПРЕЖДЕНИЕ: порт $PORT не слушается. Проверьте firewall / конфиг вручную." >&2
fi

# Открываем порт в ufw, если он используется
if command -v ufw >/dev/null 2>&1; then
    ufw allow "$PORT"/tcp >/dev/null 2>&1 || true
    ufw allow 22/tcp >/dev/null 2>&1 || true
fi

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST}&fp=randomized&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${CLIENT_LINK_NAME}"

echo ""
echo "======================================================"
echo " Xray + VLESS + REALITY настроен и запущен"
echo "======================================================"
echo "Server IP:    $SERVER_IP"
echo "Port:         $PORT"
echo "UUID:         $UUID"
echo "SNI (decoy):  $DEST"
echo "PublicKey:    $PUBLIC_KEY"
echo "ShortId:      $SHORT_ID"
echo "Fingerprint:  randomized"
echo "------------------------------------------------------"
echo "Ссылка для клиента (v2RayTun / Hiddify / v2RayN / NekoBox):"
echo ""
echo "$VLESS_LINK"
echo ""
echo "======================================================"
echo "Не забудьте сменить root-пароль, если он был передан в открытом виде:"
echo "  passwd"
echo "======================================================"

# Сохраняем данные в файл на случай, если понадобится позже
cat > /root/xray-client-info.txt << INFOEOF
UUID:        $UUID
PrivateKey:  $PRIVATE_KEY
PublicKey:   $PUBLIC_KEY
ShortId:     $SHORT_ID
SNI:         $DEST
Server IP:   $SERVER_IP
Port:        $PORT

Client link:
$VLESS_LINK
INFOEOF

echo "Данные также сохранены в /root/xray-client-info.txt"
