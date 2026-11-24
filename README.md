# OPPO R9sk Root 与可用性研究

> **研究日期**：2026-11-21
> **设备**：OPPO R9sk（`R9sk_11_A.37_191127`）/ Android 6.0.1 / ColorOS 3.0 / MSM8953 / 内核 3.18.24
> **原则**：只读采集，先验证再动手；所有结论标注「实测」或「二手资料」
> **脱敏**：IMEI → `[REDACTED-IMEI]`，设备序列号 → `244f****`，`net.hostname` → `android-[REDACTED]`，IPv6 EUI-64 → `fe80::[REDACTED]`；
> `work/`（分区备份、boot 镜像、截图、`magisk.db`、efs/modemst 转储）**不入库**，见 `.gitignore`。

---

## 一句话结论

**这台机器已经拿到 root（2026-11-24 实测）：Magisk 23.0 + BL 解锁，App 级授权、模块、MagiskHide 全部可用。**
唯一可行的路线是：9008 EDL 线刷解锁版 `aboot` → TWRP → Magisk 23.0。
其余所有路线（官方解锁、fastboot、一键 root、Shizuku、工程模式、公开 CVE）**全部走不通或不可交付**，原因各不相同，逐条列在下面。

| 验收项 | 实测结果 |
| --- | --- |
| root | `su -c id` → `uid=0(root) gid=0(root) context=u:r:magisk:s0`，不弹授权框 |
| Magisk | `23.0:MAGISK` / `23000`，`/sbin/su`、`/sbin/magisk` 在位 |
| 授权记录 | `policies`: uid 2000（`com.android.shell`）→ `policy=2 (ALLOW)` |
| MagiskHide | `MagiskHide is enabled`，重启保持 |
| Magisk App | `com.topjohnwu.magisk` @ `/data/app/com.topjohnwu.magisk-2/base.apk` |
| 模块系统 | `magisk --install-module` 实测可用 |
| 开机 | `boot_completed=1` 28s（健康基线 25–31s） |
| BL | `/proc/cmdline` → `androidboot.verifiedbootstate=orange`（已解锁） |
| SELinux | `Enforcing` |

证据链：`docs/11-boot-hang-analysis.md`（卡 logo 的真实根因）、`docs/12-magisk-success.md`（Magisk 装法与启动验证）、
`docs/13-magisk-app-and-coloros-install-gate.md`（Magisk App 安装 + 击穿 ColorOS「验证身份」拦截）。

> 注：开机后 `getprop ro.boot.verifiedbootstate` 报 `green` 是 **Magisk 做的属性伪装**（`/sbin/magisk32`、`/sbin/magisk64` 内含该字符串），
> 真实状态以 `/proc/cmdline` 的 `androidboot.verifiedbootstate=orange` 为准。

**历史（2026-11-22）**：~~手机插上电脑后 USB 层从未枚举成功，所以 adb 和 9008 同时不可用。~~
**（2026-11-22 更新）USB/adb 已打通**：数据线接 PC 后置口后可稳定枚举，`adb devices` 能认到
`244f**** device product:R9sk model:OPPO_R9sk`，`adb shell` 可用（uid 2000/shell）。
详见 `evidence/2026-11-22-adb-online.txt`。**9008 驱动已装好**（`oem139.inf`，WHQL 签名，
`evidence/2026-11-22-qdloader-driver.txt`），**开源 bkerler/edl 工具链也已就绪**（支持 `--serial`，
不再需要 MsmDownloadTool 或 Zadig）。**TWRP `twrp-3.7.1_12-4-R9s.zip` 已下载并通过
SHA-256 + ZIP CRC 双重校验、已解压**（见 `evidence/2026-11-22-twrp-source.txt`）。
PC 端准备全部就绪。**后续（2026-11-23/24）已全部执行完毕**：只读备份 7 个分区、写 TWRP、解锁 BL、
装 Magisk 23.0、装 App 并授权，详见下面「现在该做什么」。

---

## 结论总表

