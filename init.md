host_name="node1"
ip_address="192.168.25.130/24"
ip_gateway="192.168.25.2"
ip_dns="8.8.8.8,114.114.114.114"

# 获取当前网卡名称
iface=$(ip route | awk '/default/ {print $5}')
[ -z "$iface" ] && iface=$(ip a | grep 'state UP' | awk '{print $2}' | sed 's/://')

# 配置源
mkdir -p /etc/yum.repos.d/backup
mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ &>/dev/null

cat >/etc/yum.repos.d/openEuler_x86_64.repo<<EOF
[OS]
name=openEuler-20.03-LTS-OS
baseurl=http://repo.openeuler.org/openEuler-20.03-LTS/OS/x86_64/
enabled=1
gpgcheck=1
gpgkey=http://repo.openeuler.org/openEuler-20.03-LTS/OS/x86_64/RPM-GPG-KEY-openEuler

[everything]
name=openEuler-20.03-LTS-everything
baseurl=http://repo.openeuler.org/openEuler-20.03-LTS/everything/x86_64/
enabled=1
gpgcheck=1
gpgkey=http://repo.openeuler.org/openEuler-20.03-LTS/everything/x86_64/RPM-GPG-KEY-openEuler

[EPOL]
name=openEuler-20.03-LTS-EPOL
baseurl=http://repo.openeuler.org/openEuler-20.03-LTS/EPOL/x86_64/
enabled=1
gpgcheck=1
gpgkey=http://repo.openeuler.org/openEuler-20.03-LTS/EPOL/x86_64/RPM-GPG-KEY-openEuler

EOF

cat >/etc/yum.repos.d/huaweiyun.repo<<EOF

[OS]
name=openEuler OS
baseurl=https://repo.huaweicloud.com/openeuler/openEuler-20.03-LTS/OS/x86_64/
enabled=1
gpgcheck=0

[everything]
name=openEuler everything
baseurl=https://repo.huaweicloud.com/openeuler/openEuler-20.03-LTS/everything/x86_64/
enabled=1
gpgcheck=0

[EPOL]
name=openEuler EPOL
baseurl=https://repo.huaweicloud.com/openeuler/openEuler-20.03-LTS/EPOL/x86_64/
enabled=1
gpgcheck=0

EOF



echo  "=============华为+openEuler 20.03 LTS 官方源配置成功============="

sleep 2


# 配置主机名
hostnamectl set-hostname $host_name

echo  "===========主机名修改成功============="

# 命令行路径提示
grep -q "export PS1=" /etc/profile || cat >> /etc/profile <<'EOF'
export PS1='[$(whoami)@$(hostname) $PWD]\$ '
EOF

#source /etc/profile

echo  "===========命令行路径修改成功============="


# 1. 关闭防火墙服务
#systemctl stop firewalld
# 2. 禁止防火墙开机自启
#systemctl disable firewalld

# 防火墙firewall添加放行http https ssh的规则并执行重启防火墙
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-service=ssh
firewall-cmd --reload


echo  "===========防火墙规则修改成功============="


#清理 iptables
#iptables -F


# 临时关闭
setenforce 0
# 永久关闭
sed -i -r 's/^SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config

echo  "===========关闭selinux成功============="

sleep 2


# 配置dns服务器

cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 114.114.114.114
EOF

echo "==========配置dns服务器成功==========="


timedatectl set-timezone Asia/Shanghai
yum install -y chrony &>/dev/null
systemctl enable chronyd --now
chronyc sources

echo  "===========配置时间同步成功（亚洲上海）============="


echo  "===========安装常用软件工具============="

# 安装常用软件工具
yum install -y vim net-tools wget  tree  &>/dev/null

echo  "===========常用软件安装成功============="


echo  "===========重置uuid============="

# 配置新的uuid（为克隆机准备）
# 这是centos9

# 确保 uuidgen 命令可用
which uuidgen &>/dev/null || yum install -y uuidgen &>/dev/null
sed -r -i "s#^uuid=.*#uuid=$(uuidgen)#g" /etc/NetworkManager/system-connections/${iface}.nmconnection

# 这是centos7
#sed -r -i "s#^BOOTPROTO=.*#BOOTPROTO=static#g" /etc/sysconfig/network-scripts/ifcfg-${iface}
#sed -r -i "s#^UUID=.*#UUID=$(uuidgen)#g" /etc/sysconfig/network-scripts/ifcfg-${iface}


# 配置ip，网关
nmcli connection modify ${iface} ipv4.method manual ipv4.addresses ${ip_address} ipv4.gateway ${ip_gateway} ipv4.dns ${ip_dns} autoconnect yes
# 重载+重启网卡
nmcli connection reload && nmcli connection down ${iface} && nmcli connection up ${iface}

echo  "===========静态ip配置成功============="

echo "请手动执行一下=======source /etc/profile=========以完成配置"
