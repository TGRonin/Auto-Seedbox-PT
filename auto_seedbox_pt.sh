#!/bin/bash

################################################################################
# Auto-Seedbox-PT (ASP) 
# qBittorrent + Vertex + FileBrowser 一键安装脚本
# 系统要求: Debian 10+ / Ubuntu 20.04+ (x86_64 / aarch64)
# 参数说明:
#   -u : 用户名 (用于运行服务和登录WebUI)
#   -p : 密码（必须 ≥ 12 位）
#   -c : qBittorrent 缓存大小 (MiB, 仅4.x有效, 5.x使用mmap)
#   -q : qBittorrent 版本 (4, 4.3.9, 5, 5.0.4, latest, 或精确小版本如 5.1.2)
#   -v : 安装 Vertex
#   -f : 安装 FileBrowser (含 MediaInfo 扩展)
#   -t : 启用系统内核优化（强烈推荐）
#   -m : 调优模式 (1: 极限抢种 / 2: 均衡保种) [默认 1]
#   -o : 自定义端口 (会提示输入)
#   -d : Vertex data 目录 ZIP/tar.gz 下载链接 (可选)
#   -k : Vertex data ZIP 解压密码 (可选)
################################################################################

set -euo pipefail
IFS=$'\n\t'

# ================= 0. 全局变量 =================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

QB_WEB_PORT=8080
QB_BT_PORT=20000
VX_PORT=3000
FB_PORT=8081
MI_PORT=8082

APP_USER="admin"
APP_PASS=""
QB_CACHE=1024
QB_VER_REQ="5.0.4" 
DO_VX=false
DO_FB=false
DO_TUNE=false
CUSTOM_PORT=false
CACHE_SET_BY_USER=false
TUNE_MODE="1"
VX_RESTORE_URL=""
VX_ZIP_PASS=""
INSTALLED_MAJOR_VER="5"
ACTION="install" 

HB="/root"
ASP_ENV_FILE="/etc/asp_env.sh"

TEMP_DIR=$(mktemp -d -t asp-XXXXXX)
trap 'rm -rf "$TEMP_DIR"' EXIT

# 固化直链库 (兜底与默认版本)
URL_V4_AMD64="https://github.com/yimouleng/Auto-Seedbox-PT/raw/refs/heads/main/qBittorrent/x86_64/qBittorrent-4.3.9-libtorrent-v1.2.20/qbittorrent-nox"
URL_V4_ARM64="https://github.com/yimouleng/Auto-Seedbox-PT/raw/refs/heads/main/qBittorrent/ARM64/qBittorrent-4.3.9-libtorrent-v1.2.20/qbittorrent-nox"
URL_V5_AMD64="https://github.com/yimouleng/Auto-Seedbox-PT/raw/refs/heads/main/qBittorrent/x86_64/qBittorrent-5.0.4-libtorrent-v2.0.11/qbittorrent-nox"
URL_V5_ARM64="https://github.com/yimouleng/Auto-Seedbox-PT/raw/refs/heads/main/qBittorrent/ARM64/qBittorrent-5.0.4-libtorrent-v2.0.11/qbittorrent-nox"

# ================= 1. 核心工具函数 & UI 增强 =================

log_info() { echo -e "${GREEN}[INFO] $1${NC}" >&2; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }
log_err() { echo -e "${RED}[ERROR] $1${NC}" >&2; exit 1; }

