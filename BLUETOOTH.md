# OnePlus 16 上 OPPO Enco X4 的 LC3 / LE Audio 限制机制分析

| 项目 | 内容 |
|---|---|
| 设备 / 固件 | 一加 16 `PYB110_17.0.1.201`（已 root） |
| 分析对象 | `Bluetooth.apk`、`oplus_bluetooth_common_ext.jar`、`com.oplus.melody`（使用 jadx 反编译） |
| 文档状态 | 已对照反编译源码复核，并在设备上实测方案 A、B/C（见第 6 节） |

> 下文中的类路径均相对于 `oplus_bluetooth_common_ext.jar` 中的 `com/oplus/bluetooth/`，除非另注明。类名与行为来自该固件版本，其他版本可能不同。

## 1. 结论摘要

1. X3 与 X4 的区别不在白名单，而在耳机上报的 **“LE Audio 共存（Coexistence）”特性位**：X4 支持，系统将其按 **BR/EDR + LE Audio 双模共存** 处理，X3 按 **纯 LE Audio 单模** 处理。
2. 双模共存时，LE Audio 仅在 **“游戏低延迟模式” 且前台包名在双模白名单内** 时被激活，其余时间保持 A2DP/HFP。
3. 双模白名单 = 系统硬编码列表 ± 云控 `add_list` / `delete_list`，云控落地文件为 `/data/misc/bluedroid/bt_oplus_iot_list.conf`。
4. 实测结果：
   - **方案 B（自定义白名单）**：✅ 已验证。把原神加入 `add_list` 后，打开原神自动切换到 LC3。
   - **方案 C（伪造游戏态）**：✅ 已验证。设置 `debug_gamemode_*` 后 LE Audio 成为活动设备，A2DP/HFP 被清空。
   - **方案 A（关闭共存开关）**：❌ 失败，不可行（见“方案 A”一节）。

## 2. X3 与 X4 的区分机制

### 2.1 特性位

O-Echo（SmartAudio）握手时，耳机上报特性掩码，系统检查 bit14（`0x4000`）：
`feature/smartaudio/OplusBluetoothSmartAudioServer.java` 中 `onRemoteSmartAudioFeatureCallback()` → `OplusDualModeManagerImpl.notifyDualModeSupport()`。

| 耳机 | `PeerSmartAudioFeature` | bit14 | 判定 |
|---|---|---|---|
| Enco X3 | 3070 (`0x0BFE`) | 0 | 不支持共存 |
| Enco X4 | 56318 (`0xDBFE`) | 1 | 支持共存 |

> 数值来自设备 `bt_remote_dev_info.conf` 中的 `PeerSmartAudioFeature`。

结果持久化到 `/data/user_de/0/com.android.bluetooth/shared_prefs/dual_mode_support.xml`（键为 MAC，值为 boolean），`isSupportDualConnectionInternal()` 读取该文件（带内存缓存）。

### 2.2 总开关

`OplusBtFeatureConfigHelper.hasDualMode()` 读取系统属性 `persist.sys.bt.leacoexist`（`Bluetooth.apk` 中 `mSupportDualMode`，进程启动时读取一次）。`OplusDualModeManagerImpl` 构造时据此设置 `mIsDualModeFeatureEnabled`：

- 为 `false` 时：`init/startUp` 直接返回，`isDualConnectionNeeded()` 恒为 `false`。
- **注意**：`notifyDualModeSupport()` 与 `isSupportDualConnection()` **均不受该开关控制**。X4 每次握手都会把 `dual_mode_support.xml` 中的标记重新写为 `true`（实测）。

### 2.3 两种路径的行为差异

| 位置 | 单模（`isSupportDualConnection == false`，X3） | 双模（`== true`，X4） |
|---|---|---|
| `leaudio/OplusLeAudioPhonePolicyExt.handleLeAudioAllowedScenario()` | 将对端 HFP/A2DP 策略设为 `0`（禁用经典蓝牙） | 保持 HFP/A2DP 策略为 `100` |
| `btservice/OplusActiveDeviceManagerExtImpl.oplusHandleLeaConnected()` | 返回 `true`，走 AOSP 默认逻辑，LE Audio 成为活动设备 | 仅当 `isDualConnectionNeeded() && isUltraGameMode()` 时设 LE Audio 为活动设备；否则设 A2DP/HFP 为活动设备 |
| `oplusHandleLeAudioActiveDeviceChanged()` | 调用 `disableBrEdrProfiles` 关闭经典蓝牙 | 不关闭 |
| LEA 广播开启方式 | AT 指令 `enableLeaBroadcastThroughAtCommand`（`leaudio/OplusLeAudioRemoteDevice`） | O-Echo 指令 `enableLeaBroadcastThroughEcho` |

### 2.4 Melody App 的 UI

`com.oplus.melody` 的 `p201o7/C0901b.java` 同样读取 `persist.sys.bt.leacoexist`；为 `true` 时隐藏详情页的全局 “LE Audio” 开关，改在游戏模式页提供 LC3 低延迟开关。

