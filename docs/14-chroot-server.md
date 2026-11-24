# 14 · 把手机当服务器：Debian chroot + sshd + 开机自启

> 采集：`evidence/2026-11-24-chroot-server.txt`
> 脚本：`scripts/10-server.sh`（开机自启）、`scripts/chroot.sh`（手动进入）
> 时间：2026-11-24 · 全部结论为实机实测

---

## 1. 为什么选 chroot，而不是 Termux / 容器

| 方案 | 结论 | 依据 |
| --- | --- | --- |
| Termux | ❌ 不作为主力 | 官方对 Android 5/6 的源冻结在 **2019-12**（`termux-main-21`），Python 3.8 / Node 12，装不了现代服务（见 `docs/06`） |
| Docker / K8s / LXC | ❌ 直接排除 | `/proc/self/ns` 只有 `mnt`、`net`；**无 pid/uts/ipc/user namespace**，容器运行时起不来 |
| proot | ⚠️ 能跑但慢 | 纯 ptrace 翻译，性能损失 30–50%，且不支持真正的 setuid 降权 |
| **chroot（root 下）** | ✅ **采用** | `mount -o bind` / `mount -t proc` 在 magisk 域实测 OK；glibc 二进制原生执行 |

三层结构：

```
① 无 App 依赖          PC ── adb/su ──> 设备 root
② Debian 12 chroot     /data/debian       ← 服务真正跑在这里（apt 现行版本）
③ service.d 自启       /data/adb/service.d/10-server.sh  ← root 域，不依赖任何 App
```

Termux 变成「可选」：想要屏幕终端或 `termux-api` 再装，不影响主线。

---

## 2. 落地结果

| 项 | 实测值 |
| --- | --- |
| 根文件系统 | **Debian GNU/Linux 12 (bookworm)**，`aarch64`，`/etc/debian_version` = `12.15` |
| 体积 | 解压后 **466 MB**（`/data` 共 53 GB 空闲） |
| sshd | **OpenSSH 9.2p1-2+deb12u10**，监听 `0.0.0.0:2222` |
| 登录用户 | `svc`，`uid=2000(svc)`，补充组 `1015(sdcard_rw)`、`1023(media_rw)` |
| 认证 | **仅公钥**（`PasswordAuthentication no`、`PermitRootLogin no`），`AllowUsers svc` |
| 开机自启 | `/data/adb/service.d/10-server.sh`，Magisk `late_start` 阶段 |
| 重启到 sshd 可用 | **16.5 s**（`adb` 上线 16.4 s，`boot_completed` 约 28 s —— sshd 比系统起完还早） |
| 无线 adb 兜底 | `persist.adb.tcp.port=5555`，adbd 监听 `0.0.0.0:5555` |
| 共享存储 | `/data/media/0` bind 到 chroot 的 `/sdcard`，`svc` 可读写（实测 `SDCARD_WRITE_OK`） |
| 内存占用 | 整机 `used 1209 MB`，`available 2386 MB`（chroot 本身几乎不额外占内存） |
| CPU 可见核数 | chroot 内 `nproc` = **4**（Android 侧把 8 核中 4 核 offline 了） |

---

## 3. rootfs 从哪来、怎么装

镜像源：清华 LXC images 的 Debian bookworm arm64（`rootfs.tar.xz`）

```
https://mirrors.tuna.tsinghua.edu.cn/lxc-images/images/debian/bookworm/arm64/default/20261118_05%3A24/rootfs.tar.xz
size   = 95,005,828 B (90.6 MiB)
sha256 = 63009F7550F4A2A978B37E5160A37C524847FD46041ECF251D1F56F835DF344E
```

> 选 lxc-images 的原因：官方 docker 导出层是 `/` 打平的，lxc 的 `rootfs.tar.xz` 带完整 `/dev` `/proc` `/sys` 骨架；
> 且清华源在国内直连（实测 2.6 s 下完 90 MB）。

设备端解压 —— **系统 toybox 没有 `xz`/`gzip`**，必须用 Magisk 自带 busybox：

```sh
adb push debian-bookworm-arm64.tar.xz /data/local/tmp/
adb shell 'su -c "mkdir -p /data/debian && cd /data/debian && \
  /data/adb/magisk/busybox xz -dc /data/local/tmp/debian-bookworm-arm64.tar.xz | \
  /data/adb/magisk/busybox tar -xf - -p && echo EXTRACT_OK"'
```

进 chroot 必须清环境（见坑 7）：

```sh
/system/bin/chroot /data/debian /usr/bin/env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/root TERM=xterm /bin/bash -l
```

---

## 4. 十个坑（按踩到的顺序）

