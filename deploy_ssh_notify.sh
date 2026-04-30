#!/bin/bash
# SSH 登录企业微信通知 - 一键部署脚本 (Ubuntu专用)
# 支持交互式输入 Webhook，支持远程一键 curl 执行

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[31m❌ 错误：请使用 sudo / root 运行！\033[0m"
    exit 1
fi

clear
echo -e "\033[36m=============================================\033[0m"
echo -e "\033[36m   SSH 登录企业微信通知 - 一键部署工具        \033[0m"
echo -e "\033[36m=============================================\033[0m"
echo ""

# 交互式输入企微 Webhook
read -p "👉 请输入你的企业微信机器人 Webhook 地址：" webhook_url
if [ -z "$webhook_url" ]; then
    echo -e "\033[31m❌ Webhook 地址不能为空，退出！\033[0m"
    exit 1
fi
echo -e "\033[32m✅ Webhook 已接收\033[0m"
echo ""

# 固定配置
SCRIPT_PATH="/home/ubuntu/ssh_login_notify.sh"
PAM_CONFIG="/etc/pam.d/sshd"
CONFIG_LINE="session    optional    pam_exec.so $SCRIPT_PATH"

echo -e "\033[33m⏳ 正在创建通知脚本...\033[0m"
# 写入通知脚本（自动带入用户输入的 Webhook）
cat > "$SCRIPT_PATH" << EOF
#!/bin/bash
if [ "$PAM_TYPE" != "open_session" ]; then
    exit 0
fi

# 1. 基础登录信息
ip=$PAM_RHOST
date=$(date +"%e %b %Y, %a %r")
name=$PAM_USER

# 2. 获取服务器公网IP（优先），失败则取内网IP/主机名
# 方式1：通过公网API获取（推荐，多平台兼容）
server_public_ip=$(curl -fsSL --max-time 3 http://icanhazip.com 2>/dev/null || curl -fsSL --max-time 3 http://ifconfig.me 2>/dev/null)
# 方式2：若公网API访问失败，取服务器内网IP（选第一个非回环地址）
if [ -z "$server_public_ip" ]; then
    server_public_ip=$(ip -4 addr | grep -E 'inet (?!127.0.0.1)' | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | head -1)
fi
# 方式3：若仍获取失败，取主机名兜底
if [ -z "$server_public_ip" ]; then
    server_public_ip=$(hostname -f)
fi

# 3. 推送钉钉消息（包含服务器公网IP）
curl -s -X POST "$webhook_url" \
    -H "Content-Type: application/json" \
    -d "{
    \"msgtype\": \"markdown\",
    \"markdown\": {
        \"content\": \"登录提醒\\\\n> 服务器公网IP: $server_public_ip\\\\n> 登录用户: $name\\\\n> 客户端IP: $ip\\\\n> 登录时间: $date\"
    }
}"
EOF

# 授权
chmod +x "$SCRIPT_PATH"
echo -e "\033[32m✅ 通知脚本创建完成：$SCRIPT_PATH\033[0m"

# 配置 PAM
echo -e "\033[33m⏳ 正在配置 PAM  sshd...\033[0m"
if ! grep -qxF "$CONFIG_LINE" "$PAM_CONFIG"; then
    echo "$CONFIG_LINE" >> "$PAM_CONFIG"
    echo -e "\033[32m✅ PAM 配置添加成功\033[0m"
else
    echo -e "\033[33mℹ️ PAM 配置已存在，跳过\033[0m"
fi

# 重启 SSH
echo -e "\033[33m⏳ 正在重启 SSH 服务...\033[0m"
systemctl restart sshd
echo -e "\033[32m✅ SSH 服务重启完成\033[0m"

echo ""
echo -e "\033[32m=============================================\033[0m"
echo -e "\033[32m🎉 部署全部完成！\033[0m"
echo -e "\033[32m✅ 测试：重新登录 SSH 即可收到企微通知\033[0m"
echo -e "\033[32m=============================================\033[0m"
echo ""
