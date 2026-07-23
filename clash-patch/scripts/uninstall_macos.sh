#!/bin/sh
set -eu
set -f

INSTALL_DIR="$HOME/Library/Application Support/ClashPatch"
BACKUP_DIR="$INSTALL_DIR/backups"
STATE_PATH="$INSTALL_DIR/install-state.plist"
USAGE_STATE_PATH="${CLASH_PATCH_USAGE_STATE_PATH:-$INSTALL_DIR/usage-profile.plist}"
CURRENT_LABEL="com.clashpatch.profiles"
CURRENT_PLIST="$HOME/Library/LaunchAgents/$CURRENT_LABEL.plist"
CURRENT_PATCHER="$INSTALL_DIR/patch_profiles.rb"
LEGACY_LABEL="com.wallny.clash-profile-patcher"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
LEGACY_PATCHER="$HOME/Library/Application Support/ClashProfilePatcher/patch_profiles.rb"
DEFAULTS_DOMAIN="com.metacubex.ClashX.meta"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RESULT_CONTRACT_SOURCE="$SCRIPT_DIR/macos/result_contract.rb"
PATCHER_SOURCE="$SCRIPT_DIR/macos/patch_profiles.rb"
AUTO_UPDATE_OWNERSHIP_PATH="$BACKUP_DIR/clashx-meta-kAutoUpdateEnable.state.json"
JSON_OUTPUT=0
UNINSTALL_STAGING="$INSTALL_DIR/.clash-patch-uninstall-staging"

unexpected_uninstall_exit() {
  unexpected_status=$1
  trap - EXIT HUP INT TERM
  [ "$unexpected_status" -ne 0 ] || return 0
  set +e
  if [ -d "$UNINSTALL_STAGING" ] && [ ! -f "$UNINSTALL_STAGING/COMMITTED" ]; then
    restore_uncommitted_uninstall
  fi
  exit "$unexpected_status"
}

trap 'unexpected_uninstall_exit $?' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for argument do
  [ "$argument" = "--json" ] && JSON_OUTPUT=1
done

finish() {
  finish_exit=$1
  finish_status=$2
  finish_code=$3
  finish_summary=$4
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    if [ -x /usr/bin/ruby ] && [ -f "$RESULT_CONTRACT_SOURCE" ]; then
      /usr/bin/ruby "$RESULT_CONTRACT_SOURCE" \
        --command uninstall --operation uninstall --ok "$([ "$finish_exit" -eq 0 ] && /usr/bin/printf true || /usr/bin/printf false)" \
        --status "$finish_status" --code "$finish_code" --exit-code "$finish_exit" --summary "$finish_summary"
    else
      /usr/bin/printf '%s\n' "{\"schema\":\"clash-patch.result\",\"version\":1,\"command\":\"uninstall\",\"platform\":\"macos\",\"client\":\"clashx-meta\",\"operation\":\"uninstall\",\"ok\":false,\"status\":\"$finish_status\",\"code\":\"$finish_code\",\"exit_code\":$finish_exit,\"summary_zh\":\"$finish_summary\",\"profile\":null,\"changes\":[],\"checks\":[],\"items\":[],\"messages\":[],\"warnings\":[]}"
    fi
  fi
  trap - EXIT HUP INT TERM
  exit "$finish_exit"
}

say() {
  [ "$JSON_OUTPUT" -eq 0 ] || return 0
  /usr/bin/printf '%s\n' "[Clash 补丁] $1"
}

usage() {
  [ "$JSON_OUTPUT" -eq 0 ] || return 0
  /usr/bin/printf '%s\n' "用法：uninstall_macos.sh [--json]"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)
      shift
      ;;
    -h|--help)
      usage
      finish 0 ok help "已显示帮助。"
      ;;
    *)
      usage
      finish 64 invalid_request invalid_arguments "参数错误。"
      ;;
  esac
done

