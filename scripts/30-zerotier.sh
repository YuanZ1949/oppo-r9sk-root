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
#  4) ★ Android 的 netd 策略路由只查 per-network 表（wlan0 表里只有默认路由），
#     没有额外规则时，本机进程发往 zt 子网（192.168.193.0/24）的包会从 wlan0 出去被丢掉。
#     结果是：ZeroTier 自己 online，但手机 ping 不通任何 zt 对端，也不会和对端建立 peer，
#     对端同样看不到手机。补一条「按目的地址查 main 表」的规则即可（main 里才有 zt 路由）。
#  5) ★ 解析路由必须用 $BB awk：Android 7.1 的 toybox 没有 awk（/system/bin/awk 不存在），
#     用裸 awk 时命令替换恒为空 → 规则永远加不上，日志只会出现 "zt route not found"。

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

# 等 Wi-Fi 拿到 IPv4（最长 120s）。注意 main 表里没有 default 路由
# （default 在 netd 的 per-network 表里），所以只能看 wlan0 的地址
i=0
while [ $i -lt 60 ]; do
  ip -4 addr show wlan0 2>/dev/null | grep -q 'inet ' && break
  sleep 2
  i=$((i + 1))
done

if $BB netstat -tln 2>/dev/null | grep -q ':9993 '; then
  log "already listening on 9993"
else
  LD_PRELOAD= /system/bin/chroot "$R" /usr/bin/env -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    HOME=/root /usr/sbin/zerotier-one -d >> "$LOG" 2>&1
  log "start rc=$?"
fi

# ---- 4) 补 Android 策略路由 ----
# 放后台跑：ZT 接口出现时间不可控（几秒到 2 分钟），不能阻塞开机脚本；
# 规则加好后转入低频守护（netd 重启/切网会清掉自定义规则，每 5 分钟复核一次）。
#
# 子网缓存 /data/local/tmp/zt-subnet.txt：开机会比 ZT 接口更早读到，用来「先加规则」，
# 这样接口一出现就能通，不用等检测循环。首次开机没有缓存也无妨，检测到后写回。
(
  DET=/data/local/tmp/zt-subnet.txt

  CACHED=$(cat "$DET" 2>/dev/null)
  if [ -n "$CACHED" ]; then
    if ip rule show 2>/dev/null | grep -q "to $CACHED lookup main"; then
      :
    else
      ip rule add to "$CACHED" lookup main priority 21000 && log "policy rule added (cached): to $CACHED lookup main"
    fi
  fi

  i=0
  ZTRT=""
  while [ $i -lt 450 ]; do
    ZTRT=$(ip -4 route show 2>/dev/null | $BB awk '/ dev zt/ && /proto kernel/ {print $1; exit}')
    [ -n "$ZTRT" ] && break
    # 前几次循环把原始路由表写进日志，便于排查（首次开机会用到）
    [ $i -lt 3 ] && log "diag: route=[$(ip -4 route show 2>/dev/null | tr '\n' ';')]"
    sleep 2
    i=$((i + 1))
  done

  if [ -z "$ZTRT" ]; then
    log "zt route not found after 15min, policy rule skipped"
    exit 0
  fi

  log "zt subnet detected: $ZTRT"
  echo "$ZTRT" > "$DET"

  while :; do
    if ip rule show 2>/dev/null | grep -q "to $ZTRT lookup main"; then
      :
    else
      ip rule add to "$ZTRT" lookup main priority 21000 && log "policy rule added: to $ZTRT lookup main"
    fi
    sleep 300
  done
) &
log "policy-rule watcher started (bg)"