execute_with_spinner() {
    local msg="$1"
    shift
    local log="/tmp/asp_install.log"
    "$@" >> "$log" 2>&1 &
    local pid=$!
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    printf "\e[?25l"
    while kill -0 $pid 2>/dev/null; do
        local temp=${spinstr#?}
        printf "\r\033[K ${CYAN}[%c]${NC} %s..." "$spinstr" "$msg"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done
    local ret=0
    wait $pid || ret=$?
    printf "\e[?25h"
    if [ $ret -eq 0 ]; then
        printf "\r\033[K ${GREEN}[√]${NC} %s... 完成!\n" "$msg"
    else
        printf "\r\033[K ${RED}[X]${NC} %s... 失败! (请查看 /tmp/asp_install.log)\n" "$msg"
    fi
    return $ret
}

download_file() {
    local url=$1; local output=$2
    if [[ "$output" == "/usr/bin/qbittorrent-nox" ]]; then
        systemctl stop "qbittorrent-nox@$APP_USER" 2>/dev/null || true
        pkill -9 qbittorrent-nox 2>/dev/null || true
        rm -f "$output" 2>/dev/null || true
    fi
    if ! execute_with_spinner "正在获取资源 $(basename "$output")" wget -q --retry-connrefused --tries=3 --timeout=30 -O "$output" "$url"; then
        log_err "下载失败，请检查网络或 URL: $url"
    fi
}

check_root() { 
    if [[ $EUID -ne 0 ]]; then
        log_err "权限不足：请使用 root 用户运行本脚本！"
    fi
}

validate_pass() {
    if [[ ${#1} -lt 12 ]]; then
        log_err "安全性不足：密码长度必须 ≥ 12 位！"
    fi
}

wait_for_lock() {
    local max_wait=300; local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        log_warn "等待系统包管理器锁释放..."
        sleep 2; waited=$((waited + 2))
        [[ $waited -ge $max_wait ]] && break
    done
}

open_port() {
    local port=$1
    local proto=${2:-tcp}
    local added=false

    if command -v ufw >/dev/null && systemctl is-active --quiet ufw; then
        ufw allow "$port/$proto" >/dev/null 2>&1
        added=true
    fi

    if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --add-port="$port/$proto" --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        added=true
    fi

    if command -v iptables >/dev/null; then
        if ! iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT 1 -p "$proto" --dport "$port" -j ACCEPT
            if command -v netfilter-persistent >/dev/null; then
                netfilter-persistent save >/dev/null 2>&1
            elif command -v iptables-save >/dev/null; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
            added=true
        fi
    fi
}

check_port_occupied() {
    local port=$1
    if command -v netstat >/dev/null; then
        netstat -tuln | grep -q ":$port " && return 0
    elif command -v ss >/dev/null; then
        ss -tuln | grep -q ":$port " && return 0
    fi
    return 1
}

get_input_port() {
    local prompt=$1; local default=$2; local port
    while true; do
        read -p "  ▶ $prompt [默认 $default]: " port < /dev/tty
        port=${port:-$default}
        if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
            log_warn "无效输入，请输入 1-65535 端口号。"
            continue
        fi
        if check_port_occupied "$port"; then
            log_warn "端口 $port 已被占用，请更换！"
            continue
        fi
        echo "$port"
        return 0
    done
}

# ================= 2. 用户管理 =================

setup_user() {
    if [[ "$APP_USER" == "root" ]]; then
        HB="/root"
        log_info "以 Root 身份运行服务。"
        return
    fi

    if id "$APP_USER" &>/dev/null; then
        log_info "系统用户 $APP_USER 已存在，复用之。"
    else
        log_info "创建隔离系统用户: $APP_USER"
        useradd -m -s /bin/bash "$APP_USER"
    fi

    HB=$(eval echo ~$APP_USER)
}

# ================= 3. 深度卸载逻辑 =================

uninstall() {
    if [ -f "$ASP_ENV_FILE" ]; then
        source "$ASP_ENV_FILE"
    fi

    echo -e "${CYAN}=================================================${NC}"
    echo -e "${CYAN}        执行深度卸载流程 (含系统回滚)            ${NC}"
    echo -e "${CYAN}=================================================${NC}"
    
    log_info "正在扫描已安装的用户..."
    local detected_users=$(systemctl list-units --full -all --no-legend 'qbittorrent-nox@*' | sed -n 's/.*qbittorrent-nox@\([^.]*\)\.service.*/\1/p' | sort -u | tr '\n' ' ')
    
    if [[ -z "$detected_users" ]]; then
        detected_users="未检测到活跃服务 (可能是 admin)"
    fi
    
    echo -e "${YELLOW}=================================================${NC}"
    echo -e "${YELLOW} 提示: 系统中检测到以下可能的安装用户: ${NC}"
    echo -e "${GREEN} -> [ ${detected_users} ] ${NC}"
    echo -e "${YELLOW}=================================================${NC}"
    
    local default_u=${APP_USER:-admin}
    read -p "请输入要卸载的用户名 [默认: $default_u]: " input_user < /dev/tty
    target_user=${input_user:-$default_u}
    
    target_home=$(eval echo ~$target_user 2>/dev/null || echo "/home/$target_user")

    log_warn "将清理用户数据并【彻底回滚内核与系统状态】。"

    read -p "确认要卸载核心组件吗？此操作不可逆！ [Y/n]: " confirm < /dev/tty
    confirm=${confirm:-Y}
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then exit 0; fi

    execute_with_spinner "停止并移除服务守护进程" sh -c "
        for svc in \$(systemctl list-units --full -all | grep 'qbittorrent-nox@' | awk '{print \$1}'); do
            systemctl stop \"\$svc\" 2>/dev/null || true
            systemctl disable \"\$svc\" 2>/dev/null || true
            rm -f \"/etc/systemd/system/\$svc\"
        done
        pkill -9 qbittorrent-nox 2>/dev/null || true
        rm -f /usr/bin/qbittorrent-nox
    "


    execute_with_spinner "移除系统优化与内核回滚 (含服务扩展)" sh -c "
        systemctl stop asp-tune.service 2>/dev/null || true
        systemctl stop asp-mediainfo.service 2>/dev/null || true
        systemctl disable asp-tune.service 2>/dev/null || true
        systemctl disable asp-mediainfo.service 2>/dev/null || true
        rm -f /etc/systemd/system/asp-tune.service /usr/local/bin/asp-tune.sh /etc/sysctl.d/99-ptbox.conf
        rm -f /etc/systemd/system/asp-mediainfo.service /usr/local/bin/asp-mediainfo.py
        rm -f /usr/local/bin/asp-mediainfo.js /usr/local/bin/sweetalert2.all.min.js
        [ -f /etc/nginx/conf.d/asp-filebrowser.conf ] && rm -f /etc/nginx/conf.d/asp-filebrowser.conf && systemctl reload nginx 2>/dev/null || true
        [ -f /etc/security/limits.conf ] && sed -i '/# Auto-Seedbox-PT/d' /etc/security/limits.conf || true
    "
    
    log_warn "执行底层状态回滚..."
    if [ -f /etc/asp_original_governor ]; then
        orig_gov=$(cat /etc/asp_original_governor)
        for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            [ -f "$f" ] && echo "$orig_gov" > "$f" 2>/dev/null || true
        done
        rm -f /etc/asp_original_governor
    else
        for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            [ -f "$f" ] && echo "ondemand" > "$f" 2>/dev/null || true
        done
    fi
    
    ETH=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
    if [ -n "$ETH" ]; then
        ifconfig "$ETH" txqueuelen 1000 2>/dev/null || true
    fi
    DEF_ROUTE=$(ip -o -4 route show to default | head -n1)
    if [[ -n "$DEF_ROUTE" ]]; then
        ip route change $DEF_ROUTE initcwnd 10 initrwnd 10 2>/dev/null || true
    fi
    sysctl -w net.core.rmem_max=212992 >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_max=212992 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_rmem="4096 87380 6291456" >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_wmem="4096 16384 4194304" >/dev/null 2>&1 || true
    sysctl -w vm.dirty_ratio=20 >/dev/null 2>&1 || true
    sysctl -w vm.dirty_background_ratio=10 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    
    execute_with_spinner "清理防火墙规则遗留" sh -c "
        if command -v ufw >/dev/null && systemctl is-active --quiet ufw; then
            ufw delete allow $QB_WEB_PORT/tcp >/dev/null 2>&1 || true
            ufw delete allow $QB_BT_PORT/tcp >/dev/null 2>&1 || true
            ufw delete allow $QB_BT_PORT/udp >/dev/null 2>&1 || true
            ufw delete allow $VX_PORT/tcp >/dev/null 2>&1 || true
            ufw delete allow $FB_PORT/tcp >/dev/null 2>&1 || true
        fi
        if command -v firewalld >/dev/null && systemctl is-active --quiet firewalld; then
            firewall-cmd --zone=public --remove-port=\"$QB_WEB_PORT/tcp\" --permanent >/dev/null 2>&1 || true
            firewall-cmd --zone=public --remove-port=\"$QB_BT_PORT/tcp\" --permanent >/dev/null 2>&1 || true
            firewall-cmd --zone=public --remove-port=\"$QB_BT_PORT/udp\" --permanent >/dev/null 2>&1 || true
            firewall-cmd --zone=public --remove-port=\"$VX_PORT/tcp\" --permanent >/dev/null 2>&1 || true
            firewall-cmd --zone=public --remove-port=\"$FB_PORT/tcp\" --permanent >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
        fi
        if command -v iptables >/dev/null; then
            iptables -D INPUT -p tcp --dport $QB_WEB_PORT -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p tcp --dport $QB_BT_PORT -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p udp --dport $QB_BT_PORT -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p tcp --dport $VX_PORT -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p tcp --dport $FB_PORT -j ACCEPT 2>/dev/null || true
            if command -v netfilter-persistent >/dev/null; then
                netfilter-persistent save >/dev/null 2>&1
            elif command -v iptables-save >/dev/null; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
        fi
    "

    systemctl daemon-reload
    sysctl --system >/dev/null 2>&1 || true

    log_warn "清理配置文件..."
    if [[ -d "$target_home" ]]; then
         rm -rf "$target_home/.config/qBittorrent" "$target_home/.local/share/qBittorrent" "$target_home/.cache/qBittorrent" "$target_home/vertex" "$target_home/.config/filebrowser" "$target_home/filebrowser_data"
         log_info "已清理 $target_home 下的配置文件。"
         
         if [[ -d "$target_home/Downloads" ]]; then
             echo -e "${YELLOW}=================================================${NC}"
             log_warn "检测到可能包含大量数据的目录: $target_home/Downloads"
             read -p "是否连同已下载的种子数据一并彻底删除？此操作不可逆！ [Y/n]: " del_data < /dev/tty
             del_data=${del_data:-Y}
             if [[ "$del_data" =~ ^[Yy]$ ]]; then
                 rm -rf "$target_home/Downloads"
                 log_info "💣 已彻底删除 $target_home/Downloads 数据目录。"
             else
                 log_info "🛡️ 已为您安全保留 $target_home/Downloads 数据目录。"
             fi
             echo -e "${YELLOW}=================================================${NC}"
         fi
    fi
    rm -rf "/root/.config/qBittorrent" "/root/.local/share/qBittorrent" "/root/.cache/qBittorrent" "/root/vertex" "/root/.config/filebrowser" "/root/filebrowser_data" "$ASP_ENV_FILE"
    log_warn "建议重启服务器 (reboot) 以彻底清理内核内存驻留。"
    
    log_info "卸载完成。"
    exit 0
}

# ================= 4. 智能系统优化 (多阶层动态自适应版) =================

# ================= 4. 智能系统优化 (多阶层动态自适应版 - 爆改激进版) =================

optimize_system() {
    echo ""
    echo -e " ${CYAN}╔══════════════════ 系统内核优化 (ASP-Tuned Elite) ══════════════════╗${NC}"
    echo ""
    echo -e "  ${CYAN}▶ 正在深度接管系统调度与网络协议栈...${NC}"
    
    local mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local mem_gb_sys=$((mem_kb / 1024 / 1024))
    
    # 基础安全底线 (面向 4GB - 8GB 的常规 VPS)
    local rmem_max=67108864      # 64MB TCP缓冲
    local dirty_ratio=20
    local dirty_bg_ratio=5
    local backlog=30000          # 黄金队列长度，防 CPU Steal
    local syn_backlog=65535
    
    if [[ "$TUNE_MODE" == "1" ]]; then
        # 【动态自适应计算：全面解除 NVMe 封印】
        if [[ $mem_gb_sys -ge 30 ]]; then
            # 纯血独服/大内存怪兽 (32G+)：极度奔放，TCP 缓冲拉满 1GB
            rmem_max=1073741824
            dirty_ratio=50
            dirty_bg_ratio=15
            backlog=100000
            syn_backlog=200000
            echo -e "  ${PURPLE}↳ 检测到纯血级算力 (>=32GB)，已解锁最高序列内核权限 (1GB Buffer)！${NC}"
        elif [[ $mem_gb_sys -ge 15 ]]; then
            # 中大型 VPS/独服 (16G-31G)：平衡吞吐与延迟，TCP 缓冲 512MB
            rmem_max=536870912
            dirty_ratio=40
            dirty_bg_ratio=10
            backlog=50000
            syn_backlog=100000
            echo -e "  ${PURPLE}↳ 检测到中大型算力 (>=16GB)，已挂载进阶序列内核权限 (512MB Buffer)。${NC}"
        else
            # 常规级算力 (如 NCG9.5 8G)：匹配 2.5G 端口，TCP 缓冲 256MB，释放 NVMe 顺序写能力
            rmem_max=268435456
            dirty_ratio=30
            dirty_bg_ratio=10
            backlog=30000
            syn_backlog=65535
            echo -e "  ${PURPLE}↳ 检测到常规级算力 (<16GB)，已为您挂载 NVMe 激进并发矩阵 (256MB Buffer)。${NC}"
        fi
    fi

    local tcp_wmem="4096 65536 $rmem_max"
    local tcp_rmem="4096 87380 $rmem_max"
    local tcp_mem_min=$((mem_kb / 16)); local tcp_mem_def=$((mem_kb / 8)); local tcp_mem_max=$((mem_kb / 4))
    
    # 智能穿透侦测 BBR 版本
    local avail_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "bbr cubic reno")
    local kernel_name=$(uname -r | tr '[:upper:]' '[:lower:]')
    local target_cc="bbr"
    local ui_cc="bbr"

    if [[ "$TUNE_MODE" == "1" ]]; then
        # BBRv3 / BBRx 穿透识别逻辑
        if echo "$avail_cc" | grep -qw "bbrx" || echo "$kernel_name" | grep -q "bbrx"; then
            target_cc=$(echo "$avail_cc" | grep -qw "bbrx" && echo "bbrx" || echo "bbr")
            ui_cc="bbrx"
        elif echo "$avail_cc" | grep -qw "bbr3" || echo "$kernel_name" | grep -qE "bbr3|bbrv3"; then
            target_cc=$(echo "$avail_cc" | grep -qw "bbr3" && echo "bbr3" || echo "bbr")
            ui_cc="bbrv3"
        fi
        
        if [ ! -f /etc/asp_original_governor ]; then
            cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null > /etc/asp_original_governor || echo "ondemand" > /etc/asp_original_governor
        fi
    fi

    cat > /etc/sysctl.d/99-ptbox.conf << EOF
fs.file-max = 1048576
fs.nr_open = 1048576
vm.swappiness = 1
EOF

    # 核心修改：Mode 1 彻底废弃死板的 dirty_bytes，全面拥抱 ratio
    cat >> /etc/sysctl.d/99-ptbox.conf << EOF
vm.dirty_ratio = $dirty_ratio
vm.dirty_background_ratio = $dirty_bg_ratio
EOF

    cat >> /etc/sysctl.d/99-ptbox.conf << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $target_cc
net.core.somaxconn = 65535
net.core.netdev_max_backlog = $backlog
net.ipv4.tcp_max_syn_backlog = $syn_backlog
net.core.rmem_max = $rmem_max
net.core.wmem_max = $rmem_max
net.ipv4.tcp_rmem = $tcp_rmem
net.ipv4.tcp_wmem = $tcp_wmem
net.ipv4.tcp_mem = $tcp_mem_min $tcp_mem_def $tcp_mem_max
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_notsent_lowat = 131072
EOF

    if ! grep -q "Auto-Seedbox-PT" /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf << EOF
# Auto-Seedbox-PT Limits
* hard nofile 1048576
* soft nofile 1048576
root hard nofile 1048576
root soft nofile 1048576
EOF
    fi

    cat > /usr/local/bin/asp-tune.sh << EOF_SCRIPT
#!/bin/bash
IS_VIRT=\$(systemd-detect-virt 2>/dev/null || echo "none")

if [[ "$TUNE_MODE" == "1" ]]; then
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "\$f" ] && echo "performance" > "\$f" 2>/dev/null
    done
fi

for disk in \$(lsblk -nd --output NAME | grep -v '^md' | grep -v '^loop'); do
    blockdev --setra 4096 "/dev/\$disk" 2>/dev/null
    if [[ "\$IS_VIRT" == "none" ]]; then
        queue_path="/sys/block/\$disk/queue"
        if [ -f "\$queue_path/scheduler" ]; then
            rot=\$(cat "\$queue_path/rotational")
            avail=\$(cat "\$queue_path/scheduler")
            if [ "\$rot" == "0" ]; then
                if echo "\$avail" | grep -qw "mq-deadline"; then echo "mq-deadline" > "\$queue_path/scheduler" 2>/dev/null; fi
            else
                if echo "\$avail" | grep -qw "bfq"; then
                    echo "bfq" > "\$queue_path/scheduler" 2>/dev/null
                elif echo "\$avail" | grep -qw "mq-deadline"; then
                    echo "mq-deadline" > "\$queue_path/scheduler" 2>/dev/null
                fi
            fi
        fi
    fi
done
ETH=\$(ip -o -4 route show to default | awk '{print \$5}' | head -1)
if [ -n "\$ETH" ]; then
    ifconfig "\$ETH" txqueuelen 10000 2>/dev/null
    ethtool -G "\$ETH" rx 4096 tx 4096 2>/dev/null || true
    ethtool -G "\$ETH" rx 2048 tx 2048 2>/dev/null || true 
fi
DEF_ROUTE=\$(ip -o -4 route show to default | head -n1)
if [[ -n "\$DEF_ROUTE" ]]; then
    ip route change \$DEF_ROUTE initcwnd 25 initrwnd 25 2>/dev/null || true
fi
EOF_SCRIPT
    chmod +x /usr/local/bin/asp-tune.sh

    cat > /etc/systemd/system/asp-tune.service << EOF
[Unit]
Description=Auto-Seedbox-PT Tuning Service
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/asp-tune.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable asp-tune.service >/dev/null 2>&1

    execute_with_spinner "注入高吞吐网络参数 (防 Bufferbloat 策略)" sysctl --system
    execute_with_spinner "重载网卡队列与 CPU 性能调度器" systemctl start asp-tune.service || true
    
    local rmem_mb=$((rmem_max / 1024 / 1024))
    echo ""
    echo -e "  ${PURPLE}[⚡ ASP-Tuned Elite 核心调优已挂载]${NC}"
    echo -e "  ${CYAN}├─${NC} 拥塞控制算法 : ${GREEN}${ui_cc}${NC} (智能穿透匹配)"
    echo -e "  ${CYAN}├─${NC} 全局并发上限 : ${YELLOW}1,048,576${NC} (解除 Socket 封印)"
    echo -e "  ${CYAN}├─${NC} TCP 缓冲上限 : ${YELLOW}${rmem_mb} MB${NC} (动态智能感知)"
    if [[ "$TUNE_MODE" == "1" ]]; then
        echo -e "  ${CYAN}├─${NC} 脏页回写策略 : ${YELLOW}ratio=${dirty_ratio}, bg_ratio=${dirty_bg_ratio}${NC} (激进写盘适配 NVMe)"
        echo -e "  ${CYAN}├─${NC} CPU 调度策略 : ${RED}performance${NC} (锁定最高主频)"
    else
        echo -e "  ${CYAN}├─${NC} 脏页回写策略 : ${YELLOW}ratio=${dirty_ratio}, bg_ratio=${dirty_bg_ratio}${NC} (均衡平稳回写)"
        echo -e "  ${CYAN}├─${NC} CPU 调度策略 : ${GREEN}ondemand/schedutil${NC} (动态节能)"
    fi
    echo -e "  ${CYAN}└─${NC} 磁盘与网卡流 : ${YELLOW}I/O Multi-Queue & TX-Queue 优化${NC}"
    echo ""

    echo -e " ${GREEN}[√] 阶梯自适应内核引擎 (Mode $TUNE_MODE) 已全面接管！${NC}"
}

# ================= 5. 应用部署逻辑 =================

install_qbit() {
    echo ""
    echo -e " ${CYAN}╔══════════════════ 部署 qBittorrent 引擎 ══════════════════╗${NC}"
    echo ""
    local arch=$(uname -m); local url=""
    local api="https://api.github.com/repos/userdocs/qbittorrent-nox-static/releases"
    
    local hash_threads=$(nproc 2>/dev/null || echo 2)
    
    if [[ "$QB_VER_REQ" == "4" || "$QB_VER_REQ" == "4.3.9" ]]; then
        INSTALLED_MAJOR_VER="4"
        log_info "锁定版本: 4.x (绑定 libtorrent v1.2.20) -> 使用个人静态库"
        [[ "$arch" == "x86_64" ]] && url="$URL_V4_AMD64" || url="$URL_V4_ARM64"
        
    elif [[ "$QB_VER_REQ" == "5" || "$QB_VER_REQ" == "5.0.4" ]]; then
        INSTALLED_MAJOR_VER="5"
        log_info "锁定版本: 5.x (绑定 libtorrent v2.0.11 支持 mmap) -> 使用个人静态库"
        [[ "$arch" == "x86_64" ]] && url="$URL_V5_AMD64" || url="$URL_V5_ARM64"
        
    else
        INSTALLED_MAJOR_VER="5"
        log_info "请求动态版本: $QB_VER_REQ -> 正在连接 GitHub API..."
        
        local tag=""
        if [[ "$QB_VER_REQ" == "latest" ]]; then
            tag=$(curl -sL --max-time 10 "$api" | jq -r '.[0].tag_name' 2>/dev/null || echo "null")
        else
            tag=$(curl -sL --max-time 10 "$api" | jq -r --arg v "$QB_VER_REQ" '.[].tag_name | select(contains($v))' 2>/dev/null | head -n 1 || echo "null")
        fi
        
        if [[ -z "$tag" || "$tag" == "null" ]]; then
            log_warn "GitHub API 获取失败或受限，触发本地仓库兜底机制！"
            log_info "已自动降级为您个人的稳定内置版本: 5.0.4"
            [[ "$arch" == "x86_64" ]] && url="$URL_V5_AMD64" || url="$URL_V5_ARM64"
        else
            log_info "成功获取上游指定版本: $tag"
            local fname="${arch}-qbittorrent-nox"
            url="https://github.com/userdocs/qbittorrent-nox-static/releases/download/${tag}/${fname}"
        fi
    fi
    
    download_file "$url" "/usr/bin/qbittorrent-nox"
    chmod +x /usr/bin/qbittorrent-nox
    
    mkdir -p "$HB/.config/qBittorrent" "$HB/Downloads" "$HB/.local/share/qBittorrent/BT_backup"
    chown -R "$APP_USER:$APP_USER" "$HB/.config/qBittorrent" "$HB/Downloads" "$HB/.local"

    rm -f "$HB/.config/qBittorrent/qBittorrent.conf.lock"
    rm -f "$HB/.local/share/qBittorrent/BT_backup/.lock"
    
    local pass_hash=$(python3 -c "import sys, base64, hashlib, os; salt = os.urandom(16); dk = hashlib.pbkdf2_hmac('sha512', sys.argv[1].encode(), salt, 100000); print(f'@ByteArray({base64.b64encode(salt).decode()}:{base64.b64encode(dk).decode()})')" "$APP_PASS")
    
    if [[ "${CACHE_SET_BY_USER:-false}" == "false" ]]; then
        local total_mem_mb=$(free -m | awk '/^Mem:/{print $2}')
        if [[ "$TUNE_MODE" == "1" ]]; then
            QB_CACHE=$((total_mem_mb * 35 / 100))
        else
            QB_CACHE=$((total_mem_mb * 15 / 100))
            [[ $QB_CACHE -gt 2048 ]] && QB_CACHE=2048
        fi
    fi
    local cache_val="$QB_CACHE"
    local config_file="$HB/.config/qBittorrent/qBittorrent.conf"

    cat > "$config_file" << EOF
[LegalNotice]
Accepted=true

[Preferences]
General\Locale=zh_CN
WebUI\Locale=zh_CN
Downloads\SavePath=$HB/Downloads/
WebUI\Password_PBKDF2="$pass_hash"
WebUI\Port=$QB_WEB_PORT
WebUI\Username=$APP_USER
WebUI\AuthSubnetWhitelist=127.0.0.1/32, 172.16.0.0/12, 10.0.0.0/8, 192.168.0.0/16, 172.17.0.0/16
WebUI\AuthSubnetWhitelistEnabled=true
WebUI\LocalHostAuthenticationEnabled=false
WebUI\HostHeaderValidation=false
WebUI\CSRFProtection=false
WebUI\HTTPS\Enabled=false
Connection\PortRangeMin=$QB_BT_PORT
EOF

    if [[ "$INSTALLED_MAJOR_VER" == "5" ]]; then
        # 【双模动态 I/O 修复】模式 1 禁用缓存 (0)，模式 2 启用缓存 (1) 保机械盘
        local io_mode=1
        [[ "$TUNE_MODE" == "1" ]] && io_mode=0
        
        cat >> "$config_file" << EOF
Session\DiskIOType=2
Session\DiskIOReadMode=$io_mode
Session\DiskIOWriteMode=$io_mode
Session\MemoryWorkingSetLimit=$cache_val
Session\HashingThreads=$hash_threads
EOF
    fi

    chown "$APP_USER:$APP_USER" "$config_file"
    
    cat > /etc/systemd/system/qbittorrent-nox@.service << EOF
[Unit]
Description=qBittorrent Service (User: %i)
After=network.target
[Service]
Type=simple
User=$APP_USER
Group=$APP_USER
ExecStart=/usr/bin/qbittorrent-nox --webui-port=$QB_WEB_PORT
Restart=on-failure
LimitNOFILE=1048576
MemoryHigh=80%
MemoryMax=85%
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable "qbittorrent-nox@$APP_USER" >/dev/null 2>&1
    systemctl start "qbittorrent-nox@$APP_USER"
    open_port "$QB_WEB_PORT"; open_port "$QB_BT_PORT" "tcp"; open_port "$QB_BT_PORT" "udp"

    local api_ready=false
    printf "\e[?25l"
    for i in {1..20}; do
        printf "\r\033[K ${CYAN}[⠧]${NC} 轮询探测 API 接口引擎存活状态... ($i/20)"
        if curl -s -f --max-time 2 "http://127.0.0.1:$QB_WEB_PORT/api/v2/app/version" >/dev/null; then
            api_ready=true
            break
        fi
        sleep 1
    done
    printf "\e[?25h"

    if [[ "$api_ready" == "true" ]]; then
        printf "\r\033[K ${GREEN}[√]${NC} API 引擎握手成功！开始下发高级底层配置... \n"
        
        curl -s -c "$TEMP_DIR/qb_cookie.txt" --max-time 5 --data "username=$APP_USER&password=$APP_PASS" "http://127.0.0.1:$QB_WEB_PORT/api/v2/auth/login" >/dev/null
        
        curl -s -b "$TEMP_DIR/qb_cookie.txt" --max-time 5 "http://127.0.0.1:$QB_WEB_PORT/api/v2/app/preferences" > "$TEMP_DIR/current_pref.json"
        
        # 基础防漏与协议参数 
        local patch_json="{\"locale\":\"zh_CN\",\"bittorrent_protocol\":1,\"dht\":false,\"pex\":false,\"lsd\":false,\"announce_to_all_trackers\":true,\"announce_to_all_tiers\":true,\"queueing_enabled\":false,\"bdecode_depth_limit\":10000,\"bdecode_token_limit\":10000000,\"strict_super_seeding\":false,\"max_ratio_action\":0,\"max_ratio\":-1,\"max_seeding_time\":-1,\"file_pool_size\":5000,\"peer_tos\":2"
        
        if [[ "$TUNE_MODE" == "1" ]]; then
            local mem_kb_qbit=$(grep MemTotal /proc/meminfo | awk '{print $2}')
            local mem_gb_qbit=$((mem_kb_qbit / 1024 / 1024))
            
            # 【核心重构：彻底解除并发锁死，拥抱高水位】
            local dyn_async_io=8
            local dyn_max_connec=20000
            local dyn_max_connec_tor=1000
            local dyn_max_up=5000
            local dyn_max_up_tor=300
            local dyn_half_open=500
            local send_buf=20480
            local send_buf_low=5120

            if [[ $mem_gb_qbit -ge 30 ]]; then
                # 纯血物理独服 (32G+)：海量并发轰炸，超级水位
                dyn_async_io=24
                dyn_max_connec=80000
                dyn_max_connec_tor=5000
                dyn_max_up=20000
                dyn_max_up_tor=1000
                dyn_half_open=2000
                send_buf=51200
                send_buf_low=10240
            elif [[ $mem_gb_qbit -ge 15 ]]; then
                # 中大型机器 (16G-31G)：阶梯放宽
                dyn_async_io=16
                dyn_max_connec=40000
                dyn_max_connec_tor=2000
                dyn_max_up=10000
                dyn_max_up_tor=500
                dyn_half_open=1000
                send_buf=40960
                send_buf_low=10240
            elif [[ $mem_gb_qbit -lt 6 ]]; then
                # 入门级小鸡 (<6G)：防死机收敛
                dyn_async_io=4
                dyn_max_connec=5000
                dyn_max_connec_tor=500
                dyn_max_up=1000
                dyn_max_up_tor=100
                dyn_half_open=300
                send_buf=10240
                send_buf_low=3072
            else
                # 常规机器 (6G-14G，涵盖 NCG9.5)：激进并发
                dyn_async_io=8
                dyn_max_connec=20000
                dyn_max_connec_tor=1000
                dyn_max_up=5000
                dyn_max_up_tor=300
                dyn_half_open=500
                send_buf=30720
                send_buf_low=8192
            fi

            # 注入阶梯化参数与 Elite 级快速剔除算法
            patch_json="${patch_json},\"max_connec\":${dyn_max_connec},\"max_connec_per_torrent\":${dyn_max_connec_tor},\"max_uploads\":${dyn_max_up},\"max_uploads_per_torrent\":${dyn_max_up_tor},\"max_half_open_connections\":${dyn_half_open},\"send_buffer_watermark\":${send_buf},\"send_buffer_low_watermark\":${send_buf_low},\"connection_speed\":2000,\"peer_timeout\":45,\"upload_choking_algorithm\":1,\"seed_choking_algorithm\":1,\"async_io_threads\":${dyn_async_io},\"max_active_downloads\":-1,\"max_active_uploads\":-1,\"max_active_torrents\":-1"
        else
            # 【M2 均衡保种】放宽心跳检测，采用轮询公平算法，低耗长效保种
            patch_json="${patch_json},\"max_connec\":1500,\"max_connec_per_torrent\":100,\"max_uploads\":300,\"max_uploads_per_torrent\":30,\"max_half_open_connections\":50,\"send_buffer_watermark\":10240,\"send_buffer_low_watermark\":3072,\"connection_speed\":500,\"peer_timeout\":120,\"upload_choking_algorithm\":0,\"seed_choking_algorithm\":0,\"async_io_threads\":4"
        fi
        
        if [[ "$INSTALLED_MAJOR_VER" == "5" ]]; then
            # V5 mmap 必须设限
            local io_mode=1
            [[ "$TUNE_MODE" == "1" ]] && io_mode=0
            patch_json="${patch_json},\"memory_working_set_limit\":$cache_val,\"disk_io_type\":2,\"disk_io_read_mode\":$io_mode,\"disk_io_write_mode\":$io_mode,\"hashing_threads\":$hash_threads"
        else
            # V4 物理内存缓存策略
            if [[ "$TUNE_MODE" == "1" ]]; then
                patch_json="${patch_json},\"disk_cache\":$cache_val,\"disk_cache_ttl\":600"
            else
                patch_json="${patch_json},\"disk_cache\":$cache_val,\"disk_cache_ttl\":1200"
            fi
        fi
        patch_json="${patch_json}}"
        echo "$patch_json" > "$TEMP_DIR/patch_pref.json"

        local final_payload="$patch_json"
        
        if command -v jq >/dev/null && grep -q "{" "$TEMP_DIR/current_pref.json"; then
            if jq -s '.[0] * .[1]' "$TEMP_DIR/current_pref.json" "$TEMP_DIR/patch_pref.json" > "$TEMP_DIR/final_pref.json" 2>/dev/null; then
                if [[ -s "$TEMP_DIR/final_pref.json" && $(cat "$TEMP_DIR/final_pref.json") != "null" ]]; then
                    final_payload=$(cat "$TEMP_DIR/final_pref.json")
                else
                    echo -e "  ${YELLOW}[WARN] API 载荷合并后数据为空，已触发防呆回退机制 (直接下发补丁)。${NC}"
                fi
            else
                echo -e "  ${YELLOW}[WARN] jq 解析失败或版本跨度过大，已触发防呆回退机制 (直接下发补丁)。${NC}"
            fi
        else
            echo -e "  ${YELLOW}[WARN] 未检测到 jq 依赖或拉取初始配置失败，已触发防呆回退机制 (直接下发补丁)。${NC}"
        fi

        local http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -b "$TEMP_DIR/qb_cookie.txt" -X POST --data-urlencode "json=$final_payload" "http://127.0.0.1:$QB_WEB_PORT/api/v2/app/setPreferences")
        
        if [[ "$http_code" == "200" ]]; then
            echo -e " ${GREEN}[√]${NC} 引擎防泄漏与底层网络已完全锁定为极致状态！"
            systemctl restart "qbittorrent-nox@$APP_USER"
        else
            echo -e " ${RED}[X]${NC} API 注入失败 (Code: $http_code)，请手动配置。"
        fi
        rm -f "$TEMP_DIR/qb_cookie.txt" "$TEMP_DIR/"*pref.json
    else
        echo -e "\n ${RED}[X]${NC} qBittorrent WebUI 未能在 20 秒内响应！"
    fi
}

install_apps() {
    echo ""
    echo -e " ${CYAN}╔══════════════════ 部署容器化应用 (Docker) ══════════════════╗${NC}"
    echo ""
    wait_for_lock
    
    if ! command -v docker >/dev/null; then
        execute_with_spinner "自动安装 Docker 环境" sh -c "curl -fsSL https://get.docker.com | sh || (apt-get update && apt-get install -y docker.io)"
    fi

    if [[ "$DO_VX" == "true" ]]; then
        echo -e "  ${CYAN}▶ 正在处理 Vertex (智能轮询) 核心逻辑...${NC}"
        
        docker rm -f vertex &>/dev/null || true
        
        mkdir -p "$HB/vertex/data/"{client,douban,irc,push,race,rss,rule,script,server,site,watch}
        mkdir -p "$HB/vertex/data/douban/set" "$HB/vertex/data/watch/set"
        mkdir -p "$HB/vertex/data/rule/"{delete,link,rss,race,raceSet}

        local vx_pass_md5=$(echo -n "$APP_PASS" | md5sum | awk '{print $1}')
        local set_file="$HB/vertex/data/setting.json"
        local need_init=true

        if [[ -n "$VX_RESTORE_URL" ]]; then
            local extract_tmp=$(mktemp -d)
            local is_tar=false
            if [[ "$VX_RESTORE_URL" == *.tar.gz* || "$VX_RESTORE_URL" == *.tgz* ]]; then
                is_tar=true
                download_file "$VX_RESTORE_URL" "$TEMP_DIR/bk.tar.gz"
                execute_with_spinner "解压原生 tar.gz 备份数据" tar -xzf "$TEMP_DIR/bk.tar.gz" -C "$extract_tmp"
            else
                download_file "$VX_RESTORE_URL" "$TEMP_DIR/bk.zip"
                local unzip_cmd="unzip -q -o"
                [[ -n "$VX_ZIP_PASS" ]] && unzip_cmd="unzip -q -o -P\"$VX_ZIP_PASS\""
                execute_with_spinner "解压 ZIP 备份数据" sh -c "$unzip_cmd \"$TEMP_DIR/bk.zip\" -d \"$extract_tmp\""
            fi
            
            local real_set=$(find "$extract_tmp" -name "setting.json" | head -n 1)
            if [[ -n "$real_set" ]]; then
                local real_dir=$(dirname "$real_set")
                cp -a "$real_dir"/. "$HB/vertex/data/" 2>/dev/null || true
            else
                log_warn "备份包解压后未找到 setting.json，这可能是一个损坏的备份文件！"
            fi
            rm -rf "$extract_tmp"
            need_init=false
        elif [[ -f "$set_file" ]]; then
            log_info "检测到本地已有配置，执行原地接管..."
            need_init=false
        fi

        local gw=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)
        [[ -z "$gw" ]] && gw="172.17.0.1"

        if [[ "$need_init" == "false" ]]; then
            log_info "智能桥接备份数据与新网络架构 (启动 Python 强制清洗层)..."
            
            cat << 'EOF_PYTHON' > "$TEMP_DIR/vx_fix.py"
import json, os, codecs, sys

vx_dir = sys.argv[1]
app_user = sys.argv[2]
md5_pass = sys.argv[3]
gw_ip = sys.argv[4]
qb_port = sys.argv[5]
app_pass = sys.argv[6]
log_file = "/tmp/asp_vx_error.log"

def log_err(msg):
    with open(log_file, "a") as f:
        f.write(msg + "\n")

def update_json(path, modifier_func):
    if not os.path.exists(path) or not path.endswith('.json'): return
    try:
        with codecs.open(path, "r", "utf-8-sig") as f:
            data = json.load(f)
        if modifier_func(data):
            with codecs.open(path, "w", "utf-8") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
    except Exception as e:
        log_err(f"Failed to process {path}: {str(e)}")

def fix_setting(d):
    d["username"] = app_user
    d["password"] = md5_pass
    return True

update_json(os.path.join(vx_dir, "setting.json"), fix_setting)

client_dir = os.path.join(vx_dir, "client")
if os.path.exists(client_dir):
    for fname in os.listdir(client_dir):
        def fix_client(d):
            c_type = d.get("client", "") or d.get("type", "")
            if "qBittorrent" in c_type or "qbittorrent" in c_type.lower():
                d["clientUrl"] = f"http://{gw_ip}:{qb_port}"
                d["username"] = app_user
                d["password"] = app_pass
                return True
            return False
        update_json(os.path.join(client_dir, fname), fix_client)
EOF_PYTHON
            python3 "$TEMP_DIR/vx_fix.py" "$HB/vertex/data" "$APP_USER" "$vx_pass_md5" "$gw" "$QB_WEB_PORT" "$APP_PASS"
        else
            cat > "$set_file" << EOF
{
  "username": "$APP_USER",
  "password": "$vx_pass_md5",
  "port": 3000
}
EOF
        fi

        chown -R "$APP_USER:$APP_USER" "$HB/vertex"
        chmod -R 777 "$HB/vertex/data"

        execute_with_spinner "拉取 Vertex 镜像 (文件较大，视网络情况约需 1~3 分钟)" docker pull lswl/vertex:stable
        execute_with_spinner "启动 Vertex 容器" docker run -d --name vertex --restart unless-stopped -p $VX_PORT:3000 -v "$HB/vertex":/vertex -e TZ=Asia/Shanghai lswl/vertex:stable
        open_port "$VX_PORT"
    fi

    if [[ "$DO_FB" == "true" ]]; then
        echo -e "  ${CYAN}▶ 正在处理 FileBrowser 核心逻辑 (引入 Nginx 注入与 MediaInfo)...${NC}"
        
        docker rm -f filebrowser &>/dev/null || true
        
        # 彻底移除旧版单文件挂载遗留，建立全新的专属目录
        rm -rf "$HB/.config/filebrowser" "$HB/fb.db" "$HB/filebrowser_data"
        mkdir -p "$HB/.config/filebrowser" "$HB/filebrowser_data"
        chown -R "$APP_USER:$APP_USER" "$HB/.config/filebrowser" "$HB/filebrowser_data"

        if ! command -v nginx >/dev/null; then
            execute_with_spinner "安装 Nginx 底层代理引擎" sh -c "apt-get update -qq && apt-get install -y nginx"
        fi

        # 引入你存放于 GitHub 的完美重构版 JS 代码
        JS_REMOTE_URL="https://github.com/yimouleng/Auto-Seedbox-PT/raw/refs/heads/main/asp-mediainfo.js"
        execute_with_spinner "拉取 MediaInfo 前端扩展" wget -qO /usr/local/bin/asp-mediainfo.js "$JS_REMOTE_URL"
        execute_with_spinner "拉取弹窗 UI 依赖库" wget -qO /usr/local/bin/sweetalert2.all.min.js "https://cdn.jsdelivr.net/npm/sweetalert2@11/dist/sweetalert2.all.min.js"

        # 带有智能降级 JSON 重组引擎的 Python 微服务
        cat > /usr/local/bin/asp-mediainfo.py << 'EOF_PY'
import http.server, socketserver, urllib.parse, subprocess, json, os, sys
PORT = int(sys.argv[2])
BASE_DIR = sys.argv[1]

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/api/mi':
            query = urllib.parse.parse_qs(parsed.query)
            file_path = query.get('file', [''])[0].lstrip('/')
            full_path = os.path.abspath(os.path.join(BASE_DIR, file_path))
            
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            
            if not full_path.startswith(os.path.abspath(BASE_DIR)) or not os.path.isfile(full_path):
                self.wfile.write(json.dumps({"error": "非法路径或文件不存在"}).encode('utf-8'))
                return
                
            try:
                # 优先尝试原生 JSON 输出 (需要较新的 mediainfo 版本)
                res = subprocess.run(['mediainfo', '--Output=JSON', full_path], capture_output=True, text=True)
                try:
                    json.loads(res.stdout)
                    self.wfile.write(res.stdout.encode('utf-8'))
                    return
                except:
                    pass
                
                # 如果旧系统不支持 JSON 导出指令，则捕获原始文本，并智能转换拼接成 JSON
                res_text = subprocess.run(['mediainfo', full_path], capture_output=True, text=True)
                lines = res_text.stdout.split('\n')
                tracks = []
                current_track = {}
                for line in lines:
                    line = line.strip()
                    if not line:
                        if current_track:
                            tracks.append(current_track)
                            current_track = {}
                        continue
                    if ':' not in line and '@type' not in current_track:
                        current_track['@type'] = line
                    elif ':' in line:
                        k, v = line.split(':', 1)
                        current_track[k.strip()] = v.strip()
                if current_track:
                    tracks.append(current_track)
                
                self.wfile.write(json.dumps({"media": {"track": tracks}}).encode('utf-8'))
                
            except Exception as e:
                self.wfile.write(json.dumps({"error": str(e)}).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
    httpd.serve_forever()
EOF_PY
        chmod +x /usr/local/bin/asp-mediainfo.py

        cat > /etc/systemd/system/asp-mediainfo.service << EOF
[Unit]
Description=ASP MediaInfo API Service
After=network.target
[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/asp-mediainfo.py "$HB" $MI_PORT
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable asp-mediainfo.service >/dev/null 2>&1
        systemctl restart asp-mediainfo.service

        # 零侵入安全的 Nginx 代理与 HTML 劫持
        cat > /etc/nginx/conf.d/asp-filebrowser.conf << EOF_NGINX
server {
    listen $FB_PORT;
    server_name _;
    client_max_body_size 0;

    location / {
        proxy_pass http://127.0.0.1:18081;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # CSRF 防护核心：注入完整的代理溯源头部
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        proxy_set_header Accept-Encoding "";
        
        sub_filter '</body>' '<script src="/asp-mediainfo.js"></script></body>';
        sub_filter_once on;
    }

    location = /asp-mediainfo.js {
        alias /usr/local/bin/asp-mediainfo.js;
        add_header Content-Type "application/javascript; charset=utf-8";
    }
    location = /sweetalert2.all.min.js {
        alias /usr/local/bin/sweetalert2.all.min.js;
        add_header Content-Type "application/javascript; charset=utf-8";
    }

    location /api/mi {
        proxy_pass http://127.0.0.1:$MI_PORT;
    }
}
EOF_NGINX
        systemctl restart nginx

        execute_with_spinner "拉取 FileBrowser 镜像" docker pull filebrowser/filebrowser:latest

        # 【终极防弹机制】：明确指定 -d /database/filebrowser.db，并加上 --user 0:0 提权，防止宿主挂载目录权限丢失
        execute_with_spinner "初始化 FileBrowser 数据库表" sh -c "docker run --rm --user 0:0 -v \"$HB/filebrowser_data\":/database filebrowser/filebrowser:latest -d /database/filebrowser.db config init >/dev/null 2>&1 || true"
        
        execute_with_spinner "注入 FileBrowser 管理员账户" sh -c "docker run --rm --user 0:0 -v \"$HB/filebrowser_data\":/database filebrowser/filebrowser:latest -d /database/filebrowser.db users add \"$APP_USER\" \"$APP_PASS\" --perm.admin >/dev/null 2>&1 || true"
        
        execute_with_spinner "启动 FileBrowser 容器引擎" docker run -d --name filebrowser --restart unless-stopped --user 0:0 -v "$HB":/srv -v "$HB/filebrowser_data":/database -v "$HB/.config/filebrowser":/config -p 127.0.0.1:18081:80 filebrowser/filebrowser:latest -d /database/filebrowser.db
        
        open_port "$FB_PORT"
    fi
}

# ================= 6. 入口主流程 =================

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --uninstall) ACTION="uninstall"; shift ;;
        -u|--user) APP_USER="$2"; shift 2 ;;
        -p|--pass) APP_PASS="$2"; shift 2 ;;
        -c|--cache) QB_CACHE="$2"; CACHE_SET_BY_USER=true; shift 2 ;;
        -q|--qbit) QB_VER_REQ="$2"; shift 2 ;;
        -m|--mode) TUNE_MODE="$2"; shift 2 ;;
        -v|--vertex) DO_VX=true; shift ;;
        -f|--filebrowser) DO_FB=true; shift ;;
        -t|--tune) DO_TUNE=true; shift ;;
        -o|--custom-port) CUSTOM_PORT=true; shift ;;
        -d|--data) VX_RESTORE_URL="$2"; shift 2 ;;
        -k|--key) VX_ZIP_PASS="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ "$TUNE_MODE" != "1" && "$TUNE_MODE" != "2" ]]; then
    TUNE_MODE="1"
