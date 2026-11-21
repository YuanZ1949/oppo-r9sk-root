# 09 · KingRoot 为什么打不开：OPPO ROM 黑名单逆向

> **结论先行**：不是「应用被加密」，也不是 KingRoot 自己的风险弹窗。
> 是 OPPO 在 `system_server` 里按**包名 + versionCode 区间**执行的 ROM 黑名单拦截。
> 弹窗是系统弹的，唯一按钮只关闭弹窗，**不会放行**。

---

## 1. 现象

| 操作 | 结果 |
| --- | --- |
| 点桌面 KingRoot 图标（用户目击） | 弹「应用存在风险」，进不去 |
| `am start ... SliderMainActivity` | `Warning: Activity not started because the current activity is being kept for the user.` |
| `am start ... RootProcessActivity` | 同样的警告 |
| `am start ... RePackageWarningActivity` | 同样的警告 |
| `am start` SafeCenter / HOME | 正常（`its current task has been brought to the front`） |
| `monkey -p com.kingroot.kinguser ...` | 无输出，不启动 |

- 安装包签名主体：`CN=kingroot, O=kingroot, C=Beijing`，不像随手重打包（未与官方证书指纹比对）。
- 版本：`versionCode=204`，`versionName=5.4.0`（`/data/app/com.kingroot.kinguser-1/base.apk`，11,519,732 B）。
- `persist.sys.startupmanager` 未设置 → 代码默认值 `true`。

> `am` 那句「current activity is being kept for the user」是
> `ActivityManager.START_SWITCHES_CANCELED (4)` 的客户端文案，
> 但这里**不是**全局 app switch 被停：SafeCenter/HOME 都能正常切前台。
> OPPO 把同一个返回码复用于自己的黑名单拦截。

---

## 2. 代码级证据链

### 2.1 入口：`ActivityStackSupervisor.startActivityLocked`

OPPO 在标准启动流程里插了一刀：

```smali
invoke-virtual/range {v6 .. v12}, Lcom/android/server/am/OppoAppStartupManager;->handleStartActivity(...)Z
move-result v6
if-eqz v6, :cond_134
const/16 v39, 0x4        # ActivityManager.START_SWITCHES_CANCELED
```

AOSP 6.0.1 的常量定义：

```java
public static final int START_SWITCHES_CANCELED = 4;
```

所以 `am` 打出的警告与 OPPO 的拦截是同一个返回码。

### 2.2 判定：`OppoAppStartupManager.handleStartActivity`

```java
mSwitch = SystemProperties.getBoolean("persist.sys.startupmanager", true);

// handleStartActivity(Intent, ActivityInfo, callingPackage, callingUid, callingPid, userId)
if (!mSwitch) return false;
String calledPkg = aInfo.packageName;

if (OppoListManager.getInstance().isAppStartForbidden(calledPkg)) {
    Log.v(TAG, calledPkg + " is forbidden to start");

    // 只有桌面启动时才弹窗；Termux 的 am start 只静默拦截
    if ("com.oppo.launcher".equals(callingPackage)) {
        Message msg = Message.obtain();
        msg.what = 0x258;
        msg.obj = calledPkg;
        mAms.mUiHandler.sendMessage(msg);
    }
    return true;
}
```

关键点：**黑名单检查在 caller 判断之前**，所以不管从桌面、Termux 还是别的 App 启动，都会被拦。

### 2.3 名单：`OppoListManager`

```java
// readRomListFileLocked()
File file = new File("data/system/sys_rom_black_list.xml");   // system_server 的 cwd 是 /
// 解析 <startForbidden minCode="..." maxCode="...">包名</startForbidden>
mStartForbiddenList.put(pkg, Arrays.asList(minCode, maxCode));

// inAppStartForbiddenCodeList()
if (minCode == 0 && maxCode.equals("max")) return true;       // 全版本封禁
if (minCode <= versionCode &&
    (maxCode.equals("max") || versionCode <= maxCode)) return true;
```

