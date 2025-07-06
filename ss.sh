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
# 默认主服务单元名称 (根据你的日志确认)
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
    echo -e "${YELLOW}正在检查 shadowsocks-libev 是否已安装...${NC}"
    if ! dpkg -s shadowsocks-libev >/dev/null 2>&1; then
        echo -e "${YELLOW}shadowsocks-libev 未安装，正在安装...${NC}"
        apt update && apt install -y shadowsocks-libev
        if [ $? -ne 0 ]; then
            echo -e "${RED}shadowsocks-libev 安装失败，请检查您的网络或APT源配置。${NC}"
            return 1
        fi
        echo -e "${GREEN}shadowsocks-libev 安装完成。${NC}"
    else
        echo -e "${GREEN}'shadowsocks-libev' 已安装。${NC}"
    fi
    return 0
}

# 修复或创建 shadowsocks-libev.service 以指向正确配置
ensure_main_service_config_path() {
    local service_file="/lib/systemd/system/${DEFAULT_SS_SERVICE_NAME}"
    local ss_exec_path="/usr/bin/ss-server"
    local config_file="${SS_CONFIG_DIR}/config.json"
    
    # 备份原始服务文件 (如果存在)
    if [ -f "$service_file" ]; then
        cp "$service_file" "${service_file}.bak"
        echo -e "${YELLOW}已备份原始服务文件到 ${service_file}.bak${NC}"
    else
        # 如果文件不存在，创建一个基本的
        echo -e "${YELLOW}服务文件 ${service_file} 不存在，正在创建。${NC}"
        cat <<EOF > "$service_file"
[Unit]
Description=Shadowsocks-libev Default Server Service
Documentation=man:shadowsocks-libev(8)
After=network.target

[Service]
Type=simple
ExecStart=${ss_exec_path} -c ${config_file}
ExecReload=/bin/kill -HUP \$MAINPID
EnvironmentFile=-/etc/default/shadowsocks-libev
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=51200
User=nobody
Group=nogroup

[Install]
WantedBy=multi-user.target
EOF
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误：无法创建或修改服务文件 ${service_file}。请手动检查。${NC}"
            return 1
        fi
    fi

    # 确保 ExecStart 指向正确的配置文件
    # 查找 ExecStart 行，如果不是指向 config.json，则修改
    if ! grep -q "ExecStart=${ss_exec_path} -c ${config_file}" "$service_file"; then
        echo -e "${YELLOW}正在更新服务文件 ${service_file} 的 ExecStart 配置...${NC}"
        # 使用 sed 进行替换，-i 参数直接修改文件
        sed -i "s|^ExecStart=.*|ExecStart=${ss_exec_path} -c ${config_file}|" "$service_file"
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误：无法更新服务文件 ${service_file}。请手动检查。${NC}"
            return 1
        fi
    fi
    
    # 重新加载 Systemd 配置
    systemctl daemon-reload
    echo -e "${GREEN}Systemd 配置已重新加载。${NC}"
    return 0
}


# 生成 SS 链接函数 (将参数编码为 base64)
generate_ss_link() {
    local server_addr_display=$1 # 用于显示的地址，可能是 "0.0.0.0" 或 "::1, 0.0.0.0"
    local server_port=$2
    local method=$3
    local password=$4

    # 对于SS链接，通常只使用一个IP或通用地址。如果显示是多个，统一用 0.0.0.0
    local server_addr_for_link="0.0.0.0" 
    if [[ "$server_addr_display" == "0.0.0.0" ]]; then
        server_addr_for_link="0.0.0.0"
    elif [[ "$server_addr_display" == *","* ]]; then
        # 如果是多IP列表，取第一个IP作为链接地址，或者统一用 "0.0.0.0" 表示
        server_addr_for_link="0.0.0.0" 
    else
        server_addr_for_link="$server_addr_display"
    fi

    # 对密码和方法进行Base64编码
    local credentials_raw="${method}:${password}"
    local credentials_base64=$(echo -n "$credentials_raw" | base64 -w 0) # -w 0 防止换行

    # 构建 ss:// 链接
    echo "ss://${credentials_base64}@${server_addr_for_link}:${server_port}#Shadowsocks_Node"
}

