# 06 · Termux 现状：能做什么，卡在哪

> 采集：`evidence/2026-11-21-termux-inventory.txt`、`evidence/2026-11-21-termux-privileges.txt`
> 连接方式：`ssh r9sk`（`~/.ssh/config` 里的 `Host r9sk termux`）

---

## 1. 环境

| 项 | 值 |
| --- | --- |
| PREFIX | `/data/data/com.termux/files/usr` |
| 架构 | `armv8l`（**32 位 arm 构建**，跑在 arm64 内核上） |
| Python | 3.8.0 |
| Node | 12.13.0 |
| git | 2.23.0 |
| clang | 9.0.0 |
| 已装包 | 100 个 |
| SSH | `sshd` 监听 8022，公钥认证 |
| 存储 | `~/storage/downloads -> /storage/emulated/0/Download`，可读写 |
| uid | 10087（`u0_a87`） |
| SELinux | `untrusted_app` |

> 软件源是 **2019-12 的冻结快照**（`termux-main-21`），所以版本都停在那个年代。
> 这不是配置问题，是 Termux 官方对 Android 5/6 的最后一个兼容源。

---

## 2. 已装工具

```
git python node clang make cmake vim tmux jq ripgrep fd htop
rsync ncdu tree curl wget openssl sqlite less file procps
bash coreutils findutils grep sed gawk tar gzip bzip2 xz
openssh termux-api
```

够用的场景：

- 写/跑 Python 脚本（3.8，标准库完整）
- 编译 C/C++（clang 9，armv7 目标）
- git 版本管理
- SSH / rsync 同步
- tmux 长会话（配合 wake-lock）
- 访问手机共享存储

---

## 3. 被平台卡住的东西

| 目标 | 状态 | 原因 |
| --- | --- | --- |
| **ZeroTier** | ❌ | ① 官方无 Termux 包；② 手机上现成的 APK 是 v1.14.0-2，**minSdk=26**，Android 6 装不上；③ 即使装上也需要 `/dev/tun` |
| **OpenVPN** | ❌（无 root） | `/dev/tun` 是 `crw-rw---- system vpn`，uid 10087 不在 `vpn` 组 |
| WireGuard / tun2socks | ❌ | 同上，都需要 TUN |
| **opencode2** | ❌ | 需要 Node 18+ / 现代 glibc 兼容层；本机 Node 12 + Android 6 |
| **Termux:API App** | ❌ | minSdk 24，Android 6（API 23）装不上 |
| **Shizuku** | ❌ | 需要 adb 或 root 启动 |
| 新版 Termux 包 | ❌ | 官方已停止 Android 5/6 支持 |

### 关于 `/dev/tun`

```
crw-rw---- 1 system vpn 10, 200 /dev/tun
```

- 属主 `system`，属组 `vpn`（组 ID 通常 3004）
- Termux 的组：`3003(inet), 9997(everybody), 50087(all_a87)`
- **不在 `vpn` 组** → `open()` 直接 `EACCES`
- 就算加进 `vpn` 组（需要 root 改 `/system/etc/permissions`），SELinux 仍会拦 `untrusted_app` 的 `tun_device` 访问

**结论：没有 root，任何 TUN 方案都不可行。** 这不是换个 App 能解决的。

---

## 4. 一个真实的坑：Termux 会被杀

工程模式测试时，Activity 把 Termux 切到后台，几分钟后 Termux 进程被 LMK 回收，
**sshd 随之消失**，SSH 直接 `Connection refused`（ping 仍然通）。

- `.bashrc` 里的 `termux-wake-lock` 只在**有会话时**有效
- Termux 没有 `Termux:Boot`（需要额外装 App，且 minSdk 可能不兼容），**重启后不会自动起 sshd**
- 恢复方法：**在手机上打开一次 Termux**，`.bashrc` 会自动拉起 sshd

> 这是本项目「远程控制」最大的不稳定因素：手机端需要人工保活。

---

## 5. 32 位 vs 64 位

当前是 **arm（32 位）** 构建。设备是 arm64，理论上可以换 `arm64-v8a` 包：

| | arm（当前） | arm64 |
| --- | --- | --- |
| 包源 | `termux-main-21`（994 包） | 同样的 21 源，但 aarch64 分支 |
| 性能 | 一般 | 更好（64 位寄存器、更多地址空间） |
| 兼容性 | 已验证可用 | 需要重装 |
| 代价 | — | **重装会清空 `~/`** |

**建议**：暂时不换。当前环境已经配好（SSH、密钥、工具链、存储权限），
换架构的收益（性能）远小于重配成本。等 root 之后如果真要跑重负载，再考虑迁移。

如果坚持要换：

```bash
# 1. 备份
ssh r9sk 'cd ~ && tar czf /sdcard/Download/termux-home-backup.tar.gz .'

# 2. 卸载 Termux，安装 arm64 版 APK
#    termux-app_v0.119.0-beta.3+apt-android-5-github-debug_arm64-v8a.apk

# 3. 恢复
ssh r9sk 'cd ~ && tar xzf /sdcard/Download/termux-home-backup.tar.gz'
```

---

## 6. SSH 配置

`C:\Users\yuan\.ssh\config`：

```
Host r9sk termux
    HostName 192.168.2.205
    Port 8022
    User u0_a87
    IdentityFile ~/.ssh/termux_phone_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile ~/.ssh/known_hosts_termux
    ServerAliveInterval 30

Host k50
    HostName 192.168.193.2
    Port 8022
    User u0_a105
    ...
```

> ⚠️ **注意**：`termux` 和 `r9sk` 现在指向同一台 R9sk；`k50` 是另一台机器（K50 Ultra / Android 15）。
> 曾经出现过配置被改到 K50 的情况，导致命令打到错误的设备上。
> **执行任何写操作前，先 `getprop ro.product.model` 确认机型。**

密钥：`C:\Users\yuan\.ssh\termux_phone_ed25519`（无口令）。
手机端：`~/.ssh/authorized_keys`。

---

## 7. `.bashrc` 托管块

```bash
# --- opencode-managed ---
termux-wake-lock 2>/dev/null
pgrep -f sshd >/dev/null || sshd 2>/dev/null
alias ll='ls -alF'
# --- end opencode-managed ---
```

作用：登录即加 wake-lock、确保 sshd 在跑。

---

## 8. 能做什么（无 root 前提下）

| 场景 | 可行性 |
| --- | --- |
| SSH 跳板 / 端口转发 | ✅ |
| 跑 Python 脚本、定时任务 | ✅ |
| git 仓库同步 | ✅ |
| 编译 C 程序（armv7） | ✅ |
| 局域网文件服务（python -m http.server） | ✅ |
| 通过 ZeroTier 组网 | ❌ 需要 TUN |
| 反向代理到公网 | ✅（走现有网络，不需要 TUN） |
| 抓包 | ❌ 需要 root 或 VPNService |
| 改系统文件 | ❌ 需要 root |

**一句话**：它现在是一台「能 SSH、能跑脚本的 Android 6 终端」，
不是「能组网的 Linux 节点」。组网要等 root。
