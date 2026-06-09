#!/bin/bash
# ============================================================
# CentOS 9 初始化配置脚本
# 功能：关闭防火墙、配置静态IP/DNS/网关、下载必要组件
# 使用前请根据实际环境修改下方变量
# ============================================================

set -euo pipefail

# ===================== 变量配置区（按需修改） =====================
# 网络配置
NET_INTERFACE="ens160"                  # 网卡名称，用 ip a 查看
STATIC_IP="192.168.1.100/24"           # 静态IP及子网掩码（CIDR格式）
GATEWAY="192.168.1.1"                  # 网关地址
DNS1="8.8.8.8"                         # 首选DNS
DNS2="114.114.114.114"                 # 备用DNS

# 必要组件列表（按需增减）
PACKAGES=(
    vim
    wget
    curl
    net-tools
    bind-utils
    lsof
    tree
    htop
    unzip
    git
    bash-completion
    chrony
    firewalld         # 安装后会立即禁用，保留以便后续需要时启用
)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# -------------------- root 检查 --------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请以 root 用户运行此脚本"
        exit 1
    fi
}

# -------------------- 关闭防火墙 --------------------
disable_firewall() {
    log_info "正在关闭防火墙..."
    systemctl stop firewalld 2>/dev/null || true
    systemctl disable firewalld 2>/dev/null || true
    systemctl mask firewalld 2>/dev/null || true
    # 同时确保 iptables/nftables 不干扰
    systemctl stop nftables 2>/dev/null || true
    systemctl disable nftables 2>/dev/null || true
    log_info "防火墙已关闭并禁用（masked）"
}

# -------------------- 关闭 SELinux --------------------
disable_selinux() {
    log_info "正在关闭 SELinux..."
    if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
        setenforce 0 2>/dev/null || true
        # [Bug3 修复] 匹配所有模式（enforcing/permissive），统一改为 disabled
        sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
        log_info "SELinux 已设置为 disabled（重启后生效）"
    else
        log_info "SELinux 已处于关闭状态，跳过"
    fi
}

# -------------------- 配置静态IP --------------------
configure_static_ip() {
    log_info "正在配置静态IP..."

    # NetworkManager 连接名称默认与网卡名一致
    local CON_NAME="${NET_INTERFACE}"

    # 先检查连接是否存在
    if ! nmcli connection show "${CON_NAME}" &>/dev/null; then
        log_warn "未找到名为 ${CON_NAME} 的连接，尝试用网卡名创建..."
        nmcli connection add type ethernet con-name "${CON_NAME}" ifname "${NET_INTERFACE}"
    fi

    nmcli connection modify "${CON_NAME}" \
        ipv4.method manual \
        ipv4.addresses "${STATIC_IP}" \
        ipv4.gateway "${GATEWAY}" \
        ipv4.dns "${DNS1},${DNS2}" \
        ipv4.dns-search "" \
        ipv6.method disabled

    nmcli connection up "${CON_NAME}"
    log_info "静态IP配置完成：${STATIC_IP}  网关：${GATEWAY}  DNS：${DNS1},${DNS2}"
}

# -------------------- 配置DNS --------------------
configure_dns() {
    log_info "正在写入 /etc/resolv.conf..."
    # [Bug2 修复] 写入前先解除不可变属性，避免二次运行失败
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf <<EOF
# 由初始化脚本生成
nameserver ${DNS1}
nameserver ${DNS2}
options timeout:2 attempts:3
EOF
    # 防止 NetworkManager 覆盖
    chattr +i /etc/resolv.conf 2>/dev/null || true
    log_info "DNS 配置完成"
}

# -------------------- 配置时区与时间同步 --------------------
configure_chrony() {
    log_info "正在配置 chrony 时间同步..."
    timedatectl set-timezone Asia/Shanghai
    systemctl enable --now chronyd
    log_info "时区设为 Asia/Shanghai，chronyd 已启动"
}

# -------------------- 配置国内yum源 --------------------
configure_yum_repos() {
    log_info "正在配置国内 yum 源（阿里云镜像）..."
    local REPO_FILE="/etc/yum.repos.d/centos.aliyun.repo"

    # [Bug1 修复] 备份并移除原有 repo 文件（mv 而非 cp），确保旧源被禁用
    mkdir -p /etc/yum.repos.d/backup
    for f in /etc/yum.repos.d/*.repo; do
        [[ -f "$f" ]] && mv "$f" /etc/yum.repos.d/backup/ 2>/dev/null || true
    done

    cat > "${REPO_FILE}" <<'EOF'
[baseos]
name=CentOS Stream 9 - BaseOS - Aliyun Mirror
baseurl=https://mirrors.aliyun.com/centos-stream/9-stream/BaseOS/x86_64/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
enabled=1

[appstream]
name=CentOS Stream 9 - AppStream - Aliyun Mirror
baseurl=https://mirrors.aliyun.com/centos-stream/9-stream/AppStream/x86_64/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
enabled=1

[crb]
name=CentOS Stream 9 - CRB - Aliyun Mirror
baseurl=https://mirrors.aliyun.com/centos-stream/9-stream/CRB/x86_64/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
enabled=1
EOF

    dnf clean all
    dnf makecache
    log_info "yum 源已切换为阿里云镜像"
}

# -------------------- 下载必要组件 --------------------
install_packages() {
    log_info "正在安装必要组件..."
    dnf install -y epel-release 2>/dev/null || true
    dnf install -y "${PACKAGES[@]}"
    log_info "组件安装完成"
}

# -------------------- 优化系统设置 --------------------
optimize_system() {
    log_info "正在优化系统设置..."

    # [Bug4 修复] 先检查是否已存在，避免重复追加
    if ! grep -q '# 初始化脚本添加' /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf <<'EOF'
# 初始化脚本添加
*  soft  nofile  65535
*  hard  nofile  65535
*  soft  nproc   65535
*  hard  nproc   65535
EOF
    else
        log_info "limits.conf 已包含初始化配置，跳过追加"
    fi

    # 内核参数优化（用 > 覆盖，天然幂等）
    cat > /etc/sysctl.d/99-init-optimize.conf <<'EOF'
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.ip_local_port_range = 1024 65535
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
vm.swappiness = 10
EOF
    sysctl --system &>/dev/null

    log_info "系统优化完成"
}

# -------------------- 输出配置摘要 --------------------
print_summary() {
    echo ""
    echo "============================================"
    echo "       CentOS 9 初始化配置摘要"
    echo "============================================"
    echo " 网卡:         ${NET_INTERFACE}"
    echo " 静态IP:       ${STATIC_IP}"
    echo " 网关:         ${GATEWAY}"
    echo " DNS:          ${DNS1}, ${DNS2}"
    echo " 防火墙:       已关闭 (masked)"
    echo " SELinux:      已禁用"
    echo " 时区:         Asia/Shanghai"
    echo " yum源:        阿里云镜像"
    echo " 已安装组件:   ${PACKAGES[*]}"
    echo "============================================"
    echo ""
    log_info "所有配置完成！建议重启系统以使 SELinux 配置完全生效。"
}

# ===================== 主流程 =====================
main() {
    echo ""
    echo "====== CentOS 9 一键初始化脚本 ======"
    echo ""

    check_root

    disable_firewall
    disable_selinux
    configure_yum_repos
    install_packages
    configure_static_ip
    configure_dns
    configure_chrony
    optimize_system
    print_summary
}

main "$@"