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
    local valid_versions=("8.2" "8.0" "7.0" "6.0" "5.0" "4.4" "4.2")
    
    # MongoDB version selection
    echo -e "${CYAN}Select MongoDB version to install:${NC}"
    echo -e "${YELLOW}Note: MongoDB 8.2 may not be available for all Ubuntu versions yet.${NC}"
    local mongo_versions=("8.0 (Recommended)" "8.2 (Latest)" "7.0" "6.0" "5.0" "Custom")
    
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
        if prompt_yes_no "Would you like to install MongoDB 8.2 (latest stable) instead?"; then
            mongodb_version="8.2"
        else
            print_error "MongoDB installation skipped."
            return 1
        fi
    fi
    
    print_step "Adding MongoDB repository for version $mongodb_version..."
    
    # Remove any existing MongoDB GPG key and list files for this version
    sudo rm -f /usr/share/keyrings/mongodb-server-$mongodb_version.gpg
    sudo rm -f /etc/apt/sources.list.d/mongodb-org-$mongodb_version.list
    
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
    
    # Install PHP MongoDB extension if PHP is installed
    if [ -n "$php_version" ]; then
        php_ini_file="/etc/php/$php_version/fpm/php.ini"
        print_step "Installing PHP MongoDB driver..."
        add_php_extension "mongodb.so" "$php_ini_file"
        sudo NEEDRESTART_MODE=a printf "\n" | pecl install -f mongodb
        sudo systemctl restart php$php_version-fpm
    fi
    
    print_success "MongoDB $mongodb_version installed successfully!"
}

install_nodejs() {
    print_header "Installing Node.js"
    
    # Node.js version selection
    echo -e "${CYAN}Select Node.js version to install:${NC}"
    local node_versions=("22 (LTS)" "20 (LTS)" "18 (LTS)" "21" "19" "Custom")
    local node_version_numbers=("22" "20" "18" "21" "19")
    
    for i in "${!node_versions[@]}"; do
        echo "  $((i+1))) Node.js ${node_versions[$i]}"
    done
    
    while true; do
        read -rp "Enter your choice (1-${#node_versions[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#node_versions[@]}" ]; then
            if [ "$choice" -eq "${#node_versions[@]}" ]; then
                prompt_for_input "Enter custom Node.js version (e.g., 20.10.0 or just 20)" nodejs_version
            else
                nodejs_version="${node_version_numbers[$((choice-1))]}"
            fi
            break
        else
            print_error "Invalid selection."
        fi
    done
    
    print_step "Installing NVM..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    
    export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    
    print_step "Installing Node.js $nodejs_version..."
    nvm install "$nodejs_version"
    nvm use "$nodejs_version"
    nvm alias default "$nodejs_version"
    
    if prompt_yes_no "Would you like to install PM2 (process manager)?"; then
        print_step "Installing PM2..."
        npm install pm2@latest -g
    fi
    
    print_success "Node.js $nodejs_version installed successfully!"
}

install_certbot() {
    print_header "Installing Certbot (SSL Certificates)"
    
    print_step "Installing Certbot..."
    sudo NEEDRESTART_MODE=a apt install certbot -y
    
    # Install web server specific plugins
    if [ "$INSTALL_APACHE" = true ]; then
        print_step "Installing Certbot Apache plugin..."
        sudo NEEDRESTART_MODE=a apt install python3-certbot-apache -y
    fi
    
    if [ "$INSTALL_NGINX" = true ]; then
        print_step "Installing Certbot Nginx plugin..."
        sudo NEEDRESTART_MODE=a apt install python3-certbot-nginx -y
    fi
    
    # If no web server selected, install both plugins
    if [ "$INSTALL_APACHE" = false ] && [ "$INSTALL_NGINX" = false ]; then
        print_step "Installing Certbot plugins for Apache and Nginx..."
        sudo NEEDRESTART_MODE=a apt install python3-certbot-apache python3-certbot-nginx -y
    fi
    
    sudo certbot plugins
    
    print_step "Setting up auto-renewal cron job..."
    cron_job="0 0,12 * * * certbot renew --quiet --no-self-upgrade"
    (sudo crontab -l 2>/dev/null; echo "$cron_job") | sudo crontab -
    
    print_success "Certbot installed successfully!"
}

install_tools() {
    print_header "Installing Additional Tools"
    
    print_step "Installing common development tools..."
    sudo NEEDRESTART_MODE=a apt install gnupg curl git zip unzip wget htop -y
    
    print_success "Additional tools installed successfully!"
}

install_postgresql() {
    print_header "Installing PostgreSQL"
    
    # Version selection
    echo -e "${CYAN}Select PostgreSQL version to install:${NC}"
    local pg_versions=("16 (Latest)" "15" "14" "13" "12" "Default (OS package)")
    local pg_version_nums=("16" "15" "14" "13" "12" "default")
    
    for i in "${!pg_versions[@]}"; do
        echo "  $((i+1))) PostgreSQL ${pg_versions[$i]}"
    done
    
    while true; do
        read -rp "Enter your choice (1-${#pg_versions[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#pg_versions[@]}" ]; then
            postgresql_version="${pg_version_nums[$((choice-1))]}"
            break
        else
            print_error "Invalid selection."
        fi
    done
    
    if [ "$postgresql_version" = "default" ]; then
        print_step "Installing PostgreSQL from default repository..."
        sudo NEEDRESTART_MODE=a apt install postgresql postgresql-contrib -y
    else
        print_step "Adding PostgreSQL official repository..."
        sudo NEEDRESTART_MODE=a apt install wget gnupg2 -y
        
        # Add PostgreSQL repository
        sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
        wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
        sudo apt update
        
        print_step "Installing PostgreSQL $postgresql_version..."
        sudo NEEDRESTART_MODE=a apt install postgresql-$postgresql_version postgresql-contrib-$postgresql_version -y
    fi
    
    # Start and enable service
    print_step "Starting PostgreSQL service..."
    sudo systemctl start postgresql
    sudo systemctl enable postgresql
    
    # Create superuser
    if prompt_yes_no "Would you like to create a PostgreSQL superuser?"; then
        prompt_for_input "Enter PostgreSQL superuser username" pg_username
        prompt_for_input "Enter PostgreSQL superuser password" pg_password
        
        print_step "Creating PostgreSQL superuser..."
        sudo -u postgres psql -c "CREATE USER $pg_username WITH SUPERUSER CREATEDB CREATEROLE PASSWORD '$pg_password';"
        print_success "User '$pg_username' created successfully!"
    fi
    
    # Configure for remote access (optional)
    if prompt_yes_no "Allow remote connections? (not recommended for production without SSL)"; then
        local pg_conf_dir=$(sudo -u postgres psql -t -P format=unaligned -c 'SHOW config_file' | xargs dirname)
        
        # Update postgresql.conf
        sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" "$pg_conf_dir/postgresql.conf"
        
        # Update pg_hba.conf
        echo "host    all             all             0.0.0.0/0               scram-sha-256" | sudo tee -a "$pg_conf_dir/pg_hba.conf" > /dev/null
        
        # Open firewall
        sudo ufw allow 5432/tcp
        
        sudo systemctl restart postgresql
        print_warning "Remote access enabled. Make sure to secure with SSL in production!"
    fi
    
    print_success "PostgreSQL installed successfully!"
    echo ""
    echo -e "${CYAN}PostgreSQL Information:${NC}"
    echo "  Version: $(psql --version)"
    echo "  Port: 5432"
    echo "  Config: /etc/postgresql/*/main/postgresql.conf"
    echo "  Connect: sudo -u postgres psql"
    echo ""
}

