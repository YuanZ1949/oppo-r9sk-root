# 01 · 实机画像

> 采集方式：PC 通过 SSH 登录 Termux（`ssh termux`），执行只读命令。
> 原始输出：`evidence/2026-11-21-device-props.txt`、`evidence/2026-11-21-termux-privileges.txt`
> 采集时间：2026-11-21

---

## 1. 基本身份

| 项 | 值 | 采集命令 |
| --- | --- | --- |
| 型号 | `OPPO R9sk` | `getprop ro.product.model` |
| 设备代号 | `R9sk` | `getprop ro.product.device` |
| 固件版本 | `R9sk_11_A.37_191127` | `getprop ro.build.display.id` |
| 构建日期 | `2019-11-27 15:52:44 CST` | `getprop ro.build.date` |
| Android | `6.0.1`（API 23） | `getprop ro.build.version.release` |
| 安全补丁 | `2018-06-05` | `getprop ro.build.version.security_patch` |
| 平台 | `msm8953`（骁龙 625） | `getprop ro.board.platform` |
| 内核 | `3.18.24-perf-g1ec9dfb-01518-g7eeba31` | `uname -r` |
| ABI | `arm64-v8a`，`abilist=arm64-v8a,armeabi-v7a,armeabi` | `getprop ro.product.cpu.abilist` |
| zygote | `zygote64_32` | `getprop ro.zygote` |
| 构建类型 | `user` | `getprop ro.build.type` |
| 可调试 | `ro.debuggable=0` | `getprop ro.debuggable` |

### 为什么这些值重要

- **R9sk ≠ R9s ≠ R9st**：三者是同一代不同渠道/配置，`aboot`、分区表、线刷包都不能混用。
  网上大量教程写「R9s 通用」，只能当参考，不能当依据。
- **补丁 2018-06**：这是整份研究的分水岭。2016–2018 上半年的漏洞全部已修，
  2018-07 之后公开的才可能有效（见 `03-cve-analysis.md`）。
- **arm64 + 32 位用户态**：Termux 当前装的是 32 位包（`uname -m` 返回 `armv8l`），
  能用但拿不到 aarch64 包，性能与生态都受限。
- **`user` + `ro.debuggable=0`**：没有 `run-as`、没有可调试系统进程，adb 调试面很窄。

---

## 2. 启动链与完整性

| 项 | 值 | 含义 |
| --- | --- | --- |
| `ro.boot.verifiedbootstate` | `green` | 验证启动通过，BL 锁定 |
| `ro.boot.flash.locked` | （空） | 该属性未设置，不能作为解锁依据 |
| `ro.boot.veritymode` | （空） | dm-verity 状态未单独暴露 |
| `ro.boot.secureboot` | （空） | — |
| `/proc/cmdline` | 无 `androidboot.verifiedbootstate` 等字段 | 内核 cmdline 被裁剪 |

**结论**：`green` 说明 boot / system 分区哈希校验通过，**任何对 `/system` 的持久化修改都会导致启动失败**。
这也是为什么「临时 root」在这台机器上意义有限——重启即失效，而持久化必须动 boot/recovery 分区。

---

## 3. 安全姿态

| 项 | 值 | 采集方式 |
| --- | --- | --- |
| SELinux | `enforcing`（`/sys/fs/selinux/enforce = 1`） | `cat /sys/fs/selinux/enforce` |
| Termux 进程域 | `u:r:untrusted_app:s0:c512,c768` | `cat /proc/self/attr/current` |
| `perf_event_paranoid` | `3` | `cat /proc/sys/kernel/perf_event_paranoid` |
| `kptr_restrict` | 未设置（但 kallsyms 地址仍为 0） | `cat /proc/sys/kernel/kptr_restrict` |
| `dmesg_restrict` | 未设置 | `cat /proc/sys/kernel/dmesg_restrict` |
| `/proc/kallsyms` | 167148 行，**所有地址为 `0000000000000000`** | `head -3 /proc/kallsyms` |
| `/data` | `/dev/block/dm-0`，ext4，`seclabel` | `mount` |
| `/system` | 只读（`ro`），`seclabel` | `mount` |
| su | `/system/bin/su`、`/system/xbin/su` 均不存在 | `ls` |

