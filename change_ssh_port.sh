#!/bin/bash

# SSH端口修改脚本
# 功能：安全地修改SSH服务端口，包含备份、检查、测试等完整流程
# 优化：出错打印详情、自动回滚、不直接崩溃
# 版本：2.0

# 关闭严格退出，改用手动错误处理（解决一出错就停、不打印问题）
set -uo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
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

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以root用户运行"
        exit 1
    fi
}

# 检查端口是否有效
check_port_valid() {
    local port=$1
    if ! [[ $port =~ ^[0-9]+$ ]]; then
        log_error "端口必须是数字"
        return 1
    fi
    if (( port < 1 || port > 65535 )); then
        log_error "端口必须在1-65535范围内"
        return 1
    fi
    if (( port < 1024 )); then
        log_warning "选择的是特权端口(<1024)，确保你了解风险"
    fi
    return 0
}

# 检查端口是否被占用
check_port_in_use() {
    local port=$1
    if ss -tuln | grep -q ":${port}\b"; then
        log_error "端口 ${port} 已被占用"
        return 1
    fi
    return 0
}

# 备份SSH配置
backup_sshd_config() {
    local config_file="/etc/ssh/sshd_config"
    local backup_file="/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"
    
    if [[ -f $config_file ]]; then
        cp "$config_file" "$backup_file"
        log_success "SSH配置已备份到: $backup_file"
        echo "$backup_file"
        return 0
    else
        log_error "找不到SSH配置文件: $config_file"
        return 1
    fi
}

# 获取当前SSH端口
get_current_port() {
    local port=$(/usr/sbin/sshd -T 2>/dev/null | grep "^port " | awk '{print $2}' || echo "22")
    echo "$port"
}

# 修改SSH配置
modify_sshd_config() {
    local new_port=$1
    local config_file="/etc/ssh/sshd_config"
    
    # 先移除所有Port配置（注释或未注释的）
    sed -i '/^[[:space:]]*Port[[:space:]]/d' "$config_file"
    
    # 在合适位置添加新的Port配置
    if grep -q "^ListenAddress" "$config_file"; then
        sed -i "/^ListenAddress/i Port $new_port" "$config_file"
    else
        sed -i "1i Port $new_port" "$config_file"
    fi
    
    # 验证配置
    if ! /usr/sbin/sshd -t; then
        log_error "SSH配置验证失败，请检查配置"
        return 1
    fi
    
    log_success "SSH配置已更新为端口: $new_port"
    return 0
}

# 处理SELinux
configure_selinux() {
    local new_port=$1
    
    if ! command -v semanage &> /dev/null; then
        log_info "SELinux工具未安装，跳过SELinux配置"
        return 0
    fi
    
    if ! sestatus | grep -q "Current mode.*enforcing"; then
        log_info "SELinux未处于enforcing模式，跳过SELinux配置"
        return 0
    fi
    
    log_info "配置SELinux允许端口 $new_port..."
    
    # 检查端口是否已在SSH端口类型中
    if semanage port -l | grep -q "ssh_port_t.*${new_port}\b"; then
        log_info "SELinux已允许端口 $new_port"
        return 0
    fi
    
    # 添加端口
    if semanage port -a -t ssh_port_t -p tcp "$new_port"; then
        log_success "SELinux已配置允许端口 $new_port"
    else
        log_warning "SELinux配置可能需要手动调整"
    fi
}

# 处理防火墙
configure_firewall() {
    local new_port=$1
    
    # 检查ufw
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        log_info "配置UFW防火墙..."
        ufw allow "$new_port/tcp"
        log_success "UFW已允许端口 $new_port"
        return 0
    fi
    
    # 检查firewalld
    if command -v firewall-cmd &> /dev/null && firewall-cmd --state &> /dev/null; then
        log_info "配置firewalld防火墙..."
        firewall-cmd --permanent --add-port="${new_port}/tcp"
        firewall-cmd --reload
        log_success "firewalld已允许端口 $new_port"
        return 0
    fi
    
    log_info "未检测到活动的防火墙(ufw/firewalld)，跳过防火墙配置"
    log_warning "请确保云服务商安全组已放行端口 $new_port"
}

# 停止ssh.socket（如果存在）
stop_ssh_socket() {
    if systemctl list-unit-files | grep -q "ssh.socket"; then
        log_info "检测到ssh.socket，正在停止并禁用..."
        systemctl stop ssh.socket || true
        systemctl disable ssh.socket || true
        log_success "ssh.socket已停止并禁用"
    fi
}

