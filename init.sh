#!/bin/bash

# --- 颜色定义 ---
INFO='\033[1;32m'    # 绿色 (标题/成功)
OPT='\033[0;33m'     # 黄色 (选项)
INPUT='\033[1;36m'   # 青色 (提问)
RESET='\033[0m'      # 重置

# --- 1. 环境预检 (静默执行) ---
mem_total=$(free -m | awk '/Mem:/ {print $2}')
cpu_cores=$(nproc)
cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d ":" -f2)

# IPv4 检测
if curl -s4m2 1.1.1.1 > /dev/null 2>&1; then
    ipv4_status="已有 IPv4"
    warp_default="2" # 默认跳过
else
    ipv4_status="无 IPv4"
    warp_default="1" # 默认安装
fi

# 算法推荐
if [ "$cpu_cores" -ge 2 ] || [[ "$cpu_model" =~ "E3"|"E5"|"Xeon"|"Intel"|"AMD" ]]; then
    default_algo="zstd"
else
    default_algo="lz4"
fi

# ZRAM 大小计算 (阶梯规则)
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

# 0. WARP 选项
echo -e "\n${INFO}0. WARP 网络扩展 (当前: $ipv4_status)${RESET}"
echo -e "${OPT}1. 安装 WARP${RESET}"
echo -e "${OPT}2. 跳过 (默认)${RESET}"
read -p "$(echo -e ${INPUT}请选择 [默认 $warp_default]: ${RESET})" warp_choice
warp_choice=${warp_choice:-$warp_default}

# 1. 工具选项
echo -e "\n${INFO}1. 基础工具安装${RESET}"
echo -e "${OPT}1. 精简版 (sudo)${RESET}"
echo -e "${OPT}2. 基础版 (git, nano, unzip, tar, sudo)${RESET}"
read -p "$(echo -e ${INPUT}请选择 [回车默认 1]: ${RESET})" tool_p
tool_p=${tool_p:-1}

# 2. ZRAM 选项
echo -e "\n${INFO}2. 内存压缩 (ZRAM)${RESET}"
echo -e "${OPT}1. 开启 (默认)${RESET}"
echo -e "${OPT}2. 关闭${RESET}"
read -p "$(echo -e ${INPUT}请选择 [回车默认 1]: ${RESET})" zram_on
zram_on=${zram_on:-1}

if [ "$zram_on" == "1" ]; then
    echo -e "\n${INFO}3. 压缩算法选择${RESET}"
    echo -e "${OPT}1. lz4${RESET}"
    echo -e "${OPT}2. zstd${RESET}"
    read -p "$(echo -e ${INPUT}请选择 [回车自动: $default_algo]: ${RESET})" algo_choice
    case $algo_choice in
        1) final_algo="lz4" ;;
        2) final_algo="zstd" ;;
        *) final_algo=$default_algo ;;
    esac

    read -p "$(echo -e ${INPUT}4. ZRAM 大小 [回车自动: ${auto_zram_s}MB]: ${RESET})" zram_s
    zram_s=${zram_s:-$auto_zram_s}
fi

# 5. Swap 选项
if [ "$zram_on" == "1" ]; then auto_swap_s=1024; else
    auto_swap_s=$mem_total; [ $auto_swap_s -gt 2048 ] && auto_swap_s=2048
fi
echo -e "\n${INFO}5. 磁盘 Swap 设定${RESET}"
read -p "$(echo -e ${INPUT}请输入大小 [回车自动: ${auto_swap_s}MB]: ${RESET})" swap_s
swap_s=${swap_s:-$auto_swap_s}

# 6. Docker 选项
echo -e "\n${INFO}6. Docker 环境${RESET}"
echo -e "${OPT}1. 安装 (含 IPv6 & 日志限制)${RESET}"
echo -e "${OPT}2. 跳过 (默认)${RESET}"
read -p "$(echo -e ${INPUT}请选择 [回车默认 2]: ${RESET})" docker_on
docker_on=${docker_on:-2}

# --- 3. 执行阶段 ---

echo -e "\n${INFO}>> 开始执行初始化任务...${RESET}"

# WARP 执行
if [ "$warp_choice" == "1" ]; then
    wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh
fi

apt update && apt upgrade -y
[ "$tool_p" == "1" ] && apt install -y sudo || apt install -y git nano unzip tar sudo
apt dist-upgrade -y

# BBR & 时区
timedatectl set-timezone Asia/Shanghai
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
fi

# ZRAM 配置
if [ "$zram_on" == "1" ]; then
    apt install zram-tools -y
    cat > /etc/default/zramswap <<EOF
ALGO=$final_algo
SIZE=$zram_s
PRIORITY=100
EOF
    service zramswap reload
    echo -e "${INFO}>> ZRAM 配置完成 ($final_algo)${RESET}"
fi

# Swap 写入
if [ ! -f /swapfile ]; then
    fallocate -l ${swap_s}M /swapfile && chmod 600 /swapfile
    mkswap /swapfile && swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# Docker 安装
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

# 时间同步
apt install chrony -y && systemctl enable --now chrony

echo -e "\n${INFO}================================"
echo -e "       所有任务初始化完成！"
echo -e "================================${RESET}"
date