| 路线 | 结论 | 关键依据 |
| --- | --- | --- |
| OPPO 官方 BL 解锁 / 深度测试 | ❌ 不支持 | 深度测试只覆盖 R11 之后机型；R9s 系列最高 ColorOS 3.0（Android 6） |
| `fastboot oem unlock` | ❌ 命令被阉割 | OPPO 在 aboot 中移除该命令，无 fastboot 解锁通道 |
| 一键 root（KingRoot / 奇兔 / 各类「免解锁」工具） | ❌ 已失效（本机还禁止 KingRoot 启动，换版本也无效） | 服务端/漏洞链早已下线；本机 `sys_rom_black_list.xml` 按包名拦截，公开 dump 里 KingRoot 条目是 `0,max`（全版本），弹窗按钮只关闭不放行（`docs/09-kingroot-rom-blacklist.md`） |
| **9008 EDL + 解锁 aboot + TWRP + Magisk 23.0** | ✅ **已实现（2026-11-24 实测）** | 同平台（R9st / MSM8953 / 3.18.24）有 2026-07 实操记录；本机 `su -c id` = `u:r:magisk:s0`（`docs/12`、`docs/13`） |
| 工程模式后门（`com.oppo.engineermode`） | ⚠️ 有真实缺陷，但**拿不到 root** | 存在未加权限保护的广播接收器，可越权改系统属性/拉起受保护页面；进程是 `system` uid 而非 root |
| 公开内核 CVE（CVE-2019-2215 等） | ❌ **已实测证伪，不能当交付路径** | 漏洞、UAF、对象回收均实测成立；但 `writev`/`readv` 对合法内核地址双向 EFAULT，改写变不成任何读写原语（G2 失败），`PTE_PXN` 另封死 ret2usr/ret2heap（见 `docs/08-cve-lab.md` §3.4、§11） |
| Shizuku（免 root 的 adb 权限代理） | ✅ 链路打通，但仍不是 root | 2026-11-22 装了 Material Files 1.7.5（F-Droid 签名）并完成 Shizuku 授权，binder 已送达；能列 `/`，但 `/data` 仍 `AccessDeniedException`（shell 也没权限）。重启后需重跑 start.sh |
| ZeroTier / OpenVPN（设备侧） | ❌ 无 root 时不可用 | `/dev/tun` 属 `system:vpn`，Termux uid 10087 无权限；ZeroTier 官方无 Android 6 版 APK |
| opencode2 / 现代 Node 工具链 | ❌ 平台不支持 | Android 6 + arm64 + Node 12，最低要求普遍是 Node 18+/API 24+ |

---

## 这台机器到底是什么

| 项 | 实测值 | 为什么重要 |
| --- | --- | --- |
| 型号 | **OPPO R9sk**（不是 R9s） | 刷机包必须按 R9sk 找，R9s/R9st 的包不能混用 |
| 固件 | `R9sk_11_A.37_191127` | 9008 刷机前要确认版本线，避免跨版本写 aboot |
| Android | 6.0.1（API 23） | 决定所有 App 的 minSdk 门槛 |
| **安全补丁** | **2018-06-05** | 决定哪些 CVE 还没修 |
| 内核 | `3.18.24-perf-g1ec9dfb-01518-g7eeba31` | CVE 适配的结构体偏移全看它 |
| 架构 | `arm64-v8a`（`zygote64_32`） | Termux 之前装的是 32 位包，性能与包源都受限 |
| SELinux | `enforcing`，进程域 `untrusted_app` | 就算拿到内核权限，还要过 SELinux 这关 |
| `/proc/kallsyms` | 167148 条，**地址全 0** | 内核符号被隐藏，漏洞利用拿不到基址 |
| `perf_event_paranoid` | `3` | 堵掉一大类信息泄漏/利用原语 |
| `/data` | `dm-0` 加密 | 备份/取证只能在开机态做 |
| `verifiedbootstate` | **`orange`**（已解锁） | `getprop` 报 `green` 是 Magisk 的属性伪装，真实值看 `/proc/cmdline` |
| su | **Magisk 23.0**（`/sbin/su`，域 `u:r:magisk:s0`） | 出厂无 su，root 由 9008 + TWRP + Magisk 取得 |

完整 `getprop`、系统包列表、setuid 二进制清单见 `evidence/2026-11-21-device-props.txt`。

> **loader 是例外**：Firehose loader 不是按机型打包的普通固件，而是 OPPO 8953
> 签名组共用的 programmer。R9s 的 `prog_emmc_firehose_8953_ddr_oppo_r9s.mbn`
> 可作 R9sk 的首选候选；但 `aboot`、分区表和系统镜像仍必须用 R9sk 的。