- 本机文件：`/data/system/sys_rom_black_list.xml`，`-rw------- system system`，**2394 B**，mtime `2026-11-21 19:17`。
- KingRoot `versionCode=204` 被命中（否则不会走到拦截分支）。
- 具体 `minCode/maxCode` 不可读（文件 600），但**条目存在**这一点由「桌面弹窗 + 所有组件被拦」实测坐实。

### 2.4 弹窗：`ActivityManagerService$UiHandler`

```java
case 0x258:
    if (!mShowDialogs) break;
    OppoAppStartupManager.getInstance().handleAppStartForbidden(pkg); // 解析 XML 文案
    if (title != null && content != null && button != null) {
        AlertDialog d = new AlertDialog.Builder(mContext, 0xc030007).create();
        d.getWindow().setType(0x7d3);          // TYPE_SYSTEM_ALERT
        d.setCancelable(false);
        d.setTitle(title);
        d.setMessage(content);
        d.setButton(BUTTON_POSITIVE, button, obtainMessage(0x30, d));
        d.show();
    }
    resetDialogShowText();
    break;

case 0x30:
    ((Dialog) msg.obj).dismiss();              // 按钮只关闭弹窗
    break;
```

文案格式由 `OppoAppStartupManagerUtils.parseForbidText()` 决定：

```java
// 形如：标题#正文#按钮
mDialogTitleText   = text.substring(0, firstHash);
mDialogContentText = text.substring(firstHash + 1, secondHash);
mDialogButtonText  = text.substring(secondHash + 1);
```

> 所以用户看到的「应用存在风险」是 **OPPO 系统弹窗的标题**，
> 不是 KingRoot 的 `RiskPopActivity`。后者是繁体「嚴重安全警告 / 信任此軟件」，
> 而且 KingRoot 进程根本没起来，不可能由它弹。

### 2.5 名单从哪来：`OppoGuardElf`

```java
// ConfigUpdateUtil.updateStartForbiddenAppList()
String xml = getDataFromProvider("sys_rom_black_list");
if (xml != null) {
    OppoFileUtil.saveStrToFile("/data/system", "sys_rom_black_list.xml", xml);
}

// getDataFromProvider()
ContentResolver.query(
    Uri.parse("content://com.nearme.romupdate.provider.db/update_list"),
    new String[]{"xml"},
    "filtername=\"sys_rom_black_list\"", null, null);
```

- 名单由 OPPO 的 ROM 更新 provider 下发，`OppoGuardElf` 落盘到 `/data/system/`。
- 文件 mtime 19:17 说明当天有过一次写入/刷新（大概率是 `OppoGuardElf` 从 provider 拉取后落盘）。
- 这不是用户设置，也不是 SafeCenter 的「信任应用」能改的本地名单。

---

## 3. 为什么不能「点信任」或「加白名单」

| 可能入口 | 实测/代码结论 |
| --- | --- |
| 弹窗按钮 | 只有一个 `BUTTON_POSITIVE`，action 固定 `dismiss()`；没有删除名单项的回调 |
| 弹窗返回键/点外部 | `setCancelable(false)`，不能取消 |
| SafeCenter「信任应用 / 加入白名单」 | 那是病毒查杀/权限风险的流程，不接管 `sys_rom_black_list.xml` |
| `settings` / `content` 命令 | Termux 是普通 app uid，`getContentProviderExternal` 需要 `ACCESS_CONTENT_PROVIDERS_EXTERNALLY`，直接被拒 |
| 工程模式暗码 | APK 内没有 `startupmanager` / `sys_rom_black_list` / `startForbidden` 相关字符串；暗码表是固定 action，不能任意 `setprop` |
| 直接改文件 | `600 system:system`，读都不行；写需要 root —— 死循环 |

---

## 4. 绕过办法逐条判定

