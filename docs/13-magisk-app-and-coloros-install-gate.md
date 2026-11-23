# Magisk App 安装 + 击穿 ColorOS 安装拦截

日期：2026-11-24
设备：OPPO R9sk（R9s_11_A.37_191127 / Android 6.0.1 / SDK 23），序列号 `244f****`

## 一、现象：任何安装都被「验证身份」挡住

```
adb install Magisk-v23.0.apk
  → Failure [-99]

# logcat 证据链
I AdbInstallerReceiver: ACTION_OPPO_INSTALL_FROM_ADB Receiver!
I ActivityManager: START u0 {act=oppo.intent.action.INSTALL_PACKAGE cmp=com.android.packageinstaller/.OppoPackageInstallerActivity}
D OppoAdbInstallerManager: OPPO_ADB_INSTALL_CANCEL apkPath == /sdcard/Magisk-v23.0.apk
```

流程：`adb install` / `pm install` → OPPO 的 `OppoPackageInstallerReceiver` 劫持
→ 拉起 `OppoPackageInstallerActivity` → 交 `com.coloros.safecenter/.verification.VerifyControlService` 做「验证身份」
→ 用户无法通过（`RegisterActivity`，uid 1000 启动）或等待超时
→ system_server 的 `OppoAdbInstallerManager` 打 `OPPO_ADB_INSTALL_CANCEL` → 返回 `-99`。

shell 与 root 的 `pm install` **都一样被拦**，说明拦截在 PMS 层，不在 adb。

### 试过但无效的绕法

| 尝试 | 结果 |
|---|---|
| `settings put global/secure install_non_market_apps 1` | 无效，仍 `-99` |
| `adb install -i com.oppo.market`（伪装应用商店） | 无效，仍 `-99` |
| 放进 `/system/app/Magisk/`（系统应用） | PMS 直接跳过：`This is not oppo app, so skip it :/system/app/Magisk` → `Failed to parse`，ColorOS 只认 OPPO 签名 |
| 只禁用 `RegisterActivity` | 不再弹验证页，但 `adb install` 会一直挂起等手机上的确认 |

## 二、解决方案（两件事）

### 1. 彻底装上一个 App：PackageInstaller 会话 API（不经过 adb 安装钩子）

即使拦截完全没动，这条路也能装进去 —— 它就是应用商店内部使用的安装方式：

```sh
APK=/sdcard/Magisk-v23.0.apk
SIZE=6874374                      # stat -c %s $APK
OUT=$(pm install-create -r -g -S $SIZE)
ID=$(echo "$OUT" | sed -n 's/.*\[\([0-9]*\)\].*/\1/p')
pm install-write -S $SIZE $ID base $APK
pm install-commit $ID
```

实测输出：

```
Success: created install session [2077336887]
Success: streamed 6874374 bytes
Success
package:com.topjohnwu.magisk
package:/data/app/com.topjohnwu.magisk-1/base.apk
```

> 脚本：`work/root/install_via_session.sh`

### 2. 关掉安装验证（让日常安装恢复正常）

只禁用「验证」这一环，**保留** `com.android.packageinstaller` 的 OPPO 组件
（把它们也禁用会让 `adb install` 永久挂起 —— 钩子在等一个永远不会回来的回调）：

```sh
# 关掉 APK 预扫描
settings put global oppo_apk_prescan_switch 0
settings put secure oppo_apk_prescan_switch 0

# 只禁用验证服务与验证页
pm disable --user 0 com.coloros.safecenter/.verification.VerifyControlService
pm disable --user 0 com.coloros.safecenter/.verification.register.RegisterActivity

# 保持启用（重要）
pm enable --user 0 com.android.packageinstaller/.OppoPackageInstallerActivity
pm enable --user 0 com.android.packageinstaller/.OppoPackageInstallerReceiver
```

效果：`adb install` 会走 OPPO 自己的安装器外观，但**不再要求验证身份**：

```
重新安装? → [重新安装] → 自动清除安装包/应用权限页 → [安装] → 安装完成
```

### 恢复原状（如需）

```sh
settings put global oppo_apk_prescan_switch 1
settings put secure oppo_apk_prescan_switch 1
pm enable --user 0 com.coloros.safecenter/.verification.VerifyControlService
pm enable --user 0 com.coloros.safecenter/.verification.register.RegisterActivity
```

## 三、装好 App 之后：`su` 为什么又拒绝了一次

App 首次启动会重建/接管 `/data/adb/magisk.db`，TWRP 里手工写的那条预授权记录被清掉，
`adb shell`(uid 2000) 回到默认 `QUERY` 策略：

```
I ActivityManager: START ... com.topjohnwu.magisk/.ui.surequest.SuRequestActivity
W Magisk: su: request rejected (2000)      # 10 秒没人点，自动拒绝
```

解决：Magisk App → 「超级用户」页 → 把 `Shell (com.android.shell)` 的开关打开。
之后 DB 里是 App 自己写的正式记录（含包名）：

```
package_name=com.android.shell|policy=2|uid=2000
```

## 四、最终验证（重启后）

| 项目 | 结果 |
|---|---|
| 开机 | `boot_completed=1` **28s**（健康基线 25–31s） |
| root | `uid=0(root) ... context=u:r:magisk:s0`，**无弹框** |
| Magisk | `23.0:MAGISK` / `23000`，`/sbin/su`、`/sbin/magisk` 存在 |
| 授权 | `policies`: uid 2000 → `policy=2 (ALLOW)`，package `com.android.shell` |
| MagiskHide | `MagiskHide is enabled`（重启保持） |
| App | `com.topjohnwu.magisk` @ `/data/app/com.topjohnwu.magisk-2/base.apk` |
| 模块系统 | `magisk --install-module` 实测成功（测试模块已删除） |
| 安装拦截 | `oppo_apk_prescan_switch=0`、验证服务/验证页 disabled，**重启保持** |
| `/sdcard` | 读写正常（`media_rw_data_file`） |
| SELinux | `Enforcing`；`verifiedbootstate=orange` |

## 五、截图证据

- `work/backup/magisk-app7.png`：Magisk 主页（23.0 已安装，Ramdisk 是 / A/B 否 / SAR 否）
- `work/backup/magisk-su-list.png`：超级用户页（Shell 条目）
- `work/backup/install-e2e.png`：不再出现验证页的安装确认
- `work/backup/install-e2e4.png`：**安装完成**

## 六、备注

- 屏幕顶部黄色条「工程师开发使用中，点击可关闭」是 ColorOS 开发者模式提示，点一下即可关闭，与本方案无关。
- `/data/local/tmp` 里的 `Magisk-v21.4.zip`、`boot.orig.bin` 是早期遗留，可随时 `rm`；PC 侧 `work/backup/boot.orig.bin` 才是回滚用的原厂 boot。
