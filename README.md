# SettingUPMariaDB
# MariaDB Server Setup & Administration Guide

**Elite Services — `debs2` (openSUSE Tumbleweed)**

A reference guide covering SSH-based remote access, MariaDB installation, user management, performance tuning, connector packages, log retention, and daily monitoring for a self-hosted MariaDB instance.

---

## Table of Contents

1. [SSH Key Setup for Remote Tunnel Access](#1-ssh-key-setup-for-remote-tunnel-access)
2. [MariaDB Initial Setup](#2-mariadb-initial-setup)
3. [Service Management](#3-service-management)
4. [Performance Tuning](#4-performance-tuning)
5. [Additional Packages & Connectors](#5-additional-packages--connectors)
6. [Log Retention](#6-log-retention)
7. [Daily Monitoring & Reporting](#7-daily-monitoring--reporting)
8. [Automation Script](#8-automation-script)

---

## 1. SSH Key Setup for Remote Tunnel Access

Remote and mobile access to MariaDB is handled via an SSH tunnel rather than exposing port 3306 directly. This keeps the database bound to `127.0.0.1` while still allowing secure access from other devices.

### 1.1 Generate the key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_alldevices -C "All_Devices"
```

Follow the prompts. A passphrase is recommended if the private key will ever live on a mobile device.

Expected output:

```
Your identification has been saved in /home/$USER/.ssh/id_ed25519_alldevices
Your public key has been saved in /home/$USER/.ssh/id_ed25519_alldevices.pub
The key fingerprint is:
SHA256:23IVwNnG3+/05NDxR4fuU7oYFwsZPU7e5gDOvNBgCjI All_Devices
```
## Questions 

### 1.2 What is the randomart image?

`ssh-keygen` displays a small ASCII-art pattern generated deterministically from the key's fingerprint. It is a **human-friendly visual checksum**, not a security mechanism:

- The same key always produces the same art; different keys produce visibly different art.
- It helps you quickly spot a mismatched key or an unexpected "host key has changed" warning (a potential MITM signal).
- It has no bearing on key strength or how SSH authenticates — purely a recognition aid.

### 1.3 Authorize the key locally

```bash
touch ~/.ssh/authorized_keys
cat ~/.ssh/id_ed25519_alldevices.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

> **Note:** `authorized_keys` is a *file*, not a directory — use `touch`, not `mkdir`. Also confirm you're appending the `.pub` file, never the private key.

### 1.4 Export the private key to another device

The private key must reach other devices without passing through cloud storage or email in plaintext.

| Method | Notes |
|---|---|
| **QR code** | `qrencode -t ansiutf8 < ~/.ssh/id_ed25519_alldevices` — good for scanning into Termux on mobile. Save a PNG backup with `qrencode -o QRCodeForAllDevices.png < ~/.ssh/id_ed25519_alldevices`. Treat the PNG with the same care as the key file itself. |
| **scp** | `scp ~/.ssh/id_ed25519_alldevices user@other-device:~/.ssh/` — works for any Linux/Mac device on the LAN. |
| **Syncthing** | Drop the key in a dedicated synced folder — keeps it off third-party cloud storage. |
| **USB cable** | Most tedious, but zero network exposure. |

Whichever method is used, lock down permissions on the receiving end:

```bash
chmod 600 id_ed25519_alldevices
```
## Questions 

#### What does `ansiutf8` mean?

An output format for `qrencode`:

- **ANSI** — uses terminal escape codes for coloured/inverted blocks.
- **UTF8** — uses Unicode block-drawing characters to pack two QR "pixels" per character vertically, keeping the correct aspect ratio.

Without it, `qrencode -t ansi` renders using plain ASCII and appears stretched, since terminal characters are taller than they are wide.

---

## 2. MariaDB Initial Setup

### 2.1 Secure installation

Run before anything else — removes anonymous users, disables remote root login, drops the test database, and reloads privileges:

```bash
sudo mariadb-secure-installation
```

### 2.2 Creating scoped database users

Avoid one blanket superuser. Use scoped accounts per purpose so a compromised app has limited blast radius:

```sql
-- Admin (full access, local management only)
CREATE USER 'mark_admin'@'localhost' IDENTIFIED BY 'strong_password_here';
GRANT ALL PRIVILEGES ON *.* TO 'mark_admin'@'localhost' WITH GRANT OPTION;

-- App-scoped (e.g. Elite Services Qt app)
CREATE USER 'elite_app'@'localhost' IDENTIFIED BY 'another_strong_password';
GRANT ALL PRIVILEGES ON elite_services.* TO 'elite_app'@'localhost';

-- Read-only (reporting/dashboards)
CREATE USER 'elite_readonly'@'localhost' IDENTIFIED BY 'yet_another_password';
GRANT SELECT ON elite_services.* TO 'elite_readonly'@'localhost';

FLUSH PRIVILEGES;
```

---

## 3. Service Management

### 3.1 systemctl commands

```bash
sudo systemctl start mariadb      # start now
sudo systemctl stop mariadb       # stop now
sudo systemctl restart mariadb    # apply config changes
sudo systemctl enable mariadb     # start automatically on boot
sudo systemctl disable mariadb    # don't start automatically on boot
sudo systemctl status mariadb     # check current state
```

Most performance settings are **not** hot-reloadable — a config change generally requires `restart`, not `reload`.

```bash
sudo systemctl reload mariadb     # only for the small subset of settings that support it
```

### 3.2 Configuration file locations

```
/etc/my.cnf              ← main config file (openSUSE)
/etc/my.cnf.d/*.cnf       ← drop-in overrides — preferred over editing my.cnf directly
```

On Debian/Ubuntu the drop-in directory is `/etc/mysql/mariadb.conf.d/` instead.

---

## 4. Performance Tuning

### 4.1 Hardware considerations

Reference hardware: Intel i3-3220 (dual-core / 4 threads, no hyperthreading), 16GB RAM. This is a home server, not a dedicated DB box — Apache, PHP, the Qt app, and ModSecurity all share the same machine, so headroom matters. Tune differently for other hardware.

### 4.2 `tuning.cnf`

Create `/etc/my.cnf.d/tuning.cnf`:

```ini
[mysqld]
# InnoDB buffer pool — size to ~50-60% of RAM, leaving room for other services
innodb_buffer_pool_size = 4G
innodb_buffer_pool_instances = 4

# Log file size — bigger reduces checkpoint I/O, increases recovery time
innodb_log_file_size = 256M
innodb_log_buffer_size = 32M

# Flush method — good default for most Linux setups
innodb_flush_method = O_DIRECT
innodb_flush_log_at_trx_commit = 1   # safest (full ACID); use 2 for more throughput, ~1s data loss risk on crash

# Connections — small home server, don't over-allocate
max_connections = 50

# Per-connection memory buffers
sort_buffer_size = 2M
read_buffer_size = 2M
join_buffer_size = 2M

# Table cache
table_open_cache = 2000

# Temp tables
tmp_table_size = 64M
max_heap_table_size = 64M

# Slow query log — catches bad queries early during development
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 1
```

### 4.3 Notes

- `innodb_buffer_pool_size = 4G` out of 16GB total leaves room for Apache, PHP-FPM, ModSecurity, and the desktop session. Increase later if MariaDB becomes the dominant workload.
- Monitor actual usage with `free -h` and `mysqladmin status` over time — don't set-and-forget.

---

## 5. Additional Packages & Connectors

### 5.1 Core utilities

```bash
sudo zypper install mariadb-client        # CLI client
sudo zypper install mariadb-tools         # mariabackup, mysqlreport-style tools
sudo zypper install mariadb-backup        # hot backup tool, better than mysqldump for larger DBs
sudo zypper install percona-toolkit       # query analysis — may require an external repo
sudo zypper install mytop                 # live top-like view of MariaDB activity
```

### 5.2 Python integration

```bash
pip install mariadb    # official connector (needs C connector dev headers)
# or
pip install pymysql    # pure-Python alternative, no C dependency
```

### 5.3 Application connectors

```bash
# C connector — required by most other connectors, including C++
sudo zypper install libmariadb-devel libmariadb3

# C++ connector
sudo zypper install mariadb-connector-cpp-devel

# ODBC connector + driver manager
sudo zypper install unixODBC unixODBC-devel MariaDB-connector-odbc

# GTK3 / GTKmm (for GUI front-ends alongside the Qt app)
sudo zypper install gtk3-devel gtkmm3-devel glibmm2-devel

# Qt6 SQL driver plugin
sudo zypper install libqt6sql6-mysql

# PHP MySQL/MariaDB extension
sudo zypper install php8-mysql
```

Verify the ODBC driver is registered:

```bash
odbcinst -q -d
```

DSN registration in `/etc/odbcinst.ini` and `/etc/odbc.ini` is a separate step, to be covered when actually wiring up an ODBC consumer.

### 5.4 Java (Maven)

MariaDB's JDBC driver isn't packaged via `zypper`/`apt` — it's distributed via Maven Central:

```xml
<dependency>
  <groupId>org.mariadb.jdbc</groupId>
  <artifactId>mariadb-java-client</artifactId>
  <version>3.5.1</version>
</dependency>
```

Check [mariadb.com/kb/en/mariadb-connector-j](https://mariadb.com/kb/en/mariadb-connector-j/) for the latest version.

---

## 6. Log Retention

Two log types, handled differently.

### 6.1 Binary logs

If binary logging is enabled (used for replication/point-in-time recovery — may not be needed on a single-box home server):

```ini
# in /etc/my.cnf.d/binlog-retention.cnf
[mysqld]
binlog_expire_logs_seconds = 172800   # 2 days
```

This is enforced live by MariaDB itself — no cron job required.

### 6.2 Slow query & error logs

```bash
sudo tee /etc/logrotate.d/mariadb-custom << 'EOF'
/var/log/mysql/slow.log
/var/log/mysql/mariadb.err
{
    daily
    rotate 2
    maxage 2
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
```

`copytruncate` lets logrotate truncate the file in place without signalling MariaDB to reopen it — no restart required.

---

## 7. Daily Monitoring & Reporting

A separate script, `mariadb-daily-report.sh`, produces a dated report covering:

- `free -h` and `mysqladmin status` snapshots
- InnoDB buffer pool utilisation %, with a recommendation if consistently near-full
- Connection count vs. `max_connections`, plus peak usage
- Slow query summary and top 5 slowest queries from the last day
- Data directory size, per-database breakdown, filesystem free space
- Automatic pruning of its own old reports (default: 14 days)

Scheduled via cron or a systemd timer — see the script's header comments for both options. Credentials for password-free `mysql`/`mysqladmin` calls should be stored in a `~/.my.cnf` file for a dedicated least-privilege `monitor` user (`PROCESS`, `REPLICATION CLIENT` only).

---

## 8. Automation Script

`mariadb-admin-menu.sh` is a menu-driven bash script that automates everything above (except daily reporting, which stays separate). It auto-detects openSUSE Tumbleweed vs. Debian/Ubuntu and adjusts package manager and config paths accordingly.

**Menu options:**

| # | Function |
|---|---|
| 1 | Install MariaDB server + client |
| 2 | Install connectors / dev packages (C, C++, ODBC, GTK3/GTKmm, Qt6, PHP) |
| 3 | Generate SSH key for remote tunnel access (QR export included) |
| 4 | Run `mariadb-secure-installation` |
| 5 | Create a DB user with scoped grants (admin / app-scoped / read-only) |
| 6 | Service control (start/stop/restart/enable/disable/status) |
| 7 | Apply performance tuning (RAM-aware buffer pool sizing) |
| 8 | Configure log retention (binlog expiry + logrotate) |
| 9 | Run all setup steps in order |
| 10 | Additional utility packages (mariadb-backup, percona-toolkit, mytop) |
| 11 | Python driver install (mariadb / PyMySQL) |
| 12 | Show Java/Maven JDBC dependency info |

Run with:

```bash
sudo /usr/local/bin/mariadb-admin-menu.sh
```

All actions are logged to `/var/log/mariadb-admin-menu.log`. Config file writes are backed up before being overwritten.

---

*Document generated from working notes — Elite Services MariaDB administration.*
