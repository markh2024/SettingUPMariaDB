#!/usr/bin/env bash
#
# mariadb-admin-menu.sh
#
# Menu-driven MariaDB setup & administration tool.
# Supports: openSUSE Tumbleweed (zypper) and Debian/Ubuntu (apt).
#
# Covers:
#   1) OS/package detection
#   2) Install MariaDB server + client
#   3) Install connector/dev packages (C, C++, ODBC, GTK3, GTKmm, Qt6, PHP)
#   4) Generate SSH key for remote tunnel access
#   5) Run mariadb-secure-installation
#   6) Create DB users with scoped grants
#   7) Service control (start/stop/restart/enable/disable/status)
#   8) Performance tuning (my.cnf, sized to system RAM)
#   9) Log retention (binlog expiry + logrotate for slow/error logs)
#  10) Additional utility packages (mariadb-backup, percona-toolkit, mytop)
#  11) Python driver install (mariadb / PyMySQL)
#  12) Show Java/Maven JDBC dependency info
#
# Daily reporting is intentionally NOT included here — use the separate
# mariadb-daily-report.sh for that.
#
# Run as root or with sudo.

set -uo pipefail

LOG_FILE="/var/log/mariadb-admin-menu.log"

### ------------------------------------------------------------------
### Colours / helpers
### ------------------------------------------------------------------

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()   { echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"; }
info()  { echo -e "${CYAN}==> $*${NC}"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
pause() { read -rp "Press Enter to continue..." _; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (use sudo)."
        exit 1
    fi
}

### ------------------------------------------------------------------
### OS detection
### ------------------------------------------------------------------

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID="unknown"
        OS_ID_LIKE=""
    fi

    case "$OS_ID" in
        opensuse-tumbleweed|opensuse*|sles)
            PKG_FAMILY="suse"
            PKG_INSTALL="zypper install -y"
            MY_CNF_DIR="/etc/my.cnf.d"
            SLOW_LOG_DEFAULT="/var/log/mysql/slow.log"
            ERR_LOG_DEFAULT="/var/log/mysql/mariadb.err"
            ;;
        debian|ubuntu)
            PKG_FAMILY="debian"
            PKG_INSTALL="apt-get install -y"
            MY_CNF_DIR="/etc/mysql/mariadb.conf.d"
            SLOW_LOG_DEFAULT="/var/log/mysql/mariadb-slow.log"
            ERR_LOG_DEFAULT="/var/log/mysql/error.log"
            ;;
        *)
            if [[ "$OS_ID_LIKE" == *suse* ]]; then
                PKG_FAMILY="suse"; PKG_INSTALL="zypper install -y"; MY_CNF_DIR="/etc/my.cnf.d"
                SLOW_LOG_DEFAULT="/var/log/mysql/slow.log"; ERR_LOG_DEFAULT="/var/log/mysql/mariadb.err"
            elif [[ "$OS_ID_LIKE" == *debian* ]]; then
                PKG_FAMILY="debian"; PKG_INSTALL="apt-get install -y"; MY_CNF_DIR="/etc/mysql/mariadb.conf.d"
                SLOW_LOG_DEFAULT="/var/log/mysql/mariadb-slow.log"; ERR_LOG_DEFAULT="/var/log/mysql/error.log"
            else
                err "Unsupported/unrecognised distro: $OS_ID. Aborting."
                exit 1
            fi
            ;;
    esac

    info "Detected OS: ${OS_ID} (package family: ${PKG_FAMILY})"
    log "OS detected as $OS_ID / family $PKG_FAMILY"
}

pkg_refresh() {
    if [[ "$PKG_FAMILY" == "suse" ]]; then
        zypper refresh
    else
        apt-get update
    fi
}

### ------------------------------------------------------------------
### 2) Install MariaDB server + client
### ------------------------------------------------------------------

