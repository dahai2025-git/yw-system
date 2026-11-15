
#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Nginx Logrotate 自动安装脚本
# ==========================================

LOGROTATE_DIR="/data/logrotate"
LOGROTATE_CONF="${LOGROTATE_DIR}/nginx"
LOGROTATE_LOG="${LOGROTATE_DIR}/logrotate-nginx.log"

NGINX_LOG_DIR="/data/openresty/nginx/logs"
NGINX_PID="${NGINX_LOG_DIR}/nginx.pid"

CRON_SCHEDULE="1 0 * * *"
CRON_COMMAND="/usr/sbin/logrotate -vf ${LOGROTATE_CONF} >> ${LOGROTATE_LOG} 2>&1"

echo "========== Nginx Logrotate 安装 =========="

# 1. 检查 root 权限
if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] 请使用 root 运行脚本"
    exit 1
fi

# 2. 安装 logrotate
if ! command -v logrotate >/dev/null 2>&1; then
    echo "[INFO] 安装 logrotate..."

    if command -v dnf >/dev/null 2>&1; then
        dnf install -y logrotate
    elif command -v yum >/dev/null 2>&1; then
        yum install -y logrotate
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y logrotate
    else
        echo "[ERROR] 不支持的包管理器"
        exit 1
    fi
fi

# 检查 logrotate 执行路径
if [[ ! -x /usr/sbin/logrotate ]]; then
    echo "[ERROR] /usr/sbin/logrotate 不存在"
    exit 1
fi

# 3. 检查 Nginx 日志目录
if [[ ! -d "${NGINX_LOG_DIR}" ]]; then
    echo "[ERROR] Nginx 日志目录不存在: ${NGINX_LOG_DIR}"
    exit 1
fi

# 4. 创建配置目录
mkdir -p "${LOGROTATE_DIR}"
chmod 755 "${LOGROTATE_DIR}"

touch "${LOGROTATE_LOG}"
chmod 640 "${LOGROTATE_LOG}"

# 5. 生成 logrotate 配置
echo "[INFO] 生成 Logrotate 配置..."

cat > "${LOGROTATE_CONF}" <<EOF
${NGINX_LOG_DIR}/*.log {
    create 0640 root root
    daily
    rotate 1
    dateext
    missingok
    notifempty
    #compress
    delaycompress
    sharedscripts
    postrotate
        /bin/kill -USR1 \$(cat ${NGINX_PID} 2>/dev/null) 2>/dev/null || true
    endscript
}
EOF

chmod 644 "${LOGROTATE_CONF}"

# 6. 检查配置语法
echo "[INFO] 检查 Logrotate 配置..."
/usr/sbin/logrotate -d "${LOGROTATE_CONF}" \
    > /dev/null

# 7. 安装 Crontab
echo "[INFO] 配置 Crontab..."

CRON_FILE=$(mktemp)
trap 'rm -f "${CRON_FILE}"' EXIT

# 保留 root 原有定时任务
crontab -l 2>/dev/null > "${CRON_FILE}" || true

# 删除旧的同类定时任务，避免重复
sed -i "\|/usr/sbin/logrotate .*${LOGROTATE_CONF}|d" "${CRON_FILE}"

# 添加新任务
echo "${CRON_SCHEDULE} ${CRON_COMMAND}" >> "${CRON_FILE}"

crontab "${CRON_FILE}"

# 8. 确保 cron 服务运行
if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files crond.service --no-legend 2>/dev/null \
        | grep -q '^crond.service'; then
        systemctl enable --now crond
    elif systemctl list-unit-files cron.service --no-legend 2>/dev/null \
        | grep -q '^cron.service'; then
        systemctl enable --now cron
    fi
fi

echo
echo "========== 安装完成 =========="
echo "配置文件: ${LOGROTATE_CONF}"
echo "运行日志: ${LOGROTATE_LOG}"
echo "Nginx PID: ${NGINX_PID}"
echo "执行时间: 每天 00:01"
echo
echo "当前定时任务:"
crontab -l | grep -F "${LOGROTATE_CONF}" || true
echo
echo "手动测试命令:"
echo "/usr/sbin/logrotate -vf ${LOGROTATE_CONF}"