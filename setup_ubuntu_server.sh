#!/bin/bash

# =============================================================================
# Interactive Ubuntu Server Setup Script
# Version: 2.0.0
# =============================================================================

set -o pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script configuration
SCRIPT_VERSION="2.0.0"
LOG_DIR="/var/log/server-setup"
LOG_FILE="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S).log"
BACKUP_DIR="/root/server-setup-backups"
AUTO_CONFIRM=false
QUIET_MODE=false
INTERACTIVE_MODE=true

# Installation flags (default: not selected)
INSTALL_APACHE=false
INSTALL_NGINX=false
INSTALL_MYSQL=false
INSTALL_POSTGRESQL=false
INSTALL_REDIS=false
INSTALL_PHP=false
INSTALL_MONGODB=false
INSTALL_MONGODB_DOCKER=false
INSTALL_DOCKER=false
INSTALL_NODEJS=false
INSTALL_CERTBOT=false
INSTALL_TOOLS=false

# Version variables
php_version=""
mongodb_version=""
nodejs_version=""
mongodb_docker_version=""
postgresql_version=""

# =============================================================================
# Utility Functions
# =============================================================================

print_header() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_step() {
    echo -e "${GREEN}▶ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✖ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✔ $1${NC}"
}

prompt_for_input() {
    local prompt="$1"
    local input_variable_name="$2"
    local input_value=""

    while [ -z "$input_value" ]; do
        read -rp "$prompt: " input_value
        if [ -n "$input_value" ]; then
            eval "$input_variable_name=\"$input_value\""
        else
            print_error "Input cannot be empty. Please try again."
        fi
    done
}

prompt_yes_no() {
    local prompt="$1"
    local response
    while true; do
        read -rp "$prompt (y/n): " response
        case "$response" in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer y or n.";;
        esac
    done
}

select_from_menu() {
    local prompt="$1"
    shift
    local options=("$@")
    local selected=0
    local key

    echo -e "\n${CYAN}$prompt${NC}"
    
    for i in "${!options[@]}"; do
        echo "  $((i+1))) ${options[$i]}"
    done
    
    while true; do
        read -rp "Enter your choice (1-${#options[@]}): " key
        if [[ "$key" =~ ^[0-9]+$ ]] && [ "$key" -ge 1 ] && [ "$key" -le "${#options[@]}" ]; then
            selected=$((key-1))
            break
        else
            print_error "Invalid selection. Please enter a number between 1 and ${#options[@]}."
        fi
    done
    
    echo "${options[$selected]}"
}

# =============================================================================
# Logging Functions
# =============================================================================

init_logging() {
    sudo mkdir -p "$LOG_DIR"
    sudo touch "$LOG_FILE"
    sudo chmod 644 "$LOG_FILE"
    echo "=== Server Setup Log - $(date) ===" | sudo tee "$LOG_FILE" > /dev/null
    echo "Script Version: $SCRIPT_VERSION" | sudo tee -a "$LOG_FILE" > /dev/null
    echo "========================================" | sudo tee -a "$LOG_FILE" > /dev/null
}

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | sudo tee -a "$LOG_FILE" > /dev/null
    
    if [ "$QUIET_MODE" = false ]; then
        case "$level" in
            INFO) echo -e "${GREEN}▶ $message${NC}" ;;
            WARN) echo -e "${YELLOW}⚠ $message${NC}" ;;
            ERROR) echo -e "${RED}✖ $message${NC}" ;;
            SUCCESS) echo -e "${GREEN}✔ $message${NC}" ;;
        esac
    fi
}

log_cmd() {
    local cmd="$1"
    echo "[CMD] $cmd" | sudo tee -a "$LOG_FILE" > /dev/null
    eval "$cmd" 2>&1 | sudo tee -a "$LOG_FILE"
    return ${PIPESTATUS[0]}
}

# =============================================================================
# Pre-flight Checks
# =============================================================================

preflight_checks() {
    print_header "Pre-flight System Checks"
    
    local checks_passed=true
    
    # Check if running as root or with sudo capability
    if [ "$EUID" -ne 0 ]; then
        if ! sudo -n true 2>/dev/null; then
            print_error "This script requires root privileges or sudo access."
            print_step "Please run with: sudo $0"
            exit 1
        fi
    fi
    print_success "Privileges: OK (sudo available)"
    
    # Check OS
    if [ ! -f /etc/os-release ]; then
        print_error "Cannot detect OS. This script requires Ubuntu."
        exit 1
    fi
    
    source /etc/os-release
    if [ "$ID" != "ubuntu" ]; then
        print_error "This script is designed for Ubuntu. Detected: $ID"
        print_warning "Proceeding anyway, but some features may not work."
        checks_passed=false
    else
        print_success "Operating System: Ubuntu $VERSION_ID ($VERSION_CODENAME)"
    fi
    
    # Check Ubuntu version (18.04+)
    local version_num=$(echo "$VERSION_ID" | tr -d '.')
    if [ "$version_num" -lt 1804 ]; then
        print_warning "Ubuntu version $VERSION_ID may not be fully supported. Recommended: 20.04+"
    fi
    
    # Check internet connectivity
    print_step "Checking internet connectivity..."
    if ping -c 1 -W 5 8.8.8.8 &> /dev/null; then
        print_success "Internet: Connected"
    elif ping -c 1 -W 5 1.1.1.1 &> /dev/null; then
        print_success "Internet: Connected"
    else
        print_error "No internet connection detected."
        print_warning "Some installations may fail without internet access."
        checks_passed=false
    fi
    
    # Check DNS resolution
    if host google.com &> /dev/null || nslookup google.com &> /dev/null 2>&1; then
        print_success "DNS Resolution: OK"
    else
        print_warning "DNS resolution may have issues."
    fi
    
    # Check disk space (require at least 5GB free on /)
    local free_space_kb=$(df / --output=avail | tail -1 | tr -d ' ')
    local free_space_gb=$((free_space_kb / 1024 / 1024))
    if [ "$free_space_gb" -lt 5 ]; then
        print_warning "Low disk space: ${free_space_gb}GB available (5GB+ recommended)"
        checks_passed=false
    else
        print_success "Disk Space: ${free_space_gb}GB available"
    fi
    
    # Check memory
    local total_mem_mb=$(free -m | awk '/^Mem:/{print $2}')
    local free_mem_mb=$(free -m | awk '/^Mem:/{print $7}')
    if [ "$total_mem_mb" -lt 1024 ]; then
        print_warning "Low memory: ${total_mem_mb}MB total (1GB+ recommended)"
    else
        print_success "Memory: ${total_mem_mb}MB total, ${free_mem_mb}MB available"
    fi
    
    # Check if apt is locked
    if fuser /var/lib/dpkg/lock-frontend &> /dev/null; then
        print_error "APT is locked. Another package manager is running."
        print_warning "Wait for it to finish or run: sudo killall apt apt-get"
        checks_passed=false
    else
        print_success "Package Manager: Available"
    fi
    
    echo ""
    if [ "$checks_passed" = false ]; then
        print_warning "Some pre-flight checks failed. Installation may encounter issues."
        if [ "$AUTO_CONFIRM" = false ]; then
            if ! prompt_yes_no "Continue anyway?"; then
                exit 1
            fi
        fi
    else
        print_success "All pre-flight checks passed!"
    fi
    
    echo ""
}

# =============================================================================
# Backup Functions
# =============================================================================