install_mariadb_core() {
    info "Installing MariaDB server + client..."
    pkg_refresh
    if [[ "$PKG_FAMILY" == "suse" ]]; then
        $PKG_INSTALL mariadb mariadb-client mariadb-tools
    else
        $PKG_INSTALL mariadb-server mariadb-client
    fi
    log "Installed MariaDB core packages"
    ok "MariaDB core installed."
    pause
}

### ------------------------------------------------------------------
### 3) Install connector / dev packages
### ------------------------------------------------------------------

install_connectors() {
    info "Select which connectors/dev packages to install:"
    echo "  1) C connector (libmariadb dev headers)"
    echo "  2) C++ connector"
    echo "  3) ODBC connector + driver manager"
    echo "  4) GTK3 + GTKmm dev headers"
    echo "  5) Qt6 MariaDB/MySQL SQL driver plugin"
    echo "  6) PHP MySQL/MariaDB extension"
    echo "  7) All of the above"
    echo "  0) Back to main menu"
    read -rp "Choice: " conn_choice

    pkg_refresh

    case "$conn_choice" in
        1) install_c_connector ;;
        2) install_cpp_connector ;;
        3) install_odbc_connector ;;
        4) install_gtk ;;
        5) install_qt6_plugin ;;
        6) install_php_mysql ;;
        7) install_c_connector; install_cpp_connector; install_odbc_connector; install_gtk; install_qt6_plugin; install_php_mysql ;;
        0) return ;;
        *) warn "Invalid choice." ;;
    esac
    pause
}

install_c_connector() {
    info "Installing C connector..."
    if [[ "$PKG_FAMILY" == "suse" ]]; then
        $PKG_INSTALL libmariadb-devel libmariadb3
    else
        $PKG_INSTALL libmariadb-dev libmariadb-dev-compat libmariadb3
    fi
    log "Installed C connector"
    ok "C connector installed."
}

install_cpp_connector() {
    info "Installing C++ connector..."
    if [[ "$PKG_FAMILY" == "suse" ]]; then
        $PKG_INSTALL mariadb-connector-cpp-devel
    else
        warn "Debian/Ubuntu repos often don't package MariaDB Connector/C++ directly."
        warn "You may need to build it from source: https://github.com/mariadb-corporation/mariadb-connector-cpp"
        warn "The C connector (libmariadb-dev) is a prerequisite and was/will be installed separately."
    fi
    log "C++ connector step completed (see warnings if Debian)"
    ok "C++ connector step done."
}

install_odbc_connector() {
    info "Installing ODBC connector + driver manager..."
    if [[ "$PKG_FAMILY" == "suse" ]]; then
        $PKG_INSTALL unixODBC unixODBC-devel MariaDB-connector-odbc
    else
        $PKG_INSTALL unixodbc unixodbc-dev odbc-mariadb
    fi
    log "Installed ODBC connector"
    ok "ODBC connector installed. Verify with: odbcinst -q -d"
}

install_gtk() {
    info "Installing GTK3 + GTKmm dev headers..."
    if [[ "$PKG_FAMILY" == "suse" ]]; then
        $PKG_INSTALL gtk3-devel gtkmm3-devel glibmm2-devel
    else
        $PKG_INSTALL libgtk-3-dev libgtkmm-3.0-dev libglibmm-2.4-dev
    fi
    log "Installed GTK3/GTKmm"
    ok "GTK3/GTKmm installed."
}

install_qt6_plugin() {
    info "Installing Qt6 MariaDB/MySQL SQL driver plugin..."
    if [[ "$PKG_FAMILY" == "suse" ]]; then
        $PKG_INSTALL libqt6sql6-mysql
    else
        $PKG_INSTALL libqt6sql6-mysql || warn "Package name may differ on this Debian/Ubuntu release — search with: apt-cache search qt6sql"
    fi
    log "Installed Qt6 MySQL plugin"
    ok "Qt6 plugin step done."
}

