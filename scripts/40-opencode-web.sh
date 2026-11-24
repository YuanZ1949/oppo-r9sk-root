#!/system/bin/sh
# 可选 → 以 chroot 内普通用户（yuan, uid 2000）身份常驻 OpenCode 2 的 web + API 服务
# 部署位置：/data/adb/service.d/40-opencode-web.sh   日志：/data/local/tmp/server.log
#
# 监听 0.0.0.0:4300 → 局域网（192.168.2.x）和 ZeroTier（192.168.193.x）都能访问
# 登录口令在 /home/yuan/.config/opencode/service.json（与 PC 一致，不进本仓库）
#
# 说明：
#  1) chroot 里没有 systemd，`opencode service start` 只监听 127.0.0.1；对外必须用
#     `opencode serve --hostname 0.0.0.0 --port 4300 --service`（与 PC 的命令行完全一致）。
#  2) serve 是前台进程，必须 setsid 脱离调用者的会话/进程组。实测：不加 setsid 时，
#     进程在打印 "server listening" 后、调用者（adb shell / 开机脚本）退出时被连带杀掉。
#  3) 降权到 2000 需要补充组 3003(aid_inet)/3004(aid_net_raw)，否则 socket(AF_INET) 被内核拒绝。
#  4) 单个 serve 常驻 RSS 110–500 MB，手机上只允许一个实例。脚本先查端口、再查进程，均幂等。

R=/data/debian
BB=/data/adb/magisk/busybox
LOG=/data/local/tmp/server.log
PORT=4300
PIDFILE=/data/local/tmp/opencode-web.pid

log() { echo "[$($BB date '+%Y-%m-%d %H:%M:%S')] opencode: $*" >> "$LOG"; }

[ -x "$R/usr/local/bin/opencode" ] || { log "opencode missing, skip"; exit 0; }

# 等 10-server.sh 把 /proc 挂上（chroot 就绪）
i=0
while [ ! -e "$R/proc/1" ] && [ $i -lt 60 ]; do sleep 1; i=$((i + 1)); done

# 幂等：端口已在监听就直接返回
if $BB netstat -tln 2>/dev/null | grep -q ":$PORT "; then
  log "already listening on $PORT"
  exit 0
fi

# 幂等：进程还在（端口尚未就绪）也不要重复拉起
OLD=$($BB pgrep -f "opencode serve --hostname 0.0.0.0 --port $PORT" 2>/dev/null | head -1)
if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
  log "already running pid=$OLD, wait"
  exit 0
fi

LD_PRELOAD= /system/bin/chroot "$R" /usr/bin/env -i \
  PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/home/yuan USER=yuan LOGNAME=yuan TMPDIR=/tmp LANG=C.UTF-8 \
  /usr/bin/setsid /usr/bin/setpriv --reuid=2000 --regid=2000 --groups=1015,1023,3003,3004 \
  /usr/local/bin/opencode serve --hostname 0.0.0.0 --port "$PORT" --service \
  >> "$LOG" 2>&1 < /dev/null &

NEW=""
i=0
while [ $i -lt 60 ]; do
  NEW=$($BB pgrep -f "opencode serve --hostname 0.0.0.0 --port $PORT" 2>/dev/null | head -1)
  [ -n "$NEW" ] && break
  sleep 2
  i=$((i + 1))
done

if [ -n "$NEW" ]; then
  echo "$NEW" > "$PIDFILE"
  log "started pid=$NEW (uid 2000, 0.0.0.0:$PORT)"
else
  log "start failed: process not found"
fi