backup_configs() {
    local backup_timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_path="$BACKUP_DIR/backup-$backup_timestamp"
    
    print_header "Creating Configuration Backup"
    
    sudo mkdir -p "$backup_path"
    
    print_step "Backing up existing configurations..."
    
    # Backup web server configs
    [ -d /etc/apache2 ] && sudo cp -r /etc/apache2 "$backup_path/" 2>/dev/null && print_success "Backed up: /etc/apache2"
    [ -d /etc/nginx ] && sudo cp -r /etc/nginx "$backup_path/" 2>/dev/null && print_success "Backed up: /etc/nginx"
    
    # Backup database configs
    [ -d /etc/mysql ] && sudo cp -r /etc/mysql "$backup_path/" 2>/dev/null && print_success "Backed up: /etc/mysql"
    [ -d /etc/postgresql ] && sudo cp -r /etc/postgresql "$backup_path/" 2>/dev/null && print_success "Backed up: /etc/postgresql"
    [ -f /etc/mongod.conf ] && sudo cp /etc/mongod.conf "$backup_path/" 2>/dev/null && print_success "Backed up: /etc/mongod.conf"
    [ -f /etc/redis/redis.conf ] && sudo cp -r /etc/redis "$backup_path/" 2>/dev/null && print_success "Backed up: /etc/redis"
    
    # Backup PHP configs
    [ -d /etc/php ] && sudo cp -r /etc/php "$backup_path/" 2>/dev/null && print_success "Backed up: /etc/php"
    
    # Create backup info file
    cat << EOF | sudo tee "$backup_path/backup-info.txt" > /dev/null
Backup created: $(date)
Script version: $SCRIPT_VERSION
Ubuntu version: $(lsb_release -ds 2>/dev/null || echo "Unknown")
Hostname: $(hostname)
EOF
    
    print_success "Backup saved to: $backup_path"
    echo "$backup_path"
}