fi

if [[ "$ACTION" == "uninstall" ]]; then
    uninstall
fi

# ================= 开始全新极客仪表盘 UI =================
clear

echo -e "${CYAN}        ___   _____   ___  ${NC}"
echo -e "${CYAN}       / _ | / __/ |/ _ \\ ${NC}"
echo -e "${CYAN}      / __ |_\\ \\  / ___/ ${NC}"
echo -e "${CYAN}     /_/ |_/___/ /_/     ${NC}"
echo -e "${BLUE}================================================================${NC}"
echo -e "${PURPLE}     ✦ Auto-Seedbox-PT (ASP) 极限部署引擎 v3.0.1 ✦${NC}"
echo -e "${PURPLE}     ✦              作者：Supcutie              ✦${NC}"
echo -e "${GREEN}    🚀 一键部署 qBittorrent + Vertex + FileBrowser 刷流引擎${NC}"
echo -e "${YELLOW}   💡 GitHub：https://github.com/yimouleng/Auto-Seedbox-PT ${NC}"
echo -e "${BLUE}================================================================${NC}"
echo ""

echo -e " ${CYAN}╔══════════════════ 环境预检 ══════════════════╗${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
    echo -e "  检查 Root 权限...... [${RED}X${NC}] 拒绝通行"
    log_err "权限不足：请使用 root 用户运行本脚本！"
