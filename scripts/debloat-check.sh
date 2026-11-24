#!/system/bin/sh
# 手动执行：逐包核对 scripts/debloat-list.txt 里的包在 user 0 是否真的卸载
#
# 部署：adb push scripts/debloat-list.txt  /data/local/tmp/debloat-list.txt
#       adb push scripts/debloat-check.sh  /data/local/tmp/debloat-check.sh
# 用法：adb shell su -c 'sh /data/local/tmp/debloat-check.sh'
# 期望：全部 GONE；有 OK 的行说明该包仍在，重跑 debloat-coloros.sh --apply（脚本幂等）并重启
#
# 为什么不用 `pm list packages | wc -l`：`-u` 会把已卸载的也算进去，计数差 1 很容易漏判。

LIST=/data/local/tmp/debloat-list.txt
[ -f "$LIST" ] || { echo "missing $LIST"; exit 1; }

while read -r p; do
  case "$p" in
    \#*|"") continue ;;
  esac
  out=$(pm path "$p" 2>/dev/null)
  case "$out" in
    package:*) echo "OK   $p" ;;
    *)         echo "GONE $p" ;;
  esac
done < "$LIST"