| 办法 | 判定 | 说明 |
| --- | --- | --- |
| 改 `/data/system/sys_rom_black_list.xml` | ❌ | 需要 root；而 root 正是目标，形成死循环 |
| `setprop persist.sys.startupmanager false` | ❌ | 需要 root/system uid；且 `mSwitch` 只在构造时读一次，改完还得重启 system_server |
| 换一个 KingRoot 版本 | ⚠️ 理论可行 | 名单带 `minCode/maxCode`；若条目不是 `0,max`，区间外版本可能启动。但名单不可读，且 5.4.0 已是老版本、服务端早已停止维护；即使启动也大概率 root 不了 |
| 改包名重打包 | ⚠️ 理论可行 | 名单按包名匹配；但 APK 内有「KingRoot被篡改，无法安全授权」的校验提示，重打包很可能触发校验，exploit 也未必还能用 |
| 换别的 root App | ❌ | 同类工具大概率同样在黑名单；且本机 CVE 路线已实测证伪 |
| **9008 EDL** | ✅ | 芯片级写入，不受 Android 层黑名单影响；仍是唯一确定性路径 |

---

## 5. 对整体路线的影响

- KingRoot 不是「服务挂了所以没用」，而是**在这台 ROM 上被系统明确禁止启动**：连界面都进不去。
- 即使绕过启动，KingRoot 5.4.0 依赖的旧 exploit 对**补丁 2018-06** 的 3.18.24 内核也**大概率无效**（已知的 Dirty COW / QuadRooter 均已修复，见 `03-cve-analysis.md`）。
- 因此：**不要再在 KingRoot / 一键 root 上花时间**。9008 仍是唯一可行路线。

---

## 6. 复现命令

```bash
ssh r9sk
export PATH=/system/bin:$PATH

# 1) 复现拦截
am start --user 0 -n com.kingroot.kinguser/com.kingroot.kinguser.activitys.SliderMainActivity
# → Warning: Activity not started because the current activity is being kept for the user.

# 2) 对照：别的 App 正常
am start --user 0 -n com.coloros.safecenter/com.coloros.safecenter.MainActivity

# 3) 设备事实
getprop persist.sys.startupmanager          # 空 → 默认 true
ls -l /data/system/sys_rom_black_list.xml   # 600 system system, 2394 B
pm path com.kingroot.kinguser               # /data/app/com.kingroot.kinguser-1/base.apk
```

PC 侧反编译（`services.odex` → `services.dex` → baksmali）：

```powershell
java -jar baksmali.jar d services.dex -o smali_services
# 关键类：
#   com/android/server/am/OppoAppStartupManager.smali
#   com/android/server/am/OppoAppStartupManagerUtils.smali
#   com/android/server/coloros/OppoListManager.smali
#   com/android/server/am/ActivityManagerService$UiHandler.smali
#   com/android/server/am/ActivityStackSupervisor.smali
```

原始输出见 `evidence/2026-11-21-kingroot-block.txt`。

---

## 7. 实测 / 推断标注

| 结论 | 性质 |
| --- | --- |
| `am start` 警告、所有 KingRoot 组件被拦、SafeCenter/HOME 正常 | **实测** |
| `persist.sys.startupmanager` 未设置（默认 true） | **实测** |
| `/data/system/sys_rom_black_list.xml` 600、2394 B、mtime 19:17 | **实测** |
| KingRoot versionCode=204 / 5.4.0、签名未变 | **实测** |
| 拦截链：`ActivityStackSupervisor` → `OppoAppStartupManager` → `OppoListManager` | **代码确认**（反编译 system_server） |
| 返回码 4 = `START_SWITCHES_CANCELED` | **代码确认**（OPPO smali + AOSP 常量） |
| 弹窗由 `UiHandler` 构造、单按钮只 dismiss | **代码确认** |
| 文案来自 `sys_rom_black_list.xml` 的 `标题#正文#按钮` | **代码确认** |
| 用户看到的「应用存在风险」就是该弹窗标题 | **推断**（文件不可读；代码只有这一条弹窗路径，且用户已目击该文案） |
| 名单条目的具体 `minCode/maxCode` | **未验证**（文件 600 不可读） |
