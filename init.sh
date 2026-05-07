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
echo -e "${OPT}2. 基础版 (git, nano, unzip, tar, sudo)${RESET}"
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
    if [ "$zram_s" -le 0 ] 2>/dev/null; then zram_s=$auto_zram_s; fi
fi

# 5. Swap
if [ "$zram_on" == "1" ]; then 
    auto_swap_s=1024
else
    calc_swap=$mem_total
    [ $calc_swap -gt 2048 ] && calc_swap=2048
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
echo -e "\n${INFO}>> 开始执行初始化任务...${RESET}"

apt update && apt upgrade -y

if [ "$warp_choice" == "1" ]; then
    wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh
fi

[ "$tool_p" == "1" ] && apt install -y sudo || apt install -y git nano unzip tar sudo
apt dist-upgrade -y

timedatectl set-timezone Asia/Shanghai
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
fi

if [ "$zram_on" == "1" ]; then
    apt install zram-tools -y
    cat > /etc/default/zramswap <<EOF
ALGO=$final_algo
SIZE=$zram_s
PRIORITY=100
EOF
    service zramswap reload
    echo -e "${INFO}>> ZRAM 配置完成 ($final_algo / ${zram_s}MB)${RESET}"
fi

# Swap 执行阶段 (含存量检测)
if [ "$swap_s" != "0" ]; then
    current_swap=0
    [ -f /swapfile ] && current_swap=$(du -m /swapfile | cut -f1)

    if [ "$current_swap" != "$swap_s" ]; then
        echo -e "${INFO}>> 更新磁盘 Swap: ${current_swap}MB -> ${swap_s}MB...${RESET}"
        [ -f /swapfile ] && swapoff /swapfile && rm -f /swapfile
        sed -i '/\/swapfile/d' /etc/fstab
        
        fallocate -l ${swap_s}M /swapfile && chmod 600 /swapfile
        mkswap /swapfile && swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    else
        echo -e "${INFO}>> 现有 Swap 大小符合要求，跳过创建${RESET}"
    fi
else
    # 如果用户选 0，且原本存在 Swap，建议将其关闭
    if [ -f /swapfile ]; then
        echo -e "${INFO}>> 检测到 0 输入，正在关闭并移除现有 Swap...${RESET}"
        swapoff /swapfile && rm -f /swapfile
        sed -i '/\/swapfile/d' /etc/fstab
    fi
    echo -e "${INFO}>> 已禁用磁盘 Swap${RESET}"
fi

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
fi

apt install chrony -y && systemctl enable --now chrony

echo -e "\n${INFO}================================"
echo -e "       所有任务初始化完成！"
echo -e "================================${RESET}"
date
