#!/bin/bash

# --- 颜色定义 ---
INFO='\033[1;32m'    # 绿色
WARN='\033[0;33m'    # 黄色
ERROR='\033[1;31m'   # 红色
INPUT='\033[1;36m'   # 青色
RESET='\033[0m'      # 重置

# 权限与 sudo 判定（root 身份绝不使用 sudo，消除 unable to resolve host 警告）
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        echo -e "${ERROR}[错误] 请以 root 身份运行，或安装 sudo 工具后重试！${RESET}"
        exit 1
    fi
fi

# 自愈修复 /etc/hosts 缺失主机名导致的解析警告
CURRENT_HOST=$(hostname 2>/dev/null)
if [ -n "$CURRENT_HOST" ] && ! grep -qE "(^|[[:space:]])${CURRENT_HOST}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    if [ "$(id -u)" -eq 0 ]; then
        echo "127.0.0.1 $CURRENT_HOST" >> /etc/hosts
    elif [ -n "$SUDO" ]; then
        echo "127.0.0.1 $CURRENT_HOST" | $SUDO tee -a /etc/hosts >/dev/null
    fi
fi

# 仓库与文件配置
GITHUB_RAW_KEY="https://raw.githubusercontent.com/fox-baixi/linux/main/ssh/dsh_key.pub"
GITHUB_MIRROR_KEY="https://ghfast.top/https://raw.githubusercontent.com/fox-baixi/linux/main/ssh/dsh_key.pub"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
TARGET_KEY_FILE="${SCRIPT_DIR}/dsh_key.pub"

# 限制 IP 规则（IPv4 网段 + IPv6 /48 网段）
IP_RULE='from="183.193.171.0/24,2409:8a1e:6f41::/48"'
KEY_IDENTIFIER="dsh"

# 1. 动态获取纯公钥文件（本地优先，失败时回退 GitHub Raw / 镜像）
DSH_RAW_KEY=""
if [ -f "$TARGET_KEY_FILE" ]; then
    DSH_RAW_KEY=$(grep -v '^[[:space:]]*#' "$TARGET_KEY_FILE" | grep -v '^[[:space:]]*$' | head -n 1)
fi

if [ -z "$DSH_RAW_KEY" ]; then
    echo -e "${INFO}[网络] 正在从 GitHub 获取 AI Agent (${KEY_IDENTIFIER}) 专属公钥...${RESET}"
    DSH_RAW_KEY=$(curl -fsSL --connect-timeout 5 "$GITHUB_RAW_KEY" 2>/dev/null | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | head -n 1)
    if [ -z "$DSH_RAW_KEY" ]; then
        DSH_RAW_KEY=$(curl -fsSL --connect-timeout 5 "$GITHUB_MIRROR_KEY" 2>/dev/null | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | head -n 1)
    fi
fi

if [ -z "$DSH_RAW_KEY" ]; then
    echo -e "${ERROR}[错误] 无法获取 ${KEY_IDENTIFIER} 专属公钥！请确认仓库中是否存在 ssh/dsh_key.pub${RESET}"
    exit 1
fi

# 确保提取出纯公钥（如果公钥行含有前置 options 则去除，仅提取标准公钥部分）
PURE_PUB_KEY=$(echo "$DSH_RAW_KEY" | grep -oE '(ssh-|ecdsa-|sk-)[^[:space:]]+[[:space:]]+[^[:space:]]+([[:space:]]+.*)?$')
if [ -z "$PURE_PUB_KEY" ]; then
    PURE_PUB_KEY="$DSH_RAW_KEY"
fi

# 动态组合：将 IP 限制规则与纯公钥结合生成目标条目
TARGET_ENTRY="${IP_RULE} ${PURE_PUB_KEY}"

# 动态提取当前公钥的主体（Base64 字符串），用于比对与精准识别，不硬编码
DYNAMIC_KEY_BODY=$(echo "$PURE_PUB_KEY" | awk '{print $2}')

# 2. 目标路径定义与权限确保
SSH_DIR="$HOME/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

user_prompt() {
    local prompt_msg="$1"
    local var_name="$2"
    if [ -t 0 ]; then
        read -r -p "$(echo -e "$prompt_msg")" "$var_name"
    elif [ -r /dev/tty ]; then
        read -r -p "$(echo -e "$prompt_msg")" "$var_name" < /dev/tty
    else
        eval "$var_name='y'"
    fi
}

restart_sshd() {
    echo -e "${INFO}[检查] 校验 SSH 服务配置语法...${RESET}"
    if command -v sshd >/dev/null 2>&1; then
        if ! $SUDO sshd -t; then
            echo -e "${ERROR}[错误] sshd 配置检查未通过，取消重启服务！${RESET}"
            return 1
        fi
    fi

    echo -e "${INFO}[重启] 自动重启 SSH 服务以使配置生效...${RESET}"
    if $SUDO systemctl restart sshd 2>/dev/null || $SUDO systemctl restart ssh 2>/dev/null || $SUDO service ssh restart 2>/dev/null; then
        echo -e "${INFO}[成功] SSH 服务已自动重启生效。${RESET}"
    else
        echo -e "${WARN}[警告] 自动重启 SSH 服务失败，请手动重启 ssh 服务${RESET}"
    fi
}

