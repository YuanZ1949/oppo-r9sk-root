# 15 · ZeroTier 远程接入 + OpenCode 2（arm64）装进 chroot（含 web 服务自启）

> 采集：`evidence/2026-11-24-zerotier-opencode.txt`、`evidence/2026-11-24-opencode-web-zt.txt`
> 脚本：`scripts/30-zerotier.sh`（ZeroTier + 策略路由）、`scripts/40-opencode-web.sh`（web 服务）
> 时间：2026-11-24 · 实机实测（Debian 12.15 arm64 chroot / 内核 3.18.24）

---

## 1. 结论速览

| 项 | 结果 |
| --- | --- |
| ZeroTier | `zerotier-one 1.16.2` arm64，已 `join 8bd5124fd6ff23d9`，节点地址 **`23697636b0`** |
| 网络状态 | **OK**，托管 IP **`192.168.193.5/24`**；与 PC(`192.168.2.161`) 走 **DIRECT 局域网路径**（14 ms） |
| 开机自启 | `30-zerotier.sh`（含策略路由）/ `40-opencode-web.sh`，重启后 9993 + 4300 均在听 |
| OpenCode | **v2.2.5** arm64 单文件二进制（248 MB）装到 `/usr/local/bin/opencode`，**不需要 Node** |
| 插件 | 与本机一致：本地 `plugins/yzopencode` + npm `@herjarsa/oh-my-openagent-v2@0.4.2`（两者都已实际生效） |
| web 服务 | `opencode serve --hostname 0.0.0.0 --port 4300 --service`，以 uid 2000 常驻；**PC 与 ZT 两侧均 200** |
| web 口令 | 与 PC 同一份 `service.json`（Basic 认证，用户名 `opencode`）；**文件不入库** |
| 端到端 | `opencode run --model opencode/deepseek-v4.1-flash-free "…"` → **`CHROOT_OK`，23 s** |

重启计时（`adb reboot` 起算，最后一次）：SSH **26.1 s**、web 4300 **26.1 s**、
ZT 策略规则 21000 **26.1 s**、PC 经 ZT 访问 web **26.1 s**。

---

## 2. ZeroTier

### 2.1 装（root，chroot 内）

```sh
adb shell 'su -c "LD_PRELOAD= /system/bin/chroot /data/debian /usr/bin/env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
  /bin/sh -c \"apt-get install -y -qq curl ca-certificates; curl -sS https://install.zerotier.com | bash\""'
```

- 官方脚本加 ZeroTier 源 → 装上 `zerotier-one 1.16.2`（arm64）。
- chroot 里**没有 systemd**，所以脚本末尾会报 `cannot start service`，属正常；用下面的方式手动/开机启动。

### 2.2 `/dev/net/tun`：这一步不做就起不来

内核/Android 侧只有 **`/dev/tun`（char `10:200`，属主 `system:vpn`）**，而 ZeroTier 找的是 `/dev/net/tun`：

```sh
mkdir -p /dev/net && ln -s /dev/tun /dev/net/tun
```

> `/dev` 是 **tmpfs**，**重启就丢**，所以 `30-zerotier.sh` 每次开机都会重建这条软链。
> chroot 里的 `/dev` 是 bind 自 Android 的 `/dev`，所以这个软链在 chroot 内也可见。

### 2.3 启动 / 加入网络

```sh
adb shell 'su -c "LD_PRELOAD= /system/bin/chroot /data/debian /usr/bin/env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/sbin/zerotier-one -d"'
adb shell 'su -c "LD_PRELOAD= /system/bin/chroot /data/debian /usr/bin/env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/sh -c \"zerotier-cli info; zerotier-cli join 8bd5124fd6ff23d9\""'
```

- `zerotier-one -d` 会 daemonize，但**仍然继承调用者的 stdout**。用 `adb shell` 手动执行时若不定向输出，adb 会一直挂住（第一次就踩了，命令超时 180 s）。脚本里已 `>> "$LOG" 2>&1`。
- 网络成员信息存放在 `/data/debian/var/lib/zerotier-one/networks.d`，**join 一次就持久**。

### 2.4 授权（已完成）

1. https://my.zerotier.com → 网络 `8bd5124fd6ff23d9` → Members；
2. 勾选 **`23697636b0`** 的 Auth（已由用户完成）。