---

## 目录结构

```
oppo-r9sk-root/
├── README.md                     ← 本文件：结论 + 导航
├── sources.md                    ← 全部外部资料与可信度分级
├── docs/
│   ├── 01-device-profile.md      ← 实机画像与安全姿态
│   ├── 02-root-routes.md         ← 七条路线逐条判定
│   ├── 03-cve-analysis.md        ← 补丁时间线、候选 CVE、移植成本
│   ├── 04-9008-edl.md            ← 唯一可行路线的完整操作与风险
│   ├── 05-engineermode-audit.md  ← 工程模式逆向：真实缺陷与天花板
│   ├── 06-termux-node.md         ← Termux 现状、能做什么、卡在哪
│   ├── 07-blockers.md            ← 当前阻塞点与决策树
│   ├── 08-cve-lab.md             ← CVE-2019-2215 实机可利用性实验（实测断点）
│   ├── 09-kingroot-rom-blacklist.md ← KingRoot 被 ROM 黑名单拦截的完整逆向
│   ├── 10-system-root.md         ← /system 模式 root（rootd，已弃用，仅存档）
│   ├── 11-boot-hang-analysis.md  ← 卡 OPPO logo 的真实根因（SELinux 标签 → installd）
│   ├── 12-magisk-success.md      ← Magisk 23.0 装法与启动验证
│   ├── 13-magisk-app-and-coloros-install-gate.md ← App 安装 + 击穿 ColorOS 验证拦截
│   └── 14-chroot-server.md       ← 把手机当服务器：Debian 12 chroot + sshd:2222 + 开机自启
├── scripts/                      ← 部署到设备上的脚本（可直接复用）
│   ├── 10-server.sh              ← /data/adb/service.d 开机自启（挂载 + sshd + 无线 adb 兜底）
│   └── chroot.sh                 ← 手动进 Debian chroot 的入口
├── evidence/                     ← 实机采集的原始输出（只读）
│   ├── 2026-11-21-device-props.txt
│   ├── 2026-11-21-engineermode-surface.txt
│   ├── 2026-11-21-engineermode-dump.txt
│   ├── 2026-11-21-oem-manifest.txt
│   ├── 2026-11-21-engineermode-actions.txt
│   ├── 2026-11-21-engineermode-live-test.txt
│   ├── 2026-11-21-termux-resilience.txt
│   ├── 2026-11-21-termux-inventory.txt
│   ├── 2026-11-21-termux-privileges.txt
│   ├── 2026-11-21-cve-lab.txt
│   ├── 2026-11-21-kingroot-block.txt
│   └── 2026-11-24-chroot-server.txt
├── tools/
│   └── axml_dump.py              ← 二进制 AndroidManifest/XML 解码器
└── work/                         ← 中间产物（不入库，见 .gitignore）
    ├── oem.dex                   ← 从 odex 里抠出的 dex
    ├── oem_smali/                ← baksmali 反编译结果（1947 个文件）
    └── engineermode_action_qcom.xml
```

---

## 现在该做什么

**全部步骤已完成（2026-11-24）。** 保留原清单作为复盘：

1. ~~解决 USB~~ **已完成（2026-11-22）**：`adb devices` 已认到 `244f****`，`adb shell` 可用。
   若再次断开，先查 OTG / 数据线 / PC 后置口（`docs/07-blockers.md`）。
2. ~~准备 9008 工具链~~ **已完成**：✅ Qualcomm HS-USB QDLoader 9008 驱动（`oem139.inf`，WHQL 签名）；
   ✅ 开源 edl（`work/edl/edl.py`，`--serial` 串口模式）；✅ firehose loader 在 `work/loaders/`；
   ✅ TWRP `twrp-3.7.1_12-4-R9s.zip` 已下载校验（`evidence/2026-11-22-twrp-source.txt`）。
3. ~~进 EDL 只读~~ **已完成**：`printgpt` + 7 个分区只读备份（`work/backup/`）。
4. ~~备份~~ **已完成**：`aboot` / `recovery` / `modem` / `modemst1/2` / `fsg` / `persist` 全部有 SHA256 记录。
5. ~~root~~ **已完成**：解锁 BL（`oem unlock-go` → `orange`）→ TWRP → Magisk 23.0 → App 授权。

