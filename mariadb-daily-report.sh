#!/usr/bin/env bash
#
# mariadb-daily-report.sh
#
# Daily health/performance report for a self-hosted MariaDB instance.
# Designed for debs2 (openSUSE Tumbleweed, Elite Services server).
#
# What it does:
#   - Captures memory usage (free -h)
#   - Captures MariaDB status (mysqladmin status)
#   - Checks InnoDB buffer pool utilisation and flags if it's consistently full
#   - Reports connection counts vs max_connections
#   - Pulls slow query summary from the last 24h (if slow log is enabled)
#   - Reports disk usage of the MariaDB data directory
#   - Writes a dated report file
#   - Prunes reports older than REPORT_RETENTION_DAYS
#
# Usage:
#   sudo ./mariadb-daily-report.sh
#
# Recommended: run daily via cron or a systemd timer (see bottom of this file
# for a ready-made systemd unit/timer you can install).
#
# Requires a MariaDB user with at least PROCESS and REPLICATION CLIENT
# privileges to read status cleanly without a password prompt. Easiest is
# to use a .my.cnf credentials file for root or a dedicated monitoring user
# (see NOTES section at the bottom).

set -uo pipefail

### ---- Configuration ---------------------------------------------------

REPORT_DIR="/var/log/mariadb-reports"
REPORT_RETENTION_DAYS=14          # how long to keep old daily reports
SLOW_LOG_FILE="/var/log/mysql/slow.log"
DATA_DIR="/var/lib/mysql"
DATE_STAMP="$(date '+%Y-%m-%d')"
TIME_STAMP="$(date '+%Y-%m-%d %H:%M:%S')"
REPORT_FILE="${REPORT_DIR}/report-${DATE_STAMP}.txt"

# Buffer pool utilisation threshold (%) above which we flag a recommendation
BUFFER_POOL_WARN_THRESHOLD=90

### ---- Setup ------------------------------------------------------------

mkdir -p "$REPORT_DIR"

