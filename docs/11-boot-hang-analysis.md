# 启动卡 logo 事件分析（R9sk / R9s_11_A.37_191127 / Android 6.0.1）

日期：2026-11-24（设备时钟 00:0x–00:4x）

## 结论

**手机从来没坏，是"看不见"造成的误判。**

两个叠加因素：

1. **新 /data 默认 `adb_enabled=0`** → adbd 不启动。
2. **OPPO ColorOS 首次开机 USB 默认「仅充电」** → USB gadget 完全不配置，主机侧
   `usbipd` / `Get-PnpDevice` 看不到任何 `22D9|18D1|05C6` 设备。

于是"健康的首次启动"在 PC 侧表现和"死机"完全一样：**零枚举、零 adb、屏幕停在 OPPO logo
（实为 bootanimation + dex2oat 编译全系统应用）**。每次等 5 分钟就强杀进 TWRP，等于
反复打断首次启动的 dex2oat，所以每次都"卡"。

## 证据

| 证据 | 含义 |
|---|---|
| `/data/misc/audio`、`/data/misc/camera` mtime = 启动后 20 分钟点 | init 已跑到 HAL 启动阶段，不是早期死锁 |
| `/data/tombstones/tombstone_01` = `mm-pp-dpps` SIGABRT `getService(SensorService) NULL` | 次生崩溃（system_server 尚未注册服务），不是根因 |
| `/data/dalvik-cache` 只有 `arm/ arm64/ profiles` 目录 | dex2oat 还没产出 → 启动确实还很早 |
| `/system` 上 `e2fsck -fn` | 仅 `Padding at end of inode bitmap is not set`（无害），无真实损坏 |
| `/cache/recovery/last_kmsg*` | 全部是 recovery 自己的启动日志，拿不到系统启动日志 |
| `/sys/fs/pstore/*` | 被 TWRP 那次启动覆盖，失败那轮的内核日志已丢 |
| **健康基线（/data 初始化完成后）** | **adb 18s 出现，`boot_completed=1` 28s** |

## 关键机制（从 boot.img ramdisk 的 init.rc 反查）

```
service flash_recovery /system/bin/install-recovery.sh
    class main
    oneshot
```

- 它是 init 的 **`class main` 服务**（fork+exec），**不是阻塞式 builtin `exec`**
  → `install-recovery.sh` 里做什么都不可能阻塞 init 的启动序列。
- 没有 `seclabel` → 以 init 上下文执行 → 这正是 rootd 的 shebang 技巧
  （`/system/bin/sh -c` 触发 `type_transition init shell_exec:process qti_init_shell`）成立的原因。
- 只在 `init.rc` 里定义一次，其他 rc（init.at.rc / init.rf.rc / init.wlan.rc）里都是注释掉的。

**所以"rootd 卡启动"的假设被机制否证。**

## 本轮实际做过的操作

1. 取证（只读）：pstore、`/cache/recovery/last_kmsg*`、tombstone、`/data` 目录结构、
   `/system` 的 `e2fsck -fn`。
2. `/system` 回滚到已验证可开机组合（`work/root/rollback_v6.sh`）：
   - `/system/bin/install-recovery.sh` → `#!/system/bin/sh\nexit 0`，0755，`system_file`
   - 删除 `/system/xbin/su`
   - 删除 `/data/adb`、`/data/magisk_backup_*`（Magisk 惰性残留）
   - **未动 /data 文件系统，未重新格式化**（保留已完成的 FDE，避免再来一次加密）
3. boot 分区保持原厂：首 2K md5 `58afbc99ca9f5c61dd12b42c5ac43913`。
4. **拔线 → 强制关机（音量+ + 电源 10s）→ 开机**：**正常进系统**。

## 按键速查（实测，2026-11-24 修正）

| 目的 | 操作 |
| --- | --- |
| **强制关机**（卡 logo / 死机时） | **先拔掉数据线** → 同时按住 **音量+ 和 电源键** 约 10 秒 → 屏幕全黑 |
| 进 TWRP | 关机后按住 **音量-** → 点一下电源 → 继续按住 音量- |
| 进 9008 | 关机后同时按住 **音量+ 和 音量-** → 插 USB → 保持约 5 秒 |

> ⚠️ **插着数据线时只按电源键关不掉**（只会回到 OPPO 充电模式 / 毫无反应）。
> 必须先拔线，且必须用 **音量+ + 电源键** 组合。之前"长按电源 10 秒即可关机"的说法是错的，已按实测修正。

## 当时的状态快照（2026-11-24 00:4x，Magisk 23.0 之前）

> 下面是"撤掉 rootd、Magisk 还没装"那一刻的状态，仅作复盘对照。**最终状态见 `docs/12`、`docs/13`。**

- `sys.boot_completed=1`
- `ro.boot.verifiedbootstate=orange`（BL 解锁，`oem unlock-go` 生效）
- `ro.crypto.state=encrypted`（FDE 用默认口令，TWRP 可自动解密）
- `sys.usb.config=mtp,mass_storage,adb`
- 无 root（rootd 已撤除），boot 原厂

## 后续 root 试验的正确姿势（重要）

现在 /data 已完成初始化，`adb_enabled=1`，因此：

- **健康启动 ⇒ 18–20s 内 `adb devices` 必然出现 `244f**** device`**。
- 若部署 rootd 后 40s 内 adb 不出现，才是真的卡住（此时进 TWRP 跑 `rollback_v6.sh` 撤销，1 分钟内恢复）。

绝不要再对**刚格式化过的 /data** 做"等 5 分钟就强杀"的判断 —— 首次启动要 5–15 分钟，
且期间 USB 完全不可见。

## 保留的证据文件

- `work/backup/tombstone_01.txt`（失败那轮的 native crash）
- `work/backup/cache-last_kmsg*.txt`（recovery 启动日志）
- `work/backup/console-ramoops-*.txt`
- `work/backup/ramdisk_x/*.rc`（boot.img ramdisk 解包出的全部 init rc）
- `work/backup/rollback_v6.log`