install_redis() {
    print_header "Installing Redis"
    
    # Installation method selection
    echo -e "${CYAN}Select Redis installation method:${NC}"
    echo "  1) Default (OS package)"
    echo "  2) Redis official repository (latest)"
    read -rp "Enter your choice (1-2): " redis_choice
    
    if [ "$redis_choice" = "2" ]; then
        print_step "Adding Redis official repository..."
        curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list > /dev/null
        sudo apt update
    fi
    
    print_step "Installing Redis..."
    sudo NEEDRESTART_MODE=a apt install redis-server -y
    
    # Configure Redis
    print_step "Configuring Redis..."
    local redis_conf="/etc/redis/redis.conf"
    
    # Enable systemd supervision
    sudo sed -i 's/^supervised no/supervised systemd/' "$redis_conf"
    
    # Set max memory (default 256MB)
    if prompt_yes_no "Configure max memory limit?"; then
        read -rp "Enter max memory (e.g., 256mb, 1gb) [256mb]: " redis_maxmem
        redis_maxmem="${redis_maxmem:-256mb}"
        
        if grep -q "^maxmemory " "$redis_conf"; then
            sudo sed -i "s/^maxmemory .*/maxmemory $redis_maxmem/" "$redis_conf"
        else
            echo "maxmemory $redis_maxmem" | sudo tee -a "$redis_conf" > /dev/null
        fi
        
        # Set eviction policy
        if grep -q "^maxmemory-policy " "$redis_conf"; then
            sudo sed -i "s/^maxmemory-policy .*/maxmemory-policy allkeys-lru/" "$redis_conf"
        else
            echo "maxmemory-policy allkeys-lru" | sudo tee -a "$redis_conf" > /dev/null
        fi
    fi
    
    # Set password (optional)
    if prompt_yes_no "Set Redis password? (recommended)"; then
        prompt_for_input "Enter Redis password" redis_password
        
        if grep -q "^requirepass " "$redis_conf"; then
            sudo sed -i "s/^requirepass .*/requirepass $redis_password/" "$redis_conf"
        else
            echo "requirepass $redis_password" | sudo tee -a "$redis_conf" > /dev/null
        fi
        print_success "Redis password set."
    fi
    
    # Allow remote connections (optional)
    if prompt_yes_no "Allow remote connections?"; then
        sudo sed -i 's/^bind 127.0.0.1/bind 0.0.0.0/' "$redis_conf"
        sudo ufw allow 6379/tcp
        print_warning "Remote access enabled. Make sure to set a strong password!"
    fi
    
    # Start service
    print_step "Starting Redis service..."
    sudo systemctl restart redis-server
    sudo systemctl enable redis-server
    
    # Verify installation
    if redis-cli ping 2>/dev/null | grep -q "PONG"; then
        print_success "Redis installed and running!"
    else
        print_success "Redis installed! (May need password for ping)"
    fi
    
    echo ""
    echo -e "${CYAN}Redis Information:${NC}"
    echo "  Version: $(redis-server --version | awk '{print $3}' | cut -d'=' -f2)"
    echo "  Port: 6379"
    echo "  Config: /etc/redis/redis.conf"
    echo "  CLI: redis-cli"
    echo ""
    
    # Install PHP Redis extension if PHP is installed
    if [ -n "$php_version" ]; then
        if prompt_yes_no "Install PHP Redis extension?"; then
            print_step "Installing PHP Redis extension..."
            sudo NEEDRESTART_MODE=a apt install php$php_version-redis -y
            sudo systemctl restart php$php_version-fpm 2>/dev/null || true
            print_success "PHP Redis extension installed!"
        fi
    fi
}

install_docker() {
    print_header "Installing Docker"
    
    # Check if Docker is already installed
    if command -v docker &> /dev/null; then
        print_warning "Docker is already installed."
        docker --version
        if prompt_yes_no "Would you like to reinstall/update Docker?"; then
            print_step "Removing existing Docker installation..."
            sudo apt remove docker docker-engine docker.io containerd runc -y 2>/dev/null || true
        else
            print_success "Keeping existing Docker installation."
            return 0
        fi
    fi
    
    print_step "Installing Docker prerequisites..."
    sudo NEEDRESTART_MODE=a apt install ca-certificates curl gnupg lsb-release -y
    
    print_step "Adding Docker GPG key..."
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    
    print_step "Adding Docker repository..."
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    print_step "Installing Docker Engine..."
    sudo apt update
    sudo NEEDRESTART_MODE=a apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
    
    print_step "Starting Docker service..."
    sudo systemctl start docker
    sudo systemctl enable docker
    
    # Add current user to docker group (if not root)
    if [ "$EUID" -ne 0 ]; then
        print_step "Adding current user to docker group..."
        sudo usermod -aG docker $USER
        print_warning "You may need to log out and back in for group changes to take effect."
    fi
    
    # Verify installation
    if docker --version &> /dev/null; then
        print_success "Docker installed successfully!"
        docker --version
    else
        print_error "Docker installation may have failed. Please check manually."
        return 1
    fi
}

