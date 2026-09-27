#!/usr/bin/env bash

set -euo pipefail

NODE_EXPORTER_VERSION="1.11.1"
NODE_EXPORTER_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

INSTALL_DIR="/data/node_exporter"
TMP_DIR="/tmp/node_exporter_install"
SERVICE_FILE="/etc/systemd/system/node_exporter.service"

RUN_USER="opuser"
RUN_GROUP="opuser"

echo "==== 安装 node_exporter ${NODE_EXPORTER_VERSION} ===="

# 必须 root 执行
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 用户执行该脚本"
    exit 1
fi

# 检查 opuser 是否存在
if ! id "$RUN_USER" >/dev/null 2>&1; then
    echo "用户 $RUN_USER 不存在，请先创建用户"
    echo "例如：useradd $RUN_USER"
    exit 1
fi

# 创建目录
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/textfile"
mkdir -p "$TMP_DIR"

cd "$TMP_DIR"

# 下载 node_exporter
echo "下载 node_exporter..."
if command -v curl >/dev/null 2>&1; then
    curl -L -o "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" "$NODE_EXPORTER_URL"
elif command -v wget >/dev/null 2>&1; then
    wget -O "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" "$NODE_EXPORTER_URL"
else
    echo "curl 和 wget 都不存在，请先安装其中一个"
    exit 1
fi

# 解压
echo "解压 node_exporter..."
tar -zxf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

# 停止旧服务
if systemctl list-unit-files | grep -q '^node_exporter.service'; then
    echo "停止旧的 node_exporter 服务..."
    systemctl stop node_exporter || true
fi

# 安装二进制
echo "安装 node_exporter 到 $INSTALL_DIR ..."
cp -f "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" "$INSTALL_DIR/node_exporter"
chmod +x "$INSTALL_DIR/node_exporter"

# 设置权限
chown -R "$RUN_USER:$RUN_GROUP" "$INSTALL_DIR"

# 写入 systemd service
echo "创建 systemd service..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Prometheus Node Exporter
Documentation=https://prometheus.io/docs/guides/node-exporter/
After=network.target

[Service]
User=opuser
Group=opuser
Type=simple
WorkingDirectory=/data/node_exporter
ExecStart=/data/node_exporter/node_exporter --collector.textfile.directory=/data/node_exporter/textfile --web.listen-address=:19100 --log.level=info
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# 重载 systemd
systemctl daemon-reload

# 开机自启动并立即启动
systemctl enable node_exporter
systemctl restart node_exporter

# 清理临时文件
rm -rf "$TMP_DIR"

echo
echo "==== node_exporter 安装完成 ===="
echo "监听端口: 19100"
echo "安装目录: $INSTALL_DIR"
echo
echo "服务状态："
systemctl status node_exporter --no-pager


sudo chown -R opuser.opuser /data/node_exporter