# 配置 Shadowsocks 节点
configure_ss_node() {
    local config_file_path=$1 # 传入的配置文件路径，例如 /etc/shadowsocks-libev/config.json

    echo -e "\n--- ${BLUE}配置 Shadowsocks 节点${NC} ---"

    # 在尝试创建配置文件之前，先确保目录存在
    mkdir -p "$SS_CONFIG_DIR"
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：无法创建配置目录 '${SS_CONFIG_DIR}'。请检查权限。${NC}"
        return 1
    fi

    # 硬编码默认参数
    local DEFAULT_SS_SERVER_ADDR_IPV4="0.0.0.0"
    local DEFAULT_SS_SERVER_ADDR_IPV4_IPV6='["::1", "0.0.0.0"]' # JSON 数组字符串
    local DEFAULT_SS_SERVER_PORT="12306" # 默认端口
    local DEFAULT_SS_PASSWORD="your_strong_password"
    local DEFAULT_SS_METHOD="aes-256-gcm" # 默认加密方式
    local DEFAULT_SS_TIMEOUT="300"

    echo -e "${YELLOW}请根据提示输入 Shadowsocks 节点的配置参数：${NC}"
    echo -e "${YELLOW}(可以直接回车接受推荐的默认值)${NC}"

    local SS_SERVER_ADDR_CONFIG="" # 实际写入配置文件的地址
    local SS_SERVER_ADDR_DISPLAY="" # 用于显示在提示中的地址

    # 询问监听地址类型
    echo -e "\n${YELLOW}请选择 Shadowsocks 监听地址类型：${NC}"
    echo -e "  ${BLUE}1.${NC} 仅 IPv4 (默认监听地址: ${DEFAULT_SS_SERVER_ADDR_IPV4})${NC}"
    echo -e "  ${BLUE}2.${NC} IPv4 和 IPv6 (默认监听地址: ${DEFAULT_SS_SERVER_ADDR_IPV4_IPV6})${NC}"
    read -p "请输入选择 (1或2, 默认1): " ADDR_TYPE_CHOICE
    
    case "$ADDR_TYPE_CHOICE" in
        2)
            SS_SERVER_ADDR_CONFIG="$DEFAULT_SS_SERVER_ADDR_IPV4_IPV6"
            SS_SERVER_ADDR_DISPLAY="::1, 0.0.0.0" # 用于显示
            echo -e "${GREEN}选择监听 IPv4 和 IPv6 地址。${NC}"
            ;;
        *) # 默认或无效输入都视为选择 1
            SS_SERVER_ADDR_CONFIG="\"$DEFAULT_SS_SERVER_ADDR_IPV4\"" # 单个IP需要加引号
            SS_SERVER_ADDR_DISPLAY="$DEFAULT_SS_SERVER_ADDR_IPV4" # 用于显示
            echo -e "${GREEN}选择仅监听 IPv4 地址。${NC}"
            ;;
    esac

    # 询问代理端口
    read -p "请输入 Shadowsocks 代理端口 (默认: ${DEFAULT_SS_SERVER_PORT}): " SS_SERVER_PORT_INPUT
    if [ -z "$SS_SERVER_PORT_INPUT" ]; then
        SS_SERVER_PORT="$DEFAULT_SS_SERVER_PORT"
        echo -e "${GREEN}使用默认代理端口: ${SS_SERVER_PORT}${NC}"
    else
        SS_SERVER_PORT="$SS_SERVER_PORT_INPUT"
    fi
    while ! [[ "$SS_SERVER_PORT" =~ ^[0-9]+$ ]] || [ "$SS_SERVER_PORT" -lt 1 ] || [ "$SS_SERVER_PORT" -gt 65535 ]; do
        echo -e "${RED}端口号无效，请输入一个1到65535之间的数字。${NC}"
        read -p "请输入 Shadowsocks 代理端口 (默认: ${DEFAULT_SS_SERVER_PORT}): " SS_SERVER_PORT_INPUT
        if [ -z "$SS_SERVER_PORT_INPUT" ]; then
            SS_SERVER_PORT="$DEFAULT_SS_SERVER_PORT"
            echo -e "${GREEN}使用默认代理端口: ${SS_SERVER_PORT}${NC}"
        else
            SS_SERVER_PORT="$SS_SERVER_PORT_INPUT"
        fi
    done

    # 询问密码 (显示输入)
    read -p "请输入 Shadowsocks 连接密码 (默认: ${DEFAULT_SS_PASSWORD}): " SS_PASSWORD_INPUT
    if [ -z "$SS_PASSWORD_INPUT" ]; then
        SS_PASSWORD="$DEFAULT_SS_PASSWORD"
        echo -e "${GREEN}使用默认密码: ${SS_PASSWORD}${NC}"
    else
        SS_PASSWORD="$SS_PASSWORD_INPUT"
    fi

    # 询问加密方式 - 使用带序号的列表
    echo -e "\n${YELLOW}请选择 Shadowsocks 加密方式：${NC}"
    local CRYPTO_METHODS=(
        "aes-256-gcm"
        "aes-192-gcm"
        "aes-128-gcm"
        "chacha20-ietf-poly1305"
        "xchacha20-ietf-poly1305"
        "2022-blake3-aes-256-gcm" # Shadow-tls v3 推荐
        "none" # 通常不推荐，用于调试
    )
    local default_method_index=-1
    for i in "${!CRYPTO_METHODS[@]}"; do
        if [[ "${CRYPTO_METHODS[$i]}" == "$DEFAULT_SS_METHOD" ]]; then
            default_method_index=$i
        fi
        echo -e "  ${BLUE}$((i+1)).${NC} ${CRYPTO_METHODS[$i]}" $( [[ "${CRYPTO_METHODS[$i]}" == "aes-256-gcm" || "${CRYPTO_METHODS[$i]}" == "chacha20-ietf-poly1305" ]] && echo "(推荐)" || echo "" ) ${NC}
    done

    local SS_METHOD_CHOICE
    read -p "请输入选择 (1-${#CRYPTO_METHODS[@]}, 默认 $((default_method_index+1))): " SS_METHOD_CHOICE_INPUT
    if [ -z "$SS_METHOD_CHOICE_INPUT" ]; then
        SS_METHOD="${CRYPTO_METHODS[$default_method_index]}"
        echo -e "${GREEN}使用默认加密方式: ${SS_METHOD}${NC}"
    else
        if [[ "$SS_METHOD_CHOICE_INPUT" =~ ^[0-9]+$ ]] && [ "$SS_METHOD_CHOICE_INPUT" -ge 1 ] && [ "$SS_METHOD_CHOICE_INPUT" -le ${#CRYPTO_METHODS[@]} ]; then
            SS_METHOD="${CRYPTO_METHODS[$((SS_METHOD_CHOICE_INPUT-1))]}"
            echo -e "${GREEN}已选择加密方式: ${SS_METHOD}${NC}"
        else
            echo -e "${RED}无效的选择，将使用默认加密方式: ${DEFAULT_SS_METHOD}${NC}"
            SS_METHOD="$DEFAULT_SS_METHOD"
        fi
    fi

    # 询问超时时间
    read -p "请输入 Shadowsocks 超时时间 (秒, 默认: ${DEFAULT_SS_TIMEOUT}): " SS_TIMEOUT_INPUT
    if [ -z "$SS_TIMEOUT_INPUT" ]; then
        SS_TIMEOUT="$DEFAULT_SS_TIMEOUT"
        echo -e "${GREEN}使用默认超时时间: ${SS_TIMEOUT}${NC}"
    else
        SS_TIMEOUT="$SS_TIMEOUT_INPUT"
    fi
    while ! [[ "$SS_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$SS_TIMEOUT" -lt 1 ]; do
        echo -e "${RED}超时时间无效，请输入一个大于0的整数。${NC}"
        read -p "请输入 Shadowsocks 超时时间 (秒, 默认: ${DEFAULT_SS_TIMEOUT}): " SS_TIMEOUT_INPUT
        if [ -z "$SS_TIMEOUT_INPUT" ]; then
            SS_TIMEOUT="$DEFAULT_SS_TIMEOUT"
            echo -e "${GREEN}使用默认超时时间: ${SS_TIMEOUT}${NC}"
        else
            SS_TIMEOUT="$SS_TIMEOUT_INPUT"
        fi
    done

    echo -e "\n${YELLOW}正在生成 Shadowsocks-libev 配置文件: ${config_file_path}...${NC}"

    # 创建配置文件内容 - server 字段直接使用 SS_SERVER_ADDR_CONFIG
    cat <<EOF > "$config_file_path"
{
    "server":$SS_SERVER_ADDR_CONFIG,
    "server_port":$SS_SERVER_PORT,
    "password":"$SS_PASSWORD",
    "method":"$SS_METHOD",
    "timeout":$SS_TIMEOUT,
    "fast_open":true
}
EOF

    if [ $? -ne 0 ]; then
      echo -e "${RED}配置文件生成失败，请检查权限或路径。${NC}"
      return 1
    fi

    echo -e "${GREEN}配置文件已生成。${NC}"
    
    # 根据配置文件路径确定服务实例名称
    local service_instance=""
    if [ "$config_file_path" = "${SS_CONFIG_DIR}/config.json" ]; then
        service_instance="${DEFAULT_SS_SERVICE_NAME}" # 使用默认服务名称
    else
        # 对于多节点，使用实例模式
        local port_from_file=$(jq -r '.server_port' "$config_file_path" 2>/dev/null)
        service_instance="${DEFAULT_SS_SERVICE_NAME%.service}@${port_from_file}.service" # 例如 shadowsocks-libev@8389.service
    fi
    
    echo -e "\n${YELLOW}正在设置 Shadowsocks-libev 服务 (${service_instance}) 开机启动并重启...${NC}"

    # 启动/启用服务
    systemctl enable "${service_instance}" > /dev/null 2>&1
    systemctl restart "${service_instance}"

    if [ $? -eq 0 ]; then
      echo -e "${GREEN}Shadowsocks-libev 服务 (${service_instance}) 已成功重启并设置开机启动！${NC}"
      echo -e "${BLUE}配置详情：${NC}"
      echo -e "  ${BLUE}监听地址: ${GREEN}$SS_SERVER_ADDR_DISPLAY${NC}" # 显示时使用易读的格式
      echo -e "  ${BLUE}代理端口: ${GREEN}$SS_SERVER_PORT${NC}"
      echo -e "  ${BLUE}加密方式: ${GREEN}$SS_METHOD${NC}"
      echo -e "  ${BLUE}超时时间: ${GREEN}$SS_TIMEOUT${NC} 秒"
      
      # 生成并显示 SS 链接
      echo -e "\n${GREEN}请复制以下 SS 链接到您的代理软件：${NC}"
      NODE_LINK=$(generate_ss_link "$SS_SERVER_ADDR_DISPLAY" "$SS_SERVER_PORT" "$SS_METHOD" "$SS_PASSWORD")
      echo -e "${YELLOW}${NODE_LINK}${NC}"
      echo -e "${BLUE}(提示：如果监听地址是0.0.0.0或包含多个地址，请替换为您的服务器公网IP)${NC}"

    else
      echo -e "${RED}Shadowsocks-libev 服务 (${service_instance}) 重启失败，请检查日志 (journalctl -u ${service_instance}) 获取更多信息。${NC}"
    fi

    echo -e "\n--- ${GREEN}配置完成${NC} ---"
    echo -e "您可以运行 'systemctl status ${service_instance}' 来检查服务状态。"
}

# 卸载 Shadowsocks-libev
uninstall_ss() {
    echo -e "\n--- ${RED}卸载 Shadowsocks-libev${NC} ---"
    read -p "您确定要卸载 Shadowsocks-libev 及所有节点吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        echo -e "${YELLOW}正在停止并禁用所有 Shadowsocks-libev 服务实例...${NC}"
        
        # 停止并禁用所有 shadowsocks-libev@*.service 实例
        systemctl list-units --type=service --all | grep "shadowsocks-libev@" | awk '{print $1}' | while read -r service_name; do
            echo -e "${YELLOW}停止并禁用: ${service_name}${NC}"
            systemctl stop "$service_name" > /dev/null 2>&1
            systemctl disable "$service_name" > /dev/null 2>&1
        done
        
        # 停止并禁用默认的 shadowsocks-libev.service (你的系统上正在运行的)
        if systemctl list-units --type=service --all | grep -q "${DEFAULT_SS_SERVICE_NAME}"; then
            echo -e "${YELLOW}停止并禁用: ${DEFAULT_SS_SERVICE_NAME}${NC}"
            systemctl stop "${DEFAULT_SS_SERVICE_NAME}" > /dev/null 2>&1
            systemctl disable "${DEFAULT_SS_SERVICE_NAME}" > /dev/null 2>&1
        fi

        echo -e "${YELLOW}正在卸载 shadowsocks-libev 软件包...${NC}"
        apt purge -y shadowsocks-libev > /dev/null 2>&1
        echo -e "${YELLOW}正在删除所有配置文件...${NC}"
        rm -rf "$SS_CONFIG_DIR" # 删除整个配置目录

        # 重新加载 Systemd 配置以清除已卸载的服务
        systemctl daemon-reload
        systemctl reset-failed # 重置所有失败的服务单元状态
        
        echo -e "${GREEN}Shadowsocks-libev、所有节点已成功卸载。${NC}"
        # 卸载完成后直接退出
        exit 0
    else
        echo -e "${BLUE}卸载操作已取消。${NC}"
    fi
}

# 查看运行状态
check_status() {
    echo -e "\n--- ${BLUE}Shadowsocks-libev 运行状态${NC} ---"
    local found_services=false
    
    # 优先显示默认服务
    if systemctl list-units --type=service --all | grep -q "${DEFAULT_SS_SERVICE_NAME}"; then
        echo -e "\n${BLUE}服务: ${DEFAULT_SS_SERVICE_NAME}${NC}"
        systemctl status "${DEFAULT_SS_SERVICE_NAME}" --no-pager
        found_services=true
    fi

    # 再显示所有 shadowsocks-libev@*.service 实例
    systemctl list-units --type=service --all | grep "shadowsocks-libev@" | awk '{print $1}' | while read -r service_name; do
        if [ "$service_name" != "${DEFAULT_SS_SERVICE_NAME}" ]; then # 避免重复显示
            echo -e "\n${BLUE}服务: ${service_name}${NC}"
            systemctl status "$service_name" --no-pager
            found_services=true
        fi
    done

    if [ "$found_services" = false ]; then
        echo -e "${YELLOW}未检测到 Shadowsocks-libev 服务实例。${NC}"
    fi
}

# 停止服务
stop_service() {
    echo -e "\n--- ${BLUE}停止 Shadowsocks-libev 服务${NC} ---"
    local has_services=false
    local i=1
    local services_to_manage=()

    # 将默认服务添加到列表
    if systemctl list-units --type=service --all | grep -q "${DEFAULT_SS_SERVICE_NAME}"; then
        services_to_manage+=("${DEFAULT_SS_SERVICE_NAME}")
        echo -e "  ${BLUE}${i}.${NC} ${DEFAULT_SS_SERVICE_NAME}"
        i=$((i+1))
        has_services=true
    fi

    # 将所有 shadowsocks-libev@*.service 实例添加到列表
    systemctl list-units --type=service --all | grep "shadowsocks-libev@" | awk '{print $1}' | while read -r service_name; do
        if [ "$service_name" != "${DEFAULT_SS_SERVICE_NAME}" ]; then # 避免重复
            services_to_manage+=("$service_name")
            echo -e "  ${BLUE}${i}.${NC} ${service_name}"
            i=$((i+1))
            has_services=true
        fi
    done

    if [ "$has_services" = false ]; then
        echo -e "${YELLOW}未检测到可停止的 Shadowsocks-libev 服务实例。${NC}"
        return
    fi

    echo -e "  ${BLUE}0.${NC} 返回主菜单"

    read -p "请输入选择 (0-$((i-1))): " choice
    if [ "$choice" -eq 0 ]; then
        echo -e "${BLUE}操作已取消。${NC}"
        return
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $((i-1)) ]; then
        local selected_service=${services_to_manage[$((choice-1))]}
        systemctl stop "$selected_service"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}服务 '${selected_service}' 已停止。${NC}"
        else
            echo -e "${RED}停止服务 '${selected_service}' 失败，请检查。${NC}"
        fi
    else
        echo -e "${RED}无效的选择。${NC}"
    fi
}