launch_agent_owned() {
  candidate=$1
  expected_label=$2
  expected_patcher=$3
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  agent_label=$(/usr/bin/plutil -extract Label raw "$candidate" 2>/dev/null || true)
  agent_arg0=$(/usr/bin/plutil -extract ProgramArguments.0 raw "$candidate" 2>/dev/null || true)
  agent_arg1=$(/usr/bin/plutil -extract ProgramArguments.1 raw "$candidate" 2>/dev/null || true)
  [ "$agent_label" = "$expected_label" ] && [ "$agent_arg0" = "/usr/bin/ruby" ] && [ "$agent_arg1" = "$expected_patcher" ]
}

remove_owned_agent() {
  candidate=$1
  expected_label=$2
  expected_patcher=$3
  if [ -f "$candidate" ]; then
    if launch_agent_owned "$candidate" "$expected_label" "$expected_patcher"; then
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
  elif /bin/launchctl print "gui/$USER_ID/$expected_label" >/dev/null 2>&1; then
    say "发现同名 LaunchAgent，但缺少可核对的 plist；未停止该服务：${expected_label}。"
  fi
}

restore_uncommitted_uninstall() {
  [ -e "$UNINSTALL_STAGING" ] || return 0
  [ -d "$UNINSTALL_STAGING" ] && [ ! -L "$UNINSTALL_STAGING" ] ||
    finish 1 failed uninstall_state_unsafe "卸载恢复目录不安全；未继续删除。"
  if [ -f "$UNINSTALL_STAGING/COMMITTED" ]; then
    /bin/rm -rf "$UNINSTALL_STAGING"
    return 0
  fi
  restore_slot "$UNINSTALL_STAGING/patcher" "$INSTALL_DIR/patch_profiles.rb"
  restore_slot "$UNINSTALL_STAGING/policy" "$INSTALL_DIR/policy.json"
  restore_slot "$UNINSTALL_STAGING/state" "$STATE_PATH"
  restore_slot "$UNINSTALL_STAGING/usage" "$USAGE_STATE_PATH"
  restore_slot "$UNINSTALL_STAGING/log" "$INSTALL_DIR/patch.log"
  restore_slot "$UNINSTALL_STAGING/error-log" "$INSTALL_DIR/patch-error.log"
  /bin/rm -rf "$UNINSTALL_STAGING"
}

restore_slot() {
  slot=$1
  destination=$2
  [ -f "$slot" ] || return 0
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    /usr/bin/cmp -s "$slot" "$destination" ||
      finish 1 failed uninstall_restore_conflict "卸载中断后检测到新文件；未覆盖。"
    return 0
  fi
  /bin/mkdir -p "$(/usr/bin/dirname "$destination")"
  /bin/cp -p "$slot" "$destination"
}

stage_slot() {
  source=$1
  slot=$2
  [ -e "$source" ] || return 0
  [ -f "$source" ] && [ ! -L "$source" ] ||
    finish 1 failed uninstall_target_unsafe "卸载目标不是安全的普通文件；未删除。"
  /bin/cp -p "$source" "$UNINSTALL_STAGING/$slot"
}

delete_staged_install_files() {
  if [ -e "$UNINSTALL_STAGING" ] || [ -L "$UNINSTALL_STAGING" ]; then
    finish 1 failed uninstall_state_conflict "卸载恢复目录已存在；未继续删除。"
  fi
  /bin/mkdir -p "$UNINSTALL_STAGING"
  /bin/chmod 700 "$UNINSTALL_STAGING"
  stage_slot "$INSTALL_DIR/patch_profiles.rb" patcher
  stage_slot "$INSTALL_DIR/policy.json" policy
  stage_slot "$STATE_PATH" state
  stage_slot "$USAGE_STATE_PATH" usage
  stage_slot "$INSTALL_DIR/patch.log" log
  stage_slot "$INSTALL_DIR/patch-error.log" error-log
  /usr/bin/touch "$UNINSTALL_STAGING/READY"

  /bin/rm -f \
    "$INSTALL_DIR/patch_profiles.rb" \
    "$INSTALL_DIR/policy.json" \
    "$STATE_PATH" \
    "$USAGE_STATE_PATH" \
    "$INSTALL_DIR/patch.log" \
    "$INSTALL_DIR/patch-error.log"
  for removed in \
    "$INSTALL_DIR/patch_profiles.rb" \
    "$INSTALL_DIR/policy.json" \
    "$STATE_PATH" \
    "$USAGE_STATE_PATH" \
    "$INSTALL_DIR/patch.log" \
    "$INSTALL_DIR/patch-error.log"; do
    if [ -e "$removed" ] || [ -L "$removed" ]; then
      restore_uncommitted_uninstall
      finish 1 failed uninstall_delete_failed "安装文件未能整批删除，已恢复其余文件。"
    fi
  done
  /usr/bin/touch "$UNINSTALL_STAGING/COMMITTED"
  /bin/rm -rf "$UNINSTALL_STAGING"
}

