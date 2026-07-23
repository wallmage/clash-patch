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
RESULT_CONTRACT_SOURCE="$SCRIPT_DIR/macos/result_contract.rb"
POLICY_SOURCE="$SCRIPT_DIR/../references/policy.json"
USAGE_PROFILE=""
PROFILE_SOURCE=""
SHOW_PROFILE=0
SAFE_UPDATE=0
JSON_OUTPUT=0
OPERATION="install"

for argument do
  [ "$argument" = "--json" ] && JSON_OUTPUT=1
done

finish() {
  finish_exit=$1
  finish_status=$2
  finish_code=$3
  finish_summary=$4
  finish_operation=${5:-$OPERATION}
  finish_profile=${6:-$USAGE_PROFILE}
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    if [ -x /usr/bin/ruby ] && [ -f "$RESULT_CONTRACT_SOURCE" ]; then
      if [ -n "$finish_profile" ]; then
        /usr/bin/ruby "$RESULT_CONTRACT_SOURCE" \
          --command install --operation "$finish_operation" --ok "$([ "$finish_exit" -eq 0 ] && /usr/bin/printf true || /usr/bin/printf false)" \
          --status "$finish_status" --code "$finish_code" --exit-code "$finish_exit" --summary "$finish_summary" \
          --profile "$finish_profile"
      else
        /usr/bin/ruby "$RESULT_CONTRACT_SOURCE" \
          --command install --operation "$finish_operation" --ok "$([ "$finish_exit" -eq 0 ] && /usr/bin/printf true || /usr/bin/printf false)" \
          --status "$finish_status" --code "$finish_code" --exit-code "$finish_exit" --summary "$finish_summary"
      fi
    else
      /usr/bin/printf '%s\n' "{\"schema\":\"clash-patch.result\",\"version\":1,\"command\":\"install\",\"platform\":\"macos\",\"client\":\"clashx-meta\",\"operation\":\"$finish_operation\",\"ok\":false,\"status\":\"$finish_status\",\"code\":\"$finish_code\",\"exit_code\":$finish_exit,\"summary_zh\":\"$finish_summary\",\"profile\":null,\"changes\":[],\"checks\":[],\"items\":[],\"messages\":[],\"warnings\":[]}"
    fi
  fi
  exit "$finish_exit"
}

say() {
  [ "$JSON_OUTPUT" -eq 0 ] || return 0
  /usr/bin/printf '%s\n' "[Clash 补丁] $1"
}

usage() {
  [ "$JSON_OUTPUT" -eq 0 ] || return 0
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
    finish 7 failed unsafe_profile_state "档位保存位置不安全，未写入任何设置。" save_profile
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
      [ "$#" -ge 2 ] || { usage; finish 64 invalid_request missing_profile_value "--profile 缺少档位值。" parse_arguments; }
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
      OPERATION="safe_update"
      shift
      ;;
    --json)
      JSON_OUTPUT=1
      shift
      ;;
    -h|--help)
      usage
      finish 0 ok help "已显示帮助。" help
      ;;
    *)
      usage
      finish 64 invalid_request invalid_arguments "参数错误。" parse_arguments
      ;;
  esac
done

operation_count=0
[ "$SHOW_PROFILE" -eq 1 ] && operation_count=$((operation_count + 1))
[ "$SAFE_UPDATE" -eq 1 ] && operation_count=$((operation_count + 1))
if [ "$operation_count" -gt 1 ]; then
  finish 64 invalid_request conflicting_operations "一次只能执行一个操作。" parse_arguments
fi
if [ "$SHOW_PROFILE" -eq 1 ] && [ -n "$USAGE_PROFILE" ]; then
  finish 64 invalid_request conflicting_operations "读取档位时不能同时保存新档位。" parse_arguments
fi

if [ "$SHOW_PROFILE" -eq 1 ]; then
  OPERATION="show_profile"
  saved_profile=$(read_saved_profile || true)
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    if [ -n "$saved_profile" ]; then
      finish 0 ok profile_set "已读取用途档位。" show_profile "$saved_profile"
    else
      finish 0 no_change profile_unset "尚未保存用途档位。" show_profile ""
    fi
  fi
  [ -n "$saved_profile" ] && /usr/bin/printf '%s\n' "$saved_profile" || /usr/bin/printf '%s\n' "unset"
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
    finish 10 invalid_request profile_required "还没有选择用途档位。" select_profile
    ;;
  *)
    say "用途档位无效，只能是 1、2 或 3。"
    finish 64 invalid_request invalid_profile "用途档位无效，只能是 1、2 或 3。" select_profile
    ;;
esac

