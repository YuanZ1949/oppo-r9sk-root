#!/system/bin/sh
# 手动执行（不是开机脚本）：按 scripts/debloat-list.txt 卸载 ColorOS 预装
#
# 部署：
#   adb push scripts/debloat-list.txt   /data/local/tmp/debloat-list.txt
#   adb push scripts/debloat-coloros.sh /data/local/tmp/debloat-coloros.sh
#   adb shell su -c 'sh /data/local/tmp/debloat-coloros.sh'          # 打印计划
#   adb shell su -c 'sh /data/local/tmp/debloat-coloros.sh --apply'  # 真正执行
#
# 为什么用 `pm uninstall -k --user 0` 而不是 disable：
#   1) 对 user 0 卸载 = 从桌面/进程/自启里彻底消失，效果等同「卸载」
#   2) APK 仍在 /system（分区 ro，删不掉也没必要删），-k 保留 /data 数据
#   3) 状态记录在 /data/system/users/0/package-restrictions.xml 的 inst="false"，
#      可以整份回滚 → scripts/restore-coloros.sh（见后）
#
# 不要动：systemui / settings / phone / telecom / incallui / launcher / recents /
#          notificationmanager / wirelesssettings / providers.* / packageinstaller /
#          shell / externalstorage / keyguard / safecenter / mcs / activation /
#          usbselection / 相机全家桶 / 指纹 / 传感器 / Dirac 音效 / 输入法

BB=/data/adb/magisk/busybox
LIST=/data/local/tmp/debloat-list.txt
LOG=/data/local/tmp/debloat.log
APPLY=0
[ "$1" = "--apply" ] && APPLY=1

[ -f "$LIST" ] || { echo "missing $LIST"; exit 1; }
[ "$(id -u)" = "0" ] || { echo "need root"; exit 1; }

log() { echo "[$($BB date '+%Y-%m-%d %H:%M:%S')] debloat: $*" | tee -a "$LOG"; }

total=0; done_n=0; skip_n=0; fail_n=0; plan=""
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  pkg=${line%%[ 	]*}
  [ -z "$pkg" ] && continue
  total=$((total + 1))
  if ! pm list packages 2>/dev/null | $BB grep -qx "package:$pkg"; then
    skip_n=$((skip_n + 1)); plan="$plan
  skip  $pkg (already gone)"
    continue
  fi
  if [ $APPLY -eq 0 ]; then
    plan="$plan
  would $pkg"
    continue
  fi
  out=$(pm uninstall -k --user 0 "$pkg" 2>&1)
  case "$out" in
    *Success*) done_n=$((done_n + 1)); log "OK    $pkg" ;;
    *)         fail_n=$((fail_n + 1)); log "FAIL  $pkg -> $out" ;;
  esac
done < "$LIST"

if [ $APPLY -eq 0 ]; then
  echo "plan ($total packages):$plan"
  echo
  echo "not applied. re-run with --apply"
  exit 0
fi

log "summary: total=$total removed=$done_n skipped=$skip_n failed=$fail_n"
log "restore: sh /data/local/tmp/restore-coloros.sh && reboot"
