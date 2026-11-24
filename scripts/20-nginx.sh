#!/system/bin/sh
# 可选 · 开机以 uid 2000（yuan）启动 chroot 内的 nginx，监听 8080
# 部署位置：/data/adb/service.d/20-nginx.sh ；不需要 nginx 就删掉本文件
# 说明：以非 root 运行，因此不能绑 <1024 端口；要 80 端口请用 iptables 转发或改 nginx 端口

R=/data/debian
BB=/data/adb/magisk/busybox
LOG=/data/local/tmp/server.log

log() { echo "[$($BB date '+%Y-%m-%d %H:%M:%S')] nginx: $*" >> "$LOG"; }

[ -x "$R/usr/sbin/nginx" ] || { log "nginx missing, skip"; exit 0; }

# 等 10-server.sh 把 /proc 挂好、sshd 起来
i=0
while [ ! -e "$R/proc/1" ] && [ $i -lt 60 ]; do sleep 1; i=$((i + 1)); done

mkdir -p "$R/run/nginx" "$R/var/log/nginx" "$R/var/lib/nginx"
[ "$(stat -c %u "$R/run/nginx")" = "2000" ] || chown 2000:2000 "$R/run/nginx"
[ "$(stat -c %u "$R/var/log/nginx")" = "2000" ] || chown 2000:2000 "$R/var/log/nginx"

if $BB netstat -tln 2>/dev/null | grep -q ':8080 '; then
  log "already listening on 8080"
  exit 0
fi

LD_PRELOAD= /system/bin/chroot "$R" /usr/bin/setpriv \
  --reuid=2000 --regid=2000 --groups=1015,1023,3003 \
  /usr/sbin/nginx >> "$LOG" 2>&1
log "start rc=$?"
