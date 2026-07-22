#!/bin/sh
set -eu
set -f

CUSTOM_PROFILE_DIR="${CLASH_PATCH_PROFILE_DIR:-}"
INSTALL_DIR="$HOME/Library/Application Support/ClashPatch"
BACKUP_DIR="$INSTALL_DIR/backups"
USAGE_STATE_PATH="${CLASH_PATCH_USAGE_STATE_PATH:-$INSTALL_DIR/usage-profile.plist}"
CURRENT_LABEL="com.clashpatch.profiles"
CURRENT_PLIST="$HOME/Library/LaunchAgents/$CURRENT_LABEL.plist"
CURRENT_PATCHER="$INSTALL_DIR/patch_profiles.rb"
LEGACY_LABEL="com.wallny.clash-profile-patcher"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
LEGACY_PATCHER="$HOME/Library/Application Support/ClashProfilePatcher/patch_profiles.rb"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PATCHER_SOURCE="$SCRIPT_DIR/macos/patch_profiles.rb"
POLICY_SOURCE="$SCRIPT_DIR/../references/policy.json"
USAGE_PROFILE=""
PROFILE_SOURCE=""
SHOW_PROFILE=0
SAFE_UPDATE=0

say() {
  /usr/bin/printf '%s\n' "[Clash 补丁] $1"
}

usage() {
  /usr/bin/printf '%s\n' "用法：install_macos.sh [--profile 1|2|3] [--show-profile] [--safe-update]"
}

read_saved_profile() {
  [ -f "$USAGE_STATE_PATH" ] && [ ! -L "$USAGE_STATE_PATH" ] || return 1
  saved_version=$(/usr/bin/plutil -extract Version raw "$USAGE_STATE_PATH" 2>/dev/null || true)
  saved_profile=$(/usr/bin/plutil -extract Profile raw "$USAGE_STATE_PATH" 2>/dev/null || true)
  [ "$saved_version" = "1" ] || return 1
  case "$saved_profile" in
    1|2|3) /usr/bin/printf '%s\n' "$saved_profile" ;;
    *) return 1 ;;
  esac
}

save_profile() {
  state_dir=$(/usr/bin/dirname "$USAGE_STATE_PATH")
  if [ -L "$state_dir" ] || { [ -e "$USAGE_STATE_PATH" ] && { [ ! -f "$USAGE_STATE_PATH" ] || [ -L "$USAGE_STATE_PATH" ]; }; }; then
    say "档位保存位置不安全，未写入任何设置。"
    exit 7
  fi
  /bin/mkdir -p "$state_dir"
  /bin/chmod 700 "$state_dir"
  temporary=$(/usr/bin/mktemp "$state_dir/.usage-profile.XXXXXX")
  trap '/bin/rm -f "$temporary"' EXIT HUP INT TERM
  /usr/bin/plutil -create xml1 "$temporary"
  /usr/bin/plutil -insert Version -integer 1 "$temporary"
  /usr/bin/plutil -insert Profile -integer "$USAGE_PROFILE" "$temporary"
  /bin/chmod 600 "$temporary"
  /bin/mv -f "$temporary" "$USAGE_STATE_PATH"
  trap - EXIT HUP INT TERM
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      USAGE_PROFILE=$2
      PROFILE_SOURCE="argument"
      shift 2
      ;;
    --show-profile)
      SHOW_PROFILE=1
      shift
      ;;
    --safe-update)
      SAFE_UPDATE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

if [ "$SHOW_PROFILE" -eq 1 ]; then
  read_saved_profile || /usr/bin/printf '%s\n' "unset"
  exit 0
fi

if [ -z "$USAGE_PROFILE" ] && [ -n "${CLASH_PATCH_USAGE_PROFILE:-}" ]; then
  USAGE_PROFILE=$CLASH_PATCH_USAGE_PROFILE
  PROFILE_SOURCE="environment"
fi
if [ -z "$USAGE_PROFILE" ]; then
  USAGE_PROFILE=$(read_saved_profile || true)
  PROFILE_SOURCE="saved"
