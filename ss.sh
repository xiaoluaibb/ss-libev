#!/bin/bash

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查是否以root用户运行
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：请以root用户运行此脚本 (sudo ./ss.sh)${NC}"
  exit 1
fi

# 配置文件目录
SS_CONFIG_DIR="/etc/shadowsocks-libev"
# 默认主服务单元名称
DEFAULT_SS_SERVICE_NAME="shadowsocks-libev.service"

# --- 函数定义 ---

# 检查并安装 jq (用于处理JSON)
install_jq() {
    echo -e "${YELLOW}正在检查 'jq' 命令是否安装 (用于处理JSON配置)...${NC}"
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}'jq' 命令未找到，正在安装 'jq'....${NC}"
        apt update > /dev/null 2>&1
        apt install -y jq > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo -e "${RED}'jq' 安装失败。部分功能可能受限。请手动安装：sudo apt install jq${NC}"
            return 1
        fi
        echo -e "${GREEN}'jq' 安装完成。${NC}"
    else
        echo -e "${GREEN}'jq' 已安装。${NC}"
    fi
    return 0
}

# 检查并安装 shadowsocks-libev
install_ss_libev() {
    echo -e "${YELLOW}正在检查 shadowsocks-libev 是否安装...${NC}"
    if ! dpkg -s shadowsocks-libev >/dev/null 2>&1; then
        echo -e "${YELLOW}shadowsocks-libev 未安装，正在安装...${NC}"
        apt update && apt install -y shadowsocks-libev
        if [ $? -ne 0 ]; then
            echo -e "${RED}shadowsocks-libev 安装失败。请检查您的APT源或网络连接。${NC}"
            return 1
        fi
        echo -e "${GREEN}shadowsocks-libev 安装完成。${NC}"
    else
        echo -e "${GREEN}'shadowsocks-libev' 已安装。${NC}"
    fi
    return 0
}

# 获取公共 IPv4 地址 (优先使用icanhazip.com，备用ident.me和ip.sb)
get_public_ipv4() {
    local public_ipv4=""
    # 尝试从多个服务获取公共 IPv4 地址
    public_ipv4=$(curl -s4 "https://icanhazip.com" || curl -s4 "https://ident.me" || curl -s4 "http://ip.sb")
    echo "$public_ipv4" # 返回获取到的IP
}

# 获取公共 IPv6 地址 (优先使用icanhazip.com，备用ident.me和ip.sb)
get_public_ipv6() {
    local public_ipv6=""
    # 尝试从多个服务获取公共 IPv6 地址
    public_ipv6=$(curl -s6 "https://icanhazip.com" || curl -s6 "https://ident.me" || curl -s6 "http://ip.sb")
    echo "$public_ipv6" # 返回获取到的IP
}

# 生成 SS 链接 (base64编码) 需要server_ip, server_port, method, password
generate_ss_link() {
    local server_ip=$1
    local server_port=$2
    local method=$3
    local password=$4

    # 将方法和密码Base64编码
    local credentials_raw="${method}:${password}"
    local credentials_base64=$(echo -n "$credentials_raw" | base64 -w 0) # -w 0 防止换行

    # 生成 ss:// 链接
    echo "ss://${credentials_base64}@${server_ip}:${server_port}#Shadowsocks_Node"
}

