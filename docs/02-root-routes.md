# 02 · 七条 root 路线逐条判定

> 目标：在这台 `R9sk_11_A.37` 上拿到 uid 0 且**能持久化**。
> 判定标准：① 有没有入口；② 有没有可执行的工具链；③ 成功率高不高；④ 数据/变砖风险。

---

## 总览

| # | 路线 | 入口 | 工具链 | 成功率 | 风险 | 判定 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | OPPO 官方解锁 / 深度测试 | ❌ 无 | — | 0 | — | **不可行** |
| 2 | `fastboot oem unlock` | ❌ 无 | — | 0 | — | **不可行** |
| 3 | 一键 root（KingRoot 等） | ❌ 服务已死 | — | ≈0 | 中（广告/木马） | **不可行** |
| 4 | 9008 EDL 线刷 | ✅ 芯片级 | ✅ 有 | 高 | 中高（变砖/带毒工具） | **唯一可行** |
| 5 | 工程模式后门 | ✅ 未授权广播（已实测） | ⚠️ 只到 system uid | 0（拿不到 root） | 低 | **不可行（但可提权到 system）** |
| 6 | 公开内核 CVE | ✅ 漏洞未修 | ❌ 无现成利用 | 低（需移植） | 低（研究）/ 高（跑崩） | **研究可行，交付不可行** |
| 7 | Shizuku / adb 免 root | ❌ 无法启动 | — | 0 | — | **不可行** |

---

## 1. OPPO 官方 BL 解锁 / 深度测试

### 事实

- OPPO/一加的「深度测试」是官方解锁 BL 的唯一合法通道。
- 2026-06 的一加公告里，支持机型全部是 **一加 15 / Ace 6 / 平板 2 及之后的新机**。
- OPPO 侧的规则更严：**R11 之前的机型从来没有官方解锁 BL 的方法**（ROM 乐园 2024-03 的整理明确写了这一点）。
- R9s 系列最高只到 **ColorOS 3.0（Android 6）**，连深度测试 App 的安装门槛（通常要求 ColorOS 5.0+ / Android 8+）都达不到。

### 判定

**不可行。** 不是「难」，是**通道不存在**：没有申请入口、没有审核对象、没有可解锁的机型白名单条目。

> 网上任何声称「R9s 可以申请深度测试」的内容，要么是别的机型，要么是引流。

---

## 2. `fastboot oem unlock`

### 事实

- OPPO 在 `aboot` 里移除了 `oem unlock` 子命令。即使能进 fastboot，执行也会返回 `unknown command`。
- 本机 `verifiedbootstate=green`、`flash.locked` 未置位，说明 BL 处于锁定 + 验证启动状态。

### 判定

**不可行。** 这条路在 OPPO 机器上从来就不存在。

---

## 3. 一键 root（KingRoot / 奇兔 / 各类「免解锁」工具）

### 事实

- 这类工具的工作方式是：内置一批**已公开的内核/驱动 exploit**，逐个尝试提权。
- 它们的服务端在 2017–2019 年间陆续关闭；客户端现在能做的只有弹广告、装推广包。
- 即使工具本身还能跑，它依赖的漏洞（Dirty COW、QuadRooter 等）在**补丁 2018-06** 的机器上**已全部修复**（见 `03-cve-analysis.md`）。

### 2026-11-21 补充：本机 ROM 直接禁止 KingRoot 启动

KingRoot 5.4.0（versionCode 204）被 OPPO 的 ROM 黑名单
`/data/system/sys_rom_black_list.xml` 明确列为 `startForbidden`：

- 点桌面图标只会弹系统「应用存在风险」对话框；
- `am start` 所有组件都返回 `START_SWITCHES_CANCELED`，连界面都进不去；
- 弹窗是 OPPO 系统弹的，唯一按钮只关闭弹窗，没有「信任/白名单」入口；
- 改名单需要 root，形成死循环。

所以它不只是「服务已死」，而是**在这台 ROM 上被系统层禁止启动**。
完整逆向见 `09-kingroot-rom-blacklist.md`。

### 判定

**不可行，且有安全风险。** 除了服务已死，本机 ROM 还明确禁止它启动；
不建议在这台机器上安装任何此类 APK。

---

## 4. 9008 EDL 线刷（唯一可行）

### 原理

高通的 **EDL（Emergency Download Mode，9008）** 是芯片级下载模式，位于 `aboot` 之前，
**不受 BL 锁和验证启动约束**，可以直接往 eMMC 的任意分区写数据。

```
关机 → 按住 音量+ / 音量- → 插 USB
   → Windows 出现 Qualcomm HS-USB QDLoader 9008 (COMx)
   → MsmDownloadTool 只写两个分区：
        aboot     ← 解锁版 emmc_appsboot.mbn
        recovery  ← TWRP recovery.img
   → 手动进 Recovery → 刷 SuperSU / Magisk
   → root
```

### 为什么它能绕过 BL

BL 锁校验的是「谁来写分区」。9008 模式下，写入由 **PBL/SBL 的下载协议**执行，
此时 `aboot` 还没被加载，自然没有校验逻辑。代价是：**写错 `aboot` 会直接进不了 fastboot**，
只能靠「还能进 9008」救回来。

### 可行性依据

| 来源 | 内容 | 可信度 |
| --- | --- | --- |
| 博客园《【刷机】OPPO R9st 获取 Root 权限》(2026-07) | 同平台 R9st（MSM8953 / 3.18.24 / Android 6）实测成功，只刷 aboot + recovery | 高（有完整步骤和结果） |
| ROM 乐园《OPPO A57 R9s R9SK 无需解锁线刷 TWRP》 | 明确点名 R9sk，步骤一致 | 中高 |
| 7to《OPPO R9s MIFlash 线刷 TWRP》 | R9s 的另一套工具链（MiFlash 变体） | 中 |