## 3. 双模 LC3 触发条件

`feature/lowlatency/BluetoothLowLatencyService.isUltraGameMode()`：

```java
isLowLatencyRequired() && isUltraGameModeAcceptPackage()
```

另外 `isDualConnectionNeeded()` 还要求：电源模式非省电、HFP 与 A2DP 策略均为 `100`、耳机支持共存、用户的双连接偏好为开，**且设备上至少安装了一个双模白名单包**（`OplusDualModeHelper.hasLowLatencyPackage()`）。

### 3.1 `isLowLatencyRequired()` = `mGameMode && isUserPreferLLMode()`

- `mGameMode`：`OplusBluetoothScenarioMonitor.handleGameSpaceModeChanged()` 在 `Settings.Global.debug_gamemode_value == "1"` 时置位，并通知低延迟服务。
- 当前前台游戏包名取自 `Settings.Global.debug_gamemode_savegame`。
- `isUserPreferLLMode()`：仅在静态标志 `sSupportLLByUserPrefer` 为 `true` 时生效。该标志在 **蓝牙进程启动时**（`ro.oplus.audio.support.low_latency_game` 为真且 `oplus_games_low_latency_state` 非空）或 **监听到该设置变化时** 置位，**置位后不会自动复位**。置位后，当前包名必须在 `mGameAppUserPreferMap` 中且值为 `1`；该 map 只能通过解析 `oplus_games_low_latency_state`（格式 `<包名>:<0|1>`，每次仅一个包）填充。

### 3.2 `isUltraGameModeAcceptPackage()`

`OplusDualModeManagerImpl.isDualModeAcceptPackage(debug_gamemode_savegame)` → `OplusDualModeHelper.mDualModePackageList`，由 `initPackageList()`（蓝牙启动时）构造：

```
DUAL_MODE_ACCEPT_LIST_DOMESTIC ∪ DUAL_MODE_ACCEPT_LIST_OVERSEAS
  ∪ 云控[dualmode_a2dp_lowlatency].add_list
  \ 云控[dualmode_a2dp_lowlatency].delete_list
```

**硬编码国内列表（22 项）**：`org.chromium.latency.walt`、`com.android.sound.localization`、`com.superpowered.superpoweredlatency`、`com.tencent.tmgp.pubgmhd`、`com.tencent.tmgp.dfm`、`com.garena.game.df`、`com.proxima.dfm.mobile`、`com.tencent.tmgp.codev`、`com.tencent.tmgp.sgame`、`com.tencent.lolm`、`com.tencent.tmgp.cod`、`com.tencent.tmgp.cf`、`com.netease.hyxd`、`com.netease.hyxd.nearme.gamecenter`、`com.netease.dwrg`、`com.netease.dwrg.nearme.gamecenter`、`com.tencent.mf.uam`、`com.gamestar.perfectpiano`、`com.hermes.mk`、`com.tencent.tmgp.speedmobile`、`com.netease.yhtj.nearme.gamecenter`、`com.netease.mrzh`。
海外列表另含 PUBG Mobile、Valorant、Phigros、Project Sekai 等，见 `btservice/OplusDualModeHelper.java`。

### 3.3 云控配置

- `feature/rus/OplusBluetoothRusHelper`：从 ROM Update 的 `filtername="sys_bt_iot_config_list"` 同步，写入 `/data/misc/bluedroid/bt_oplus_iot_list.conf`；蓝牙启动时由 `resetSections()` 解析该文件（不存在则忽略）。
- 解析器 `feature/common/OplusBluetoothConfigParser`：INI 风格，`[section]` + `key=value`，`#` 为注释；**每个键值行 `split("=")` 必须恰好得到 2 段**（值中不能含 `=`）。
- 设备 ROM Update 数据库（`rom_update.db`）中**没有** `sys_bt_iot_config_list` 条目，与“该文件当前不存在”一致（设备上的文件是否存在需实测确认）。

## 4. 可行方案

> 命令均需在已连接设备的电脑上执行（`adb shell su -c '...'`）。以下均为**依据源码的推演，未在设备上验证**。

### 方案 B：自定义双模白名单（推荐，✅ 已验证）

实测：设备上没有任何默认白名单游戏，因此 `hasLowLatencyPackage()` 为假；写入 `add_list=com.miHoYo.GenshinImpact` 并重启蓝牙后，打开原神即自动切换到 LC3。

保留日常 LHDC/AAC，对指定应用/游戏启用 LC3。

1. 写入云控文件（以原神、星穹铁道为例）：

```bash
adb shell su -c 'cat > /data/misc/bluedroid/bt_oplus_iot_list.conf <<EOF
[dualmode_a2dp_lowlatency]
add_list=com.miHoYo.GenshinImpact,com.miHoYo.hkrpg
EOF
chown bluetooth:bluetooth /data/misc/bluedroid/bt_oplus_iot_list.conf
chmod 660 /data/misc/bluedroid/bt_oplus_iot_list.conf
restorecon /data/misc/bluedroid/bt_oplus_iot_list.conf'
```

