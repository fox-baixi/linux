#!/usr/bin/env bash
set -euo pipefail

DEFAULT_INSTALL_DIR="/root/back"
DEFAULT_REMOTE_PATH="OneDrive/Backup/vps_docker"
SCRIPT_SOURCE_BASE="https://raw.githubusercontent.com/fox-baixi/linux/main/backup-installer"
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
  printf "%s [%s]: " "$prompt" "$default_value"
  IFS= read -r value
  if [ -z "$value" ]; then
    printf -v "$__var_name" '%s' "$default_value"
  else
    printf -v "$__var_name" '%s' "$value"
  fi
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

ensure_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "请用 root 运行。"
    exit 1
  fi
}

ensure_dependency() {
  local cmd="$1"
  local pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "缺少依赖: $cmd，尝试安装 $pkg"
    apt-get update && apt-get install -y "$pkg"
  fi
}

download_files() {
  mkdir -p "$INSTALL_DIR"
  curl -fsSL "${SCRIPT_SOURCE_BASE}/backup.sh" -o "$BACKUP_SCRIPT_PATH"
  chmod +x "$BACKUP_SCRIPT_PATH"
  curl -fsSL "${SCRIPT_SOURCE_BASE}/backup.env.example" -o "${INSTALL_DIR}/backup.env.example"
}

write_env() {
  local webdav_domain="$1"
  local webdav_username="$2"
  local webdav_password="$3"
  local webdav_path="$4"
  local server_id="$5"
  local backup_sources="$6"
  local exclude_patterns="$7"

  cat > "$BACKUP_ENV_PATH" <<EOF
WEBDAV_DOMAIN="$webdav_domain"
WEBDAV_USERNAME="$webdav_username"
WEBDAV_PASSWORD="$webdav_password"
WEBDAV_PATH="$webdav_path"
SERVER_ID="$server_id"
BACKUP_SOURCES="$backup_sources"
ARCHIVE_TMP_DIR="/tmp"
RCLONE_REMOTE_NAME="openlist"
RETENTION_DAYS="3"
ARCHIVE_PREFIX="backup"
EOF

  if [ -n "$exclude_patterns" ]; then
    printf "EXCLUDE_PATTERNS='%s'\n" "$exclude_patterns" >> "$BACKUP_ENV_PATH"
  fi
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

install_cron_job() {
  local expr="$1"
  local cmd="$BACKUP_SCRIPT_PATH >> $LOG_FILE 2>&1"
  local current
  current="$(crontab -l 2>/dev/null || true)"
  current="$(printf '%s\n' "$current" | grep -Fv "$BACKUP_SCRIPT_PATH" || true)"
  printf '%s\n%s %s\n' "$current" "$expr" "$cmd" | sed '/^$/N;/^\n$/D' | crontab -
}

show_config() {
  if [ ! -f "$BACKUP_ENV_PATH" ]; then
    echo "未找到配置文件：$BACKUP_ENV_PATH"
    return 1
  fi
  # shellcheck disable=SC1090
  source "$BACKUP_ENV_PATH"
  local cron_line
  cron_line="$(crontab -l 2>/dev/null | grep -F "$BACKUP_SCRIPT_PATH" || true)"
  echo "当前配置："
  echo "安装目录：$INSTALL_DIR"
  echo "WebDAV 域名：${WEBDAV_DOMAIN:-}"
  echo "WebDAV 用户名：${WEBDAV_USERNAME:-}"
  echo "WebDAV 密码：********"
  echo "远端路径：${WEBDAV_PATH:-}"
  echo "SERVER_ID：${SERVER_ID:-}"
  echo "备份内容路径：${BACKUP_SOURCES:-}"
  echo "排除规则：${EXCLUDE_PATTERNS:-无}"
  if [ -n "$cron_line" ]; then
    echo "当前定时任务：$cron_line"
  else
    echo "当前定时任务：未安装"
  fi
  return 0
}

manage_cron() {
  while true; do
    echo
    echo "定时任务管理："
    echo "1) 查看当前定时任务"
    echo "2) 添加定时任务"
    echo "3) 修改定时任务"
    echo "4) 删除定时任务"
    echo "0) 返回"
    printf "输入选项: "
    IFS= read -r sub
    case "$sub" in
      1)
        crontab -l 2>/dev/null | grep -F "$BACKUP_SCRIPT_PATH" || echo "未找到相关定时任务"
        pause
        ;;
      2)
        build_cron_expr_interactive
        if [ -n "$CRON_EXPR" ]; then
          install_cron_job "$CRON_EXPR"
          echo "定时任务已添加。"
        fi
        pause
        ;;
      3)
        build_cron_expr_interactive
        if [ -n "$CRON_EXPR" ]; then
          install_cron_job "$CRON_EXPR"
          echo "定时任务已修改。"
        fi
        pause
        ;;
      4)
        current="$(crontab -l 2>/dev/null || true)"
        current="$(printf '%s\n' "$current" | grep -Fv "$BACKUP_SCRIPT_PATH" || true)"
        printf '%s\n' "$current" | crontab -
        echo "定时任务已删除。"
        pause
        ;;
      0)
        return
        ;;
      *)
        echo "无效选项"
        ;;
    esac
  done
}

