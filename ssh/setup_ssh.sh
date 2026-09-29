#!/bin/bash

# --- 颜色定义 ---
INFO='\033[1;32m'    # 绿色
WARN='\033[0;33m'    # 黄色
ERROR='\033[1;31m'   # 红色
INPUT='\033[1;36m'   # 青色
RESET='\033[0m'      # 重置

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_KEY_FILE="${SCRIPT_DIR}/target_key.pub"

# 1. 检查公钥源文件
if [ ! -f "$TARGET_KEY_FILE" ]; then
    echo -e "${ERROR}[错误] 未找到目标公钥文件: ${TARGET_KEY_FILE}${RESET}"
    exit 1
fi

TARGET_KEY=$(grep -v '^[[:space:]]*#' "$TARGET_KEY_FILE" | grep -v '^[[:space:]]*$' | head -n 1)
if [ -z "$TARGET_KEY" ]; then
    echo -e "${ERROR}[错误] 目标公钥文件内容为空！${RESET}"
    exit 1
fi

TARGET_CORE=$(echo "$TARGET_KEY" | awk '{print $1, $2}')

# 2. 目标路径定义
SSH_DIR="$HOME/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

# 3. 获取当前系统的 SSH 状态
get_password_auth_status() {
    local status="yes"
    if command -v sshd >/dev/null 2>&1; then
        local check
        check=$(sshd -T 2>/dev/null | grep -i '^passwordauthentication ' | awk '{print $2}')
        if [ -n "$check" ]; then
            status="$check"
        fi
    fi
    # 若无法通过 sshd -T 获取（非 root），读取配置文件 fallback
    if [ -z "$check" ] && [ -f /etc/ssh/sshd_config ]; then
        local raw
        raw=$(grep -iE '^[[:space:]]*PasswordAuthentication' /etc/ssh/sshd_config | tail -n 1 | awk '{print $2}')
        if [ -n "$raw" ]; then
            status=$(echo "$raw" | tr '[:upper:]' '[:lower:]')
        fi
    fi
    echo "$status"
}

# 检查 authorized_keys 中是否存在有效公钥
check_has_keys() {
    if [ -f "$AUTH_KEYS" ]; then
        if grep -qE '^(ssh-|ecdsa-|sk-)' "$AUTH_KEYS"; then
            echo "1"
            return
        fi
    fi
    echo "0"
}

