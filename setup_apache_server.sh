#!/bin/bash

# =============================================================================
# Interactive Apache Server Setup Script
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Installation flags (default: not selected)
INSTALL_APACHE=false
INSTALL_MYSQL=false
INSTALL_PHP=false
INSTALL_MONGODB=false
INSTALL_NODEJS=false
INSTALL_CERTBOT=false
INSTALL_TOOLS=false

# Version variables
php_version=""
mongodb_version=""
nodejs_version=""

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
    print_header "Installing Apache Web Server"
    
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
    print_success "Apache installed successfully!"
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
    
    # PHP version selection
    echo -e "${CYAN}Select PHP version to install:${NC}"
    local php_versions=("8.4" "8.3" "8.2" "8.1" "8.0" "7.4" "Custom")
    
    for i in "${!php_versions[@]}"; do
        echo "  $((i+1))) PHP ${php_versions[$i]}"
    done
    
    while true; do
        read -rp "Enter your choice (1-${#php_versions[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#php_versions[@]}" ]; then
            if [ "$choice" -eq "${#php_versions[@]}" ]; then
                prompt_for_input "Enter custom PHP version (e.g., 8.2)" php_version
            else
                php_version="${php_versions[$((choice-1))]}"
            fi
            break
        else
            print_error "Invalid selection."
        fi
    done
    
    print_step "Adding PHP repository..."
    yes | sudo add-apt-repository ppa:ondrej/php
    sudo apt update
    
    print_step "Installing PHP $php_version and modules..."
    sudo NEEDRESTART_MODE=a apt install php$php_version -y
    sudo NEEDRESTART_MODE=a apt install php$php_version-common php$php_version-mysql php$php_version-xml \
        php$php_version-xmlrpc php$php_version-curl php$php_version-gd php$php_version-imagick \
        php$php_version-cli php$php_version-dev php$php_version-imap php$php_version-mbstring \
        php$php_version-opcache php$php_version-soap php$php_version-zip php$php_version-intl \
        php$php_version-bcmath libapache2-mod-php$php_version php-pear -y
    sudo NEEDRESTART_MODE=a apt install autoconf g++ make openssl libssl3 libssl-dev \
        libcurl4-openssl-dev pkg-config libsasl2-dev libpcre3-dev -y
    
    print_step "Enabling PHP modules..."
    sudo phpenmod mbstring
    
    if [ "$INSTALL_APACHE" = true ]; then
        print_step "Enabling HTTP/2 with PHP-FPM..."
        sudo a2enmod http2
        sudo a2dismod php$php_version 2>/dev/null || true
        sudo a2dismod mpm_prefork 2>/dev/null || true
        sudo a2enmod mpm_event proxy_fcgi setenvif
        sudo NEEDRESTART_MODE=a apt install php$php_version-fpm -y
        sudo systemctl start php$php_version-fpm
        sudo a2enconf php$php_version-fpm
    else
        sudo NEEDRESTART_MODE=a apt install php$php_version-fpm -y
        sudo systemctl start php$php_version-fpm
    fi
    
    php_ini_file="/etc/php/$php_version/fpm/php.ini"
    php_fpm_file="/etc/php/$php_version/fpm/pool.d/www.conf"
    
    print_step "Configuring PHP settings..."
    update_php_config "upload_max_filesize" "64M" "$php_ini_file"
    update_php_config "post_max_size" "64M" "$php_ini_file"
    update_php_config "memory_limit" "256M" "$php_ini_file"
    update_php_config "max_execution_time" "600" "$php_ini_file"
    update_php_config "max_input_time" "600" "$php_ini_file"
    update_php_config "max_input_vars" "10000" "$php_ini_file"
    
    add_php_extension "opcache.so" "$php_ini_file"
    
    update_php_config "opcache.enable" "1" "$php_ini_file"
    update_php_config "opcache.enable_cli" "1" "$php_ini_file"
    update_php_config "opcache.memory_consumption" "128" "$php_ini_file"
    update_php_config "opcache.interned_strings_buffer" "8" "$php_ini_file"
    update_php_config "opcache.max_accelerated_files" "10000" "$php_ini_file"
    update_php_config "opcache.revalidate_freq" "2" "$php_ini_file"
    update_php_config "opcache.fast_shutdown" "1" "$php_ini_file"
    
    update_php_config "pm" "dynamic" "$php_fpm_file"
    update_php_config "pm.max_children" "6" "$php_fpm_file"
    update_php_config "pm.start_servers" "2" "$php_fpm_file"
    update_php_config "pm.min_spare_servers" "1" "$php_fpm_file"
    update_php_config "pm.max_spare_servers" "3" "$php_fpm_file"
    
    sudo systemctl restart php$php_version-fpm
    [ "$INSTALL_APACHE" = true ] && sudo systemctl restart apache2
    
    print_success "PHP $php_version installed successfully!"
}