### 关键含义

1. **SELinux 是第二道门**。内核提权成功 ≠ 能改系统。
   `untrusted_app` 域即使拿到 uid 0，仍会被策略拦住写 `/system`、加载内核模块、改 `selinux_enforcing`。
2. **kallsyms 地址清零**意味着漏洞利用第一步（拿内核基址）就必须另找 info leak，
   或者从固件包里解 `boot.img` 反推符号表。
3. **`perf_event_paranoid=3`** 关掉了 perf 相关的信息泄漏原语，很多公开 exploit 的第一步就废了。
4. **`/data` 加密**：取证/备份只能在开机解锁后做；9008 直接读 userdata 拿到的是密文。

---

## 4. 权限与可写面

Termux 进程：

```
uid=10087(u0_a87) gid=10087(u0_a87)
groups=10087(u0_a87),3003(inet),9997(everybody),50087(all_a87),99909997(u999_everybody)
```

- **有 `inet`（3003）**：可以正常收发网络，SSH / HTTP / 自定义 TCP 都没问题。
- **不在 `vpn` 组**：`/dev/tun` 是 `crw-rw---- system vpn`，uid 10087 打不开。
  → 任何需要 TUN 的方案（ZeroTier、OpenVPN、WireGuard、tun2socks）**无 root 全部不可用**。
- **共享存储可用**：`~/storage/downloads -> /storage/emulated/0/Download`，可读写。

`/dev/net/tun` 不存在（Android 只有 `/dev/tun`）。

---

## 5. 系统里的可疑/可利用面（只读盘点）

### 5.1 setuid 二进制

```
-rwxr-xr-x 1 root   shell   10096 antradio_app
-rwxr-xr-x 1 root   shell   72264 dexdump
-rwxr-xr-x 1 root   shell  483480 klogd
-rwxr-xr-x 1 root   shell   10096 mdm-notify
-rwxr-xr-x 1 root   shell 1220008 tcpdump
-rwxr-x--- 1 system shell 1042672 xkit_10
```

- 全部 **没有 setuid 位**（只有执行位），owner 是 root/system，普通 App 无法借此提权。
- `xkit_10` 是 OPPO 诊断工具，`-rwxr-x--- system shell`，Termux 连执行权限都没有。
- `klogd` / `tcpdump` 是 Android 自带调试工具，非 setuid，无提权价值。

### 5.2 init 服务

```
[init.svc.engineermode-sh]: [stopped]
[init.svc.cnss_diag]:       [stopped]
[init.svc.ipacm-diag]:      [running]
```

`engineermode-sh` 存在但处于 stopped —— 说明系统里**确实有一个以 root 运行的工程模式 shell 服务定义**，
但当前没有代码路径去启动它（详见 `05-engineermode-audit.md` 的逆向结论）。

### 5.3 预装 OPPO 组件

`pm list packages -s` 里与提权相关的主要是：

| 包 | 说明 |
| --- | --- |
| `com.oppo.engineermode` | 工程模式，`sharedUserId=android.uid.system`，本次重点审计对象 |
| `com.oppo.oppologkit` | 日志工具，接收 `*#800#` 跳转 |
| `com.coloros.oppoguardelf` | 系统守护 |
| `com.oppo.rftoolkit`（未安装，仅被暗码引用） | 射频工具，暗码 `*#7332#` 等指向它 |

---

## 6. 复现方式

```bash
# PC 侧
ssh termux 'getprop | sort'                       # 完整属性
ssh termux 'pm list packages -s'                  # 系统包
ssh termux 'find /system/bin /system/xbin -perm -4000 -type f'
ssh termux 'cat /sys/fs/selinux/enforce; cat /proc/self/attr/current'
ssh termux 'head -3 /proc/kallsyms; wc -l /proc/kallsyms'
```

SSH 配置在 `C:\Users\yuan\.ssh\config` 的 `Host termux`（端口 8022，用户 `u0_a87`）。
