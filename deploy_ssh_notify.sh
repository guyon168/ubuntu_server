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

# 固定配置（修改为通用路径，避免ubuntu用户不存在的问题）
SCRIPT_PATH="/usr/local/bin/ssh_login_notify.sh"
PAM_CONFIG="/etc/pam.d/sshd"
CONFIG_LINE="session    optional    pam_exec.so $SCRIPT_PATH"

echo -e "\033[33m⏳ 正在创建通知脚本...\033[0m"
# 关键修复：EOF前加\，避免变量提前插值；企微消息格式适配
cat > "$SCRIPT_PATH" << \EOF
#!/bin/bash
# 仅在SSH登录会话创建时执行
if [ "$PAM_TYPE" != "open_session" ]; then
    exit 0
fi

# 1. 基础登录信息（PAM环境变量，登录时动态获取）
ip="$PAM_RHOST"
# 兼容无远程IP的场景（如本地登录）
if [ -z "$ip" ]; then
    ip="localhost/本地登录"
fi
date="$(date +"%Y-%m-%d %H:%M:%S")"
name="$PAM_USER"

# 2. 获取服务器公网IP（登录时动态获取，而非部署时）
# 方式1：公网API（国内兼容）
server_public_ip="$(curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null || curl -fsSL --max-time 3 http://icanhazip.com 2>/dev/null)"
# 方式2：内网IP兜底
if [ -z "$server_public_ip" ]; then
    server_public_ip="$(ip -4 addr | grep -E 'inet (?!127.0.0.1)' | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | head -1)"
fi
# 方式3：主机名兜底
if [ -z "$server_public_ip" ]; then
    server_public_ip="$(hostname -f)"
fi

# 3. 推送企业微信消息（适配企微Markdown格式）
# 企微Markdown换行需用\n，且JSON需严格转义
content="### SSH登录提醒
> 服务器公网IP：$server_public_ip
> 登录用户：$name
> 客户端IP：$ip
> 登录时间：$date"

curl -s -X POST "$webhook_url" \
    -H "Content-Type: application/json" \
    -d '{
    "msgtype": "markdown",
    "markdown": {
        "content": "'"${content}"'"
    }
}' > /dev/null 2>&1
EOF

# 替换子脚本中的webhook_url（因为EOF加了\，需手动替换）
sed -i "s|\$webhook_url|$webhook_url|g" "$SCRIPT_PATH"

# 授权（确保执行权限）
chmod +x "$SCRIPT_PATH"
echo -e "\033[32m✅ 通知脚本创建完成：$SCRIPT_PATH\033[0m"

# 配置 PAM（避免重复添加）
echo -e "\033[33m⏳ 正在配置 PAM sshd...\033[0m"
if ! grep -qxF "$CONFIG_LINE" "$PAM_CONFIG"; then
    # 追加配置，避免覆盖原有内容
    echo "$CONFIG_LINE" >> "$PAM_CONFIG"
    echo -e "\033[32m✅ PAM 配置添加成功\033[0m"
else
    echo -e "\033[33mℹ️ PAM 配置已存在，跳过\033[0m"
fi

# 重启 SSH（兼容不同Ubuntu版本）
echo -e "\033[33m⏳ 正在重启 SSH 服务...\033[0m"
if systemctl restart sshd > /dev/null 2>&1; then
    echo -e "\033[32m✅ SSH 服务重启完成\033[0m"
else
    service ssh restart > /dev/null 2>&1
    echo -e "\033[32m✅ SSH 服务重启完成（兼容模式）\033[0m"
fi

echo ""
echo -e "\033[32m=============================================\033[0m"
echo -e "\033[32m🎉 部署全部完成！\033[0m"
echo -e "\033[32m✅ 测试：重新登录 SSH 即可收到企微通知\033[0m"
echo -e "\033[33m⚠️  注意：若收不到通知，请检查服务器能否访问公网\033[0m"
echo -e "\033[32m=============================================\033[0m"