# 配置 Shadowsocks 节点
configure_ss_node() {
    local config_file_path=$1 # 配置文件路径，如 /etc/shadowsocks-libev/config.json
    echo -e "\n--- ${BLUE}配置 Shadowsocks 节点${NC} ---"

    # 确保配置目录存在
    mkdir -p "$SS_CONFIG_DIR"
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：无法创建配置目录 '${SS_CONFIG_DIR}'。请检查权限或尝试手动创建。${NC}"
        return 1
    fi

    # 默认节点配置
    local DEFAULT_SS_SERVER_ADDR_IPV4="0.0.0.0"
    local DEFAULT_SS_SERVER_PORT="12306" # 默认端口
    local DEFAULT_SS_PASSWORD="xiaolu668" # 默认密码，请务必修改，否则不安全
    local DEFAULT_SS_METHOD="aes-256-gcm" # 默认加密方法
    local DEFAULT_SS_TIMEOUT="300"

    echo -e "${YELLOW}开始配置 Shadowsocks 节点。${NC}"
    echo -e "${YELLOW}(回车使用默认值)${NC}"

    local SS_SERVER_ADDR_CONFIG="" # 实际用于配置文件的地址
    local SS_SERVER_ADDR_DISPLAY="" # 用于显示给用户的地址
    local IS_IPV6_ENABLED="false" # 标记是否启用IPv6

    # 检查当前服务器是否支持IPv6地址
    local public_ipv6_test=$(get_public_ipv6)
    if [ -n "$public_ipv6_test" ]; then
        SS_SERVER_ADDR_CONFIG='["::0", "0.0.0.0"]' # JSON 数组格式
        SS_SERVER_ADDR_DISPLAY="::0, 0.0.0.0" # 显示格式
        IS_IPV6_ENABLED="true"
        echo -e "${GREEN}检测到服务器支持 IPv6 地址，将同时监听 IPv4 和 IPv6 地址。${NC}"
    else
        SS_SERVER_ADDR_CONFIG="\"$DEFAULT_SS_SERVER_ADDR_IPV4\"" # 单引号IP地址
        SS_SERVER_ADDR_DISPLAY="$DEFAULT_SS_SERVER_ADDR_IPV4" # 显示格式
        IS_IPV6_ENABLED="false"
        echo -e "${GREEN}未检测到服务器支持 IPv6 地址，将仅监听 IPv4 地址。${NC}"
    fi

    # 输入端口
    read -p "请输入 Shadowsocks 监听端口 (默认: ${DEFAULT_SS_SERVER_PORT}): " SS_SERVER_PORT_INPUT
    if [ -z "$SS_SERVER_PORT_INPUT" ]; then
        SS_SERVER_PORT="$DEFAULT_SS_SERVER_PORT"
        echo -e "${GREEN}使用默认端口: ${SS_SERVER_PORT}${NC}"
    else
        SS_SERVER_PORT="$SS_SERVER_PORT_INPUT"
    fi
    while ! [[ "$SS_SERVER_PORT" =~ ^[0-9]+$ ]] || [ "$SS_SERVER_PORT" -lt 1 ] || [ "$SS_SERVER_PORT" -gt 65535 ]; do
        echo -e "${RED}端口号无效。请输入1到65535之间的数字。${NC}"
        read -p "请重新输入 Shadowsocks 监听端口 (默认: ${DEFAULT_SS_SERVER_PORT}): " SS_SERVER_PORT_INPUT
        if [ -z "$SS_SERVER_PORT_INPUT" ]; then
            SS_SERVER_PORT="$DEFAULT_SS_SERVER_PORT"
            echo -e "${GREEN}使用默认端口: ${SS_SERVER_PORT}${NC}"
        else
            SS_SERVER_PORT="$SS_SERVER_PORT_INPUT"
        fi
    done

    # 输入密码 (显示输入)
    read -p "请输入 Shadowsocks 连接密码 (默认: ${DEFAULT_SS_PASSWORD}): " SS_PASSWORD_INPUT
    if [ -z "$SS_PASSWORD_INPUT" ]; then
        SS_PASSWORD="$DEFAULT_SS_PASSWORD"
        echo -e "${GREEN}使用默认密码: ${SS_PASSWORD}${NC}"
    else
        SS_PASSWORD="$SS_PASSWORD_INPUT"
    fi

    # 选择加密方法 - 推荐带AEAD的算法 (例如 2022)
    echo -e "\n${YELLOW}请选择 Shadowsocks 加密方法：${NC}"
    local CRYPTO_METHODS=(
        "aes-256-gcm" # 推荐
        "aes-192-gcm"
        "aes-128-gcm"
        "aes-256-ctr"
        "aes-192-ctr"
        "aes-128-ctr"
        "aes-256-cfb"
        "aes-192-cfb"
        "aes-128-cfb"
        "camellia-128-cfb"
        "camellia-192-cfb"
        "camellia-256-cfb"
        "xchacha20-ietf-poly1305" # 推荐
        "chacha20-ietf-poly1305" # 推荐
        "chacha20-ietf"
        "chacha20"
        "salsa20"
        "rc4-md5"
        "2022-blake3-aes-256-gcm" # 新一代加密方法
        "none" # 不加密 (不推荐，仅用于调试)
    )
    local default_method_index=-1
    for i in "${!CRYPTO_METHODS[@]}"; do
        if [[ "${CRYPTO_METHODS[$i]}" == "$DEFAULT_SS_METHOD" ]]; then
            default_method_index=$i
        fi
        echo -e " ${BLUE}$((i+1)).${NC} ${CRYPTO_METHODS[$i]}" $( [[ \
            "${CRYPTO_METHODS[$i]}" == "aes-256-gcm" || "${CRYPTO_METHODS[$i]}" == "chacha20-ietf-poly1305" || \
            "${CRYPTO_METHODS[$i]}" == "xchacha20-ietf-poly1305" || "${CRYPTO_METHODS[$i]}" == \
            "2022-blake3-aes-256-gcm" ]] && echo "(推荐)" || echo "" ) ${NC}
    done
    local SS_METHOD_CHOICE
    read -p "请选择加密方法 (1-${#CRYPTO_METHODS[@]}, 默认 $((default_method_index+1))): " SS_METHOD_CHOICE_INPUT
    if [ -z "$SS_METHOD_CHOICE_INPUT" ]; then
        SS_METHOD="${CRYPTO_METHODS[$default_method_index]}"
        echo -e "${GREEN}使用默认加密方法: ${SS_METHOD}${NC}"
    else
        if [[ "$SS_METHOD_CHOICE_INPUT" =~ ^[0-9]+$ ]] && [ "$SS_METHOD_CHOICE_INPUT" -ge 1 ] && [ \
            "$SS_METHOD_CHOICE_INPUT" -le ${#CRYPTO_METHODS[@]} ]; then
            SS_METHOD="${CRYPTO_METHODS[$((SS_METHOD_CHOICE_INPUT-1))]}"
            echo -e "${GREEN}已选择加密方法: ${SS_METHOD}${NC}"
        else
            echo -e "${RED}输入无效，使用默认加密方法: ${DEFAULT_SS_METHOD}${NC}"
            SS_METHOD="$DEFAULT_SS_METHOD"
        fi
    fi

    # 输入超时时间
    read -p "请输入 Shadowsocks 超时时间 (秒, 默认: ${DEFAULT_SS_TIMEOUT}): " SS_TIMEOUT_INPUT
    if [ -z "$SS_TIMEOUT_INPUT" ]; then
        SS_TIMEOUT="$DEFAULT_SS_TIMEOUT"
        echo -e "${GREEN}使用默认超时时间: ${SS_TIMEOUT}${NC}"
    else
        SS_TIMEOUT="$SS_TIMEOUT_INPUT"
    fi
    while ! [[ "$SS_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$SS_TIMEOUT" -lt 1 ]; do
        echo -e "${RED}超时时间无效。请输入一个大于0的整数。${NC}"
        read -p "请输入 Shadowsocks 超时时间 (秒, 默认: ${DEFAULT_SS_TIMEOUT}): " SS_TIMEOUT_INPUT
        if [ -z "$SS_TIMEOUT_INPUT" ]; then
            SS_TIMEOUT="$DEFAULT_SS_TIMEOUT"
            echo -e "${GREEN}使用默认超时时间: ${SS_TIMEOUT}${NC}"
        else
            SS_TIMEOUT="$SS_TIMEOUT_INPUT"
        fi
    done

    echo -e "\n${YELLOW}正在生成 Shadowsocks-libev 配置文件: ${config_file_path}...${NC}"
    # 写入配置文件 - fast_open 设为 false，mode 设为 tcp_and_udp
    cat <<EOF > "$config_file_path"
{
  "server":$SS_SERVER_ADDR_CONFIG,
  "server_port":$SS_SERVER_PORT,
  "password":"$SS_PASSWORD",
  "method":"$SS_METHOD",
  "timeout":$SS_TIMEOUT,
  "fast_open":false,
  "mode":"tcp_and_udp"
}
EOF
    if [ $? -ne 0 ]; then
        echo -e "${RED}配置文件生成失败。请检查目录权限或磁盘空间。${NC}"
        return 1
    fi
    echo -e "${GREEN}配置文件生成完成。${NC}"
    echo -e "${BLUE}配置文件路径: ${GREEN}${config_file_path}${NC}" # 显示完整配置文件路径

    # 根据配置文件路径确定服务实例名称
    local service_instance=""
    if [ "$config_file_path" = "${SS_CONFIG_DIR}/config.json" ]; then
        service_instance="${DEFAULT_SS_SERVICE_NAME}" # 默认主实例
    else
        # 尝试从配置文件中读取端口号来创建服务实例名称
        local port_from_file=$(jq -r '.server_port' "$config_file_path" 2>/dev/null)
        service_instance="${DEFAULT_SS_SERVICE_NAME%.service}@${port_from_file}.service" # 例如 shadowsocks-libev@8389.service
    fi

    echo -e "\n${YELLOW}正在启动 Shadowsocks-libev 服务 (${service_instance}) 并设置开机自启....${NC}"
    # 停止、禁用（如果存在）旧的服务，防止端口占用等问题
    echo -e "${YELLOW}正在停止旧的服务...${NC}"
    systemctl stop "${service_instance}" > /dev/null 2>&1 || true # 忽略停止失败，可能未运行
    echo -e "${YELLOW}正在禁用旧的服务 (防止开机自启)...${NC}"
    systemctl disable "${service_instance}" > /dev/null 2>&1 || true
    echo -e "${YELLOW}重载 Systemd 配置...${NC}"
    systemctl daemon-reload
    echo -e "${YELLOW}启用并启动服务...${NC}"
    systemctl enable "${service_instance}"
    systemctl start "${service_instance}"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Shadowsocks-libev 服务 (${service_instance}) 已成功启动并设置为开机自启！${NC}"
        echo -e "${BLUE}当前配置信息:${NC}"
        echo -e " ${BLUE}监听地址: ${GREEN}$SS_SERVER_ADDR_DISPLAY${NC}" # 显示实际监听的IP
        echo -e " ${BLUE}监听端口: ${GREEN}$SS_SERVER_PORT${NC}"
        echo -e " ${BLUE}加密方法: ${GREEN}$SS_METHOD${NC}"
        echo -e " ${BLUE}超时时间: ${GREEN}$SS_TIMEOUT${NC} 秒"
        echo -e " ${BLUE}协议: ${GREEN}TCP and UDP${NC}" # 强制TCP和UDP

        # 显示 SS 链接
        echo -e "\n${GREEN}请复制以下 SS 链接到您的客户端使用：${NC}"

        # 获取并显示 IPv4 SS 链接
        local public_ipv4=$(get_public_ipv4)
        if [ -n "$public_ipv4" ]; then
            echo -e "${BLUE}IPv4 SS 链接:${NC}"
            NODE_LINK_IPV4=$(generate_ss_link "$public_ipv4" "$SS_SERVER_PORT" "$SS_METHOD" "$SS_PASSWORD")
            echo -e "${YELLOW}${NODE_LINK_IPV4}${NC}"
        else
            echo -e "${RED}警告：无法获取公共 IPv4 地址，无法生成 IPv4 SS 链接。${NC}"
        fi

        # 如果启用了 IPv6，则获取并显示 IPv6 SS 链接
        if [ "$IS_IPV6_ENABLED" = "true" ]; then
            local public_ipv6=$(get_public_ipv6)
            if [ -n "$public_ipv6" ]; then
                echo -e "${BLUE}IPv6 SS 链接:${NC}"
                NODE_LINK_IPV6=$(generate_ss_link "[$public_ipv6]" "$SS_SERVER_PORT" "$SS_METHOD" "$SS_PASSWORD") # IPv6 地址需要用方括号括起来
                echo -e "${YELLOW}${NODE_LINK_IPV6}${NC}"
            else
                echo -e "${YELLOW}提示：虽然检测到IPv6支持，但无法获取公共 IPv6 地址，无法生成 IPv6 SS 链接。${NC}"
            fi
        fi
        echo -e "${BLUE}(提示：SS 链接中的 IP 地址是当前服务器的公共 IP)${NC}"

    else
        echo -e "${RED}Shadowsocks-libev 服务 (${service_instance}) 启动失败。请检查日志 (journalctl -u ${service_instance}) 以获取更多信息。${NC}"
    fi

    echo -e "\n--- ${GREEN}配置完成${NC} ---"
    echo -e "您可以使用 'systemctl status ${service_instance}' 查看服务状态。"
}

# 新增 Shadowsocks 节点（端口、密码、加密方式可自定义）
add_new_ss_node() {
    echo -e "\n--- ${BLUE}新增 Shadowsocks 节点${NC} ---"
    local config_name=""
    while true; do
        read -p "请输入新节点的名称 (例如: my_node_8888, 仅支持字母、数字、下划线): " config_name
        if [[ "$config_name" =~ ^[a-zA-Z0-9_]+$ ]]; then
            if [ -f "${SS_CONFIG_DIR}/${config_name}.json" ]; then
                echo -e "${RED}错误：节点名称 '${config_name}' 已存在。请选择其他名称。${NC}"
            else
                break
            fi
        else
            echo -e "${RED}错误：无效的节点名称。请仅使用字母、数字和下划线。${NC}"
        fi
    done
    configure_ss_node "${SS_CONFIG_DIR}/${config_name}.json"
}

# 卸载 Shadowsocks-libev
uninstall_ss() {
    echo -e "\n--- ${RED}卸载 Shadowsocks-libev${NC} ---"
    read -p "确定要完全卸载 Shadowsocks-libev 及其所有配置节点吗？此操作不可逆！(y/N): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        echo -e "${YELLOW}正在停止并禁用所有 Shadowsocks-libev 服务实例...${NC}"

        # 停止并禁用 shadowsocks-libev@*.service 实例
        systemctl list-units --type=service --all | grep "shadowsocks-libev@" | awk '{print $1}' | while read -r service_name; do
            echo -e "${YELLOW}停止并禁用: ${service_name}${NC}"
            systemctl stop "$service_name" > /dev/null 2>&1
            systemctl disable "$service_name" > /dev/null 2>&1
        done

        # 停止并禁用默认 shadowsocks-libev.service
        if systemctl list-units --type=service --all | grep -q "${DEFAULT_SS_SERVICE_NAME}"; then
            echo -e "${YELLOW}停止并禁用: ${DEFAULT_SS_SERVICE_NAME}${NC}"
            systemctl stop "${DEFAULT_SS_SERVICE_NAME}" > /dev/null 2>&1
            systemctl disable "${DEFAULT_SS_SERVICE_NAME}" > /dev/null 2>&1
        fi

        echo -e "${YELLOW}尝试终止所有 ss-server 进程...${NC}"
        # 尝试通过 pgrep 查找 ss-server 进程并终止 (如果仍在运行)
        PIDS=$(pgrep -f "ss-server")
        if [ -n "$PIDS" ]; then
            echo -e "${YELLOW}找到正在运行的 ss-server 进程 PID: ${PIDS}，正在终止...${NC}"
            kill -9 $PIDS > /dev/null 2>&1 || true
            sleep 1 # 等待进程结束
            # 再次检查是否完全终止
            PIDS_AFTER_KILL=$(pgrep -f "ss-server")
            if [ -n "$PIDS_AFTER_KILL" ]; then
                echo -e "${RED}警告：部分 ss-server 进程未能终止 (PID: ${PIDS_AFTER_KILL})。可能需要手动清理。${NC}"
            else
                echo -e "${GREEN}ss-server 进程已成功终止。${NC}"
            fi
        else
            echo -e "${YELLOW}未找到任何 ss-server 进程。${NC}"
        fi

        echo -e "${YELLOW}正在卸载 shadowsocks-libev 软件包...${NC}"
        apt purge -y shadowsocks-libev > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo -e "${RED}警告：卸载软件包时发生错误，请手动执行：sudo apt purge -y shadowsocks-libev${NC}"
        fi

        echo -e "${YELLOW}正在删除所有 Shadowsocks 配置文件...${NC}"
        rm -rf "$SS_CONFIG_DIR" # 删除整个配置目录
        if [ $? -ne 0 ]; then
            echo -e "${RED}警告：删除配置文件时发生错误，请手动删除目录：rm -rf ${SS_CONFIG_DIR}${NC}"
        fi

        # 刷新 Systemd 状态，确保服务已完全移除
        echo -e "${YELLOW}刷新 Systemd 配置并清理残留...${NC}"
        systemctl daemon-reload
        systemctl reset-failed # 重置所有失败的服务，确保状态干净

        echo -e "${GREEN}Shadowsocks-libev 已成功卸载！${NC}"
        # 退出脚本，因为卸载是最终操作
        exit 0
    else
        echo -e "${BLUE}取消卸载。${NC}"
    fi
}

# 查看 Shadowsocks-libev 运行状态
check_status() {
    echo -e "\n--- ${BLUE}Shadowsocks-libev 运行状态${NC} ---"
    local found_services=false

    # 检查默认服务实例
    if systemctl list-units --type=service --all | grep -q "${DEFAULT_SS_SERVICE_NAME}"; then
        echo -e "\n${BLUE}服务: ${DEFAULT_SS_SERVICE_NAME}${NC}"
        systemctl status "${DEFAULT_SS_SERVICE_NAME}" --no-pager
        found_services=true
    fi

    # 检查所有 Shadowsocks-libev@*.service 实例
    systemctl list-units --type=service --all | grep "shadowsocks-libev@" | awk '{print $1}' | while read -r service_name; do
        # 排除默认服务实例，避免重复检查
        if [[ "$service_name" != "${DEFAULT_SS_SERVICE_NAME}" ]]; then
            echo -e "\n${BLUE}服务: ${service_name}${NC}"
            systemctl status "$service_name" --no-pager
            found_services=true
        fi
    done

    if [ "$found_services" = false ]; then
        echo -e "${YELLOW}未找到任何 Shadowsocks-libev 服务实例。${NC}"
    fi

    echo -e "\n${BLUE}正在检查 ss-server 进程...${NC}"
    if command -v pgrep &> /dev/null; then
        local ss_pids=$(pgrep -f "ss-server")
        if [ -n "$ss_pids" ]; then
            echo -e "${RED}检测到 ss-server 进程正在运行 (PID: ${ss_pids})！${NC}"
            ps -fp "$ss_pids"
        else
            echo -e "${GREEN}未找到 ss-server 进程。${NC}"
        fi
    else
        echo -e "${YELLOW}pgrep 命令未找到，无法精确查找 ss-server 进程。${NC}"
        echo -e "${YELLOW}请尝试运行 'ps aux | grep ss-server' 检查。${NC}"
    fi

    echo -e "\n${BLUE}正在检查 12306 端口是否被占用...${NC}"
    if command -v lsof &> /dev/null; then
        lsof -i:12306
        if [ $? -ne 0 ]; then
            echo -e "${GREEN}端口 12306 未被占用。${NC}"
        fi
    else
        echo -e "${YELLOW}lsof 命令未找到，无法检查端口占用情况。${NC}"
        echo -e "${YELLOW}请尝试运行 'netstat -tulnp | grep 12306' 或 'ss -tulnp | grep 12306' 检查。${NC}"
    fi
}

# 停止 Shadowsocks-libev 服务
stop_service() {
    echo -e "\n--- ${BLUE}停止 Shadowsocks-libev 服务${NC} ---"
    local has_services=false
    local i=1
    local services_to_manage=()

    # 列出所有服务实例
    if systemctl list-units --type=service --all | grep -q "${DEFAULT_SS_SERVICE_NAME}"; then
        services_to_manage+=("${DEFAULT_SS_SERVICE_NAME}")
        echo -e " ${BLUE}${i}.${NC} ${DEFAULT_SS_SERVICE_NAME}"
        i=$((i+1))
        has_services=true
    fi
    systemctl list-units --type=service --all | grep "shadowsocks-libev@" | awk '{print $1}' | while read -r service_name; do
        if [[ "$service_name" != "${DEFAULT_SS_SERVICE_NAME}" ]]; then # 避免重复显示默认服务
            services_to_manage+=("$service_name")
            echo -e " ${BLUE}${i}.${NC} ${service_name}"
            i=$((i+1))
            has_services=true
        fi
    done

    if [ "$has_services" = false ]; then
        echo -e "${YELLOW}未找到任何可停止的 Shadowsocks-libev 服务实例。${NC}"
        return
    fi

    echo -e " ${BLUE}0.${NC} 返回主菜单"
    read -p "请选择要停止的服务 (0-$((i-1))): " choice
    if [ "$choice" -eq 0 ]; then
        echo -e "${BLUE}已取消操作。${NC}"
        return
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $((i-1)) ]; then
        local selected_service=${services_to_manage[$((choice-1))]}
        systemctl stop "$selected_service"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}服务 '${selected_service}' 已成功停止。${NC}"
        else
            echo -e "${RED}停止服务 '${selected_service}' 失败。请检查服务状态。${NC}"
        fi
    else
        echo -e "${RED}无效的选择。${NC}"
    fi
}

# 重启 Shadowsocks-libev 服务
restart_service() {
    echo -e "\n--- ${BLUE}重启 Shadowsocks-libev 服务${NC} ---"
    local has_services=false
    local i=1
    local services_to_manage=()

    # 列出所有服务实例
    if systemctl list-units --type=service --all | grep -q "${DEFAULT_SS_SERVICE_NAME}"; then
        services_to_manage+=("${DEFAULT_SS_SERVICE_NAME}")
        echo -e " ${BLUE}${i}.${NC} ${DEFAULT_SS_SERVICE_NAME}"
        i=$((i+1))
        has_services=true
    fi
    systemctl list-units --type=service --all | grep "shadowsocks-libev@" | awk '{print $1}' | while read -r service_name; do
        if [[ "$service_name" != "${DEFAULT_SS_SERVICE_NAME}" ]]; then
            services_to_manage+=("$service_name")
            echo -e " ${BLUE}${i}.${NC} ${service_name}"
            i=$((i+1))
            has_services=true
        fi
    done

    if [ "$has_services" = false ]; then
        echo -e "${YELLOW}未找到任何可重启的 Shadowsocks-libev 服务实例。${NC}"
        return
    fi

    echo -e " ${BLUE}0.${NC} 返回主菜单"
    read -p "请选择要重启的服务 (0-$((i-1))): " choice
    if [ "$choice" -eq 0 ]; then
        echo -e "${BLUE}已取消操作。${NC}"
        return
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $((i-1)) ]; then
        local selected_service=${services_to_manage[$((choice-1))]}
        systemctl restart "$selected_service"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}服务 '${selected_service}' 已成功重启。${NC}"
        else
            echo -e "${RED}重启服务 '${selected_service}' 失败。请检查服务状态。${NC}"
        fi
    else
        echo -e "${RED}无效的选择。${NC}"
    fi
}