PREVIOUS_PROFILE=$(read_saved_profile || true)
if [ "$PREVIOUS_PROFILE" = "3" ] && [ "$USAGE_PROFILE" != "3" ] && [ "$PROFILE_SOURCE" != "saved" ]; then
  say "从档位 3 改为轻量档位前，必须先运行安全卸载。"
  finish 1 failed safe_uninstall_required "从档位 3 降档前必须先运行安全卸载。" install
fi

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
  finish 2 unsupported unsupported_platform "当前系统不是 macOS。" install
fi

USER_ID=$(/usr/bin/id -u)
if [ "$USER_ID" -eq 0 ]; then
  say "请不要使用 sudo 或 root；请用当前登录用户直接运行。"
  finish 2 invalid_request root_not_allowed "请用当前登录用户直接运行。" install
fi

if [ ! -x /usr/bin/ruby ]; then
  say "这台 Mac 没有系统 Ruby，无法运行补丁。"
  finish 3 unsupported ruby_missing "这台 Mac 没有系统 Ruby，无法运行补丁。" install
fi

if [ ! -d "/Applications/ClashX Meta.app" ] && [ ! -d "$HOME/Applications/ClashX Meta.app" ]; then
  say "没有找到受支持的 ClashX Meta。"
  finish 4 unsupported client_missing "没有找到受支持的 ClashX Meta。" install
fi

if [ -n "$CUSTOM_PROFILE_DIR" ] && [ ! -d "$CUSTOM_PROFILE_DIR" ]; then
  say "没有找到指定的 ClashX Meta 配置目录。"
  finish 5 failed profile_directory_missing "没有找到指定的 ClashX Meta 配置目录。" install
fi

if [ ! -f "$PATCHER_SOURCE" ] || [ ! -f "$POLICY_SOURCE" ] || [ ! -f "$RESULT_CONTRACT_SOURCE" ]; then
  say "安装包不完整：缺少补丁程序或策略文件。"
  finish 6 failed incomplete_package "安装包不完整。" install
fi

# 旧版目录监听会被补丁自己的写入再次触发。只移除能核对所有权的旧服务。
remove_legacy_agent "$CURRENT_PLIST" "$CURRENT_LABEL" "$CURRENT_PATCHER"
remove_legacy_agent "$LEGACY_PLIST" "$LEGACY_LABEL" "$LEGACY_PATCHER"

core_status=$(/usr/bin/ruby "$PATCHER_SOURCE" --print-core-status 2>/dev/null || true)
if [ "$core_status" != "supported" ]; then
  case "$core_status" in
    too_old) say "Mihomo 内核版本过旧，需要 1.19.27 或更高版本。" ;;
    timeout) say "Mihomo 内核检查超过 30 秒，未修改任何订阅。" ;;
    *) say "没有找到可用的 Mihomo 内核，或无法确认版本。" ;;
  esac
  finish 8 unsupported mihomo_unavailable "Mihomo 内核不可用或版本不受支持。" core_status
fi

if [ "$USAGE_PROFILE" -eq 3 ]; then
  if ! auto_update_result=$(/usr/bin/ruby "$PATCHER_SOURCE" --backup-dir "$BACKUP_DIR" --disable-subscription-auto-update 2>&1); then
    say "无法自动关闭 ClashX Meta 的订阅自动更新；本次未修改任何订阅。"
    finish 9 failed auto_update_failed "无法自动关闭订阅自动更新；未修改任何订阅。" install
  fi
  case "$auto_update_result" in
    disabled) say "已自动关闭订阅更新，并保存修改前状态。" ;;
    already_disabled) say "订阅自动更新已经关闭。" ;;
    *) say "订阅自动更新回读结果异常；本次未修改任何订阅。"; finish 9 failed auto_update_verify_failed "订阅自动更新回读结果异常；未修改任何订阅。" install ;;
  esac
fi

/bin/mkdir -p "$BACKUP_DIR"
/bin/chmod 700 "$INSTALL_DIR" "$BACKUP_DIR"

if [ -n "$CUSTOM_PROFILE_DIR" ]; then
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    /usr/bin/ruby "$PATCHER_SOURCE" --profile-dir "$CUSTOM_PROFILE_DIR" --backup-dir "$BACKUP_DIR" --snapshot-initial --json >/dev/null ||
      finish 1 failed snapshot_failed "无法创建初始快照。" snapshot_initial
  else
    /usr/bin/ruby "$PATCHER_SOURCE" --profile-dir "$CUSTOM_PROFILE_DIR" --backup-dir "$BACKUP_DIR" --snapshot-initial ||
      { say "无法创建初始快照。"; finish 1 failed snapshot_failed "无法创建初始快照。" snapshot_initial; }
  fi