授权前 `ACCESS_DENIED`，授权后：

```
200 info 23697636b0 1.16.2 ONLINE
200 listnetworks 8bd5124fd6ff23d9 My da:00:96:a0:79:a2 OK PRIVATE ztyqb623ap 192.168.193.5/24
```

### 2.5 ★ 策略路由：不做这一步，ZT「online 但谁也通不了」

这是本项目最隐蔽的一个坑，现象非常有迷惑性：

- `zerotier-cli info` → `ONLINE`，`listnetworks` → `OK`，`zt*` 接口 UP，IP 也对；
- 但手机 ping 不通任何 zt 地址，PC 也访问不了手机 zt IP；
- `tcpdump -i wlan0 'udp port 9993'` 只看到手机在跟 **planet 服务器**（如 `185.152.67.145`、`103.195.103.66`）打洞，
  **从不**与同局域网的 PC（`192.168.2.161`）直接通信。

真因不是 ZT，而是 **Android 的策略路由**：netd 给进程只留了 per-network 表
（`ip rule … oif wlan0 lookup wlan0` 等），而 wlan0 表里只有默认路由；
`192.168.193.0/24 dev ztyqb623ap` 这条路由只在 **main 表**里。
于是发往 zt 子网的包被 wlan0 默认路由带走，到 LAN 上被丢弃。

```sh
ip rule add to 192.168.193.0/24 lookup main priority 21000
```

加完立刻生效：`zerotier-cli peers` 里出现 `8c9fe6aa1c … 192.168.2.161/47197  DIRECT  14ms`，
PC 访问 `http://192.168.193.5:4300/` → **200 / 89 ms**。

两个配套细节（脚本里都已处理）：

| 细节 | 原因 |
| --- | --- |
| 必须用 `$BB awk` 解析路由 | Android 7.1 的 toybox **没有 awk**（`/system/bin/awk` 不存在），裸 `awk` 恒为空 → 规则永远加不上，日志只有 `zt route not found` |
| 开机等网络不能看 main 表的 default 路由 | main 表里**没有** default（在 netd per-network 表），要等 `ip -4 addr show wlan0` 出现 `inet` |
| 补规则放后台 + 子网缓存 | ZT 接口出现时间不可控（网络就绪前启动要 2 min+）；`/data/local/tmp/zt-subnet.txt` 让下次开机**先加规则**，接口一出现即通 |

### 2.6 两个已知告警（可忽略）

| 告警 | 原因 |
| --- | --- |
| `failed to drop privileges (kernel may not support required prctl features), running as root` | 3.18 老内核缺 ZeroTier 用来降权的 `prctl` 特性，守护进程只能以 root 跑。它只应监听 9993/UDP + 建 TUN，风险面小；但要清楚这是「网络守护进程在 root」 |
| `zerotier-cli: authtoken.secret not found or readable … (try again as root)` | `authtoken.secret` 是 600 root，普通用户 `yahoo`/`yuan` 不能读。查状态请从 Android 侧 `su` 进 chroot 执行 |

---

## 3. OpenCode 2（arm64）

### 3.1 为什么用二进制而不是 npm 装

`@opencode/cli@2.2.5` 的 arm64 平台包是**编译好的单文件二进制**（Bun 打包，248 MB），
直接拿 `@opencode/cli-linux-arm64` 的 tarball 解出来即可，**不需要在手机装 Node 24**：

```sh
# PC 上下载（npmmirror 国内快）
# https://registry.npmmirror.com/@opencode/cli-linux-arm64/-/cli-linux-arm64-2.2.5.tgz
adb push oc.tgz /data/local/tmp/oc.tgz
adb shell 'su -c "cp /data/local/tmp/oc.tgz /data/debian/tmp/ && \
  LD_PRELOAD= /system/bin/chroot /data/debian /usr/bin/env -i PATH=/usr/bin:/bin \
  /bin/sh -c \"mkdir -p /tmp/ocpkg && tar -xzf /tmp/oc.tgz -C /tmp/ocpkg && \
  install -m 755 /tmp/ocpkg/package/bin/opencode /usr/local/bin/opencode && \
  rm -rf /tmp/ocpkg /tmp/oc.tgz\""'
```

验证：`opencode --version` → `2.2.5`。二进制依赖 glibc ≥ 2.28（bookworm 是 2.36），内核 3.18 不影响。

