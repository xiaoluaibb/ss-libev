#!/bin/bash

# 检查是否以root用户运行
if [ "$EUID" -ne 0 ]; then
  echo "请以root用户运行此脚本 (sudo ./configure_ss.sh)"
  exit 1
fi

echo "--- Shadowsocks-libev 自动配置脚本 ---"
echo "--- 您可以随时运行此脚本来修改 Shadowsocks-libev 的配置 ---"

# 脚本的最终目标路径和快捷方式名称
SCRIPT_TARGET_PATH="/usr/local/bin/configure_ss.sh"
SS_COMMAND_LINK="/usr/local/bin/ss"

# 检查并安装 shadowsocks-libev
echo "正在检查 shadowsocks-libev 是否已安装..."
if ! dpkg -s shadowsocks-libev >/dev/null 2>&1; then
  echo "shadowsocks-libev 未安装，正在安装..."
  apt update && apt install -y shadowsocks-libev
  if [ $? -ne 0 ]; then
    echo "shadowsocks-libev 安装失败，请检查您的网络或APT源配置。"
    exit 1
  fi
  echo "shadowsocks-libev 安装完成。"
else
  echo "shadowsocks-libev 已安装。"
fi

# 检查并安装 jq (用于读取JSON配置)
echo "正在检查 'jq' 命令是否安装 (用于读取现有配置)..."
if ! command -v jq &> /dev/null; then
    echo "'jq' 命令未找到，正在安装 'jq'..."
    apt install -y jq
    if [ $? -ne 0 ]; then
        echo "'jq' 安装失败，将无法读取现有配置作为默认值。"
        # 如果jq安装失败，重置默认值，避免后面读取失败
        unset SS_SERVER_ADDR_DEFAULT
        unset SS_SERVER_PORT_DEFAULT
        unset SS_METHOD_DEFAULT
        unset SS_TIMEOUT_DEFAULT
    else
        echo "'jq' 安装完成。"
    fi
else
    echo "'jq' 已安装。"
fi

echo ""
echo "请根据提示输入 Shadowsocks-libev 的配置参数："
echo "(如果您想保持当前值，可以直接回车使用默认或现有值)"

# 配置文件的路径
CONFIG_FILE="/etc/shadowsocks-libev/config.json"

# 读取现有配置（如果存在）
SS_SERVER_ADDR_DEFAULT="0.0.0.0"
SS_SERVER_PORT_DEFAULT="8388"
SS_PASSWORD_DEFAULT="" # 密码不从文件读取，总是要求输入
SS_METHOD_DEFAULT="chacha20-ietf-poly1305"
SS_TIMEOUT_DEFAULT="300"

if [ -f "$CONFIG_FILE" ] && command -v jq &> /dev/null; then
    echo "检测到现有配置文件，将尝试读取其值作为默认选项。"
    SS_SERVER_ADDR_DEFAULT=$(jq -r '.server // "0.0.0.0"' "$CONFIG_FILE")
    SS_SERVER_PORT_DEFAULT=$(jq -r '.server_port // 8388' "$CONFIG_FILE")
    SS_METHOD_DEFAULT=$(jq -r '.method // "chacha20-ietf-poly1305"' "$CONFIG_FILE")
    SS_TIMEOUT_DEFAULT=$(jq -r '.timeout // 300' "$CONFIG_FILE")
fi

# 询问监听地址
read -p "请输入 Shadowsocks 监听地址 (默认: $SS_SERVER_ADDR_DEFAULT): " SS_SERVER_ADDR
if [ -z "$SS_SERVER_ADDR" ]; then
    SS_SERVER_ADDR="$SS_SERVER_ADDR_DEFAULT"
    echo "使用默认监听地址: $SS_SERVER_ADDR"
fi

# 询问代理端口
read -p "请输入 Shadowsocks 代理端口 (默认: $SS_SERVER_PORT_DEFAULT): " SS_SERVER_PORT_INPUT
if [ -z "$SS_SERVER_PORT_INPUT" ]; then
    SS_SERVER_PORT="$SS_SERVER_PORT_DEFAULT"
    echo "使用默认代理端口: $SS_SERVER_PORT"