### 坑 1 · `resolv.conf` 写不进去：`No such file or directory`

lxc 镜像里 `/etc/resolv.conf` 是指向 `/run/systemd/resolve/stub-resolv.conf` 的**悬空符号链接**，
`/run` 是空的 → 重定向跟随链接 → `ENOENT`（不是权限问题，很容易误判）。

```sh
rm -f /data/debian/etc/resolv.conf      # 先删链接，再写实体文件
printf 'nameserver 223.5.5.5\n' > /data/debian/etc/resolv.conf
```

### 坑 2 · `apt` 报 `Could not resolve`，但 `getent hosts` 正常

**Android netd 按 UID 管控 DNS**：apt 默认把下载方法降权到 `_apt`（uid 100），该 UID 不在 `inet` 组，
DNS 查询被 netd 拦掉。`getent`/`ping` 用的是 root，所以看起来“网络是好的”。

```sh
# /etc/apt/apt.conf.d/99-r9sk
APT::Sandbox::User "root";
```

### 坑 3 · 只解析出 IPv6，`deb.debian.org` 连不上

蜂窝网络下 DNS 常先返回 AAAA，而 `rmnet_data0` 只有 IPv4（CGNAT `10.x`），IPv6 走另一条链路。
双保险：换国内镜像（清华）+ 强制 IPv4。

```sh
# /etc/apt/sources.list → http://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm main ...
# /etc/apt/apt.conf.d/99-r9sk
Acquire::ForceIPv4 "true";
Acquire::Retries "3";
```

换源后 `apt-get update` 实测 **1555 kB/s**。

### 坑 4 · sshd 起不来：`Subsystem 'sftp' already defined`

Debian 自带 `sshd_config` 末尾已有 `Subsystem sftp /usr/lib/openssh/sftp-server`，
`sshd_config.d/*.conf` 里再写一条 → sshd 直接 fatal 退出（重复 `Subsystem` 是硬错误，不是覆盖）。

**只写业务配置，不重复 Debian 已有的项。**

### 坑 5 · `Permission denied (publickey)`，但 `authorized_keys` 内容对

`/home/svc/.ssh` 目录是 root 建的（700 root:root），`svc` 读不到自己的 `authorized_keys`。
`StrictModes yes` 下 sshd 直接拒绝。

```sh
chown -R 2000:2000 /data/debian/home/svc
chmod 700 /home/svc/.ssh && chmod 600 /home/svc/.ssh/authorized_keys
```

### 坑 6 · service.d 里 `chroot: not found` / `date: not found`

开机脚本里为了给 chroot 准备环境把 `PATH` 改成了 Debian 的路径，结果 **Android 侧的 `chroot`（toybox）
和 `date` 都不在 PATH 里**了。

```sh
# 正确写法：Android 侧命令用绝对路径，Debian 侧环境用 chroot 里的 env 重置
/system/bin/chroot "$R" /usr/bin/env -i PATH=... /usr/sbin/sshd -p 2222
$BB date '+%F %T'      # $BB = /data/adb/magisk/busybox
```

### 坑 7 · `LD_PRELOAD: libNimsWrap.so cannot be preloaded`

Android 环境里 `LD_PRELOAD` 指向 OPPO 的 `libNimsWrap.so`，chroot 内没有这个库，每个 glibc 程序都会打一行噪音
（功能不受影响，但会污染日志、也会拖慢启动）。

```sh
LD_PRELOAD= /system/bin/chroot ...   # 或 chroot 内用 env -i 重置
```

### 坑 8 · 手动执行 service.d 脚本时，脚本“跑一半就没了”

脚本里原本有 `stop adbd; start adbd`（为了开无线调试）。如果这条脚本是**通过 `adb shell` 手动触发**的，
重启 adbd 会把自己那条 adb 连接一起掐掉 → 脚本中途被杀，后面全不执行。

```sh
# 不要重启 adbd，只写持久属性，下次开机 adbd 自己会读
setprop persist.adb.tcp.port 5555
```

### 坑 9 · chroot 内 `sudo` 不可用

`/data` 挂载参数是 `rw,seclabel,nosuid,nodev,...` —— **nosuid** 让 chroot 内所有 setuid 程序失效，
`sudo` / `su` / `passwd` 都用不了。

这不是缺陷：需要 root 的操作**从 Android 侧 `su -c` 进 chroot**，chroot 内只跑降权后的服务。

### 坑 10 · `/sdcard` 能挂上但 `Permission denied`

`/data/media/0` 属主 `media_rw:media_rw`（uid/gid **1023**），mode `770`；`svc` 是 2000，不在组里。

