# 15 · ZeroTier 远程接入 + OpenCode 2（arm64）装进 chroot

> 采集：`evidence/2026-11-24-zerotier-opencode.txt`
> 脚本：`scripts/30-zerotier.sh`（开机自启 ZeroTier）
> 时间：2026-11-24 · 实机实测（Debian 12.15 arm64 chroot / 内核 3.18.24）

---

## 1. 结论速览

| 项 | 结果 |
| --- | --- |
| ZeroTier | `zerotier-one 1.16.2` arm64，已 `join 8bd5124fd6ff23d9`，节点地址 **`23697636b0`** |
| 网络状态 | **等待 ZeroTier Central 授权**（`ACCESS_DENIED` / `REQUESTING_CONFIGURATION`），授权后才会出现 `zt*` 接口与托管 IP |
| 开机自启 | `/data/adb/service.d/30-zerotier.sh`，重启后 9993 已在听 |
| OpenCode | **v2.2.5** arm64 单文件二进制（248 MB）装到 `/usr/local/bin/opencode`，**不需要 Node** |
| 插件 | 与本机一致：本地 `plugins/yzopencode` + npm `@herjarsa/oh-my-openagent-v2@0.4.2`（两者都已实际生效） |
| 端到端 | `opencode run --model opencode/deepseek-v4.1-flash-free "…"` → **`CHROOT_OK`，23 s** |
| 凭据 | **没有**复制 `auth.json` / `service.json` / provider `apiKey`（按你的要求留空） |

重启计时（`adb reboot` 起算）：SSH **27.7 s** 可用；ZeroTier 与 nginx 均自动拉起。

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

### 2.4 授权（必须在网页端做一次）

1. 打开 https://my.zerotier.com → 网络 `8bd5124fd6ff23d9`；
2. 在 Members 里找到 **`23697636b0`**（未授权时前面是空心圆）；
3. 勾选 Auth，给它分配托管 IP（或留自动）。

授权前 `listnetworks` 显示：

```
8bd5124fd6ff23d9  da:00:96:a0:79:a2  ACCESS_DENIED  PRIVATE  ztyqb623ap  -
```

授权后应变成 `OK`，并出现 `ztxxxxxxx` 接口与 `10.x.x.x`/`192.168.x.x` 之类的托管地址。

### 2.5 两个已知告警（可忽略）

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

**没有复制**（按「凭据留空」）：`auth.json`、`service.json`、`provider.lm.options.apiKey`。
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

## 4. 开机自启脚本 `30-zerotier.sh`

```sh
R=/data/debian
mkdir -p /dev/net; [ -e /dev/net/tun ] || ln -s /dev/tun /dev/net/tun   # tmpfs，每次开机重建
# 等 10-server.sh 挂好 /proc
while [ ! -e "$R/proc/1" ]; do sleep 1; done
# 幂等：9993 已在听就不重复起
LD_PRELOAD= /system/bin/chroot "$R" /usr/bin/env -i PATH=… /usr/sbin/zerotier-one -d >> "$LOG" 2>&1
```

实测开机日志：

```
[2026-11-24 11:04:21] sshd start rc=0
2026/11/24 11:04:21 [warn] user directive ignored in /etc/nginx/nginx.conf:1
[2026-11-24 11:04:21] nginx: start rc=0
/usr/sbin/zerotier-one: WARNING: failed to drop privileges …, running as root
[2026-11-24 11:04:21] zerotier: start rc=0
Starting Control Plane...
```

---

## 5. 边界与提醒

| 项 | 说明 |
| --- | --- |
| 内存 | 整机 3.68 GB；opencode 空闲约 100–200 MB，模型请求是远端，本地不做推理 |
| 磁盘 | opencode 二进制 248 MB + `node_modules` 64 MB + ZeroTier ~20 MB，`/data` 仍余 50 GB+ |
| 不要在路由器上映射 2222 | 远程走 ZeroTier；ZeroTier 的 `zt` 接口属于加密虚拟网，不暴露公网端口 |
| 手机端登录 provider | `opencode auth login`（凭据只落手机）；或用本地/局域网 provider（`lm` 指向 `192.168.2.214:1234`） |
| `ninfer` provider | 配置里 `127.0.0.1:8080` 是 PC 的本地模型服务，在手机上指向的是 nginx，需要时改成 PC 的局域网 IP |
| 老内核降权告警 | ZeroTier 以 root 运行（见 2.5），这是这台机器无法规避的 |