else
    SS_SERVER_PORT="$SS_SERVER_PORT_INPUT"
fi
while ! [[ "$SS_SERVER_PORT" =~ ^[0-9]+$ ]] || [ "$SS_SERVER_PORT" -lt 1 ] || [ "$SS_SERVER_PORT" -gt 65535 ]; do
    echo "端口号无效，请输入一个1到65535之间的数字。"
    read -p "请输入 Shadowsocks 代理端口 (默认: $SS_SERVER_PORT_DEFAULT): " SS_SERVER_PORT_INPUT
    if [ -z "$SS_SERVER_PORT_INPUT" ]; then
        SS_SERVER_PORT="$SS_SERVER_PORT_DEFAULT"
        echo "使用默认代理端口: $SS_SERVER_PORT"
    else
        SS_SERVER_PORT="$SS_SERVER_PORT_INPUT"
    fi
done

# 询问密码
read -s -p "请输入 Shadowsocks 连接密码 (留空将使用现有密码，如果存在): " SS_PASSWORD_INPUT
echo ""
if [ -z "$SS_PASSWORD_INPUT" ]; then
    # 如果用户未输入新密码，尝试读取现有密码
    if [ -f "$CONFIG_FILE" ] && command -v jq &> /dev/null; then
        SS_PASSWORD=$(jq -r '.password // ""' "$CONFIG_FILE")
        if [ -z "$SS_PASSWORD" ]; then
            echo "未输入新密码，且现有配置文件中未找到密码。请务必设置一个密码。"
            while [ -z "$SS_PASSWORD" ]; do
                read -s -p "请重新输入 Shadowsocks 连接密码 (不能为空): " SS_PASSWORD
                echo ""
            done
        else
            echo "未输入新密码，将使用现有密码。"
        fi
    else
        echo "未输入新密码，且无现有配置文件。请务必设置一个密码。"
        while [ -z "$SS_PASSWORD" ]; do
            read -s -p "请重新输入 Shadowsocks 连接密码 (不能为空): " SS_PASSWORD
            echo ""
        done
    fi
else
    SS_PASSWORD="$SS_PASSWORD_INPUT"
fi


# 询问加密方式
echo "可用的加密方式："
echo "  aes-256-gcm (推荐)"
echo "  aes-192-gcm"
echo "  aes-128-gcm"
echo "  chacha20-ietf-poly1305 (推荐)"
echo "  xchacha20-ietf-poly1305"
read -p "请输入 Shadowsocks 加密方式 (默认: $SS_METHOD_DEFAULT): " SS_METHOD_INPUT
if [ -z "$SS_METHOD_INPUT" ]; then
    SS_METHOD="$SS_METHOD_DEFAULT"
    echo "使用默认加密方式: $SS_METHOD"
else
    SS_METHOD="$SS_METHOD_INPUT"
fi

# 询问超时时间
read -p "请输入 Shadowsocks 超时时间 (秒, 默认: $SS_TIMEOUT_DEFAULT): " SS_TIMEOUT_INPUT
if [ -z "$SS_TIMEOUT_INPUT" ]; then
    SS_TIMEOUT="$SS_TIMEOUT_DEFAULT"
    echo "使用默认超时时间: $SS_TIMEOUT"
else
    SS_TIMEOUT="$SS_TIMEOUT_INPUT"