modify_config_flow() {
  local current_install_dir webdav_domain webdav_username webdav_password webdav_path server_id backup_sources exclude_patterns
  if ! show_config; then
    pause
    return
  fi
  echo
  echo "1) 修改配置"
  echo "2) 管理定时任务"
  echo "0) 返回"
  printf "输入选项: "
  IFS= read -r sub
  case "$sub" in
    1)
      # shellcheck disable=SC1090
      source "$BACKUP_ENV_PATH"
      current_install_dir="$INSTALL_DIR"
      prompt_default_into current_install_dir "安装目录" "$current_install_dir"
      set_paths "$current_install_dir"
      prompt_required_into webdav_domain "WebDAV 域名"
      prompt_required_into webdav_username "WebDAV 用户名"
      prompt_required_into webdav_password "WebDAV 密码"
      prompt_default_into webdav_path "远端路径" "${WEBDAV_PATH:-$DEFAULT_REMOTE_PATH}"
      prompt_required_into server_id "SERVER_ID"
      prompt_required_into backup_sources "备份内容路径"
      prompt_optional_into exclude_patterns "排除规则，多个请用空格或后续手改 env"
      mkdir -p "$INSTALL_DIR"
      if [ ! -f "$BACKUP_SCRIPT_PATH" ]; then
        download_files
      fi
      write_env "$webdav_domain" "$webdav_username" "$webdav_password" "$webdav_path" "$server_id" "$backup_sources" "$exclude_patterns"
      echo "配置已更新。"
      pause
      ;;
    2)
      manage_cron
      ;;
    0)
      return
      ;;
    *)
      echo "无效选项"
      pause
      ;;
  esac
}

install_flow() {
  local install_cron
  local webdav_domain webdav_username webdav_password webdav_path server_id backup_sources exclude_patterns
  echo
  echo "开始安装引导"
  prompt_default_into INSTALL_DIR "安装目录" "$DEFAULT_INSTALL_DIR"
  set_paths "$INSTALL_DIR"
  prompt_required_into webdav_domain "WebDAV 域名"
  prompt_required_into webdav_username "WebDAV 用户名"
  prompt_required_into webdav_password "WebDAV 密码"
  prompt_default_into webdav_path "远端路径" "$DEFAULT_REMOTE_PATH"
  prompt_required_into server_id "SERVER_ID"
  prompt_required_into backup_sources "备份内容路径"
  prompt_optional_into exclude_patterns "排除规则，多个请用空格或后续手改 env"
  printf "是否安装 cron（定时任务）？ [Y/n]: "
  IFS= read -r install_cron
  if [[ "${install_cron:-Y}" =~ ^([Yy]|)$ ]]; then
    build_cron_expr_interactive
  else
    CRON_EXPR=""
  fi
  mkdir -p "$INSTALL_DIR"
  download_files
  write_env "$webdav_domain" "$webdav_username" "$webdav_password" "$webdav_path" "$server_id" "$backup_sources" "$exclude_patterns"
  if [ -n "$CRON_EXPR" ]; then
    install_cron_job "$CRON_EXPR"
  fi
  echo "安装完成。"
  pause
}

upgrade_flow() {
  prompt_default_into INSTALL_DIR "安装目录" "$DEFAULT_INSTALL_DIR"
  set_paths "$INSTALL_DIR"
  printf "将升级脚本，保留现有配置和定时任务，是否继续？ [Y/n]: "
  IFS= read -r confirm
  case "${confirm:-Y}" in
    Y|y|"")
      mkdir -p "$INSTALL_DIR"
      download_files
      echo "升级完成。"
      ;;
    *)
      echo "已取消。"
      ;;
  esac
  pause
}

uninstall_flow() {
  prompt_default_into INSTALL_DIR "安装目录" "$DEFAULT_INSTALL_DIR"
  set_paths "$INSTALL_DIR"
  printf "这会删除所有脚本、配置和定时任务。如果存在日志，也会先打包带走再卸载。是否确认继续？ [y/N]: "
  IFS= read -r confirm
  case "$confirm" in
    y|Y)
      if [ -f "$LOG_FILE" ]; then
        tar -czf "/tmp/backup-logs-$(date +%F-%H-%M-%S).tar.gz" "$LOG_FILE" || true
      fi
      current="$(crontab -l 2>/dev/null || true)"
      current="$(printf '%s\n' "$current" | grep -Fv "$BACKUP_SCRIPT_PATH" || true)"
      printf '%s\n' "$current" | crontab -
      rm -f "$BACKUP_SCRIPT_PATH" "$BACKUP_ENV_PATH" "${INSTALL_DIR}/backup.env.example"
      echo "卸载完成。"
      ;;
    *)
      echo "已取消。"
      ;;
  esac
  pause
}

view_logs() {
  prompt_default_into INSTALL_DIR "安装目录" "$DEFAULT_INSTALL_DIR"
  set_paths "$INSTALL_DIR"
  if [ -f "$LOG_FILE" ]; then
    cat "$LOG_FILE"
  else
    echo "未找到日志文件：$LOG_FILE"
  fi
  pause
}

main_menu() {
  while true; do
    clear || true
    echo "请选择操作："
    echo "1) 安装"
    echo "2) 升级"
    echo "3) 卸载"
    echo "4) 查看/修改配置"
    echo "5) 查看日志"
    echo "0) 退出"
    printf "输入选项: "
    IFS= read -r choice
    case "$choice" in
      1) install_flow ;;
      2) upgrade_flow ;;
      3) uninstall_flow ;;
      4)
        prompt_default_into INSTALL_DIR "安装目录" "$DEFAULT_INSTALL_DIR"
        set_paths "$INSTALL_DIR"
        modify_config_flow
        ;;
      5)
        view_logs
        ;;
      0) exit 0 ;;
      *) echo "无效选项"; pause ;;
    esac
  done
}

ensure_root
ensure_dependency curl curl
main_menu
