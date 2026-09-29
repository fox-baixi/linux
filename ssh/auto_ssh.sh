#!/bin/bash

# --- 颜色定义 ---
INFO='\033[1;32m'    # 绿色
WARN='\033[0;33m'    # 黄色
ERROR='\033[1;31m'   # 红色
RESET='\033[0m'      # 重置

GITHUB_RAW_KEY="https://raw.githubusercontent.com/fox-baixi/linux/main/ssh/target_key.pub"
GITHUB_MIRROR_KEY="https://ghfast.top/https://raw.githubusercontent.com/fox-baixi/linux/main/ssh/target_key.pub"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
TARGET_KEY_FILE="${SCRIPT_DIR}/target_key.pub"

# 1. 获取目标公钥
TARGET_KEY=""
if [ -f "$TARGET_KEY_FILE" ]; then
    TARGET_KEY=$(grep -v '^[[:space:]]*#' "$TARGET_KEY_FILE" | grep -v '^[[:space:]]*$' | head -n 1)
fi

if [ -z "$TARGET_KEY" ]; then
    echo -e "${INFO}[网络] 正在从 GitHub 获取最新公钥...${RESET}"
    TARGET_KEY=$(curl -fsSL --connect-timeout 5 "$GITHUB_RAW_KEY" 2>/dev/null | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | head -n 1)
    if [ -z "$TARGET_KEY" ]; then
        TARGET_KEY=$(curl -fsSL --connect-timeout 5 "$GITHUB_MIRROR_KEY" 2>/dev/null | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | head -n 1)
    fi
fi

if [ -z "$TARGET_KEY" ]; then
    echo -e "${ERROR}[错误] 无法获取目标公钥！${RESET}"
    exit 1
fi

TARGET_CORE=$(echo "$TARGET_KEY" | awk '{print $1, $2}')

# 2. 目标路径定义
SSH_DIR="$HOME/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

get_password_auth_status() {
    local status="yes"
    local check=""
    if command -v sshd >/dev/null 2>&1; then
        check=$(sshd -T 2>/dev/null | grep -i '^passwordauthentication ' | awk '{print $2}')
        if [ -n "$check" ]; then
            status="$check"
        fi
    fi
    if [ -z "$check" ] && [ -f /etc/ssh/sshd_config ]; then
        local raw
        raw=$(grep -iE '^[[:space:]]*PasswordAuthentication' /etc/ssh/sshd_config | tail -n 1 | awk '{print $2}')
        if [ -n "$raw" ]; then
            status=$(echo "$raw" | tr '[:upper:]' '[:lower:]')
        fi
    fi
    echo "$status"
}

check_key_match() {
    if [ -f "$AUTH_KEYS" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue
            
            line_core=$(echo "$line" | awk '{print $1, $2}')
            if [ "$line_core" == "$TARGET_CORE" ]; then
                echo "1"
                return
            fi
        done < "$AUTH_KEYS"
    fi
    echo "0"
}

apply_target_key() {
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    if [ -f "$AUTH_KEYS" ]; then
        cp "$AUTH_KEYS" "${AUTH_KEYS}.bak.$(date +%s)"
    fi
    echo "$TARGET_KEY" > "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    echo -e "${INFO}[成功] 目标公钥已配置: ${AUTH_KEYS} (权限 600)${RESET}"
}

disable_password_authentication() {
    echo -e "${INFO}[配置] 正在关闭密码登录...${RESET}"
    local conf_d="/etc/ssh/sshd_config.d"
    local conf_file="/etc/ssh/sshd_config"

    if [ -d "$conf_d" ]; then
        echo "PasswordAuthentication no" | sudo tee "${conf_d}/99-disable-password.conf" > /dev/null
    elif [ -f "$conf_file" ]; then
        if sudo grep -qE '^[[:space:]]*#?[[:space:]]*PasswordAuthentication' "$conf_file"; then
            sudo sed -i -E 's/^[[:space:]]*#?[[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' "$conf_file"
        else
            echo "PasswordAuthentication no" | sudo tee -a "$conf_file" > /dev/null
        fi
    fi
}

restart_sshd() {
    echo -e "${INFO}[检查] 校验 SSH 服务配置语法...${RESET}"
    if command -v sshd >/dev/null 2>&1; then
        if ! sudo sshd -t; then
            echo -e "${ERROR}[错误] sshd 配置检查未通过，取消重启服务！${RESET}"
            return 1
        fi
    fi

    echo -e "${INFO}[重启] 自动重启 SSH 服务生效...${RESET}"
    if sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null || sudo service ssh restart 2>/dev/null; then
        echo -e "${INFO}[成功] SSH 服务已成功重启生效。${RESET}"
    else
        echo -e "${WARN}[警告] 自动重启 SSH 服务失败，请手动重启 ssh 服务${RESET}"
    fi
}

# --- 免确认全自动执行 ---
echo -e "\n${INFO}===================================${RESET}"
echo -e "${INFO}   SSH 自动配置（无需确认极速模式）  ${RESET}"
echo -e "${INFO}===================================${RESET}"

PASSWORD_STATUS=$(get_password_auth_status)
KEY_MATCH=$(check_key_match)

if [ "$KEY_MATCH" == "1" ] && [ "$PASSWORD_STATUS" != "yes" ]; then
    echo -e "${INFO}[状态] 当前已是目标公钥且已禁用密码登录，无需任何变更。${RESET}"
    exit 0
fi

NEED_RESTART=0

# 1. 公钥不符或未配置，直接更新
if [ "$KEY_MATCH" != "1" ]; then
    echo -e "${INFO}[执行] 正在自动写入目标公钥...${RESET}"
    apply_target_key
    NEED_RESTART=1
else
    echo -e "${INFO}[状态] 公钥已匹配一致。${RESET}"
fi

# 2. 密码未关闭，直接关闭
if [ "$PASSWORD_STATUS" == "yes" ]; then
    echo -e "${INFO}[执行] 正在自动关闭密码登录...${RESET}"
    disable_password_authentication
    NEED_RESTART=1
fi

# 3. 自动重启生效
if [ "$NEED_RESTART" -eq 1 ]; then
    restart_sshd
fi

echo -e "${INFO}[完成] 已全自动更新为纯密钥登录！${RESET}\n"