install_php_mysql() {
    info "Installing PHP MySQL/MariaDB extension..."
    if [[ "$PKG_FAMILY" == "suse" ]]; then
        $PKG_INSTALL php8-mysql
    else
        $PKG_INSTALL php-mysql
    fi
    log "Installed PHP MySQL extension"
    ok "PHP extension installed."
}

### ------------------------------------------------------------------
### 4) SSH key generation for remote tunnel access
### ------------------------------------------------------------------

generate_ssh_key() {
    info "Generate an SSH key for remote MariaDB tunnel access"
    read -rp "Key comment/label [All_Devices]: " key_label
    key_label=${key_label:-All_Devices}
    read -rp "Target user's home directory [${SUDO_USER:-$HOME}]: " target_home
    target_home=${target_home:-/home/${SUDO_USER:-$USER}}
    # filename uses lowercase, comment keeps whatever case you entered
    key_slug=$(echo "$key_label" | tr '[:upper:]' '[:lower:]')
    key_path="${target_home}/.ssh/id_ed25519_${key_slug}"

    mkdir -p "${target_home}/.ssh"
    chmod 700 "${target_home}/.ssh"

    if [[ -f "$key_path" ]]; then
        warn "Key already exists at $key_path — skipping generation."
    else
        sudo -u "${SUDO_USER:-$USER}" ssh-keygen -t ed25519 -f "$key_path" -C "$key_label"
        ok "Key generated at $key_path"
        log "Generated SSH key $key_path"
    fi

    read -rp "Authorize this key for local login (append to authorized_keys)? [y/N]: " auth_local
    if [[ "$auth_local" =~ ^[Yy]$ ]]; then
        cat "${key_path}.pub" >> "${target_home}/.ssh/authorized_keys"
        chmod 600 "${target_home}/.ssh/authorized_keys"
        ok "Public key added to authorized_keys."
    fi

    echo
    info "Public key (safe to copy to other devices):"
    cat "${key_path}.pub"
    echo
    info "Export options for the PRIVATE key (${key_path}):"
    echo "  - QR code (terminal): qrencode -t ansiutf8 < ${key_path}"
    echo "  - scp:                scp ${key_path} user@device:~/.ssh/"
    echo "  - Syncthing / USB transfer for higher security"

    read -rp "Generate a QR code now? [y/N]: " do_qr
    if [[ "$do_qr" =~ ^[Yy]$ ]]; then
        if ! command -v qrencode &>/dev/null; then
            info "qrencode not found, installing..."
            $PKG_INSTALL qrencode
        fi
        qrencode -t ansiutf8 < "$key_path"
        read -rp "Also save a PNG backup (e.g. QRCodeFor${key_label}.png)? [y/N]: " do_png
        if [[ "$do_png" =~ ^[Yy]$ ]]; then
            png_path="${target_home}/QRCodeFor${key_label}.png"
            qrencode -o "$png_path" < "$key_path"
            chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$png_path" 2>/dev/null
            ok "QR PNG saved to $png_path"
            warn "This PNG contains your private key — store/delete it as carefully as the key file itself."
        fi
    fi
    pause
}

### ------------------------------------------------------------------
### 5) Secure installation
### ------------------------------------------------------------------

run_secure_installation() {
    info "Running mariadb-secure-installation..."
    warn "This is interactive — follow the prompts (set root password, remove anonymous users, disable remote root, remove test DB)."
    pause
    mariadb-secure-installation
    log "Ran mariadb-secure-installation"
    pause
}

### ------------------------------------------------------------------
### 6) User creation with scoped grants
### ------------------------------------------------------------------