# 检查目标公钥是否已在 authorized_keys 中匹配
check_key_match() {
    if [ -f "$AUTH_KEYS" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            # 过滤注释与空行
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

# 应用目标公钥
apply_target_key() {
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    if [ -f "$AUTH_KEYS" ]; then
        cp "$AUTH_KEYS" "${AUTH_KEYS}.bak.$(date +%s)"
    fi
    echo "$TARGET_KEY" > "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    echo -e "${INFO}[成功] 目标公钥已写入: ${AUTH_KEYS} (权限 600)${RESET}"
}

# 关闭密码登录
disable_password_authentication() {
    echo -e "${INFO}[配置] 正在关闭密码登录...${RESET}"
    local conf_d="/etc/ssh/sshd_config.d"
    local conf_file="/etc/ssh/sshd_config"

    if [ -d "$conf_d" ]; then
        # 推荐使用子配置目录覆盖
        echo "PasswordAuthentication no" | sudo tee "${conf_d}/99-disable-password.conf" > /dev/null
    elif [ -f "$conf_file" ]; then
        if sudo grep -qE '^[[:space:]]*#?[[:space:]]*PasswordAuthentication' "$conf_file"; then
            sudo sed -i -E 's/^[[:space:]]*#?[[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' "$conf_file"
        else
            echo "PasswordAuthentication no" | sudo tee -a "$conf_file" > /dev/null
        fi
    fi
    restart_sshd
}

# 重启 SSH 服务
restart_sshd() {
    echo -e "${INFO}[检查] 校验 SSH 服务配置语法...${RESET}"
    if command -v sshd >/dev/null 2>&1; then
        if ! sudo sshd -t; then
            echo -e "${ERROR}[错误] sshd 语法检查未通过，请检查配置，取消重启服务！${RESET}"
            return 1
        fi
    fi

    echo -e "${INFO}[重启] 正在自动重启 SSH 服务以生效...${RESET}"
    if sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null || sudo service ssh restart 2>/dev/null; then
        echo -e "${INFO}[成功] SSH 服务已自动重启生效。${RESET}"
    else
        echo -e "${WARN}[警告] 自动重启 SSH 服务失败，请手动执行 systemctl restart ssh/sshd${RESET}"
    fi
}

# --- 主逻辑 ---
PASSWORD_STATUS=$(get_password_auth_status)
HAS_KEYS=$(check_has_keys)
KEY_MATCH=$(check_key_match)

echo -e "\n${INFO}===================================${RESET}"
echo -e "${INFO}       SSH 认证状态检测与配置       ${RESET}"
echo -e "${INFO}===================================${RESET}"

# 1. 优先级一：密码 + 密钥混合
if [ "$PASSWORD_STATUS" == "yes" ] && [ "$HAS_KEYS" == "1" ]; then
    echo -e "${WARN}[检测结果] 当前处于: 密码 + 密钥 混合登录状态${RESET}"
    if [ "$KEY_MATCH" == "1" ]; then
        echo -e "${INFO}[公钥校验] 公钥一致，无需更改。${RESET}"
        read -p "$(echo -e ${INPUT}当前仍允许密码登录，是否关闭密码登录以提高安全性？[y/N]: ${RESET})" disable_pwd
        case "$disable_pwd" in
            [yY][eE][sS]|[yY])
                disable_password_authentication
                ;;
            *)
                echo -e "${INFO}[保持] 保持当前混合登录状态。${RESET}"
                ;;
        esac
    else
        echo -e "${WARN}[公钥校验] 公钥不符！${RESET}"
        read -p "$(echo -e ${INPUT}是否更新为目标公钥？[y/N]: ${RESET})" update_key
        case "$update_key" in
            [yY][eE][sS]|[yY])
                apply_target_key
                read -p "$(echo -e ${INPUT}是否同时关闭密码登录？[y/N]: ${RESET})" disable_pwd
                case "$disable_pwd" in
                    [yY][eE][sS]|[yY])
                        disable_password_authentication
                        ;;
                    *)
                        echo -e "${INFO}[保持] 密码登录已保留。${RESET}"
                        ;;
                esac
                ;;
            *)
                echo -e "${INFO}[取消] 未对公钥和密码配置做任何修改。${RESET}"
                ;;
        esac
    fi

# 2. 优先级二：纯密码登录
elif [ "$PASSWORD_STATUS" == "yes" ] && [ "$HAS_KEYS" == "0" ]; then
    echo -e "${WARN}[检测结果] 当前处于: 纯密码登录状态 (未检测到公钥)${RESET}"
    read -p "$(echo -e ${INPUT}是否更新成密钥登录？[y/N]: ${RESET})" switch_key
    case "$switch_key" in
        [yY][eE][sS]|[yY])
            apply_target_key
            read -p "$(echo -e ${INPUT}是否关闭密码登录？[y/N]: ${RESET})" disable_pwd
            case "$disable_pwd" in
                [yY][eE][sS]|[yY])
                    disable_password_authentication
                    ;;
                *)
                    echo -e "${INFO}[提示] 密钥已配置，密码登录依然保留。${RESET}"
                    ;;
            esac
            ;;
        *)
            echo -e "${INFO}[取消] 保持密码登录不变。${RESET}"
            ;;
    esac

# 3. 优先级三：纯密钥登录
else
    echo -e "${INFO}[检测结果] 当前处于: 纯密钥登录状态 (已禁用密码登录)${RESET}"
    if [ "$KEY_MATCH" == "1" ]; then
        echo -e "${INFO}[公钥校验] 公钥一致，无需更改。${RESET}"
    else
        echo -e "${WARN}[公钥校验] 公钥不符！${RESET}"
        read -p "$(echo -e ${INPUT}公钥不符，是否更新？[y/N]: ${RESET})" update_key
        case "$update_key" in
            [yY][eE][sS]|[yY])
                apply_target_key
                ;;
            *)
                echo -e "${INFO}[取消] 未更新公钥。${RESET}"
                ;;
        esac
    fi
fi