# 重启服务
restart_service() {
    echo -e "\n--- ${BLUE}重启 Shadowsocks-libev 服务${NC} ---"
    local has_services=false
    local i=1
    local services_to_manage=()

    # 将默认服务添加到列表
    if systemctl list-units --type=service --all | grep -q "${DEFAULT_SS_SERVICE_NAME}"; then
        services_to_manage+=("${DEFAULT_SS_SERVICE_NAME}")
        echo -e "  ${BLUE}${i}.${NC} ${DEFAULT_SS_SERVICE_NAME}"
        i=$((i+1))
        has_services=true
    fi

    # 将所有 shadowsocks-libev@*.service 实例添加到列表
    systemctl list-units --type=service --all | grep "shadowsocks-libev@" | awk '{print $1}' | while read -r service_name; do
        if [ "$service_name" != "${DEFAULT_SS_SERVICE_NAME}" ]; then # 避免重复
            services_to_manage+=("$service_name")
            echo -e "  ${BLUE}${i}.${NC} ${service_name}"
            i=$((i+1))
        has_services=true
        fi
    done

    if [ "$has_services" = false ]; then
        echo -e "${YELLOW}未检测到可重启的 Shadowsocks-libev 服务实例。${NC}"
        return
    fi

    echo -e "  ${BLUE}0.${NC} 返回主菜单"

    read -p "请输入选择 (0-$((i-1))): " choice
    if [ "$choice" -eq 0 ]; then
        echo -e "${BLUE}操作已取消。${NC}"
        return
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $((i-1)) ]; then
        local selected_service=${services_to_manage[$((choice-1))]}
        systemctl restart "$selected_service"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}服务 '${selected_service}' 已重启。${NC}"
        else
            echo -e "${RED}重启服务 '${selected_service}' 失败，请检查。${NC}"
        fi
    else
        echo -e "${RED}无效的选择。${NC}"
    fi
}