else
    echo -e "  检查 Root 权限...... [${GREEN}√${NC}] 通行"
fi

mem_kb_chk=$(grep MemTotal /proc/meminfo | awk '{print $2}')
mem_gb_chk=$((mem_kb_chk / 1024 / 1024))
tune_downgraded=false
if [[ "$TUNE_MODE" == "1" && $mem_gb_chk -lt 4 ]]; then
    TUNE_MODE="2"
    tune_downgraded=true
    echo -e "  检测 物理内存....... [${RED}!${NC}] ${mem_gb_chk} GB ${RED}(不足4G,触发降级保护)${NC}"
else
    echo -e "  检测 物理内存....... [${GREEN}√${NC}] ${mem_gb_chk} GB"
fi

arch_chk=$(uname -m)
echo -e "  检测 系统架构....... [${GREEN}√${NC}] ${arch_chk}"
kernel_chk=$(uname -r)
echo -e "  检测 内核版本....... [${GREEN}√${NC}] ${kernel_chk}"

if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo -e "  检测 网络连通性..... [${GREEN}🌐${NC}] 正常"
else
    echo -e "  检测 网络连通性..... [${YELLOW}!${NC}] 异常 (后续拉取依赖可能失败)"
fi

echo -n -e "  检查 DPKG 锁状态.... "
wait_for_lock_silent() {
    local max_wait=60; local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        echo -n "."
        sleep 1; waited=$((waited + 1))
        [[ $waited -ge $max_wait ]] && break
    done
}
wait_for_lock_silent
echo -e "[${GREEN}√${NC}] 就绪"

