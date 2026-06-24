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
# 登录后自动跳转确认接口路径
LOGIN_REDIRECT_URL_PATH="/portalLoginRedirect.wlan"
# 连接超时时间 (秒)
CONNECT_TIMEOUT=5
# 请求总超时时间 (秒)
MAX_TIME=10
# 浏览器 User-Agent
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36 Edg/148.0.0.0"

# 日志标签
LOG_TAG="campus_login"

# 锁文件，防止脚本重复执行
LOCK_FILE="/var/run/campus_login.lock"

# 检查用户名密码是否已填写
if [ "$USERNAME" = "YOUR_USERNAME" ] || [ "$PASSWORD" = "YOUR_PASSWORD" ]; then
    logger -t "$LOG_TAG" "错误：请先在脚本中修改 USERNAME 和 PASSWORD 变量。"
    exit 1
fi

# --- 工具函数 ---

normalize_portal_url() {
    INPUT_URL="$1"

    case "$INPUT_URL" in
        http://*|https://*)
            echo "$INPUT_URL"
            ;;
        /*)
            echo "${LOGIN_PORTAL_BASE_URL}${INPUT_URL}"
            ;;
        *)
            echo "${LOGIN_PORTAL_BASE_URL}/${INPUT_URL}"
            ;;
    esac
}

extract_input_value() {
    FIELD_NAME="$1"
    HTML_TEXT="$2"

    LINE=$(printf '%s' "$HTML_TEXT" | tr '<' '\n' | grep "name[[:space:]]*=[[:space:]]*\"$FIELD_NAME\"" | head -n 1)

    if [ -z "$LINE" ]; then
        LINE=$(printf '%s' "$HTML_TEXT" | tr '<' '\n' | grep "name[[:space:]]*=[[:space:]]*'$FIELD_NAME'" | head -n 1)
    fi

    VALUE=$(printf '%s' "$LINE" | sed -n 's/.*value[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p')

    if [ -z "$VALUE" ]; then
        VALUE=$(printf '%s' "$LINE" | sed -n "s/.*value[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p")
    fi

    echo "$VALUE"
}

extract_form_action() {
    FORM_NAME="$1"
    HTML_TEXT="$2"

    LINE=$(printf '%s' "$HTML_TEXT" | tr '<' '\n' | grep '^form' | grep "id[[:space:]]*=[[:space:]]*\"$FORM_NAME\"" | head -n 1)

    if [ -z "$LINE" ]; then
        LINE=$(printf '%s' "$HTML_TEXT" | tr '<' '\n' | grep '^form' | grep "name[[:space:]]*=[[:space:]]*\"$FORM_NAME\"" | head -n 1)
    fi

    if [ -z "$LINE" ]; then
        LINE=$(printf '%s' "$HTML_TEXT" | tr '<' '\n' | grep '^form' | grep "id[[:space:]]*=[[:space:]]*'$FORM_NAME'" | head -n 1)
    fi

    if [ -z "$LINE" ]; then
        LINE=$(printf '%s' "$HTML_TEXT" | tr '<' '\n' | grep '^form' | grep "name[[:space:]]*=[[:space:]]*'$FORM_NAME'" | head -n 1)
    fi

    ACTION=$(printf '%s' "$LINE" | sed -n 's/.*action[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p')

    if [ -z "$ACTION" ]; then
        ACTION=$(printf '%s' "$LINE" | sed -n "s/.*action[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p")
    fi

    echo "$ACTION"
}

extract_frame_src() {
    FRAME_NAME="$1"
    HTML_TEXT="$2"

    LINE=$(printf '%s' "$HTML_TEXT" | tr '<' '\n' | grep '^frame' | grep "name[[:space:]]*=[[:space:]]*\"$FRAME_NAME\"" | head -n 1)

    if [ -z "$LINE" ]; then
        LINE=$(printf '%s' "$HTML_TEXT" | tr '<' '\n' | grep '^frame' | grep "name[[:space:]]*=[[:space:]]*'$FRAME_NAME'" | head -n 1)
    fi

    if [ -z "$LINE" ]; then
        LINE=$(printf '%s' "$HTML_TEXT" | tr '<' '\n' | grep '^frame' | grep 'portal\.wlan' | head -n 1)
    fi

    SRC=$(printf '%s' "$LINE" | sed -n 's/.*src[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p')

    if [ -z "$SRC" ]; then
        SRC=$(printf '%s' "$LINE" | sed -n "s/.*src[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p")
    fi

    echo "$SRC"
}

check_online() {
    for url in $CHECK_204_URLS; do
        logger -t "$LOG_TAG" "204 探测 $url ..."
        HTTP_CODE=$(curl -4 -s -o /dev/null -w "%{http_code}" \
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
        HTTP_CODE=$(curl -4 -s -o /dev/null -w "%{http_code}" \
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

    logger -t "$LOG_TAG" "访问 $PROBE_URL 以获取跳转信息..."
    REDIRECT_HEADER_LINE=$(curl -s -I \
        -A "$USER_AGENT" \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        "$PROBE_URL" | grep -i '^Location:' | tail -n 1)

    if [ -z "$REDIRECT_HEADER_LINE" ]; then
        logger -t "$LOG_TAG" "错误：无法从 $PROBE_URL 获取重定向 Location Header。"
        rm -f "$LOCK_FILE"
        exit 1
    fi

    REDIRECT_URL=$(echo "$REDIRECT_HEADER_LINE" | sed -e 's/^[Ll]ocation: //i' -e 's/\r$//')
    logger -t "$LOG_TAG" "获取到跳转 URL: $REDIRECT_URL"

    LOGIN_PORTAL_BASE_URL=$(echo "$REDIRECT_URL" | sed -n 's,^\(http://[^/]*\)/.*,\1,p')
    LOGIN_PORTAL_HOST_PORT=$(echo "$LOGIN_PORTAL_BASE_URL" | sed -n 's,^http://\([^/]*\),\1,p')

    if [ -z "$LOGIN_PORTAL_BASE_URL" ] || [ -z "$LOGIN_PORTAL_HOST_PORT" ]; then
        logger -t "$LOG_TAG" "错误：无法从跳转 URL 中提取登录门户地址。"
        logger -t "$LOG_TAG" "原始跳转 URL: $REDIRECT_URL"
        rm -f "$LOCK_FILE"
        exit 1
    fi

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

    logger -t "$LOG_TAG" "动态获取到登录门户地址: $LOGIN_PORTAL_BASE_URL (Host: $LOGIN_PORTAL_HOST_PORT)"
    logger -t "$LOG_TAG" "提取参数成功: wlanUserIp=$WLAN_USER_IP, wlanAcIp=$WLAN_AC_IP"

    # --- 模拟浏览器访问 index.php -> indexs.wlan -> portal.wlan ---
    logger -t "$LOG_TAG" "访问门户跳转页 $REDIRECT_URL ..."
    INDEX_REDIRECT_HEADER=$(curl -s -I \
        -A "$USER_AGENT" \
        -H "Host: ${LOGIN_PORTAL_HOST_PORT}" \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        "$REDIRECT_URL" | grep -i '^Location:' | tail -n 1)

    if [ -n "$INDEX_REDIRECT_HEADER" ]; then
        INDEX_REDIRECT_URL=$(echo "$INDEX_REDIRECT_HEADER" | sed -e 's/^[Ll]ocation: //i' -e 's/\r$//')
        INDEX_URL=$(normalize_portal_url "$INDEX_REDIRECT_URL")
    else
        INDEX_URL="$REDIRECT_URL"
    fi

    logger -t "$LOG_TAG" "访问登录框架页 $INDEX_URL ..."
    INDEX_PAGE=$(curl -s \
        -A "$USER_AGENT" \
        -H "Host: ${LOGIN_PORTAL_HOST_PORT}" \
        -H "Referer: ${REDIRECT_URL}" \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        "$INDEX_URL")

    FRAME_SRC=$(extract_frame_src "input" "$INDEX_PAGE")

    if [ -n "$FRAME_SRC" ]; then
        LOGIN_PAGE_URL=$(normalize_portal_url "$FRAME_SRC")
    else
        LOGIN_PAGE_URL="${LOGIN_PORTAL_BASE_URL}/portal.wlan?wlanacname=&wlanacip=${WLAN_AC_IP}&wlanuserip=${WLAN_USER_IP}&ssid=edu"
        logger -t "$LOG_TAG" "警告：未从框架页提取 frame src，使用默认登录页: $LOGIN_PAGE_URL"
    fi

    logger -t "$LOG_TAG" "访问登录页 $LOGIN_PAGE_URL 以提取隐藏参数..."
    LOGIN_PAGE=$(curl -s \
        -A "$USER_AGENT" \
        -H "Host: ${LOGIN_PORTAL_HOST_PORT}" \
        -H "Referer: ${INDEX_URL}" \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        "$LOGIN_PAGE_URL")
    LOGIN_PAGE_CURL_CODE=$?

    if [ "$LOGIN_PAGE_CURL_CODE" -ne 0 ] || [ -z "$LOGIN_PAGE" ]; then
        logger -t "$LOG_TAG" "错误：无法获取登录页 (curl 退出码: $LOGIN_PAGE_CURL_CODE)。"
        rm -f "$LOCK_FILE"
        exit 1
    fi

    PORTAL_LOGIN=$(extract_input_value "portalLogin" "$LOGIN_PAGE")
    LOGIN_FORM_ACTION=$(extract_form_action "loginForm" "$LOGIN_PAGE")
    PASS_TYPE=$(extract_input_value "passType" "$LOGIN_PAGE")
    SSID_VALUE=$(extract_input_value "ssid" "$LOGIN_PAGE")

    if [ -z "$PORTAL_LOGIN" ]; then
        logger -t "$LOG_TAG" "错误：无法从登录页中提取 portalLogin 隐藏参数。请检查登录页 HTML 是否变化。"
        rm -f "$LOCK_FILE"
        exit 1
    fi

    if [ -z "$LOGIN_FORM_ACTION" ]; then
        LOGIN_FORM_ACTION="${LOGIN_URL_PATH}?$(date +%s)"
        logger -t "$LOG_TAG" "警告：无法从登录页提取 form action，使用默认登录路径: $LOGIN_FORM_ACTION"
    fi

    [ -z "$PASS_TYPE" ] && PASS_TYPE="1"
    [ -z "$SSID_VALUE" ] && SSID_VALUE="edu"

    LOGIN_FULL_URL=$(normalize_portal_url "$LOGIN_FORM_ACTION")
    logger -t "$LOG_TAG" "提取新版登录参数成功：portalLogin 已获取，loginUrl=$LOGIN_FULL_URL"

    # --- 第一次 POST：提交账号密码 ---
    POST_DATA="wlanAcName=&wlanAcIp=${WLAN_AC_IP}&wlanUserIp=${WLAN_USER_IP}&ssid=${SSID_VALUE}&portalLogin=${PORTAL_LOGIN}&passType=${PASS_TYPE}&userName=${USERNAME}&userPwd=${PASSWORD}&saveUser=on"

    logger -t "$LOG_TAG" "向 $LOGIN_FULL_URL 发送第一次登录请求..."
    LOGIN_RESPONSE=$(curl -s -X POST \
        -A "$USER_AGENT" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Host: ${LOGIN_PORTAL_HOST_PORT}" \
        -H "Origin: ${LOGIN_PORTAL_BASE_URL}" \
        -H "Referer: ${LOGIN_PAGE_URL}" \
        -H "Connection: close" \
        --data "${POST_DATA}" \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        "$LOGIN_FULL_URL")
    LOGIN_CURL_CODE=$?

    if [ "$LOGIN_CURL_CODE" -ne 0 ] || [ -z "$LOGIN_RESPONSE" ]; then
        logger -t "$LOG_TAG" "错误：第一次登录请求失败 (curl 退出码: $LOGIN_CURL_CODE)。"
        rm -f "$LOCK_FILE"
        exit 1
    fi

    # --- 第二次 POST：模拟浏览器自动提交 portalLoginRedirect.wlan ---
    REDIRECT_FORM_ACTION=$(extract_form_action "submitForm" "$LOGIN_RESPONSE")

    if [ -z "$REDIRECT_FORM_ACTION" ]; then
        REDIRECT_FORM_ACTION="$LOGIN_REDIRECT_URL_PATH"
        logger -t "$LOG_TAG" "警告：无法从第一次登录响应中提取 submitForm action，使用默认跳转确认路径: $REDIRECT_FORM_ACTION"
    fi

    LOGIN_REDIRECT_FULL_URL=$(normalize_portal_url "$REDIRECT_FORM_ACTION")

    VALID_PERIOD=$(extract_input_value "validperiod" "$LOGIN_RESPONSE")
    REDIRECT_WLAN_AC_IP=$(extract_input_value "wlanAcIp" "$LOGIN_RESPONSE")
    IS_LOCAL_USER=$(extract_input_value "isLocalUser" "$LOGIN_RESPONSE")
    REDIRECT_PASS_TYPE=$(extract_input_value "passType" "$LOGIN_RESPONSE")
    ONLINE_NUM=$(extract_input_value "onlineNum" "$LOGIN_RESPONSE")
    LOGON_SESS_ID=$(extract_input_value "logonsessid" "$LOGIN_RESPONSE")
    WLAN_AC_NAME=$(extract_input_value "wlanAcName" "$LOGIN_RESPONSE")
    BOOK_TIME=$(extract_input_value "booktime" "$LOGIN_RESPONSE")
    REDIRECT_WLAN_USER_IP=$(extract_input_value "wlanUserIp" "$LOGIN_RESPONSE")
    AUTO_LOGIN=$(extract_input_value "AUTO_LOGIN" "$LOGIN_RESPONSE")
    REDIRECT_SSID=$(extract_input_value "ssid" "$LOGIN_RESPONSE")
    REDIRECT_USERNAME=$(extract_input_value "userName" "$LOGIN_RESPONSE")
    ENCRY_USER=$(extract_input_value "encryUser" "$LOGIN_RESPONSE")
    COOKIES_VALUE=$(extract_input_value "cookies" "$LOGIN_RESPONSE")

    [ -z "$REDIRECT_WLAN_AC_IP" ] && REDIRECT_WLAN_AC_IP="$WLAN_AC_IP"
    [ -z "$REDIRECT_PASS_TYPE" ] && REDIRECT_PASS_TYPE="$PASS_TYPE"
    [ -z "$ONLINE_NUM" ] && ONLINE_NUM="2"
    [ -z "$REDIRECT_WLAN_USER_IP" ] && REDIRECT_WLAN_USER_IP="$WLAN_USER_IP"
    [ -z "$AUTO_LOGIN" ] && AUTO_LOGIN="true"
    [ -z "$REDIRECT_SSID" ] && REDIRECT_SSID="$SSID_VALUE"
    [ -z "$REDIRECT_USERNAME" ] && REDIRECT_USERNAME="$USERNAME"

    REDIRECT_POST_DATA="validperiod=${VALID_PERIOD}&wlanAcIp=${REDIRECT_WLAN_AC_IP}&isLocalUser=${IS_LOCAL_USER}&passType=${REDIRECT_PASS_TYPE}&onlineNum=${ONLINE_NUM}&logonsessid=${LOGON_SESS_ID}&wlanAcName=${WLAN_AC_NAME}&booktime=${BOOK_TIME}&wlanUserIp=${REDIRECT_WLAN_USER_IP}&AUTO_LOGIN=${AUTO_LOGIN}&ssid=${REDIRECT_SSID}&userName=${REDIRECT_USERNAME}&encryUser=${ENCRY_USER}&cookies=${COOKIES_VALUE}"

    logger -t "$LOG_TAG" "向 $LOGIN_REDIRECT_FULL_URL 发送第二次登录确认请求..."
    REDIRECT_RESPONSE=$(curl -s -X POST \
        -A "$USER_AGENT" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Host: ${LOGIN_PORTAL_HOST_PORT}" \
        -H "Origin: ${LOGIN_PORTAL_BASE_URL}" \
        -H "Referer: ${LOGIN_FULL_URL}" \
        -H "Connection: close" \
        --data "${REDIRECT_POST_DATA}" \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        "$LOGIN_REDIRECT_FULL_URL")
    REDIRECT_CURL_CODE=$?

    if [ "$REDIRECT_CURL_CODE" -ne 0 ] || [ -z "$REDIRECT_RESPONSE" ]; then
        logger -t "$LOG_TAG" "错误：第二次登录确认请求失败 (curl 退出码: $REDIRECT_CURL_CODE)。"
        rm -f "$LOCK_FILE"
        exit 1
    fi

    # --- 验证登录结果 ---
    sleep 3
    logger -t "$LOG_TAG" "登录请求已发送，再次验证网络连接..."

    if check_online; then
        logger -t "$LOG_TAG" "登录流程完成，网络已连接。"
    else
        logger -t "$LOG_TAG" "登录后验证失败，网络可能仍未连接。"
    fi
else
    logger -t "$LOG_TAG" "网络已连接，无需执行登录操作。"
fi

# --- 清理锁 ---
logger -t "$LOG_TAG" "脚本执行完毕。"
rm -f "$LOCK_FILE"
exit 0
