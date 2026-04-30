本仓库包含一系列面向 Ubuntu 服务器的自动化运维脚本，旨在简化服务器初始化、SSH 安全配置、登录监控等常见操作，所有脚本支持**一键执行**，无需手动修改配置（部分支持交互式配置）。

## 脚本列表

| 脚本名称 | 功能说明 | 适用场景 |
| --- | --- | --- |
| `change\_ssh\_port.sh `| 一键修改 SSH 端口（自动配置防火墙 + 重启 SSH 服务） | 服务器初始化、提升 SSH 安全性 |
| `ubuntu_2fa_install.sh` | Ubuntu 服务器安装2fa一键部署|
| `deploy\_ssh\_notify.sh` | SSH 登录监控与通知（登录时触发企微通知） | 服务器安全审计、异常登录告警 |

## 快速使用（一键执行）

### 1\. 一键修改 SSH 端口


```bash
# 下载脚本+赋权+执行（交互式输入新端口）
curl -fsSL https://raw.githubusercontent.com/guyon168/ubuntu_server/main/change_ssh_port.sh -o change_ssh_port.sh && \
sudo chmod +x change_ssh_port.sh && \
sudo ./change_ssh_port.sh

# 非交互式执行（直接指定端口，例如 2024）
curl -fsSL https://raw.githubusercontent.com/guyon168/ubuntu_server/main/change_ssh_port.sh -o change_ssh_port.sh && \
sudo chmod +x change_ssh_port.sh && \
sudo ./change_ssh_port.sh 2024
```

### 2\. 一键为 Ubuntu 服务器安装2fa


```bash
# 1. 下载
curl -O https://raw.githubusercontent.com/guyon168/ubuntu_server/main/ubuntu_2fa_install.sh
sudo chmod +x ubuntu_2fa_install.sh
sudo ./ubuntu_2fa_install.sh
```

### 3\. 一键部署 SSH 登录通知



```bash
# 下载脚本+赋权+执行（自动配置 PAM 触发通知）
curl -fsSL https://raw.githubusercontent.com/guyon168/ubuntu_server/main/deploy_ssh_notify.sh -o deploy_ssh_notify.sh && \
sudo chmod +x deploy_ssh_notify.sh && \
sudo ./deploy_ssh_notify.sh
```

## 详细说明

### 1\. 脚本执行前提

- 服务器系统：Ubuntu 18.04/20.04/22.04（其他 Debian 系系统可兼容）
- 网络要求：服务器可访问 GitHub（若无法访问，可替换为 `raw.fastgit.org` 镜像地址）
- 权限要求：必须使用 `sudo` 执行（脚本涉及系统配置，需 root 权限）

### 2\. 常见问题解决

#### 问题 1：curl 下载失败（提示 Connection refused）



```bash
# 替换为 FastGit 镜像地址（国内服务器推荐）
# 以 SSH 登录通知脚本为例：
curl -fsSL https://raw.fastgit.org/guyon168/ubuntu_server/main/deploy_ssh_notify.sh -o deploy_ssh_notify.sh && \
sudo chmod +x deploy_ssh_notify.sh && \
sudo ./deploy_ssh_notify.sh
```

#### 问题 2：脚本执行后无效果

1. 检查脚本是否下载完整：
	bash
	运行
	```bash
	head -5 deploy_ssh_notify.sh  # 正常应显示 #!/bin/bash 开头
	```
2. 检查执行权限：
	bash
	运行
	```bash
	ls -l deploy_ssh_notify.sh  # 正常应显示 -rwxr-xr-x 权限
	```
3. 查看系统日志（以 SSH 通知为例）：
	bash
	运行
	```bash
	grep sshd /var/log/auth.log
	grep ssh_login_notify /var/log/syslog
	```

#### 问题 3：SSH 端口修改后无法登录

- 先通过控制台 / 物理机登录服务器，检查防火墙：

	```bash
	ufw status  # 确认新端口已放行
	```
- 恢复默认端口（若需回滚）：

	
	```bash
	sudo sed -i 's/Port .*/Port 22/' /etc/ssh/sshd_config && sudo systemctl restart sshd
	```

### 3\. 自定义配置（以 SSH 登录通知为例）

脚本默认使用钉钉机器人通知，如需修改为邮件 / Telegram 通知：

1. 编辑脚本：

	```bash
	sudo vim deploy_ssh_notify.sh
	```
2. 找到 `NOTIFY_CONTENT` 下方的通知逻辑，替换为对应渠道的 API 调用：
	- 邮件通知：
		bash
		运行
		```bash
		# 先安装依赖：sudo apt install mailutils
		echo "$NOTIFY_CONTENT" | mail -s "SSH 登录提醒" your-email@example.com
		```
		- Telegram 通知：
		bash
		运行
		```bash
		TELEGRAM_BOT_TOKEN="你的机器人Token"
		TELEGRAM_CHAT_ID="你的聊天ID"
		curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
		  -d "chat_id=$TELEGRAM_CHAT_ID&text=$NOTIFY_CONTENT"
		```

## 安全说明

1. 所有脚本仅修改必要的系统配置，无冗余操作；
2. 建议执行前先查看脚本内容，确认无恶意逻辑：
	bash
	运行
	```bash
	curl -fsSL https://raw.githubusercontent.com/guyon168/ubuntu_server/main/deploy_ssh_notify.sh | cat
	```
3. 脚本执行后会保留操作日志（`/var/log/` 目录下），可随时审计。
