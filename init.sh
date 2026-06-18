#!/bin/bash

# --- 颜色定义 ---
INFO='\033[1;32m'    # 绿色
OPT='\033[0;33m'     # 黄色
INPUT='\033[1;36m'   # 青色
AUTO='\033[1;35m'    # 紫色
RESET='\033[0m'      # 重置

# --- 1. 环境预检 ---
mem_total=$(free -m | awk '/Mem:/ {print $2}')
cpu_cores=$(nproc)
cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d ":" -f2)

if curl -s4m2 1.1.1.1 > /dev/null 2>&1; then
    ipv4_status="已有 IPv4"; warp_default="2"
else
    ipv4_status="无 IPv4"; warp_default="1"
fi

if [ "$cpu_cores" -ge 2 ] || [[ "$cpu_model" =~ "E3"|"E5"|"Xeon"|"Intel"|"AMD" ]]; then
    default_algo="zstd"; algo_idx="2"
else
    default_algo="lz4"; algo_idx="1"
fi

# ZRAM 大小阶梯算法 (512MB 对齐)
if [ "$mem_total" -lt 1024 ]; then
    calc=$(( mem_total * 2 ))
elif [ "$mem_total" -lt 2048 ]; then
    calc=2048
else
    calc=$mem_total
fi
[ $calc -gt 4096 ] && calc=4096
auto_zram_s=$(( (calc + 256) / 512 * 512 ))

# --- 2. 交互布局 ---

clear
echo -e "${INFO}================================"
echo -e "       Debian 系统初始化脚本"
echo -e "================================${RESET}"

# 0. WARP
echo -e "\n${INFO}0. WARP 网络扩展 (当前: $ipv4_status)${RESET}"
echo -e "${OPT}1. 安装 WARP$( [ "$warp_default" == "1" ] && echo " (默认)" )${RESET}"
echo -e "${OPT}2. 跳过$( [ "$warp_default" == "2" ] && echo " (默认)" )${RESET}"
read -p "$(echo -e ${INPUT}请选择: ${RESET})" warp_choice
warp_choice=${warp_choice:-$warp_default}

# 1. 工具
echo -e "\n${INFO}1. 基础工具安装${RESET}"
echo -e "${OPT}1. 精简版 (sudo) (默认)${RESET}"
echo -e "${OPT}2. 基础版 (git, nano, zip, unzip, tar, sudo)${RESET}"
read -p "$(echo -e ${INPUT}请选择: ${RESET})" tool_p
tool_p=${tool_p:-1}

# 2. ZRAM
echo -e "\n${INFO}2. 内存压缩 (ZRAM)${RESET}"
echo -e "${OPT}1. 开启 (默认)${RESET}"
echo -e "${OPT}2. 关闭${RESET}"
read -p "$(echo -e ${INPUT}请选择: ${RESET})" zram_on
zram_on=${zram_on:-1}

if [ "$zram_on" == "1" ]; then
    echo -e "\n${INFO}3. 压缩算法选择${RESET}"
    echo -e "${OPT}1. lz4$( [ "$algo_idx" == "1" ] && echo " (默认)" )${RESET}"
    echo -e "${OPT}2. zstd$( [ "$algo_idx" == "2" ] && echo " (默认)" )${RESET}"
    read -p "$(echo -e ${INPUT}请选择: ${RESET})" algo_choice
    case $algo_choice in
        1) final_algo="lz4" ;;
        2) final_algo="zstd" ;;
        *) final_algo=$default_algo ;;
    esac

    echo -e "\n${INFO}4. ZRAM 大小设定${RESET}"
    read -p "$(echo -e ${INPUT}请输入大小 ${AUTO}[回车自动: ${auto_zram_s}MB]: ${RESET})" zram_s
    zram_s=${zram_s:-$auto_zram_s}
    [ "$zram_s" -le 0 ] 2>/dev/null && zram_s=$auto_zram_s
fi

# 5. Swap
if [ "$zram_on" == "1" ]; then auto_swap_s=1024; else
    calc_swap=$mem_total; [ $calc_swap -gt 2048 ] && calc_swap=2048
    auto_swap_s=$(( (calc_swap + 256) / 512 * 512 ))
    [ $auto_swap_s -lt 512 ] && auto_swap_s=512
