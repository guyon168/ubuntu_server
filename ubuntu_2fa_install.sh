#!/bin/bash
set -euo pipefail

# ===================== 仅需修改这里 =====================
# 填写你要启用2FA的登录用户名
USERNAME="root"
# =========================================================

# 检查是否以root/ sudo执行
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请以 root 或 sudo 执行此脚本"
    exit 1
fi

# 1. 自动获取公网IP
echo -e "\n🌐 自动获取服务器公网IP..."
SERVER_IP=$(curl -s ifconfig.me)
echo "✅ 当前公网IP：$SERVER_IP"

# 2. 自动获取当前SSH真实端口
echo -e "\n🔍 自动读取当前SSH端口..."
SSH_PORT=$(sshd -T 2>/dev/null | grep -E '^port ' | awk '{print $2}')
echo "✅ 当前SSH端口：$SSH_PORT"

echo "==================== 开始部署 SSH 2FA ===================="

# 更新源
echo -e "\n[1/5] 更新系统软件源..."
apt update -y

# 检测安装2FA依赖
echo -e "\n[2/5] 检测并安装 Google Authenticator 依赖..."
if ! dpkg -l | grep -q libpam-google-authenticator; then
    apt install libpam-google-authenticator -y
else
    echo "✅ 已安装 libpam-google-authenticator，跳过安装"
fi

# 生成2FA密钥，自带标签 用户名@公网IP
echo -e "\n[3/5] 为 ${USERNAME}@${SERVER_IP} 生成2FA密钥"
echo "👉 操作提示："
echo "   1. 第一个问题选 y (基于时间令牌)"
echo "   2. 手机Authenticator扫码，名称自动为：${USERNAME}@${SERVER_IP}"
echo "   3. 输入APP6位验证码验证"
echo "   4. 后续所有提问全部选 y"
sudo -u "$USERNAME" google-authenticator -l "${USERNAME}@${SERVER_IP}"

# 配置PAM
echo -e "\n[4/5] 配置 PAM 2FA 认证..."
PAM_CONF="/etc/pam.d/sshd"
PAM_LINE="auth required pam_google_authenticator.so nullok"

if ! grep -qxF "$PAM_LINE" "$PAM_CONF"; then
    echo "$PAM_LINE" >> "$PAM_CONF"
    echo "✅ 已写入2FA PAM配置"
else
    echo "✅ PAM 2FA配置已存在，无需重复写入"
fi

# 校准SSH必要参数
echo -e "\n[5/5] 校准 sshd_config 必要参数..."
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config

# 重启ssh生效
echo -e "\n🔄 重启 SSH 服务生效..."
systemctl restart ssh

echo -e "\n==================== 部署完成 ===================="
echo "✅ SSH 密钥 + 2FA 双因子已配置完毕"
echo "ℹ️ 2FA标识名称：${USERNAME}@${SERVER_IP}"
echo "ℹ️ 当前SSH端口：${SSH_PORT}"
echo "ℹ️ 登录流程：先校验SSH私钥 → 再输入2FA动态验证码"
echo "💡 直接登录命令：ssh -p ${SSH_PORT} ${USERNAME}@${SERVER_IP}"
echo "=================================================="