restore_backup() {
    print_header "Restore Configuration Backup"
    
    if [ ! -d "$BACKUP_DIR" ]; then
        print_error "No backups found in $BACKUP_DIR"
        return 1
    fi
    
    # List available backups
    echo -e "${CYAN}Available backups:${NC}"
    local backups=($(ls -1d "$BACKUP_DIR"/backup-* 2>/dev/null | sort -r))
    
    if [ ${#backups[@]} -eq 0 ]; then
        print_error "No backups found."
        return 1
    fi
    
    for i in "${!backups[@]}"; do
        local backup_name=$(basename "${backups[$i]}")
        local backup_date=$(cat "${backups[$i]}/backup-info.txt" 2>/dev/null | head -1 || echo "Unknown date")
        echo "  $((i+1))) $backup_name - $backup_date"
    done
    
    read -rp "Select backup to restore (1-${#backups[@]}): " choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#backups[@]}" ]; then
        local selected_backup="${backups[$((choice-1))]}"
        
        print_warning "This will overwrite current configurations!"
        if prompt_yes_no "Are you sure you want to restore from $selected_backup?"; then
            print_step "Restoring configurations..."
            
            [ -d "$selected_backup/apache2" ] && sudo cp -r "$selected_backup/apache2"/* /etc/apache2/ 2>/dev/null
            [ -d "$selected_backup/nginx" ] && sudo cp -r "$selected_backup/nginx"/* /etc/nginx/ 2>/dev/null
            [ -d "$selected_backup/mysql" ] && sudo cp -r "$selected_backup/mysql"/* /etc/mysql/ 2>/dev/null
            [ -d "$selected_backup/php" ] && sudo cp -r "$selected_backup/php"/* /etc/php/ 2>/dev/null
            
            print_success "Configuration restored from backup."
            print_warning "You may need to restart services for changes to take effect."
        fi
    else
        print_error "Invalid selection."
    fi
}

# =============================================================================
# Command-Line Argument Parsing
# =============================================================================

show_help() {
    echo "Ubuntu Server Setup Script v$SCRIPT_VERSION"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help              Show this help message"
    echo "  -v, --version           Show script version"
    echo "  -y, --yes               Auto-confirm all prompts"
    echo "  -q, --quiet             Minimal output (logs still written)"
    echo "  --status                Show server status and exit"
    echo "  --backup                Create configuration backup and exit"
    echo "  --restore               Restore from backup and exit"
    echo ""
    echo "Installation options:"
    echo "  --apache                Install Apache web server"
    echo "  --nginx                 Install Nginx web server"
    echo "  --mysql                 Install MySQL database"
    echo "  --postgresql            Install PostgreSQL database"
    echo "  --redis                 Install Redis cache server"
    echo "  --php[=VERSION]         Install PHP (e.g., --php=8.3)"
    echo "  --node[=VERSION]        Install Node.js (e.g., --node=20)"
    echo "  --mongodb               Install MongoDB (native)"
    echo "  --mongodb-docker        Install MongoDB via Docker"
    echo "  --docker                Install Docker"
    echo "  --certbot               Install Certbot for SSL"
    echo "  --tools                 Install common tools"
    echo ""
    echo "Quick installation:"
    echo "  --all-apache            Install all with Apache"
    echo "  --all-nginx             Install all with Nginx"
    echo ""
    echo "System options:"
    echo "  --swap[=SIZE]           Setup swap file (e.g., --swap=4G)"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Interactive mode"
    echo "  $0 --nginx --php=8.3 --mysql          # Non-interactive install"
    echo "  $0 --all-nginx -y                     # Full install with Nginx, auto-confirm"
    echo "  $0 --status                           # Check server status"
    echo ""
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                echo "Server Setup Script v$SCRIPT_VERSION"
                exit 0
                ;;
            -y|--yes)
                AUTO_CONFIRM=true
                ;;
            -q|--quiet)
                QUIET_MODE=true
                ;;
            --status)
                show_status
                exit 0
                ;;
            --backup)
                init_logging
                backup_configs
                exit 0
                ;;
            --restore)
                restore_backup
                exit 0
                ;;
            --apache)
                INSTALL_APACHE=true
                INTERACTIVE_MODE=false
                ;;
            --nginx)
                INSTALL_NGINX=true
                INTERACTIVE_MODE=false
                ;;
            --mysql)
                INSTALL_MYSQL=true
                INTERACTIVE_MODE=false
                ;;
            --postgresql)
                INSTALL_POSTGRESQL=true
                INTERACTIVE_MODE=false
                ;;
            --redis)
                INSTALL_REDIS=true
                INTERACTIVE_MODE=false
                ;;
            --php)
                INSTALL_PHP=true
                INTERACTIVE_MODE=false
                ;;
            --php=*)
                INSTALL_PHP=true
                php_version="${1#*=}"
                INTERACTIVE_MODE=false
                ;;
            --node|--nodejs)
                INSTALL_NODEJS=true
                INTERACTIVE_MODE=false
                ;;
            --node=*|--nodejs=*)
                INSTALL_NODEJS=true
                nodejs_version="${1#*=}"
                INTERACTIVE_MODE=false
                ;;
            --mongodb)
                INSTALL_MONGODB=true
                INTERACTIVE_MODE=false
                ;;
            --mongodb-docker)
                INSTALL_MONGODB_DOCKER=true
                INTERACTIVE_MODE=false
                ;;
            --docker)
                INSTALL_DOCKER=true
                INTERACTIVE_MODE=false
                ;;
            --certbot)
                INSTALL_CERTBOT=true
                INTERACTIVE_MODE=false
                ;;
            --tools)
                INSTALL_TOOLS=true
                INTERACTIVE_MODE=false
                ;;
            --all-apache)
                INSTALL_APACHE=true
                INSTALL_MYSQL=true
                INSTALL_PHP=true
                INSTALL_MONGODB_DOCKER=true
                INSTALL_DOCKER=true
                INSTALL_NODEJS=true
                INSTALL_CERTBOT=true
                INSTALL_TOOLS=true
                INTERACTIVE_MODE=false
                ;;
            --all-nginx)
                INSTALL_NGINX=true
                INSTALL_MYSQL=true
                INSTALL_PHP=true
                INSTALL_MONGODB_DOCKER=true
                INSTALL_DOCKER=true
                INSTALL_NODEJS=true
                INSTALL_CERTBOT=true
                INSTALL_TOOLS=true
                INTERACTIVE_MODE=false
                ;;
            --swap)
                setup_swap
                ;;
            --swap=*)
                setup_swap "${1#*=}"
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use --help for usage information."
                exit 1
                ;;
        esac
        shift
    done
}

# =============================================================================
# Status Check Functions
# =============================================================================

show_status() {
    print_header "Server Status Report"
    
    echo -e "${CYAN}System Information:${NC}"
    echo "  Hostname: $(hostname)"
    echo "  OS: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    echo "  Kernel: $(uname -r)"
    echo "  Uptime: $(uptime -p)"
    echo ""
    
    echo -e "${CYAN}Resource Usage:${NC}"
    echo "  CPU Load: $(cat /proc/loadavg | awk '{print $1, $2, $3}')"
    echo "  Memory: $(free -h | awk '/^Mem:/{print $3 " / " $2 " (" int($3/$2*100) "%)"}')"
    echo "  Swap: $(free -h | awk '/^Swap:/{if($2=="0B") print "Not configured"; else print $3 " / " $2}')"
    echo "  Disk (/): $(df -h / | awk 'NR==2{print $3 " / " $2 " (" $5 ")"}')"
    echo ""
    
    echo -e "${CYAN}Services Status:${NC}"
    
    # Web Servers
    check_service_status "apache2" "Apache"
    check_service_status "nginx" "Nginx"
    
    # Databases
    check_service_status "mysql" "MySQL"
    check_service_status "postgresql" "PostgreSQL"
    check_service_status "mongod" "MongoDB"
    check_service_status "redis-server" "Redis"
    
    # PHP-FPM (check multiple versions)
    for phpfpm in /run/php/php*-fpm.sock; do
        if [ -S "$phpfpm" ]; then
            local ver=$(echo "$phpfpm" | grep -oP 'php\K[0-9.]+')
            echo -e "  ${GREEN}●${NC} PHP $ver FPM: running"
        fi
    done 2>/dev/null
    
    # Docker
    check_service_status "docker" "Docker"
    
    # Check Docker containers if Docker is running
    if systemctl is-active --quiet docker 2>/dev/null; then
        local running_containers=$(docker ps -q 2>/dev/null | wc -l)
        local total_containers=$(docker ps -aq 2>/dev/null | wc -l)
        echo "    └─ Containers: $running_containers running / $total_containers total"
    fi
    
    echo ""
    
    # Port usage
    echo -e "${CYAN}Active Ports:${NC}"
    sudo ss -tlnp 2>/dev/null | grep LISTEN | awk '{print $4}' | sort -u | while read port; do
        local service=$(sudo ss -tlnp 2>/dev/null | grep "$port" | awk '{print $NF}' | head -1)
        echo "  $port - $service"
    done | head -15
    
    echo ""
    
    # Installed versions
    echo -e "${CYAN}Installed Versions:${NC}"
    command -v apache2 &>/dev/null && echo "  Apache: $(apache2 -v 2>/dev/null | head -1 | awk '{print $3}')"
    command -v nginx &>/dev/null && echo "  Nginx: $(nginx -v 2>&1 | cut -d'/' -f2)"
    command -v mysql &>/dev/null && echo "  MySQL: $(mysql --version 2>/dev/null | awk '{print $3}')"
    command -v psql &>/dev/null && echo "  PostgreSQL: $(psql --version 2>/dev/null | awk '{print $3}')"
    command -v mongod &>/dev/null && echo "  MongoDB: $(mongod --version 2>/dev/null | head -1 | awk -F'"' '{print $4}')"
    command -v redis-server &>/dev/null && echo "  Redis: $(redis-server --version 2>/dev/null | awk '{print $3}' | cut -d'=' -f2)"
    command -v php &>/dev/null && echo "  PHP: $(php -v 2>/dev/null | head -1 | awk '{print $2}')"
    command -v node &>/dev/null && echo "  Node.js: $(node -v 2>/dev/null)"
    command -v docker &>/dev/null && echo "  Docker: $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
    
    echo ""
}

check_service_status() {
    local service="$1"
    local display_name="$2"
    
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo -e "  ${GREEN}●${NC} $display_name: running"
    elif systemctl is-enabled --quiet "$service" 2>/dev/null; then
        echo -e "  ${RED}●${NC} $display_name: stopped (enabled)"
    elif command -v "$service" &>/dev/null || [ -f "/etc/init.d/$service" ]; then
        echo -e "  ${YELLOW}●${NC} $display_name: installed (disabled)"
    fi
}

# =============================================================================
# Swap Management
# =============================================================================

setup_swap() {
    local swap_size="${1:-auto}"
    
    print_header "Swap Configuration"
    
    # Check existing swap
    local current_swap=$(free -m | awk '/^Swap:/{print $2}')
    if [ "$current_swap" -gt 0 ]; then
        print_warning "Swap is already configured: ${current_swap}MB"
        if [ -f /swapfile ]; then
            echo "  Swap file: /swapfile"
        fi
        swapon --show
        echo ""
        
        if ! prompt_yes_no "Would you like to resize the swap?"; then
            return 0
        fi
        
        print_step "Disabling current swap..."
        sudo swapoff -a
        [ -f /swapfile ] && sudo rm /swapfile
    fi
    
    # Calculate swap size
    local mem_total_mb=$(free -m | awk '/^Mem:/{print $2}')
    local recommended_swap
    
    if [ "$swap_size" = "auto" ]; then
        # Automatic sizing based on RAM
        if [ "$mem_total_mb" -le 2048 ]; then
            recommended_swap=$((mem_total_mb * 2))
        elif [ "$mem_total_mb" -le 8192 ]; then
            recommended_swap=$mem_total_mb
        else
            recommended_swap=8192
        fi
        
        echo -e "${CYAN}System RAM: ${mem_total_mb}MB${NC}"
        echo -e "${CYAN}Recommended swap: ${recommended_swap}MB${NC}"
        echo ""
        
        read -rp "Enter swap size in MB (or press Enter for $recommended_swap): " input_size
        swap_size="${input_size:-$recommended_swap}"
    else
        # Parse size argument (e.g., 4G, 2048M, 2048)
        if [[ "$swap_size" =~ ^([0-9]+)[Gg]$ ]]; then
            swap_size=$((${BASH_REMATCH[1]} * 1024))
        elif [[ "$swap_size" =~ ^([0-9]+)[Mm]?$ ]]; then
            swap_size="${BASH_REMATCH[1]}"
        fi
    fi
    
    # Check available disk space
    local free_space_mb=$(($(df / --output=avail | tail -1) / 1024))
    if [ "$swap_size" -gt "$((free_space_mb - 1024))" ]; then
        print_error "Not enough disk space for ${swap_size}MB swap. Available: ${free_space_mb}MB"
        return 1
    fi
    
    print_step "Creating ${swap_size}MB swap file..."
    sudo fallocate -l "${swap_size}M" /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count="$swap_size" status=progress
    
    print_step "Setting up swap..."
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    
    # Make permanent
    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
    fi
    
    # Optimize swappiness for server
    print_step "Optimizing swap settings..."
    echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swap.conf > /dev/null
    echo 'vm.vfs_cache_pressure=50' | sudo tee -a /etc/sysctl.d/99-swap.conf > /dev/null
    sudo sysctl -p /etc/sysctl.d/99-swap.conf > /dev/null
    
    print_success "Swap configured successfully!"
    free -h | grep -E "Mem:|Swap:"
    echo ""
}

# =============================================================================
# Configuration Functions
# =============================================================================

update_php_config() {
    local setting="$1"
    local value="$2"
    local php_ini="$3"

    if grep -q "^\s*;$setting" "$php_ini"; then
        sudo sed -i "s/^\s*;$setting\s*=.*/$setting = $value/" "$php_ini"
    elif grep -q "^\s*$setting" "$php_ini"; then
        sudo sed -i "s/^\s*$setting\s*=.*/$setting = $value/" "$php_ini"
    else
        echo "$setting = $value" | sudo tee -a "$php_ini" > /dev/null
    fi
}

add_php_extension() {
    local extension_line="extension=$1"
    local php_ini_file="$2"

    if grep -q "^\s*;${extension_line}" "$php_ini_file"; then
        sudo sed -i "s/^\s*;${extension_line}/${extension_line}/" "$php_ini_file"
        print_success "Uncommented extension line in php.ini: $extension_line"
    elif ! grep -Fxq "$extension_line" "$php_ini_file"; then
        echo "$extension_line" | sudo tee -a "$php_ini_file" > /dev/null
        print_success "Extension line added to php.ini: $extension_line"
    else
        print_warning "Extension line already exists in php.ini: $extension_line"
    fi
}

update_mysql_config() {
    local config_file="/etc/mysql/mysql.conf.d/mysqld.cnf"
    local variable_name="$1"
    local value="$2"
    
    if grep -qE "^\s*#\s*$variable_name\b" "$config_file"; then
        sed -i "s/^\s*#\s*\($variable_name\b\)/\1/" "$config_file"
    elif ! grep -qE "^\s*$variable_name\b" "$config_file"; then
        echo "$variable_name = $value" >> "$config_file"
    fi
    
    if grep -qE "^\s*$variable_name\b" "$config_file"; then
        sed -i "s/^\s*$variable_name\s*=.*/$variable_name = $value/" "$config_file"
    fi
    
    echo "MySQL configuration updated: $variable_name = $value"
}

# =============================================================================
# Installation Functions
# =============================================================================

install_apache() {
    print_header "Installing Apache (HTTPD) Web Server"
    
    print_step "Installing Apache..."
    sudo NEEDRESTART_MODE=a apt install apache2 -y
    
    print_step "Setting up firewall..."
    sudo NEEDRESTART_MODE=a apt install ufw -y
    sudo ufw allow 'Apache'
    sudo ufw allow ssh
    sudo ufw allow OpenSSH
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw allow 587/tcp
    sudo ufw allow 465/tcp
    sudo ufw allow 25/tcp
    yes | sudo ufw enable
    
    print_step "Enabling required Apache modules..."
    sudo a2enmod proxy proxy_http proxy_ajp rewrite deflate headers
    sudo a2enmod proxy_balancer proxy_connect proxy_html ssl
    
    sudo systemctl restart apache2
    print_success "Apache (HTTPD) installed successfully!"
}

install_nginx() {
    print_header "Installing Nginx Web Server"
    
    print_step "Installing Nginx..."
    sudo NEEDRESTART_MODE=a apt install nginx -y
    
    print_step "Setting up firewall..."
    sudo NEEDRESTART_MODE=a apt install ufw -y
    sudo ufw allow 'Nginx Full'
    sudo ufw allow ssh
    sudo ufw allow OpenSSH
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw allow 587/tcp
    sudo ufw allow 465/tcp
    sudo ufw allow 25/tcp
    yes | sudo ufw enable
    
    print_step "Creating Nginx configuration directories..."
    sudo mkdir -p /etc/nginx/sites-available
    sudo mkdir -p /etc/nginx/sites-enabled
    
    # Ensure sites-enabled is included in nginx.conf
    if ! grep -q "sites-enabled" /etc/nginx/nginx.conf; then
        sudo sed -i '/http {/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
    fi
    
    sudo systemctl enable nginx
    sudo systemctl start nginx
    print_success "Nginx installed successfully!"
}

install_mysql() {
    print_header "Installing MySQL Server"
    
    prompt_for_input "Enter MySQL superuser username" new_username
    prompt_for_input "Enter MySQL superuser password" new_password
    
    print_step "Installing MySQL..."
    sudo NEEDRESTART_MODE=a apt install mysql-server -y
    sudo mysql -e "SET GLOBAL binlog_expire_logs_seconds = 86400;"
    
    config_file_path="/etc/mysql/mysql.conf.d/mysqld.cnf"
    directive="skip-name-resolve"
    
    if grep -qE "^\s*#\s*$directive\b" "$config_file_path"; then
        sed -i "s/^\s*#\s*\($directive\b\)/\1/" "$config_file_path"
    elif ! grep -qE "^\s*$directive\b" "$config_file_path"; then
        sed -i "/^\[mysqld\]/a $directive" "$config_file_path"
    fi
    
    print_step "Configuring MySQL..."
    update_mysql_config "innodb_buffer_pool_size" "512M"
    update_mysql_config "innodb_log_file_size" "64M"
    update_mysql_config "innodb_file_per_table" "1"
    update_mysql_config "innodb_log_buffer_size" "4M"
    update_mysql_config "max_connections" "300"
    update_mysql_config "slow_query_log" "1"
    update_mysql_config "slow_query_log_file" "/var/log/mysql/mysql-slow.log"
    update_mysql_config "long_query_time" "2"
    update_mysql_config "binlog_expire_logs_seconds" "86400"
    
    print_step "Creating MySQL superuser..."
    sudo mysql -e "CREATE USER '$new_username'@'localhost' IDENTIFIED BY '$new_password';"
    sudo mysql -e "GRANT ALL PRIVILEGES ON *.* TO '$new_username'@'localhost';"
    sudo mysql -e "FLUSH PRIVILEGES;"
    
    sudo systemctl restart mysql
    print_success "MySQL installed successfully!"
}

install_php() {
    print_header "Installing PHP"
    
    # Clean up any broken Apache PHP modules if Apache is not selected
    if [ "$INSTALL_APACHE" = false ]; then
        if [ -d "/etc/apache2/mods-enabled" ]; then
            print_step "Cleaning up broken Apache PHP modules..."
            shopt -s nullglob
            for phpmod in /etc/apache2/mods-enabled/php*.load; do
                if [ -f "$phpmod" ]; then
                    local modname=$(basename "$phpmod" .load)
                    sudo a2dismod "$modname" 2>/dev/null || true
                    print_warning "Disabled orphan Apache module: $modname"
                fi
            done
            shopt -u nullglob
        fi
    fi
    
    # Available PHP versions
    local available_versions=("8.4" "8.3" "8.2" "8.1" "8.0" "7.4" "7.3" "7.2")
    local selected_versions=()
    
    # Ask for installation mode
    echo -e "${CYAN}PHP Installation Mode:${NC}"
    echo "  1) Install single PHP version"
    echo "  2) Install multiple PHP versions"
    read -rp "Enter your choice (1-2): " install_mode
    
    if [ "$install_mode" = "2" ]; then
        # Multiple version selection
        echo ""
        echo -e "${CYAN}Select PHP versions to install (y/n for each):${NC}"
        echo -e "${YELLOW}You can install multiple versions side by side.${NC}\n"
        
        for ver in "${available_versions[@]}"; do
            if prompt_yes_no "Install PHP $ver?"; then
                selected_versions+=("$ver")
            fi
        done
        
        if prompt_yes_no "Add a custom PHP version?"; then
            local custom_ver
            prompt_for_input "Enter custom PHP version (e.g., 7.1)" custom_ver
            selected_versions+=("$custom_ver")
        fi
        
        if [ ${#selected_versions[@]} -eq 0 ]; then
            print_error "No PHP versions selected."
            return 1
        fi
    else
        # Single version selection
        echo ""
        echo -e "${CYAN}Select PHP version to install:${NC}"
        
        for i in "${!available_versions[@]}"; do
            echo "  $((i+1))) PHP ${available_versions[$i]}"
        done
        echo "  $((${#available_versions[@]}+1))) Custom version"
        
        while true; do
            read -rp "Enter your choice (1-$((${#available_versions[@]}+1))): " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$((${#available_versions[@]}+1))" ]; then
                if [ "$choice" -eq "$((${#available_versions[@]}+1))" ]; then
                    prompt_for_input "Enter custom PHP version (e.g., 8.2)" php_version
                    selected_versions+=("$php_version")
                else
                    selected_versions+=("${available_versions[$((choice-1))]}")
                fi
                break
            else
                print_error "Invalid selection."
            fi
        done
    fi
    
    # Show selected versions
    echo ""
    echo -e "${CYAN}PHP versions to install:${NC}"
    for ver in "${selected_versions[@]}"; do
        echo -e "  ${GREEN}✔${NC} PHP $ver"
    done
    echo ""
    
    print_step "Adding PHP repository..."
    yes | sudo add-apt-repository ppa:ondrej/php
    sudo apt update
    
    # Install each selected PHP version
    for ver in "${selected_versions[@]}"; do
        print_header "Installing PHP $ver"
        
        print_step "Installing PHP $ver CLI and FPM..."
        # Install CLI and FPM first (without Apache module dependency)
        sudo NEEDRESTART_MODE=a apt install php$ver-cli php$ver-fpm -y
        
        print_step "Installing PHP $ver modules..."
        sudo NEEDRESTART_MODE=a apt install php$ver-common php$ver-mysql php$ver-xml \
            php$ver-xmlrpc php$ver-curl php$ver-gd php$ver-imagick \
            php$ver-dev php$ver-imap php$ver-mbstring \
            php$ver-opcache php$ver-soap php$ver-zip php$ver-intl \
            php$ver-bcmath -y 2>/dev/null || print_warning "Some modules may not be available for PHP $ver"
        
        # Only install Apache module if Apache is selected
        if [ "$INSTALL_APACHE" = true ]; then
            print_step "Installing Apache PHP $ver module..."
            sudo NEEDRESTART_MODE=a apt install libapache2-mod-php$ver -y 2>/dev/null || true
        else
            # Remove/disable any accidentally installed Apache PHP modules
            if [ -f "/etc/apache2/mods-enabled/php$ver.load" ]; then
                print_step "Disabling Apache PHP $ver module (Apache not selected)..."
                sudo a2dismod php$ver 2>/dev/null || true
            fi
            # Prevent Apache PHP module from being installed as dependency
            sudo apt-mark hold libapache2-mod-php$ver 2>/dev/null || true
        fi
        
        print_step "Starting PHP $ver FPM service..."
        sudo systemctl start php$ver-fpm
        sudo systemctl enable php$ver-fpm
        
        # Configure PHP settings
        local php_ini="/etc/php/$ver/fpm/php.ini"
        local php_fpm="/etc/php/$ver/fpm/pool.d/www.conf"
        
        if [ -f "$php_ini" ]; then
            print_step "Configuring PHP $ver settings..."
            update_php_config "upload_max_filesize" "64M" "$php_ini"
            update_php_config "post_max_size" "64M" "$php_ini"
            update_php_config "memory_limit" "256M" "$php_ini"
            update_php_config "max_execution_time" "600" "$php_ini"
            update_php_config "max_input_time" "600" "$php_ini"
            update_php_config "max_input_vars" "10000" "$php_ini"
            add_php_extension "opcache.so" "$php_ini"
            update_php_config "opcache.enable" "1" "$php_ini"
            update_php_config "opcache.memory_consumption" "128" "$php_ini"
        fi
        
        if [ -f "$php_fpm" ]; then
            update_php_config "pm" "dynamic" "$php_fpm"
            update_php_config "pm.max_children" "6" "$php_fpm"
            update_php_config "pm.start_servers" "2" "$php_fpm"
        fi
        
        sudo systemctl restart php$ver-fpm
        print_success "PHP $ver installed!"
    done
    
    # Set default version
    php_version="${selected_versions[0]}"
    
    if [ ${#selected_versions[@]} -gt 1 ]; then
        echo ""
        echo -e "${CYAN}Select default PHP version for CLI:${NC}"
        for i in "${!selected_versions[@]}"; do
            echo "  $((i+1))) PHP ${selected_versions[$i]}"
        done
        read -rp "Enter choice (1-${#selected_versions[@]}): " def_choice
        if [[ "$def_choice" =~ ^[0-9]+$ ]] && [ "$def_choice" -ge 1 ] && [ "$def_choice" -le "${#selected_versions[@]}" ]; then
            php_version="${selected_versions[$((def_choice-1))]}"
        fi
        
        sudo update-alternatives --set php /usr/bin/php$php_version 2>/dev/null || true
        
        # Create switch script
        print_step "Creating PHP switch script..."
        sudo tee /usr/local/bin/php-switch > /dev/null << 'SWITCHEOF'
#!/bin/bash
VERSION="$1"
if [ -z "$VERSION" ]; then
    echo "Usage: php-switch <version>"
    echo "Current: $(php -v | head -1)"
    exit 1
fi
sudo update-alternatives --set php /usr/bin/php$VERSION 2>/dev/null || { echo "PHP $VERSION not found"; exit 1; }
echo "Switched to PHP $VERSION"
php -v | head -1
SWITCHEOF
        sudo chmod +x /usr/local/bin/php-switch
    fi
    
    # Configure web server
    if [ "$INSTALL_APACHE" = true ]; then
        sudo a2enmod http2 mpm_event proxy_fcgi setenvif
        sudo a2dismod mpm_prefork 2>/dev/null || true
        sudo a2enconf php$php_version-fpm
        sudo systemctl restart apache2
    fi
    
    if [ "$INSTALL_NGINX" = true ]; then
        sudo mkdir -p /etc/nginx/snippets
        for ver in "${selected_versions[@]}"; do
            sudo tee /etc/nginx/snippets/php$ver-fpm.conf > /dev/null << NGINXEOF
location ~ \\.php\$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:/var/run/php/php$ver-fpm.sock;
}
NGINXEOF
        done
        sudo systemctl restart nginx
    fi
    
    # Summary
    echo ""
    print_header "PHP Installation Complete"
    echo -e "${CYAN}Installed versions:${NC}"
    for ver in "${selected_versions[@]}"; do
        echo "  - PHP $ver (socket: /var/run/php/php$ver-fpm.sock)"
    done
    echo -e "${YELLOW}Default CLI:${NC} PHP $php_version"
    if [ ${#selected_versions[@]} -gt 1 ]; then
        echo -e "${YELLOW}Switch CLI:${NC} sudo php-switch <version>"
    fi
    print_success "PHP installation completed!"
}

install_mongodb() {
    print_header "Installing MongoDB"
    
    # Valid MongoDB versions (update this list as new versions are released)
    # Note: 8.2 removed from default options - not yet available for all Ubuntu versions
    local valid_versions=("8.0" "7.0" "6.0" "5.0" "4.4")
    
    # MongoDB version selection
    echo -e "${CYAN}Select MongoDB version to install:${NC}"
    local mongo_versions=("8.0 (Recommended/Latest)" "7.0 (LTS)" "6.0" "5.0" "Custom")
    
    for i in "${!mongo_versions[@]}"; do
        echo "  $((i+1))) MongoDB ${mongo_versions[$i]}"
    done
    
    while true; do
        read -rp "Enter your choice (1-${#mongo_versions[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#mongo_versions[@]}" ]; then
            if [ "$choice" -eq "${#mongo_versions[@]}" ]; then
                echo -e "${YELLOW}Valid MongoDB versions: ${valid_versions[*]}${NC}"
                prompt_for_input "Enter MongoDB version (e.g., 7.0)" mongodb_version
                
                # Validate custom version
                local is_valid=false
                for v in "${valid_versions[@]}"; do
                    if [ "$mongodb_version" = "$v" ]; then
                        is_valid=true
                        break
                    fi
                done
                
                if [ "$is_valid" = false ]; then
                    print_warning "Version $mongodb_version may not be available. Checking..."
                fi
            else
                # Extract version number (remove " (Latest)" suffix if present)
                mongodb_version=$(echo "${mongo_versions[$((choice-1))]}" | awk '{print $1}')
            fi
            break
        else
            print_error "Invalid selection."
        fi
    done
    
    # Detect Ubuntu version for repository
    ubuntu_codename=$(lsb_release -cs)
    
    # Verify the GPG key URL exists before proceeding
    print_step "Verifying MongoDB repository for version $mongodb_version..."
    local gpg_url="https://www.mongodb.org/static/pgp/server-$mongodb_version.asc"
    
    if ! curl -fsSL --head "$gpg_url" >/dev/null 2>&1; then
        print_error "MongoDB version $mongodb_version does not exist or is not available."
        print_warning "Available versions: ${valid_versions[*]}"
        echo ""
        
        # Ask user to select a valid version
        if prompt_yes_no "Would you like to install MongoDB 8.0 (latest stable) instead?"; then
            mongodb_version="8.0"
        else
            print_error "MongoDB installation skipped."
            return 1
        fi
    fi
    
    print_step "Adding MongoDB repository for version $mongodb_version..."
    
    # Remove ALL existing MongoDB GPG keys and list files (not just the current version)
    # This prevents conflicts from leftover repositories of different versions
    sudo rm -f /usr/share/keyrings/mongodb-server-*.gpg
    sudo rm -f /etc/apt/sources.list.d/mongodb-org-*.list
    
    # Import GPG key using the recommended method
    curl -fsSL https://www.mongodb.org/static/pgp/server-$mongodb_version.asc | \
        sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-$mongodb_version.gpg
    
    # Check if GPG key was imported successfully
    if [ ! -f /usr/share/keyrings/mongodb-server-$mongodb_version.gpg ]; then
        print_error "Failed to import MongoDB GPG key."
        return 1
    fi
    
    # Set proper permissions
    sudo chmod 644 /usr/share/keyrings/mongodb-server-$mongodb_version.gpg
    
    # Add the repository
    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-$mongodb_version.gpg ] https://repo.mongodb.org/apt/ubuntu $ubuntu_codename/mongodb-org/$mongodb_version multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-$mongodb_version.list
    
    print_step "Updating package list..."
    if ! sudo apt update 2>&1 | tee /tmp/apt_update.log; then
        # Check if the error is related to MongoDB repository
        if grep -q "NO_PUBKEY\|not signed\|does not have a Release file" /tmp/apt_update.log; then
            print_error "MongoDB $mongodb_version repository is not available for Ubuntu $ubuntu_codename."
            print_warning "This version may not support your Ubuntu release yet."
            
            # Clean up the broken repository
            sudo rm -f /etc/apt/sources.list.d/mongodb-org-$mongodb_version.list
            sudo rm -f /usr/share/keyrings/mongodb-server-$mongodb_version.gpg
            
            # Offer fallback to 8.0
            if [ "$mongodb_version" != "8.0" ]; then
                if prompt_yes_no "Would you like to try MongoDB 8.0 instead?"; then
                    mongodb_version="8.0"
                    # Recursive call with 8.0
                    install_mongodb
                    return $?
                fi
            fi
            
            print_error "MongoDB installation skipped."
            return 1
        fi
    fi
    
    # Check if mongodb-org package is available
    if ! apt-cache show mongodb-org >/dev/null 2>&1; then
        print_error "MongoDB package not found. The version may not support Ubuntu $ubuntu_codename."
        print_warning "Try a different MongoDB version or check https://www.mongodb.com/docs/manual/installation/"
        
        # Clean up
        sudo rm -f /etc/apt/sources.list.d/mongodb-org-$mongodb_version.list
        sudo rm -f /usr/share/keyrings/mongodb-server-$mongodb_version.gpg
        return 1
    fi
    
    print_step "Installing MongoDB..."
    sudo NEEDRESTART_MODE=a apt install mongodb-org -y
    
    if [ $? -ne 0 ]; then
        print_error "MongoDB installation failed."
        return 1
    fi
    
    sudo systemctl start mongod.service
    sudo systemctl enable mongod
    
    # Install PHP MongoDB extension for ALL installed PHP versions
    install_php_mongodb_extension
    
    print_success "MongoDB $mongodb_version installed successfully!"
}

install_php_mongodb_extension() {
    # Find all installed PHP versions
    local installed_php_versions=()
    
    if [ -d /etc/php ]; then
        for php_dir in /etc/php/*/; do
            if [ -d "$php_dir" ]; then
                local ver=$(basename "$php_dir")
                # Check if it's a valid version directory (has fpm or cli)
                if [ -d "/etc/php/$ver/fpm" ] || [ -d "/etc/php/$ver/cli" ]; then
                    installed_php_versions+=("$ver")
                fi
            fi
        done
    fi
    
    # If no PHP versions found, skip
    if [ ${#installed_php_versions[@]} -eq 0 ]; then
        print_warning "No PHP installations found. Skipping MongoDB PHP extension."
        return 0
    fi
    
    print_step "Installing PHP MongoDB extension for ${#installed_php_versions[@]} PHP version(s)..."
    
    # Install MongoDB extension for each PHP version using apt packages (preferred method)
    # This handles different extension directories automatically
    for ver in "${installed_php_versions[@]}"; do
        print_step "Installing MongoDB extension for PHP $ver..."
        
        # Try to install via apt package first (from ondrej/php PPA)
        if sudo apt-get install -y "php$ver-mongodb" 2>/dev/null; then
            print_success "PHP $ver MongoDB extension installed via apt"
        else
            # Fallback: compile with PECL for this specific PHP version
            print_warning "php$ver-mongodb package not available, compiling with PECL..."
            
            # Install dev package for this PHP version if not present
            sudo apt-get install -y "php$ver-dev" 2>/dev/null || true
            
            # Use update-alternatives to switch to this PHP version for PECL
            sudo update-alternatives --set php "/usr/bin/php$ver" 2>/dev/null || true
            sudo update-alternatives --set php-config "/usr/bin/php-config$ver" 2>/dev/null || true
            sudo update-alternatives --set phpize "/usr/bin/phpize$ver" 2>/dev/null || true
            
            # Install via PECL
            sudo NEEDRESTART_MODE=a printf "\n" | pecl install -f mongodb 2>/dev/null || true
            
            # Add extension configuration
            local mods_dir="/etc/php/$ver/mods-available"
            if [ -d "$mods_dir" ] && [ ! -f "$mods_dir/mongodb.ini" ]; then
                echo "extension=mongodb.so" | sudo tee "$mods_dir/mongodb.ini" > /dev/null
                sudo phpenmod -v "$ver" mongodb 2>/dev/null || true
            fi
        fi
        
        # Restart PHP-FPM for this version
        if systemctl is-active --quiet "php$ver-fpm"; then
            sudo systemctl restart "php$ver-fpm"
        fi
    done
    
    # Restore default PHP version if php_version is set
    if [ -n "$php_version" ]; then
        sudo update-alternatives --set php "/usr/bin/php$php_version" 2>/dev/null || true
    fi
    
    print_success "MongoDB PHP extension installed for: ${installed_php_versions[*]}"
}

run_installation() {
    print_header "Starting Installation"
    
    # Clean up any broken MongoDB repositories before apt update
    print_step "Cleaning up invalid repositories..."
    for repo in /etc/apt/sources.list.d/mongodb-org-*.list; do
        if [ -f "$repo" ]; then
            # Test if repo is valid by checking if key exists
            local version=$(echo "$repo" | grep -oP 'mongodb-org-\K[0-9.]+')
            if [ ! -f "/usr/share/keyrings/mongodb-server-$version.gpg" ]; then
                print_warning "Removing broken MongoDB $version repository..."
                sudo rm -f "$repo"
            fi
        fi
    done
    
    print_step "Updating package list..."
    sudo apt update 2>&1 | grep -v "NO_PUBKEY" || true
    
    [ "$INSTALL_DOCKER" = true ] && install_docker
    
    [ "$INSTALL_APACHE" = true ] && install_apache
    [ "$INSTALL_NGINX" = true ] && install_nginx
    [ "$INSTALL_MYSQL" = true ] && install_mysql
    [ "$INSTALL_POSTGRESQL" = true ] && install_postgresql
    [ "$INSTALL_REDIS" = true ] && install_redis
    [ "$INSTALL_PHP" = true ] && install_php
    [ "$INSTALL_MONGODB" = true ] && install_mongodb
    [ "$INSTALL_MONGODB_DOCKER" = true ] && install_mongodb_docker
    [ "$INSTALL_NODEJS" = true ] && install_nodejs
    [ "$INSTALL_CERTBOT" = true ] && install_certbot
    [ "$INSTALL_TOOLS" = true ] && install_tools
    
    # Final restart of services
    print_header "Finalizing Installation"
    
    if [ "$INSTALL_APACHE" = true ]; then
        print_step "Restarting Apache..."
        sudo systemctl restart apache2
    fi
    
    if [ "$INSTALL_NGINX" = true ]; then
        print_step "Restarting Nginx..."
        sudo systemctl restart nginx
    fi
    
    if [ "$INSTALL_PHP" = true ] && [ -n "$php_version" ]; then
        print_step "Restarting PHP-FPM..."
        sudo systemctl restart php$php_version-fpm
    fi
    
    print_step "Cleaning up..."
    sudo apt-get autoremove -y
    sudo apt-get clean
    
    print_header "Installation Complete!"
    echo -e "${GREEN}All selected components have been installed successfully!${NC}\n"
    
    # Show installed versions
    echo -e "${CYAN}Installed versions:${NC}"
    [ "$INSTALL_APACHE" = true ] && echo "  Apache: $(apache2 -v 2>/dev/null | head -1)"
    [ "$INSTALL_NGINX" = true ] && echo "  Nginx: $(nginx -v 2>&1)"
    [ "$INSTALL_MYSQL" = true ] && echo "  MySQL: $(mysql --version 2>/dev/null)"
    [ "$INSTALL_POSTGRESQL" = true ] && echo "  PostgreSQL: $(psql --version 2>/dev/null)"
    [ "$INSTALL_REDIS" = true ] && echo "  Redis: $(redis-server --version 2>/dev/null | awk '{print $3}')"
    [ "$INSTALL_PHP" = true ] && echo "  PHP: $(php -v 2>/dev/null | head -1)"
    [ "$INSTALL_MONGODB" = true ] && echo "  MongoDB: $(mongod --version 2>/dev/null | head -1)"
    [ "$INSTALL_MONGODB_DOCKER" = true ] && echo "  MongoDB (Docker): Running in container"
    [ "$INSTALL_DOCKER" = true ] && echo "  Docker: $(docker --version 2>/dev/null)"
    [ "$INSTALL_NODEJS" = true ] && echo "  Node.js: $(node -v 2>/dev/null)"
    echo ""
}

# =============================================================================
# Interactive Menu Functions
# =============================================================================

show_main_menu() {
    clear
    print_header "Ubuntu Server Setup - Interactive Menu"
    
    echo -e "${CYAN}Select components to install:${NC}\n"
    echo "  1) Apache Web Server"
    echo "  2) Nginx Web Server"
    echo "  3) MySQL Database"
    echo "  4) PostgreSQL Database"
    echo "  5) MongoDB (Native)"
    echo "  6) MongoDB (Docker)"
    echo "  7) Redis"
    echo "  8) PHP"
    echo "  9) Node.js"
    echo "  10) Docker"
    echo "  11) Certbot (SSL)"
    echo "  12) Development Tools"
    echo ""
    echo -e "${CYAN}Quick Install Options:${NC}"
    echo "  A) LAMP Stack (Apache + MySQL + PHP + Tools)"
    echo "  N) LEMP Stack (Nginx + MySQL + PHP + Tools)"
    echo "  C) Custom Selection (multi-select)"
    echo ""
    echo -e "${CYAN}Other Options:${NC}"
    echo "  T) Show Server Status"
    echo "  W) Configure Swap"
    echo "  R) Remove Components"
    echo "  Q) Quit"
    echo ""
    
    # Show current selections if any
    local has_selections=false
    for var in INSTALL_APACHE INSTALL_NGINX INSTALL_MYSQL INSTALL_POSTGRESQL \
               INSTALL_MONGODB INSTALL_MONGODB_DOCKER INSTALL_REDIS INSTALL_PHP \
               INSTALL_NODEJS INSTALL_DOCKER INSTALL_CERTBOT INSTALL_TOOLS; do
        if [ "${!var}" = true ]; then
            has_selections=true
            break
        fi
    done
    
    if [ "$has_selections" = true ]; then
        echo -e "${GREEN}Current selections:${NC}"
        [ "$INSTALL_APACHE" = true ] && echo "  ✔ Apache"
        [ "$INSTALL_NGINX" = true ] && echo "  ✔ Nginx"
        [ "$INSTALL_MYSQL" = true ] && echo "  ✔ MySQL"
        [ "$INSTALL_POSTGRESQL" = true ] && echo "  ✔ PostgreSQL"
        [ "$INSTALL_MONGODB" = true ] && echo "  ✔ MongoDB (Native)"
        [ "$INSTALL_MONGODB_DOCKER" = true ] && echo "  ✔ MongoDB (Docker)"
        [ "$INSTALL_REDIS" = true ] && echo "  ✔ Redis"
        [ "$INSTALL_PHP" = true ] && echo "  ✔ PHP"
        [ "$INSTALL_NODEJS" = true ] && echo "  ✔ Node.js"
        [ "$INSTALL_DOCKER" = true ] && echo "  ✔ Docker"
        [ "$INSTALL_CERTBOT" = true ] && echo "  ✔ Certbot"
        [ "$INSTALL_TOOLS" = true ] && echo "  ✔ Dev Tools"
        echo ""
        echo -e "${YELLOW}Press Enter to proceed with installation, or select more components.${NC}"
        echo ""
    fi
}

show_selection_summary() {
    print_header "Installation Summary"
    
    echo -e "${CYAN}The following components will be installed:${NC}\n"
    
    local count=0
    [ "$INSTALL_APACHE" = true ] && { echo "  • Apache Web Server"; ((count++)); }
    [ "$INSTALL_NGINX" = true ] && { echo "  • Nginx Web Server"; ((count++)); }
    [ "$INSTALL_MYSQL" = true ] && { echo "  • MySQL Database"; ((count++)); }
    [ "$INSTALL_POSTGRESQL" = true ] && { echo "  • PostgreSQL Database"; ((count++)); }
    [ "$INSTALL_MONGODB" = true ] && { echo "  • MongoDB (Native)"; ((count++)); }
    [ "$INSTALL_MONGODB_DOCKER" = true ] && { echo "  • MongoDB (Docker)"; ((count++)); }
    [ "$INSTALL_REDIS" = true ] && { echo "  • Redis"; ((count++)); }
    [ "$INSTALL_PHP" = true ] && { echo "  • PHP"; ((count++)); }
    [ "$INSTALL_NODEJS" = true ] && { echo "  • Node.js"; ((count++)); }
    [ "$INSTALL_DOCKER" = true ] && { echo "  • Docker"; ((count++)); }
    [ "$INSTALL_CERTBOT" = true ] && { echo "  • Certbot (SSL)"; ((count++)); }
    [ "$INSTALL_TOOLS" = true ] && { echo "  • Development Tools"; ((count++)); }
    
    if [ $count -eq 0 ]; then
        echo -e "${YELLOW}  No components selected.${NC}"
        return 1
    fi
    
    echo ""
    echo -e "${CYAN}Total: $count component(s)${NC}\n"
}

custom_selection() {
    print_header "Custom Component Selection"
    
    echo -e "${CYAN}Toggle components (enter number to toggle, 'done' when finished):${NC}\n"
    
    while true; do
        echo "  1) [$([ "$INSTALL_APACHE" = true ] && echo "X" || echo " ")] Apache"
        echo "  2) [$([ "$INSTALL_NGINX" = true ] && echo "X" || echo " ")] Nginx"
        echo "  3) [$([ "$INSTALL_MYSQL" = true ] && echo "X" || echo " ")] MySQL"
        echo "  4) [$([ "$INSTALL_POSTGRESQL" = true ] && echo "X" || echo " ")] PostgreSQL"
        echo "  5) [$([ "$INSTALL_MONGODB" = true ] && echo "X" || echo " ")] MongoDB (Native)"
        echo "  6) [$([ "$INSTALL_MONGODB_DOCKER" = true ] && echo "X" || echo " ")] MongoDB (Docker)"
        echo "  7) [$([ "$INSTALL_REDIS" = true ] && echo "X" || echo " ")] Redis"
        echo "  8) [$([ "$INSTALL_PHP" = true ] && echo "X" || echo " ")] PHP"
        echo "  9) [$([ "$INSTALL_NODEJS" = true ] && echo "X" || echo " ")] Node.js"
        echo "  10) [$([ "$INSTALL_DOCKER" = true ] && echo "X" || echo " ")] Docker"
        echo "  11) [$([ "$INSTALL_CERTBOT" = true ] && echo "X" || echo " ")] Certbot"
        echo "  12) [$([ "$INSTALL_TOOLS" = true ] && echo "X" || echo " ")] Dev Tools"
        echo ""
        
        read -rp "Enter number (or 'done'): " choice
        
        case "$choice" in
            1) [ "$INSTALL_APACHE" = true ] && INSTALL_APACHE=false || INSTALL_APACHE=true ;;
            2) [ "$INSTALL_NGINX" = true ] && INSTALL_NGINX=false || INSTALL_NGINX=true ;;
            3) [ "$INSTALL_MYSQL" = true ] && INSTALL_MYSQL=false || INSTALL_MYSQL=true ;;
            4) [ "$INSTALL_POSTGRESQL" = true ] && INSTALL_POSTGRESQL=false || INSTALL_POSTGRESQL=true ;;
            5) [ "$INSTALL_MONGODB" = true ] && INSTALL_MONGODB=false || INSTALL_MONGODB=true ;;
            6) [ "$INSTALL_MONGODB_DOCKER" = true ] && INSTALL_MONGODB_DOCKER=false || INSTALL_MONGODB_DOCKER=true ;;
            7) [ "$INSTALL_REDIS" = true ] && INSTALL_REDIS=false || INSTALL_REDIS=true ;;
            8) [ "$INSTALL_PHP" = true ] && INSTALL_PHP=false || INSTALL_PHP=true ;;
            9) [ "$INSTALL_NODEJS" = true ] && INSTALL_NODEJS=false || INSTALL_NODEJS=true ;;
            10) [ "$INSTALL_DOCKER" = true ] && INSTALL_DOCKER=false || INSTALL_DOCKER=true ;;
            11) [ "$INSTALL_CERTBOT" = true ] && INSTALL_CERTBOT=false || INSTALL_CERTBOT=true ;;
            12) [ "$INSTALL_TOOLS" = true ] && INSTALL_TOOLS=false || INSTALL_TOOLS=true ;;
            done|Done|DONE) break ;;
            *) print_error "Invalid option" ;;
        esac
        echo ""
    done
}

run_removal() {
    print_header "Remove Components"
    
    echo -e "${CYAN}Select component to remove:${NC}\n"
    echo "  1) Apache"
    echo "  2) Nginx"
    echo "  3) MySQL"
    echo "  4) PostgreSQL"
    echo "  5) MongoDB (Native)"
    echo "  6) MongoDB (Docker)"
    echo "  7) Redis"
    echo "  8) PHP"
    echo "  9) Node.js"
    echo "  10) Docker"
    echo "  11) Certbot"
    echo "  0) Cancel"
    echo ""
    
    read -rp "Enter choice: " rem_choice
    
    case "$rem_choice" in
        1)
            if prompt_yes_no "Remove Apache?"; then
                sudo systemctl stop apache2 2>/dev/null
                sudo apt purge apache2 apache2-utils -y
                sudo apt autoremove -y
                print_success "Apache removed"
            fi
            ;;
        2)
            if prompt_yes_no "Remove Nginx?"; then
                sudo systemctl stop nginx 2>/dev/null
                sudo apt purge nginx nginx-common -y
                sudo apt autoremove -y
                print_success "Nginx removed"
            fi
            ;;
        3)
            if prompt_yes_no "Remove MySQL? WARNING: This will delete all databases!"; then
                sudo systemctl stop mysql 2>/dev/null
                sudo apt purge mysql-server mysql-client -y
                sudo apt autoremove -y
                print_success "MySQL removed"
            fi
            ;;
        4)
            if prompt_yes_no "Remove PostgreSQL? WARNING: This will delete all databases!"; then
                sudo systemctl stop postgresql 2>/dev/null
                sudo apt purge postgresql* -y
                sudo apt autoremove -y
                print_success "PostgreSQL removed"
            fi
            ;;
        5)
            if prompt_yes_no "Remove MongoDB (Native)? WARNING: This will delete all databases!"; then
                sudo systemctl stop mongod 2>/dev/null
                sudo apt purge mongodb-org* -y
                sudo rm -f /etc/apt/sources.list.d/mongodb-org-*.list
                sudo rm -f /usr/share/keyrings/mongodb-server-*.gpg
                sudo apt autoremove -y
                print_success "MongoDB (Native) removed"
            fi
            ;;
        6)
            if prompt_yes_no "Remove MongoDB (Docker)? WARNING: This will delete all data!"; then
                docker stop mongodb 2>/dev/null
                docker rm mongodb 2>/dev/null
                docker volume rm mongodb_data 2>/dev/null
                print_success "MongoDB (Docker) removed"
            fi
            ;;
        7)
            if prompt_yes_no "Remove Redis?"; then
                sudo systemctl stop redis 2>/dev/null
                sudo apt purge redis-server -y
                sudo apt autoremove -y
                print_success "Redis removed"
            fi
            ;;
        8)
            if prompt_yes_no "Remove PHP?"; then
                sudo apt purge php* -y
                sudo apt autoremove -y
                print_success "PHP removed"
            fi
            ;;
        9)
            if prompt_yes_no "Remove Node.js?"; then
                sudo apt purge nodejs -y
                sudo rm -rf /usr/local/lib/node_modules
                sudo apt autoremove -y
                print_success "Node.js removed"
            fi
            ;;
        10)
            if prompt_yes_no "Remove Docker?"; then
                sudo systemctl stop docker 2>/dev/null
                sudo apt purge docker-ce docker-ce-cli containerd.io -y
                sudo apt autoremove -y
                print_success "Docker removed"
            fi
            ;;
        11)
            if prompt_yes_no "Remove Certbot?"; then
                sudo apt purge certbot python3-certbot-* -y
                sudo apt autoremove -y
                print_success "Certbot removed"
            fi
            ;;
        0|"")
            echo "Cancelled"
            ;;
        *)
            print_error "Invalid option"
            ;;
    esac
    
    read -rp "Press Enter to continue..."
}

# Main Script Execution
# =============================================================================

main() {
    # Parse command-line arguments
    parse_args "$@"
    
    # If not interactive mode (CLI args provided), run installation directly
    if [ "$INTERACTIVE_MODE" = false ]; then
        preflight_checks
        show_selection_summary
        if [ "$AUTO_CONFIRM" = true ] || prompt_yes_no "Proceed with installation?"; then
            run_installation
        else
            echo -e "\n${YELLOW}Installation cancelled.${NC}\n"
            exit 0
        fi
        exit 0
    fi
    
    # Interactive mode
    # Check if running as root
    if [ "$EUID" -eq 0 ]; then
        print_warning "Running as root. Some operations might behave differently."
    fi
    
    while true; do
        show_main_menu
        read -rp "Enter your choice: " main_choice
        
        case "$main_choice" in
            1)
                INSTALL_APACHE=true
                ;;
            2)
                INSTALL_NGINX=true
                ;;
            3)
                INSTALL_MYSQL=true
                ;;
            4)
                INSTALL_POSTGRESQL=true
                ;;
            5)
                INSTALL_MONGODB=true
                ;;
            6)
                INSTALL_MONGODB_DOCKER=true
                ;;
            7)
                INSTALL_REDIS=true
                ;;
            8)
                INSTALL_PHP=true
                ;;
            9)
                INSTALL_NODEJS=true
                ;;
            10)
                INSTALL_DOCKER=true
                ;;
            11)
                INSTALL_CERTBOT=true
                ;;
            12)
                INSTALL_TOOLS=true
                ;;
            [Aa])
                INSTALL_APACHE=true
                INSTALL_MYSQL=true
                INSTALL_PHP=true
                INSTALL_MONGODB_DOCKER=true
                INSTALL_DOCKER=true
                INSTALL_NODEJS=true
                INSTALL_CERTBOT=true
                INSTALL_TOOLS=true
                ;;
            [Nn])
                INSTALL_NGINX=true
                INSTALL_MYSQL=true
                INSTALL_PHP=true
                INSTALL_MONGODB_DOCKER=true
                INSTALL_DOCKER=true
                INSTALL_NODEJS=true
                INSTALL_CERTBOT=true
                INSTALL_TOOLS=true
                ;;
            [Cc])
                custom_selection
                ;;
            [Tt])
                show_status
                read -rp "Press Enter to continue..."
                continue
                ;;
            [Ww])
                setup_swap
                read -rp "Press Enter to continue..."
                continue
                ;;
            [Rr])
                run_removal
                continue
                ;;
            [Qq])
                echo -e "\n${YELLOW}Goodbye!${NC}\n"
                exit 0
                ;;
            *)
                print_error "Invalid option. Please try again."
                continue
                ;;
        esac
        
        # If a single component was selected, ask if user wants to add more
        if [[ "$main_choice" =~ ^([1-9]|1[0-2])$ ]]; then
            if prompt_yes_no "Would you like to select additional components?"; then
                continue
            fi
        fi
        
        break
    done
    
    # Run pre-flight checks
    preflight_checks
    
    # Show summary and confirm
    show_selection_summary
    
    if prompt_yes_no "Proceed with installation?"; then
        run_installation
    else
        echo -e "\n${YELLOW}Installation cancelled.${NC}\n"
        exit 0
    fi
}

# Run the main function with all arguments
main "$@"