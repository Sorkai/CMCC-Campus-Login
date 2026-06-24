#!/bin/sh

# --- 用户配置 ---
# 请在此处直接修改你的校园网账号和密码
USERNAME='YOUR_USERNAME'  # 替换成你的校园网用户名
PASSWORD='YOUR_PASSWORD'  # 替换成你的校园网密码

# --- 常量与检查配置 ---
# 固定 204 探测地址：正常联网时应返回 HTTP 204，未认证被劫持时通常不会返回 204
CHECK_204_URLS="http://detect.sorkai.com/generate_204"
# HTTPS 备用探测列表：204 探测失败时作为备用判断，避免单一探测地址故障导致误登录
CHECK_HTTPS_URLS="https://cn.bing.com/ https://net-test.sorkai.com/ https://www.baidu.com/"
# 用于触发 302 跳转以获取登录参数的 URL
PROBE_URL="http://www.msftconnecttest.com/redirect"
# 登录接口相对于门户根路径的路径
LOGIN_URL_PATH="/portalLogin.wlan"
# 连接超时时间 (秒)
CONNECT_TIMEOUT=5
# 请求总超时时间 (秒)
MAX_TIME=10

# 日志标签
LOG_TAG="campus_login"

# 锁文件，防止脚本重复执行
LOCK_FILE="/var/run/campus_login.lock"

# 检查用户名密码是否已填写
if [ "$USERNAME" = "YOUR_USERNAME" ] || [ "$PASSWORD" = "YOUR_PASSWORD" ]; then
    logger -t "$LOG_TAG" "错误：请先在脚本中修改 USERNAME 和 PASSWORD 变量。"
    exit 1
fi

# --- 网络状态检测函数 ---
# 返回 0 表示网络已连接，返回 1 表示需要登录或无法确认已联网
check_online() {
    for url in $CHECK_204_URLS; do
        logger -t "$LOG_TAG" "204 探测 $url ..."
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$MAX_TIME" \
            "$url")
        CURL_EXIT_CODE=$?

        if [ "$CURL_EXIT_CODE" -eq 0 ] && [ "$HTTP_CODE" = "204" ]; then
            logger -t "$LOG_TAG" "204 探测成功：$url 返回 HTTP 204，网络已连接。"
            return 0
        fi

        logger -t "$LOG_TAG" "204 探测未通过：$url (Curl Exit: $CURL_EXIT_CODE, HTTP Code: $HTTP_CODE)。"
    done

    for url in $CHECK_HTTPS_URLS; do
        logger -t "$LOG_TAG" "HTTPS 备用探测 $url ..."
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$MAX_TIME" \
            "$url")
        CURL_EXIT_CODE=$?

        if [ "$CURL_EXIT_CODE" -eq 0 ]; then
            case "$HTTP_CODE" in
                2*|3*)
                    logger -t "$LOG_TAG" "HTTPS 备用探测成功：$url 返回 HTTP $HTTP_CODE，网络已连接。"
                    return 0
                    ;;
            esac
        fi

        logger -t "$LOG_TAG" "HTTPS 备用探测未通过：$url (Curl Exit: $CURL_EXIT_CODE, HTTP Code: $HTTP_CODE)。"
    done

    return 1
}

# --- 锁机制 ---
if [ -e "$LOCK_FILE" ]; then
    PID=$(cat "$LOCK_FILE")
    if ps | grep -q "^ *$PID "; then
        logger -t "$LOG_TAG" "脚本已在运行 (PID: $PID)。"
        exit 1
    else
        logger -t "$LOG_TAG" "发现残留的锁文件，移除之。"
        rm -f "$LOCK_FILE"
    fi
fi

echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"; exit $?' INT TERM EXIT HUP

# --- 检查是否需要登录 ---
logger -t "$LOG_TAG" "开始检查网络连接状态..."
if check_online; then
    NEED_LOGIN=0
else
    NEED_LOGIN=1
fi