# 查看所有 Shadowsocks 节点当前配置及 SS 链接
view_current_config() {
    echo -e "\n--- ${BLUE}所有 Shadowsocks 节点配置与 SS 链接${NC} ---"
    local found_configs=false

    # 查找所有 shadowsocks-libev 的配置文件
    find "$SS_CONFIG_DIR" -maxdepth 1 -name "*.json" | while read -r config_file; do
        found_configs=true
        echo -e "\n${BLUE}配置文件: ${config_file}${NC}"
        if ! command -v jq &> /dev/null; then
            echo -e "${RED}错误：未安装 'jq'，无法解析配置文件。请手动安装：sudo apt install jq${NC}"
            continue
        fi

        local server_ip_config=$(jq -r '.server' "$config_file" 2>/dev/null)
        local server_port=$(jq -r '.server_port' "$config_file" 2>/dev/null)
        local password=$(jq -r '.password' "$config_file" 2>/dev/null)
        local method=$(jq -r '.method' "$config_file" 2>/dev/null)
        local timeout=$(jq -r '.timeout' "$config_file" 2>/dev/null)
        local fast_open=$(jq -r '.fast_open' "$config_file" 2>/dev/null)
        local mode=$(jq -r '.mode' "$config_file" 2>/dev/null)

        echo -e "  ${BLUE}监听地址 (配置文件): ${GREEN}$server_ip_config${NC}"
        echo -e "  ${BLUE}监听端口: ${GREEN}$server_port${NC}"
        echo -e "  ${BLUE}加密方法: ${GREEN}$method${NC}"
        echo -e "  ${BLUE}密码: ${GREEN}$password${NC}"
        echo -e "  ${BLUE}超时时间: ${GREEN}$timeout${NC} 秒"
        echo -e "  ${BLUE}快速打开: ${GREEN}$fast_open${NC}"
        echo -e "  ${BLUE}模式: ${GREEN}$mode${NC}"

        echo -e "  ${BLUE}SS 链接:${NC}"
        # 获取公共 IPv4 地址并生成链接
        local public_ipv4=$(get_public_ipv4)
        if [ -n "$public_ipv4" ]; then
            local node_link_ipv4=$(generate_ss_link "$public_ipv4" "$server_port" "$method" "$password")
            echo -e "    ${BLUE}IPv4:${NC} ${YELLOW}${node_link_ipv4}${NC}"
        else
            echo -e "    ${RED}无法获取公共 IPv4 地址，无法生成 IPv4 SS 链接。${NC}"
        fi

        # 检查配置文件中的监听地址是否包含 IPv6 (简化判断，实际应更严谨)
        if echo "$server_ip_config" | grep -q "::0"; then
            local public_ipv6=$(get_public_ipv6)
            if [ -n "$public_ipv6" ]; then
                local node_link_ipv6=$(generate_ss_link "[$public_ipv6]" "$server_port" "$method" "$password") # IPv6 地址需要方括号
                echo -e "    ${BLUE}IPv6:${NC} ${YELLOW}${node_link_ipv6}${NC}"
            else
                echo -e "    ${YELLOW}服务器支持 IPv6，但无法获取公共 IPv6 地址，无法生成 IPv6 SS 链接。${NC}"
            fi
        fi
    done

    if [ "$found_configs" = false ]; then
        echo -e "${YELLOW}未找到任何 Shadowsocks 配置文件。请先安装或配置节点。${NC}"
    fi
}


