#!/bin/sh

# 确保脚本在遇到错误时退出
set -e

# 检查系统类型，确保在 Alpine 上运行
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" != "alpine" ]; then
        echo "此脚本仅适用于 Alpine 系统。"
        exit 1
    fi
else
    echo "无法确定操作系统类型，请手动安装依赖项。"
    exit 1
fi

# 提示用户输入域名和电子邮件地址
read -p "请输入域名: " DOMAIN
read -p "请输入电子邮件地址: " EMAIL

# 显示选项菜单
echo "请选择要使用的证书颁发机构 (CA):"
echo "1) Let's Encrypt"
echo "2) Buypass"
echo "3) ZeroSSL"
read -p "输入选项 (1, 2, or 3): " CA_OPTION

# 根据用户选择设置CA参数
case $CA_OPTION in
    1)
        CA_SERVER="letsencrypt"
        ;;
    2)
        CA_SERVER="buypass"
        ;;
    3)
        CA_SERVER="zerossl"
        ;;
    *)
        echo "无效选项"
        exit 1
        ;;
esac

# 提示用户是否关闭防火墙
echo "是否关闭防火墙？"
echo "1) 是"
echo "2) 否"
read -p "输入选项 (1 或 2): " FIREWALL_OPTION

# 如果用户选择不关闭防火墙，提示用户是否放行端口
if [ "$FIREWALL_OPTION" -eq 2 ]; then
    echo "是否放行特定端口？"
    echo "1) 是"
    echo "2) 否"
    read -p "输入选项 (1 或 2): " PORT_OPTION

    # 如果用户选择放行端口，提示用户输入端口号
    if [ "$PORT_OPTION" -eq 1 ]; then
        read -p "请输入要放行的端口号: " PORT
    fi
fi

# 安装依赖项、cron，并关闭防火墙或放行端口
apk update
apk upgrade
apk add curl socat git openrc acme.sh

# 启动和启用 crond 服务
rc-update add crond
service crond start

if [ "$FIREWALL_OPTION" -eq 1 ]; then
    # Alpine 系统默认没有防火墙，如果安装了 iptables，可以清除规则
    if command -v iptables >/dev/null 2>&1; then
        iptables -F
        echo "已清除 iptables 规则。"
    else
        echo "iptables 未安装，跳过防火墙步骤。"
    fi
elif [ "$PORT_OPTION" -eq 1 ]; then
    if command -v iptables >/dev/null 2>&1; then
        iptables -A INPUT -p tcp --dport $PORT -j ACCEPT
        echo "已放行端口 $PORT。"
    else
        echo "iptables 未安装，跳过端口放行步骤。"
    fi
fi

# 注册 acme.sh 帐户
acme.sh --register-account -m $EMAIL --server $CA_SERVER

# 申请 SSL 证书
if ! acme.sh --issue --standalone -d $DOMAIN --server $CA_SERVER; then
    echo "证书申请失败，删除已生成的文件和文件夹。"
    rm -f /root/${DOMAIN}.key /root/${DOMAIN}.crt
    acme.sh --remove -d $DOMAIN
    exit 1
fi

# 安装 SSL 证书
acme.sh --installcert -d $DOMAIN \
    --key-file       /root/${DOMAIN}.key \
    --fullchain-file /root/${DOMAIN}.crt

# 提示用户证书已生成
echo "SSL证书和私钥已生成:"
echo "证书: /root/${DOMAIN}.crt"
echo "私钥: /root/${DOMAIN}.key"

# 创建自动续期的脚本
cat << EOF > /root/renew_cert.sh
#!/bin/sh
export PATH="\$HOME/.acme.sh:\$PATH"
acme.sh --renew -d $DOMAIN --server $CA_SERVER
EOF
chmod +x /root/renew_cert.sh

# 创建自动续期的 cron 任务，每天午夜执行一次
(crontab -l 2>/dev/null; echo "0 0 * * * /root/renew_cert.sh > /dev/null 2>&1") | crontab -
