# 去预装（ColorOS 3.0 debloat）

> 日期：2026-11-24　设备：OPPO R9sk（`R9sk_11_A.37_191127`）/ Android 6.0.1 / ColorOS 3.0 / MSM8953
> 前置：已 root（Magisk 23.0），`/system` 只读，无 SIM（`gsm.sim.state=READY,ABSENT`）
> 目标：这台机器已经当服务器用（Debian chroot + sshd:2222 + ZeroTier + OpenCode web:4300），
> 需要把后台白吃 RAM 的预装清掉，**但不能动它作为「手机」和「传感器盒子」的能力**。

---

## 1. 边界（机主 2026-11-24 明确）

**保留**「手机这台机器特有的核心能力」+「传感器相关能力」：

| 保留项 | 包 |
| --- | --- |
| 相机全套 + 拍照特效 + 图库 | `com.oppo.camera` 及 8 个插件、`com.coloros.photoeffects`、`com.coloros.gallery3d` |
| 指纹（传感器） | `com.coloros.fingerprint`、`com.oppo.fingerprints.fingerprintsensortest` |
| 其它传感器 / GNSS | `com.oppo.freefallingmonitor`、`com.gnss.power`、`com.qualcomm.location`、`com.android.location.fused`、`com.amap.android.location`、`com.dsi.ant.server` |
| 音频硬件能力 | `com.oppo.multimedia.dirac`、`se.dirac.acs` |
| 投屏（Wi-Fi Display） | `com.qualcomm.wfd.service` |
| 通话 / 短信 / 联系人 | `com.android.phone`、`com.android.server.telecom`、`com.android.incallui`、`com.android.mms`、`providers.telephony`、`providers.contacts`、`com.coloros.phonenoareainquire` |
| 录音 / 手电 / 截屏 / 闹钟 / 文件管理 / 输入法 | `com.coloros.soundrecorder`、`com.coloros.flashlight`、`com.coloros.screenshot`、`com.coloros.alarmclock`、`com.coloros.filemanager`、`com.sohu.inputmethod.sogouoem` |
| 语音识别引擎（输入法语音键依赖） | `com.iflytek.speechcloud` |
| 系统骨架 | `systemui`、`settings`、`launcher`、`recents`、`keyguard`、`notificationmanager`、`wirelesssettings`、`packageinstaller`、`shell`、`externalstorage`、`safecenter`、`mcs`、`activation`、`usbselection` |

**删除**：商店 / 推广 / 统计 / OTA / 云 / 备份 / 主题 / 壁纸 / 锁屏杂志 / 娱乐 / 语音助手 /
运营商增值 / 虚拟 SIM / 高通调试 / 厂商日志 —— 共 **58 个**，清单见 `scripts/debloat-list.txt`。

---

## 2. 结论（实测）

| 指标 | 卸载前 | 卸载后 | 变化 |
| --- | --- | --- | --- |
| 已安装包 | 181（180 系统 + 1 三方） | **123** | −58 |
| 内存 used / free（MB，`dumpsys meminfo`） | 2915 / 679 | **1362–2239 / 1355–1915**（3 次采样） | free ×2–2.8 |
| `nearme.instant.platform` PSS | 36.9 MB | 已卸载 | 快应用框架，最大的单体垃圾 |
| `ted.number` PSS | 31.2 MB | 已卸载 | 号码识别 |
| `nearme.statistics.rom` PSS | 12.4 MB | 已卸载 | 统计上报 |
| `FATAL EXCEPTION` / `ANR` | — | **0** | logcat 全量扫描 |
| 重启后 ssh:2222 / web:4300 | 26.1 s | 25–33 s | 见 §5，服务本身没慢 |
| 重启后 PC→ZT web | 26.1 s | 30–33 s | 同上 |
| 5 个核心进程 | — | systemui / keyguard / phone / launcher / safecenter 全在 | 见 evidence |

> **注意 opencode 的 PSS 不能直接对比**：它随会话增长（卸载前 408 MB 是长跑后，
> 重启后 161 MB 是冷启动），不是去预装省下来的。

---

## 3. 方法：为什么是 `pm uninstall -k --user 0`

```
su -c 'pm uninstall -k --user 0 <pkg>'
```

- `/system` 是 `ro`（`/dev/block/bootdevice/by-name/system ext4 ro`），删不掉也没必要删。
- `--user 0` 对唯一用户卸载 → 桌面图标、进程、自启全部消失，效果等同「卸载」。
- APK 仍在 `/system`，`-k` 保留 `/data` 数据 → 恢复不需要重新下载。
- 真实状态写在 `/data/system/users/0/package-restrictions.xml`：
  ```xml
  <pkg name="com.android.browser" inst="false" stopped="true" nl="true" />
  ```
- **Android 6 没有 `pm install-existing`**（`Error: unknown command`），所以不能像 Android 7+
  那样一条命令装回来 —— 恢复路径见 §4。
