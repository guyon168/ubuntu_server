#!/bin/bash
# Ubuntu 服务器监控一键部署脚本
# 目录固定：/ubuntu/scripts
# 严格错误捕获 + 自动日志记录

# 严格模式
set -euo pipefail

# 日志路径
LOG_FILE="/var/log/monitor_deploy.log"
SCRIPT_BASE="/ubuntu/scripts"
PY_FILE="${SCRIPT_BASE}/server_monitor.py"
CRON_LOG="${SCRIPT_BASE}/monitor_cron_run.log"

# 错误捕获函数
error_exit() {
    local code=$1
    local line=$2
    echo -e "\n============================================="
    echo -e "❌ 部署脚本执行失败"
    echo -e "📍 错误行号：${line}"
    echo -e "🔴 退出码：${code}"
    echo -e "📄 详细日志：${LOG_FILE}"
    echo -e "=============================================\n"
    exit ${code}
}

# 捕获异常、错误行号
trap 'error_exit $? $LINENO' ERR

# 所有输出同时写入日志
exec >> "${LOG_FILE}" 2>&1
echo "====================================================="
echo "部署开始时间：$(date '+%Y-%m-%d %H:%M:%S')"
echo "====================================================="

# 颜色定义（仅终端可见，日志不存颜色）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}
warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}
err() {
    echo -e "${RED}[ERROR] $1${NC}"
}

# 必须root执行
if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 身份执行：sudo -i 再运行此脚本"
    exit 1
fi

clear
echo "============================================="
echo "     Ubuntu 服务器监控一键部署工具"
echo "============================================="

# 1. 输入企微 Webhook
read -p "请输入企业微信机器人 Webhook 地址：" WEBHOOK
if [[ ! "${WEBHOOK}" =~ qyapi.weixin.qq.com ]]; then
    err "Webhook 地址格式不正确！"
    exit 1
fi

