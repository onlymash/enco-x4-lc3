#!/usr/bin/env bash
# x4lc3.sh — 管理一加 16 上 Enco X4 的双模 LC3 白名单与“常驻游戏态”
# 原理与验证见 BLUETOOTH.md（方案 B / C）。需要 root（su）。
set -euo pipefail

# 定位 adb：优先 $ADB，其次 PATH，最后尝试 Android SDK 目录
find_adb() {
  if [ -n "${ADB:-}" ]; then
    command -v "$ADB" 2>/dev/null && return 0
    echo "指定的 ADB 不可执行: $ADB" >&2; return 1
  fi
  command -v adb 2>/dev/null && return 0
  local d
  for d in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
    [ -n "$d" ] && [ -x "$d/platform-tools/adb" ] && { echo "$d/platform-tools/adb"; return 0; }
  done
  echo "未找到 adb：请安装 Android platform-tools 并加入 PATH，或设置 ADB=/path/to/adb" >&2
  return 1
}
ADB="$(find_adb)" || exit 1
CONF=/data/misc/bluedroid/bt_oplus_iot_list.conf
SECTION=dualmode_a2dp_lowlatency
KEY=add_list

usage() {
  cat <<EOF
用法: $0 <命令> [参数]

白名单（写入 $CONF，改动后需重启蓝牙才生效）:
  list                  显示自定义白名单与当前状态
  add <包名>...         添加应用（多个包名用空格分隔）并重启蓝牙
  del <包名>...         删除应用（多个包名用空格分隔）并重启蓝牙
  clear                 清空自定义白名单并重启蓝牙
  restart               仅重启蓝牙

常驻游戏态（让所有声音走 LC3，包名须在白名单且已安装）:
  on [包名]             开启；省略包名时使用白名单第一项
  off                   关闭，切回 LHDC/A2DP
  status                显示游戏态与当前活动设备

选项: 环境变量 NO_RESTART=1 可让 add/del/clear 不自动重启蓝牙。
      环境变量 ADB=/path/to/adb 指定 adb（默认从 PATH 查找）。
EOF
}

ash() { "$ADB" shell "$1"; }
rsh() { "$ADB" shell "su -c '$1'"; }

check_device() {
  "$ADB" get-state >/dev/null 2>&1 || { echo "未检测到 adb 设备" >&2; exit 1; }
}

has_root() { rsh 'id -u' 2>/dev/null | tr -d '\r' | grep -qx 0; }
check_root() { has_root || { echo "无法获取 root" >&2; exit 1; }; }

# 默认系统不存在 $CONF，若不存在则先创建并设置权限与 SELinux 上下文
ensure_conf() {
  rsh "if [ ! -f $CONF ]; then
    printf '[%s]\n' '$SECTION' > $CONF
    chown bluetooth:bluetooth $CONF
    chmod 660 $CONF
    restorecon $CONF >/dev/null 2>&1 || true
  fi"
}