- 没有用 `pm disable-user`：禁用只是隐藏组件，进程也可能被别的入口拉起来，
  且状态同样落在 package-restrictions，恢复成本一致，收益更低。

---

## 4. 恢复：三条路径，只有一条能脚本化

### 4.1 直接 `pm install` → 被 ColorOS 安装门挡住（**表现为卡死**）

```
su -c 'pm install -r -d /system/app/OppoOperationManual/OppoOperationManual.apk'
        pkg: /system/app/OppoOperationManual/OppoOperationManual.apk
        ... 之后 180–300 s 无任何输出
```

不是 PackageManager 死锁。此时：

```
$ dumpsys window | grep mFocusedApp
  mFocusedApp=... com.android.packageinstaller/.OppoPackageInstallerActivity
```

是 ColorOS 的安装确认页被拉到锁屏后面，等人点。`docs/13` 已经记录过这个门
（`OppoInstallerReceiver` + `VerifyControlService`），当时结论是「会话 API 可绕过」——
对**安装新包**成立，对**恢复 `inst="false"` 的系统包**不成立（见 4.2）。

修复靠 UI 自动化（实测可用，但脆）：

```sh
input keyevent 224                       # 亮屏
input swipe 540 1600 540 200 200         # 上滑
input keyevent 82                        # 解 keyguard
input tap 810 1839                       # 安装按钮坐标（1080x1920 / density 480）
# -> InstallAppProgress -> package:/data/app/<pkg>-1/base.apk
```

> `uiautomator dump` 抓不到该页按钮节点（`bottom_button_layout` 无子节点），只能点坐标。

### 4.2 PackageInstaller 会话 API → 装得上，但安装态不回来

```sh
pm install-create -r -g -S $SIZE      # Success: created install session [955746753]
pm install-write -S $SIZE $ID base /data/local/tmp/x.apk
pm install-commit $ID                 # Success
pm list packages | grep <pkg>         # 空
pm list packages -u | grep <pkg>      # package:<pkg>  ← 仍标记为「已卸载」
pm enable --user 0 <pkg>              # Package <pkg> new state: enabled，但 pm path 仍为空
```

原因：系统包同版本已存在，commit 只替换了代码、没有清掉 user 0 的 `inst="false"`。
（对**新增/升级**包，会话 API 依然是绕过安装门的正确姿势，见 `docs/13`。）

### 4.3 改 `package-restrictions.xml` + 重启 → **完整恢复（采用）**

`scripts/restore-coloros.sh --apply` 做的事：备份 → 删掉这些 `<pkg .../>` 行 →
校验 XML 头尾 → 提示重启。实测：

```
pkg=com.coloros.feedback before=1 after=0 lines=135
xml-head=ok / xml-tail=ok
（reboot）
pm path com.coloros.feedback -> package:/data/app/com.coloros.feedback-1/base.apk
```

所以本仓库的去预装是**可回滚**的：`scripts/restore-coloros.sh --apply` + `adb reboot`。

### 4.4 全量回滚演练（58 个包，端到端）

单包实验不足以证明批量可用，所以又做了一次完整往返：**58 个全恢复 → 重启（181 包）→ 再全卸载（123 包）**。

| 时刻 | 动作 / 观测 | 证据 |
| --- | --- | --- |
| 16:51 | 快照：`inst="false"` 共 58 条 | `work/debloat/package-restrictions.xml` |
| 16:58 | `restore-coloros.sh --apply`，备份含 58 条 `inst="false"`，头尾校验 ok | `work/debloat/drill-bak.xml` |
| ~16:59 | `adb reboot` | — |
| 16:59:59–17:01:59 | 回滚后跑 `debloat --apply`：`removed=58 skipped=0 failed=0` → 58 个包确实都回来了 | `debloat.log` |
| 17:05 | 逐包 `pm path`：GONE=55，3 个仍可解析（`com.dropboxchmod` / `com.ted.number` / `com.svox.pico`） | `work/debloat/restrictions-now.xml`（55 条） |
| 17:12 | 重跑 `debloat --apply`：`removed=3 skipped=55 failed=0` | `debloat.log` |
| 17:13 | `adb reboot` → 58/58 GONE，`pm list packages`=123 | `work/debloat/check-postboot.txt` |

**注意这 3 个包**：第一次 `--apply` 同样返回 `Success`，但 `pm path` 4 分钟后仍能解析；重跑一次并重启才彻底消失。
脚本是幂等的，遇到残留直接重跑 `--apply`，不要怀疑脚本逻辑。

---

## 5. 重启计时（0 回归，差异来自 Wi-Fi 关联）

两次 `adb reboot` 实测：

```
adb device back 17.5–17.6 s
ssh:2222        32.0–32.6 s
web LAN         32.4–32.8 s
web ZT          32.7–33.3 s
```

