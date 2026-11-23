# OPPO R9sk EDL 执行计划

## 侦察

- 现象：手机插在 ASMedia 口（Port_#0003.Hub_#0004）后不再枚举为 9008，而是 `USB\VID_0000&PID_0002\6&2BCCCFA4&0&3`（Status=Error，"未知 USB 设备(设备描述符请求失败)"）；同期无 ADB、无任何 05C6/22D9 设备。
- 复现：`Get-PnpDevice -PresentOnly | ? InstanceId -like 'USB\VID_0000*'` 在 02:19:15–02:20:27 连续 10 次采样结果恒定；`Get-CimInstance Win32_SerialPort` 全程无 05C6 端口；runner 日志 `work\backup\edl-handoff2.log` 从 02:17:25 起每 10s 打印 "still waiting for 9008 to appear"。
- 影响面：仅阻断 O1 的入口（设备重新枚举）；loader/TWRP 产物、备份脚本、文档与 G1 只读约束均不受影响，手机分区未被写入。
- 基线：02:05:22 同一口曾枚举为 COM7 且 `write_probe.py COM7` 返回 `LINK ALIVE (RESET_RSP)`；02:09:51 发送 RESET_REQ 后 02:14:50 端口消失，此后不再出现；02:14:24 打开 COM7 读 26s 全空、写入只进缓冲。
- 假设：RESET_REQ 使 PBL 挂死；拔插 USB 不断电（电池仍供电），挂死状态跨重插保留，故每次重插只重新枚举一次并再次失败；VBUS 在位时 PMIC 抑制电源键长按硬复位。
- 结论：软件侧已无自愈手段（非管理员不能重启设备节点，且节点重启也不切断 SoC 供电）；必须先让 SoC 真正断电或 PMIC 硬复位，才可能重新进入 Sahara，之后握手与 printgpt 链路才能推进。

## 执行计划

- [x] P1 → O1：让手机在无 VBUS 状态下做 PMIC 硬复位（拔线 → 长按电源 30s → 再电源+音量+ 30s），随后按住音量+和音量-插回 ASMedia 口，使其重新枚举为 9008；依赖：无；验证：`Get-PnpDevice -PresentOnly` 出现 `VID_05C6&PID_9008` 且 `work\backup\edl-handoff2.log` 出现 "opened COM" 与 "RX HELLO_REQ"；回退：若仍只有 `VID_0000&PID_0002`，改为拆后盖断电池排线，或拔线静置放电 12h 后重试 P1。
- [x] P2 → O1：握手成功后确认 runner 自动执行 stage2 printgpt 并输出完整 GPT 分区表；依赖：P1；验证：`work\backup\edl-handoff2.log` 出现 "*** PROGRAMMER UPLOADED, FIREHOSE READY ***" 与 "STAGE2 OK"，且 `work\backup\printgpt.log` 含 "Number of partitions" 及分区行；回退：若 printgpt 失败，改用 `python edl.py --serial=COMx printgpt` 手动重跑并检查 firehose 会话是否存活。
- [x] P3 → O2：按 docs/04-9008-edl.md §11 用 `edl.py r` 只读导出 aboot/recovery/efs/modem/persist 到 work\backup\；依赖：P2；验证：`Get-ChildItem work\backup\*.img` 列出 5 个文件，大小与 printgpt 的分区尺寸一致，且每个文件可读（Get-FileHash 成功）；回退：某分区读取失败时仅重跑该分区的 r 命令并记录错误，绝不改写任何分区。
- [x] P4 → O3：经用户明确确认后，仅用 `edl.py w recovery work\twrp-r9s\recovery.img` 写入 recovery 并验证设备能进 TWRP；依赖：P3；验证：写入返回成功，重启后设备进入 TWRP 界面且 `adb devices` 出现 recovery 设备；回退：若无法进 TWRP，用 P3 备份的官方 recovery 镜像回写恢复。
- [x] P5 → O3：纯 /system 模式 root（boot 未动）。实测 SuperSU 2.82 不可用（stock policy 无 supersu/sudaemon 域、init 无 load_policy 无法重载策略、daemonsu 需 ptrace 被拒），改用 stock policy 自带的 qti_init_shell 域——TWRP 内把 `/system/bin/install-recovery.sh`（system_file，init 域执行）改为启动 `/system/bin/sh -c "...toybox netcat -s 127.0.0.1 -p $PORT -L /system/bin/sh"`，内层 sh 经 shell_exec 入口转换到 `u:r:qti_init_shell:s0`，`/system/xbin/su` 换成客户端脚本转发到该端口，SuperSU 残留备份到 /sdcard/sysbak 后移除；依赖：P4；验证：两次重启后 `adb shell su -c id` = `uid=0(root) ... context=u:r:qti_init_shell:s0`、`su -c getenforce` = Enforcing、`getprop sys.boot_completed`=1、app_process md5 未变；回退：TWRP 内还原 `/sdcard/sysbak/install-recovery.sh.orig` 并删 /system/xbin/su（或整分区用 recovery.orig.bin 恢复），userdata 不受影响
- [x] P6 → G1：收尾核验（除已授权的 recovery/aboot 写入与 P5 授权的 /system root 安装外无其他分区写入、无闭源 exe、证据日志未删）；依赖：P5；验证：`work\backup\*.log` 与 `work\root\` 记录齐全，写入仅限 w recovery / w aboot / 替换 /system/bin/install-recovery.sh 与 /system/xbin/su / 移除 SuperSU 残留（均有 /sdcard/sysbak 备份），boot 分区未改；回退：若发现越界写入，立即停止并在契约 evidence 记录。
