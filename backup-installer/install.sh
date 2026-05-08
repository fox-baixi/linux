#!/usr/bin/env bash
set -euo pipefail

DEFAULT_INSTALL_DIR="/root/back"
DEFAULT_REMOTE_PATH="OneDrive/Backup/vps_docker"
LOG_FILE_DEFAULT="/var/log/backup.log"

INSTALL_DIR=""
BACKUP_ENV_PATH=""
BACKUP_SCRIPT_PATH=""
LOG_FILE="$LOG_FILE_DEFAULT"
CRON_EXPR=""

pause() {
  printf "\n"
  read -r -p "按回车继续..." _
}

set_paths() {
  INSTALL_DIR="$1"
  BACKUP_ENV_PATH="${INSTALL_DIR}/backup.env"
  BACKUP_SCRIPT_PATH="${INSTALL_DIR}/backup.sh"
}

prompt_default_into() {
  local __var_name="$1"
  local prompt="$2"
  local default_value="$3"
  local value
  while true; do
    printf "%s [%s]: " "$prompt" "$default_value"
    IFS= read -r value
    if [ -z "$value" ]; then
      printf -v "$__var_name" '%s' "$default_value"
    else
      printf -v "$__var_name" '%s' "$value"
    fi
    return
  done
}

prompt_required_into() {
  local __var_name="$1"
  local prompt="$2"
  local value
  while true; do
    printf "%s: " "$prompt"
    IFS= read -r value
    if [ -n "$value" ]; then
      printf -v "$__var_name" '%s' "$value"
      return
    fi
    echo "此项必填。"
  done
}

prompt_optional_into() {
  local __var_name="$1"
  local prompt="$2"
  local value
  printf "%s（回车跳过）: " "$prompt"
  IFS= read -r value
  printf -v "$__var_name" '%s' "$value"
}

build_cron_expr_interactive() {
  CRON_EXPR=""
  local cron_choice hour hours expr confirm
  while true; do
    echo
    echo "请选择定时方式："
    echo "1) 每天凌晨 x 点"
    echo "2) 每 x 小时"
    echo "3) 自定义 cron 表达式"
    echo "0) 跳过"
    printf "输入选项: "
    IFS= read -r cron_choice
    case "$cron_choice" in
      1)
        prompt_required_into hour "请输入小时（0-23）"
        expr="0 ${hour} * * *"
        ;;
      2)
        prompt_required_into hours "请输入间隔小时数"
        expr="0 */${hours} * * *"
        ;;
      3)
        prompt_required_into expr "请输入 cron 表达式"
        ;;
      0)
        CRON_EXPR=""
        return
        ;;
      *)
        echo "无效选项"
        continue
        ;;
    esac

    echo
    echo "生成的定时任务表达式为："
    echo "$expr"
    printf "是否确认使用这个表达式？ [Y/n]: "
    IFS= read -r confirm
    case "${confirm:-Y}" in
      Y|y|"")
        CRON_EXPR="$expr"
        return
        ;;
      *)
        echo "已取消，返回定时方式选择。"
        ;;
    esac
  done
}

show_config_preview() {
  echo
  echo "当前输入配置预览："
  echo "安装目录：$INSTALL_DIR"
  echo "WebDAV 域名：$WEBDAV_DOMAIN"
  echo "WebDAV 用户名：$WEBDAV_USERNAME"
  echo "WebDAV 密码：********"
  echo "远端路径：$WEBDAV_PATH"
  echo "SERVER_ID：$SERVER_ID"
  echo "备份内容路径：$BACKUP_SOURCES"
  echo "排除规则：${EXCLUDE_PATTERNS:-无}"
  if [ -n "$CRON_EXPR" ]; then
    echo "定时任务：$CRON_EXPR"
  else
    echo "定时任务：未安装"
  fi
}

install_flow() {
  local install_cron
  echo
  echo "开始安装引导"
  prompt_default_into INSTALL_DIR "安装目录" "$DEFAULT_INSTALL_DIR"
  set_paths "$INSTALL_DIR"
  prompt_required_into WEBDAV_DOMAIN "WebDAV 域名"
  prompt_required_into WEBDAV_USERNAME "WebDAV 用户名"
  prompt_required_into WEBDAV_PASSWORD "WebDAV 密码"
  prompt_default_into WEBDAV_PATH "远端路径" "$DEFAULT_REMOTE_PATH"
  prompt_required_into SERVER_ID "SERVER_ID"
  prompt_required_into BACKUP_SOURCES "备份内容路径"
  prompt_optional_into EXCLUDE_PATTERNS "排除规则，多个请用空格或后续手改 env"
  printf "是否安装 cron（定时任务）？ [Y/n]: "
  IFS= read -r install_cron
  if [[ "${install_cron:-Y}" =~ ^([Yy]|)$ ]]; then
    build_cron_expr_interactive
  else
    CRON_EXPR=""
  fi
  show_config_preview
  pause
}

main_menu() {
  while true; do
    clear || true
    echo "请选择操作："
    echo "1) 安装"
    echo "0) 退出"
    printf "输入选项: "
    IFS= read -r choice
    case "$choice" in
      1) install_flow ;;
      0) exit 0 ;;
      *) echo "无效选项"; pause ;;
    esac
  done
}

main_menu
