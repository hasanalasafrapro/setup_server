#!/bin/bash

# Function to prompt for input
prompt_for_input() {
    local prompt="$1"
    local input_variable_name="$2"
    local input_value=""

    while [ -z "$input_value" ]; do
        read -rp "$prompt: " input_value
        if [ -n "$input_value" ]; then
            eval "$input_variable_name=\"$input_value\""
        else
            echo "Input cannot be empty. Please try again."
        fi
    done
}

# Function to update php.ini settings
update_php_config() {
    local setting="$1"
    local value="$2"
    local php_ini="$3"

    # Check if the setting exists as commented and uncomment it
    if grep -q "^\s*;$setting" "$php_ini"; then
        sudo sed -i "s/^\s*;$setting\s*=.*/$setting = $value/" "$php_ini"
    # Check if the setting exists uncommented and update it
    elif grep -q "^\s*$setting" "$php_ini"; then
        sudo sed -i "s/^\s*$setting\s*=.*/$setting = $value/" "$php_ini"
    else
        # If the setting does not exist, add it
        echo "$setting = $value" | sudo tee -a "$php_ini" > /dev/null
    fi
}

# Function to add a PHP extension to php.ini if it doesn't exist
add_php_extension() {
    local extension_line="extension=$1"
    local php_ini_file="$2"

    # Check if the extension line exists as a commented line
    if grep -q "^\s*;${extension_line}" "$php_ini_file"; then
        # Uncomment the extension line
        sudo sed -i "s/^\s*;${extension_line}/${extension_line}/" "$php_ini_file"
        echo "Uncommented extension line in php.ini: $extension_line"
    elif ! grep -Fxq "$extension_line" "$php_ini_file"; then
        # If the line doesn't exist, add it to the end of the file
        echo "$extension_line" | sudo tee -a "$php_ini_file" > /dev/null
        echo "Extension line added to php.ini: $extension_line"
    else
        echo "Extension line already exists in php.ini: $extension_line"
    fi
}

update_mysql_config() {
    local config_file="/etc/my.cnf.d/mysql-server.cnf"  # Path to MySQL config file in Rocky Linux
    local variable_name="$1"
    local value="$2"
    
    # Check if the variable already exists and is commented
    if grep -qE "^\s*#\s*$variable_name\b" "$config_file"; then
        # Uncomment the variable
        sudo sed -i "s/^\s*#\s*\($variable_name\b\)/\1/" "$config_file"
    elif ! grep -qE "^\s*$variable_name\b" "$config_file"; then
        # Variable doesn't exist, add it under [mysqld] section
        sudo sed -i "/^\[mysqld\]/a $variable_name = $value" "$config_file"
    fi
    
    # Update the value if the variable exists
    if grep -qE "^\s*$variable_name\b" "$config_file"; then
        sudo sed -i "s/^\s*$variable_name\s*=.*/$variable_name = $value/" "$config_file"
    fi
    
    echo "MySQL configuration updated: $variable_name = $value"
}

# Prompt for new superuser details
prompt_for_input "Enter MySQL superuser username" new_username
prompt_for_input "Enter MySQL superuser password" new_password

# Prompt for php version
prompt_for_input "Enter php version to be install" php_version

# Update the package list
echo "Updating package list..."
sudo dnf update -y

# Install EPEL repository
echo "Installing EPEL repository..."
sudo dnf install epel-release -y

# Install Remi repository for PHP
echo "Installing Remi repository for PHP..."
sudo dnf install dnf-utils http://rpms.remirepo.net/enterprise/remi-release-$(rpm -E %rhel).rpm -y

# Install Apache (httpd in Rocky Linux)
echo "Installing Apache..."
sudo dnf install httpd -y

# Enable and start Apache service
sudo systemctl enable httpd
sudo systemctl start httpd

# Set up firewall
echo "Setting up firewall..."
sudo dnf install firewalld -y
sudo systemctl enable firewalld
sudo systemctl start firewalld
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --permanent --add-service=ssh
sudo firewall-cmd --permanent --add-port=587/tcp
sudo firewall-cmd --permanent --add-port=465/tcp
sudo firewall-cmd --permanent --add-port=25/tcp
sudo firewall-cmd --reload

# Install MySQL (MariaDB in Rocky Linux)
echo "Installing MariaDB..."
sudo dnf install mariadb-server -y
sudo systemctl enable mariadb
sudo systemctl start mariadb

# Secure MariaDB installation
echo "Securing MariaDB installation..."
sudo mysql -e "SET GLOBAL expire_logs_days = 1;"

config_file_path="/etc/my.cnf.d/mysql-server.cnf"
directive="skip-name-resolve"

# Check if the directive already exists and is commented
if grep -qE "^\s*#\s*$directive\b" "$config_file_path"; then
    # Uncomment the directive
    sudo sed -i "s/^\s*#\s*\($directive\b\)/\1/" "$config_file_path"
elif ! grep -qE "^\s*$directive\b" "$config_file_path"; then
    # Directive doesn't exist, add it under [mysqld] section
    sudo sed -i "/^\[mysqld\]/a $directive" "$config_file_path"
fi

# Update MySQL configuration
update_mysql_config "innodb_buffer_pool_size" "512M"
update_mysql_config "innodb_log_file_size" "64M"
update_mysql_config "innodb_file_per_table" "1"
update_mysql_config "innodb_log_buffer_size" "4M"
update_mysql_config "max_connections" "300"
update_mysql_config "slow_query_log" "1"
update_mysql_config "slow_query_log_file" "/var/log/mariadb/mariadb-slow.log"

