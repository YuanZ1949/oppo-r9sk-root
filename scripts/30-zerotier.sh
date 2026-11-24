#!/system/bin/sh
# 可选 · 开机启动 chroot 内的 ZeroTier One（root 身份，需要 /dev/net/tun）
# 部署位置：/data/adb/service.d/30-zerotier.sh ；日志：/data/local/tmp/server.log
#
# 关键点：
#  1) Android 只有 /dev/tun（char 10:200），而 ZeroTier 找 /dev/net/tun → 必须建软链
#     /dev 是 tmpfs，**重启就没了**，所以每次开机都要重建
#  2) zerotier-one -d 会 daemonize，但仍继承调用者的 stdout；
#     用 adb 手动执行时若不定向输出，会把 adb 会话一直挂住
#  3) 网络成员信息存在 /data/debian/var/lib/zerotier-one/networks.d，join 一次即可

R=/data/debian
BB=/data/adb/magisk/busybox
LOG=/data/local/tmp/server.log

log() { echo "[$($BB date '+%Y-%m-%d %H:%M:%S')] zerotier: $*" >> "$LOG"; }

[ -x "$R/usr/sbin/zerotier-one" ] || { log "not installed, skip"; exit 0; }

mkdir -p /dev/net
[ -e /dev/net/tun ] || ln -s /dev/tun /dev/net/tun

# 等 10-server.sh 挂完 /proc
i=0
while [ ! -e "$R/proc/1" ] && [ $i -lt 60 ]; do sleep 1; i=$((i + 1)); done

if $BB netstat -tln 2>/dev/null | grep -q ':9993 '; then
  log "already listening on 9993"
  exit 0
fi

LD_PRELOAD= /system/bin/chroot "$R" /usr/bin/env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/root /usr/sbin/zerotier-one -d >> "$LOG" 2>&1

log "start rc=$?"
