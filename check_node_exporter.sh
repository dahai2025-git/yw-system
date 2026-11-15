
#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Node Exporter 自动安装与配置修复
# ==========================================

INSTALL_DIR="/data/node_exporter"
NODE_BINARY="${INSTALL_DIR}/node_exporter"
TEXTFILE_DIR="${INSTALL_DIR}/textfile"

SERVICE_NAME="node_exporter"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

INSTALL_URL="https://raw.githubusercontent.com/dahai2025-git/yw-system/main/install_node_exporter.sh"

EXPECTED_EXEC="${NODE_BINARY} --collector.textfile.directory=${TEXTFILE_DIR} --web.listen-address=:19100 --log.level=info"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# 1. 检查 root 权限
if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] 请使用 root 执行脚本"
    exit 1
fi

# 2. 检查 systemd
if ! command -v systemctl >/dev/null 2>&1; then
    log "[ERROR] 当前系统不支持 systemd"
    exit 1
fi

# 3. 检查服务状态
SERVICE_RUNNING=false

if systemctl is-active --quiet "${SERVICE_NAME}"; then
    SERVICE_RUNNING=true
    log "[INFO] node_exporter 服务正在运行"
else
    log "[INFO] node_exporter 服务未运行"
fi

# 4. 如果没有安装目录，并且服务未运行，则安装
if [[ ! -d "${INSTALL_DIR}" ]] && [[ "${SERVICE_RUNNING}" == "false" ]]; then

    log "[INFO] 未检测到安装目录，准备安装 node_exporter"

    TEMP_SCRIPT=$(mktemp)
    trap 'rm -f "${TEMP_SCRIPT}"' EXIT

    curl -fsSL "${INSTALL_URL}" -o "${TEMP_SCRIPT}"

    log "[INFO] 执行 GitHub 安装脚本..."
    bash "${TEMP_SCRIPT}"

    log "[INFO] node_exporter 安装脚本执行完成"
fi

# 5. 确保 textfile 目录存在
log "[INFO] 检查 textfile 目录..."

mkdir -p "${TEXTFILE_DIR}"
chmod 755 "${TEXTFILE_DIR}"

# 6. 检查 node_exporter 可执行文件
if [[ ! -f "${NODE_BINARY}" ]]; then
    log "[ERROR] node_exporter 文件不存在: ${NODE_BINARY}"
    exit 1
fi

if [[ ! -x "${NODE_BINARY}" ]]; then
    chmod +x "${NODE_BINARY}"
fi

# 7. 获取当前 systemd 启动命令
CURRENT_EXEC=""

if systemctl cat "${SERVICE_NAME}.service" \
    >/dev/null 2>&1; then

    CURRENT_EXEC=$(
        systemctl show "${SERVICE_NAME}.service" \
        -p ExecStart --value 2>/dev/null || true
    )
fi

# 判断当前启动命令是否符合要求
NEED_UPDATE=false

if [[ "${CURRENT_EXEC}" != *"${EXPECTED_EXEC}"* ]]; then
    NEED_UPDATE=true
    log "[WARN] 当前 ExecStart 与目标配置不一致"
else
    log "[INFO] 当前 ExecStart 配置正确"
fi

# 8. 如果 service 不存在或配置不一致，则修复
if [[ "${NEED_UPDATE}" == "true" ]] || \
   [[ ! -f "${SERVICE_FILE}" ]]; then

    log "[INFO] 更新 node_exporter Service 文件..."

    # 清理可能存在的旧 drop-in ExecStart 覆盖
    # 保留其他 systemd 配置，不主动删除 drop-in

    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=${EXPECTED_EXEC}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "${SERVICE_FILE}"

    systemctl daemon-reload

    log "[INFO] Service 文件更新完成"
fi

# 9. 确认 systemd 实际生效的 ExecStart
ACTUAL_EXEC=$(
    systemctl show "${SERVICE_NAME}.service" \
    -p ExecStart --value
)

if [[ "${ACTUAL_EXEC}" != *"${EXPECTED_EXEC}"* ]]; then
    log "[ERROR] 实际生效的 ExecStart 不符合预期"
    log "[ERROR] 请检查 systemd drop-in 覆盖配置"
    systemctl cat "${SERVICE_NAME}.service"
    exit 1
fi

# 10. 启用服务并启动或重启
systemctl enable "${SERVICE_NAME}.service"

if [[ "${NEED_UPDATE}" == "true" ]] || \
   ! systemctl is-active --quiet "${SERVICE_NAME}"; then

    log "[INFO] 启动或重启 node_exporter..."

    systemctl restart "${SERVICE_NAME}.service"
else
    log "[INFO] node_exporter 正常运行，无需重启"
fi

# 11. 验证服务
sleep 2

if systemctl is-active --quiet "${SERVICE_NAME}"; then
    log "[SUCCESS] node_exporter 服务运行正常"
else
    log "[ERROR] node_exporter 启动失败"
    journalctl -u "${SERVICE_NAME}" -n 30 --no-pager
    exit 1
fi

# 12. 检查 HTTP Metrics
if curl -fsS --max-time 5 \
    http://127.0.0.1:19100/metrics \
    -o /dev/null; then

    log "[SUCCESS] Metrics 接口正常: 19100"
else
    log "[WARN] Metrics 接口检查失败"
fi

echo
echo "========== Node Exporter 检查完成 =========="
echo "安装目录: ${INSTALL_DIR}"
echo "Service文件: ${SERVICE_FILE}"
echo "Textfile目录: ${TEXTFILE_DIR}"
echo "监听端口: 19100"
echo
echo "实际启动命令:"
systemctl show "${SERVICE_NAME}" -p ExecStart
echo
echo "服务状态:"
systemctl --no-pager status "${SERVICE_NAME}" || true