### 3.2 配置移植（本机 → 手机）

复制 `~/.config/opencode` 到 `/home/yuan/.config/opencode`，只改三处：

| 改动 | 原因 |
| --- | --- |
| `"shell": "pwsh"` → `"bash"` | 手机没有 PowerShell |
| `plugins` 里的 `C:/Users/yuan/.config/opencode/plugins/yzopencode` → `/home/yuan/.config/opencode/plugins/yzopencode` | Windows 绝对路径在 Linux 不存在 |
| `mcp.servers.codegraph.disabled = true` | codegraph 没有 arm64 二进制（PC 上是 x64 npm 包） |

**没有复制**：`auth.json`、`provider.lm.options.apiKey`（手机端要登录就在手机上 `opencode auth login`）。
**后来按用户要求补了** `service.json`（只有 web 口令，与 PC 一致，600 权限、不入库），见 4.3。
`context7` / `websearch` 两个远程 MCP 不需要凭据，已实测 `mcp connected`（各 2 tools）。

### 3.3 本地插件必须带 `node_modules`

第一次只拷了 `plugins/yzopencode/index.js` + `tui.js`，结果是：

```
opencode auth list → "Location plugins did not finish activating"（约 13 s 后放弃）
```

因为这个插件是**外部依赖式**打包（`import { Plugin } from "@opencode/plugin/effect"`、`effect`、`zod` …），
没有 `node_modules` 时模块解析卡住、激活永远不完成。补上 PC 的同版本依赖后正常：

```sh
tar -czf oc-nm.tgz -C ~/.config/opencode --exclude node_modules/.bin node_modules package.json
# 解到 /home/yuan/.config/opencode → 64 MB
```

> `msgpackr-extract` 的 native 包只有 win32 版，Linux 上缺失会在 `try/catch` 里回退到纯 JS，不影响功能。

### 3.4 验证

```sh
opencode --version                     # 2.2.5
opencode run --model opencode/deepseek-v4.1-flash-free "reply with exactly: CHROOT_OK"
# → CHROOT_OK（首次 23 s，含插件激活 + MCP 连接）
```

插件确实生效的旁证：`~/.config/opencode/auto-quota-recover.log`、`fetch-diag.log` 被创建（这正是 `yzopencode` 干的事）。

> `opencode auth list` 这类**短命令**仍可能打印 `Location plugins did not finish activating`：
> CLI 只等约 5–13 s，而两个插件 + 两个 MCP 在 4 核 A53 上启动要更久。**不影响 `run`/TUI**，属噪声。

---

## 4. OpenCode web 服务（`40-opencode-web.sh`）

### 4.1 为什么要用 `serve` 而不是 `service start`

chroot 里没有 systemd，`opencode service start` 只会在 `127.0.0.1` 上起本地服务；
要对局域网/ZeroTier 提供服务，直接跑 **与 PC 完全同一条命令行**：

```sh
opencode serve --hostname 0.0.0.0 --port 4300 --service
```

### 4.2 ★ 必须 `setsid`，否则进程活不过调用者

第一次用 `… opencode serve … &` 放在 `adb shell` 里，日志已经打印
`server listening on http://0.0.0.0:4300`，几秒后进程消失、端口消失。
原因：`serve` 是前台进程，没有脱离调用者的会话/进程组，调用者退出时被一起收掉。

```sh
LD_PRELOAD= /system/bin/chroot /data/debian /usr/bin/env -i \
  PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/home/yuan USER=yuan LOGNAME=yuan TMPDIR=/tmp LANG=C.UTF-8 \
  /usr/bin/setsid /usr/bin/setpriv --reuid=2000 --regid=2000 --groups=1015,1023,3003,3004 \
  /usr/local/bin/opencode serve --hostname 0.0.0.0 --port 4300 --service \
  >> /data/local/tmp/server.log 2>&1 < /dev/null &
```

启动后 `ps` 里能看到 `ppid=1`、`user=shell`(uid 2000)，这才是「真常驻」。

> `setpriv` 保留 `3003/3004` 组是必须的：内核 `CONFIG_ANDROID_PARANOID_NETWORK` 下缺 `aid_inet`
> 连 `socket(AF_INET)` 都会被拒（见 `docs/14` 坑 11）。

### 4.3 口令（与 PC 一致，但不入库）