install_mongodb_docker() {
    print_header "Installing MongoDB via Docker"
    
    # Check if Docker is installed
    if ! command -v docker &> /dev/null; then
        print_warning "Docker is not installed. Installing Docker first..."
        install_docker
        if [ $? -ne 0 ]; then
            print_error "Failed to install Docker. Cannot proceed with MongoDB Docker installation."
            return 1
        fi
    fi
    
    # Deployment type selection
    echo -e "${CYAN}Select MongoDB deployment type:${NC}"
    echo "  1) Single Node (simple setup)"
    echo "  2) Replica Set - 3 Nodes (high availability)"
    read -rp "Enter your choice (1-2): " deployment_choice
    
    case "$deployment_choice" in
        2)
            install_mongodb_replica_set
            return $?
            ;;
        *)
            # Continue with single node installation
            ;;
    esac
    
    # MongoDB version selection for Docker
    echo -e "${CYAN}Select MongoDB Docker version to install:${NC}"
    echo -e "${GREEN}Docker images are available for all MongoDB versions!${NC}"
    local mongo_docker_versions=("8 (Latest)" "7" "6" "5" "4.4" "Custom")
    
    for i in "${!mongo_docker_versions[@]}"; do
        echo "  $((i+1))) MongoDB ${mongo_docker_versions[$i]}"
    done
    
    while true; do
        read -rp "Enter your choice (1-${#mongo_docker_versions[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#mongo_docker_versions[@]}" ]; then
            if [ "$choice" -eq "${#mongo_docker_versions[@]}" ]; then
                prompt_for_input "Enter MongoDB version (e.g., 7.0.5)" mongodb_docker_version
            else
                mongodb_docker_version=$(echo "${mongo_docker_versions[$((choice-1))]}" | awk '{print $1}')
            fi
            break
        else
            print_error "Invalid selection."
        fi
    done
    
    # Configuration options
    local mongo_port="27017"
    local mongo_container_name="mongodb"
    local mongo_data_dir="/var/lib/mongodb-docker"
    local mongo_root_user=""
    local mongo_root_pass=""
    
    echo ""
    if prompt_yes_no "Would you like to customize MongoDB Docker configuration?"; then
        read -rp "Enter MongoDB port (default: 27017): " input_port
        [ -n "$input_port" ] && mongo_port="$input_port"
        
        read -rp "Enter container name (default: mongodb): " input_name
        [ -n "$input_name" ] && mongo_container_name="$input_name"
        
        read -rp "Enter data directory (default: /var/lib/mongodb-docker): " input_dir
        [ -n "$input_dir" ] && mongo_data_dir="$input_dir"
    fi
    
    if prompt_yes_no "Would you like to set up MongoDB authentication?"; then
        prompt_for_input "Enter MongoDB root username" mongo_root_user
        prompt_for_input "Enter MongoDB root password" mongo_root_pass
    fi
    
    print_step "Creating MongoDB data directory..."
    sudo mkdir -p "$mongo_data_dir"
    sudo chmod 755 "$mongo_data_dir"
    
    print_step "Pulling MongoDB Docker image..."
    sudo docker pull mongo:$mongodb_docker_version
    
    if [ $? -ne 0 ]; then
        print_error "Failed to pull MongoDB image. Please check the version."
        return 1
    fi
    
    # Stop and remove existing container if it exists
    if sudo docker ps -a --format '{{.Names}}' | grep -q "^${mongo_container_name}$"; then
        print_warning "Container '$mongo_container_name' already exists. Removing..."
        sudo docker stop "$mongo_container_name" 2>/dev/null || true
        sudo docker rm "$mongo_container_name" 2>/dev/null || true
    fi
    
    print_step "Starting MongoDB container..."
    if [ -n "$mongo_root_user" ] && [ -n "$mongo_root_pass" ]; then
        sudo docker run -d \
            --name "$mongo_container_name" \
            --restart unless-stopped \
            -p "$mongo_port":27017 \
            -v "$mongo_data_dir":/data/db \
            -e MONGO_INITDB_ROOT_USERNAME="$mongo_root_user" \
            -e MONGO_INITDB_ROOT_PASSWORD="$mongo_root_pass" \
            mongo:$mongodb_docker_version
    else
        sudo docker run -d \
            --name "$mongo_container_name" \
            --restart unless-stopped \
            -p "$mongo_port":27017 \
            -v "$mongo_data_dir":/data/db \
            mongo:$mongodb_docker_version
    fi
    
    if [ $? -ne 0 ]; then
        print_error "Failed to start MongoDB container."
        return 1
    fi
    
    # Wait for MongoDB to be ready
    print_step "Waiting for MongoDB to be ready..."
    sleep 5
    
    # Verify MongoDB is running
    if sudo docker ps --format '{{.Names}}' | grep -q "^${mongo_container_name}$"; then
        print_success "MongoDB Docker container is running!"
        echo ""
        echo -e "${CYAN}MongoDB Docker Information:${NC}"
        echo "  Container Name: $mongo_container_name"
        echo "  Port: $mongo_port"
        echo "  Data Directory: $mongo_data_dir"
        echo "  Version: mongo:$mongodb_docker_version"
        if [ -n "$mongo_root_user" ]; then
            echo "  Root Username: $mongo_root_user"
            echo "  Connection String: mongodb://$mongo_root_user:<password>@localhost:$mongo_port"
        else
            echo "  Connection String: mongodb://localhost:$mongo_port"
        fi
        echo ""
        echo -e "${YELLOW}Useful Docker commands:${NC}"
        echo "  View logs: docker logs $mongo_container_name"
        echo "  Stop: docker stop $mongo_container_name"
        echo "  Start: docker start $mongo_container_name"
        echo "  Shell: docker exec -it $mongo_container_name mongosh"
    else
        print_error "MongoDB container failed to start. Check logs with: docker logs $mongo_container_name"
        return 1
    fi
    
    # Install PHP MongoDB extension if PHP is installed
    if [ -n "$php_version" ]; then
        php_ini_file="/etc/php/$php_version/fpm/php.ini"
        if [ -f "$php_ini_file" ]; then
            print_step "Installing PHP MongoDB driver..."
            add_php_extension "mongodb.so" "$php_ini_file"
            sudo NEEDRESTART_MODE=a printf "\n" | pecl install -f mongodb
            sudo systemctl restart php$php_version-fpm
        fi
    fi
    
    print_success "MongoDB $mongodb_docker_version installed via Docker successfully!"
}