2. 处理“用户偏好”干扰：若设备上 `oplus_games_low_latency_state` 非空（示例设备上为 `com.miHoYo.GenshinImpact:1`），则 `sSupportLLByUserPrefer` 已为真，**只有该设置里标为 `:1` 的当前包名才满足 `isUserPreferLLMode()`**。因此二选一：
   - 在游戏助手中为目标游戏打开“低延迟”选项（由系统写入该设置）；或
   - 重启蓝牙进程后让该设置为空，使标志保持 `false`。
3. 目标应用必须被游戏助手识别为游戏（由其写入 `debug_gamemode_value/savegame`）。
4. 重启蓝牙使 `initPackageList()` 重新读取：

```bash
adb shell su -c 'pkill -f com.android.bluetooth'
adb logcat -d | grep -i OplusDualModeHelper
```

**注意**：
- 不需要写 `[a2dp_lowlatency] acceptlist_app`：该列表仅在 `persist.bluetooth.a2dp.low_latency_mode == 2`（默认 `1`，即黑名单模式）时才起作用，且属于经典 A2DP 低延迟，与双模 LC3 白名单是两套逻辑。
- ROM Update 一旦重新下发 `sys_bt_iot_config_list`，会覆盖该文件。可通过冻结 `com.oplus.romupdate` 或设置文件为只读防护，但这会影响其他云控项，请自行评估。

### 方案 A：关闭共存开关让 X4 按 X3 方式工作 —— ❌ 失败

原思路：关闭 `persist.sys.bt.leacoexist` 并清除 X4 的共存标记，使其走单模路径。

实测：停蓝牙 → 设属性为 `false` → 删除 `dual_mode_support.xml` → 重启蓝牙后，文件**立即被重新写回** `<X4_MAC> = true`。原因是 `OplusBluetoothSmartAudioServer.onRemoteSmartAudioFeatureCallback()` 每次握手无条件调用 `notifyDualModeSupport()`，且该方法不受总开关限制。

后果：总开关关闭使 `isDualConnectionNeeded()` 恒为 `false`，而 X4 仍被判为支持共存，`oplusHandleLeaConnected()` 走“设 A2DP/HFP 为活动设备”的分支，**LE Audio 永远不会激活，连游戏内 LC3 也失效**。

要真正让 X4 走单模路径，只能修改 `Bluetooth.apk` 或用 Xposed 类框架 hook `isSupportDualConnection` / `notifyDualModeSupport`，纯配置无法实现。已回退（属性恢复 `true`，文件从备份恢复）。

### 方案 C：伪造常驻游戏态（保留共存，✅ 已验证）

```bash
# 启用（无需 root）
adb shell settings put global debug_gamemode_savegame com.tencent.tmgp.sgame
adb shell settings put global debug_gamemode_value 1
# 关闭
adb shell settings put global debug_gamemode_value 0
```

实测（需先按方案 B 把 `com.miHoYo.GenshinImpact` 加入 `add_list` 并重启蓝牙，`savegame` 取该包名）：设置后 `ActiveDeviceManager` 记录 `Active Device Changed: X4 for profile: LE_AUDIO`，A2DP/HEADSET 活动设备变为 null，ASE 配置选中 `Lc3_32_2 ... Low_Latency`；原 codec 为 LHDC。此时所有应用声音均走 LC3。

前提与局限：
- 设备上必须已安装至少一个白名单包（`hasLowLatencyPackage()`），否则 `isDualConnectionNeeded()` 为 `false`；也可结合方案 B 添加一个必然存在的包。
- 若 `sSupportLLByUserPrefer` 已为真，还需 `oplus_games_low_latency_state` 为 `<该包名>:1`。**不要把它设为空串**（空值会被 `updateGameModeFromGlobal()` 直接忽略，不会清除已有 map）。
- 游戏助手或 Athena 可能随时重写这些键；`debug_gamemode_value=1` 还会触发游戏模式下的其他系统行为（性能策略、勿扰等），副作用需评估。

## 5. 验证状态

- 2026-11-08 在 OnePlus 16 + Enco X4 上实测：方案 A 失败；方案 B、C 成功（B 以真实打开原神验证，C 以设置 `debug_gamemode_*` 验证）。
- 设备上当前保留的改动：`/data/misc/bluedroid/bt_oplus_iot_list.conf`（`add_list=com.miHoYo.GenshinImpact`）。备份位于设备 `/data/local/tmp/btbak/`。
- 撤销：删除上述 conf 并重启蓝牙；若用过方案 C，执行 `settings put global debug_gamemode_value 0`。
- 以上改动不涉及系统 APK 修改，系统 OTA 或 ROM Update 重新下发 `sys_bt_iot_config_list` 后可能需要重做。
- 排查可用：`adb logcat | grep -E "OplusDualModeHelper|isDualConnectionNeeded|oplusHandleLeaConnected|BluetoothLowLatency"`，以及 `dumpsys bluetooth_manager` 中 `BluetoothActiveDeviceManager event log`。