install_mongodb() {
    print_header "Installing MongoDB"
    
    # MongoDB version selection
    echo -e "${CYAN}Select MongoDB version to install:${NC}"
    local mongo_versions=("8.0" "7.0" "6.0" "5.0" "Custom")
    
    for i in "${!mongo_versions[@]}"; do
        echo "  $((i+1))) MongoDB ${mongo_versions[$i]}"
    done
    
    while true; do
        read -rp "Enter your choice (1-${#mongo_versions[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#mongo_versions[@]}" ]; then
            if [ "$choice" -eq "${#mongo_versions[@]}" ]; then
                prompt_for_input "Enter custom MongoDB version (e.g., 7.0)" mongodb_version
            else
                mongodb_version="${mongo_versions[$((choice-1))]}"
            fi
            break
        else
            print_error "Invalid selection."
        fi
    done
    
    # Detect Ubuntu version for repository
    ubuntu_codename=$(lsb_release -cs)
    
    print_step "Adding MongoDB repository for version $mongodb_version..."
    curl -fsSL https://www.mongodb.org/static/pgp/server-$mongodb_version.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-$mongodb_version.gpg --dearmor
    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-$mongodb_version.gpg ] https://repo.mongodb.org/apt/ubuntu $ubuntu_codename/mongodb-org/$mongodb_version multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-$mongodb_version.list
    
    sudo apt update
    
    print_step "Installing MongoDB..."
    sudo NEEDRESTART_MODE=a apt install mongodb-org -y
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
    sudo NEEDRESTART_MODE=a apt install certbot python3-certbot-apache -y
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

# =============================================================================
# Main Menu
# =============================================================================

show_main_menu() {
    print_header "Apache Server Setup Script"
    
    echo -e "${CYAN}Select components to install:${NC}"
    echo ""
    echo "  1) Apache Web Server"
    echo "  2) MySQL Database Server"
    echo "  3) PHP (with version selection)"
    echo "  4) MongoDB (with version selection)"
    echo "  5) Node.js (with version selection)"
    echo "  6) Certbot (SSL Certificates)"
    echo "  7) Additional Tools (git, curl, zip, etc.)"
    echo ""
    echo "  A) Install ALL components"
    echo "  C) Custom selection"
    echo "  Q) Quit"
    echo ""
}

custom_selection() {
    print_header "Custom Component Selection"
    
    echo -e "${CYAN}Select which components to install (answer y/n for each):${NC}\n"
    
    prompt_yes_no "Install Apache Web Server?" && INSTALL_APACHE=true
    prompt_yes_no "Install MySQL Database Server?" && INSTALL_MYSQL=true
    prompt_yes_no "Install PHP?" && INSTALL_PHP=true
    prompt_yes_no "Install MongoDB?" && INSTALL_MONGODB=true
    prompt_yes_no "Install Node.js?" && INSTALL_NODEJS=true
    prompt_yes_no "Install Certbot (SSL)?" && INSTALL_CERTBOT=true
    prompt_yes_no "Install Additional Tools?" && INSTALL_TOOLS=true
}

