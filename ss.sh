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

# 脚本的最终目标路径和快捷方式名称
SCRIPT_TARGET_PATH="/usr/local/bin/ss.sh"
SS_COMMAND_LINK="/usr/local/bin/ss"
CONFIG_FILE="/etc/shadowsocks-libev/config.json"

# --- 函数定义 ---

# 检查并安装 jq (用于读取JSON配置)
install_jq() {
    echo -e "${YELLOW}正在检查 'jq' 命令是否安装 (用于读取现有配置)...${NC}"
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}'jq' 命令未找到，正在安装 'jq'....${NC}"
        apt update > /dev/null 2>&1
        apt install -y jq > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo -e "${RED}'jq' 安装失败。某些功能可能无法显示当前配置。请手动安装：sudo apt install jq${NC}"
            return 1
        fi
        echo -e "${GREEN}'jq' 安装完成。${NC}"
    else
        echo -e "${GREEN}'jq' 已安装。${NC}"
    fi
    return 0
}

# 获取当前配置参数
get_current_config() {
    # 这些是硬编码的默认值，当配置文件不存在或jq无法读取时使用
    SS_SERVER_ADDR_DEFAULT_DISPLAY="0.0.0.0" # 用于显示在提示中
    SS_SERVER_ADDR_DEFAULT_RAW="\"0.0.0.0\""  # 用于实际写入配置文件

    SS_SERVER_PORT_DEFAULT="8388"
    SS_PASSWORD_DEFAULT=""
    SS_METHOD_DEFAULT="chacha20-ietf-poly1305"
    SS_TIMEOUT_DEFAULT="300"

    # 尝试从现有配置文件中读取值
    if [ -f "$CONFIG_FILE" ] && command -v jq &> /dev/null; then
        SERVER_VALUE=$(jq -r '.server' "$CONFIG_FILE")
        SERVER_TYPE=$(jq -r '.server | type' "$CONFIG_FILE")

        if [ "$SERVER_TYPE" == "array" ]; then
            # 如果是数组，格式化为逗号分隔字符串用于显示
            SS_SERVER_ADDR_DEFAULT_DISPLAY=$(echo "$SERVER_VALUE" | jq -r 'join(", ")')
            # 原始 JSON 数组字符串用于写入配置文件
            SS_SERVER_ADDR_DEFAULT_RAW="$SERVER_VALUE"
        else
            # 如果是字符串，直接使用
            SS_SERVER_ADDR_DEFAULT_DISPLAY="$SERVER_VALUE"
            # 确保是带引号的 JSON 字符串用于写入配置文件
            SS_SERVER_ADDR_DEFAULT_RAW="\"$SERVER_VALUE\""
        fi
        
        SS_SERVER_PORT_DEFAULT=$(jq -r '.server_port // 8388' "$CONFIG_FILE")
        SS_PASSWORD_DEFAULT=$(jq -r '.password // ""' "$CONFIG_FILE")
        SS_METHOD_DEFAULT=$(jq -r '.method // "chacha20-ietf-poly1305"' "$CONFIG_FILE")
        SS_TIMEOUT_DEFAULT=$(jq -r '.timeout // 300' "$CONFIG_FILE")
    fi
}