```sh
# /etc/group
sdcard_rw:x:1015:svc
media_rw:x:1023:svc
```

加完组后 `svc` 对 `/sdcard` 读写正常。

> 顺带一个反面教材：改 `/etc/passwd` 时把补充组写进了 gecos 字段（`svc:x:2000:2000,1015,1023::`），
> 导致 `getpwnam` 解析失败、SSH 直接 `Permission denied (publickey)`。补充组只能写在 `/etc/group`。

---

## 5. 开机自启脚本

部署位置 `/data/adb/service.d/10-server.sh`（源文件 `scripts/10-server.sh`）：

```sh
R=/data/debian
BB=/data/adb/magisk/busybox
LOG=/data/local/tmp/server.log

# 1) 无线 adb 兜底：只写持久属性，不重启 adbd（见坑 8）
# 2) bind /dev /proc /sys /dev/pts —— 缺 /dev/pts 则 ssh -t 拿不到 pty
# 3) bind /data/media/0 → $R/sdcard
# 4) 用当前 net.dns1 重写 chroot 的 resolv.conf（换网后 DNS 会变）
# 5) 幂等启动：先 netstat 查 2222，没监听才起 sshd
```

日志实测（重启后）：

```
[2026-11-24 09:12:36] === boot: start ===
[2026-11-24 09:12:36] wireless adb: persist.adb.tcp.port=5555
[2026-11-24 09:12:37] sshd start rc=0
[2026-11-24 09:12:37] === boot: done ===
```

重启计时（`adb reboot` 起算）：`adb` 上线 **16.4 s**，2222 监听 **16.5 s**。

---

## 6. 运维命令速查

```sh
# 看开机日志
adb shell 'su -c "cat /data/local/tmp/server.log"'

# 手动跑一遍自启脚本（幂等，可随时执行）
adb shell 'su -c "sh /data/adb/service.d/10-server.sh"'

# 进 chroot（PC 上）
adb shell 'su -c "sh /data/local/tmp/chroot.sh"'

# 停 / 起 sshd
adb shell 'su -c "kill $(cat /data/debian/run/sshd.pid)"'
adb shell 'su -c "LD_PRELOAD= /system/bin/chroot /data/debian /usr/bin/env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/sbin/sshd -p 2222 -o PidFile=/run/sshd.pid"'

# 没 WiFi 时临时从 PC 连（本地 2222 被占用就换个端口）
adb forward tcp:22222 tcp:2222
ssh -p 22222 svc@127.0.0.1
```

---

## 7. 安全边界（必须知道）

| 事实 | 含义 |
| --- | --- |
| chroot **不是**安全边界 | root 想逃逸随时能逃（`chroot` 只隔离依赖，不是沙箱） |
| sshd 以 root 启动 | sshd 必须 root 才能切换用户；**会话本身是 `svc`（uid 2000）** |
| 服务都跑 `svc` | 单个服务被 RCE，拿不到 root；要 root 只能从 Android 侧 `su` |
| 不要暴露 22/2222 到公网 | Android 6 的 sshd + 公网 = 一天被扫穿。用 Tailscale（`/dev/tun` 实测 `TUN_OPEN_OK`）或 Cloudflare Tunnel |
| 不要用 uid 1000 | Android 里 `1000=system`；chroot 与 Android 共用同一 uid 命名空间，选 **2000**（`shell`）最安全 |
| 电池 | 长期 100% 插电会鼓包；建议智能插座定时上电，维持 40–70% |

---

## 8. 当前状态与下一步

**已完成**：rootfs → chroot → apt（清华源）→ openssh → `svc` 用户 → 公钥登录 → service.d 开机自启 →
无线 adb 兜底 → 重启验证（16.5 s 可用）→ `/sdcard` 读写。

**待办**：

1. **WiFi 未连接** —— 解锁时 `/data` 被清空，`wpa_supplicant.conf` 里没有任何保存的网络，
   手机现在只有蜂窝（CGNAT `10.x`，PC 连不进去）。需要手动连一次家里 AP，
   或用 `adb forward` 临时替代（已验证可用）。
2. 按需装服务：`nginx` / `caddy` / `gitea` / `mosquitto` / `syncthing` 都只是 `apt install` 一句话；
   Home Assistant 能跑但吃紧（300–500 MB），Jellyfin 转码 / ES 不行。
3. 远程接入：`/dev/tun` 可开 → Tailscale 官方 arm64 静态包可直接放进 chroot 跑。
4. 内存上限（可选）：`/sys/fs/cgroup/memory/<group>/memory.limit_in_bytes` 实测可写，可给单服务兜底。
