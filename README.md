# CMCC-Campus-Login
# OpenWrt 校园网自动登录脚本 V2

**目前脚本仅测试了长春工业大学CMCC移动校园网自动登录情况，理论上吉林省内高校CMCC移动校园网均可使用**

## 1. 概述

本项目提供了一个在 OpenWrt 路由器上运行的 Shell 脚本，旨在自动处理特定类型的校园网 Web 认证登录流程。当路由器检测到网络断开（需要 Web 认证）时，脚本会自动执行登录操作，无需人工干预，方便路由器下的设备接入互联网。

该脚本特别适用于以下特点的校园网认证系统：

* 未认证时访问特定 HTTP 网站（如 `http://www.msftconnecttest.com/redirect`）会返回 302 重定向到登录门户页面。
* 登录门户 URL 包含动态参数（如 `userip`, `basip`）。
* 通过向登录门户的特定路径发送 POST 请求（包含用户名、密码及从跳转 URL 中提取的动态参数）来完成认证。

**最新版本 (V2) 特性:**

* **动态登录门户地址获取:** 不再硬编码登录服务器的 IP 和端口，而是从 302 跳转的 `Location` 头中动态提取，增强了对服务器地址变化的适应性。
* **健壮的网络状态检测:** 通过尝试访问多个（当前为三个）常用网站（百度、腾讯、Sorkai），判断网络是否真正需要登录认证，提高了检测的可靠性。
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

1.  **创建脚本文件:**
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
    # 检查网络状态的 URL 列表 (用空格分隔)
    CHECK_URLS="[https://www.baidu.com/](https://www.baidu.com/) [https://www.qq.com/](https://www.qq.com/) [https://www.sorkai.com/](https://www.sorkai.com/)"
    # 用于触发 302 跳转以获取登录参数的 URL (仍需访问以获取动态参数)
    PROBE_URL="[http://www.msftconnecttest.com/redirect](http://www.msftconnecttest.com/redirect)"
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

    # --- 锁机制 ---
    if [ -e "$LOCK_FILE" ]; then
        PID=$(cat "$LOCK_FILE")
        if ps | grep -q "^ *$PID "; then
            logger -t $LOG_TAG "脚本已在运行 (PID: $PID)。"
            exit 1
        else
            logger -t $LOG_TAG "发现残留的锁文件，移除之。"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"; exit $?' INT TERM EXIT HUP

    # --- 检查是否需要登录 ---
    logger -t $LOG_TAG "开始检查网络连接状态..."
    NEED_LOGIN=1 # 默认需要登录 (1 表示需要, 0 表示不需要)

    for url in $CHECK_URLS; do
        logger -t $LOG_TAG "尝试访问 $url ..."
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout $CONNECT_TIMEOUT --max-time $MAX_TIME "$url")
        CURL_EXIT_CODE=$?
        if [ $CURL_EXIT_CODE -eq 0 ] && [ "$HTTP_CODE" -eq 200 ]; then
            logger -t $LOG_TAG "成功访问 $url (HTTP 200)。网络已连接。"
            NEED_LOGIN=0 # 设置为不需要登录
            break # 只要有一个成功，就跳出循环
        else
            logger -t $LOG_TAG "访问 $url 失败 (Curl Exit: $CURL_EXIT_CODE, HTTP Code: $HTTP_CODE)。"
        fi
    done

    # --- 如果需要登录，则执行登录流程 ---
    if [ $NEED_LOGIN -eq 1 ]; then
        logger -t $LOG_TAG "所有检查 URL 均无法访问，判断需要登录。尝试获取登录参数..."

        # --- 获取登录参数和动态门户地址 ---
        logger -t $LOG_TAG "访问 $PROBE_URL 以获取跳转信息..."
        REDIRECT_HEADER_LINE=$(curl -s -I --connect-timeout $CONNECT_TIMEOUT --max-time $MAX_TIME $PROBE_URL | grep -i '^Location:')

        if [ -z "$REDIRECT_HEADER_LINE" ]; then
            logger -t $LOG_TAG "错误：无法从 $PROBE_URL 获取重定向 Location Header。可能是网络问题或探测 URL 失效。"
            rm -f "$LOCK_FILE" # 出错退出前清理锁
            exit 1
        fi
        REDIRECT_URL=$(echo "$REDIRECT_HEADER_LINE" | sed -e 's/^[Ll]ocation: //i' -e 's/\r$//')
        logger -t $LOG_TAG "获取到跳转 URL: $REDIRECT_URL"
        LOGIN_PORTAL_BASE_URL=$(echo "$REDIRECT_URL" | sed -n 's,^\(http://[^/]*\)/.*,\1,p')
        LOGIN_PORTAL_HOST_PORT=$(echo "$LOGIN_PORTAL_BASE_URL" | sed -n 's,^http://\([^/]*\),\1,p')

        if [ -z "$LOGIN_PORTAL_BASE_URL" ] || [ -z "$LOGIN_PORTAL_HOST_PORT" ]; then
            logger -t $LOG_TAG "错误：无法从跳转 URL 中提取登录门户地址。"
            logger -t $LOG_TAG "原始跳转 URL: $REDIRECT_URL"
            rm -f "$LOCK_FILE"
            exit 1
        fi
        logger -t $LOG_TAG "动态获取到登录门户地址: $LOGIN_PORTAL_BASE_URL (Host: $LOGIN_PORTAL_HOST_PORT)"
        USER_IP=$(echo "$REDIRECT_URL" | sed -n 's/.*userip=\([^&]*\).*/\1/p')
        BAS_IP=$(echo "$REDIRECT_URL" | sed -n 's/.*basip=\([^&]*\).*/\1/p')
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
        else
            # --- 验证登录结果 ---
            sleep 3
            logger -t $LOG_TAG "登录请求已发送，再次验证网络连接..."
            VERIFY_SUCCESS=0
            for url in $CHECK_URLS; do
                logger -t $LOG_TAG "尝试访问 $url 进行验证..."
                HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout $CONNECT_TIMEOUT --max-time $MAX_TIME "$url")
                CURL_EXIT_CODE=$?
                if [ $CURL_EXIT_CODE -eq 0 ] && [ "$HTTP_CODE" -eq 200 ]; then
                    logger -t $LOG_TAG "验证成功：成功访问 $url (HTTP 200)。"
                    VERIFY_SUCCESS=1
                    break
                else
                    logger -t $LOG_TAG "验证时访问 $url 失败 (Curl Exit: $CURL_EXIT_CODE, HTTP Code: $HTTP_CODE)。"
                fi
            done
            if [ $VERIFY_SUCCESS -eq 1 ]; then
                logger -t $LOG_TAG "登录流程完成，网络已连接。"
            else
                logger -t $LOG_TAG "登录后验证失败，网络可能仍未连接。"
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