{
echo "=================================================================="
echo " MariaDB Daily Report — ${TIME_STAMP}"
echo " Host: $(hostname)"
echo "=================================================================="
echo

### ---- Memory -------------------------------------------------------

echo "---- Memory (free -h) ----"
free -h
echo

### ---- MariaDB service status ---------------------------------------

echo "---- systemctl status mariadb ----"
systemctl status mariadb --no-pager -l | head -n 10
echo

echo "---- mysqladmin status ----"
if mysqladmin status 2>/tmp/mysqladmin_err.$$; then
    mysqladmin status
else
    echo "mysqladmin status failed — check credentials (see NOTES at bottom of script)."
    cat /tmp/mysqladmin_err.$$
fi
rm -f /tmp/mysqladmin_err.$$
echo

### ---- Connections ----------------------------------------------------

echo "---- Connections ----"
MAX_CONN=$(mysql -N -B -e "SHOW VARIABLES LIKE 'max_connections';" 2>/dev/null | awk '{print $2}')
CUR_CONN=$(mysql -N -B -e "SHOW STATUS LIKE 'Threads_connected';" 2>/dev/null | awk '{print $2}')
MAX_USED=$(mysql -N -B -e "SHOW STATUS LIKE 'Max_used_connections';" 2>/dev/null | awk '{print $2}')

if [[ -n "$MAX_CONN" && -n "$CUR_CONN" ]]; then
    echo "Current connections : ${CUR_CONN} / ${MAX_CONN}"
    echo "Peak connections used: ${MAX_USED}"
else
    echo "Could not read connection stats — check DB credentials."
fi
echo

### ---- InnoDB buffer pool ----------------------------------------------

echo "---- InnoDB Buffer Pool ----"
BP_TOTAL=$(mysql -N -B -e "SHOW STATUS LIKE 'Innodb_buffer_pool_pages_total';" 2>/dev/null | awk '{print $2}')
BP_FREE=$(mysql -N -B -e "SHOW STATUS LIKE 'Innodb_buffer_pool_pages_free';" 2>/dev/null | awk '{print $2}')

if [[ -n "$BP_TOTAL" && -n "$BP_FREE" && "$BP_TOTAL" -gt 0 ]]; then
    BP_USED=$((BP_TOTAL - BP_FREE))
    BP_PCT=$(( 100 * BP_USED / BP_TOTAL ))
    echo "Buffer pool pages total : ${BP_TOTAL}"
    echo "Buffer pool pages free  : ${BP_FREE}"
    echo "Buffer pool utilisation : ${BP_PCT}%"

    if [[ "$BP_PCT" -ge "$BUFFER_POOL_WARN_THRESHOLD" ]]; then
        echo
        echo "  *** RECOMMENDATION: buffer pool utilisation is ${BP_PCT}%,"
        echo "      at/above your ${BUFFER_POOL_WARN_THRESHOLD}% threshold."
        echo "      Consider increasing innodb_buffer_pool_size in"
        echo "      /etc/my.cnf.d/tuning.cnf if system RAM headroom allows."
    fi
else
    echo "Could not read buffer pool stats — check DB credentials."
fi
echo

### ---- Slow queries -----------------------------------------------------

echo "---- Slow Query Summary (last 24h) ----"
if [[ -f "$SLOW_LOG_FILE" ]]; then
    SLOW_COUNT=$(find "$SLOW_LOG_FILE" -mtime -1 2>/dev/null | wc -l)
    if [[ -s "$SLOW_LOG_FILE" ]]; then
        echo "Slow log location: $SLOW_LOG_FILE"
        echo "Entries matching '# Time:' in last 24h (approx query count):"
        grep -c '^# Time:' "$SLOW_LOG_FILE" 2>/dev/null || echo "0"
        echo
        echo "Top 5 slowest queries (by Query_time) currently in log:"
        awk '/^# Query_time:/{print $3, prev} {prev=$0}' "$SLOW_LOG_FILE" 2>/dev/null \
            | sort -rn | head -n 5
    else
        echo "Slow log is empty — no slow queries recorded."
    fi
else
    echo "Slow log not found at $SLOW_LOG_FILE (slow_query_log may be disabled)."
fi
echo

### ---- Disk usage ---------------------------------------------------

echo "---- Disk Usage (MariaDB data directory) ----"
if [[ -d "$DATA_DIR" ]]; then
    du -sh "$DATA_DIR" 2>/dev/null
    echo
    echo "Per-database breakdown:"
    du -sh "$DATA_DIR"/*/ 2>/dev/null | sort -rh | head -n 10
else
    echo "Data directory $DATA_DIR not found."
fi
echo

echo "---- Filesystem free space ----"
df -h / /var 2>/dev/null
echo

echo "=================================================================="
echo " End of report"
echo "=================================================================="

} > "$REPORT_FILE" 2>&1

### ---- Prune old reports ------------------------------------------------

find "$REPORT_DIR" -name 'report-*.txt' -mtime +"$REPORT_RETENTION_DAYS" -delete

echo "Report written to: $REPORT_FILE"

### ---- NOTES -------------------------------------------------------------
#
# 1. CREDENTIALS
#    For the `mysql`/`mysqladmin` calls above to work without a password
#    prompt, create a credentials file for the user running this script
#    (e.g. root, or a dedicated 'monitor' user):
#
#      cat > ~/.my.cnf << 'EOF'
#      [client]
#      user=monitor
#      password=your_monitor_password
#      EOF
#      chmod 600 ~/.my.cnf
#
#    Recommended monitoring user (least privilege):
#      CREATE USER 'monitor'@'localhost' IDENTIFIED BY 'strong_password';
#      GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'monitor'@'localhost';
#      FLUSH PRIVILEGES;
#
# 2. SCHEDULING — cron
#    sudo crontab -e
#    Add:
#      0 6 * * * /usr/local/bin/mariadb-daily-report.sh
#
# 3. SCHEDULING — systemd timer (preferred on Tumbleweed)
#
#    /etc/systemd/system/mariadb-daily-report.service
#    ------------------------------------------------
#    [Unit]
#    Description=MariaDB daily health report
#
#    [Service]
#    Type=oneshot
#    ExecStart=/usr/local/bin/mariadb-daily-report.sh
#
#    /etc/systemd/system/mariadb-daily-report.timer
#    ------------------------------------------------
#    [Unit]
#    Description=Run MariaDB daily report every day at 06:00
#
#    [Timer]
#    OnCalendar=*-*-* 06:00:00
#    Persistent=true
#
#    [Install]
#    WantedBy=timers.target
#
#    Then:
#      sudo systemctl daemon-reload
#      sudo systemctl enable --now mariadb-daily-report.timer
#      systemctl list-timers | grep mariadb
#