install_mongodb_replica_set() {
    print_header "Installing MongoDB Replica Set (High Availability)"
    
    echo -e "${CYAN}This will set up a 3-node MongoDB replica set for high availability.${NC}"
    echo -e "${YELLOW}Requirements: Docker and Docker Compose${NC}\n"
    
    # Check if Docker Compose is available
    if ! docker compose version &> /dev/null && ! docker-compose --version &> /dev/null; then
        print_error "Docker Compose is not available. Please install Docker with Compose plugin."
        return 1
    fi
    
    # MongoDB version selection
    echo -e "${CYAN}Select MongoDB version for replica set:${NC}"
    local mongo_versions=("8 (Latest)" "7" "6" "5" "Custom")
    
    for i in "${!mongo_versions[@]}"; do
        echo "  $((i+1))) MongoDB ${mongo_versions[$i]}"
    done
    
    while true; do
        read -rp "Enter your choice (1-${#mongo_versions[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#mongo_versions[@]}" ]; then
            if [ "$choice" -eq "${#mongo_versions[@]}" ]; then
                prompt_for_input "Enter MongoDB version (e.g., 7.0)" mongodb_docker_version
            else
                mongodb_docker_version=$(echo "${mongo_versions[$((choice-1))]}" | awk '{print $1}')
            fi
            break
        else
            print_error "Invalid selection."
        fi
    done
    
    # Configuration
    local replica_set_name="rs0"
    local base_port="27017"
    local base_dir="/var/lib/mongodb-cluster"
    local mongo_root_user=""
    local mongo_root_pass=""
    local keyfile_path="$base_dir/keyfile"
    
    echo ""
    if prompt_yes_no "Would you like to customize replica set configuration?"; then
        read -rp "Enter replica set name (default: rs0): " input_rs
        [ -n "$input_rs" ] && replica_set_name="$input_rs"
        
        read -rp "Enter base port (nodes will use port, port+1, port+2) (default: 27017): " input_port
        [ -n "$input_port" ] && base_port="$input_port"
        
        read -rp "Enter base data directory (default: /var/lib/mongodb-cluster): " input_dir
        [ -n "$input_dir" ] && base_dir="$input_dir"
    fi
    
    if prompt_yes_no "Would you like to set up MongoDB authentication? (recommended for production)"; then
        prompt_for_input "Enter MongoDB root username" mongo_root_user
        prompt_for_input "Enter MongoDB root password" mongo_root_pass
    fi
    
    # Calculate ports
    local port1=$base_port
    local port2=$((base_port + 1))
    local port3=$((base_port + 2))
    
    print_step "Creating directories..."
    sudo mkdir -p "$base_dir"/{mongo1,mongo2,mongo3,config}
    sudo chmod -R 755 "$base_dir"
    
    # Generate keyfile for replica set authentication
    print_step "Generating replica set keyfile..."
    openssl rand -base64 756 | sudo tee "$keyfile_path" > /dev/null
    sudo chmod 400 "$keyfile_path"
    sudo chown 999:999 "$keyfile_path"  # MongoDB user in container
    
    # Create Docker Compose file
    print_step "Creating Docker Compose configuration..."
    
    local compose_file="$base_dir/docker-compose.yml"
    
    if [ -n "$mongo_root_user" ] && [ -n "$mongo_root_pass" ]; then
        cat <<EOF | sudo tee "$compose_file" > /dev/null
version: '3.8'

services:
  mongo1:
    image: mongo:${mongodb_docker_version}
    container_name: mongo1
    hostname: mongo1
    restart: unless-stopped
    ports:
      - "${port1}:27017"
    volumes:
      - ${base_dir}/mongo1:/data/db
      - ${keyfile_path}:/etc/mongodb/keyfile:ro
    environment:
      MONGO_INITDB_ROOT_USERNAME: ${mongo_root_user}
      MONGO_INITDB_ROOT_PASSWORD: ${mongo_root_pass}
    command: mongod --replSet ${replica_set_name} --keyFile /etc/mongodb/keyfile --bind_ip_all
    networks:
      - mongo-cluster
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 5

  mongo2:
    image: mongo:${mongodb_docker_version}
    container_name: mongo2
    hostname: mongo2
    restart: unless-stopped
    ports:
      - "${port2}:27017"
    volumes:
      - ${base_dir}/mongo2:/data/db
      - ${keyfile_path}:/etc/mongodb/keyfile:ro
    environment:
      MONGO_INITDB_ROOT_USERNAME: ${mongo_root_user}
      MONGO_INITDB_ROOT_PASSWORD: ${mongo_root_pass}
    command: mongod --replSet ${replica_set_name} --keyFile /etc/mongodb/keyfile --bind_ip_all
    networks:
      - mongo-cluster
    depends_on:
      - mongo1
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 5

  mongo3:
    image: mongo:${mongodb_docker_version}
    container_name: mongo3
    hostname: mongo3
    restart: unless-stopped
    ports:
      - "${port3}:27017"
    volumes:
      - ${base_dir}/mongo3:/data/db
      - ${keyfile_path}:/etc/mongodb/keyfile:ro
    environment:
      MONGO_INITDB_ROOT_USERNAME: ${mongo_root_user}
      MONGO_INITDB_ROOT_PASSWORD: ${mongo_root_pass}
    command: mongod --replSet ${replica_set_name} --keyFile /etc/mongodb/keyfile --bind_ip_all
    networks:
      - mongo-cluster
    depends_on:
      - mongo1
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 5

networks:
  mongo-cluster:
    driver: bridge
EOF
    else
        cat <<EOF | sudo tee "$compose_file" > /dev/null
version: '3.8'

