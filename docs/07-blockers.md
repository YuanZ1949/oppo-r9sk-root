# 07 · 当前阻塞点与决策树

> 这份文档回答一个问题：**现在到底卡在哪，下一步做什么。**

---

## 阻塞点一览

| # | 阻塞点 | 影响 | 谁能解决 |
| --- | --- | --- | --- |
| **B1** | **USB 不枚举** | adb、9008、fastboot 全部不可用 | **用户**（换线 / 去 OTG / 修尾插） |
| B2 | Termux 被系统杀，sshd 掉线 | 远程操作中断 | 用户（打开一次 Termux） |
| B3 | ZeroTier 无 Android 6 APK | 设备侧组网 | 需要 root + 自行编译 |
| B4 | opencode2 需要新 Node | 无法运行 | 平台限制，无解 |
| B5 | 没有 9008 工具与整包固件（loader 已找到） | 无法开始刷机 | 用户下载 + 校验 |

---

## B1 · USB 不枚举（最关键）

### 症状

- 手机插电脑，**Windows 没有提示音**
- 设备管理器里没有任何 OPPO / Qualcomm / Android 设备
- `adb devices` 空
- 但手机能正常充电、能连 Wi-Fi、SSH 可用

### 三个可能原因（按概率排序）

| 假设 | 判断方法 | 处理 |
| --- | --- | --- |
| **OTG 转接头让手机进了 Host 模式** | 拔掉转接头，用直连线 | 去掉 OTG，直连 PC |
| **线是充电线（只有电源针，没有 D+/D-）** | 换一根确定传过文件的线 | 换线 |
| **手机尾插 / PC USB 口坏** | 换口、换电脑试 | 修硬件 |

### 为什么 OTG 会导致这个现象

OTG 线会把手机的 `ID` 脚接地，手机判定为 **Host**，于是它给外设供电，而不是作为 Device 被 PC 识别。
9008 和 adb 都要求手机是 **Device** 角色，所以 OTG 在场时两者都不可能工作。

### 验证顺序（严格按顺序）

```
1. 拔掉 OTG 转接头
2. 换一根「确定传过文件」的 Micro-USB 线
3. 插到 PC 的【主板后置 USB 口】（不要用前面板/扩展坞）
4. 听有没有提示音
5. 设备管理器看有没有新设备（哪怕带感叹号）
6. 有设备 → 装驱动；没设备 → 换线/换口/换电脑
```

### 一个有利的变化

工程模式测试已经把 USB 配置改成 `diag,adb` 并开启了 adb（见 `05-engineermode-audit.md`）。
所以**线一修好，adb 应该直接可用**，不需要再去开发者选项里点开关。

### 实时监视 USB 是否枚举（PC 上跑）

在 PC 上开一个终端，执行：

```powershell
ssh r9sk "while true; do echo \$(date +%H:%M:%S) state=\$(cat /sys/class/udc/7000000.dwc3/state) speed=\$(cat /sys/class/udc/7000000.dwc3/current_speed); sleep 1; done"
```

然后把手机关机、按住音量上下、插 PC 后置 USB 口，观察输出：

- 一直是 `state=not attached` / `speed=UNKNOWN` → 手机根本没看到数据链路（线/口/尾插）。
- 变成 `state=configured` 或出现 `speed=high/full` → 物理层通了，接着看
  Windows 设备管理器是否出现 `Qualcomm HS-USB QDLoader 9008` 或 `Android ADB Interface`。

### 2026-11-21 实测补充

| 项 | 值 | 解读 |
| --- | --- | --- |
| `sys.usb.state` | `diag,adb` | 软件配置正确 |
| `persist.sys.usb.config` | `diag,adb` | 开机默认就是 diag+adb |
| `/sys/class/udc/7000000.dwc3/state` | `not attached` | 当前没有主机/数据链路 |
| `current_speed` | `UNKNOWN` | 未枚举 |
| `/sys/class/power_supply/usb` | `online=1, type=USB_DCP` | 接的是 D+/D- 短接的专用充电器 |

> **关键**：DCP 充电器本来就不会枚举数据，所以上面的 `not attached`
> **不能**证明数据线坏了。B1 的判据仍然是：
> 换一根确定传过文件的线 + PC 后置 USB 口，看 Windows 有没有提示音、
> 设备管理器有没有新设备。若仍然毫无反应，才指向尾插/主板数据线故障。

### 只有 USB 通了，才能做这些

| 动作 | 依赖 |
| --- | --- |
| `adb devices` | USB 枚举 + adb 授权 |
| 9008 刷机 | USB 枚举（9008 模式） |
| fastboot | 需要先刷解锁 aboot |
| Shizuku 启动 | adb 或 root |

---

## B2 · Termux 被系统杀

### 症状

- `ssh r9sk` → `Connection refused`
- `ping 192.168.2.205` → 通

### 原因

