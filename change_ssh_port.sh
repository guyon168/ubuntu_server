#!/bin/bash

# SSH端口修改脚本
# 支持：正常修改端口 / -r 自动从最新备份回滚
# 版本：3.0

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}
log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}
log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}
log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "必须用root/sudo运行"
        exit 1
    fi
}

check_port_valid() {
    local port=$1
    if ! [[ $port =~ ^[0-9]+$ ]]; then
        log_error "端口必须是数字"
        return 1
    fi
    if (( port < 1 || port > 65535 )); then
        log_error "端口范围 1-65535"
        return 1
    fi
    return 0
}

check_port_in_use() {
    local port=$1
    if ss -tuln | grep -q ":${port}\b"; then
        log_error "端口 $port 已被占用"
        return 1
    fi
    return 0
}

backup_sshd_config() {
    local config_file="/etc/ssh/sshd_config"
    local backup_file="/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$config_file" "$backup_file"
    log_success "备份完成：$backup_file"
    echo "$backup_file"
}

get_current_port() {
    local port=$(/usr/sbin/sshd -T 2>/dev/null | grep "^port " | awk '{print $2}' || echo "22")
    echo "$port"
}

modify_sshd_config() {
    local new_port=$1
    local config_file="/etc/ssh/sshd_config"
    sed -i '/^[[:space:]]*Port[[:space:]]/d' "$config_file"
    if grep -q "^ListenAddress" "$config_file"; then
        sed -i "/^ListenAddress/i Port $new_port" "$config_file"
    else
        sed -i "1i Port $new_port" "$config_file"
    fi
    if ! /usr/sbin/sshd -t; then
        log_error "SSH配置无效"
        return 1
    fi
}

configure_selinux() {
    local new_port=$1
    if ! command -v semanage &>/dev/null; then return 0; fi
    if ! sestatus | grep -q "enforcing"; then return 0; fi
    if ! semanage port -l | grep -q "ssh_port_t.*${new_port}\b"; then
        semanage port -a -t ssh_port_t -p tcp "$new_port" 2>/dev/null
    fi
}

configure_firewall() {
    local new_port=$1
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "$new_port/tcp"
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        firewall-cmd --permanent --add-port="${new_port}/tcp"
        firewall-cmd --reload
    fi
}

stop_ssh_socket() {
    if systemctl list-unit-files | grep -q "ssh.socket"; then
        systemctl stop ssh.socket && systemctl disable ssh.socket 2>/dev/null
    fi
}

restart_sshd() {
    systemctl restart sshd
    sleep 2
    if ! systemctl is-active --quiet sshd; then
        log_error "SSH启动失败"
        return 1
    fi
}

verify_port_listening() {
    local port=$1
    for ((i=1; i<=10; i++)); do
        if ss -tuln | grep -q ":${port}\b"; then
            return 0
        fi
        sleep 1
    done
    log_error "端口未监听"
    return 1
}

# ==================== 回滚函数（核心修复） ====================
rollback() {
    local latest_backup=$(ls -t /etc/ssh/sshd_config.backup.* 2>/dev/null | head -1)
    if [[ -z $latest_backup || ! -f $latest_backup ]]; then
        log_error "未找到任何SSH备份文件，无法回滚"
        exit 1
    fi

    log_warning "=================================================="
    log_warning "正在从最新备份回滚：$latest_backup"
    log_warning "=================================================="

    cp "$latest_backup" /etc/ssh/sshd_config
    systemctl restart sshd
    sleep 2

    if systemctl is-active --quiet sshd; then
        log_success "✅ 回滚成功！SSH已恢复正常"
    else
        log_error "❌ 回滚后SSH启动失败，请手动修复"
    fi
    exit 0
}

# ==================== 参数解析（修复 -r 报错） ====================
parse_args() {
    if [[ $1 == "-r" || $1 == "--rollback" ]]; then
        check_root
        rollback
    fi
}

# ==================== 主流程 ====================
main() {
    # 优先解析参数
    parse_args "$@"

    local new_port=${1:-}
    echo "========================================="
    echo "       SSH 端口修改工具"
    echo "========================================="

    check_root
    local current_port=$(get_current_port)
    log_info "当前端口：$current_port"

    if [[ -z $new_port ]]; then
        read -p "请输入新SSH端口 [默认：2039]: " input_port
        new_port=${input_port:-2039}
    fi

    if ! check_port_valid "$new_port"; then exit 1; fi
    if [[ $new_port -eq $current_port ]]; then
        log_warning "端口相同，无需修改"
        exit 0
    fi
    if ! check_port_in_use "$new_port"; then exit 1; fi

    read -p "确定修改? (y/N): " confirm
    [[ ! $confirm =~ ^[Yy]$ ]] && { log_info "已取消"; exit 0; }

    local backup_file=$(backup_sshd_config)
    trap 'cp "$backup_file" /etc/ssh/sshd_config && systemctl restart sshd; log_error "执行失败，已自动回滚"; exit 1' ERR

    modify_sshd_config "$new_port"
    configure_selinux "$new_port"
    configure_firewall "$new_port"
    stop_ssh_socket
    restart_sshd
    verify_port_listening "$new_port"

    trap - ERR

    echo -e "\n========================================="
    log_success "✅ SSH端口修改完成！"
    echo "========================================="
    echo "旧端口：$current_port"
    echo "新端口：$new_port"
    echo "备份文件：$backup_file"
    echo -e "\n⚠️  请新开终端测试连接，再关闭当前窗口！\n"
}

main "$@"
