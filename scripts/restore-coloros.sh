#!/system/bin/sh
# 手动执行：撤销 scripts/debloat-coloros.sh 的卸载（把包还给 user 0）
#
# 部署：adb push scripts/restore-coloros.sh /data/local/tmp/restore-coloros.sh
# 用法：
#   adb shell su -c 'sh /data/local/tmp/restore-coloros.sh'              # 列出将被恢复的包
#   adb shell su -c 'sh /data/local/tmp/restore-coloros.sh --apply'      # 改 package-restrictions.xml
#   adb reboot                                                          # 必须重启，PMS 才会重新解析
#
# 原理（实测，Android 6.0.1）：
#   `pm uninstall --user 0` 在 /data/system/users/0/package-restrictions.xml 里写下
#       <pkg name="com.xxx" inst="false" stopped="true" nl="true" />
#   删掉这一行并重启，PMS 会重新把 /system 里的 APK 装回 user 0。
#   已实测：删记录 + 重启 → `pm path` 返回 /data/app/<pkg>-1/base.apk，功能正常。
#
# 为什么不能直接 `pm install`：
#   ColorOS 的 OppoPackageInstallerReceiver 会劫持 adb/pm 安装并弹出验证页，
#   无人点击就一直挂着（`pkg:` 之后无输出，180s+）。绕过方式是 PackageInstaller
#   会话 API（pm install-create/-write/-commit，见 docs/13），但会话安装对
#   「inst=false」的系统包只替换代码、不恢复 user 0 安装态，所以恢复仍要走本脚本。
#
# 安全措施：改前备份到 /data/local/tmp/package-restrictions.xml.bak，改后校验
#           XML 头尾结构，异常立即回滚。

BB=/data/adb/magisk/busybox
LIST=/data/local/tmp/debloat-list.txt
F=/data/system/users/0/package-restrictions.xml
BAK=/data/local/tmp/package-restrictions.xml.bak
APPLY=0
[ "$1" = "--apply" ] && APPLY=1

[ -f "$LIST" ] || { echo "missing $LIST"; exit 1; }
[ -f "$F" ]    || { echo "missing $F"; exit 1; }
[ "$(id -u)" = "0" ] || { echo "need root"; exit 1; }

WANT=""
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  pkg=${line%%[ 	]*}
  [ -n "$pkg" ] && WANT="$WANT $pkg"
done < "$LIST"

echo "packages in list: $(echo $WANT | wc -w)"
echo "entries currently blocked for user 0: $($BB grep -c 'inst="false"' "$F")"

if [ $APPLY -eq 0 ]; then
  for p in $WANT; do
    $BB grep -q "name=\"$p\"" "$F" && echo "  restore $p"
  done
  echo
  echo "not applied. re-run with --apply, then reboot"
  exit 0
fi

cp "$F" "$BAK"
n=0
for p in $WANT; do
  # 只删「一行内同时含 <pkg name="X" 和 inst="false"」的记录，避免误删多行组件块
  if $BB grep -q "<pkg name=\"$p\"[^>]*inst=\"false\"" "$F"; then
    $BB sed -i "/<pkg name=\"$p\"[^>]*inst=\"false\"/d" "$F"
    n=$((n + 1))
  fi
done
LEFT=0
for p in $WANT; do
  $BB grep -q "name=\"$p\"" "$F" && LEFT=$((LEFT + 1))
done

if ! $BB head -c 60 "$F" | $BB grep -q '^<?xml'; then
  cp "$BAK" "$F"; echo "XML head broken, rolled back"; exit 1
fi
if ! $BB tail -c 40 "$F" | $BB grep -q '</package-restrictions>'; then
  cp "$BAK" "$F"; echo "XML tail broken, rolled back"; exit 1
fi

echo "removed $n entries; backup=$BAK"
echo "now: entries blocked for user 0 = $($BB grep -c 'inst="false"' "$F")"
[ "$LEFT" -gt 0 ] && echo "WARN: $LEFT package(s) still have residual entries (multi-line <pkg> blocks) — 手工检查后重启"
echo "reboot required: adb reboot"