# 安装或修改 Shadowsocks-libev
install_or_modify_ss() {
    echo -e "\n--- ${BLUE}安装/修改 Shadowsocks-libev 配置${NC} ---"

    # 检查并安装 shadowsocks-libev
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
        echo -e "${GREEN}shadowsocks-libev 已安装。${NC}"
    fi

    # 获取当前配置作为默认值
    get_current_config

    echo -e "\n${YELLOW}请根据提示输入 Shadowsocks-libev 的配置参数：${NC}"
    echo -e "${YELLOW}(如果您想保持当前值，可以直接回车使用默认或现有值)${NC}"

    # 询问监听地址
    read -p "请输入 Shadowsocks 监听地址 (当前: ${BLUE}$SS_SERVER_ADDR_DEFAULT_DISPLAY${NC}): " SS_SERVER_ADDR_INPUT
    if [ -z "$SS_SERVER_ADDR_INPUT" ]; then
        # 如果用户回车，使用原始的 JSON 格式
        SS_SERVER_ADDR="$SS_SERVER_ADDR_DEFAULT_RAW"
        echo -e "${GREEN}使用默认监听地址: ${SS_SERVER_ADDR_DEFAULT_DISPLAY}${NC}"
    else
        # 如果用户输入了新值，将其作为字符串处理
        SS_SERVER_ADDR="\"$SS_SERVER_ADDR_INPUT\""
    fi

    # 询问代理端口
    read -p "请输入 Shadowsocks 代理端口 (当前: ${BLUE}$SS_SERVER_PORT_DEFAULT${NC}): " SS_SERVER_PORT_INPUT
    if [ -z "$SS_SERVER_PORT_INPUT" ]; then
        SS_SERVER_PORT="$SS_SERVER_PORT_DEFAULT"
        echo -e "${GREEN}使用默认代理端口: ${SS_SERVER_PORT}${NC}"
    else
        SS_SERVER_PORT="$SS_SERVER_PORT_INPUT"
    fi
    while ! [[ "$SS_SERVER_PORT" =~ ^[0-9]+$ ]] || [ "$SS_SERVER_PORT" -lt 1 ] || [ "$SS_SERVER_PORT" -gt 65535 ]; do
        echo -e "${RED}端口号无效，请输入一个1到65535之间的数字。${NC}"
        read -p "请输入 Shadowsocks 代理端口 (当前: ${BLUE}$SS_SERVER_PORT_DEFAULT${NC}): " SS_SERVER_PORT_INPUT
        if [ -z "$SS_SERVER_PORT_INPUT" ]; then
            SS_SERVER_PORT="$SS_SERVER_PORT_DEFAULT"
            echo -e "${GREEN}使用默认代理端口: ${SS_SERVER_PORT}${NC}"
        else
            SS_SERVER_PORT="$SS_SERVER_PORT_INPUT"
        fi
    done

    # 询问密码 (显示输入)
    read -p "请输入 Shadowsocks 连接密码 (留空将使用现有密码，当前密码${YELLOW}不显示${NC}): " SS_PASSWORD_INPUT
    if [ -z "$SS_PASSWORD_INPUT" ]; then
        SS_PASSWORD="$SS_PASSWORD_DEFAULT"
        if [ -z "$SS_PASSWORD" ]; then
            echo -e "${RED}警告：未输入新密码，且现有配置文件中未找到密码。请务必设置一个密码。${NC}"
            while [ -z "$SS_PASSWORD" ]; do
                read -p "请重新输入 Shadowsocks 连接密码 (不能为空): " SS_PASSWORD
            done
        else
            echo -e "${GREEN}未输入新密码，将使用现有密码。${NC}"
        fi
    else
        SS_PASSWORD="$SS_PASSWORD_INPUT"
    fi

    # 询问加密方式
    echo "可用的加密方式："
    echo -e "  ${GREEN}aes-256-gcm (推荐)${NC}"
    echo "  aes-192-gcm"
    echo "  aes-128-gcm"
    echo -e "  ${GREEN}chacha20-ietf-poly1305 (推荐)${NC}"
    echo "  xchacha20-ietf-poly1305"
    read -p "请输入 Shadowsocks 加密方式 (当前: ${BLUE}$SS_METHOD_DEFAULT${NC}): " SS_METHOD_INPUT
    if [ -z "$SS_METHOD_INPUT" ]; then
        SS_METHOD="$SS_METHOD_DEFAULT"
        echo -e "${GREEN}使用默认加密方式: ${SS_METHOD}${NC}"
    else
        SS_METHOD="$SS_METHOD_INPUT"
    fi

    # 询问超时时间
    read -p "请输入 Shadowsocks 超时时间 (秒, 当前: ${BLUE}$SS_TIMEOUT_DEFAULT${NC}): " SS_TIMEOUT_INPUT
    if [ -z "$SS_TIMEOUT_INPUT" ]; then
        SS_TIMEOUT="$SS_TIMEOUT_DEFAULT"
        echo -e "${GREEN}使用默认超时时间: ${SS_TIMEOUT}${NC}"
    else
        SS_TIMEOUT="$SS_TIMEOUT_INPUT"
    fi
    while ! [[ "$SS_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$SS_TIMEOUT" -lt 1 ]; do
        echo -e "${RED}超时时间无效，请输入一个大于0的整数。${NC}"
        read -p "请输入 Shadowsocks 超时时间 (秒, 当前: ${BLUE}$SS_TIMEOUT_DEFAULT${NC}): " SS_TIMEOUT_INPUT
        if [ -z "$SS_TIMEOUT_INPUT" ]; then
            SS_TIMEOUT="$SS_TIMEOUT_DEFAULT"
            echo -e "${GREEN}使用默认超时时间: ${SS_TIMEOUT}${NC}"
        else
            SS_TIMEOUT="$SS_TIMEOUT_INPUT"
        fi
    done

    echo -e "\n${YELLOW}正在生成 Shadowsocks-libev 配置文件...${NC}"

    # 创建配置文件内容 - server 字段直接使用 SS_SERVER_ADDR，它现在已经是引号或数组格式
    cat <<EOF > "$CONFIG_FILE"
{
    "server":$SS_SERVER_ADDR,
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

    echo -e "${GREEN}配置文件已生成到: ${BLUE}$CONFIG_FILE${NC}"
    echo -e "\n${YELLOW}正在设置 Shadowsocks-libev 开机启动并重启服务...${NC}"

    # 设置开机启动 (幂等操作，重复执行无害)
    systemctl enable shadowsocks-libev > /dev/null 2>&1

    # 重启服务以应用新配置
    systemctl restart shadowsocks-libev

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Shadowsocks-libev 服务已成功重启并设置开机启动！${NC}"
        echo -e "${BLUE}配置详情：${NC}"
        echo -e "  ${BLUE}监听地址: ${GREEN}$SS_SERVER_ADDR_DEFAULT_DISPLAY${NC}" # 显示时使用易读的格式
        echo -e "  ${BLUE}代理端口: ${GREEN}$SS_SERVER_PORT${NC}"
        echo -e "  ${BLUE}加密方式: ${GREEN}$SS_METHOD${NC}"
        echo -e "  ${BLUE}超时时间: ${GREEN}$SS_TIMEOUT${NC} 秒"
    else
        echo -e "${RED}Shadowsocks-libev 服务重启失败，请检查日志 (journalctl -u shadowsocks-libev.service) 获取更多信息。${NC}"
    fi

    echo -e "\n--- ${GREEN}配置完成${NC} ---"
    echo -e "您可以运行 'systemctl status shadowsocks-libev' 来检查服务状态。"
}

# 卸载 Shadowsocks-libev
uninstall_ss() {
    echo -e "\n--- ${RED}卸载 Shadowsocks-libev${NC} ---"
    read -p "您确定要卸载 Shadowsocks-libev 吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        echo -e "${YELLOW}正在停止并禁用 Shadowsocks-libev 服务...${NC}"
        systemctl stop shadowsocks-libev > /dev/null 2>&1
        systemctl disable shadowsocks-libev > /dev/null 2>&1
        echo -e "${YELLOW}正在卸载 shadowsocks-libev 软件包...${NC}"
        apt purge -y shadowsocks-libev > /dev/null 2>&1
        echo -e "${YELLOW}正在删除配置文件...${NC}"
        rm -f "$CONFIG_FILE"
        echo -e "${GREEN}Shadowsocks-libev 已成功卸载。${NC}"
    else
        echo -e "${BLUE}卸载操作已取消。${NC}"
    fi
}

# 查看运行状态
check_status() {
    echo -e "\n--- ${BLUE}Shadowsocks-libev 运行状态${NC} ---"
    systemctl status shadowsocks-libev
}

# 停止服务
stop_service() {
    echo -e "\n--- ${BLUE}停止 Shadowsocks-libev 服务${NC} ---"
    systemctl stop shadowsocks-libev
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Shadowsocks-libev 服务已停止。${NC}"
    else
        echo -e "${RED}停止服务失败，请检查。${NC}"
    fi
}

# 重启服务
restart_service() {
    echo -e "\n--- ${BLUE}重启 Shadowsocks-libev 服务${NC} ---"
    systemctl restart shadowsocks-libev
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Shadowsocks-libev 服务已重启。${NC}"
    else
        echo -e "${RED}重启服务失败，请检查。${NC}"
    fi
}

# 查看当前配置
view_current_config() {
    echo -e "\n--- ${BLUE}当前 Shadowsocks-libev 配置${NC} ---"
    if [ -f "$CONFIG_FILE" ] && command -v jq &> /dev/null; then
        echo -e "${YELLOW}配置文件路径: ${BLUE}$CONFIG_FILE${NC}"
        echo -e "${YELLOW}内容：${NC}"
        jq . "$CONFIG_FILE" | while IFS= read -r line; do
            echo -e "  ${GREEN}$line${NC}" # 输出JSON内容并着色
        done
        echo -e "\n${BLUE}注意：出于安全考虑，密码在此处不直接显示明文。${NC}"
    else
        echo -e "${RED}配置文件 '$CONFIG_FILE' 不存在或 'jq' 未安装，无法显示当前配置。${NC}"
        echo -e "${YELLOW}请先运行 '安装/修改 Shadowsocks-libev' 选项来配置。${NC}"
    fi
}

# 自动设置 'ss' 快捷方式
setup_ss_shortcut() {
    echo -e "\n--- ${BLUE}正在设置 'ss' 快捷方式...${NC} ---"

    # 获取当前脚本的绝对路径
    CURRENT_SCRIPT_PATH=$(readlink -f "$0")

    # 如果脚本不在目标位置，则移动它
    if [ "$CURRENT_SCRIPT_PATH" != "$SCRIPT_TARGET_PATH" ]; then
        echo -e "${YELLOW}脚本将从 '${CURRENT_SCRIPT_PATH}' 移动到 '${SCRIPT_TARGET_PATH}'...${NC}"
        mv "$CURRENT_SCRIPT_PATH" "$SCRIPT_TARGET_PATH"
        if [ $? -ne 0 ]; then
            echo -e "${RED}脚本移动失败！请手动将脚本移动到 '${SCRIPT_TARGET_PATH}' 并检查权限。${NC}"
            return 1
        fi
        # 更新当前脚本路径变量
        CURRENT_SCRIPT_PATH="$SCRIPT_TARGET_PATH"
    else
        echo -e "${GREEN}脚本已位于 '${SCRIPT_TARGET_PATH}'，无需移动。${NC}"
    fi

    # 确保脚本有执行权限
    echo -e "${YELLOW}正在确保脚本 '${SCRIPT_TARGET_PATH}' 具有执行权限...${NC}"
    chmod +x "$SCRIPT_TARGET_PATH"
    if [ $? -ne 0 ]; then
        echo -e "${RED}设置脚本执行权限失败！请手动设置：chmod +x '${SCRIPT_TARGET_PATH}'。${NC}"
        return 1
    fi

    # 创建软链接
    echo -e "${YELLOW}正在创建 'ss' 快捷方式 (软链接) 到 '${SS_COMMAND_LINK}'...${NC}"
    ln -sf "$SCRIPT_TARGET_PATH" "$SS_COMMAND_LINK"
    if [ $? -ne 0 ]; then
        echo -e "${RED}创建软链接失败！请手动创建：ln -sf '${SCRIPT_TARGET_PATH}' '${SS_COMMAND_LINK}'。${NC}"
        return 1
    fi

    echo -e "${GREEN}'ss' 快捷方式已成功设置！${NC}"
    echo -e "现在，您可以在任何地方直接输入 '${YELLOW}sudo ss${NC}' 来运行此脚本了。"
    echo -e "如果 '${YELLOW}ss${NC}' 命令立即不生效，请尝试重新登录终端或运行 '${BLUE}source ~/.bashrc${NC}'。"
    echo -e "------------------------------"
}

# --- 主菜单 ---

main_menu() {
    clear
    echo -e "--- ${GREEN}Shadowsocks-libev 管理脚本${NC} ---"
    echo -e "${BLUE}1.${NC} ${YELLOW}安装/修改 Shadowsocks-libev 配置${NC}"
    echo -e "${BLUE}2.${NC} ${RED}卸载 Shadowsocks-libev${NC}"
    echo -e "${BLUE}3.${NC} ${GREEN}查看 Shadowsocks-libev 运行状态${NC}"
    echo -e "${BLUE}4.${NC} ${YELLOW}停止 Shadowsocks-libev 服务${NC}"
    echo -e "${BLUE}5.${NC} ${YELLOW}重启 Shadowsocks-libev 服务${NC}"
    echo -e "${BLUE}6.${NC} ${GREEN}查看当前 Shadowsocks-libev 配置${NC}"
    echo -e "${BLUE}0.${NC} ${YELLOW}退出${NC}"
    echo -e "------------------------------------"
    read -p "请选择一个操作 (0-6): " choice
    echo ""

    case "$choice" in
        1)
            install_or_modify_ss
            ;;
        2)
            uninstall_ss
            ;;
        3)
            check_status
            ;;
        4)
            stop_service
            ;;
        5)
            restart_service
            ;;
        6)
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

# 确保安装jq
install_jq

# 在第一次运行时，尝试设置快捷方式
# 注意：如果脚本当前在非目标路径（如 /root），第一次运行它会将其移动并设置快捷方式
# 之后再次运行将直接使用快捷方式，并直接进入菜单
if [ "$0" == "$SCRIPT_TARGET_PATH" ] || [ "$(readlink -f "$0")" == "$SCRIPT_TARGET_PATH" ]; then
    # 如果脚本已经位于目标路径，或者通过软链接运行，则直接进入菜单
    main_menu
else
    # 否则，在第一次运行时设置快捷方式，然后进入菜单
    echo -e "${YELLOW}检测到脚本首次运行或位置不符，将自动设置快捷方式...${NC}"
    setup_ss_shortcut
    echo -e "\n${BLUE}快捷方式设置完成，现在请使用 'sudo ss' 命令重新运行脚本进入主菜单。${NC}"
    echo -e "${BLUE}当前脚本即将退出...${NC}"
    exit 0 # 第一次运行时，设置完快捷方式后退出，让用户用新的命令运行
fi