# 重启SSH服务
restart_sshd() {
    log_info "正在重启SSH服务..."
    
    if systemctl restart sshd; then
        sleep 2
        if systemctl is-active --quiet sshd; then
            log_success "SSH服务重启成功"
            return 0
        fi
    fi
    
    log_error "SSH服务启动失败"
    return 1
}

# 验证新端口是否监听
verify_port_listening() {
    local port=$1
    local max_attempts=10
    local attempt=1
    
    log_info "验证端口 $port 是否正在监听..."
    
    while (( attempt <= max_attempts )); do
        if ss -tuln | grep -q ":${port}\b"; then
            log_success "端口 $port 正在监听"
            return 0
        fi
        log_info "等待端口启动... (${attempt}/${max_attempts})"
        sleep 1
        (( attempt++ ))
    done
    
    log_error "端口 $port 未能在预期时间内启动监听"
    return 1
}

# 回滚函数
rollback() {
    local backup_file=$1
    log_warning "=================================================="
    log_warning "执行失败，正在自动回滚SSH配置..."
    log_warning "=================================================="
    
    if [[ -n $backup_file && -f $backup_file ]]; then
        cp "$backup_file" "/etc/ssh/sshd_config"
        log_success "配置已从备份恢复"
        
        systemctl restart sshd || true
        sleep 2
        if systemctl is-active --quiet sshd; then
            log_success "SSH服务已恢复正常"
        else
            log_warning "SSH服务恢复失败，请手动修复"
        fi
    else
        log_error "没有可用的备份文件，无法自动回滚"
    fi

    log_error "脚本执行失败！"
    exit 1
}

# 主函数
main() {
    local new_port=${1:-}
    
    echo "========================================="
    echo "       SSH 端口修改脚本 v2.0"
    echo "========================================="
    echo
    
    # 检查root
    check_root
    
    # 获取当前端口
    local current_port=$(get_current_port)
    log_info "当前SSH端口: $current_port"
    
    # 如果没有提供端口，提示输入
    if [[ -z $new_port ]]; then
        read -p "请输入新的SSH端口 [默认: 2039]: " input_port
        new_port=${input_port:-2039}
    fi
    
    # 验证端口
    if ! check_port_valid "$new_port"; then
        exit 1
    fi
    
    if [[ $new_port -eq $current_port ]]; then
        log_warning "新端口与当前端口相同，无需修改"
        exit 0
    fi
    
    # 检查端口占用
    if ! check_port_in_use "$new_port"; then
        exit 1
    fi
    
    echo
    log_info "准备将SSH端口从 $current_port 修改为 $new_port"
    read -p "确认继续? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log_info "用户取消操作"
        exit 0
    fi
    echo
    
    # 备份配置
    local backup_file=""
    backup_file=$(backup_sshd_config)
    if [[ $? -ne 0 || -z $backup_file ]]; then
        log_error "备份失败，终止操作"
        exit 1
    fi
    
    # ==================== 核心优化：错误捕获 + 自动回滚 ====================
    trap 'rollback "$backup_file"' SIGINT SIGTERM ERR

    # 修改配置
    modify_sshd_config "$new_port" || exit 1
    
    # 配置SELinux
    configure_selinux "$new_port"
    
    # 配置防火墙
    configure_firewall "$new_port"
    
    # 停止ssh.socket
    stop_ssh_socket
    
    # 重启SSH服务
    restart_sshd || exit 1
    
    # 验证端口监听
    verify_port_listening "$new_port" || exit 1
    
    # 成功：清除回滚陷阱
    trap - SIGINT SIGTERM ERR
    
    echo
    echo "========================================="
    log_success "SSH端口修改完成！"
    echo "========================================="
    echo
    echo "📋 修改摘要："
    echo "   旧端口: $current_port"
    echo "   新端口: $new_port"
    echo "   配置备份: $backup_file"
    echo
    echo "⚠️  重要提示："
    echo "   1. 不要关闭当前会话！"
    echo "   2. 新开终端测试：ssh -p $new_port user@服务器IP"
    echo "   3. 确认能登录再关闭当前窗口"
    echo "   4. 云服务器必须在安全组放行 $new_port 端口！"
    echo
}

# 运行主函数
main "$@"