if [ "$(uname -s)" != "Darwin" ]; then
  say "当前系统不是 macOS。"
  finish 2 unsupported unsupported_platform "当前系统不是 macOS。"
fi

USER_ID=$(/usr/bin/id -u)
if [ "$USER_ID" -eq 0 ]; then
  say "请不要使用 sudo 或 root 运行卸载程序；请用当前登录用户直接运行。"
  finish 2 invalid_request root_not_allowed "请用当前登录用户直接运行。"
fi

restore_uncommitted_uninstall

remove_owned_agent "$CURRENT_PLIST" "$CURRENT_LABEL" "$CURRENT_PATCHER"
remove_owned_agent "$LEGACY_PLIST" "$LEGACY_LABEL" "$LEGACY_PATCHER"

AUTO_UPDATE_RESTORED=0
if [ -e "$AUTO_UPDATE_OWNERSHIP_PATH" ] || [ -L "$AUTO_UPDATE_OWNERSHIP_PATH" ]; then
  if [ ! -f "$PATCHER_SOURCE" ]; then
    say "安装包不完整，无法安全恢复订阅自动更新；未删除用途档位。"
    finish 6 failed incomplete_package "安装包不完整，无法安全恢复订阅自动更新。"
  fi
  if ! auto_update_restore=$(/usr/bin/ruby "$PATCHER_SOURCE" \
    --backup-dir "$BACKUP_DIR" --restore-owned-subscription-auto-update 2>/dev/null); then
    say "无法恢复本工具关闭的订阅自动更新；未删除用途档位和所有权状态。"
    finish 1 failed auto_update_restore_failed "无法恢复本工具关闭的订阅自动更新；未删除用途档位。"
  fi
  case "$auto_update_restore" in
    restored|already_restored)
      if [ -e "$AUTO_UPDATE_OWNERSHIP_PATH" ] || [ -L "$AUTO_UPDATE_OWNERSHIP_PATH" ]; then
        say "订阅自动更新虽已处理，但所有权状态未能清除；未删除用途档位。"
        finish 1 partial auto_update_state_cleanup_failed "订阅自动更新已处理，但所有权状态未能清除。"
      fi
      AUTO_UPDATE_RESTORED=1
      ;;
    *)
      say "订阅自动更新恢复结果异常；未删除用途档位和所有权状态。"
      finish 1 failed auto_update_restore_failed "订阅自动更新恢复结果异常；未删除用途档位。"
      ;;
  esac
fi

delete_staged_install_files
/bin/rmdir "$INSTALL_DIR" >/dev/null 2>&1 || true

say "Clash Patch 安装文件已移除；当前版本没有后台监听任务。"
if [ -d "$BACKUP_DIR" ]; then
  say "原始订阅备份仍保留在本机；卸载程序没有删除或还原它们。"
fi
say "旧版安装前的 TUN 偏好无法证明仍是当前选择，因此保留当前值。订阅里的 DNS、WebRTC 和 AI 设置不会自动撤销。"
if [ "$AUTO_UPDATE_RESTORED" -eq 1 ]; then
  say "本工具关闭的订阅自动更新已经恢复并回读确认。"
fi
finish 0 ok uninstall_completed "Clash Patch 卸载处理完成；备份未删除。"