services:
  mongo1:
    image: mongo:${mongodb_docker_version}
    container_name: mongo1
    hostname: mongo1
    restart: unless-stopped
    ports:
      - "${port1}:27017"
    volumes:
      - ${base_dir}/mongo1:/data/db
    command: mongod --replSet ${replica_set_name} --bind_ip_all
    networks:
      - mongo-cluster
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 5

  mongo2:
    image: mongo:${mongodb_docker_version}
    container_name: mongo2
    hostname: mongo2
    restart: unless-stopped
    ports:
      - "${port2}:27017"
    volumes:
      - ${base_dir}/mongo2:/data/db
    command: mongod --replSet ${replica_set_name} --bind_ip_all
    networks:
      - mongo-cluster
    depends_on:
      - mongo1
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 5

  mongo3:
    image: mongo:${mongodb_docker_version}
    container_name: mongo3
    hostname: mongo3
    restart: unless-stopped
    ports:
      - "${port3}:27017"
    volumes:
      - ${base_dir}/mongo3:/data/db
    command: mongod --replSet ${replica_set_name} --bind_ip_all
    networks:
      - mongo-cluster
    depends_on:
      - mongo1
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 5

networks:
  mongo-cluster:
    driver: bridge
EOF
    fi
    
    # Create replica set initialization script
    print_step "Creating replica set initialization script..."
    
    local init_script="$base_dir/init-replica-set.sh"
    
    if [ -n "$mongo_root_user" ] && [ -n "$mongo_root_pass" ]; then
        cat <<EOF | sudo tee "$init_script" > /dev/null
#!/bin/bash
echo "Waiting for MongoDB nodes to be ready..."
sleep 10

echo "Initializing replica set..."
docker exec mongo1 mongosh -u "${mongo_root_user}" -p "${mongo_root_pass}" --authenticationDatabase admin --eval '
rs.initiate({
  _id: "${replica_set_name}",
  members: [
    { _id: 0, host: "mongo1:27017", priority: 2 },
    { _id: 1, host: "mongo2:27017", priority: 1 },
    { _id: 2, host: "mongo3:27017", priority: 1 }
  ]
});
'

echo "Waiting for replica set to initialize..."
sleep 10

echo "Checking replica set status..."
docker exec mongo1 mongosh -u "${mongo_root_user}" -p "${mongo_root_pass}" --authenticationDatabase admin --eval 'rs.status()'
EOF
    else
        cat <<EOF | sudo tee "$init_script" > /dev/null
#!/bin/bash
echo "Waiting for MongoDB nodes to be ready..."
sleep 10

echo "Initializing replica set..."
docker exec mongo1 mongosh --eval '
rs.initiate({
  _id: "${replica_set_name}",
  members: [
    { _id: 0, host: "mongo1:27017", priority: 2 },
    { _id: 1, host: "mongo2:27017", priority: 1 },
    { _id: 2, host: "mongo3:27017", priority: 1 }
  ]
});
'

echo "Waiting for replica set to initialize..."
sleep 10

echo "Checking replica set status..."
docker exec mongo1 mongosh --eval 'rs.status()'
EOF
    fi
    
    sudo chmod +x "$init_script"
    
    # Create management scripts
    print_step "Creating management scripts..."
    
    # Start script
    cat <<EOF | sudo tee "$base_dir/start.sh" > /dev/null
#!/bin/bash
cd "$base_dir"
docker compose up -d
echo "MongoDB Replica Set started!"
EOF
    sudo chmod +x "$base_dir/start.sh"
    
    # Stop script
    cat <<EOF | sudo tee "$base_dir/stop.sh" > /dev/null
#!/bin/bash
cd "$base_dir"
docker compose down
echo "MongoDB Replica Set stopped!"
EOF
    sudo chmod +x "$base_dir/stop.sh"
    
    # Status script
    cat <<EOF | sudo tee "$base_dir/status.sh" > /dev/null
#!/bin/bash
echo "=== Container Status ==="
docker ps --filter "name=mongo" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "=== Replica Set Status ==="
EOF
    
    if [ -n "$mongo_root_user" ] && [ -n "$mongo_root_pass" ]; then
        cat <<EOF | sudo tee -a "$base_dir/status.sh" > /dev/null
docker exec mongo1 mongosh -u "${mongo_root_user}" -p "${mongo_root_pass}" --authenticationDatabase admin --quiet --eval 'rs.status().members.forEach(m => print(m.name + " - " + m.stateStr))'
EOF
    else
        cat <<EOF | sudo tee -a "$base_dir/status.sh" > /dev/null
docker exec mongo1 mongosh --quiet --eval 'rs.status().members.forEach(m => print(m.name + " - " + m.stateStr))'
EOF
    fi
    sudo chmod +x "$base_dir/status.sh"
    
    # Pull MongoDB image
    print_step "Pulling MongoDB Docker image..."
    sudo docker pull mongo:$mongodb_docker_version
    
    # Start the replica set
    print_step "Starting MongoDB Replica Set..."
    cd "$base_dir"
    sudo docker compose up -d
    
    if [ $? -ne 0 ]; then
        print_error "Failed to start MongoDB containers."
        return 1
    fi
    
    # Wait for containers to be ready
    print_step "Waiting for containers to be ready..."
    sleep 15
    
    # Initialize replica set
    print_step "Initializing replica set..."
    sudo bash "$init_script"
    
    # Verify replica set
    print_step "Verifying replica set status..."
    sleep 5
    
    if sudo docker ps --filter "name=mongo1" --format '{{.Names}}' | grep -q "mongo1"; then
        print_success "MongoDB Replica Set is running!"
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}MongoDB Replica Set Information${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "${YELLOW}Nodes:${NC}"
        echo "  • mongo1 (Primary):   localhost:${port1}"
        echo "  • mongo2 (Secondary): localhost:${port2}"
        echo "  • mongo3 (Secondary): localhost:${port3}"
        echo ""
        echo -e "${YELLOW}Replica Set Name:${NC} ${replica_set_name}"
        echo -e "${YELLOW}Data Directory:${NC} ${base_dir}"
        echo -e "${YELLOW}MongoDB Version:${NC} ${mongodb_docker_version}"
        echo ""
        if [ -n "$mongo_root_user" ]; then
            echo -e "${YELLOW}Authentication:${NC}"
            echo "  Username: ${mongo_root_user}"
            echo "  Password: (as configured)"
            echo ""
            echo -e "${YELLOW}Connection String:${NC}"
            echo "  mongodb://${mongo_root_user}:<password>@localhost:${port1},localhost:${port2},localhost:${port3}/?replicaSet=${replica_set_name}"
        else
            echo -e "${YELLOW}Connection String:${NC}"
            echo "  mongodb://localhost:${port1},localhost:${port2},localhost:${port3}/?replicaSet=${replica_set_name}"
        fi
        echo ""
        echo -e "${YELLOW}Management Scripts:${NC}"
        echo "  Start:  sudo ${base_dir}/start.sh"
        echo "  Stop:   sudo ${base_dir}/stop.sh"
        echo "  Status: sudo ${base_dir}/status.sh"
        echo "  Init:   sudo ${base_dir}/init-replica-set.sh"
        echo ""
        echo -e "${YELLOW}Docker Commands:${NC}"
        echo "  View logs:     docker logs mongo1"
        echo "  Shell (primary): docker exec -it mongo1 mongosh"
        echo "  Compose logs:  cd ${base_dir} && docker compose logs -f"
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    else
        print_error "Failed to verify replica set. Check logs with: docker logs mongo1"
        return 1
    fi
    
    # Install PHP MongoDB extension if PHP is installed
    if [ -n "$php_version" ]; then
        php_ini_file="/etc/php/$php_version/fpm/php.ini"
        if [ -f "$php_ini_file" ]; then
            print_step "Installing PHP MongoDB driver..."
            add_php_extension "mongodb.so" "$php_ini_file"
        fi
    fi
    
    if ! sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qE "^mongo"; then
        print_warning "No MongoDB Docker containers found."
    else
        print_success "MongoDB Docker containers removed successfully!"
    fi
}