# 查看当前配置
view_current_config() {
    echo -e "\n--- ${BLUE}当前 Shadowsocks-libev 配置${NC} ---"
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}'jq' 命令未安装，无法解析配置文件。请先安装 jq。${NC}"
        return
    fi

    local config_files=$(find "$SS_CONFIG_DIR" -maxdepth 1 -name "*.json" -print 2>/dev/null)
    if [ -z "$config_files" ]; then
        echo -e "${RED}未检测到 Shadowsocks-libev 配置文件。请先运行 '安装/重新配置默认节点' 进行配置。${NC}"
        return
    fi

    for cfg in $config_files; do
        echo -e "\n${YELLOW}--- 配置文件: ${BLUE}$cfg${NC} ---"
        if [ -f "$cfg" ]; then
            local server_addr_raw=$(jq '.server' "$cfg" 2>/dev/null) # 获取原始JSON格式的server字段
            local server_addr_display=""
            # 判断是字符串还是数组
            if echo "$server_addr_raw" | grep -q '\[.*\]'; then # 如果是数组
                server_addr_display=$(echo "$server_addr_raw" | jq -r 'join(", ")' 2>/dev/null)
            else # 如果是字符串
                server_addr_display=$(echo "$server_addr_raw" | jq -r '.' 2>/dev/null)
            fi

            local server_port=$(jq -r '.server_port' "$cfg" 2>/dev/null)
            local password=$(jq -r '.password' "$cfg" 2>/dev/null)
            local method=$(jq -r '.method' "$cfg" 2>/dev/null)
            local timeout=$(jq -r '.timeout' "$cfg" 2>/dev/null)

            echo -e "  ${BLUE}监听地址: ${GREEN}$server_addr_display${NC}"
            echo -e "  ${BLUE}代理端口: ${GREEN}$server_port${NC}"
            echo -e "  ${BLUE}加密方式: ${GREEN}$method${NC}"
            echo -e "  ${BLUE}超时时间: ${GREEN}$timeout${NC} 秒"
            echo -e "  ${BLUE}连接密码: ${GREEN}(已设置，此处不显示)${NC}"

            echo -e "\n${GREEN}对应的 SS 链接 (可复制)：${NC}"
            NODE_LINK=$(generate_ss_link "$server_addr_display" "$server_port" "$method" "$password")
            echo -e "${YELLOW}${NODE_LINK}${NC}"
            echo -e "${BLUE}(提示：如果监听地址是0.0.0.0或包含多个地址，请替换为您的服务器公网IP)${NC}"

        else
            echo -e "${RED}文件不存在或无法读取。${NC}"
        fi
    done
    echo -e "------------------------------------"
}

