#!/bin/bash

# =============================================================================
# Domain Setup Script for Apache/Nginx
# Creates virtual host configurations for web applications
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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
    local default_value="$3"
    local input_value=""

    if [ -n "$default_value" ]; then
        read -rp "$prompt [$default_value]: " input_value
        input_value="${input_value:-$default_value}"
    else
        while [ -z "$input_value" ]; do
            read -rp "$prompt: " input_value
            if [ -z "$input_value" ]; then
                print_error "Input cannot be empty. Please try again."
            fi
        done
    fi
    eval "$input_variable_name=\"$input_value\""
}

prompt_yes_no() {
    local prompt="$1"
    local default="$2"
    local response
    
    if [ "$default" = "y" ]; then
        prompt="$prompt (Y/n)"
    elif [ "$default" = "n" ]; then
        prompt="$prompt (y/N)"
    else
        prompt="$prompt (y/n)"
    fi
    
    while true; do
        read -rp "$prompt: " response
        response="${response:-$default}"
        case "$response" in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer y or n.";;
        esac
    done
}

# =============================================================================
# Detection Functions
# =============================================================================

detect_web_server() {
    local apache_installed=false
    local nginx_installed=false
    
    if command -v apache2 &> /dev/null && systemctl is-active --quiet apache2; then
        apache_installed=true
    fi
    
    if command -v nginx &> /dev/null && systemctl is-active --quiet nginx; then
        nginx_installed=true
    fi
    
    if [ "$apache_installed" = true ] && [ "$nginx_installed" = true ]; then
        echo "both"
    elif [ "$apache_installed" = true ]; then
        echo "apache"
    elif [ "$nginx_installed" = true ]; then
        echo "nginx"
    else
        echo "none"
    fi
}

detect_php_version() {
    if command -v php &> /dev/null; then
        php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;" 2>/dev/null
    else
        echo ""
    fi
}

