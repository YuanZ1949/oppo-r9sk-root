# Magisk 23.0 在这台机器上成功了（推翻之前的失败结论）

日期：2026-11-24

## 结论

**Magisk 23.0 打补丁的 boot 在这台 R9sk 上完全正常启动。**
之前两次"Magisk 打补丁后卡在 OPPO logo"是误判，原因不是 Magisk，而是：

1. 测试每次都发生在**刚 mke2fs 过的 /data** 上；
2. 新 /data 默认 `adb_enabled=0` + OPPO 首次开机 USB「仅充电」→ **健康启动时 USB 也零枚举**；
3. 于是"看不见"被当成"卡死"，每次都在 5 分钟时强杀进 TWRP，
   **反复打断首次启动的 dex2oat**，导致下一次又慢，形成自我实现的"卡 logo"。

## 公平测试（/data 初始化完成后的干净信号）

安装流程（TWRP 内，直接跑 apk 里的安装器，无需界面点击）：

```sh
# 前提：/data 已解密挂载；Magisk-v23.0.apk 已 push 到 /data/local/tmp
unzip -o /data/local/tmp/Magisk-v23.0.apk -d /data/local/tmp/magisk23
mkdir -p /data/adb/magisk /data/adb/post-fs-data.d /data/adb/service.d /data/adb/modules
cd /data/local/tmp/magisk23
unset OUTFD
sh META-INF/com/google/android/update-binary 3 1 /data/local/tmp/Magisk-v23.0.apk
```

安装器输出关键行：

```
Loading dtbs from [kernel_dtb]
Patch @ 01319C32 [736B69705F696E697472616D667300] -> [77616E745F696E697472616D667300]
Parsing boot image: [/dev/block/mmcblk0p24]   HEADER_VER [0] PAGESIZE [2048]
Repack to boot image: [new-boot.img]  RAMDISK_SZ 1977738 -> 2282597
```

结果验证：

| 项目 | 值 |
|---|---|
| boot 分区 md5（首 2K） | `58afbc99…`（原厂） → **`07bda20468f480ab6663e01e5a898bd0`**（已打补丁） |
| `/data/adb/magisk` | v23 全套：`magisk32 magisk64 magiskboot magiskinit busybox util_functions.sh boot_patch.sh addon.d.sh uninstaller.sh` |
| `MAGISK_VER` | `23.0` |
| 启动 | **adb 18s 出现，`boot_completed=1` 25s** |
| `/sbin/su`、`/sbin/magisk` | 存在（magiskinit 注入成功） |

## 为什么之前 Magisk 21.4 失败、23.0 成功？

21.4 那次从未有过干净信号，因此**不能断定 21.4 本身不行**。23.0 是"最后一代自带 MagiskHide"的版本，
对 Android 6 支持好，且当前已实测可用 —— 应优先用 23.0，不要再回头折腾 21.4。

## 关键教训（写进操作规范）

- **刚格式化的 /data + 插线开机 = 完全不可观测**。要判断启动是否正常，唯一可靠的窗口是：
  `/data` 初始化完成、`adb_enabled=1` 之后 —— 此时健康启动 **18–25 秒** adb 必然出现。
- 首次启动（fresh /data）需要 5–15 分钟且 USB 全程不可见。**不要在这个窗口内强杀**。
- 判断"能不能启动"的实验，必须在**已验证可启动的 /data** 上做，变量一次只改一个（本次只改 boot 分区）。

## 当前状态

- BL 解锁：`ro.boot.verifiedbootstate=orange`
- boot：Magisk 23.0 补丁版（原厂备份仍在 `work/backup/boot.orig.bin`，首 2K md5 `58afbc99ca9f5c61dd12b42c5ac43913`）
- `/system`：干净（`install-recovery.sh` = no-op，无 `/system/xbin/su`）—— **不再依赖 rootd**
- ~~待办：安装 Magisk App 并授权 `adb shell` 的 su 请求~~ → **已完成（2026-11-24）**：
  App 已装上（`/data/app/com.topjohnwu.magisk-2/base.apk`），`su -c id` = `uid=0(root) context=u:r:magisk:s0`，
  MagiskHide 已启用，ColorOS 的「验证身份」安装拦截已击穿。
  详见 **`docs/13-magisk-app-and-coloros-install-gate.md`**