show_selection_summary() {
    print_header "Installation Summary"
    
    echo -e "${CYAN}The following components will be installed:${NC}\n"
    
    [ "$INSTALL_APACHE" = true ] && echo -e "  ${GREEN}✔${NC} Apache Web Server"
    [ "$INSTALL_MYSQL" = true ] && echo -e "  ${GREEN}✔${NC} MySQL Database Server"
    [ "$INSTALL_PHP" = true ] && echo -e "  ${GREEN}✔${NC} PHP"
    [ "$INSTALL_MONGODB" = true ] && echo -e "  ${GREEN}✔${NC} MongoDB"
    [ "$INSTALL_NODEJS" = true ] && echo -e "  ${GREEN}✔${NC} Node.js"
    [ "$INSTALL_CERTBOT" = true ] && echo -e "  ${GREEN}✔${NC} Certbot"
    [ "$INSTALL_TOOLS" = true ] && echo -e "  ${GREEN}✔${NC} Additional Tools"
    
    echo ""
}

run_installation() {
    print_header "Starting Installation"
    
    print_step "Updating package list..."
    sudo apt update
    
    [ "$INSTALL_APACHE" = true ] && install_apache
    [ "$INSTALL_MYSQL" = true ] && install_mysql
    [ "$INSTALL_PHP" = true ] && install_php
    [ "$INSTALL_MONGODB" = true ] && install_mongodb
    [ "$INSTALL_NODEJS" = true ] && install_nodejs
    [ "$INSTALL_CERTBOT" = true ] && install_certbot
    [ "$INSTALL_TOOLS" = true ] && install_tools
    
    # Final restart of services
    print_header "Finalizing Installation"
    
    if [ "$INSTALL_APACHE" = true ]; then
        print_step "Restarting Apache..."
        sudo systemctl restart apache2
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
    [ "$INSTALL_MYSQL" = true ] && echo "  MySQL: $(mysql --version 2>/dev/null)"
    [ "$INSTALL_PHP" = true ] && echo "  PHP: $(php -v 2>/dev/null | head -1)"
    [ "$INSTALL_MONGODB" = true ] && echo "  MongoDB: $(mongod --version 2>/dev/null | head -1)"
    [ "$INSTALL_NODEJS" = true ] && echo "  Node.js: $(node -v 2>/dev/null)"
    echo ""
}

# =============================================================================
# Main Script Execution
# =============================================================================

main() {
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
                INSTALL_MYSQL=true
                ;;
            3)
                INSTALL_PHP=true
                ;;
            4)
                INSTALL_MONGODB=true
                ;;
            5)
                INSTALL_NODEJS=true
                ;;
            6)
                INSTALL_CERTBOT=true
                ;;
            7)
                INSTALL_TOOLS=true
                ;;
            [Aa])
                INSTALL_APACHE=true
                INSTALL_MYSQL=true
                INSTALL_PHP=true
                INSTALL_MONGODB=true
                INSTALL_NODEJS=true
                INSTALL_CERTBOT=true
                INSTALL_TOOLS=true
                ;;
            [Cc])
                custom_selection
                ;;
            [Qq])
                echo -e "\n${YELLOW}Installation cancelled.${NC}\n"
                exit 0
                ;;
            *)
                print_error "Invalid option. Please try again."
                continue
                ;;
        esac
        
        # If a single component was selected, ask if user wants to add more
        if [[ "$main_choice" =~ ^[1-7]$ ]]; then
            if prompt_yes_no "Would you like to select additional components?"; then
                continue
            fi
        fi
        
        break
    done
    
    # Show summary and confirm
    show_selection_summary
    
    if prompt_yes_no "Proceed with installation?"; then
        run_installation
    else
        echo -e "\n${YELLOW}Installation cancelled.${NC}\n"
        exit 0
    fi
}

# Run the main function
main