# --- 如果需要登录，则执行登录流程 ---
if [ "$NEED_LOGIN" -eq 1 ]; then
    logger -t "$LOG_TAG" "网络状态检测未通过，判断需要登录。尝试获取登录参数..."

    # --- 获取登录参数和动态门户地址 ---
    logger -t "$LOG_TAG" "访问 $PROBE_URL 以获取跳转信息..."
    REDIRECT_HEADER_LINE=$(curl -s -I \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        "$PROBE_URL" | grep -i '^Location:')

    if [ -z "$REDIRECT_HEADER_LINE" ]; then
        logger -t "$LOG_TAG" "错误：无法从 $PROBE_URL 获取重定向 Location Header。可能是网络问题或探测 URL 失效。"
        rm -f "$LOCK_FILE"
        exit 1
    fi

    # 提取 Location URL
    REDIRECT_URL=$(echo "$REDIRECT_HEADER_LINE" | sed -e 's/^[Ll]ocation: //i' -e 's/\r$//')
    logger -t "$LOG_TAG" "获取到跳转 URL: $REDIRECT_URL"

    # 动态提取登录门户的 Base URL (scheme://host:port)
    LOGIN_PORTAL_BASE_URL=$(echo "$REDIRECT_URL" | sed -n 's,^\(http://[^/]*\)/.*,\1,p')
    # 动态提取登录门户的 Host[:Port]
    LOGIN_PORTAL_HOST_PORT=$(echo "$LOGIN_PORTAL_BASE_URL" | sed -n 's,^http://\([^/]*\),\1,p')

    if [ -z "$LOGIN_PORTAL_BASE_URL" ] || [ -z "$LOGIN_PORTAL_HOST_PORT" ]; then
        logger -t "$LOG_TAG" "错误：无法从跳转 URL 中提取登录门户地址。"
        logger -t "$LOG_TAG" "原始跳转 URL: $REDIRECT_URL"
        rm -f "$LOCK_FILE"
        exit 1
    fi

    logger -t "$LOG_TAG" "动态获取到登录门户地址: $LOGIN_PORTAL_BASE_URL (Host: $LOGIN_PORTAL_HOST_PORT)"

    # 从跳转 URL 中提取 userip 和 basip
    USER_IP=$(echo "$REDIRECT_URL" | sed -n 's/.*userip=\([^&]*\).*/\1/p')
    BAS_IP=$(echo "$REDIRECT_URL" | sed -n 's/.*basip=\([^&]*\).*/\1/p')

    WLAN_AC_IP=$BAS_IP
    WLAN_USER_IP=$USER_IP

    if [ -z "$WLAN_USER_IP" ] || [ -z "$WLAN_AC_IP" ]; then
        logger -t "$LOG_TAG" "错误：无法从跳转 URL 中提取 userip 或 basip。"
        logger -t "$LOG_TAG" "原始跳转 URL: $REDIRECT_URL"
        rm -f "$LOCK_FILE"
        exit 1
    fi

    logger -t "$LOG_TAG" "提取参数成功: wlanUserIp=$WLAN_USER_IP, wlanAcIp=$WLAN_AC_IP"

    # --- 构建 POST 数据和目标 URL ---
    POST_DATA="wlanAcName=&wlanAcIp=${WLAN_AC_IP}&wlanUserIp=${WLAN_USER_IP}&ssid=edu&passType=1&userName=${USERNAME}&userPwd=${PASSWORD}&saveUser=on"
    LOGIN_FULL_URL="${LOGIN_PORTAL_BASE_URL}${LOGIN_URL_PATH}"

    # --- 发送登录请求 ---
    logger -t "$LOG_TAG" "向 $LOGIN_FULL_URL 发送登录请求..."
    LOGIN_RESPONSE=$(curl -s -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Host: ${LOGIN_PORTAL_HOST_PORT}" \
        -H "Connection: close" \
        --data "${POST_DATA}" \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        "$LOGIN_FULL_URL")

    LOGIN_CURL_CODE=$?

    if [ "$LOGIN_CURL_CODE" -ne 0 ]; then
        logger -t "$LOG_TAG" "错误：登录请求失败 (curl 退出码: $LOGIN_CURL_CODE)。"
    else
        sleep 3
        logger -t "$LOG_TAG" "登录请求已发送，再次验证网络连接..."

        if check_online; then
            logger -t "$LOG_TAG" "登录流程完成，网络已连接。"
        else
            logger -t "$LOG_TAG" "登录后验证失败，网络可能仍未连接。"
            # 如需深度排查，可临时取消下一行注释，但注意不要长期记录敏感响应。
            # logger -t "$LOG_TAG" "登录服务器响应的部分内容: $(echo "$LOGIN_RESPONSE" | head -n 5)"
        fi
    fi
else
    logger -t "$LOG_TAG" "网络已连接，无需执行登录操作。"
fi

# --- 清理锁 ---
logger -t "$LOG_TAG" "脚本执行完毕。"
rm -f "$LOCK_FILE"
exit 0