fi
case "$USAGE_PROFILE" in
  1|2|3) ;;
  "")
    say "还没有选择用途档位。请先在 skill 中选择：1 普通浏览、2 海外 AI、3 Claude/Claude Code。"
    exit 10
    ;;
  *)
    say "用途档位无效，只能是 1、2 或 3。"
    exit 64
    ;;
esac

PREVIOUS_PROFILE=$(read_saved_profile || true)

legacy_agent_owned() {
  candidate=$1
  expected_label=$2
  expected_patcher=$3
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  agent_label=$(/usr/bin/plutil -extract Label raw "$candidate" 2>/dev/null || true)
  agent_arg0=$(/usr/bin/plutil -extract ProgramArguments.0 raw "$candidate" 2>/dev/null || true)
  agent_arg1=$(/usr/bin/plutil -extract ProgramArguments.1 raw "$candidate" 2>/dev/null || true)
  [ "$agent_label" = "$expected_label" ] && [ "$agent_arg0" = "/usr/bin/ruby" ] && [ "$agent_arg1" = "$expected_patcher" ]
}

remove_legacy_agent() {
  candidate=$1
  expected_label=$2
  expected_patcher=$3
  [ -f "$candidate" ] || return 0
  if legacy_agent_owned "$candidate" "$expected_label" "$expected_patcher"; then
    /bin/launchctl bootout "gui/$USER_ID/$expected_label" >/dev/null 2>&1 || true
    /bin/rm -f "$candidate"
    if [ -f "$expected_patcher" ] && [ ! -L "$expected_patcher" ]; then
      /bin/rm -f "$expected_patcher"
      /bin/rmdir "$(/usr/bin/dirname "$expected_patcher")" >/dev/null 2>&1 || true
    fi
    say "已移除旧版自动目录监听：${expected_label}。"
  else
    say "发现同名但无法确认属于 Clash 补丁的 LaunchAgent，已保留：${expected_label}。"
  fi
}

if [ "$(uname -s)" != "Darwin" ]; then
  say "当前系统不是 macOS。Windows 请使用 Clash Verge Rev 的 Windows 安装程序。"
  exit 2
fi

USER_ID=$(/usr/bin/id -u)
if [ "$USER_ID" -eq 0 ]; then
  say "请不要使用 sudo 或 root；请用当前登录用户直接运行。"
  exit 2
fi

if [ ! -x /usr/bin/ruby ]; then
  say "这台 Mac 没有系统 Ruby，无法运行补丁。"
  exit 3
fi

if [ ! -d "/Applications/ClashX Meta.app" ] && [ ! -d "$HOME/Applications/ClashX Meta.app" ]; then
  say "没有找到受支持的 ClashX Meta。"
  exit 4
fi

if [ "$PROFILE_SOURCE" != "saved" ] && [ "$USAGE_PROFILE" -ne 3 ]; then
  save_profile
  say "已保存用途档位 ${USAGE_PROFILE}。"
fi

if [ -n "$CUSTOM_PROFILE_DIR" ] && [ ! -d "$CUSTOM_PROFILE_DIR" ]; then
  say "没有找到指定的 ClashX Meta 配置目录。"
  exit 5
fi

if [ ! -f "$PATCHER_SOURCE" ] || [ ! -f "$POLICY_SOURCE" ]; then
  say "安装包不完整：缺少补丁程序或策略文件。"
  exit 6
fi

# 旧版目录监听会被补丁自己的写入再次触发。只移除能核对所有权的旧服务。
remove_legacy_agent "$CURRENT_PLIST" "$CURRENT_LABEL" "$CURRENT_PATCHER"
remove_legacy_agent "$LEGACY_PLIST" "$LEGACY_LABEL" "$LEGACY_PATCHER"