create_db_user() {
    info "Create a new MariaDB user"
    read -rp "New username: " db_user
    read -rsp "Password: " db_pass; echo
    read -rp "Host scope [localhost]: " db_host
    db_host=${db_host:-localhost}

    echo "Privilege template:"
    echo "  1) Full admin (ALL PRIVILEGES ON *.* WITH GRANT OPTION)"
    echo "  2) App-scoped (ALL PRIVILEGES on one database only)"
    echo "  3) Read-only (SELECT on one database only)"
    read -rp "Choice: " priv_choice

    case "$priv_choice" in
        1)
            mysql -e "CREATE USER '${db_user}'@'${db_host}' IDENTIFIED BY '${db_pass}';"
            mysql -e "GRANT ALL PRIVILEGES ON *.* TO '${db_user}'@'${db_host}' WITH GRANT OPTION;"
            ;;
        2)
            read -rp "Database name: " db_name
            mysql -e "CREATE USER '${db_user}'@'${db_host}' IDENTIFIED BY '${db_pass}';"
            mysql -e "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'${db_host}';"
            ;;
        3)
            read -rp "Database name: " db_name
            mysql -e "CREATE USER '${db_user}'@'${db_host}' IDENTIFIED BY '${db_pass}';"
            mysql -e "GRANT SELECT ON \`${db_name}\`.* TO '${db_user}'@'${db_host}';"
            ;;
        *)
            warn "Invalid choice, no user created."
            return
            ;;
    esac

    mysql -e "FLUSH PRIVILEGES;"
    ok "User '${db_user}'@'${db_host}' created."
    log "Created DB user ${db_user}@${db_host} with privilege template ${priv_choice}"
    pause
}

### ------------------------------------------------------------------
### 7) Service control
### ------------------------------------------------------------------

service_control_menu() {
    echo "Service control:"
    echo "  1) Start"
    echo "  2) Stop"
    echo "  3) Restart"
    echo "  4) Enable on boot"
    echo "  5) Disable on boot"
    echo "  6) Status"
    echo "  0) Back"
    read -rp "Choice: " sc_choice
    case "$sc_choice" in
        1) systemctl start mariadb; ok "Started." ;;
        2) systemctl stop mariadb; ok "Stopped." ;;
        3) systemctl restart mariadb; ok "Restarted." ;;
        4) systemctl enable mariadb; ok "Enabled on boot." ;;
        5) systemctl disable mariadb; ok "Disabled on boot." ;;
        6) systemctl status mariadb --no-pager -l ;;
        0) return ;;
        *) warn "Invalid choice." ;;
    esac
    log "Service control action: $sc_choice"
    pause
}

### ------------------------------------------------------------------
### 8) Performance tuning
### ------------------------------------------------------------------

apply_performance_tuning() {
    info "Applying performance tuning based on system RAM..."

    total_ram_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    total_ram_mb=$((total_ram_kb / 1024))
    # Default to 50% of RAM for buffer pool, rounded to nearest 256MB
    buffer_pool_mb=$(( (total_ram_mb / 2 / 256) * 256 ))
    [[ $buffer_pool_mb -lt 256 ]] && buffer_pool_mb=256

    info "Detected ~${total_ram_mb}MB RAM. Recommended buffer pool: ${buffer_pool_mb}MB"
    read -rp "Buffer pool size in MB [${buffer_pool_mb}]: " user_bp
    buffer_pool_mb=${user_bp:-$buffer_pool_mb}

    tuning_file="${MY_CNF_DIR}/tuning.cnf"

    if [[ -f "$tuning_file" ]]; then
        cp "$tuning_file" "${tuning_file}.bak.$(date +%s)"
        warn "Existing tuning file backed up."
    fi

    cat > "$tuning_file" << EOF
[mysqld]
innodb_buffer_pool_size = ${buffer_pool_mb}M
innodb_buffer_pool_instances = 4
innodb_log_file_size = 256M
innodb_log_buffer_size = 32M
innodb_flush_method = O_DIRECT
innodb_flush_log_at_trx_commit = 1

max_connections = 50
sort_buffer_size = 2M
read_buffer_size = 2M
join_buffer_size = 2M
table_open_cache = 2000
tmp_table_size = 64M
max_heap_table_size = 64M

slow_query_log = 1
slow_query_log_file = ${SLOW_LOG_DEFAULT}
long_query_time = 1
EOF

    ok "Tuning config written to $tuning_file"
    log "Wrote tuning config, buffer pool ${buffer_pool_mb}M"

    read -rp "Restart MariaDB now to apply changes? [y/N]: " do_restart
    if [[ "$do_restart" =~ ^[Yy]$ ]]; then
        systemctl restart mariadb
        ok "MariaDB restarted."
    else
        warn "Remember to restart MariaDB manually for changes to take effect."
    fi
    pause
}