# Create MySQL superuser
echo "Creating MySQL superuser..."
sudo mysql -e "CREATE USER IF NOT EXISTS '$new_username'@'localhost' IDENTIFIED BY '$new_password';"
sudo mysql -e "GRANT ALL PRIVILEGES ON *.* TO '$new_username'@'localhost' WITH GRANT OPTION;"
sudo mysql -e "FLUSH PRIVILEGES;"

# Restart MariaDB to apply changes
sudo systemctl restart mariadb

# Enable PHP Remi repository for the specified PHP version
echo "Enabling PHP $php_version repository..."
sudo dnf module reset php -y
sudo dnf module enable php:remi-$php_version -y

# Install PHP and required extensions
echo "Installing PHP $php_version and extensions..."
sudo dnf install php php-fpm php-cli php-mysqlnd php-zip php-devel php-gd php-mcrypt php-mbstring php-curl php-xml php-pear php-bcmath php-json php-opcache -y

# Enable and start PHP-FPM
sudo systemctl enable php-fpm
sudo systemctl start php-fpm

# Configure Apache to use PHP-FPM
echo "Configuring Apache to use PHP-FPM..."
sudo dnf install mod_ssl -y

# Create PHP-FPM configuration for Apache
cat << EOF | sudo tee /etc/httpd/conf.d/php-fpm.conf
<FilesMatch \.php$>
    SetHandler "proxy:unix:/var/run/php-fpm/www.sock|fcgi://localhost"
</FilesMatch>
EOF

# Enable required Apache modules
echo "Enabling required Apache modules..."
sudo dnf install mod_proxy mod_proxy_http mod_proxy_ajp mod_proxy_balancer mod_proxy_connect mod_proxy_html mod_ssl -y

# Enable HTTP/2 in Apache
echo "Enabling HTTP/2..."
cat << EOF | sudo tee /etc/httpd/conf.d/http2.conf
Protocols h2 h2c http/1.1
EOF

# Configure PHP settings
php_ini_file="/etc/php.ini"
php_fpm_file="/etc/php-fpm.d/www.conf"

# Change php.ini settings
echo "Changing php.ini settings..."
update_php_config "upload_max_filesize" "64M" "$php_ini_file"
update_php_config "post_max_size" "64M" "$php_ini_file"
update_php_config "memory_limit" "256M" "$php_ini_file"
update_php_config "max_execution_time" "600" "$php_ini_file"
update_php_config "max_input_time" "600" "$php_ini_file"
update_php_config "max_input_vars" "10000" "$php_ini_file"

# Enable and configure opcache
add_php_extension "opcache.so" "$php_ini_file"

update_php_config "opcache.enable" "1" "$php_ini_file"
update_php_config "opcache.enable_cli" "1" "$php_ini_file"
update_php_config "opcache.memory_consumption" "128" "$php_ini_file"
update_php_config "opcache.interned_strings_buffer" "8" "$php_ini_file"
update_php_config "opcache.max_accelerated_files" "10000" "$php_ini_file"
update_php_config "opcache.revalidate_freq" "2" "$php_ini_file"
update_php_config "opcache.fast_shutdown" "1" "$php_ini_file"

# Configure PHP-FPM settings
update_php_config "pm" "dynamic" "$php_fpm_file"
update_php_config "pm.max_children" "6" "$php_fpm_file"
update_php_config "pm.start_servers" "2" "$php_fpm_file"
update_php_config "pm.min_spare_servers" "1" "$php_fpm_file"
update_php_config "pm.max_spare_servers" "3" "$php_fpm_file"

# Restart Apache to apply changes
echo "Restarting Apache..."
sudo systemctl restart httpd

# Restart PHP-FPM to apply changes
echo "Restarting PHP-FPM..."
sudo systemctl restart php-fpm

# Install additional tools
echo "Installing additional tools..."
sudo dnf install gnupg curl git zip unzip -y

# Install Certbot for SSL certificates
echo "Installing Certbot..."
sudo dnf install certbot python3-certbot-apache -y
sudo certbot plugins

# Set up automatic renewal for SSL certificates
cron_job="0 0,12 * * * certbot renew --quiet --no-self-upgrade"
(sudo crontab -l 2>/dev/null; echo "$cron_job") | sudo crontab -

# Install MongoDB
echo "Installing MongoDB..."
cat << EOF | sudo tee /etc/yum.repos.d/mongodb-org-7.0.repo
[mongodb-org-7.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/\$releasever/mongodb-org/7.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-7.0.asc
EOF

sudo dnf install mongodb-org -y
sudo systemctl enable mongod
sudo systemctl start mongod

# Install PHP MongoDB extension
echo "Installing PHP MongoDB extension..."
sudo dnf install php-pecl-mongodb -y

add_php_extension "mongodb.so" "$php_ini_file"

# Install nvm
echo "Installing nvm..."
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.1/install.sh | bash

# Source nvm script to add it to the current shell session
export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm

# Install Node.js version 18.20.3
echo "Installing Node.js v18.20.3..."
nvm install 18.20.3

# Install pm2
echo "Installing pm2..."
npm install pm2@latest -g

# Restart Apache to apply changes
echo "Restarting Apache..."
sudo systemctl restart httpd

# Restart PHP-FPM to apply changes
echo "Restarting PHP-FPM..."
sudo systemctl restart php-fpm

# Clean up
echo "Cleaning up..."
sudo dnf clean all

echo "Setup completed successfully!"