echo ""
echo -e " ${GREEN}√ 环境预检通过${NC}"
echo ""

echo -e " ${CYAN}╔══════════════════ 模式配置 ══════════════════╗${NC}"
echo ""

if [[ "$DO_TUNE" == "true" ]]; then
    if [[ "$TUNE_MODE" == "1" ]]; then
        echo -e "  当前选定模式: ${RED}极限抢种 (Mode 1 - Elite Dynamic)${NC}"
        echo -e "  推荐场景:     ${YELLOW}抢种打榜 / 追求瞬时满速爆发${NC}"
        echo -e "  机制提示:     ${GREEN}阶梯自适应并发墙，防死锁微量写盘，最快上传匹配。${NC}"
        echo ""
        echo -e "  ${YELLOW}即刻为您加载极限引擎，3秒后开始部署...${NC}"
        sleep 3
    else
        echo -e "  当前选定模式: ${GREEN}均衡保种 (Mode 2 - Stable)${NC}"
        echo -e "  推荐场景:     ${GREEN}长期养站 / 低耗稳定做种${NC}"
        if [[ "$tune_downgraded" == "true" ]]; then
            echo -e "  ${YELLOW}※ 已触发防呆机制，为您强制降级至此模式以防 OOM 死机。${NC}"
        fi
        echo ""
    fi