fi
echo -e "\n${INFO}5. 磁盘 Swap 设定${RESET}"
read -p "$(echo -e ${INPUT}请输入大小 ${AUTO}[回车自动: ${auto_swap_s}MB, 输入0不启用]: ${RESET})" swap_s
swap_s=${swap_s:-$auto_swap_s}

# 6. Docker
echo -e "\n${INFO}6. Docker 环境${RESET}"
echo -e "${OPT}1. 安装 (含 IPv6 & 日志限制)${RESET}"
echo -e "${OPT}2. 跳过 (默认)${RESET}"
read -p "$(echo -e ${INPUT}请选择: ${RESET})" docker_on
docker_on=${docker_on:-2}

# --- 3. 执行阶段 ---
echo -e "\n${INFO}>> 正在全力初始化中，请稍候...${RESET}"

# 初始化报告变量
R_WARP="跳过"; R_TOOLS="精简版"; R_BBR="已开启"; R_ZRAM="未启用"; R_SWAP="未启用"; R_DOCKER="未安装"

apt update && apt upgrade -y

# WARP
if [ "$warp_choice" == "1" ]; then
    wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh
    R_WARP="已安装"
fi

# 工具
if [ "$tool_p" == "1" ]; then
    apt install -y sudo
else
    apt install -y git nano unzip tar sudo
    R_TOOLS="基础版"
fi
apt dist-upgrade -y

# BBR & 时区
timedatectl set-timezone Asia/Shanghai
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
fi

# ZRAM
if [ "$zram_on" == "1" ]; then
    apt install zram-tools -y
    cat > /etc/default/zramswap <<EOF
ALGO=$final_algo
SIZE=$zram_s
PRIORITY=100
EOF
    service zramswap reload
    R_ZRAM="$final_algo / ${zram_s}MB"
fi

# Swap
if [ "$swap_s" != "0" ]; then
    current_swap=0
    [ -f /swapfile ] && current_swap=$(du -m /swapfile | cut -f1)
    if [ "$current_swap" != "$swap_s" ]; then
        [ -f /swapfile ] && swapoff /swapfile && rm -f /swapfile
        sed -i '/\/swapfile/d' /etc/fstab
        fallocate -l ${swap_s}M /swapfile && chmod 600 /swapfile
        mkswap /swapfile && swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    R_SWAP="${swap_s}MB"
else
    if [ -f /swapfile ]; then
        swapoff /swapfile && rm -f /swapfile
        sed -i '/\/swapfile/d' /etc/fstab
    fi
fi

# Docker
if [ "$docker_on" == "1" ]; then
    curl -fsSL https://get.docker.com | bash
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
    "ipv6": true, "fixed-cidr-v6": "fd00:1::/64", "experimental": true, "ip6tables": true,
    "log-driver": "json-file", "log-opts": { "max-size": "3m", "max-file": "3" }
}
EOF
    systemctl restart docker
    docker network create --driver bridge --ipv6 --subnet fd00::/48 ipv6-network || true
    R_DOCKER="已安装 (含 IPv6 & 日志限制)"
fi

apt install chrony -y && systemctl enable --now chrony

# --- 4. 任务报告面板 ---
clear
echo -e "${INFO}========================================"
echo -e "         系统初始化任务报告"
echo -e "========================================${RESET}"
echo -e "  ${OPT}WARP 网络:    ${RESET} $R_WARP"
echo -e "  ${OPT}软件工具:    ${RESET} $R_TOOLS"
echo -e "  ${OPT}网络优化:    ${RESET} $R_BBR"
echo -e "  ${OPT}内存压缩:    ${RESET} $R_ZRAM"
echo -e "  ${OPT}磁盘 Swap:   ${RESET} $R_SWAP"
echo -e "  ${OPT}Docker:      ${RESET} $R_DOCKER"
echo -e "  ${OPT}时间同步:    ${RESET} 已完成 (Chrony)"
echo -e "${INFO}========================================${RESET}"
echo -e "  ${INFO}全部搞定！系统已处于最佳状态。${RESET}"
date
