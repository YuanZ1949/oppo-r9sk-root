#!/system/bin/sh
# 进 Debian chroot 的交互入口（在 PC 上执行：adb shell su -c 'sh /data/local/tmp/chroot.sh'）
# 或先 ssh 进去后：ssh -t svc@<ip> -p 2222 直接用，不需要这个脚本
R=/data/debian
BB=/data/adb/magisk/busybox

for d in dev proc sys; do
  mkdir -p "$R/$d"
  $BB mountpoint -q "$R/$d" || $BB mount -o bind "/$d" "$R/$d"
done
mkdir -p "$R/dev/pts"
$BB mountpoint -q "$R/dev/pts" || $BB mount -o bind /dev/pts "$R/dev/pts"

LD_PRELOAD=
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
TERM=${TERM:-xterm}
export LD_PRELOAD PATH TERM

exec chroot "$R" /bin/bash -l
