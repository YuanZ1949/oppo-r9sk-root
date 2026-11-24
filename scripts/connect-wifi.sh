#!/system/bin/sh
# 在设备上以 root 直接给 Android 6 写入 WiFi 配置（不碰屏幕）
# 用法： sh connect-wifi.sh "SSID" "PASSWORD"
#
# 注意：
#  - 用 >> 追加而不是重写文件，保持原文件的属主/权限（wpa_supplicant 对权限敏感）
#  - 改完必须 svc wifi disable/enable 让 supplicant 重新读配置
#  - 密码会出现在 shell 历史里；用完可 `history -c`

SSID="$1"
PSK="$2"
CONF=/data/misc/wifi/wpa_supplicant.conf

[ -n "$SSID" ] || { echo "usage: $0 SSID PASSWORD"; exit 2; }
[ -n "$PSK" ] || { echo "usage: $0 SSID PASSWORD"; exit 2; }

cp -f "$CONF" /data/local/tmp/wpa_supplicant.conf.bak 2>/dev/null
echo "backup: /data/local/tmp/wpa_supplicant.conf.bak"

# 已有同 SSID 的配置先删掉（简单做法：整体重写 network 段太危险，这里只追加 priority 更高的新段）
{
  echo "network={"
  echo "	ssid=\"$SSID\""
  echo "	psk=\"$PSK\""
  echo "	key_mgmt=WPA-PSK"
  echo "	priority=10"
  echo "}"
} >> "$CONF"

echo "--- 当前配置尾部 ---"
tail -8 "$CONF"

svc wifi disable
sleep 2
svc wifi enable

i=0
while [ $i -lt 30 ]; do
  sleep 1
  IP=$(ip -4 addr show wlan0 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
  if [ -n "$IP" ]; then
    echo "WLAN_IP=$IP"
    exit 0
  fi
  i=$((i + 1))
done
echo "WIFI_NOT_CONNECTED"
dumpsys wifi | grep -E "Wi-Fi is|mNetworkInfo" | head -2
exit 1
