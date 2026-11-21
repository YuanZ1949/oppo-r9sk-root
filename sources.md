# 资料来源与可信度

> 本项目的每条结论都尽量标注来源。分级：
> **A = 一手/官方**，**B = 可复现的技术记录**，**C = 社区教程（需自行核对）**，**D = 仅作线索**。

---

## 一、设备与平台

| 来源 | 用途 | 级别 |
| --- | --- | --- |
| 本机 `getprop` / `mount` / `pm` 输出（`evidence/2026-11-21-*.txt`） | 全部设备画像 | **A（实测）** |
| Android 6.0.1 安全公告索引 `https://source.android.com/docs/security/bulletin` | 补丁级别与 CVE 对应关系 | A |
| Android 版本分布 / EOL 说明 | 说明 Android 6 已停止支持 | A |

---

## 二、CVE

| 来源 | 用途 | 级别 |
| --- | --- | --- |
| Project Zero《Bad Binder: Android In-The-Wild Exploit》<br>`https://projectzero.google/2019/11/bad-binder-android-in-wild-exploit.html` | CVE-2019-2215 的原理、在野利用 | A |
| Project Zero 0day RCA<br>`https://googleprojectzero.github.io/0days-in-the-wild/0day-RCAs/2019/CVE-2019-2215.html` | `binder_thread` 结构、PoC 片段 | A |
| NVD `https://nvd.nist.gov/vuln/detail/CVE-2019-2215` | CVSS、影响版本 | A |
| Exploit-DB 47463 `https://www.exploit-db.com/exploits/47463` | 公开 PoC（Pixel 2 向） | B |
| Red Hat《Understanding and mitigating Dirty COW》 | CVE-2016-5195 原理与修复 | A |
| QuadRooter 披露（Check Point, 2016） | CVE-2016-2503/2504/2059/2060 | A |
| 《CVE-2019-2215 漏洞复现》`https://blingblingxuanxuan.github.io/2023/11/06/231106-cve-2019-2215/` | 中文复现记录 | B |
| 《CVE-2019-2215 分析利用记录》`https://ykiko.top/p/cve-2019-2215...` | 利用细节 | B |
| 看雪《CVE-2020-0423 分析》`https://bbs.kanxue.com/thread-264616.htm` | binder race 类漏洞 | B |

---

## 三、9008 / 刷机

| 来源 | 用途 | 级别 |
| --- | --- | --- |
| 博客园《【刷机】OPPO R9st 获取 Root 权限》<br>`https://www.cnblogs.com/minuhy/p/21348253` | **同平台（R9st / MSM8953 / 3.18.24 / Android 6）完整实操**，只刷 aboot + recovery | **B（有步骤和结果）** |
| ROM 乐园《OPPO A57 R9s R9SK 无需解锁线刷 TWRP》<br>`http://www.romleyuan.com/lec/read?id=142` | 明确点名 **R9sk** | C |
| 7to《OPPO R9s MIFlash 线刷 TWRP》<br>`http://www.7to.cn/jiaochengDetail.aspx?id=4605` | 另一套工具链 | C |
| ZOL《OPPO R9sk 线刷包》`https://m.zol.com.cn/sjbbs/d1673_46586.html` | 线刷包线索 | D（下载站，需核对） |
| B 站《OPPO R9S 线刷救砖/TWRP》`https://www.bilibili.com/video/BV13t411S7aE/` | 视频参考 | C |

> ⚠️ 9008 相关的中文教程普遍存在**工具捆绑、包版本错配**问题。
> 本文档只把它们当「流程参考」，不推荐任何具体下载链接。

---

## 四、BL 解锁政策

| 来源 | 用途 | 级别 |
| --- | --- | --- |
| 一加社区《深度测试公告 & QA》(2026-06)<br>`https://bbs.oneplus.com/thread/1926504022886318086` | 官方支持机型列表（全部为新机） | A |
| GitHub `AdaUnlocked/2026-All-Brands-Bootloader-Unlock-Status`<br>`https://github.com/AdaUnlocked/2026-All-Brands-Bootloader-Unlock-Status` | 各厂 BL 现状汇总（含「R11 之前无官方解锁」） | C |
| GitHub `lokey0905/rootWithoutUnlockBootloaderList`<br>`https://github.com/lokey0905/rootWithoutUnlockBootloaderList` | 免解锁 root 漏洞汇总 | C |
| ROM 乐园机型支持列表（2024-03） | OPPO R11 之前无官方解锁 | C |

---

## 五、Termux

| 来源 | 用途 | 级别 |
| --- | --- | --- |
| Termux 主源 `https://termux.dev/termux-main-21` | Android 5/6 兼容包（994 个） | A |
| Termux root 源 `https://termux.dev/termux-root-packages-21-bin` | root 包（39 个，含 `openvpn 2.4.8-1`） | A |
| 本机 `pkg list-installed`（`evidence/2026-11-21-termux-inventory.txt`） | 实际安装清单 | A（实测） |
| Termux Wiki（镜像/源说明） | 源结构 | B |

---

## 六、APK minSdk 核验

| 文件 | minSdk | 结论 |
| --- | --- | --- |
| `termux-app ... armv7` | 21 | ✅ 可装（当前使用） |
| `termux-app ... arm64` | 21 | ✅ 可装（需重装） |
| `shizuku-11.0.0.apk` | 23 | ✅ 可装，但**无法启动**（需 adb/root） |
| `shizuku-13.6.apk` | 24 | ❌ Android 6 装不上 |
| `zerotier-one.apk` v1.14.0-2 | 26 | ❌ Android 6 装不上 |

核验方法：解包 APK → `tools/axml_dump.py` 读 `AndroidManifest.xml` 的 `uses-sdk`。

---

## 七、本项目的原始产物

| 文件 | 说明 |
| --- | --- |
| `evidence/2026-11-21-device-props.txt` | 完整 `getprop` + 系统包 + setuid 清单 |
| `evidence/2026-11-21-engineermode-surface.txt` | 工程模式相关属性/二进制/路径 |
| `evidence/2026-11-21-engineermode-dump.txt` | `dumpsys package` 摘要 + APK 拷贝测试 |
| `evidence/2026-11-21-oem-manifest.txt` | 1092 行解码后的 AndroidManifest |
| `evidence/2026-11-21-engineermode-actions.txt` | 40 条暗码映射 |
| `evidence/2026-11-21-engineermode-live-test.txt` | 未授权广播的实机验证记录 |
| `evidence/2026-11-21-termux-inventory.txt` | Termux 包清单与版本 |
| `evidence/2026-11-21-termux-privileges.txt` | uid / 组 / SELinux / `/dev/tun` |
| `tools/axml_dump.py` | AXML 解码器（本项目自写） |
| `work/oem_smali/` | 工程模式反编译结果（1947 个 smali，不入库） |

---

## 八、没有采用的来源

| 来源类型 | 原因 |
| --- | --- |
| 「一键 root」工具官网 | 服务已停，客户端不可信 |
| 网盘分享的 MsmDownloadTool 破解版 | 无法验证哈希，存在木马风险 |
| 各类「免解锁 root 教程」 | 大多基于已修复的 2016 年漏洞 |
| 声称 R9s 支持深度测试的内容 | 与官方公告矛盾，判定为引流 |
