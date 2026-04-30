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
if [ "\$PAM_TYPE" != "open_session" ]; then
    exit 0
fi
ip=\$PAM_RHOST
date=\$(date +"%e %b %Y, %a %r")
name=\$PAM_USER
curl -s -X POST "$webhook_url" \
    -H "Content-Type: application/json" \
    -d "{
    \"msgtype\": \"markdown\",
    \"markdown\": {
        \"content\": \"登录提醒\\\\n> 登录用户: \$name\\\\n> 客户端IP: \$ip\\\\n> 登录时间: \$date\"
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
