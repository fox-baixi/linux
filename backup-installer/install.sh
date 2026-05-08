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

pause() {
  read -r -p "按回车继续..." _
}

read_with_default() {
  local prompt="$1"
  local default_value="$2"
  local value
  read -r -p "$prompt [$default_value]: " value
  printf '%s' "${value:-$default_value}"
}

read_required() {
  local prompt="$1"
  local value
  while true; do
    read -r -p "$prompt: " value
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return
    fi
    echo "此项必填。"
  done
}

read_optional_singleline() {
  local prompt="$1"
  local value
  read -r -p "$prompt（回车跳过）: " value
  printf '%s' "$value"
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

setup_paths() {
  INSTALL_DIR="$1"
  BACKUP_ENV_PATH="${INSTALL_DIR}/backup.env"
  BACKUP_SCRIPT_PATH="${INSTALL_DIR}/backup.sh"
}

download_files() {
  mkdir -p "$INSTALL_DIR"
  curl -fsSL "${SCRIPT_SOURCE_BASE}/backup.sh" -o "$BACKUP_SCRIPT_PATH"
  chmod +x "$BACKUP_SCRIPT_PATH"
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

build_cron_expr() {
  while true; do
    echo "请选择定时方式："
    echo "1) 每天凌晨 x 点"
    echo "2) 每 x 小时"
    echo "3) 自定义 cron 表达式"
    echo "0) 跳过"
    read -r -p "输入选项: " cron_choice
    case "$cron_choice" in
      1)
        hour=$(read_required "请输入小时（0-23）")
        expr="0 ${hour} * * *"
        ;;
      2)
        hours=$(read_required "请输入间隔小时数")
        expr="0 */${hours} * * *"
        ;;
      3)
        expr=$(read_required "请输入 cron 表达式")
        ;;
      0)
        printf ''
        return
        ;;
      *)
        echo "无效选项"
        continue
        ;;
    esac

    echo "生成的定时任务表达式为："
    echo "$expr"
    read -r -p "是否确认使用这个表达式？ [Y/n]: " confirm
    case "${confirm:-Y}" in
      Y|y|"")
        printf '%s' "$expr"
        return
        ;;
      *)
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
    return
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
}

manage_cron() {
  while true; do
    echo "定时任务管理："
    echo "1) 查看当前定时任务"
    echo "2) 添加定时任务"
    echo "3) 修改定时任务"
    echo "4) 删除定时任务"
    echo "0) 返回"
    read -r -p "输入选项: " sub
    case "$sub" in
      1)
        crontab -l 2>/dev/null | grep -F "$BACKUP_SCRIPT_PATH" || echo "未找到相关定时任务"
        pause
        ;;
      2)
        expr="$(build_cron_expr)"
        if [ -n "$expr" ]; then
          install_cron_job "$expr"
          echo "定时任务已添加。"
        fi
        pause
        ;;
      3)
        expr="$(build_cron_expr)"
        if [ -n "$expr" ]; then
          install_cron_job "$expr"
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

modify_config() {
  while true; do
    show_config
    echo
    echo "1) 修改配置"
    echo "2) 管理定时任务"
    echo "0) 返回"
    read -r -p "输入选项: " sub
    case "$sub" in
      1)
        if [ ! -f "$BACKUP_ENV_PATH" ]; then
          echo "未找到配置文件。"
          pause
          continue
        fi
        # shellcheck disable=SC1090
        source "$BACKUP_ENV_PATH"
        install_dir=$(read_with_default "安装目录" "$INSTALL_DIR")
        setup_paths "$install_dir"
        webdav_domain=$(read_required "WebDAV 域名")
        webdav_username=$(read_required "WebDAV 用户名")
        webdav_password=$(read_required "WebDAV 密码")
        webdav_path=$(read_with_default "远端路径" "${WEBDAV_PATH:-$DEFAULT_REMOTE_PATH}")
        server_id=$(read_required "SERVER_ID")
        backup_sources=$(read_required "备份内容路径")
        exclude_patterns=$(read_optional_singleline "排除规则，多个请自行写成换行转义或简洁模式")
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
        ;;
    esac
  done
}

install_flow() {
  local install_dir webdav_domain webdav_username webdav_password webdav_path server_id backup_sources exclude_patterns install_cron expr
  install_dir=$(read_with_default "安装目录" "$DEFAULT_INSTALL_DIR")
  setup_paths "$install_dir"
  webdav_domain=$(read_required "WebDAV 域名")
  webdav_username=$(read_required "WebDAV 用户名")
  webdav_password=$(read_required "WebDAV 密码")
  webdav_path=$(read_with_default "远端路径" "$DEFAULT_REMOTE_PATH")
  server_id=$(read_required "SERVER_ID")
  backup_sources=$(read_required "备份内容路径")
  exclude_patterns=$(read_optional_singleline "排除规则，多个请用空格或后续手改 env")
  read -r -p "是否安装 cron（定时任务）？ [Y/n]: " install_cron
  mkdir -p "$INSTALL_DIR"
  download_files
  write_env "$webdav_domain" "$webdav_username" "$webdav_password" "$webdav_path" "$server_id" "$backup_sources" "$exclude_patterns"
  if [[ "${install_cron:-Y}" =~ ^([Yy]|)$ ]]; then
    expr="$(build_cron_expr)"
    if [ -n "$expr" ]; then
      install_cron_job "$expr"
    fi
  fi
  echo "安装完成。"
  pause
}

upgrade_flow() {
  install_dir=$(read_with_default "安装目录" "$DEFAULT_INSTALL_DIR")
  setup_paths "$install_dir"
  read -r -p "将升级脚本，保留现有配置和定时任务，是否继续？ [Y/n]: " confirm
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
  install_dir=$(read_with_default "安装目录" "$DEFAULT_INSTALL_DIR")
  setup_paths "$install_dir"
  read -r -p "这会删除所有脚本、配置和定时任务。如果存在日志，也会先打包带走再卸载。是否确认继续？ [y/N]: " confirm
  case "$confirm" in
    y|Y)
      if [ -f "$LOG_FILE" ]; then
        tar -czf "/tmp/backup-logs-$(date +%F-%H-%M-%S).tar.gz" "$LOG_FILE" || true
      fi
      current="$(crontab -l 2>/dev/null || true)"
      current="$(printf '%s\n' "$current" | grep -Fv "$BACKUP_SCRIPT_PATH" || true)"
      printf '%s\n' "$current" | crontab -
      rm -f "$BACKUP_SCRIPT_PATH" "$BACKUP_ENV_PATH"
      echo "卸载完成。"
      ;;
    *)
      echo "已取消。"
      ;;
  esac
  pause
}

view_logs() {
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
    read -r -p "输入选项: " choice
    case "$choice" in
      1) install_flow ;;
      2) upgrade_flow ;;
      3) uninstall_flow ;;
      4)
        install_dir=$(read_with_default "安装目录" "$DEFAULT_INSTALL_DIR")
        setup_paths "$install_dir"
        modify_config
        ;;
      5)
        install_dir=$(read_with_default "安装目录" "$DEFAULT_INSTALL_DIR")
        setup_paths "$install_dir"
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