**后续可做（都已有前提条件）：**

- **当服务器用（已完成，2026-11-24）**：Debian 12 arm64 chroot 在 `/data/debian`，`sshd:2222` 仅公钥登录、
  会话降权到 `svc`(uid 2000)，`/data/adb/service.d` 开机自启，重启 **16.5 s** 可连，
  无线 adb `5555` 兜底。详见 `docs/14-chroot-server.md`。
  当前唯一缺口：解锁时 `/data` 被清空，手机**没有保存的 WiFi**，只有蜂窝（CGNAT），需手动连一次家里 AP。
- ZeroTier / Tailscale：现在有 root，`/dev/tun`（`system:vpn`）实测 `TUN_OPEN_OK`，可在 chroot 内跑官方 arm64 包。
- 去预装 / 改 hosts / 模块：Magisk 模块系统实测可用（`magisk --install-module`）。
- 银行类 App 隐藏 root：MagiskHide 已启用，按需在 App 里勾选目标。
- ⚠️ **不要**在 Magisk App 里点「安装」升级到 24+：会失去 MagiskHide 且需要重新打补丁；23.0 是最后一代自带 Hide 的版本。

**不建议现在做的：**

- ❌ 不要下载来源不明的「一键 root」「免解锁 root」工具往手机上装
- ❌ 不要用来源不明的 R9s / R9st `aboot` 刷 R9sk。唯一例外是当前选定的
  **R9s/k 专用 TWRP 包内的 `emmc_appsboot.mbn`**（XDA 原帖明确 R9s/k 通刷），
  且写入前必须先把原机 `aboot` 读出来备份
- ❌ 不要在没备份 efs 的情况下刷任何东西
- ❌ 注意 GitHub 上名为 `r9s` 的 TWRP 可能是**三星 S21 FE** 的代号（见证据文件）
- ❌ 不要指望 CVE 路线能「今晚搞定」——2026-11-21 已实测证伪：G2（把改写变成读写原语）双向失败，不是改几行 PoC 的事

---

## 一个额外发现（值得单独说）

`com.oppo.engineermode` 以 `sharedUserId="android.uid.system"` 运行，其中
`EngineerModeActionReceiver` **没有加任何权限保护**，任何普通 App 都能给它发广播，
让它以 **system uid** 去执行：

- `*#8011#` → 打开 adb、把 USB 配置切成 `diag,adb`、写一批 `persist.*` 属性
- 其余 40 个暗码 → 以 system 身份拉起被 `OPPO_COMPONENT_SAFE` 保护的工程模式页面

**已在真机上验证**：Termux（uid 10087，`untrusted_app`，零特殊权限）发送广播后，
`persist.sys.usb.config` 从 `mtp` 变成 `diag,adb`，`persist.sys.allcommode` 从空变成 `true`。
这些属性只有 system uid 能写，说明代码确实在 system 进程里执行了。

这是一个**真实的本地权限提升（App → system uid）**，但它**不是 root**：
进程仍是 `system`（uid 1000），SELinux 域仍是 `system_app`，改不了 `/system`、开不了 `/dev/tun`。

细节和证据见 `docs/05-engineermode-audit.md`。
它当前唯一有实用价值的点是「用普通 App 打开 adb」——**而 adb 又依赖 USB**，所以仍然回到同一个阻塞点。

> ⚠️ 副作用：测试后本机 USB 配置已持久变为 `diag,adb`（MTP 不再自动出现）。
> 恢复：设置 → 开发者选项 → 选择 USB 配置 → MTP。
> 反过来，数据线修好后 adb 会自动可用，对后续调试有利。

---

## 证据可信度说明

| 级别 | 含义 | 本文档中的用法 |
| --- | --- | --- |
| **实测** | 在本机 SSH 里跑命令得到的输出，原始文本已存 `evidence/` | 设备画像、权限、manifest、smali |
| **公开资料** | 厂商公告、CVE 记录、可复现的技术博客 | 9008 流程、CVE 影响范围 |
| **推断** | 由前两者推导，未在本机验证 | 「9008 大概率可用」「CVE 移植工作量」 |

`docs/` 里每条关键结论都标了级别，避免把推断当事实。