2.  **修改认证信息:**
    在脚本文件的开头找到以下两行：
    ```sh
    USERNAME='YOUR_USERNAME'  # 替换成你的校园网用户名
    PASSWORD='YOUR_PASSWORD'  # 替换成你的校园网密码
    ```
    将 `'YOUR_USERNAME'` 和 `'YOUR_PASSWORD'` 替换为你实际的校园网用户名和密码。**请确保使用单引号将用户名和密码括起来**。

3.  **赋予执行权限:**
    保存脚本文件后，在 SSH 终端中运行以下命令赋予脚本执行权限：
    ```bash
    chmod +x /usr/bin/campus_login.sh
    ```

## 4. 使用方法

1.  **手动测试:**
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

2.  **设置定时任务 (Cron):**
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

1.  **读取配置:** 从脚本开头的变量中读取用户名和密码。
2.  **检查网络状态:** 依次尝试访问 `CHECK_URLS` 列表中的网站。如果其中任何一个网站能成功访问（返回 HTTP 200），则认为网络已连接，脚本退出。
3.  **获取登录参数:** 如果所有检查网站都无法访问，则认为需要登录。此时，脚本会访问 `PROBE_URL` (`http://www.msftconnecttest.com/redirect`) 并获取 HTTP 响应头中的 `Location` 字段，即登录门户的跳转 URL。
4.  **解析动态信息:** 从获取的跳转 URL 中，使用 `sed` 命令动态提取：
    * 登录门户的基础 URL (`scheme://host:port`)。
    * 登录门户的主机名和端口 (`host:port`)，用于 POST 请求的 `Host` 头。
    * 认证所需的动态参数 `userip` 和 `basip`。
5.  **发送登录请求:** 构建包含用户名、密码以及动态参数 (`wlanUserIp=userip`, `wlanAcIp=basip` 等) 的 POST 数据，并将其发送到动态获取的登录门户 URL 的 `/portalLogin.wlan` 路径。
6.  **验证登录结果:** 登录请求发送后，脚本会稍作等待，然后再次执行第 2 步的网络状态检查。如果此时能成功访问检查网站，则认为登录成功。
7.  **日志记录:** 在整个过程中，关键步骤、提取的参数、成功或失败信息都会通过 `logger` 记录到系统日志。
8.  **并发控制:** 通过在 `/var/run/` 目录下创建和检查锁文件 (`campus_login.lock`) 来确保同一时间只有一个脚本实例在运行。

## 6. 故障排查

如果脚本没有按预期工作，可以尝试以下步骤：

* **检查日志:** 这是最重要的步骤。使用 `logread | grep campus_login` 查看脚本的详细输出，通常能定位问题所在（如参数提取失败、curl 请求错误、密码错误等）。
* **检查凭据:** 确认脚本中填写的 `USERNAME` 和 `PASSWORD` 是否准确无误。
* **手动执行:** 在 SSH 中手动运行 `/usr/bin/campus_login.sh`，观察是否有直接的错误信息输出。
* **检查网络环境:** 确认你的校园网认证流程是否与脚本假设的一致（302 跳转、参数名称、POST 地址等）。如果校园网认证系统更新，脚本可能需要相应调整。
* **检查 `curl`:** 确保 `curl` 已正确安装并能正常工作。
* **检查 `CHECK_URLS`:** 确认用于检查网络状态的网站是否可以从你的网络环境正常访问（在已登录状态下）。

## 7. 免责声明

此脚本是根据用户提供的特定校园网认证逻辑编写的。不同的学校或网络环境可能有不同的认证机制。请在充分理解脚本工作原理和自身网络环境的基础上使用。作者不对因使用此脚本导致的任何问题负责。

