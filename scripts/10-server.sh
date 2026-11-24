#!/system/bin/sh
# Magisk service.d · 开机以 root 启动 Debian chroot 内的 sshd
# 部署位置：/data/adb/service.d/10-server.sh   日志：/data/local/tmp/server.log
#
# 设计要点：
#  1) 幂等：重复执行不会起第二个 sshd（先查 2222 是否已监听）
#  2) 不依赖 Termux / 任何 App，App 被 LMK 杀掉也不影响
#  3) 挂载 /dev /proc /sys /dev/pts 后再 chroot，缺 /dev/pts 会导致 ssh -t 拿不到 pty
#  4) 顺手把无线 adb 拉起来做应急入口（sshd 挂了还能进）

R=/data/debian
BB=/data/adb/magisk/busybox
LOG=/data/local/tmp/server.log

log() { echo "[$($BB date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

log "=== boot: start ==="

# 等 rootfs 就绪（理论上 /data 已挂好，保险起见）
i=0
while [ ! -x "$R/usr/sbin/sshd" ] && [ $i -lt 30 ]; do
  sleep 1
  i=$((i + 1))
done
[ -x "$R/usr/sbin/sshd" ] || { log "FATAL: $R/usr/sbin/sshd missing"; exit 1; }

# ---------- 无线 adb 兜底 ----------
# 注意：这里**不能** stop/start adbd —— service.d 若通过 adb shell 手动触发，
# 重启 adbd 会把执行它的那条 adb 会话一起干掉，脚本会在中途死掉。
# 只要 persist.adb.tcp.port 已设置，下次开机 adbd 自己就会监听 5555。
if [ -z "$(getprop persist.adb.tcp.port)" ]; then
  setprop persist.adb.tcp.port 5555
  log "wireless adb: persist.adb.tcp.port set to 5555 (生效于下次开机)"
else
  log "wireless adb: persist.adb.tcp.port=$(getprop persist.adb.tcp.port)"
fi

# ---------- 挂载 ----------
mkdir -p "$R/dev" "$R/proc" "$R/sys" "$R/dev/pts" "$R/sdcard"
for d in dev proc sys; do
  $BB mountpoint -q "$R/$d" || $BB mount -o bind "/$d" "$R/$d" || log "WARN: bind /$d failed"
done
$BB mountpoint -q "$R/dev/pts" || $BB mount -o bind /dev/pts "$R/dev/pts" || log "WARN: bind /dev/pts failed"

# 共享存储：/data/media/0 是 /sdcard 的底层路径，无需等用户解锁
if [ -d /data/media/0 ]; then
  $BB mountpoint -q "$R/sdcard" || $BB mount -o bind /data/media/0 "$R/sdcard" || log "WARN: bind sdcard failed"
fi

# ---------- 网络组（关键坑）----------
# 这台机器的内核开了 CONFIG_ANDROID_PARANOID_NETWORK：只有 supplementary group
# 里含 aid_inet(3003) 的 UID 才能 socket(AF_INET)，否则连 socket() 都返回
# EACCES（表现为 curl "Failed to connect after 0 ms"、getent 解析失败、ping
# 却因为 setuid 差异表现不一致，极易误判成 DNS/路由问题）。
# sshd 用 initgroups() 从 chroot 的 /etc/group 取组，所以要写在那里。
ensure_member() { # $1=组名 $2=gid $3=用户
  G="$R/etc/group"
  grep -q "^$1:" "$G" || echo "$1:x:$2:" >> "$G"
  $BB awk -F: -v OFS=: -v g="$1" -v u="$3" '
    $1 == g { if ($4 == "") $4 = u; else if (index("," $4 ",", "," u ",") == 0) $4 = $4 "," u }
    { print }' "$G" > "$G.new" && mv "$G.new" "$G"
  chmod 644 "$G"; chown 0:0 "$G"
}
ensure_member aid_inet     3003 svc
ensure_member aid_net_raw  3004 svc
ensure_member sdcard_rw    1015 svc
ensure_member media_rw     1023 svc
ensure_member aid_inet     3003 _apt   # apt 的沙箱用户也要能联网

# ---------- DNS ----------
# 蜂窝/无线切换后运营商 DNS 会变；这里取 Android 当前的 dns1
D1=$(getprop net.dns1)
[ -n "$D1" ] && printf 'nameserver %s\nnameserver 223.5.5.5\nnameserver 8.8.8.8\n' "$D1" > "$R/etc/resolv.conf"

# ---------- sshd ----------
mkdir -p "$R/run/sshd"
chmod 755 "$R/run/sshd"

if $BB netstat -tln 2>/dev/null | grep -q ':2222 '; then
  log "sshd already listening on 2222"
else
  # 用 /system/bin/chroot（toybox）显式指定，避免改 Android 侧 PATH 后找不到 chroot；
  # 进 chroot 后用 Debian 的 env 重置环境（Android 的 LD_PRELOAD=libNimsWrap.so 会污染 glibc 程序）
  LD_PRELOAD= /system/bin/chroot "$R" /usr/bin/env -i \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      HOME=/root TERM=xterm LANG=C.UTF-8 \
      /usr/sbin/sshd -p 2222 -o PidFile=/run/sshd.pid >> "$LOG" 2>&1
  log "sshd start rc=$?"
fi

log "=== boot: done ==="