### ------------------------------------------------------------------
### 9) Log retention (2-day default)
### ------------------------------------------------------------------

configure_log_retention() {
    info "Configure log retention"
    read -rp "Retention period in days [2]: " retention_days
    retention_days=${retention_days:-2}
    retention_seconds=$(( retention_days * 86400 ))

    # Binary log expiry (live + persisted)
    binlog_file="${MY_CNF_DIR}/binlog-retention.cnf"
    cat > "$binlog_file" << EOF
[mysqld]
binlog_expire_logs_seconds = ${retention_seconds}
EOF
    ok "Binary log expiry set to ${retention_days} day(s) in $binlog_file"

    # logrotate for slow/error logs
    logrotate_file="/etc/logrotate.d/mariadb-custom"
    cat > "$logrotate_file" << EOF
${SLOW_LOG_DEFAULT}
${ERR_LOG_DEFAULT}
{
    daily
    rotate ${retention_days}
    maxage ${retention_days}
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
    ok "Logrotate config written to $logrotate_file (retention: ${retention_days} day(s))"
    log "Configured log retention at ${retention_days} days"

    read -rp "Restart MariaDB now to apply binlog setting? [y/N]: " do_restart
    if [[ "$do_restart" =~ ^[Yy]$ ]]; then
        systemctl restart mariadb
        ok "MariaDB restarted."
    fi
    pause
}

### ------------------------------------------------------------------
### 10) Additional utility packages
### ------------------------------------------------------------------

install_utility_packages() {
    info "Select additional utility packages to install:"
    echo "  1) mariadb-backup (mariabackup — proper hot backup tool)"
    echo "  2) percona-toolkit (query analysis — may need an external repo)"
    echo "  3) mytop (top-like live view of MariaDB activity)"
    echo "  4) All of the above"
    echo "  0) Back to main menu"
    read -rp "Choice: " util_choice

    pkg_refresh

    case "$util_choice" in
        1) install_mariabackup ;;
        2) install_percona_toolkit ;;
        3) install_mytop ;;
        4) install_mariabackup; install_percona_toolkit; install_mytop ;;
        0) return ;;
        *) warn "Invalid choice." ;;
    esac
    pause
}

install_mariabackup() {
    info "Installing mariadb-backup..."
    if [[ "$PKG_FAMILY" == "suse" ]]; then
        $PKG_INSTALL mariadb-backup
    else
        $PKG_INSTALL mariadb-backup
    fi
    log "Installed mariadb-backup"
    ok "mariadb-backup installed."
}

install_percona_toolkit() {
    info "Installing percona-toolkit..."
    if [[ "$PKG_FAMILY" == "suse" ]]; then
        $PKG_INSTALL percona-toolkit || warn "Not found in default repos — you may need to add Percona's repo: https://docs.percona.com/percona-toolkit/installation.html"
    else
        $PKG_INSTALL percona-toolkit || warn "Not found in default repos — you may need to add Percona's repo: https://docs.percona.com/percona-toolkit/installation.html"
    fi
    log "Attempted percona-toolkit install"
}

install_mytop() {
    info "Installing mytop..."
    if [[ "$PKG_FAMILY" == "suse" ]]; then
        $PKG_INSTALL mytop || warn "mytop may not be in default Tumbleweed repos — check with: zypper search mytop"
    else
        $PKG_INSTALL mytop
    fi
    log "Attempted mytop install"
    ok "mytop step done."
}