# --- 主菜单 ---
main_menu() {
    while true; do
        echo -e "\n--- ${BLUE}Shadowsocks-libev 管理脚本${NC} ---"
        echo -e "${BLUE}1.${NC} ${YELLOW}安装/重新配置默认节点 (端口: 12306)${NC}"
        echo -e "${BLUE}2.${NC} ${YELLOW}新增 Shadowsocks 节点${NC}"
        echo -e "${BLUE}3.${NC} ${RED}卸载 Shadowsocks-libev 及所有节点${NC}"
        echo -e "${BLUE}4.${NC} ${GREEN}查看所有 Shadowsocks 节点运行状态${NC}"
        echo -e "${BLUE}5.${NC} ${YELLOW}停止 Shadowsocks 服务实例${NC}"
        echo -e "${BLUE}6.${NC} ${YELLOW}重启 Shadowsocks 服务实例${NC}"
        echo -e "${BLUE}7.${NC} ${GREEN}查看所有 Shadowsocks 节点当前配置及 SS 链接${NC}"
        echo -e "${BLUE}0.${NC} ${YELLOW}退出${NC}"
        echo -e "------------------------------------"
        read -p "请选择一个操作 (0-7): " choice
        echo ""

        case "$choice" in
            1)
                # 默认主实例配置文件路径
                configure_ss_node "${SS_CONFIG_DIR}/config.json"
                ;;
            2)
                add_new_ss_node
                ;;
            3)
                uninstall_ss
                ;; # 卸载函数内部已包含退出逻辑
            4)
                check_status
                ;;
            5)
                stop_service
                ;;
            6)
                restart_service
                ;;
            7)
                view_current_config
                ;;
            0)
                echo -e "${BLUE}感谢使用，再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选择，请重新输入。${NC}"
                ;;
        esac
    done
}

# --- 脚本执行开始 ---
# 检查并安装 jq
install_jq || { echo -e "${RED}jq 安装失败，退出脚本。${NC}"; exit 1; }
# 检查并安装 shadowsocks-libev
install_ss_libev || { echo -e "${RED}shadowsocks-libev 安装失败，退出脚本。${NC}"; exit 1; }

# 显示主菜单
main_menu