# 新增 SS 节点
add_new_ss_node() {
    echo -e "\n--- ${BLUE}新增 Shadowsocks 节点${NC} ---"
    install_jq # 确保 jq 已安装
    if [ $? -ne 0 ]; then return; fi

    read -p "请输入新节点的端口号 (例如 8389): " NEW_PORT
    while ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; do
        echo -e "${RED}端口号无效，请输入一个1到65535之间的数字。${NC}"
        read -p "请重新输入新节点的端口号: " NEW_PORT
    done

    # 检查端口是否已被现有节点使用
    local existing_ports=()
    local config_files=$(find "$SS_CONFIG_DIR" -maxdepth 1 -name "*.json" -print 2>/dev/null)
    for cfg in $config_files; do
        local existing_port=$(jq -r '.server_port' "$cfg" 2>/dev/null)
        existing_ports+=("$existing_port")
    done

    for p in "${existing_ports[@]}"; do
        if [ "$p" = "$NEW_PORT" ]; then
            echo -e "${RED}错误：端口 ${NEW_PORT} 已被现有 Shadowsocks 节点使用。请选择其他端口。${NC}"
            return 1
        fi
    done

    local new_config_file="${SS_CONFIG_DIR}/config-${NEW_PORT}.json"
    configure_ss_node "$new_config_file"
}


# --- 主菜单 ---

main_menu() {
    clear
    echo -e "--- ${GREEN}Shadowsocks-libev 管理脚本${NC} ---"
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
            # 默认主实例配置文件路径。configure_ss_node 会使用其内部的 DEFAULT_SS_SERVER_PORT
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
            echo -e "${GREEN}退出脚本。再见！${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选择，请重新输入。${NC}"
            ;;
    esac
    echo -e "\n${BLUE}按任意键返回主菜单...${NC}"
    read -n 1 -s
    main_menu
}

# --- 脚本启动逻辑 ---

# 确保安装 jq 和 shadowsocks-libev
install_jq || exit 1 # 如果jq安装失败，则退出脚本
install_ss_libev || exit 1 # 如果shadowsocks-libev安装失败，则退出脚本

# 确保主服务文件指向正确的配置文件
ensure_main_service_config_path || exit 1

# 直接进入主菜单
main_menu