Android 6 的 LMK 在内存紧张时会回收后台进程。Termux 被切到后台后，
wake-lock 不再生效，进程被回收，`sshd` 随之消失。

### 处理

**在手机上打开一次 Termux**。`.bashrc` 里的托管块会自动：

```bash
termux-wake-lock
pgrep -f sshd >/dev/null || sshd
```

### 长期方案（可选）

- 装 `Termux:Boot`（如果找到兼容 Android 6 的版本），开机自启
- 把 Termux 加入「电池白名单 / 自启动白名单」（ColorOS 的省电策略）
- 不要长时间把 Termux 切后台

---

## B3 · ZeroTier

| 障碍 | 详情 |
| --- | --- |
| APK 版本 | 手机上现有 `zerotier-one.apk` v1.14.0-2，**minSdk=26**，Android 6 装不上 |
| 官方渠道 | ZeroTier 不在 Play 之外分发 APK |
| Termux 包 | `termux-main-21` 里没有 `zerotier-one` |
| 内核接口 | 需要 `/dev/tun`，无 root 打不开 |

**结论**：ZeroTier 在这台机器上**必须等 root**，而且 root 之后还要自行交叉编译 arm 版 `zerotier-one`。
更现实的替代是 **OpenVPN**（root 源里有 `openvpn 2.4.8-1`）。

---

## B4 · opencode2

| 要求 | 本机 |
| --- | --- |
| Node 18+ | Node 12.13 |
| 现代 OpenSSL / glibc 兼容 | Android 6 bionic |
| 磁盘/内存 | 有限 |

**无解**，与 root 无关。除非有人做 Android 6 的兼容移植。

---

## B5 · 9008 工具链

本机 `C:\MyFile` 扫描三层深度，**没有任何** MsmDownloadTool / 线刷包 / TWRP / 高通驱动。

需要准备：

1. Qualcomm USB Driver（Win10 需关驱动签名）
2. R9sk 线刷包：公开镜像有 **A.14 / A.18 / A.22(firehose) / A.26 / A.53**；
   本机是 **A.37_191127**，没有找到 A.37 的公开镜像。
   只刷 recovery 时可用较老版本的 firehose + 分区表，但属跨版本操作。
3. 改版 MsmDownloadTool（先跑 `MsmDownloadTool-0.exe` 一次，再跑原版）；
   R9sk 项目号 **16027**。⚠️ 来源不可信，建议虚拟机断网运行。
4. R9sk 专用 TWRP：`r9s-twrp-3.2.3-0-20180906.img`（170112+）
   或 `r9s-twrp-3.0.2.0-20170107-old.img`（161202-）；
   必要时加刷 R9sk 的 `emmc_appsboot.mbn`（**不要用 R9s/R9st 的**）。
5. Firehose loader：已从公开集合拿到 **R9s 签名**的全功能 8953 loader
   `prog_emmc_firehose_8953_ddr_oppo_r9s.mbn`（359048B，MD5
   `1ded75bb22c4e9334462f8be717ac907`，无 Firehose 二次认证门）。
   R9sk 是否接受同一 OPPO 根证书，需进 9008 用 Sahara 握手实测；
   若拒绝，回退到 R9sk A.18/A.22 包内 loader。详见 `04-9008-edl.md` §9.5.1。

> 详细步骤、镜像来源与替代工具链见 `04-9008-edl.md` §9。
> 原始检索记录见 `evidence/2026-11-21-9008-research.txt`。

---

## 决策树

```
USB 通了吗？
├─ 否 → 换线 / 去 OTG / 换口（B1）
│        └─ 还是不通 → 尾插/主板问题，考虑维修或放弃
└─ 是
   ├─ adb 能用吗？（应该已经自动开了）
   │   ├─ 能 → 可以先做免 root 的事（Shizuku、文件管理、调试）
   │   └─ 不能 → 检查驱动 / 授权弹窗
   └─ 要 root 吗？
       ├─ 要 → 9008（04-9008-edl.md）
       │        ├─ 有工具和包 → 开刷
       │        └─ 没有 → 先下载 + 校验哈希
       └─ 不要 → 停在当前状态（Termux 节点）
```

---

## 现在（今天）能推进的三件事

| 优先级 | 事项 | 需要谁 |
| --- | --- | --- |
| P0 | 确认数据线/OTG 情况，让 `adb devices` 能认到机器 | 用户 |
| P1 | 打开一次 Termux，恢复 SSH | 用户 |
| P2 | 决定：走 9008（要 root）还是停在 Termux（不要 root） | 用户 |

---

## 不要做的事

- ❌ 不要在 USB 没通的情况下买 9008 工具/刷机包（可能白买）
- ❌ 不要用 R9s / R9st 的 aboot 刷 R9sk
- ❌ 不要装来源不明的「一键 root」
- ❌ 不要在没备份 efs 的情况下刷机
- ❌ 不要把 `termux` 和 `k50` 搞混（先 `getprop ro.product.model`）