get_installed_php_versions() {
    local versions=()
    for dir in /etc/php/*/fpm; do
        if [ -d "$dir" ]; then
            ver=$(basename $(dirname "$dir"))
            versions+=("$ver")
        fi
    done
    echo "${versions[@]}"
}

# =============================================================================
# Apache Configuration Functions
# =============================================================================

create_apache_static_config() {
    local domain="$1"
    local doc_root="$2"
    local config_file="/etc/apache2/sites-available/${domain}.conf"
    
    sudo tee "$config_file" > /dev/null << EOF
<VirtualHost *:80>
    ServerName ${domain}
    ServerAlias www.${domain}
    DocumentRoot ${doc_root}
    
    <Directory ${doc_root}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/${domain}-error.log
    CustomLog \${APACHE_LOG_DIR}/${domain}-access.log combined
</VirtualHost>
EOF
    
    echo "$config_file"
}

create_apache_php_config() {
    local domain="$1"
    local doc_root="$2"
    local php_ver="$3"
    local config_file="/etc/apache2/sites-available/${domain}.conf"
    
    sudo tee "$config_file" > /dev/null << EOF
<VirtualHost *:80>
    ServerName ${domain}
    ServerAlias www.${domain}
    DocumentRoot ${doc_root}
    
    <Directory ${doc_root}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    <FilesMatch \.php$>
        SetHandler "proxy:unix:/var/run/php/php${php_ver}-fpm.sock|fcgi://localhost"
    </FilesMatch>
    
    ErrorLog \${APACHE_LOG_DIR}/${domain}-error.log
    CustomLog \${APACHE_LOG_DIR}/${domain}-access.log combined
</VirtualHost>
EOF
    
    echo "$config_file"
}

create_apache_proxy_config() {
    local domain="$1"
    local proxy_port="$2"
    local proxy_host="${3:-localhost}"
    local config_file="/etc/apache2/sites-available/${domain}.conf"
    
    sudo tee "$config_file" > /dev/null << EOF
<VirtualHost *:80>
    ServerName ${domain}
    ServerAlias www.${domain}
    
    ProxyPreserveHost On
    ProxyPass / http://${proxy_host}:${proxy_port}/
    ProxyPassReverse / http://${proxy_host}:${proxy_port}/
    
    # WebSocket support
    RewriteEngine On
    RewriteCond %{HTTP:Upgrade} websocket [NC]
    RewriteCond %{HTTP:Connection} upgrade [NC]
    RewriteRule ^/?(.*) "ws://${proxy_host}:${proxy_port}/\$1" [P,L]
    
    ErrorLog \${APACHE_LOG_DIR}/${domain}-error.log
    CustomLog \${APACHE_LOG_DIR}/${domain}-access.log combined
</VirtualHost>
EOF
    
    echo "$config_file"
}

create_apache_laravel_config() {
    local domain="$1"
    local doc_root="$2"
    local php_ver="$3"
    local config_file="/etc/apache2/sites-available/${domain}.conf"
    
    sudo tee "$config_file" > /dev/null << EOF
<VirtualHost *:80>
    ServerName ${domain}
    ServerAlias www.${domain}
    DocumentRoot ${doc_root}/public
    
    <Directory ${doc_root}/public>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    <FilesMatch \.php$>
        SetHandler "proxy:unix:/var/run/php/php${php_ver}-fpm.sock|fcgi://localhost"
    </FilesMatch>
    
    # Deny access to sensitive files
    <FilesMatch "^\.">
        Require all denied
    </FilesMatch>
    
    ErrorLog \${APACHE_LOG_DIR}/${domain}-error.log
    CustomLog \${APACHE_LOG_DIR}/${domain}-access.log combined
</VirtualHost>
EOF
    
    echo "$config_file"
}

create_apache_angular_config() {
    local domain="$1"
    local doc_root="$2"
    local config_file="/etc/apache2/sites-available/${domain}.conf"
    
    sudo tee "$config_file" > /dev/null << EOF
<VirtualHost *:80>
    ServerName ${domain}
    ServerAlias www.${domain}
    DocumentRoot ${doc_root}
    
    <Directory ${doc_root}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
        
        # Angular routing - fallback to index.html
        RewriteEngine On
        RewriteBase /
        RewriteRule ^index\.html$ - [L]
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteCond %{REQUEST_FILENAME} !-d
        RewriteRule . /index.html [L]
    </Directory>
    
    # Cache static assets
    <FilesMatch "\.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$">
        Header set Cache-Control "public, max-age=31536000, immutable"
    </FilesMatch>
    
    # Deny access to hidden files
    <FilesMatch "^\.">
        Require all denied
    </FilesMatch>
    
    ErrorLog \${APACHE_LOG_DIR}/${domain}-error.log
    CustomLog \${APACHE_LOG_DIR}/${domain}-access.log combined
</VirtualHost>
EOF
    
    echo "$config_file"
}

create_apache_angular_ssr_config() {
    local domain="$1"
    local proxy_port="$2"
    local proxy_host="${3:-localhost}"
    local config_file="/etc/apache2/sites-available/${domain}.conf"
    
    sudo tee "$config_file" > /dev/null << EOF
<VirtualHost *:80>
    ServerName ${domain}
    ServerAlias www.${domain}
    
    ProxyPreserveHost On
    ProxyPass / http://${proxy_host}:${proxy_port}/
    ProxyPassReverse / http://${proxy_host}:${proxy_port}/
    
    # WebSocket support
    RewriteEngine On
    RewriteCond %{HTTP:Upgrade} websocket [NC]
    RewriteCond %{HTTP:Connection} upgrade [NC]
    RewriteRule ^/?(.*) "ws://${proxy_host}:${proxy_port}/\$1" [P,L]
    
    # Cache static assets
    <LocationMatch "\.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$">
        Header set Cache-Control "public, max-age=31536000, immutable"
    </LocationMatch>
    
    ErrorLog \${APACHE_LOG_DIR}/${domain}-error.log
    CustomLog \${APACHE_LOG_DIR}/${domain}-access.log combined
</VirtualHost>
EOF
    
    echo "$config_file"
}

# =============================================================================
# Nginx Configuration Functions
# =============================================================================

create_nginx_static_config() {
    local domain="$1"
    local doc_root="$2"
    local config_file="/etc/nginx/sites-available/${domain}"
    
    sudo tee "$config_file" > /dev/null << EOF
server {
    listen 80;
    listen [::]:80;
    
    server_name ${domain} www.${domain};
    root ${doc_root};
    index index.html index.htm;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    
    # Deny access to hidden files
    location ~ /\. {
        deny all;
    }
    
    access_log /var/log/nginx/${domain}-access.log;
    error_log /var/log/nginx/${domain}-error.log;
}
EOF
    
    echo "$config_file"
}

create_nginx_php_config() {
    local domain="$1"
    local doc_root="$2"
    local php_ver="$3"
    local config_file="/etc/nginx/sites-available/${domain}"
    
    sudo tee "$config_file" > /dev/null << EOF
server {
    listen 80;
    listen [::]:80;
    
    server_name ${domain} www.${domain};
    root ${doc_root};
    index index.php index.html index.htm;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${php_ver}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
    
    # Deny access to hidden files
    location ~ /\. {
        deny all;
    }
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    
    access_log /var/log/nginx/${domain}-access.log;
    error_log /var/log/nginx/${domain}-error.log;
}
EOF
    
    echo "$config_file"
}

create_nginx_proxy_config() {
    local domain="$1"
    local proxy_port="$2"
    local proxy_host="${3:-localhost}"
    local config_file="/etc/nginx/sites-available/${domain}"
    
    sudo tee "$config_file" > /dev/null << EOF
server {
    listen 80;
    listen [::]:80;
    
    server_name ${domain} www.${domain};
    
    location / {
        proxy_pass http://${proxy_host}:${proxy_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 86400;
    }
    
    access_log /var/log/nginx/${domain}-access.log;
    error_log /var/log/nginx/${domain}-error.log;
}
EOF
    
    echo "$config_file"
}

create_nginx_laravel_config() {
    local domain="$1"
    local doc_root="$2"
    local php_ver="$3"
    local config_file="/etc/nginx/sites-available/${domain}"
    
    sudo tee "$config_file" > /dev/null << EOF
server {
    listen 80;
    listen [::]:80;
    
    server_name ${domain} www.${domain};
    root ${doc_root}/public;
    index index.php index.html index.htm;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${php_ver}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
    
    # Deny access to hidden files
    location ~ /\.(?!well-known).* {
        deny all;
    }
    
    # Cache static assets
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff|woff2)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    access_log /var/log/nginx/${domain}-access.log;
    error_log /var/log/nginx/${domain}-error.log;
}
EOF
    
    echo "$config_file"
}

create_nginx_nextjs_config() {
    local domain="$1"
    local proxy_port="$2"
    local proxy_host="${3:-localhost}"
    local config_file="/etc/nginx/sites-available/${domain}"
    
    sudo tee "$config_file" > /dev/null << EOF
server {
    listen 80;
    listen [::]:80;
    
    server_name ${domain} www.${domain};
    
    # Gzip compression
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml;
    gzip_min_length 1000;
    
    location / {
        proxy_pass http://${proxy_host}:${proxy_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
    
    # Next.js static files
    location /_next/static {
        proxy_pass http://${proxy_host}:${proxy_port};
        proxy_cache_valid 60m;
        add_header Cache-Control "public, immutable";
    }
    
    access_log /var/log/nginx/${domain}-access.log;
    error_log /var/log/nginx/${domain}-error.log;
}
EOF
    
    echo "$config_file"
}

create_nginx_nuxtjs_config() {
    local domain="$1"
    local proxy_port="$2"
    local proxy_host="${3:-localhost}"
    local config_file="/etc/nginx/sites-available/${domain}"
    
    sudo tee "$config_file" > /dev/null << EOF
server {
    listen 80;
    listen [::]:80;
    
    server_name ${domain} www.${domain};
    
    # Gzip compression
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml;
    gzip_min_length 1000;
    
    location / {
        proxy_pass http://${proxy_host}:${proxy_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
    
    # Nuxt.js static files
    location /_nuxt/ {
        proxy_pass http://${proxy_host}:${proxy_port};
        proxy_cache_valid 60m;
        add_header Cache-Control "public, immutable";
    }
    
    access_log /var/log/nginx/${domain}-access.log;
    error_log /var/log/nginx/${domain}-error.log;
}
EOF
    
    echo "$config_file"
}

create_nginx_angular_config() {
    local domain="$1"
    local doc_root="$2"
    local config_file="/etc/nginx/sites-available/${domain}"
    
    sudo tee "$config_file" > /dev/null << EOF
server {
    listen 80;
    listen [::]:80;
    
    server_name ${domain} www.${domain};
    root ${doc_root};
    index index.html;
    
    # Gzip compression
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml;
    gzip_min_length 1000;
    
    # Angular routing - serve index.html for all routes
    location / {
        try_files \$uri \$uri/ /index.html;
    }
    
    # Cache static assets
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # Deny access to hidden files
    location ~ /\. {
        deny all;
    }
    
    access_log /var/log/nginx/${domain}-access.log;
    error_log /var/log/nginx/${domain}-error.log;
}
EOF
    
    echo "$config_file"
}

create_nginx_angular_ssr_config() {
    local domain="$1"
    local proxy_port="$2"
    local proxy_host="${3:-localhost}"
    local config_file="/etc/nginx/sites-available/${domain}"
    
    sudo tee "$config_file" > /dev/null << EOF
server {
    listen 80;
    listen [::]:80;
    
    server_name ${domain} www.${domain};
    
    # Gzip compression
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml;
    gzip_min_length 1000;
    
    location / {
        proxy_pass http://${proxy_host}:${proxy_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
    
    # Angular SSR static assets
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        proxy_pass http://${proxy_host}:${proxy_port};
        proxy_cache_valid 60m;
        add_header Cache-Control "public, immutable";
    }
    
    access_log /var/log/nginx/${domain}-access.log;
    error_log /var/log/nginx/${domain}-error.log;
}
EOF
    
    echo "$config_file"
}

# =============================================================================
# SSL Functions
# =============================================================================

setup_ssl() {
    local domain="$1"
    local web_server="$2"
    local email=""
    local include_www=false
    local domain_args=""
    
    if ! command -v certbot &> /dev/null; then
        print_warning "Certbot is not installed. Skipping SSL setup."
        return 1
    fi
    
    # Prompt for email address
    prompt_for_input "Enter email address for SSL certificate notifications" email
    
    # Validate email format (basic check)
    if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        print_warning "Email format appears invalid, but continuing anyway..."
    fi
    
    # Ask about www subdomain
    if prompt_yes_no "Include www.${domain} in the certificate?" "y"; then
        include_www=true
        domain_args="-d ${domain} -d www.${domain}"
    else
        domain_args="-d ${domain}"
    fi
    
    print_step "Setting up SSL certificate for ${domain}..."
    
    if [ "$web_server" = "apache" ]; then
        sudo certbot --apache $domain_args --non-interactive --agree-tos --redirect --email "$email"
    elif [ "$web_server" = "nginx" ]; then
        sudo certbot --nginx $domain_args --non-interactive --agree-tos --redirect --email "$email"
    fi
    
    if [ $? -eq 0 ]; then
        print_success "SSL certificate installed successfully!"
        return 0
    else
        print_error "SSL certificate installation failed."
        if [ "$include_www" = true ]; then
            echo ""
            print_warning "Tip: If www.${domain} failed, try again without www subdomain."
            print_warning "Make sure www.${domain} has DNS pointing to this server and is configured in ${web_server}."
        fi
        return 1
    fi
}

# =============================================================================
# Main Setup Function
# =============================================================================

setup_domain() {
    print_header "Domain Setup Wizard"
    
    # Detect web server
    local web_server=$(detect_web_server)
    
    if [ "$web_server" = "none" ]; then
        print_error "No web server (Apache or Nginx) is running."
        print_warning "Please install and start a web server first."
        exit 1
    fi
    
    # If both are installed, ask which one to configure
    if [ "$web_server" = "both" ]; then
        echo -e "${CYAN}Both Apache and Nginx are running. Which one do you want to configure?${NC}"
        echo "  1) Apache"
        echo "  2) Nginx"
        read -rp "Enter your choice (1-2): " server_choice
        case "$server_choice" in
            1) web_server="apache" ;;
            2) web_server="nginx" ;;
            *) web_server="nginx" ;;
        esac
    fi
    
    echo -e "${GREEN}Configuring: ${web_server^}${NC}\n"
    
    # Get domain name
    prompt_for_input "Enter domain name (e.g., example.com)" domain_name
    
    # Remove www. prefix if present
    domain_name="${domain_name#www.}"
    
    # Select application type
    echo ""
    echo -e "${CYAN}Select application type:${NC}"
    echo "  1) Static HTML/CSS/JS"
    echo "  2) PHP Application"
    echo "  3) Laravel/Symfony (PHP Framework)"
    echo "  4) Node.js/Express (Reverse Proxy)"
    echo "  5) Next.js (SSR Framework)"
    echo "  6) Nuxt.js (SSR Framework)"
    echo "  7) Angular (Static SPA)"
    echo "  8) Angular SSR (Server-Side Rendering)"
    echo "  9) Custom Reverse Proxy"
    read -rp "Enter your choice (1-9): " app_type
    
    local config_file=""
    local doc_root=""
    local php_version=""
    local proxy_port=""
    
    case "$app_type" in
        1)
            # Static site
            prompt_for_input "Enter document root path" doc_root "/var/www/${domain_name}"
            
            if [ "$web_server" = "apache" ]; then
                config_file=$(create_apache_static_config "$domain_name" "$doc_root")
            else
                config_file=$(create_nginx_static_config "$domain_name" "$doc_root")
            fi
            ;;
        2)
            # PHP Application
            prompt_for_input "Enter document root path" doc_root "/var/www/${domain_name}"
            
            # Get PHP version
            local available_php=$(get_installed_php_versions)
            local default_php=$(detect_php_version)
            
            if [ -n "$available_php" ]; then
                echo -e "\n${CYAN}Available PHP versions: ${available_php}${NC}"
            fi
            prompt_for_input "Enter PHP version to use" php_version "$default_php"
            
            if [ "$web_server" = "apache" ]; then
                config_file=$(create_apache_php_config "$domain_name" "$doc_root" "$php_version")
            else
                config_file=$(create_nginx_php_config "$domain_name" "$doc_root" "$php_version")
            fi
            ;;
        3)
            # Laravel/Symfony
            prompt_for_input "Enter project root path (not public)" doc_root "/var/www/${domain_name}"
            
            local available_php=$(get_installed_php_versions)
            local default_php=$(detect_php_version)
            
            if [ -n "$available_php" ]; then
                echo -e "\n${CYAN}Available PHP versions: ${available_php}${NC}"
            fi
            prompt_for_input "Enter PHP version to use" php_version "$default_php"
            
            if [ "$web_server" = "apache" ]; then
                config_file=$(create_apache_laravel_config "$domain_name" "$doc_root" "$php_version")
            else
                config_file=$(create_nginx_laravel_config "$domain_name" "$doc_root" "$php_version")
            fi
            ;;
        4)
            # Node.js Proxy
            prompt_for_input "Enter application port" proxy_port "3000"
            prompt_for_input "Enter proxy host" proxy_host "localhost"
            
            if [ "$web_server" = "apache" ]; then
                config_file=$(create_apache_proxy_config "$domain_name" "$proxy_port" "$proxy_host")
            else
                config_file=$(create_nginx_proxy_config "$domain_name" "$proxy_port" "$proxy_host")
            fi
            ;;
        5)
            # Next.js
            prompt_for_input "Enter application port" proxy_port "3000"
            prompt_for_input "Enter proxy host" proxy_host "localhost"
            
            if [ "$web_server" = "apache" ]; then
                config_file=$(create_apache_proxy_config "$domain_name" "$proxy_port" "$proxy_host")
            else
                config_file=$(create_nginx_nextjs_config "$domain_name" "$proxy_port" "$proxy_host")
            fi
            ;;
        6)
            # Nuxt.js
            prompt_for_input "Enter application port" proxy_port "3000"
            prompt_for_input "Enter proxy host" proxy_host "localhost"
            
            if [ "$web_server" = "apache" ]; then
                config_file=$(create_apache_proxy_config "$domain_name" "$proxy_port" "$proxy_host")
            else
                config_file=$(create_nginx_nuxtjs_config "$domain_name" "$proxy_port" "$proxy_host")
            fi
            ;;
        7)
            # Angular Static SPA
            prompt_for_input "Enter document root path (dist folder)" doc_root "/var/www/${domain_name}"
            
            if [ "$web_server" = "apache" ]; then
                config_file=$(create_apache_angular_config "$domain_name" "$doc_root")
            else
                config_file=$(create_nginx_angular_config "$domain_name" "$doc_root")
            fi
            ;;
        8)
            # Angular SSR
            prompt_for_input "Enter application port" proxy_port "4000"
            prompt_for_input "Enter proxy host" proxy_host "localhost"
            
            if [ "$web_server" = "apache" ]; then
                config_file=$(create_apache_angular_ssr_config "$domain_name" "$proxy_port" "$proxy_host")
            else
                config_file=$(create_nginx_angular_ssr_config "$domain_name" "$proxy_port" "$proxy_host")
            fi
            ;;
        9)
            # Custom Proxy
            prompt_for_input "Enter backend port" proxy_port
            prompt_for_input "Enter backend host" proxy_host "localhost"
            
            if [ "$web_server" = "apache" ]; then
                config_file=$(create_apache_proxy_config "$domain_name" "$proxy_port" "$proxy_host")
            else
                config_file=$(create_nginx_proxy_config "$domain_name" "$proxy_port" "$proxy_host")
            fi
            ;;
        *)
            print_error "Invalid selection."
            exit 1
            ;;
    esac
    
    print_success "Configuration file created: $config_file"
    
    # Create document root if needed
    if [ -n "$doc_root" ] && [ ! -d "$doc_root" ]; then
        if prompt_yes_no "Document root doesn't exist. Create it?" "y"; then
            sudo mkdir -p "$doc_root"
            sudo chown -R www-data:www-data "$doc_root"
            sudo chmod -R 755 "$doc_root"
            print_success "Created document root: $doc_root"
            
            # Create a default index file
            if [ "$app_type" = "1" ]; then
                echo "<html><head><title>${domain_name}</title></head><body><h1>Welcome to ${domain_name}</h1></body></html>" | sudo tee "$doc_root/index.html" > /dev/null
            elif [ "$app_type" = "2" ]; then
                echo "<?php phpinfo();" | sudo tee "$doc_root/index.php" > /dev/null
            fi
        fi
    fi
    
    # Enable site
    print_step "Enabling site..."
    if [ "$web_server" = "apache" ]; then
        sudo a2ensite "${domain_name}.conf"
        
        # Test configuration
        if sudo apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
            sudo systemctl reload apache2
            print_success "Apache configuration reloaded."
        else
            print_error "Apache configuration test failed!"
            sudo apache2ctl configtest
            exit 1
        fi
    else
        sudo ln -sf "/etc/nginx/sites-available/${domain_name}" "/etc/nginx/sites-enabled/"
        
        # Test configuration
        if sudo nginx -t 2>&1 | grep -q "successful"; then
            sudo systemctl reload nginx
            print_success "Nginx configuration reloaded."
        else
            print_error "Nginx configuration test failed!"
            sudo nginx -t
            exit 1
        fi
    fi
    
    # SSL setup
    echo ""
    if prompt_yes_no "Would you like to set up SSL (HTTPS) with Let's Encrypt?" "y"; then
        setup_ssl "$domain_name" "$web_server"
    fi
    
    # Add to hosts file for local testing
    if prompt_yes_no "Add ${domain_name} to /etc/hosts for local testing?" "n"; then
        echo "127.0.0.1 ${domain_name} www.${domain_name}" | sudo tee -a /etc/hosts > /dev/null
        print_success "Added to /etc/hosts"
    fi
    
    # Summary
    echo ""
    print_header "Setup Complete!"
    echo -e "${CYAN}Domain:${NC} ${domain_name}"
    echo -e "${CYAN}Web Server:${NC} ${web_server^}"
    echo -e "${CYAN}Config File:${NC} ${config_file}"
    [ -n "$doc_root" ] && echo -e "${CYAN}Document Root:${NC} ${doc_root}"
    [ -n "$proxy_port" ] && echo -e "${CYAN}Proxy:${NC} http://${proxy_host:-localhost}:${proxy_port}"
    [ -n "$php_version" ] && echo -e "${CYAN}PHP Version:${NC} ${php_version}"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "  1. Point your domain's DNS A record to this server's IP"
    echo "  2. Deploy your application to the document root"
    [ -n "$proxy_port" ] && echo "  3. Make sure your app is running on port ${proxy_port}"
    echo ""
    print_success "Domain ${domain_name} is ready!"
}

# =============================================================================
# List/Manage Domains
# =============================================================================

list_domains() {
    print_header "Configured Domains"
    
    local web_server=$(detect_web_server)
    
    if [ "$web_server" = "apache" ] || [ "$web_server" = "both" ]; then
        echo -e "${CYAN}Apache Sites:${NC}"
        if [ -d /etc/apache2/sites-available ]; then
            for conf in /etc/apache2/sites-available/*.conf; do
                if [ -f "$conf" ]; then
                    local name=$(basename "$conf" .conf)
                    local enabled=""
                    [ -L "/etc/apache2/sites-enabled/$(basename $conf)" ] && enabled="${GREEN}[enabled]${NC}"
                    echo "  - $name $enabled"
                fi
            done
        fi
        echo ""
    fi
    
    if [ "$web_server" = "nginx" ] || [ "$web_server" = "both" ]; then
        echo -e "${CYAN}Nginx Sites:${NC}"
        if [ -d /etc/nginx/sites-available ]; then
            for conf in /etc/nginx/sites-available/*; do
                if [ -f "$conf" ]; then
                    local name=$(basename "$conf")
                    local enabled=""
                    [ -L "/etc/nginx/sites-enabled/$name" ] && enabled="${GREEN}[enabled]${NC}"
                    echo -e "  - $name $enabled"
                fi
            done
        fi
        echo ""
    fi
}

remove_domain() {
    print_header "Remove Domain"
    
    local web_server=$(detect_web_server)
    
    prompt_for_input "Enter domain name to remove" domain_name
    domain_name="${domain_name#www.}"
    
    echo ""
    echo -e "${RED}This will remove the following:${NC}"
    
    local found=false
    
    # Check Apache
    if [ -f "/etc/apache2/sites-available/${domain_name}.conf" ]; then
        echo "  - Apache config: /etc/apache2/sites-available/${domain_name}.conf"
        found=true
    fi
    
    # Check Nginx
    if [ -f "/etc/nginx/sites-available/${domain_name}" ]; then
        echo "  - Nginx config: /etc/nginx/sites-available/${domain_name}"
        found=true
    fi
    
    if [ "$found" = false ]; then
        print_warning "No configuration found for ${domain_name}"
        return 1
    fi
    
    echo ""
    if ! prompt_yes_no "Are you sure you want to remove ${domain_name}?" "n"; then
        print_warning "Removal cancelled."
        return 0
    fi
    
    # Remove Apache config
    if [ -f "/etc/apache2/sites-available/${domain_name}.conf" ]; then
        sudo a2dissite "${domain_name}.conf" 2>/dev/null
        sudo rm -f "/etc/apache2/sites-available/${domain_name}.conf"
        sudo systemctl reload apache2
        print_success "Removed Apache configuration"
    fi
    
    # Remove Nginx config
    if [ -f "/etc/nginx/sites-available/${domain_name}" ]; then
        sudo rm -f "/etc/nginx/sites-enabled/${domain_name}"
        sudo rm -f "/etc/nginx/sites-available/${domain_name}"
        sudo systemctl reload nginx
        print_success "Removed Nginx configuration"
    fi
    
    # Offer to remove SSL certs
    if [ -d "/etc/letsencrypt/live/${domain_name}" ]; then
        if prompt_yes_no "Remove SSL certificates for ${domain_name}?" "n"; then
            sudo certbot delete --cert-name "$domain_name" --non-interactive
            print_success "SSL certificates removed"
        fi
    fi
    
    print_success "Domain ${domain_name} removed!"
}

issue_ssl_certificate() {
    print_header "Issue SSL Certificate"
    
    local web_server=$(detect_web_server)
    
    if [ "$web_server" = "none" ]; then
        print_error "No web server (Apache or Nginx) is running."
        return 1
    fi
    
    # If both are installed, ask which one to use
    if [ "$web_server" = "both" ]; then
        echo -e "${CYAN}Both Apache and Nginx are running. Which one is serving the domain?${NC}"
        echo "  1) Apache"
        echo "  2) Nginx"
        read -rp "Enter your choice (1-2): " server_choice
        case "$server_choice" in
            1) web_server="apache" ;;
            2) web_server="nginx" ;;
            *) web_server="nginx" ;;
        esac
    fi
    
    # Get domain name
    prompt_for_input "Enter domain name (e.g., example.com)" domain_name
    domain_name="${domain_name#www.}"
    
    # Check if domain is already configured
    local config_exists=false
    if [ "$web_server" = "apache" ] && [ -f "/etc/apache2/sites-available/${domain_name}.conf" ]; then
        config_exists=true
    elif [ "$web_server" = "nginx" ] && [ -f "/etc/nginx/sites-available/${domain_name}" ]; then
        config_exists=true
    fi
    
    if [ "$config_exists" = false ]; then
        print_warning "No virtual host configuration found for ${domain_name}"
        if ! prompt_yes_no "Continue anyway?" "n"; then
            return 1
        fi
    fi
    
    # Check if SSL already exists
    if [ -d "/etc/letsencrypt/live/${domain_name}" ]; then
        print_warning "SSL certificate already exists for ${domain_name}"
        if prompt_yes_no "Renew/reinstall the certificate?" "n"; then
            setup_ssl "$domain_name" "$web_server"
        fi
    else
        setup_ssl "$domain_name" "$web_server"
    fi
}

# =============================================================================
# Main Menu
# =============================================================================

show_menu() {
    print_header "Domain Management"
    
    echo -e "${CYAN}Select an option:${NC}"
    echo ""
    echo "  1) Setup new domain"
    echo "  2) List configured domains"
    echo "  3) Issue SSL certificate"
    echo "  4) Remove domain"
    echo "  5) Exit"
    echo ""
}

main() {
    # Check if running as root or with sudo
    if [ "$EUID" -ne 0 ]; then
        print_warning "This script requires root privileges."
        print_step "Please run with: sudo $0"
        exit 1
    fi
    
    while true; do
        show_menu
        read -rp "Enter your choice (1-5): " choice
        
        case "$choice" in
            1) setup_domain ;;
            2) list_domains ;;
            3) issue_ssl_certificate ;;
            4) remove_domain ;;
            5) 
                echo -e "\n${YELLOW}Goodbye!${NC}\n"
                exit 0 
                ;;
            *)
                print_error "Invalid option."
                ;;
        esac
        
        echo ""
        read -rp "Press Enter to continue..."
    done
}

# Run main function
main