# 读取当前 add_list，逐行输出
read_list() {
  rsh "if [ -f $CONF ]; then cat $CONF; fi" | tr -d '\r' | awk -F= -v s="[$SECTION]" -v k="$KEY" '
    /^\[/ { insec = ($0 == s); next }
    insec { gsub(/[ \t]/, "", $1); if ($1 == k) { gsub(/[ \t]/, "", $2); n = split($2, a, ","); for (i = 1; i <= n; i++) if (a[i] != "") print a[i] } }'
}

# 将标准输入的包名列表写回配置文件（若文件不存在则先创建）
write_list() {
  local joined
  joined="$(paste -sd, - || true)"
  ensure_conf
  if [ -z "$joined" ]; then
    rsh "cat > $CONF <<EOF
[$SECTION]
EOF
chown bluetooth:bluetooth $CONF
chmod 660 $CONF
restorecon $CONF >/dev/null 2>&1 || true"
    echo "白名单已清空"
    return
  fi
  rsh "cat > $CONF <<EOF
[$SECTION]
$KEY=$joined
EOF
chown bluetooth:bluetooth $CONF
chmod 660 $CONF
restorecon $CONF >/dev/null 2>&1 || true"
  echo "白名单: $joined"
}

restart_bt() {
  echo "重启蓝牙…"
  rsh 'svc bluetooth disable'; sleep 4
  rsh 'svc bluetooth enable'; sleep 10
  echo "完成（耳机重连后生效）"
}

maybe_restart() { [ "${NO_RESTART:-0}" = 1 ] && echo "已跳过重启，改动需重启蓝牙后生效" || restart_bt; }

installed() { ash "pm list packages $1" | tr -d '\r' | grep -qx "package:$1"; }

cmd_list() {
  check_root
  echo "自定义白名单 ($CONF):"
  read_list | sed 's/^/  /'
  echo "（系统内置白名单见 BLUETOOTH.md 第 3.2 节）"
  echo
  cmd_status
}

cmd_add() {
  [ $# -ge 1 ] || { usage; exit 1; }
  check_root
  ensure_conf
  local cur new p
  cur="$(read_list)"
  new="$cur"
  for p in "$@"; do
    installed "$p" || echo "警告: $p 未安装（白名单仍会写入）" >&2
    printf '%s\n' "$new" | grep -qxF "$p" || new="$(printf '%s\n%s' "$new" "$p" | sed '/^$/d')"
  done
  printf '%s\n' "$new" | sed '/^$/d' | write_list
  maybe_restart
}

cmd_del() {
  [ $# -ge 1 ] || { usage; exit 1; }
  check_root
  ensure_conf
  local cur p
  cur="$(read_list)"
  for p in "$@"; do cur="$(printf '%s\n' "$cur" | grep -vxF "$p" || true)"; done
  printf '%s\n' "$cur" | sed '/^$/d' | write_list
  maybe_restart
}

cmd_on() {
  local pkg="${1:-}"
  if [ -z "$pkg" ]; then
    check_root
    pkg="$(read_list | head -n1 || true)"
    [ -n "$pkg" ] || { echo "白名单为空，请先 add 或指定包名" >&2; exit 1; }
  elif has_root; then
    read_list | grep -qxF "$pkg" || echo "警告: $pkg 不在自定义白名单，若不在系统内置名单中将不会生效" >&2
  fi
  installed "$pkg" || echo "警告: $pkg 未安装，需至少安装一个白名单应用才会启用双连接" >&2
  ash "settings put global debug_gamemode_savegame $pkg"
  # 开启“用户偏好低延迟”的机型需要 <包名>:1，否则 isUserPreferLLMode() 为假
  if [ "$(ash 'getprop ro.oplus.audio.support.low_latency_game' | tr -d '\r')" = true ]; then
    ash "settings put global oplus_games_low_latency_state $pkg:1"
  fi
  ash 'settings put global debug_gamemode_value 1'
  echo "已开启常驻游戏态: $pkg"
}

cmd_off() {
  ash 'settings put global debug_gamemode_value 0'
  echo "已关闭常驻游戏态"
}

cmd_status() {
  echo "游戏态: value=$(ash 'settings get global debug_gamemode_value' | tr -d '\r')," \
       "package=$(ash 'settings get global debug_gamemode_savegame' | tr -d '\r')," \
       "user_prefer=$(ash 'settings get global oplus_games_low_latency_state' | tr -d '\r')"
  echo "共存开关 persist.sys.bt.leacoexist=$(ash 'getprop persist.sys.bt.leacoexist' | tr -d '\r')"
  echo "最近的活动设备切换:"
  ash "dumpsys bluetooth_manager" | tr -d '\r' | grep -a "Active Device Changed" | tail -n 4 | sed 's/^ */  /' || true
}

[ $# -ge 1 ] || { usage; exit 1; }
c="$1"; shift
case "$c" in
  -h|--help|help) usage; exit 0 ;;
esac
check_device
case "$c" in
  list) cmd_list ;;
  add) cmd_add "$@" ;;
  del|rm|remove) cmd_del "$@" ;;
  clear) check_root; : | write_list; maybe_restart ;;
  restart) check_root; restart_bt ;;
  on) cmd_on "$@" ;;
  off) cmd_off ;;
  status) cmd_status ;;
  *) usage; exit 1 ;;
esac
