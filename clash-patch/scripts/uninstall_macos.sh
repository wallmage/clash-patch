#!/bin/sh
set -eu
set -f

INSTALL_DIR="$HOME/Library/Application Support/ClashPatch"
BACKUP_DIR="$INSTALL_DIR/backups"
STATE_PATH="$INSTALL_DIR/install-state.plist"
CURRENT_LABEL="com.clashpatch.profiles"
CURRENT_PLIST="$HOME/Library/LaunchAgents/$CURRENT_LABEL.plist"
CURRENT_PATCHER="$INSTALL_DIR/patch_profiles.rb"
LEGACY_LABEL="com.wallny.clash-profile-patcher"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
LEGACY_PATCHER="$HOME/Library/Application Support/ClashProfilePatcher/patch_profiles.rb"
DEFAULTS_DOMAIN="com.metacubex.ClashX.meta"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RESULT_CONTRACT_SOURCE="$SCRIPT_DIR/macos/result_contract.rb"
JSON_OUTPUT=0

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
  exit "$finish_exit"
}

say() {
  [ "$JSON_OUTPUT" -eq 0 ] || return 0
  /usr/bin/printf '%s\n' "[Clash 补丁] $1"
}

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

if [ "$(uname -s)" != "Darwin" ]; then
  say "当前系统不是 macOS。"
  finish 2 unsupported unsupported_platform "当前系统不是 macOS。"
fi

USER_ID=$(/usr/bin/id -u)
if [ "$USER_ID" -eq 0 ]; then
  say "请不要使用 sudo 或 root 运行卸载程序；请用当前登录用户直接运行。"
  finish 2 invalid_request root_not_allowed "请用当前登录用户直接运行。"
fi

remove_owned_agent "$CURRENT_PLIST" "$CURRENT_LABEL" "$CURRENT_PATCHER"
remove_owned_agent "$LEGACY_PLIST" "$LEGACY_LABEL" "$LEGACY_PATCHER"

# 只有状态明确记录了安装前值时才恢复。无状态旧版的更早值无法推断。
TUN_RESTORED=0
if [ -f "$STATE_PATH" ]; then
  restore_known=$(/usr/bin/plutil -extract RestoreTunKnown raw "$STATE_PATH" 2>/dev/null || true)
  if [ "$restore_known" = "true" ] || [ "$restore_known" = "1" ]; then
    restore_present=$(/usr/bin/plutil -extract RestoreTunPresent raw "$STATE_PATH" 2>/dev/null || true)
    if [ "$restore_present" = "true" ] || [ "$restore_present" = "1" ]; then
      restore_value=$(/usr/bin/plutil -extract RestoreTunValue raw "$STATE_PATH" 2>/dev/null || true)
      case "$restore_value" in
        true|1)
          if ! /usr/bin/defaults write "$DEFAULTS_DOMAIN" restoreTunProxy -bool true >/dev/null 2>&1; then
            say "无法恢复安装前的 TUN 启动偏好；未删除安装状态。"
            finish 1 failed restore_tun_preference_failed "无法恢复安装前的 TUN 启动偏好；未删除安装状态。"
          fi
          ;;
        *)
          if ! /usr/bin/defaults write "$DEFAULTS_DOMAIN" restoreTunProxy -bool false >/dev/null 2>&1; then
            say "无法恢复安装前的 TUN 启动偏好；未删除安装状态。"
            finish 1 failed restore_tun_preference_failed "无法恢复安装前的 TUN 启动偏好；未删除安装状态。"
          fi
          ;;
      esac
    else
      /usr/bin/defaults delete "$DEFAULTS_DOMAIN" restoreTunProxy >/dev/null 2>&1 || true
    fi
    TUN_RESTORED=1
  fi
fi

/bin/rm -f \
  "$INSTALL_DIR/patch_profiles.rb" \
  "$INSTALL_DIR/policy.json" \
  "$STATE_PATH" \
  "$INSTALL_DIR/patch.log" \
  "$INSTALL_DIR/patch-error.log"
/bin/rmdir "$INSTALL_DIR" >/dev/null 2>&1 || true

say "Clash Patch 安装文件已移除；当前版本没有后台监听任务。"
if [ -d "$BACKUP_DIR" ]; then
  say "原始订阅备份仍保留在本机；卸载程序没有删除或还原它们。"
fi
if [ "$TUN_RESTORED" -eq 1 ]; then
  say "安装程序写入的 TUN 启动偏好已恢复。订阅里的 DNS、WebRTC 和 AI 设置不会自动撤销。"
else
  say "旧版安装前的 TUN 偏好无法确认，因此保留当前值。订阅里的 DNS、WebRTC 和 AI 设置不会自动撤销。"
fi
finish 0 ok uninstall_completed "Clash Patch 卸载处理完成；备份未删除。"