uninstall_nodejs() {
    print_header "Removing Node.js"
    
    if ! command -v node &> /dev/null && [ ! -d "$HOME/.nvm" ]; then
        print_warning "Node.js is not installed."
        return 0
    fi
    
    print_step "Removing NVM and Node.js..."
    
    # Remove NVM
    if [ -d "$HOME/.nvm" ]; then
        rm -rf "$HOME/.nvm"
        
        # Remove NVM from shell config files
        for file in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
            if [ -f "$file" ]; then
                sed -i '/NVM_DIR/d' "$file"
                sed -i '/nvm.sh/d' "$file"
            fi
        done
    fi
    
    # Remove system-wide Node.js if installed
    if command -v node &> /dev/null; then
        sudo apt purge nodejs npm -y 2>/dev/null || true
        sudo apt autoremove -y
    fi
    
    # Remove PM2
    if command -v pm2 &> /dev/null; then
        pm2 kill 2>/dev/null || true
        npm uninstall -g pm2 2>/dev/null || true
    fi
    
    print_success "Node.js removed successfully!"
}

uninstall_docker() {
    print_header "Removing Docker"
    
    if ! command -v docker &> /dev/null; then
        print_warning "Docker is not installed."
        return 0
    fi
    
    # Check for running containers
    local running_containers=$(sudo docker ps -q 2>/dev/null | wc -l)
    if [ "$running_containers" -gt 0 ]; then
        print_warning "There are $running_containers running Docker containers."
        if ! prompt_yes_no "Stop all containers and proceed with Docker removal?"; then
            print_warning "Docker removal cancelled."
            return 0
        fi
        print_step "Stopping all containers..."
        sudo docker stop $(sudo docker ps -q) 2>/dev/null || true
    fi
    
    print_step "Removing all Docker containers..."
    sudo docker rm $(sudo docker ps -aq) 2>/dev/null || true
    
    if prompt_yes_no "Remove all Docker images?"; then
        print_step "Removing Docker images..."
        sudo docker rmi $(sudo docker images -q) 2>/dev/null || true
    fi
    
    if prompt_yes_no "Remove all Docker volumes (data)?"; then
        print_step "Removing Docker volumes..."
        sudo docker volume prune -f 2>/dev/null || true
    fi
    
    print_step "Stopping Docker service..."
    sudo systemctl stop docker 2>/dev/null || true
    sudo systemctl disable docker 2>/dev/null || true
    
    print_step "Removing Docker packages..."
    sudo apt purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
    sudo apt autoremove -y
    
    print_step "Removing Docker configuration..."
    sudo rm -rf /var/lib/docker
    sudo rm -rf /var/lib/containerd
    sudo rm -rf /etc/docker
    sudo rm -f /etc/apt/sources.list.d/docker.list
    sudo rm -f /etc/apt/keyrings/docker.gpg
    
    print_success "Docker removed successfully!"
}

uninstall_certbot() {
    print_header "Removing Certbot"
    
    if ! command -v certbot &> /dev/null; then
        print_warning "Certbot is not installed."
        return 0
    fi
    
    print_step "Removing Certbot packages..."
    sudo apt purge certbot python3-certbot-apache python3-certbot-nginx -y
    sudo apt autoremove -y
    
    if prompt_yes_no "Remove SSL certificates and Certbot configuration?"; then
        sudo rm -rf /etc/letsencrypt
        print_success "Certbot certificates removed."
    fi
    
    # Remove cron job
    print_step "Removing Certbot cron job..."
    sudo crontab -l 2>/dev/null | grep -v "certbot renew" | sudo crontab -
    
    print_success "Certbot removed successfully!"
}

uninstall_tools() {
    print_header "Removing Additional Tools"
    
    print_step "Removing development tools..."
    sudo apt purge gnupg curl git zip unzip wget htop -y
    sudo apt autoremove -y
    
    print_success "Additional tools removed successfully!"
}

uninstall_postgresql() {
    print_header "Removing PostgreSQL"
    
    if ! command -v psql &> /dev/null; then
        print_warning "PostgreSQL is not installed."
        return 0
    fi
    
    print_step "Stopping PostgreSQL service..."
    sudo systemctl stop postgresql 2>/dev/null || true
    sudo systemctl disable postgresql 2>/dev/null || true
    
    if prompt_yes_no "Remove PostgreSQL data (all databases)?"; then
        print_step "Removing PostgreSQL packages and data..."
        sudo apt purge postgresql* -y
        sudo rm -rf /var/lib/postgresql
        sudo rm -rf /etc/postgresql
        print_success "PostgreSQL data removed."
    else
        print_step "Removing PostgreSQL packages (keeping data)..."
        sudo apt purge postgresql* -y
    fi
    
    sudo apt autoremove -y
    
    # Remove repository
    sudo rm -f /etc/apt/sources.list.d/pgdg.list
    
    print_success "PostgreSQL removed successfully!"
}