最终一轮（去预装全部完成后）再测一次：

```
adb device back 16.0 s / boot_completed +7.8 s（累计 24 s）
ssh:2222        +1 s      （累计 25 s）
web LAN         +0 s
web ZT          +4 s      （累计 29.6 s）
```

历史基线（卸载前，`docs/14`）是 26.1 s。最终一轮 29.6 s，看起来慢了 3–7 s（随 Wi-Fi 关联抖动），但服务本身没有变慢：

```
[2026-11-24 16:49:46] === boot: start ===
[2026-11-24 16:49:47] sshd start rc=0
[2026-11-24 16:49:47] opencode: started pid=1321 (uid 2000, 0.0.0.0:4300)
[2026-11-24 16:50:00] zerotier: policy rule added (cached): to 192.168.193.0/24 lookup main
```

sshd / opencode 在 boot 标记后 **1 s 内**就绪，ZT 策略路由 **13 s** 就绪；
「PC 能连上」的时刻由 wlan0 关联 + DHCP 决定，这一段的抖动（26↔33 s）属于环境，
与去预装无关。判据是 `server.log` 的时间戳，不是 ping 通的时间。

---

## 6. 操作手册

```bash
# 0) 备份清单里的 APK（可选，但建议：/system 虽在，重刷固件就没了）
#    实测整包备份 58 个到 PC，最大 54 MB，合计约 200 MB；work/ 已在 .gitignore

# 1) 部署
adb push scripts/debloat-list.txt    /data/local/tmp/debloat-list.txt
adb push scripts/debloat-coloros.sh  /data/local/tmp/debloat-coloros.sh
adb push scripts/restore-coloros.sh  /data/local/tmp/restore-coloros.sh

# 2) 先看计划（不执行）
adb shell su -c 'sh /data/local/tmp/debloat-coloros.sh'

# 3) 执行
adb shell su -c 'sh /data/local/tmp/debloat-coloros.sh --apply'
#    日志：/data/local/tmp/debloat.log

# 4) 验证
adb push scripts/debloat-check.sh   /data/local/tmp/debloat-check.sh
adb shell su -c 'sh /data/local/tmp/debloat-check.sh'    # 期望全部 GONE
adb shell su -c 'logcat -d | grep -cE "FATAL EXCEPTION|ANR in"'   # 期望 0

# 5) 回滚（先确认 /data/local/tmp/debloat-list.txt 还在）
adb shell su -c 'sh /data/local/tmp/restore-coloros.sh --apply'
adb reboot
```

---

## 7. 踩坑清单

1. **别把 ColorOS 安装门当成 PM 死锁**：`pm install` 卡在 `pkg:` 行是因为
   `OppoPackageInstallerActivity` 在等人点，`dumpsys window | grep mFocusedApp` 一看就知道。
2. **PowerShell 会吃掉嵌套引号**：`adb shell "su -c 'sed -i \"/x/d\" f'"` 到设备上会变成
   `sed: unmatched 'y'`。带引号的设备侧逻辑一律写成脚本 `adb push` 过去再 `sh`。
3. **`uiautomator dump` 抓不到 ColorOS 安装页按钮**，只能按坐标点（810,1839）。
4. **卸载状态不在 packages.xml**，在 `package-restrictions.xml` 的 `inst="false"`；
   改之前必须 `cp` 备份 + 改完校验 XML 头尾，否则 PMS 解析失败会重置用户包状态。
5. **首次重启后 PC→ZT 可能几分钟不可达**：ZT peers 走 relay、ARP 未建立；
   从设备侧 `ping 192.168.193.4` 立刻恢复直连。后续两次重启都在 33 s 内可达，
   属 ZeroTier 路径协商，与去预装无关（`docs/15` 的策略路由规则仍然生效）。
6. **不要动 `com.coloros.safecenter`**：它是权限管理（App 权限弹窗、清理），
   删了会让其它应用申请权限直接失败；`com.coloros.mcs` / `activation` 同理属于系统骨架。
7. **`com.iflytek.speechcloud` 保留**：搜狗输入法的语音键依赖它，删了会 FC；
   真要删，先换输入法。
8. **个别包 `pm uninstall --user 0` 返回 `Success` 但没真卸载**：实测 `com.dropboxchmod` /
   `com.ted.number` / `com.svox.pico` 第一次 `Success` 之后 `pm path` 仍可解析，重跑一次
   （再重启）才消失。脚本幂等，复查发现残留就重跑 `--apply`，别当成脚本 bug。
9. **验证要逐包 `pm path`，不看 `pm list packages` 计数**：`-u` 会把已卸载的算进去，
   计数差 1 很容易漏判。用 `scripts/debloat-check.sh`（循环查 `debloat-list.txt`）：
   期望 `GONE=58 OK=0`。