# 2. 输入每天整点小时
read -p "请输入每天推送整点时间(0-23，如6=早上6点)：" PUSH_HOUR
if ! [[ "${PUSH_HOUR}" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
    err "时间必须是 0-23 的整数！"
    exit 1
fi
CRON_RULE="0 ${PUSH_HOUR} * * *"
CRON_EXEC="cd ${SCRIPT_BASE} && python3 server_monitor.py >> ${CRON_LOG} 2>&1"

# 3. 创建目录
info "创建目录 ${SCRIPT_BASE}"
mkdir -p "${SCRIPT_BASE}"

# 4. 安装依赖
info "更新软件源并安装 python3-psutil python3-requests"
apt update -y
apt install python3-psutil python3-requests -y

# 5. 生成 server_monitor.py
info "生成监控脚本 server_monitor.py"
cat > "${PY_FILE}" << 'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
服务器状态监控脚本
支持：系统负载/内存/磁盘/运行服务/Chrome/定时任务/宿主机PM2/Docker qronos-app内PM2
自动推送企业微信
"""

import os
import sys
import time
import socket
import platform
import subprocess
import psutil
import requests
import json
from datetime import datetime

WEBHOOK_URL = "__WEBHOOK__"

def get_server_ip():
    try:
        resp = requests.get('https://api.ipify.org', timeout=3)
        if resp.status_code == 200:
            return resp.text.strip()
    except:
        pass
    try:
        resp = requests.get('https://icanhazip.com', timeout=3)
        if resp.status_code == 200:
            return resp.text.strip()
    except:
        pass
    return "无法获取公网IP"

def get_uptime():
    boot_time = psutil.boot_time()
    now = time.time()
    uptime_seconds = now - boot_time
    days = int(uptime_seconds // 86400)
    hours = int((uptime_seconds % 86400) // 3600)
    if days > 0:
        return f"{days}天{hours}小时"
    elif hours > 0:
        return f"{hours}小时"
    else:
        return "刚刚启动"

def get_pm2_status():
    try:
        result = subprocess.run(['pm2', 'jlist'], capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            return json.loads(result.stdout)
    except:
        pass
    return []

def get_docker_qronos_pm2():
    try:
        cmd = ["docker", "exec", "qronos-app", "pm2", "jlist"]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if res.returncode == 0 and res.stdout.strip():
            return json.loads(res.stdout)
    except:
        pass
    return None

def get_system_info():
    uname = platform.uname()
    return {
        'hostname': socket.gethostname(),
        'ip': get_server_ip(),
        'system': uname.system,
    }

def get_cpu_info():
    cpu_percent = psutil.cpu_percent(interval=0.5)
    load_avg = psutil.getloadavg() if hasattr(psutil, 'getloadavg') else (0,0,0)
    return {
        'load_avg': load_avg,
        'usage': cpu_percent
    }

def get_memory_info():
    mem = psutil.virtual_memory()
    return {
        'total_gb': round(mem.total / 1024**3, 1),
        'used_gb': round(mem.used / 1024**3, 1),
        'percent': mem.percent
    }

def get_disk_info():
    try:
        usage = psutil.disk_usage('/')
        return {
            'total_gb': round(usage.total / 1024**3),
            'used_gb': round(usage.used / 1024**3),
            'percent': usage.percent
        }
    except:
        return {'total_gb':0, 'used_gb':0, 'percent':0}

def get_running_services():
    services = []
    seen = set()
    for proc in psutil.process_iter(['name', 'cmdline']):
        try:
            name = proc.info['name'] or ''
            cmd = ' '.join(proc.info['cmdline'] or [])
            full = f"{name} {cmd}".lower()
            if name in seen:
                continue
            label = None
            if 'sshd' in full: label = 'SSH 服务'
            elif 'nginx' in full: label = 'Web 服务'
            elif 'mysql' in full or 'mariadb' in full: label = '数据库'
            elif 'docker' in full or 'containerd' in full: label = '容器服务'
            elif 'pm2' in full: label = '进程管理器'
            elif 'node' in full: label = 'Node 应用'
            elif 'python' in full: label = 'Python 服务'
            elif 'redis' in full: label = '缓存服务'
            elif 'barad' in full: label = '云监控'
            elif 'ydservice' in full: label = '安全组件'
            if label and name not in seen:
                services.append([name, label])
                seen.add(name)
        except:
            continue
    return services[:7]

def has_chrome_running():
    for proc in psutil.process_iter(['name']):
        try:
            name = proc.info['name'].lower()
            if 'chrome' in name or 'chromium' in name:
                return True
        except:
            continue
    return False

def get_crontab_list():
    try:
        res = subprocess.run(['crontab', '-l'], capture_output=True, text=True, timeout=5)
        if res.returncode == 0:
            lines = res.stdout.strip().splitlines()
            tasks = []
            last_comment = ""
            for line in lines:
                line = line.strip()
                if line.startswith("#"):
                    last_comment = line.lstrip("# ").strip()
                    continue
                if not line:
                    continue
                parts = line.split(None,5)
                if len(parts)>=6:
                    time_expr = ' '.join(parts[:5])
                    cmd = parts[5]
                    task_name = last_comment if last_comment else "系统任务"
                    tasks.append([time_expr, cmd, task_name])
                    last_comment = ""
            return tasks
    except:
        pass
    return []

def generate_report():
    r = []
    system = get_system_info()
    cpu = get_cpu_info()
    mem = get_memory_info()
    disk = get_disk_info()
    services = get_running_services()
    crontab = get_crontab_list()
    pm2 = get_pm2_status()
    chrome = has_chrome_running()
    docker_qronos_pm2 = get_docker_qronos_pm2()

    r.append("**🖥️ 服务器状态完整报告**")
    r.append("")

    load1 = cpu['load_avg'][0]
    mem_percent = mem['percent']
    disk_percent = disk['percent']

    perf_tag = "优秀 ✅" if load1 < 0.7 else "良好 🟢" if load1 < 1.5 else "一般 ⚠️" if load1 < 3 else "高负载 🔴"
    mem_status = "✅ 正常" if mem_percent < 70 else "⚠️ 警告" if mem_percent < 90 else "🔴 危险"
    disk_status = "✅ 正常" if disk_percent < 70 else "⚠️ 警告" if disk_percent < 90 else "🔴 危险"
    load_status = "✅ 空闲" if load1 < 1 else "⚠️ 偏高" if load1 < 2 else "🔴 过载"

    r.append(f"📊 系统性能（{perf_tag}）")
    r.append("```")
    r.append("| 指标            | 数值                          | 状态     |")
    r.append("|-----------------|------------------------------|----------|")
    uptime = get_uptime()
    r.append(f"| ⏱️ 运行时间      | {uptime:<22}          | 稳定     |")
    load_str = f"{cpu['load_avg'][0]:.2f}, {cpu['load_avg'][1]:.2f}, {cpu['load_avg'][2]:.2f}"
    r.append(f"| 📈 系统负载      | {load_str} | {load_status} |")
    r.append(f"| 🧠 内存使用      | {mem['used_gb']}Gi / {mem['total_gb']}Gi ({mem_percent:.0f}%) | {mem_status} |")
    r.append(f"| 💾 磁盘使用      | {disk['used_gb']}G / {disk['total_gb']}G ({disk_percent:.0f}%)     | {disk_status} |")
    r.append("```")
    r.append("")

    r.append("📋 当前运行服务")
    r.append("```")
    r.append("| 程序                | 说明            |")
    r.append("|---------------------|-----------------|")
    for name, desc in services:
        r.append(f"| {name:<18} | {desc:<14} |")
    if not services:
        r.append("| （未识别到服务）| -               |")
    r.append("```")
    r.append("")

    r.append("🌐 Chrome 浏览器状态")
    r.append("⚠️  发现 Chrome/Chromium 进程正在运行" if chrome else "✅ 无 Chrome 进程运行")
    r.append("")

    r.append("⏰ 定时任务 (crontab)")
    r.append("```")
    r.append("| 执行时间     | 任务名称                 |")
    r.append("|-------------|--------------------------|")

    def cron_to_human(time_expr):
        parts = time_expr.strip().split()
        if len(parts)!=5:
            return time_expr
        m, h, dom, mon, dow = parts
        if m.startswith("*/"):
            return f"每{m[2:]}分钟"
        elif m=="0" and h.startswith("*/"):
            return f"每{h[2:]}小时"
        elif m=="0" and h!="*" and dom=="*":
            return f"每天{h.zfill(2)}:{m.zfill(2)}"
        elif m!="0" and h!="*":
            return f"每天{h.zfill(2)}:{m.zfill(2)}"
        return "定时任务"

    for time_expr, cmd, task_name in crontab:
        time_str = cron_to_human(time_expr)
        if "stargate" in cmd:
            task_name = "腾讯云stargate守护"
        if len(task_name) > 20:
            task_name = task_name[:18] + ".."
        r.append(f"| {time_str:<11} | {task_name:<22} |")
    if not crontab:
        r.append("| 无定时任务   | -                        |")
    r.append("```")
    r.append("")

    r.append("🚀 宿主机 PM2 管理程序")
    r.append("```")
    r.append("| 应用名称          | 状态        | 运行时间 |")
    r.append("|-------------------|-------------|----------|")
    for app in pm2[:6]:
        name = app.get('name', 'unknown')[:14]
        status = app.get('pm2_env', {}).get('status', 'stopped')
        icon = "✅ online" if status == "online" else "❌ offline"
        r.append(f"| {name:<16} | {icon:10} | -        |")
    if not pm2:
        r.append("| （无PM2应用）| -           | -        |")
    r.append("```")
    r.append("")

    r.append("🐳 Docker qronos-app 容器内 PM2")
    r.append("```")
    r.append("| 应用名称          | 容器内状态   |")
    r.append("|-------------------|--------------|")
    if docker_qronos_pm2 and isinstance(docker_qronos_pm2, list):
        for app in docker_qronos_pm2[:6]:
            name = app.get('name', 'unknown')[:14]
            status = app.get('pm2_env', {}).get('status', 'stopped')
            icon = "✅ 运行中" if status == "online" else "❌ 已停止"
            r.append(f"| {name:<16} | {icon:<12} |")
    else:
        r.append("| 容器不存在/无PM2进程 | -            |")
    r.append("```")
    r.append("")

    r.append(f"📍 服务器地址：**{system['ip']}**")
    r.append(f"✅ 报告生成时间：{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    r.append("")

    return "\n".join(r)

def send_to_wechat(content):
    try:
        payload = {
            "msgtype": "markdown",
            "markdown": {"content": content}
        }
        requests.post(WEBHOOK_URL, json=payload, timeout=15)
    except Exception as e:
        with open("/ubuntu/scripts/monitor_err.log", "a", encoding="utf-8") as f:
            f.write(f"{datetime.now()} 推送异常：{str(e)}\n")

def main():
    report = generate_report()
    send_to_wechat(report)
    print("已推送企业微信监控报告")

if __name__ == "__main__":
    main()
PYEOF

# 替换webhook
sed -i "s|__WEBHOOK__|${WEBHOOK}|g" "${PY_FILE}"
chmod +x "${PY_FILE}"
info "监控脚本写入完成"

# 6. 添加定时任务，去重
info "配置定时任务：每天 ${PUSH_HOUR}:00 自动执行"
if crontab -l 2>/dev/null | grep -Fq "${CRON_EXEC}"; then
    warn "定时任务已存在，无需重复添加"
else
    (crontab -l 2>/dev/null; echo "${CRON_RULE} ${CRON_EXEC}") | crontab -
    info "定时任务添加成功"
fi

# 7. 立即测试运行
info "正在立即测试推送一次，请查看企业微信..."
cd "${SCRIPT_BASE}" && python3 server_monitor.py

echo -e "\n${GREEN}=============================================${NC}"
echo -e "${GREEN} 部署全部完成！${NC}"
echo "脚本路径：${PY_FILE}"
echo "定时日志：${CRON_LOG}"
echo "部署日志：${LOG_FILE}"
echo "查看定时：crontab -l"
echo "手动测试：cd /ubuntu/scripts && python3 server_monitor.py"
echo -e "${GREEN}=============================================${NC}"
