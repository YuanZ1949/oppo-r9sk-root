# 14 · 把手机当服务器：Debian chroot + sshd + 开机自启

> 采集：`evidence/2026-11-24-chroot-server.txt`、`evidence/2026-11-24-chroot-wifi-inet.txt`
> 脚本：`scripts/10-server.sh`（sshd 开机自启）、`scripts/20-nginx.sh`（可选 nginx 自启）、
> `scripts/chroot.sh`（手动进入）、`scripts/connect-wifi.sh`（root 写 Wi-Fi 配置）
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
| 登录用户 | `svc`，`uid=2000(svc)`，补充组 `1015(sdcard_rw)`、`1023(media_rw)`、**`3003(aid_inet)`**、`3004(aid_net_raw)` |
| 认证 | **仅公钥**（`PasswordAuthentication no`、`PermitRootLogin no`），`AllowUsers svc` |
| 开机自启 | `/data/adb/service.d/10-server.sh`（sshd）+ `20-nginx.sh`（可选，nginx），Magisk `late_start` 阶段 |
| 重启到 SSH 可用（局域网） | **26.6 s**（`boot_completed` 25.7 s；此前 adb 直连口径 16.5 s） |
| 局域网地址 | `192.168.2.205:2222`（Wi-Fi `yuan_5G`，5 GHz，RSSI -29，433 Mbps） |
| 示例服务 | nginx 1.22.1 以 `svc` 跑在 `:8080`，PC 访问 **200 / 27 ms** |
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

## 4. 十一个坑（按踩到的顺序）

### 坑 1 · `resolv.conf` 写不进去：`No such file or directory`

lxc 镜像里 `/etc/resolv.conf` 是指向 `/run/systemd/resolve/stub-resolv.conf` 的**悬空符号链接**，
`/run` 是空的 → 重定向跟随链接 → `ENOENT`（不是权限问题，很容易误判）。

```sh
rm -f /data/debian/etc/resolv.conf      # 先删链接，再写实体文件
printf 'nameserver 223.5.5.5\n' > /data/debian/etc/resolv.conf
```

### 坑 2 · `apt` 报 `Could not resolve`，但 `getent hosts`（root）正常

当时归因成“netd 按 UID 拦 DNS”，**后来证伪**：真正原因是 UID 缺少 `aid_inet` 组，
连 `socket(AF_INET)` 都会 `EACCES`（详见坑 11）。root 在组豁免范围内，所以看起来“网络是好的”。
把 `svc` / `_apt` 加进 `aid_inet(3003)` 后，`svc` 自己就能解析域名，apt 的 `Sandbox::User "root"` 也就不再是必需品。

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

### 坑 11 · `svc` 完全没网（`socket(AF_INET): Permission denied`）—— 最隐蔽的一个

现象很会骗人：

| 观察到的 | 容易得出的错结论 |
| --- | --- |
| `curl https://…` → `Could not resolve host` | “DNS 坏了” |
| `getent hosts`（root）正常返回 A/AAAA | “网络是好的，是解析配置错” |
| `ip route get 8.8.8.8` 能出 `via 192.168.2.1 dev wlan0` | “路由没问题” |
| iptables / nat 里找不到任何 `dport 53` 规则 | “不是防火墙” |
| 但 `curl http://146.75.114.132/` 也失败，`after 0 ms` | ← **0 ms 是关键线索** |

真正的报错藏在 busybox 的 errno 里：

```
wget: socket(AF_INET,1,0): Permission denied     # EACCES，发生在 socket()，不是 connect()
```

原因：这台机器的内核开了 **`CONFIG_ANDROID_PARANOID_NETWORK`** —— 只有 supplementary group
含 **`aid_inet(3003)`** 的 UID 才允许创建 IPv4/IPv6 socket（`AID_NET_RAW=3004` 对应 raw socket）。
`svc` 当时只有 1015/1023，于是**连 socket 都建不出来**；root 属于豁免，所以 root 一切正常。

修复（写进 chroot 的 `/etc/group`，sshd 用 `initgroups()` 从那取组）：

```sh
# /data/debian/etc/group
aid_inet:x:3003:svc,_apt
aid_net_raw:x:3004:svc
```

验证（重启 sshd 后必须重新登录）：

```sh
ssh -p 2222 svc@192.168.2.205 'id'   # 要出现 3003(aid_inet)
ssh -p 2222 svc@192.168.2.205 'getent hosts deb.debian.org; curl -sS -o /dev/null -w "%{http_code}\n" https://deb.debian.org/debian/README'
```

`scripts/10-server.sh` 里已加幂等的 `ensure_member`，每次开机自动补齐，避免重建 rootfs 后再踩。

> 这个坑顺带解释了另一件事：`androidboot.selinux`、`ip rule` 里的
> `22000: from all fwmark 0x0/0xffff lookup wlan0` 都正常，**未打 mark 的 socket 也能路由**——
> 模板化的“Android 需要 netd 打 fwmark 才能联网”在这个版本上并不是根因。


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

## 5.5 Wi-Fi 接入（无屏操作）

解锁时 `/data` 被清空，`wpa_supplicant.conf` 是空的 → 手机只有蜂窝（CGNAT `10.x`），PC 连不进去。