else
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    /usr/bin/ruby "$PATCHER_SOURCE" --backup-dir "$BACKUP_DIR" --snapshot-initial --json >/dev/null ||
      finish 1 failed snapshot_failed "无法创建初始快照。" snapshot_initial
  else
    /usr/bin/ruby "$PATCHER_SOURCE" --backup-dir "$BACKUP_DIR" --snapshot-initial ||
      { say "无法创建初始快照。"; finish 1 failed snapshot_failed "无法创建初始快照。" snapshot_initial; }
  fi
fi

if [ "$SAFE_UPDATE" -eq 1 ]; then
  if [ -n "$CUSTOM_PROFILE_DIR" ]; then
    if [ "$JSON_OUTPUT" -eq 1 ]; then
      /usr/bin/ruby "$PATCHER_SOURCE" \
        --profile-dir "$CUSTOM_PROFILE_DIR" \
        --policy "$POLICY_SOURCE" \
        --backup-dir "$BACKUP_DIR" \
        --safe-update-all \
        --usage-profile "$USAGE_PROFILE" --json >/dev/null ||
        finish 1 failed safe_update_failed "安全更新失败。" safe_update
    else
      /usr/bin/ruby "$PATCHER_SOURCE" \
        --profile-dir "$CUSTOM_PROFILE_DIR" \
        --policy "$POLICY_SOURCE" \
        --backup-dir "$BACKUP_DIR" \
        --safe-update-all \
        --usage-profile "$USAGE_PROFILE" ||
        { say "安全更新失败。"; finish 1 failed safe_update_failed "安全更新失败。" safe_update; }
    fi
  else
    if [ "$JSON_OUTPUT" -eq 1 ]; then
      /usr/bin/ruby "$PATCHER_SOURCE" \
        --policy "$POLICY_SOURCE" \
        --backup-dir "$BACKUP_DIR" \
        --safe-update-all \
        --usage-profile "$USAGE_PROFILE" --json >/dev/null ||
        finish 1 failed safe_update_failed "安全更新失败。" safe_update
    else
      /usr/bin/ruby "$PATCHER_SOURCE" \
        --policy "$POLICY_SOURCE" \
        --backup-dir "$BACKUP_DIR" \
        --safe-update-all \
        --usage-profile "$USAGE_PROFILE" ||
        { say "安全更新失败。"; finish 1 failed safe_update_failed "安全更新失败。" safe_update; }
    fi
  fi
  if [ "$PROFILE_SOURCE" != "saved" ]; then
    save_profile
    say "已保存用途档位 ${USAGE_PROFILE}。"
  fi
  say "安全更新已完成：当前存储位置中的全部远程订阅已一起更新。"
  finish 0 ok safe_update_completed "安全更新已完成。" safe_update
fi

if [ -n "$CUSTOM_PROFILE_DIR" ]; then
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    /usr/bin/ruby "$PATCHER_SOURCE" \
      --profile-dir "$CUSTOM_PROFILE_DIR" \
      --policy "$POLICY_SOURCE" \
      --backup-dir "$BACKUP_DIR" --usage-profile "$USAGE_PROFILE" --json >/dev/null ||
      finish 1 failed patch_failed "配置处理失败。" patch_profiles
  else
    /usr/bin/ruby "$PATCHER_SOURCE" \
      --profile-dir "$CUSTOM_PROFILE_DIR" \
      --policy "$POLICY_SOURCE" \
      --backup-dir "$BACKUP_DIR" --usage-profile "$USAGE_PROFILE" ||
      { say "配置处理失败。"; finish 1 failed patch_failed "配置处理失败。" patch_profiles; }
  fi
else
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    /usr/bin/ruby "$PATCHER_SOURCE" \
      --policy "$POLICY_SOURCE" \
      --backup-dir "$BACKUP_DIR" --usage-profile "$USAGE_PROFILE" --json >/dev/null ||
      finish 1 failed patch_failed "配置处理失败。" patch_profiles
  else
    /usr/bin/ruby "$PATCHER_SOURCE" \
      --policy "$POLICY_SOURCE" \
      --backup-dir "$BACKUP_DIR" --usage-profile "$USAGE_PROFILE" ||
      { say "配置处理失败。"; finish 1 failed patch_failed "配置处理失败。" patch_profiles; }
  fi
fi

if [ "$PROFILE_SOURCE" != "saved" ]; then
  save_profile
  say "已保存用途档位 ${USAGE_PROFILE}。"
fi
say "本次为单次运行；当前存储位置中的全部订阅都已使用同一套国内域名直连规则。"
say "当前订阅需要修改时，会通过本地控制器自动刷新并检查；失败时补丁程序会恢复原配置。"
say "脚本没有退出、停止或重启 ClashX Meta，也没有切换订阅、代理组或节点。"
finish 0 ok install_completed "Clash Patch 处理完成。" install