### ------------------------------------------------------------------
### 11) Python driver install
### ------------------------------------------------------------------

install_python_driver() {
    info "Python MariaDB driver options:"
    echo "  1) mariadb (official connector, needs C connector dev headers)"
    echo "  2) PyMySQL (pure Python, no C dependency)"
    echo "  0) Back to main menu"
    read -rp "Choice: " py_choice

    case "$py_choice" in
        1)
            info "Ensure C connector dev headers are installed first (menu option 2 > C connector)."
            pip3 install mariadb || pip install mariadb
            ok "Attempted install of python 'mariadb' package."
            ;;
        2)
            pip3 install pymysql || pip install pymysql
            ok "Attempted install of PyMySQL."
            ;;
        0) return ;;
        *) warn "Invalid choice." ;;
    esac
    log "Python driver install attempted (choice $py_choice)"
    pause
}

### ------------------------------------------------------------------
### 12) Java / Maven JDBC info
### ------------------------------------------------------------------

show_java_info() {
    info "MariaDB's JDBC driver isn't distributed via zypper/apt — it's a Maven Central artifact."
    echo
    echo "Add this dependency to your project's pom.xml:"
    echo
    echo "  <dependency>"
    echo "    <groupId>org.mariadb.jdbc</groupId>"
    echo "    <artifactId>mariadb-java-client</artifactId>"
    echo "    <version>3.5.1</version>"
    echo "  </dependency>"
    echo
    echo "Check https://mariadb.com/kb/en/mariadb-connector-j/ for the latest version number."
    echo
    info "For ODBC-based access, confirm the driver is registered with:"
    echo "  odbcinst -q -d"
    echo "DSN registration in /etc/odbcinst.ini and /etc/odbc.ini is a separate step — ask when you're ready to wire that up."
    log "Displayed Java/Maven JDBC info"
    pause
}

### ------------------------------------------------------------------
### Main menu
### ------------------------------------------------------------------

main_menu() {
    while true; do
        clear
        echo "=================================================================="
        echo "  MariaDB Admin Menu — ${OS_ID} (${PKG_FAMILY})"
        echo "=================================================================="
        echo "  1) Install MariaDB server + client"
        echo "  2) Install connectors / dev packages (C, C++, ODBC, GTK, Qt6, PHP)"
        echo "  3) Generate SSH key for remote tunnel access"
        echo "  4) Run mariadb-secure-installation"
        echo "  5) Create a new DB user with scoped grants"
        echo "  6) Service control (start/stop/restart/enable/disable/status)"
        echo "  7) Apply performance tuning (my.cnf)"
        echo "  8) Configure log retention (binlog + slow/error log rotation)"
        echo "  9) Run ALL setup steps in order (1,2,3,4,7,8)"
        echo " 10) Additional utility packages (mariadb-backup, percona-toolkit, mytop)"
        echo " 11) Python driver install (mariadb / PyMySQL)"
        echo " 12) Show Java/Maven JDBC dependency info"
        echo "  0) Exit"
        echo "------------------------------------------------------------------"
        read -rp "Choice: " choice

        case "$choice" in
            1) install_mariadb_core ;;
            2) install_connectors ;;
            3) generate_ssh_key ;;
            4) run_secure_installation ;;
            5) create_db_user ;;
            6) service_control_menu ;;
            7) apply_performance_tuning ;;
            8) configure_log_retention ;;
            9)
                install_mariadb_core
                install_connectors
                generate_ssh_key
                run_secure_installation
                apply_performance_tuning
                configure_log_retention
                ok "All setup steps completed."
                pause
                ;;
            10) install_utility_packages ;;
            11) install_python_driver ;;
            12) show_java_info ;;
            0) info "Exiting."; exit 0 ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

### ------------------------------------------------------------------
### Entry point
### ------------------------------------------------------------------

require_root
touch "$LOG_FILE"
detect_os
main_menu
