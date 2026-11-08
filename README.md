# OPPO Enco X4 × OnePlus：自定义 LC3 / LE Audio 白名单

在 OnePlus（ColorOS 17）手机上，OPPO Enco X3 可以全局使用 LC3 / LE Audio，而 Enco X4 被限制为**仅在白名单游戏运行时**才切到 LC3。本项目分析了该限制的实现，并提供一个脚本，用来自定义白名单、随时手动切换 LC3。

- 原理分析与实测记录：[BLUETOOTH.md](BLUETOOTH.md)
- 管理脚本：[x4lc3.sh](x4lc3.sh)

> [!WARNING]
> 本项目需要 **root** 并修改系统蓝牙配置，属于非官方用法，使用风险自负。已在 **OnePlus 16（`PYB110_17.0.1.201`）+ Enco X4** 上验证，其他机型/固件版本未测试，类名与行为可能不同。脚本不修改任何系统 APK，可随时撤销。

## 原理简述

X4 向手机上报“支持 LE Audio 共存”，系统因此将其按 **BR/EDR + LE Audio 双模** 处理：平时保持 A2DP（LHDC/AAC），仅当“游戏模式 + 前台包名在双模白名单”同时满足时才激活 LC3。白名单由系统内置列表加云控文件 `/data/misc/bluedroid/bt_oplus_iot_list.conf` 组成，蓝牙启动时读取。本项目向该文件追加自定义包名，并可手动设置游戏态让 LC3 常驻。详见 [BLUETOOTH.md](BLUETOOTH.md)。

已验证结论：

| 方案 | 结果 |
|---|---|
| 自定义白名单（写入 `add_list`） | ✅ 打开白名单应用后自动切换到 LC3 |
| 伪造常驻游戏态（`debug_gamemode_*`） | ✅ LE Audio 成为活动设备，所有声音走 LC3 |
| 关闭共存开关，让 X4 按 X3 方式工作 | ❌ 不可行：X4 每次连接都会重新上报共存标记 |

## 前提

- 已 root（需要 `su`），已开启 USB 调试并授权 adb。
- 电脑上有 `adb`（Android platform-tools）。脚本按以下顺序查找：环境变量 `ADB` → `PATH` → `$ANDROID_HOME` / `$ANDROID_SDK_ROOT` 下的 `platform-tools`。找不到会报错退出。
- 设备上**至少安装一个白名单应用**（内置白名单或你添加的），否则系统不会建立 LE Audio 双连接。

## 用法

```bash
chmod +x x4lc3.sh

./x4lc3.sh list                    # 查看自定义白名单与当前状态
./x4lc3.sh add com.example.game    # 添加应用（可多个），并重启蓝牙
./x4lc3.sh del com.example.game    # 删除应用，并重启蓝牙
./x4lc3.sh clear                   # 清空自定义白名单
./x4lc3.sh restart                 # 仅重启蓝牙

./x4lc3.sh on [包名]               # 开启常驻游戏态（全局 LC3）
./x4lc3.sh off                     # 关闭，切回 LHDC / A2DP
./x4lc3.sh status                  # 游戏态与最近的活动设备切换
```

环境变量：

| 变量 | 作用 |
|---|---|
| `ADB=/path/to/adb` | 指定 adb（默认从 PATH 查找） |
| `NO_RESTART=1` | `add` / `del` / `clear` 后不自动重启蓝牙 |

### 典型流程

```bash
# 1. 把一个已安装的应用加入白名单（会重启蓝牙，耳机自动重连）
./x4lc3.sh add com.miHoYo.GenshinImpact

# 2a. 直接打开该应用：系统识别为游戏后自动切到 LC3
# 2b. 或让 LC3 常驻（所有应用的声音都走 LC3）：
./x4lc3.sh on
./x4lc3.sh off      # 用完切回
```

### 注意事项

- 白名单只在蓝牙启动时读取，所以修改后必须重启蓝牙（脚本默认会做），耳机会短暂断开。
- 自动切换依赖系统“游戏助手”把应用识别为游戏；常驻游戏态（`on`）不依赖它，但游戏助手、系统重启可能重置相关设置，需重新执行。
- `on` 会写入 `debug_gamemode_value` / `debug_gamemode_savegame`，可能触发游戏模式下的其他系统行为（性能策略、通知等）。
- ROM Update 重新下发云控配置（`sys_bt_iot_config_list`）或系统 OTA 后，自定义文件可能被覆盖，需要重新添加。
- 撤销全部改动：`./x4lc3.sh clear`，并执行 `./x4lc3.sh off`。

## 目录

| 文件 | 说明 |
|---|---|
| `BLUETOOTH.md` | 机制分析、方案对比、实测结果 |
| `x4lc3.sh` | 白名单与游戏态管理脚本 |

## 免责声明

本项目与 OPPO / OnePlus 无关，仅供学习与研究。分析基于对本人设备上系统组件的反编译，仓库不包含任何固件或反编译源码。

