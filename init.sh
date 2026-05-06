#!/bin/bash

# --- 1. 环境预检与智能计算 ---
mem_total=$(free -m | awk '/Mem:/ {print $2}')
cpu_cores=$(nproc)
cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d ":" -f2)

# 智能判断默认算法
if [ "$cpu_cores" -ge 2 ]; then
    default_algo="zstd"
    algo_reason="多核处理器"
elif [[ "$cpu_model" =~ "E3"|"E5"|"Xeon"|"Intel"|"AMD" ]]; then
    default_algo="zstd"
    algo_reason="高性能单核"
else
    default_algo="lz4"
    algo_reason="低功耗单核"
fi

# ZRAM 大小阶梯算法
if [ "$mem_total" -lt 1024 ]; then
    calc=$(( mem_total * 2 ))
elif [ "$mem_total" -ge 1024 ] && [ "$mem_total" -lt 2048 ]; then
    calc=2048
else
    calc=$mem_total
fi
# 4G 封顶并进行 512MB 对齐
[ $calc -gt 4096 ] && calc=4096
auto_zram_s=$(( (calc + 256) / 512 * 512 ))

# --- 2. 交互菜单 ---

echo "--------------------------------"
echo "1. 基础工具: [1] 精简 (默认) | [2] 基础"
read -p "选择 [回车默认1]: " tool_p
tool_p=${tool_p:-1}

read -p "2. 开启内存压缩 (ZRAM)? [Y/n] (默认开启): " zram_on
zram_on=${zram_on:-y}

if [[ "$zram_on" =~ ^[Yy]$ ]]; then
    echo "3. 压缩算法选择 [系统推荐: $default_algo ($algo_reason)]:"
    echo "   1) lz4 | 2) zstd"
    read -p "选择 [回车自动]: " algo_choice
    case $algo_choice in
        1) final_algo="lz4" ;;
        2) final_algo="zstd" ;;
        *) final_algo=$default_algo ;;
    esac

    read -p "4. ZRAM 大小 [回车自动: ${auto_zram_s}MB]: " zram_s
    zram_s=${zram_s:-$auto_zram_s}
fi

# Swap 逻辑：开了 ZRAM 则磁盘 Swap 设为 1G，没开则设为内存等大(Max 2G)
if [[ "$zram_on" =~ ^[Yy]$ ]]; then
    auto_swap_s=1024
else
    auto_swap_s=$mem_total
    [ $auto_swap_s -gt 2048 ] && auto_swap_s=2048
fi
read -p "5. 磁盘 Swap 大小 [回车自动: ${auto_swap_s}MB]: " swap_s
swap_s=${swap_s:-$auto_swap_s}

read -p "6. 安装 Docker? [y/N] (默认n): " docker_on
docker_on=${docker_on:-n}

# --- 3. 执行阶段 ---

echo ">> 开始系统初始化..."

apt update && apt upgrade -y
[ "$tool_p" == "1" ] && apt install -y curl wget sudo || apt install -y curl wget git nano unzip tar sudo
apt dist-upgrade -y

# 默认优化项
timedatectl set-timezone Asia/Shanghai
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
fi

# 写入 ZRAM 配置
if [[ "$zram_on" =~ ^[Yy]$ ]]; then
    apt install zram-tools -y
    cat > /etc/default/zramswap <<EOF
ALGO=$final_algo
SIZE=$zram_s
PRIORITY=100
EOF
    service zramswap reload
    echo ">> ZRAM 已配置: $final_algo / ${zram_s}MB"
fi

# 写入 Swap
if [ ! -f /swapfile ]; then
    fallocate -l ${swap_s}M /swapfile && chmod 600 /swapfile
    mkswap /swapfile && swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo ">> 磁盘 Swap 已创建: ${swap_s}MB"
fi

# Docker 配置 (IPv6 & 日志限制)
if [[ "$docker_on" =~ ^[Yy]$ ]]; then
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
echo "--------------------------------"
echo "初始化完成！"
date

