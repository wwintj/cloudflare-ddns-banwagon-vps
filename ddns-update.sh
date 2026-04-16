#!/usr/bin/env bash
# ==============================================================================
# Cloudflare DDNS Updater
# ==============================================================================

set -euo pipefail

# 显式声明系统路径，防止 Systemd 极简环境导致命令找不到
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- 预检 ---
for cmd in curl jq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "CRITICAL: Required command '$cmd' is not installed or not in PATH." >&2
        exit 1
    fi
done

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <path_to_env_file>" >&2
    exit 1
fi

CONFIG_FILE="$1"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "CRITICAL: Configuration file not found at $CONFIG_FILE" >&2
    exit 1
fi

# 安全加载配置
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# 严格变量校验
: "${CF_API_TOKEN:?CF_API_TOKEN is required}"
: "${CF_ZONE_NAME:?CF_ZONE_NAME is required}"
: "${CF_RECORD_NAME:?CF_RECORD_NAME is required}"
: "${CF_RECORD_TYPE:?CF_RECORD_TYPE is required}"
: "${CF_TTL:?CF_TTL is required}"
: "${CF_PROXIED:?CF_PROXIED is required}"

CACHE_DIR="/var/lib/cf-ddns"
CACHE_FILE="${CACHE_DIR}/${CF_RECORD_NAME}.cache"
HOSTNAME=$(hostname)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- 辅助函数 ---

# 使用 HTML 模式发送 Telegram 通知，避免 Markdown 解析因 Hostname 中的特殊字符崩溃
send_tg() {
    local message="$1"
    if [[ -n "${TG_BOT_TOKEN:-}" ]] && [[ -n "${TG_CHAT_ID:-}" ]]; then
        curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TG_CHAT_ID}" \
            -d "parse_mode=HTML" \
            --data-urlencode "text=${message}" > /dev/null || {
                echo "WARNING: Failed to send Telegram notification." >&2
            }
    fi
}

is_valid_ipv4() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if (( octet < 0 || octet > 255 )); then return 1; fi
        done
        return 0
    fi
    return 1
}

get_public_ip() {
    local ip=""
    local endpoints=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://icanhazip.com"
        "https://ident.me"
    )

    for endpoint in "${endpoints[@]}"; do
        if ip=$(curl -s -4 --max-time 10 "$endpoint"); then
            if is_valid_ipv4 "$ip"; then
                echo "$ip"
                return 0
            fi
        fi
    done
    return 1
}

# --- 主执行逻辑 ---

CURRENT_IP=$(get_public_ip) || {
    echo "CRITICAL: Could not determine a valid public IPv4 address from any endpoint." >&2
    exit 1
}

# 缓存评估
if [ -f "$CACHE_FILE" ]; then
    CACHED_IP=$(cat "$CACHE_FILE")
    if [ "$CURRENT_IP" == "$CACHED_IP" ]; then
        exit 0
    fi
else
    CACHED_IP="None"
fi

echo "INFO: IP change detected: ${CACHED_IP} -> ${CURRENT_IP}"
send_tg "🔄 <b>DDNS IP Change Detected</b>
<b>Host:</b> <code>${HOSTNAME}</code>
<b>Domain:</b> <code>${CF_RECORD_NAME}</code>
<b>Old IP:</b> <code>${CACHED_IP}</code>
<b>New IP:</b> <code>${CURRENT_IP}</code>
<b>Time (UTC):</b> <code>${TIMESTAMP}</code>
<b>Status:</b> Updating Cloudflare..."

# 1. 获取 Zone ID (增加超时限制，防宕机阻塞)
ZONE_RESPONSE=$(curl -s --max-time 15 -X GET "https://api.cloudflare.com/client/v4/zones?name=${CF_ZONE_NAME}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" || true)