uninstall_redis() {
    print_header "Removing Redis"
    
    if ! command -v redis-server &> /dev/null; then
        print_warning "Redis is not installed."
        return 0
    fi
    
    print_step "Stopping Redis service..."
    sudo systemctl stop redis-server 2>/dev/null || true
    sudo systemctl disable redis-server 2>/dev/null || true
    
    if prompt_yes_no "Remove Redis data?"; then
        print_step "Removing Redis packages and data..."
        sudo apt purge redis-server redis-tools -y
        sudo rm -rf /var/lib/redis
        sudo rm -rf /etc/redis
        print_success "Redis data removed."
    else
        print_step "Removing Redis packages (keeping data)..."
        sudo apt purge redis-server redis-tools -y
    fi
    
    sudo apt autoremove -y
    
    # Remove repository
    sudo rm -f /etc/apt/sources.list.d/redis.list
    sudo rm -f /usr/share/keyrings/redis-archive-keyring.gpg
    
    print_success "Redis removed successfully!"
}

# =============================================================================
# Removal Menu Functions
# =============================================================================

show_removal_menu() {
    print_header "Remove Components"
    
    echo -e "${RED}WARNING: Removal operations may delete data!${NC}\n"
    echo -e "${CYAN}Select components to remove:${NC}"
    echo ""
    echo -e "  ${YELLOW}Web Servers:${NC}"
    echo "  1) Apache (HTTPD)"
    echo "  2) Nginx"
    echo ""
    echo -e "  ${YELLOW}Databases:${NC}"
    echo "  3) MySQL"
    echo "  4) PostgreSQL"
    echo "  5) MongoDB (native)"
    echo "  6) MongoDB (Docker)"
    echo "  7) Redis"
    echo ""
    echo -e "  ${YELLOW}Languages & Runtimes:${NC}"
    echo "  8) PHP"
    echo "  9) Node.js"
    echo ""
    echo -e "  ${YELLOW}Containers & Utilities:${NC}"
    echo "  10) Docker"
    echo "  11) Certbot"
    echo "  12) Additional Tools"
    echo ""
    echo -e "  ${RED}X) Remove ALL components${NC}"
    echo "  S) Select multiple components"
    echo "  B) Back to main menu"
    echo ""
}

run_removal() {
    while true; do
        show_removal_menu
        read -rp "Enter your choice: " removal_choice
        
        case "$removal_choice" in
            1) uninstall_apache ;;
            2) uninstall_nginx ;;
            3) uninstall_mysql ;;
            4) uninstall_postgresql ;;
            5) uninstall_mongodb ;;
            6) uninstall_mongodb_docker ;;
            7) uninstall_redis ;;
            8) uninstall_php ;;
            9) uninstall_nodejs ;;
            10) uninstall_docker ;;
            11) uninstall_certbot ;;
            12) uninstall_tools ;;
            [Xx])
                print_header "Remove ALL Components"
                echo -e "${RED}This will remove ALL installed components and their data!${NC}"
                if prompt_yes_no "Are you absolutely sure?"; then
                    uninstall_certbot
                    uninstall_redis
                    uninstall_mongodb_docker
                    uninstall_mongodb
                    uninstall_postgresql
                    uninstall_nodejs
                    uninstall_php
                    uninstall_mysql
                    uninstall_nginx
                    uninstall_apache
                    uninstall_docker
                    uninstall_tools
                    print_success "All components removed!"
                fi
                ;;
            [Ss])
                selective_removal
                ;;
            [Bb])
                return 0
                ;;
            *)
                print_error "Invalid option."
                ;;
        esac
        
        echo ""
        if ! prompt_yes_no "Would you like to remove more components?"; then
            break
        fi
    done
}

selective_removal() {
    print_header "Selective Component Removal"
    
    echo -e "${CYAN}Select which components to remove (answer y/n for each):${NC}\n"
    
    local remove_apache=false
    local remove_nginx=false
    local remove_mysql=false
    local remove_mongodb=false
    local remove_mongodb_docker=false
    local remove_php=false
    local remove_nodejs=false
    local remove_docker=false
    local remove_certbot=false
    local remove_tools=false
    
    echo -e "${YELLOW}Web Servers:${NC}"
    prompt_yes_no "Remove Apache?" && remove_apache=true
    prompt_yes_no "Remove Nginx?" && remove_nginx=true
    
    echo -e "\n${YELLOW}Databases:${NC}"
    prompt_yes_no "Remove MySQL?" && remove_mysql=true
    prompt_yes_no "Remove MongoDB (native)?" && remove_mongodb=true
    prompt_yes_no "Remove MongoDB (Docker)?" && remove_mongodb_docker=true
    
    echo -e "\n${YELLOW}Languages & Runtimes:${NC}"
    prompt_yes_no "Remove PHP?" && remove_php=true
    prompt_yes_no "Remove Node.js?" && remove_nodejs=true
    
    echo -e "\n${YELLOW}Containers & Utilities:${NC}"
    prompt_yes_no "Remove Docker?" && remove_docker=true
    prompt_yes_no "Remove Certbot?" && remove_certbot=true
    prompt_yes_no "Remove Additional Tools?" && remove_tools=true
    
    # Show summary
    print_header "Removal Summary"
    echo -e "${RED}The following components will be REMOVED:${NC}\n"
    
    [ "$remove_apache" = true ] && echo -e "  ${RED}✖${NC} Apache"
    [ "$remove_nginx" = true ] && echo -e "  ${RED}✖${NC} Nginx"
    [ "$remove_mysql" = true ] && echo -e "  ${RED}✖${NC} MySQL"
    [ "$remove_mongodb" = true ] && echo -e "  ${RED}✖${NC} MongoDB (native)"
    [ "$remove_mongodb_docker" = true ] && echo -e "  ${RED}✖${NC} MongoDB (Docker)"
    [ "$remove_php" = true ] && echo -e "  ${RED}✖${NC} PHP"
    [ "$remove_nodejs" = true ] && echo -e "  ${RED}✖${NC} Node.js"
    [ "$remove_docker" = true ] && echo -e "  ${RED}✖${NC} Docker"
    [ "$remove_certbot" = true ] && echo -e "  ${RED}✖${NC} Certbot"
    [ "$remove_tools" = true ] && echo -e "  ${RED}✖${NC} Additional Tools"
    
    echo ""
    if ! prompt_yes_no "Proceed with removal?"; then
        print_warning "Removal cancelled."
        return 0
    fi
    
    # Execute removals
    [ "$remove_certbot" = true ] && uninstall_certbot
    [ "$remove_mongodb_docker" = true ] && uninstall_mongodb_docker
    [ "$remove_mongodb" = true ] && uninstall_mongodb
    [ "$remove_nodejs" = true ] && uninstall_nodejs
    [ "$remove_php" = true ] && uninstall_php
    [ "$remove_mysql" = true ] && uninstall_mysql
    [ "$remove_nginx" = true ] && uninstall_nginx
    [ "$remove_apache" = true ] && uninstall_apache
    [ "$remove_docker" = true ] && uninstall_docker
    [ "$remove_tools" = true ] && uninstall_tools
    
    print_success "Selected components removed successfully!"
}
# Main Menu
# =============================================================================