if [ "$SAFE_UPDATE" -eq 0 ] && [ "$USAGE_PROFILE" -ne 3 ]; then
  if [ "$PREVIOUS_PROFILE" = "3" ] && [ "$PROFILE_SOURCE" != "saved" ]; then
    say "检测到从档位 3 改为轻量档位。安装程序不会覆盖后来产生的用户改动；请由本 skill 先运行安全卸载流程，并说明无法自动恢复的旧订阅增强。"
  fi
  if [ "$USAGE_PROFILE" -eq 1 ]; then
    say "档位 1 只需要确认 ClashX Meta 的“设置为系统代理”已开启；未修改 TUN 或订阅。"
  else
    say "档位 2 只需要开启 TUN 并关闭 ClashX Meta 自己的系统代理开关；未修改订阅、DNS、WebRTC 或 AI 分组。"
  fi
  say "请由本 skill 使用 Computer Use 完成客户端开关和对应网站复测。"
  exit 0
fi

core_status=$(/usr/bin/ruby "$PATCHER_SOURCE" --print-core-status 2>/dev/null || true)
if [ "$core_status" != "supported" ]; then
  case "$core_status" in
    too_old) say "Mihomo 内核版本过旧，需要 1.19.27 或更高版本。" ;;
    timeout) say "Mihomo 内核检查超过 30 秒，未修改任何订阅。" ;;
    *) say "没有找到可用的 Mihomo 内核，或无法确认版本。" ;;
  esac
  exit 8
fi

if [ "$PROFILE_SOURCE" != "saved" ] && [ "$USAGE_PROFILE" -eq 3 ]; then
  save_profile
  say "已保存用途档位 ${USAGE_PROFILE}。"
fi

if [ "$USAGE_PROFILE" -eq 3 ]; then
  if ! auto_update_result=$(/usr/bin/ruby "$PATCHER_SOURCE" --backup-dir "$BACKUP_DIR" --disable-subscription-auto-update 2>&1); then
    say "无法自动关闭 ClashX Meta 的订阅自动更新；本次未修改任何订阅。"
    exit 9
  fi
  case "$auto_update_result" in
    disabled) say "已自动关闭订阅更新，并保存修改前状态。" ;;
    already_disabled) say "订阅自动更新已经关闭。" ;;
    *) say "订阅自动更新回读结果异常；本次未修改任何订阅。"; exit 9 ;;
  esac
fi

/bin/mkdir -p "$BACKUP_DIR"
/bin/chmod 700 "$INSTALL_DIR" "$BACKUP_DIR"

if [ -n "$CUSTOM_PROFILE_DIR" ]; then
  /usr/bin/ruby "$PATCHER_SOURCE" --profile-dir "$CUSTOM_PROFILE_DIR" --backup-dir "$BACKUP_DIR" --snapshot-initial
else
  /usr/bin/ruby "$PATCHER_SOURCE" --backup-dir "$BACKUP_DIR" --snapshot-initial
fi

if [ "$SAFE_UPDATE" -eq 1 ]; then
  if [ -n "$CUSTOM_PROFILE_DIR" ]; then
    /usr/bin/ruby "$PATCHER_SOURCE" \
      --profile-dir "$CUSTOM_PROFILE_DIR" \
      --policy "$POLICY_SOURCE" \
      --backup-dir "$BACKUP_DIR" \
      --safe-update-all \
      --usage-profile "$USAGE_PROFILE"
  else
    /usr/bin/ruby "$PATCHER_SOURCE" \
      --policy "$POLICY_SOURCE" \
      --backup-dir "$BACKUP_DIR" \
      --safe-update-all \
      --usage-profile "$USAGE_PROFILE"
  fi
  say "安全更新已完成：当前存储位置中的全部远程订阅已一起更新。"
  exit 0
fi

if [ -n "$CUSTOM_PROFILE_DIR" ]; then
  /usr/bin/ruby "$PATCHER_SOURCE" \
    --profile-dir "$CUSTOM_PROFILE_DIR" \
    --policy "$POLICY_SOURCE" \
    --backup-dir "$BACKUP_DIR"
else
  /usr/bin/ruby "$PATCHER_SOURCE" \
    --policy "$POLICY_SOURCE" \
    --backup-dir "$BACKUP_DIR"
fi

say "本次为单次运行，只处理 ClashX Meta 当前存储位置中的订阅。"
say "当前订阅需要修改时，会通过本地控制器自动刷新并检查；失败时补丁程序会恢复原配置。"
say "脚本没有退出、停止或重启 ClashX Meta，也没有切换订阅、代理组或节点。"
