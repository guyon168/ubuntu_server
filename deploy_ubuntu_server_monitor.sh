#!/bin/bash
set -euo pipefail

# 统一放在用户家目录，兼容所有系统，普通用户有权限
BASE_DIR="$HOME/ubuntu/scripts"
PY_FILE="${BASE_DIR}/server_monitor.py"
CRON_LOG="${BASE_DIR}/cron_run.log"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
err()  { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

# 第一步：强制创建目录，确保一定存在
info "创建脚本目录：${BASE_DIR}"
mkdir -p "${BASE_DIR}"

clear
echo "============================================="
echo "  服务器监控一键部署（兼容所有系统+完整版PY）"
echo "============================================="

# 1. 输入企微 Webhook
read -p "请粘贴企业微信Webhook完整地址：" WEBHOOK
if [[ ! "${WEBHOOK}" =~ ^https://qyapi.weixin.qq.com ]]; then
    err "Webhook 格式错误，必须是企业微信机器人链接"
fi

# 2. 输入整点时间
read -p "请输入每天推送整点(0-23，如6=早上6点)：" H
if ! [[ "${H}" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
    err "时间必须是 0-23 之间整数"
fi

CRON_TIME="0 ${H} * * *"
CRON_CMD="cd ${BASE_DIR} && python3 server_monitor.py >> ${CRON_LOG} 2>&1"

# 3. 自动适配 yum / apt 安装依赖
info "检测系统包管理器并安装依赖..."
if command -v apt &>/dev/null; then
    sudo apt update -y
    sudo apt install python3-psutil python3-requests -y
elif command -v yum &>/dev/null; then
    sudo yum install python3-psutil python3-requests -y
else
    err "不支持当前系统，请手动安装：python3-psutil python3-requests"
fi

# 4. 写入你原版完整未删减的 server_monitor.py
info "写入完整版监控脚本 server_monitor.py"
cat > "${PY_FILE}" << 'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
服务器状态监控脚本 - 纯美观样式版
✅ 仅优化企业微信展示格式
✅ 所有数据动态获取，无任何硬编码任务/进程
✅ 表格 + 代码块包裹，和截图风格完全一致
✅ 新增：抓取 docker exec qronos-app pm2 列表
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


def get_server_ip():
    """获取服务器 公网IP地址"""
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
    """获取系统运行时间"""
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
    """获取宿主机 PM2 状态"""
    try:
        result = subprocess.run(['pm2', 'jlist'], capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            return json.loads(result.stdout)
    except:
        pass
    return []


def get_docker_qronos_pm2():
    """新增：获取 docker exec -it qronos-app pm2 list 进程"""
    try:
        # 用jlist输出json，方便解析
        cmd = ["docker", "exec", "qronos-app", "pm2", "jlist"]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout)
    except Exception as e:
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
    """动态识别重要服务，不硬编码任何名称"""
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
    """读取crontab，并且把注释作为任务名称"""
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
    """生成美观报告"""
    r = []
    system = get_system_info()
    cpu = get_cpu_info()
    mem = get_memory_info()
    disk = get_disk_info()
    services = get_running_services()
    crontab = get_crontab_list()
    pm2 = get_pm2_status()
    chrome = has_chrome_running()
    # 新增获取docker容器内pm2
    docker_qronos_pm2 = get_docker_qronos_pm2()

    # ====================== 标题 ======================
    r.append("**🖥️ 服务器状态完整报告**")
    r.append("")

    # ====================== 系统性能 ======================
    load1 = cpu['load_avg'][0]
    mem_percent = mem['percent']
    disk_percent = disk['percent']

    if load1 < 0.7:
        perf_tag = "优秀 ✅"
    elif load1 < 1.5:
        perf_tag = "良好 🟢"
    elif load1 < 3:
        perf_tag = "一般 ⚠️"
    else:
        perf_tag = "高负载 🔴"

    if mem_percent < 70:
        mem_status = "✅ 正常"
    elif mem_percent < 90:
        mem_status = "⚠️ 警告"
    else:
        mem_status = "🔴 危险"

    if disk_percent < 70:
        disk_status = "✅ 正常"
    elif disk_percent < 90:
        disk_status = "⚠️ 警告"
    else:
        disk_status = "🔴 危险"

    if load1 < 1:
        load_status = "✅ 空闲"
    elif load1 < 2:
        load_status = "⚠️ 偏高"
    else:
        load_status = "🔴 过载"

    r.append(f"📊 系统性能（{perf_tag}）")
    r.append("```")
    r.append("| 指标            | 数值                          | 状态     |")
    r.append("|-----------------|-----------------------|----------|")

    uptime = get_uptime()
    r.append(f"| ⏱️ 运行时间      | {uptime:12}                  | 稳定     |")

    load_str = f"{cpu['load_avg'][0]:.2f}, {cpu['load_avg'][1]:.2f}, {cpu['load_avg'][2]:.2f}"
    r.append(f"| 📈 系统负载      | {load_str:20}              | {load_status} |")

    r.append(f"| 🧠 内存使用      | {mem['used_gb']}Gi / {mem['total_gb']}Gi ({mem_percent:.0f}%) | {mem_status} |")
    r.append(f"| 💾 磁盘使用      | {disk['used_gb']}G / {disk['total_gb']}G ({disk_percent:.0f}%)     | {disk_status} |")
    r.append("```")
    r.append("")

    # ====================== 运行服务 ======================
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

    # ====================== Chrome 状态 ======================
    r.append("🌐 Chrome 浏览器状态")
    if chrome:
        r.append("⚠️  发现 Chrome/Chromium 进程正在运行")
    else:
        r.append("✅ 无 Chrome 进程运行")
    r.append("")

    # ====================== 定时任务 ======================
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

    # ====================== 宿主机 PM2 ======================
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

    # ====================== 新增：Docker qronos-app 内部 PM2 ======================
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

    # ====================== 服务器信息 ======================
    r.append(f"📍 服务器地址：**{system['ip']}**")
    r.append(f"✅ 报告生成时间：{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    r.append("")

    return "\n".join(r)


def send_to_wechat(webhook, content):
    try:
        payload = {
            "msgtype": "markdown",
            "markdown": {"content": content}
        }
        requests.post(webhook, json=payload, timeout=15)
    except:
        pass


def main():
    WEBHOOK = "__WEBHOOK_PLACEHOLDER__"
    report = generate_report()
    send_to_wechat(WEBHOOK, report)
    print("已推送至企微")


if __name__ == "__main__":
    main()
PYEOF

# 5. 自动替换里面的 Webhook 占位符为你输入的地址
sed -i "s|__WEBHOOK_PLACEHOLDER__|${WEBHOOK}|g" "${PY_FILE}"
chmod +x "${PY_FILE}"
info "完整版监控脚本写入并配置完成"

# 6. 去重添加定时任务
if crontab -l 2>/dev/null | grep -Fq "${CRON_CMD}"; then
    warn "定时任务已存在，无需重复添加"
else
    (crontab -l 2>/dev/null; echo "${CRON_TIME} ${CRON_CMD}") | crontab -
    info "定时任务添加成功：每天 ${H}:00 自动推送"
fi

# 7. 立即测试推送一次
info "正在测试推送，请查看企业微信消息..."
cd "${BASE_DIR}" && python3 server_monitor.py

echo -e "\n${GREEN}==================== 部署完成 ====================${NC}"
echo "脚本目录：${BASE_DIR}"
echo "监控脚本：${PY_FILE}"
echo "定时运行日志：${CRON_LOG}"
echo "手动执行测试：cd ${BASE_DIR} && python3 server_monitor.py"
echo "查看定时任务：crontab -l"
echo -e "${GREEN}==================================================${NC}"