两个办法，**优先用手机屏幕**（不把密码写进会话记录）：

| 方式 | 做法 | 注意 |
| --- | --- | --- |
| 手机点一下（推荐） | 设置 → WLAN → 选 AP → 输密码 | 最干净，密码不落任何日志 |
| root 直接写配置 | `scripts/connect-wifi.sh "SSID" "PASSWORD"` | 脚本只接参数、不写死；密码会进 shell 历史/会话记录 |

`connect-wifi.sh` 的关键点：

```sh
cp -f /data/misc/wifi/wpa_supplicant.conf /data/local/tmp/wpa_supplicant.conf.bak   # 先备份
# 用 >> 追加 network 段：保持原文件属主/权限（wpa_supplicant 对此敏感）
svc wifi disable; sleep 2; svc wifi enable                                           # 让 supplicant 重读配置
# 轮询 wlan0 直到拿到 IPv4，最多 30 s
```

实测结果（2026-11-24）：`yuan_5G`（**5 GHz**，`5200 MHz`，`433 Mbps`，RSSI -29）连上后
`wlan0 = 192.168.2.205/24`，PC 端 `ssh -p 2222 svc@192.168.2.205` 直连成功（不再需要 `adb forward`）。

> 注意 `dumpsys wifi` 里两个不同的 SSID 状态：`Wi-Fi is enabled` 只表示**开关**开着，
> 真正的连接状态看 `mNetworkInfo … state: CONNECTED` / `Supplicant state: COMPLETED`。
> `mWifiInfo: [null]` + `SCANNING` 就是没连上。

---

## 5.6 跑一个真实服务（nginx 示例）

```sh
# 装（root，从 Android 侧进 chroot）
adb shell 'su -c "LD_PRELOAD= /system/bin/chroot /data/debian /usr/bin/env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/bin/apt-get install -y nginx-light"'

# 非 root 不能绑 80 → 改成 8080；pid/日志目录给 svc
sed -i 's/listen 80 default_server;/listen 8080 default_server;/' /etc/nginx/sites-available/default
sed -i 's#^pid /run/nginx.pid;#pid /run/nginx/nginx.pid;#' /etc/nginx/nginx.conf
mkdir -p /run/nginx && chown 2000:2000 /run/nginx /var/log/nginx

# 以 svc 起（sshd 会话里）
nginx && nginx -t && nginx -s reload
```

实测：`ps` 里 nginx master/worker 全是 `uid 2000`；PC `curl http://192.168.2.205:8080/` → **200，27 ms**；
开机脚本 `20-nginx.sh` 会在重启后自动拉起（不需要就删掉该文件）。

> `nginx -t` 报 `"user" directive makes sense only if the master process runs with super-user privileges`
> 是**预期警告**（非 root 启动时 `user` 指令被忽略），不是错误。

---

## 6. 运维命令速查

```sh
# 看开机日志
adb shell 'su -c "cat /data/local/tmp/server.log"'

# 手动跑一遍自启脚本（幂等，可随时执行）
adb shell 'su -c "sh /data/adb/service.d/10-server.sh"'

# 从 PC 直连（Wi-Fi 就绪时）
ssh -p 2222 svc@192.168.2.205

# 进 chroot（PC 上）
adb shell 'su -c "sh /data/local/tmp/chroot.sh"'

# 停 / 起 sshd
adb shell 'su -c "kill $(cat /data/debian/run/sshd.pid)"'
adb shell 'su -c "LD_PRELOAD= /system/bin/chroot /data/debian /usr/bin/env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/sbin/sshd -p 2222 -o PidFile=/run/sshd.pid"'

# nginx（以 svc 身份，在 ssh 会话里）
nginx -t && nginx -s reload        # 改完配置热加载
kill $(cat /run/nginx/nginx.pid)   # 停

# 需要 root 的操作（apt / 改系统文件）：从 Android 侧进 chroot，不要 sudo（nosuid）
adb shell 'su -c "LD_PRELOAD= /system/bin/chroot /data/debian /usr/bin/env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root /bin/bash -l"'

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
无线 adb 兜底 → `/sdcard` 读写 → **Wi-Fi 接入（5 GHz，192.168.2.205）** → **`aid_inet` 网络组修复** →
**nginx 以 uid 2000 跑在 8080** → 重启验证（重启后 SSH **26.6 s** 可用、DNS/HTTP 正常、nginx 自动拉起）。

**待办 / 可选**：

1. 按需装服务：`caddy` / `gitea` / `mosquitto` / `syncthing` 都是 `apt install` 一句话；
   Home Assistant 能跑但吃紧（300–500 MB），Jellyfin 转码 / ES 不行。
2. 远程接入：`/dev/tun` 可开 → Tailscale 官方 arm64 静态包可直接放进 chroot 跑（不要在路由器上把 2222 映射出去）。
3. 内存上限（可选）：`/sys/fs/cgroup/memory/<group>/memory.limit_in_bytes` 实测可写，可给单服务兜底。
4. 想绑 80/443：要么 `iptables -t nat` 从 80 转发到 8080，要么把 `net.ipv4.ip_unprivileged_port_start` 调低，不要为此给 `svc` sudo。