# 3. 识别 authorized_keys 中属于 dsh 标识的行（依据特殊标识 dsh 或当前动态公钥）
is_dsh_line() {
    local line="$1"
    [[ "$line" =~ ^[[:space:]]*# ]] && return 1
    [[ -z "${line// }" ]] && return 1

    # 条件 A：注释或内容中包含特殊标识 dsh
    if echo "$line" | grep -qE "([[:space:]]|\"|^)${KEY_IDENTIFIER}(@|[[:space:]]|$)"; then
        return 0
    fi
    # 条件 B：与从 dsh_key.pub 动态读取出的公钥主体匹配
    if [ -n "$DYNAMIC_KEY_BODY" ] && echo "$line" | grep -qF "$DYNAMIC_KEY_BODY"; then
        return 0
    fi
    return 1
}

EXISTING_DSH_LINE=""
DSH_EXISTS=0
NEED_UPDATE=0

while IFS= read -r line || [ -n "$line" ]; do
    if is_dsh_line "$line"; then
        DSH_EXISTS=1
        EXISTING_DSH_LINE="$line"
        if [ "$line" != "$TARGET_ENTRY" ]; then
            NEED_UPDATE=1
        fi
        break
    fi
done < "$AUTH_KEYS"

echo -e "\n${INFO}===========================================${RESET}"
echo -e "${INFO}    AI Agent 专属受限公钥管理 (${KEY_IDENTIFIER})     ${RESET}"
echo -e "${INFO}===========================================${RESET}"

AUTO_MODE=0
if [[ "${1:-}" == "-y" || "${1:-}" == "--auto" || ! -t 0 && ! -r /dev/tty ]]; then
    AUTO_MODE=1
fi

if [ "$DSH_EXISTS" -eq 1 ] && [ "$NEED_UPDATE" -eq 0 ]; then
    echo -e "${INFO}[状态校验] AI Agent (${KEY_IDENTIFIER}) 公钥已存在，且配置与 IP 限制均为最新，无需更新。${RESET}"
    echo -e "当前配置：\n  ${EXISTING_DSH_LINE}\n"
    exit 0
fi

if [ "$DSH_EXISTS" -eq 1 ] && [ "$NEED_UPDATE" -eq 1 ]; then
    echo -e "${WARN}[状态校验] 检测到已存在 ${KEY_IDENTIFIER} 公钥，但与目标配置不一致！${RESET}"
    echo -e "${WARN}当前配置: ${EXISTING_DSH_LINE}${RESET}"
    echo -e "${INFO}目标配置: ${TARGET_ENTRY}${RESET}"

    do_update="y"
    if [ "$AUTO_MODE" -ne 1 ]; then
        user_prompt "${INPUT}是否更新该公钥及 IP 限制规则？[Y/n]: ${RESET}" do_update
    fi

    case "${do_update:-y}" in
        [yY][eE][sS]|[yY]|"")
            echo -e "${INFO}[更新] 正在原地更新 ${KEY_IDENTIFIER} 专属公钥（保留其它所有原有公钥）...${RESET}"
            TMP_FILE=$(mktemp "${AUTH_KEYS}.tmp.XXXXXX")
            while IFS= read -r line || [ -n "$line" ]; do
                if is_dsh_line "$line"; then
                    continue
                fi
                echo "$line" >> "$TMP_FILE"
            done < "$AUTH_KEYS"

            [[ -s "$TMP_FILE" && "$(tail -c1 "$TMP_FILE")" != "" ]] && echo "" >> "$TMP_FILE"
            echo "$TARGET_ENTRY" >> "$TMP_FILE"

            mv "$TMP_FILE" "$AUTH_KEYS"
            chmod 600 "$AUTH_KEYS"
            echo -e "${INFO}[成功] ${KEY_IDENTIFIER} 专属公钥已更新为最新版本！${RESET}"
            restart_sshd
            ;;
        *)
            echo -e "${INFO}[取消] 未对公钥做任何修改。${RESET}"
            ;;
    esac
else
    echo -e "${WARN}[状态校验] 当前未配置 ${KEY_IDENTIFIER} 专属公钥。${RESET}"
    echo -e "${INFO}待添加配置: ${TARGET_ENTRY}${RESET}"

    do_add="y"
    if [ "$AUTO_MODE" -ne 1 ]; then
        user_prompt "${INPUT}是否安全追加该公钥（不影响已有其它公钥）？[Y/n]: ${RESET}" do_add
    fi

    case "${do_add:-y}" in
        [yY][eE][sS]|[yY]|"")
            echo -e "${INFO}[添加] 正在追加写入 ${KEY_IDENTIFIER} 专属公钥...${RESET}"
            [[ -s "$AUTH_KEYS" && "$(tail -c1 "$AUTH_KEYS")" != "" ]] && echo "" >> "$AUTH_KEYS"
            echo "$TARGET_ENTRY" >> "$AUTH_KEYS"
            chmod 600 "$AUTH_KEYS"
            echo -e "${INFO}[成功] ${KEY_IDENTIFIER} 专属公钥已安全添加！已限制仅允许指定 IPv4/IPv6 访问。${RESET}"
            restart_sshd
            ;;
        *)
            echo -e "${INFO}[取消] 未追加公钥。${RESET}"
            ;;
    esac
fi

echo -e "\n${INFO}[完成] 当前生效的 ${KEY_IDENTIFIER} 配置：${RESET}"
grep -E "([[:space:]]|\"|^)${KEY_IDENTIFIER}(@|[[:space:]]|$)" "$AUTH_KEYS" 2>/dev/null || true
echo ""
