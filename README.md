# CMCC-Campus-Login

# OpenWrt 校园网自动登录脚本 V3

**目前脚本仅测试了长春工业大学CMCC移动校园网自动登录情况，理论上吉林省内高校CMCC移动校园网均可使用**

**问题反馈、项目讨论：**  [https://www.sorkai.com/archives/250](https://www.sorkai.com/archives/250)

**AI写文档改脚本真厉害哈哈哈**

## 1. 概述

本项目提供了一个在 OpenWrt 路由器上运行的 Shell 脚本，旨在自动处理特定类型的校园网 Web 认证登录流程。当路由器检测到网络断开（需要 Web 认证）时，脚本会自动执行登录操作，无需人工干预，方便路由器下的设备接入互联网。

该脚本特别适用于以下特点的校园网认证系统：

* 未认证时访问特定 HTTP 网站（如 `http://www.msftconnecttest.com/redirect`）会返回 302 重定向到登录门户页面。
* 登录门户 URL 包含动态参数（如 `userip`, `basip`）。
* 通过向登录门户的特定路径发送 POST 请求（包含用户名、密码及从跳转 URL 中提取的动态参数）来完成认证。

**最新版本 (V3) 特性:**

* **动态登录门户地址获取:** 不再硬编码登录服务器的 IP 和端口，而是从 302 跳转的 `Location` 头中动态提取，增强了对服务器地址变化的适应性。
* **更可靠的网络状态检测:** 使用固定 204 探测地址 `http://detect.sorkai.com/generate_204` 判断是否真正联网；当 204 探测失败时，再使用 `https://cn.bing.com/`、`https://net-test.sorkai.com/`、`https://www.baidu.com/` 作为 HTTPS 备用探测，避免校园网认证页返回 HTTP 200 时误判为已联网。
* **简化的配置:** 用户名和密码直接在脚本文件头部配置，方便快速部署。
* **日志记录:** 详细记录关键步骤和错误信息到 OpenWrt 系统日志，方便调试和追踪。
* **并发控制:** 使用锁文件机制防止多个脚本实例同时运行。

## 2. 先决条件

在部署此脚本之前，请确保满足以下条件：

* 一台运行 OpenWrt 系统的路由器。
* 可以通过 SSH 访问你的 OpenWrt 路由器。
* 路由器上已安装 `curl` 命令行工具。如果未安装，请通过 SSH 登录后运行：

    ```bash
    opkg update
    opkg install curl
    ```

## 3. 安装与配置

1. **创建脚本文件:**
    通过 SSH 登录到你的 OpenWrt 路由器，使用 `vi` 或其他编辑器创建脚本文件，例如 `/usr/bin/campus_login.sh`：

    ```bash
    vi /usr/bin/campus_login.sh
    ```

    将下面提供的最新脚本代码**完整复制**并粘贴到文件中。

    ```sh
    #!/bin/sh

    # --- 用户配置 ---
    # 请在此处直接修改你的校园网账号和密码
    USERNAME='YOUR_USERNAME'  # 替换成你的校园网用户名
    PASSWORD='YOUR_PASSWORD'  # 替换成你的校园网密码

    # --- 常量与检查配置 ---
    # 固定 204 探测地址：正常联网时应返回 HTTP 204，未认证被劫持时通常不会返回 204
    CHECK_204_URLS="<http://detect.sorkai.com/generate_204>"

    # HTTPS 备用探测列表：204 探测失败时作为备用判断，避免单一探测地址故障导致误登录
    CHECK_HTTPS_URLS="<https://cn.bing.com/> <https://net-test.sorkai.com/> <https://www.baidu.com/>"

    # 用于触发 302 跳转以获取登录参数的 URL (仍需访问以获取动态参数)
    PROBE_URL="<http://www.msftconnecttest.com/redirect>"

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
        logger -t $LOG_TAG "错误：请先在脚本中修改 USERNAME 和 PASSWORD 变量。"
        exit 1
    fi

    # --- 网络状态检测函数 ---
    # 返回 0 表示网络已连接，返回 1 表示需要登录或无法确认已联网
    check_online() {
        for url in $CHECK_204_URLS; do
            logger -t $LOG_TAG "204 探测 $url ..."
            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                --connect-timeout $CONNECT_TIMEOUT \
                --max-time $MAX_TIME \
                "$url")
            CURL_EXIT_CODE=$?

            if [ "$CURL_EXIT_CODE" -eq 0 ] && [ "$HTTP_CODE" = "204" ]; then
                logger -t $LOG_TAG "204 探测成功：$url 返回 HTTP 204，网络已连接。"
                return 0
            fi

            logger -t $LOG_TAG "204 探测未通过：$url (Curl Exit: $CURL_EXIT_CODE, HTTP Code: $HTTP_CODE)。"
        done

        for url in $CHECK_HTTPS_URLS; do
            logger -t $LOG_TAG "HTTPS 备用探测 $url ..."
            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                --connect-timeout $CONNECT_TIMEOUT \
                --max-time $MAX_TIME \
                "$url")
            CURL_EXIT_CODE=$?

            if [ "$CURL_EXIT_CODE" -eq 0 ]; then
                case "$HTTP_CODE" in
                    2*|3*)
                        logger -t $LOG_TAG "HTTPS 备用探测成功：$url 返回 HTTP $HTTP_CODE，网络已连接。"
                        return 0
                        ;;
                esac
            fi

            logger -t $LOG_TAG "HTTPS 备用探测未通过：$url (Curl Exit: $CURL_EXIT_CODE, HTTP Code: $HTTP_CODE)。"
        done

        return 1
    }

    # --- 锁机制 ---
    # 检查锁文件是否存在且对应进程是否仍在运行
    # 使用 flock 会更健壮，但需要安装，这里用简单方法
    if [ -e "$LOCK_FILE" ]; then
        PID=$(cat "$LOCK_FILE")
        # 检查进程是否存在，`ps` 在不同系统参数可能不同，OpenWrt 通常支持无参数 `ps`
        # `grep -q` 用于安静模式匹配
        if ps | grep -q "^ *$PID "; then
            logger -t $LOG_TAG "脚本已在运行 (PID: $PID)。"
            exit 1
        else
            # 进程不存在，但锁文件还在，可能是上次异常退出，移除旧锁
            logger -t $LOG_TAG "发现残留的锁文件，移除之。"
            rm -f "$LOCK_FILE"
        fi
    fi

    # 创建新的锁文件，写入当前进程ID
    echo $$ > "$LOCK_FILE"

    # 设置 trap，确保脚本退出时（正常、中断、终止、挂起）删除锁文件
    trap 'rm -f "$LOCK_FILE"; exit $?' INT TERM EXIT HUP

    # --- 检查是否需要登录 ---
    logger -t $LOG_TAG "开始检查网络连接状态..."
    if check_online; then
        NEED_LOGIN=0 # 0 表示不需要登录
    else
        NEED_LOGIN=1 # 1 表示需要登录
    fi

    # --- 如果需要登录，则执行登录流程 ---
    if [ $NEED_LOGIN -eq 1 ]; then
        logger -t $LOG_TAG "网络状态检测未通过，判断需要登录。尝试获取登录参数..."

        # --- 获取登录参数和动态门户地址 ---
        # 访问探测 URL，获取 302 跳转的 Location Header
        logger -t $LOG_TAG "访问 $PROBE_URL 以获取跳转信息..."
        REDIRECT_HEADER_LINE=$(curl -s -I --connect-timeout $CONNECT_TIMEOUT --max-time $MAX_TIME $PROBE_URL | grep -i '^Location:')

        if [ -z "$REDIRECT_HEADER_LINE" ]; then
            logger -t $LOG_TAG "错误：无法从 $PROBE_URL 获取重定向 Location Header。可能是网络问题或探测 URL 失效。"
            rm -f "$LOCK_FILE" # 出错退出前清理锁
            exit 1
        fi

        # 提取 Location URL
        REDIRECT_URL=$(echo "$REDIRECT_HEADER_LINE" | sed -e 's/^[Ll]ocation: //i' -e 's/\r$//')
        logger -t $LOG_TAG "获取到跳转 URL: $REDIRECT_URL"

        # 动态提取登录门户的 Base URL (scheme://host:port)
        LOGIN_PORTAL_BASE_URL=$(echo "$REDIRECT_URL" | sed -n 's,^\(http://[^/]*\)/.*,\1,p')
        # 动态提取登录门户的 Host[:Port]
        LOGIN_PORTAL_HOST_PORT=$(echo "$LOGIN_PORTAL_BASE_URL" | sed -n 's,^http://\([^/]*\),\1,p')

        if [ -z "$LOGIN_PORTAL_BASE_URL" ] || [ -z "$LOGIN_PORTAL_HOST_PORT" ]; then
            logger -t $LOG_TAG "错误：无法从跳转 URL 中提取登录门户地址。"
            logger -t $LOG_TAG "原始跳转 URL: $REDIRECT_URL"
            rm -f "$LOCK_FILE"
            exit 1
        fi
        logger -t $LOG_TAG "动态获取到登录门户地址: $LOGIN_PORTAL_BASE_URL (Host: $LOGIN_PORTAL_HOST_PORT)"

        # 从跳转 URL 中提取 userip 和 basip
        USER_IP=$(echo "$REDIRECT_URL" | sed -n 's/.*userip=\([^&]*\).*/\1/p')
        BAS_IP=$(echo "$REDIRECT_URL" | sed -n 's/.*basip=\([^&]*\).*/\1/p')

        # 将提取的值赋给 POST 参数名
        WLAN_AC_IP=$BAS_IP
        WLAN_USER_IP=$USER_IP

        if [ -z "$WLAN_USER_IP" ] || [ -z "$WLAN_AC_IP" ]; then
            logger -t $LOG_TAG "错误：无法从跳转 URL 中提取 userip 或 basip。"
            logger -t $LOG_TAG "原始跳转 URL: $REDIRECT_URL"
            rm -f "$LOCK_FILE"
            exit 1
        fi

        logger -t $LOG_TAG "提取参数成功: wlanUserIp=$WLAN_USER_IP, wlanAcIp=$WLAN_AC_IP"

        # --- 构建 POST 数据和目标 URL ---
        POST_DATA="wlanAcName=&wlanAcIp=${WLAN_AC_IP}&wlanUserIp=${WLAN_USER_IP}&ssid=edu&passType=1&userName=${USERNAME}&userPwd=${PASSWORD}&saveUser=on"
        LOGIN_FULL_URL="${LOGIN_PORTAL_BASE_URL}${LOGIN_URL_PATH}"

        # --- 发送登录请求 ---
        logger -t $LOG_TAG "向 $LOGIN_FULL_URL 发送登录请求..."
        # 注意：Host Header 使用动态获取的 LOGIN_PORTAL_HOST_PORT
        LOGIN_RESPONSE=$(curl -s -X POST \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -H "Host: ${LOGIN_PORTAL_HOST_PORT}" \
            -H "Connection: close" \
            --data "${POST_DATA}" \
            --connect-timeout $CONNECT_TIMEOUT \
            --max-time $MAX_TIME \
            "$LOGIN_FULL_URL")

        LOGIN_CURL_CODE=$?

        if [ $LOGIN_CURL_CODE -ne 0 ]; then
            logger -t $LOG_TAG "错误：登录请求失败 (curl 退出码: $LOGIN_CURL_CODE)。"
            # 可以选择在这里重试或退出
        else
            # --- 验证登录结果 ---
            # 等待一小段时间让网络状态生效
            sleep 3
            logger -t $LOG_TAG "登录请求已发送，再次验证网络连接..."

            if check_online; then
                logger -t $LOG_TAG "登录流程完成，网络已连接。"
            else
                logger -t $LOG_TAG "登录后验证失败，网络可能仍未连接。"
                # 可以考虑记录登录服务器的响应内容帮助排查问题
                # logger -t $LOG_TAG "登录服务器响应的部分内容: $(echo "$LOGIN_RESPONSE" | head -n 5)"
            fi
        fi
    else
        logger -t $LOG_TAG "网络已连接，无需执行登录操作。"
    fi

    # --- 清理锁 ---
    logger -t $LOG_TAG "脚本执行完毕。"
    rm -f "$LOCK_FILE"
    exit 0
    ```

2. **修改认证信息:**
    在脚本文件的开头找到以下两行：

    ```sh
    USERNAME='YOUR_USERNAME'  # 替换成你的校园网用户名
    PASSWORD='YOUR_PASSWORD'  # 替换成你的校园网密码
    ```

    将 `'YOUR_USERNAME'` 和 `'YOUR_PASSWORD'` 替换为你实际的校园网用户名和密码。**请确保使用单引号将用户名和密码括起来**。

3. **赋予执行权限:**
    保存脚本文件后，在 SSH 终端中运行以下命令赋予脚本执行权限：

    ```bash
    chmod +x /usr/bin/campus_login.sh
    ```

## 4. 使用方法

1. **手动测试:**
    可以直接在 SSH 终端中运行脚本进行测试：

    ```bash
    /usr/bin/campus_login.sh
    ```

    同时，可以在另一个 SSH 窗口中查看实时日志输出：

    ```bash
    logread -f | grep campus_login
    ```

    或者查看所有相关日志：

    ```bash
    logread | grep campus_login
    ```

    观察日志输出，检查脚本是否能正确判断网络状态、获取参数、发送登录请求并验证成功。

2. **设置定时任务 (Cron):**
    为了让脚本自动运行，需要将其添加到 OpenWrt 的定时任务 (`cron`) 中。
    * 编辑 crontab 文件：

        ```bash
        crontab -e
        ```

    * 在文件末尾添加一行，设置脚本的执行频率。例如，每 5 分钟执行一次：

        ```
        */5 * * * * /usr/bin/campus_login.sh
        ```

        *(解释：`*/5` 表示每 5 分钟，后面四个 `*` 分别代表小时、日、月、星期，`*` 表示任意值)*
    * 保存并退出编辑器 (在 `vi` 中通常是按 `Esc`，然后输入 `:wq` 回车)。
    * 重启 cron 服务以应用更改：

        ```bash
        /etc/init.d/cron restart
        ```

        现在，脚本将按照设定的频率自动检查网络状态并尝试登录。

## 5. 工作原理

脚本的主要工作流程如下：

1. **读取配置:** 从脚本开头的变量中读取用户名和密码。
2. **检查网络状态:** 脚本首先访问 `CHECK_204_URLS` 中的固定 204 探测地址，只有返回 HTTP 204 才认为网络已连接；如果 204 探测失败，再访问 `CHECK_HTTPS_URLS` 中的 HTTPS 备用探测地址，返回 2xx/3xx 时认为网络已连接。这样可以避免未认证状态下校园网登录页返回 HTTP 200 导致误判。
3. **获取登录参数:** 如果所有检查网站都无法访问，则认为需要登录。此时，脚本会访问 `PROBE_URL` (`http://www.msftconnecttest.com/redirect`) 并获取 HTTP 响应头中的 `Location` 字段，即登录门户的跳转 URL。
4. **解析动态信息:** 从获取的跳转 URL 中，使用 `sed` 命令动态提取：
    * 登录门户的基础 URL (`scheme://host:port`)。
    * 登录门户的主机名和端口 (`host:port`)，用于 POST 请求的 `Host` 头。
    * 认证所需的动态参数 `userip` 和 `basip`。
5. **发送登录请求:** 构建包含用户名、密码以及动态参数 (`wlanUserIp=userip`, `wlanAcIp=basip` 等) 的 POST 数据，并将其发送到动态获取的登录门户 URL 的 `/portalLogin.wlan` 路径。
6. **验证登录结果:** 登录请求发送后，脚本会稍作等待，然后再次执行第 2 步的网络状态检查。如果此时能成功访问检查网站，则认为登录成功。
7. **日志记录:** 在整个过程中，关键步骤、提取的参数、成功或失败信息都会通过 `logger` 记录到系统日志。
8. **并发控制:** 通过在 `/var/run/` 目录下创建和检查锁文件 (`campus_login.lock`) 来确保同一时间只有一个脚本实例在运行。

## 6. 故障排查

如果脚本没有按预期工作，可以尝试以下步骤：

* **检查日志:** 这是最重要的步骤。使用 `logread | grep campus_login` 查看脚本的详细输出，通常能定位问题所在（如参数提取失败、curl 请求错误、密码错误等）。
* **检查凭据:** 确认脚本中填写的 `USERNAME` 和 `PASSWORD` 是否准确无误。
* **手动执行:** 在 SSH 中手动运行 `/usr/bin/campus_login.sh`，观察是否有直接的错误信息输出。
* **检查网络环境:** 确认你的校园网认证流程是否与脚本假设的一致（302 跳转、参数名称、POST 地址等）。如果校园网认证系统更新，脚本可能需要相应调整。
* **检查 `curl`:** 确保 `curl` 已正确安装并能正常工作。
* **检查探测地址:** 确认 `CHECK_204_URLS` 中的 204 探测地址在已登录状态下能返回 HTTP 204；同时确认 `CHECK_HTTPS_URLS` 中的 HTTPS 备用探测地址可以正常访问。

## 7. 免责声明

此脚本是根据用户提供的特定校园网认证逻辑编写的。不同的学校或网络环境可能有不同的认证机制。请在充分理解脚本工作原理和自身网络环境的基础上使用。作者不对因使用此脚本导致的任何问题负责。