show_main_menu() {
    print_header "Ubuntu Server Setup Script v$SCRIPT_VERSION"
    
    echo -e "${CYAN}Select components to install:${NC}"
    echo ""
    echo -e "  ${YELLOW}Web Servers:${NC}"
    echo "  1) Apache (HTTPD) Web Server"
    echo "  2) Nginx Web Server"
    echo ""
    echo -e "  ${YELLOW}Databases:${NC}"
    echo "  3) MySQL Database Server"
    echo "  4) PostgreSQL Database Server"
    echo "  5) MongoDB (native installation)"
    echo "  6) MongoDB via Docker (recommended)"
    echo "  7) Redis Cache Server"
    echo ""
    echo -e "  ${YELLOW}Languages & Runtimes:${NC}"
    echo "  8) PHP (with version selection)"
    echo "  9) Node.js (with version selection)"
    echo ""
    echo -e "  ${YELLOW}Containers & Utilities:${NC}"
    echo "  10) Docker"
    echo "  11) Certbot (SSL Certificates)"
    echo "  12) Additional Tools (git, curl, zip, etc.)"
    echo ""
    echo "  A) Install ALL components (Apache + all others)"
    echo "  N) Install ALL components (Nginx + all others)"
    echo "  C) Custom selection"
    echo "  T) Server status"
    echo "  W) Configure swap"
    echo ""
    echo -e "  ${RED}R) Remove components${NC}"
    echo "  Q) Quit"
    echo ""
}

custom_selection() {
    print_header "Custom Component Selection"
    
    echo -e "${CYAN}Select which components to install (answer y/n for each):${NC}\n"
    
    echo -e "${YELLOW}Web Servers:${NC}"
    prompt_yes_no "Install Apache (HTTPD) Web Server?" && INSTALL_APACHE=true
    prompt_yes_no "Install Nginx Web Server?" && INSTALL_NGINX=true
    
    # Warn if both web servers are selected
    if [ "$INSTALL_APACHE" = true ] && [ "$INSTALL_NGINX" = true ]; then
        print_warning "Both Apache and Nginx selected. They will run on different ports or you'll need to configure them manually."
    fi
    
    echo -e "\n${YELLOW}Databases:${NC}"
    prompt_yes_no "Install MySQL Database Server?" && INSTALL_MYSQL=true
    prompt_yes_no "Install PostgreSQL Database Server?" && INSTALL_POSTGRESQL=true
    prompt_yes_no "Install Redis Cache Server?" && INSTALL_REDIS=true
    
    # MongoDB installation choice
    if prompt_yes_no "Install MongoDB?"; then
        echo -e "${CYAN}How would you like to install MongoDB?${NC}"
        echo "  1) Native installation (direct on system)"
        echo "  2) Docker installation (recommended for compatibility)"
        read -rp "Enter your choice (1-2): " mongo_choice
        case "$mongo_choice" in
            1) INSTALL_MONGODB=true ;;
            2) INSTALL_MONGODB_DOCKER=true ;;
            *) 
                print_warning "Invalid choice. Defaulting to Docker installation."
                INSTALL_MONGODB_DOCKER=true
                ;;
        esac
    fi
    
    echo -e "\n${YELLOW}Languages & Runtimes:${NC}"
    prompt_yes_no "Install PHP?" && INSTALL_PHP=true
    prompt_yes_no "Install Node.js?" && INSTALL_NODEJS=true
    
    echo -e "\n${YELLOW}Containers & Utilities:${NC}"
    prompt_yes_no "Install Docker?" && INSTALL_DOCKER=true
    prompt_yes_no "Install Certbot (SSL)?" && INSTALL_CERTBOT=true
    prompt_yes_no "Install Additional Tools?" && INSTALL_TOOLS=true
}

show_selection_summary() {
    print_header "Installation Summary"
    
    echo -e "${CYAN}The following components will be installed:${NC}\n"
    
    [ "$INSTALL_APACHE" = true ] && echo -e "  ${GREEN}✔${NC} Apache (HTTPD) Web Server"
    [ "$INSTALL_NGINX" = true ] && echo -e "  ${GREEN}✔${NC} Nginx Web Server"
    [ "$INSTALL_MYSQL" = true ] && echo -e "  ${GREEN}✔${NC} MySQL Database Server"
    [ "$INSTALL_POSTGRESQL" = true ] && echo -e "  ${GREEN}✔${NC} PostgreSQL Database Server"
    [ "$INSTALL_REDIS" = true ] && echo -e "  ${GREEN}✔${NC} Redis Cache Server"
    [ "$INSTALL_MONGODB" = true ] && echo -e "  ${GREEN}✔${NC} MongoDB (native)"
    [ "$INSTALL_MONGODB_DOCKER" = true ] && echo -e "  ${GREEN}✔${NC} MongoDB (Docker)"
    [ "$INSTALL_DOCKER" = true ] && echo -e "  ${GREEN}✔${NC} Docker"
    [ "$INSTALL_PHP" = true ] && echo -e "  ${GREEN}✔${NC} PHP"
    [ "$INSTALL_NODEJS" = true ] && echo -e "  ${GREEN}✔${NC} Node.js"
    [ "$INSTALL_CERTBOT" = true ] && echo -e "  ${GREEN}✔${NC} Certbot"
    [ "$INSTALL_TOOLS" = true ] && echo -e "  ${GREEN}✔${NC} Additional Tools"
    
    echo ""
}

run_installation() {
    print_header "Starting Installation"
    
    print_step "Updating package list..."
    sudo apt update
    
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