else
     echo -e "  当前选定模式: ${GREEN}默认 (未开启系统内核调优)${NC}"
     echo ""
fi

if [[ -z "$APP_USER" ]]; then APP_USER="admin"; fi
if [[ -n "$APP_PASS" ]]; then validate_pass "$APP_PASS"; fi

if [[ -z "$APP_PASS" ]]; then
    while true; do
        echo -n -e "  ▶ 请输入 Web 面板统一密码 (必须 ≥ 12 位): "
        read -s APP_PASS < /dev/tty; echo ""
        if [[ ${#APP_PASS} -ge 12 ]]; then break; fi
        log_warn "密码过短，请重新输入！"
    done
    echo ""
fi

export DEBIAN_FRONTEND=noninteractive
execute_with_spinner "修复可能的系统包损坏状态" sh -c "dpkg --configure -a && apt-get --fix-broken install -y >/dev/null 2>&1 || true"
execute_with_spinner "部署核心运行依赖 (curl, jq, tar...)" sh -c "apt-get -qq update && apt-get -qq install -y curl wget jq unzip tar python3 net-tools ethtool iptables mediainfo"

if [[ "$CUSTOM_PORT" == "true" ]]; then
    echo -e " ${CYAN}╔══════════════════ 自定义端口 ════════════════╗${NC}"
    echo ""
    QB_WEB_PORT=$(get_input_port "qBit WebUI" 8080); QB_BT_PORT=$(get_input_port "qBit BT监听" 20000)
    [[ "$DO_VX" == "true" ]] && VX_PORT=$(get_input_port "Vertex" 3000)
    [[ "$DO_FB" == "true" ]] && FB_PORT=$(get_input_port "FileBrowser" 8081)
    # MI_PORT 不再对外暴露，仅用于 Nginx 内部通信映射，因此不再要求用户手动输入
fi

# ================= 新增端口探测逻辑 =================
# 自动探测并分配一个空闲的内部端口给 MediaInfo API
while check_port_occupied "$MI_PORT"; do
    MI_PORT=$((MI_PORT + 1))
done
# =================================================

cat > "$ASP_ENV_FILE" << EOF
export QB_WEB_PORT=$QB_WEB_PORT
export QB_BT_PORT=$QB_BT_PORT
export VX_PORT=${VX_PORT:-3000}
export FB_PORT=${FB_PORT:-8081}
export MI_PORT=${MI_PORT:-8082}
EOF
chmod 600 "$ASP_ENV_FILE"

setup_user
install_qbit
[[ "$DO_VX" == "true" || "$DO_FB" == "true" ]] && install_apps
[[ "$DO_TUNE" == "true" ]] && optimize_system

PUB_IP=$(curl -s --max-time 5 https://api.ipify.org || echo "ServerIP")

tune_str=""
if [[ "$TUNE_MODE" == "1" ]]; then
    tune_str="${RED}Mode 1 (极限抢种 - Elite)${NC}"
else
    tune_str="${GREEN}Mode 2 (均衡保种 - Stable)${NC}"
fi

# ================= 极简极客版终端 Dashboard =================
echo ""
echo ""

VX_GW=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)
[[ -z "$VX_GW" ]] && VX_GW="172.17.0.1"

cat << EOF
========================================================================
                    ✨ AUTO-SEEDBOX-PT 部署完成 ✨                     
========================================================================
  [系统状态] 
EOF
echo -e "  ▶ 调优模式 : $tune_str"
echo -e "  ▶ 运行用户 : ${YELLOW}$APP_USER${NC} (已做运行目录隔离，保障安全)"
echo ""
echo -e " ------------------------ ${CYAN}🌐 终端访问地址${NC} ------------------------"
echo -e "  🧩 qBittorrent WebUI : ${GREEN}http://$PUB_IP:$QB_WEB_PORT${NC} (若不是中文，请按Ctrl+F5清空缓存)"
if [[ "$INSTALLED_MAJOR_VER" == "5" ]]; then
    echo -e "  ${YELLOW}💡 温馨提示: qBit 5.x 官方新版 UI 偶有显示延迟。若首次登录看到 0 个种子，请按 Ctrl+F5 强制刷新页面即可正常加载。${NC}"
fi
if [[ "$DO_VX" == "true" ]]; then
echo -e "  🌐 Vertex 智控面板   : ${GREEN}http://$PUB_IP:$VX_PORT${NC}"
echo -e "     └─ 内部直连 qBit  : ${YELLOW}$VX_GW:$QB_WEB_PORT${NC}"
fi
if [[ "$DO_FB" == "true" ]]; then
echo -e "  📁 FileBrowser 文件  : ${GREEN}http://$PUB_IP:$FB_PORT${NC}"
echo -e "     └─ MediaInfo 扩展 : ${YELLOW}已由本地 Nginx 安全代理分发${NC}"
fi

echo ""
echo -e " ------------------------ ${CYAN}🔐 统一鉴权凭证${NC} ------------------------"
echo -e "  👤 面板统一账号 : ${YELLOW}$APP_USER${NC}"
echo -e "  🔑 面板统一密码 : ${YELLOW}$APP_PASS${NC}"
echo -e "  📡 BT 监听端口  : ${YELLOW}$QB_BT_PORT${NC} (TCP/UDP 已尝试放行)"

echo ""
echo -e " ------------------------ ${CYAN}📂 核心数据目录${NC} ------------------------"
echo -e "  ⬇️ 种子下载目录 : $HB/Downloads"
echo -e "  ⚙️ qBit 配置文件: $HB/.config/qBittorrent"
[[ "$DO_VX" == "true" ]] && echo -e "  📦 Vertex 数据  : $HB/vertex/data"

echo ""
echo -e " ------------------------ ${CYAN}🛠️ 日常维护指令${NC} ------------------------"
echo -e "  重启 qBit : ${YELLOW}systemctl restart qbittorrent-nox@$APP_USER${NC}"
[[ "$DO_VX" == "true" || "$DO_FB" == "true" ]] && echo -e "  重启容器  : ${YELLOW}docker restart vertex filebrowser${NC}"
echo -e "  卸载脚本  : ${YELLOW}bash ./asp.sh --uninstall${NC}"

echo -e "========================================================================"
if [[ "$DO_TUNE" == "true" ]]; then
echo -e " ⚠️ ${YELLOW}强烈建议: 极速内核参数已注入，请执行 reboot 重启服务器以完全生效！${NC}"
echo -e "========================================================================"
fi
echo ""