> ⚠️ 三篇都是**二手资料**，没有一篇是在这台具体机器上验证的。
> 但「同 SoC + 同内核 + 同代 BL」的组合足够强，可以认为**大概率可行**。

### 判定

**可行，但被 USB 阻塞。** 完整操作、文件清单、风险控制见 `04-9008-edl.md`。

---

## 5. 工程模式后门

### 事实（本次逆向的核心产出）

`com.oppo.engineermode`：

- `sharedUserId="android.uid.system"` → 进程以 **system（uid 1000）** 运行
- 264 个 Activity / 8 个 Service / 4 个 Receiver / 1 个 Provider
- 几乎所有组件都加了 `oppo.permission.OPPO_COMPONENT_SAFE`（签名级权限）
- **但 `EngineerModeActionReceiver` 没有任何权限保护**，action 是 `com.oppo.engineermode.EngineerModeMain`

这意味着：**任何普通 App 都能给它发广播**，让它以 system 身份执行动作，包括：

```
order = "*#8011#"  →  Settings.Global.putInt("adb_enabled", 1)
                      SystemProperties.set("persist.sys.usb.config", "diag,adb")
                      SystemProperties.set("persist.sys.allcommode", "true")
                      ...
order = "<其余暗码>" → 以 system 身份 startActivity 打开受 OPPO_COMPONENT_SAFE 保护的页面
```

### 为什么它不是 root

| 维度 | 工程模式进程 | root |
| --- | --- | --- |
| uid | 1000（system） | 0 |
| SELinux 域 | `system_app` | `su` / `magisk` |
| 能写 `/system` | ❌ | ✅ |
| 能开 `/dev/tun` | ❌ | ✅ |
| 能改 `selinux_enforcing` | ❌ | ✅ |
| 能装 Magisk 模块 | ❌ | ✅ |

### 判定

**拿不到 root。** 它是一个真实的 **App → system uid** 提权（已在真机验证，见 `05-engineermode-audit.md`），
但天花板就在 `system_app` 域，离 root 还差一整个 SELinux 策略层。

唯一有实用价值的动作是「用普通 App 打开 adb」——而 **adb 又依赖 USB**，所以仍然回到同一个阻塞点。

详见 `05-engineermode-audit.md`。

---

## 6. 公开内核 CVE

### 事实

补丁级别 **2018-06-05** 决定了可用漏洞的范围：

| 漏洞 | 公开时间 | 本机状态 |
| --- | --- | --- |
| Dirty COW (CVE-2016-5195) | 2016-10 | ❌ 已修 |
| QuadRooter (CVE-2016-2503/2504/2059/2060) | 2016-08 | ❌ 已修 |
| CVE-2017-* 系列 | 2017 | ❌ 已修 |
| **CVE-2019-2215**（binder UAF） | 2019-10 | ✅ 未修；漏洞真实但**实机证伪**（见 `08-cve-lab.md`） |
| CVE-2020-0041 / 0423（binder） | 2020 | ✅ 未修，但 PoC 面向 Android 8/9 |
| CVE-2021-0920（unix socket GC） | 2021 | ✅ 未修，公开 PoC 少 |

### 为什么「有漏洞」≠「能 root」

公开 PoC 基本全是 **Pixel 2 + 特定内核版本**：

1. **拿不到内核基址**：`/proc/kallsyms` 地址全 0，`perf_event_paranoid=3`，需要另找 leak 或解 `boot.img`
2. **结构体偏移不对**：`binder_thread` / `epoll` 布局随内核版本变化，必须逐个校准
3. **SELinux 拦路**：拿到 kernel R/W 后还要改 `cred->security` 或 `selinux_enforcing`
4. **竞态不稳定**：UAF 类漏洞十次崩九次是常态
5. **不能持久化**：`/system` 只读 + dm-verity + BL 锁，重启即失效

### 判定

**研究可行，交付不可行。** 熟练的内核漏洞研究者需要 1–2 周；没有 exploit 开发经验基本做不出来。
详见 `03-cve-analysis.md`。

---

## 7. Shizuku / adb 免 root

### 事实

- Shizuku 的工作方式是：**由 adb（或 root）启动一个带 `shell` uid 的服务**，普通 App 通过它借用权限。
- 也就是说，**Shizuku 的前置条件恰好就是 adb 或 root**。
- 本机：adb 不可用（USB 不枚举），root 不可用。
- 已推送的 `shizuku-11.0.0.apk`（minSdk 23，唯一兼容 Android 6 的版本）**装得上但起不来**。

### 判定

**不可行。** 它是「有 adb 之后的便利工具」，不是「没有 adb 时的替代方案」。

---

## 附：root 之后能得到什么

| 能力 | root 前 | root 后 | 备注 |
| --- | --- | --- | --- |
| `/dev/tun` | ❌ | ✅ | ZeroTier / OpenVPN / WireGuard 的前提 |
| Termux 跑 OpenVPN | ❌ | ✅ | root 源里有 `openvpn 2.4.8-1` |
| ZeroTier | ❌ | ⚠️ | 无 Termux 包，需自行交叉编译 |
| 改 `/system` | ❌ | ⚠️ | dm-verity + BL 锁，需先关验证或改 boot |
| 装 Xposed / Magisk 模块 | ❌ | ✅ | 老平台模块生态有限 |
| opencode2 | ❌ | ❌ | 与 root 无关，是 Node/API 版本问题 |
| Termux:API App | ❌ | ❌ | minSdk 24，Android 6 装不上 |

**一句话**：root 解决的是「网络与系统写入」，解决不了「Android 6 太老」。