| 项 | 值 |
| --- | --- |
| 文件 | `/home/yuan/.config/opencode/service.json`（600，属主 2000） |
| 内容 | `{"password": "…"}`，**与 PC 的 `service.json` 同一口令** |
| 认证方式 | HTTP Basic，`WWW-Authenticate: Basic realm="Secure Area"` |
| 用户名 | 固定 **`opencode`**（密码来自 `service.json`） |
| 免认证路径 | `/health`、`/global/health`；`/api/*` 其余都要认证 |

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.2.205:4300/api/config                    # 401
curl -s -o /dev/null -w '%{http_code}\n' -u 'opencode:<口令>' http://192.168.2.205:4300/api/config # 200
```

浏览器打开 `http://192.168.2.205:4300/`（或 `http://192.168.193.5:4300/`）时弹的就是这个 Basic 登录框。

### 4.4 实测

```
LAN  4300 web      200  0.219 s      LAN  4300 api(ok)  200  0.032 s
ZT   4300 web      200  0.089 s      ZT   4300 api(ok)  200
LAN  8080 nginx    200               ZT   8080 nginx    200
```

> 单个 `serve` 常驻 RSS 从 110 MB 涨到 350 MB+（插件 + MCP + 会话缓存）。
> 手机上**只允许一个实例**：脚本先查端口、再查 `pgrep -f "opencode serve …"`，两者都幂等。

---

## 5. 开机自启脚本

### 5.1 `30-zerotier.sh`

```sh
R=/data/debian
mkdir -p /dev/net; [ -e /dev/net/tun ] || ln -s /dev/tun /dev/net/tun   # tmpfs，每次开机重建
# 等 10-server.sh 挂好 /proc
while [ ! -e "$R/proc/1" ]; do sleep 1; done
# 等 wlan0 拿到 IPv4（main 表里没有 default，不能等 default 路由）
ip -4 addr show wlan0 | grep -q 'inet ' && …
# 幂等：9993 已在听就不重复起
LD_PRELOAD= /system/bin/chroot "$R" /usr/bin/env -i PATH=… /usr/sbin/zerotier-one -d >> "$LOG" 2>&1
# 后台补策略路由（先读缓存子网，再等 zt 路由出现）
( … ip rule add to 192.168.193.0/24 lookup main priority 21000 … ) &
```

### 5.2 `40-opencode-web.sh`

见 4.2：等 `/proc` → 端口/进程幂等检查 → `setsid + setpriv` 起 `opencode serve` → 写 pid 文件。

### 5.3 实测开机日志

```
[2026-11-24 12:18:14] sshd start rc=0
[2026-11-24 12:18:14] nginx: start rc=0
[2026-11-24 12:18:14] zerotier: start rc=0
[2026-11-24 12:18:14] zerotier: policy rule added (cached): to 192.168.193.0/24 lookup main
[2026-11-24 12:18:16] zerotier: diag: route=[… 192.168.193.0/24 dev ztyqb623ap …]
[2026-11-24 12:18:14] opencode: started pid=1322 (uid 2000, 0.0.0.0:4300)
server listening on http://0.0.0.0:4300
```

---

## 6. 边界与提醒

| 项 | 说明 |
| --- | --- |
| 内存 | 整机 3.68 GB；opencode `serve` 常驻 110→350 MB 且随会话增长，模型请求是远端，本地不做推理 |
| 磁盘 | opencode 二进制 248 MB + `node_modules` 64 MB + ZeroTier ~20 MB，`/data` 仍余 50 GB+ |
| Basic 认证是明文 | HTTP 上密码可被同网段抓包；ZeroTier 通道本身加密。**不要**在路由器上把 4300 映射到公网 |
| 不要在路由器上映射 2222 | 远程走 ZeroTier；ZeroTier 的 `zt` 接口属于加密虚拟网，不暴露公网端口 |
| 手机端登录 provider | `opencode auth login`（凭据只落手机）；或用本地/局域网 provider（`lm` 指向 `192.168.2.214:1234`） |
| `ninfer` provider | 配置里 `127.0.0.1:8080` 是 PC 的本地模型服务，在手机上指向的是 nginx，需要时改成 PC 的局域网 IP |
| 老内核降权告警 | ZeroTier 以 root 运行（见 2.6），这是这台机器无法规避的 |