# 安全解析 JSON，防止 CF 网关错误返回 HTML 导致 jq 崩溃
ZONE_SUCCESS=$(echo "$ZONE_RESPONSE" | jq -r '.success // "false"' 2>/dev/null || echo "false")

if [ "$ZONE_SUCCESS" != "true" ]; then
    ERR_MSG=$(echo "$ZONE_RESPONSE" | jq -r '.errors[0].message // "API connection failed or invalid JSON returned"' 2>/dev/null || echo "Invalid API Response")
    echo "CRITICAL: Failed to fetch Zone ID. Cloudflare API Error: $ERR_MSG" >&2
    send_tg "❌ <b>DDNS Update Failed</b>
<b>Domain:</b> <code>${CF_RECORD_NAME}</code>
<b>Error:</b> Zone ID fetch failed - ${ERR_MSG}"
    exit 1
fi

ZONE_ID=$(echo "$ZONE_RESPONSE" | jq -r '.result[0].id // empty' 2>/dev/null || echo "")
if [ -z "$ZONE_ID" ]; then
    echo "CRITICAL: Zone '$CF_ZONE_NAME' not found in Cloudflare account." >&2
    exit 1
fi

# 2. 获取 Record ID
RECORD_RESPONSE=$(curl -s --max-time 15 -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${CF_RECORD_NAME}&type=${CF_RECORD_TYPE}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" || true)

RECORD_ID=$(echo "$RECORD_RESPONSE" | jq -r '.result[0].id // empty' 2>/dev/null || echo "")

# 结构化安全载荷：统一采用字符串传入，由 jq 内部强转类型，防止 Bash 空字符导致 jq 崩溃
PAYLOAD=$(jq -n \
    --arg type "$CF_RECORD_TYPE" \
    --arg name "$CF_RECORD_NAME" \
    --arg content "$CURRENT_IP" \
    --arg ttl "${CF_TTL:-60}" \
    --arg proxied "${CF_PROXIED:-false}" \
    '{type: $type, name: $name, content: $content, ttl: ($ttl | tonumber), proxied: ($proxied == "true")}')

# 3. 执行更新或创建
if [ -z "$RECORD_ID" ]; then
    echo "INFO: DNS record does not exist. Creating new record..."
    API_RESPONSE=$(curl -s --max-time 15 -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" || true)
else
    echo "INFO: DNS record found (ID: $RECORD_ID). Updating..."
    API_RESPONSE=$(curl -s --max-time 15 -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" || true)
fi

UPDATE_SUCCESS=$(echo "$API_RESPONSE" | jq -r '.success // "false"' 2>/dev/null || echo "false")

if [ "$UPDATE_SUCCESS" == "true" ]; then
    echo "SUCCESS: DNS record for $CF_RECORD_NAME updated to $CURRENT_IP"
    
    # 确保持久化状态写入
    mkdir -p "$CACHE_DIR"
    echo "$CURRENT_IP" > "$CACHE_FILE"
    
    send_tg "✅ <b>DDNS Update Successful</b>
<b>Host:</b> <code>${HOSTNAME}</code>
<b>Domain:</b> <code>${CF_RECORD_NAME}</code>
<b>New IP:</b> <code>${CURRENT_IP}</code>
<b>Time (UTC):</b> <code>${TIMESTAMP}</code>"
else
    ERR_MSG=$(echo "$API_RESPONSE" | jq -r '.errors[0].message // "Unknown API error"' 2>/dev/null || echo "Invalid API Response")
    echo "CRITICAL: Error updating DNS record: $ERR_MSG" >&2
    
    send_tg "❌ <b>DDNS Update Failed</b>
<b>Host:</b> <code>${HOSTNAME}</code>
<b>Domain:</b> <code>${CF_RECORD_NAME}</code>
<b>IP:</b> <code>${CURRENT_IP}</code>
<b>Error:</b> ${ERR_MSG}
<b>Time (UTC):</b> <code>${TIMESTAMP}</code>"
    exit 1
fi