fi
while ! [[ "$SS_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$SS_TIMEOUT" -lt 1 ]; do
    echo "超时时间无效，请输入一个大于0的整数。"
    read -p "请输入 Shadowsocks 超时时间 (秒, 默认: $SS_TIMEOUT_DEFAULT): " SS_TIMEOUT_INPUT
    if [ -z "$SS_TIMEOUT_INPUT" ]; then
        SS_TIMEOUT="$SS_TIMEOUT_DEFAULT"
        echo "使用默认超时时间: $SS_TIMEOUT"
    else
        SS_TIMEOUT="$SS_TIMEOUT_INPUT"
    fi
done

echo ""
echo "正在生成 Shadowsocks-libev 配置文件..."

# 创建配置文件内容
cat <<EOF > "$CONFIG_FILE"
{
    "server":"$SS_SERVER_ADDR",
    "server_port":$SS_SERVER_PORT,
    "password":"$SS_PASSWORD",
    "method":"$SS_METHOD",
    "timeout":$SS_TIMEOUT,
    "fast_open":true
}
EOF

if [ $? -ne 0 ]; then
  echo "配置文件生成失败，请检查权限或路径。"
  exit 1
fi

echo "配置文件已生成到: $CONFIG_FILE"
echo ""
echo "正在设置 Shadowsocks-libev 开机启动并重启服务..."

# 设置开机启动 (幂等操作，重复执行无害)
systemctl enable shadowsocks-libev

# 重启服务以应用新配置
systemctl restart shadowsocks-libev

if [ $? -eq 0 ]; then
  echo "Shadowsocks-libev 服务已成功重启并设置开机启动！"
  echo "配置详情："
  echo "  监听地址: $SS_SERVER_ADDR"
  echo "  代理端口: $SS_SERVER_PORT"
  echo "  连接密码: (已设置，出于安全不显示)"
  echo "  加密方式: $SS_METHOD"
  echo "  超时时间: $SS_TIMEOUT 秒"
else
  echo "Shadowsocks-libev 服务重启失败，请检查日志 (journalctl -u shadowsocks-libev.service) 获取更多信息。"
fi

echo ""
echo "--- 配置完成 ---"
echo "您可以运行 'systemctl status shadowsocks-libev' 来检查服务状态。"
echo ""

# --- 自动设置 'ss' 快捷方式 ---
echo "--- 正在设置 'ss' 快捷方式... ---"

# 获取当前脚本的绝对路径
CURRENT_SCRIPT_PATH=$(readlink -f "$0")

# 如果脚本不在目标位置，则移动它
if [ "$CURRENT_SCRIPT_PATH" != "$SCRIPT_TARGET_PATH" ]; then
    echo "脚本将从 '$CURRENT_SCRIPT_PATH' 移动到 '$SCRIPT_TARGET_PATH'..."
    mv "$CURRENT_SCRIPT_PATH" "$SCRIPT_TARGET_PATH"
    if [ $? -ne 0 ]; then
        echo "脚本移动失败！请手动将脚本移动到 '$SCRIPT_TARGET_PATH' 并检查权限。"
        exit 1
    fi
    # 更新当前脚本路径变量
    CURRENT_SCRIPT_PATH="$SCRIPT_TARGET_PATH"
else
    echo "脚本已位于 '$SCRIPT_TARGET_PATH'，无需移动。"
fi

# 确保脚本有执行权限
echo "正在确保脚本 '$SCRIPT_TARGET_PATH' 具有执行权限..."
chmod +x "$SCRIPT_TARGET_PATH"
if [ $? -ne 0 ]; then
    echo "设置脚本执行权限失败！请手动设置：chmod +x '$SCRIPT_TARGET_PATH'。"
    exit 1
fi

# 创建软链接
echo "正在创建 'ss' 快捷方式 (软链接) 到 '$SS_COMMAND_LINK'..."
ln -sf "$SCRIPT_TARGET_PATH" "$SS_COMMAND_LINK"
if [ $? -ne 0 ]; then
    echo "创建软链接失败！请手动创建：ln -sf '$SCRIPT_TARGET_PATH' '$SS_COMMAND_LINK'。"
    exit 1
fi

echo "'ss' 快捷方式已成功设置！"
echo "现在，您可以在任何地方直接输入 'sudo ss' 来运行此配置脚本了。"
echo "如果您在运行后立即尝试 'ss' 命令但未生效，请尝试重新登录终端或运行 'source ~/.bashrc'。"
echo "------------------------------"
