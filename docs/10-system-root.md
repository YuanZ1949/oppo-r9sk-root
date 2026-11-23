# 10 - 纯 /system root（qti_init_shell 域）· 已弃用（存档）

> **⚠️ 本文结论已被推翻，仅作历史存档（2026-11-24 更新）**
> - 「Magisk patch boot 必定不启动」是**误判**：真实根因是新 `/data` 的 SELinux 标签问题（`/data/media` 由 TWRP root shell 创建 → `unlabeled` → `installd` 起不来），
>   与 boot 补丁无关。修掉后 **Magisk 23.0 正常启动**，见 `docs/11-boot-hang-analysis.md`、`docs/12-magisk-success.md`。
> - 本方案（rootd）只提供 adb 终端层 root、无授权机制、且有本地 TCP 后门隐患，已从 `/system` 彻底移除。
> - 现状：**Magisk 23.0**（App 级授权 + 模块 + MagiskHide），见 `docs/13-magisk-app-and-coloros-install-gate.md`。

OPPO R9sk / R9s_11_A.37_191127（Android 6.0.1 / SDK 23）在本机实测下唯一可用的持久化 root 方案。
**boot 分区未做任何修改**（boot 被 OPPO 强签名校验，Magisk patch 必定触发「系统文件被破坏」）。

## 为什么不是 SuperSU / Magisk

| 路线 | 失败原因（实测） |
|---|---|
| Magisk patch boot | OPPO boot 签名校验，不启动 |
| SuperSU 2.82 system 模式 | stock policy 无 `supersu`/`sudaemon` 域；daemonsu 在 init 域被拒 `sys_ptrace`；`init-->kernel (security)` 无 `load_policy`，无法通过 `/data/security/current/sepolicy` 重载策略；`setenforce 0` 被拒 |
| app_process 钩子 | zygote 起不来，卡 OPPO logo |
| install-recovery.sh 标 `toolbox_exec` | 进入 toolbox 域，`toolbox-->system_file` 无 execute，daemonsu 起不来 |

## 原理

stock policy 自带 QTI init shell 域，且存在完整转换链：

```
TRANSITION init-->shell_exec (process) [qti_init_shell]
ALLOW init-->qti_init_shell (process) [siginh transition noatsecure rlimitinh]
ALLOW qti_init_shell-->shell_exec (file) [execute getattr read entrypoint execute_no_trans open]
ALLOW qti_init_shell-->port (tcp_socket) [name_bind name_connect]
```

`/system/bin/sh` 的 context 就是 `shell_exec`。所以由 init 域显式执行 `/system/bin/sh ...`
即可进入 `u:r:qti_init_shell:s0`（uid 0）。该域权限足以当 root 用：
`system_data_file` / `app_data_file` / `cache_file` / `sdcardfs` 读写、TCP bind/connect、
`setprop`（system_prop）、`/dev/kmsg` 写、binder 调 system_server（`pm`/`am` 可用）。

注意：**直接执行 shebang 脚本（`#!/system/bin/sh`）不会转换**（域按脚本文件类型 system_file 计算，
停留在 init 域）；必须显式 `exec /system/bin/sh`。

## 组件

1. `/system/bin/install-recovery.sh`（0750 root:root，`u:object_r:system_file:s0`）
   - init.rc:894 `service flash_recovery /system/bin/install-recovery.sh`（class main, oneshot, uid 0）
   - 每次开机随机端口（20000-39999），写 `ROOTD_PORT=<port>` 到 `/dev/kmsg`，`setprop sys.rootd.port <port>`
   - 后台 `exec /system/bin/sh -c "... toybox netcat -s 127.0.0.1 -p <port> -L /system/bin/sh"`
2. `/system/xbin/su`（0755 root:root，`system_file`）
   - 从 `getprop sys.rootd.port`（app 可用）或 `dmesg | grep ROOTD_PORT=`（shell 可用）取端口
   - `su -c "cmd"`：把命令发给 127.0.0.1 的 qti_init_shell；无参数时进入交互式转发
   - `su -v` 返回 `2.82:SUPERSU`（仅为 root app 兼容性）

源文件：`work/root/ir_v4.sh`、`work/root/su_wrapper.sh`、`work/root/deploy_v4.sh`。

## 使用

```sh
adb shell su -c id          # uid=0(root) ... context=u:r:qti_init_shell:s0
adb shell su -c 'ls /data/data'
adb shell su                # 交互（无提示符，逐行执行）
adb forward tcp:12323 tcp:<port>   # PC 侧也可直连
```

## 已知限制

- **没有按应用授权**：能执行 `/system/xbin/su` 的调用者（adb shell、任意 app）直接获得 root。
  这是 stock policy 无法加载新策略（无 `load_policy`）导致的，无法用 SuperSU 式弹窗授权。
- **不能 remount /system**：`mount -o remount,rw /system` → `Operation not permitted`；
  改 /system 仍需进 TWRP。
- 不能 `setenforce 0`、不能加载自定义 sepolicy。
- 域是 `qti_init_shell`，不是 `su`；依赖 Magisk/SuperSU 专有接口的模块（Xposed 等）不适用。

## 回滚

TWRP 内：

```sh
mount -t ext4 -o rw /dev/block/bootdevice/by-name/system /system
cp /sdcard/sysbak/install-recovery.sh.orig /system/bin/install-recovery.sh
chown 0:0 /system/bin/install-recovery.sh; chmod 0750 /system/bin/install-recovery.sh
chcon u:object_r:system_file:s0 /system/bin/install-recovery.sh
rm -f /system/xbin/su
sync && umount /system
```

`/sdcard/sysbak/` 另有 `su.supersu`、`daemonsu`、`supolicy`、`libsupol.so`、`SuperSU.apk`、
`app_process32/64`、`app_process.link` 备份。boot 分区始终是原始镜像（`work/backup/boot.orig.bin`）。

## 验证记录

| 时间 | 事件 |
|---|---|
| 22:19:42 | 首启：dmesg `ROOTD_PORT=21203`；`su -c id` = uid=0(root)，`context=u:r:qti_init_shell:s0` |
| 22:22:02 | 二次重启：`ROOTD_PORT=24638`；`su -c id` 同上；`getenforce`=Enforcing；`sys.boot_completed`=1 |
