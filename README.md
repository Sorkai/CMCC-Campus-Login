# CMCC-Campus-Login

OpenWrt 校园网 CMCC Web 认证自动登录脚本。

本项目用于在 OpenWrt 路由器上自动完成校园网门户认证。路由器检测到网络未认证时，会按浏览器实际登录流程访问认证门户、提交账号密码、完成二次确认，并在登录后再次验证网络连通性。

目前脚本主要按长春工业大学 CMCC 移动校园网环境整理，吉林省内类似 CMCC 校园网门户可参考使用。不同学校的门户参数、表单字段、认证地址可能不同，使用前请先确认你的认证页面流程是否匹配。

问题反馈和项目讨论：[https://www.sorkai.com/archives/250](https://www.sorkai.com/archives/250)

## 功能特性

* 自动检测当前网络是否已经联网，避免重复提交登录请求。
* 使用 HTTP 204 探测加 HTTPS 备用探测，降低被认证页 HTTP 200 误判为联网的概率。
* 从未认证重定向地址中动态提取门户地址、`userip` 和 `basip`。
* 模拟浏览器先访问门户入口，再进入 `indexs.wlan` 框架页，解析 frame 中的 `portal.wlan` 登录页。
* 从登录页提取隐藏参数 `portalLogin` 和带时间戳的表单 `action`。
* HTML 提取逻辑兼容 `value="xxx"`、`value = "xxx"`、单引号和双引号写法。
* 第一次 POST 使用登录页真实 `form action`，提交到 `portalLogin.wlan?...`。
* 第一次响应后继续模拟浏览器自动提交 `portalLoginRedirect.wlan`，补齐第二次确认 POST。
* 使用浏览器 User-Agent、`Origin`、`Referer`、`Host` 等请求头，尽量贴近浏览器请求。
* 使用锁文件避免脚本并发执行。
* 通过 OpenWrt `logger` 写入系统日志，方便排障。

## 适用条件

脚本适用于大致符合以下流程的校园网认证系统：

1. 未认证时访问 HTTP 探测地址会被 302 跳转到认证门户。
2. 跳转 URL 中包含 `userip` 和 `basip`。
3. 门户入口会跳到类似 `indexs.wlan` 的框架页。
4. 框架页中包含指向 `portal.wlan` 的 `frame src`。
5. `portal.wlan` 页面中包含隐藏字段 `portalLogin`。
6. 登录表单会提交到 `portalLogin.wlan`，并且 `action` 可能带时间戳参数。
7. 首次登录响应中还有一个自动提交表单，需要再次 POST 到 `portalLoginRedirect.wlan` 或响应中的确认 `action`。

如果你的校园网仍是旧版一次 POST 流程，或字段名不是这些值，需要按实际浏览器请求调整 `campus_login.sh`。

## 安装

先通过 SSH 登录 OpenWrt，并安装 `curl`：

```bash
opkg update
opkg install curl
```

把仓库中的 `campus_login.sh` 放到 OpenWrt，例如：

```bash
scp campus_login.sh root@192.168.1.1:/usr/bin/campus_login.sh
ssh root@192.168.1.1
chmod +x /usr/bin/campus_login.sh
```

也可以在 OpenWrt 上直接下载：

```bash
curl -L -o /usr/bin/campus_login.sh https://raw.githubusercontent.com/Sorkai/CMCC-Campus-Login/main/campus_login.sh
chmod +x /usr/bin/campus_login.sh
```

## 配置账号

编辑 `/usr/bin/campus_login.sh`，修改文件开头的账号密码：

```sh
USERNAME='YOUR_USERNAME'
PASSWORD='YOUR_PASSWORD'
```

把 `YOUR_USERNAME` 和 `YOUR_PASSWORD` 替换成你的校园网账号和密码。建议保留单引号，避免 shell 对特殊字符做额外展开。

脚本会把账号密码保存在本地明文文件中，请只部署在你信任和可控的路由器上。可以收紧文件权限：

```bash
chmod 700 /usr/bin/campus_login.sh
```

## 手动测试

在 OpenWrt 上运行：

```bash
/usr/bin/campus_login.sh
```

查看实时日志：

```bash
logread -f | grep campus_login
```

或查看历史日志：

```bash
logread | grep campus_login
```

如果登录成功，日志中通常会出现“登录流程完成，网络已连接”。如果失败，请根据日志中的具体阶段定位问题。

## 定时运行

编辑 crontab：

```bash
crontab -e
```

例如每 5 分钟检查一次：

```cron
*/5 * * * * /usr/bin/campus_login.sh
```

保存后重启 cron：

```bash
/etc/init.d/cron restart
```

## 工作流程

脚本的核心流程如下：

1. 执行网络连通性检测。
   * 首先访问 `http://detect.sorkai.com/generate_204`，只有返回 HTTP 204 才直接认为已联网。
   * 204 探测失败后，再访问 `https://cn.bing.com/`、`https://net-test.sorkai.com/`、`https://www.baidu.com/`，返回 2xx 或 3xx 时认为已联网。
2. 如果检测失败，访问 `http://www.msftconnecttest.com/redirect` 获取认证门户的 `Location`。
3. 从重定向 URL 中解析：
   * 门户基础地址，例如 `http://portal.wlan` 或带端口的地址。
   * 门户 `Host`。
   * `userip`，作为 `wlanUserIp`。
   * `basip`，作为 `wlanAcIp`。
4. 访问门户跳转页，按响应中的 `Location` 进入登录框架页。常见路径类似：

   ```text
   index.php -> indexs.wlan
   ```

5. 从框架页解析 `name="input"` 的 frame，或兜底查找包含 `portal.wlan` 的 frame，并拼出真实登录页地址。
6. GET 登录页，提取：
   * 隐藏字段 `portalLogin`。
   * `loginForm` 的 `action`，通常是带时间戳的 `portalLogin.wlan?...`。
   * `passType` 和 `ssid`，提取不到时分别回退到 `1` 和 `edu`。
7. 第一次 POST 到登录表单真实 `action`，提交：
   * `wlanAcIp`
   * `wlanUserIp`
   * `ssid`
   * `portalLogin`
   * `passType`
   * `userName`
   * `userPwd`
   * `saveUser`
8. 解析第一次响应中的自动提交表单，提取 `submitForm` 的 `action` 和隐藏字段。
9. 第二次 POST 到 `portalLoginRedirect.wlan` 或响应中给出的确认 `action`，提交 `validperiod`、`logonsessid`、`encryUser`、`cookies` 等确认字段。
10. 等待 3 秒后再次执行网络检测，确认是否已经联网。

## 可调整参数

这些参数位于 `campus_login.sh` 顶部：

| 参数 | 说明 |
| --- | --- |
| `CHECK_204_URLS` | 204 联网探测地址，正常联网时应返回 HTTP 204。 |
| `CHECK_HTTPS_URLS` | 204 探测失败后的 HTTPS 备用探测地址。 |
| `PROBE_URL` | 用于触发未认证重定向的 HTTP 地址。 |
| `LOGIN_URL_PATH` | 第一次登录 POST 的默认路径。 |
| `LOGIN_REDIRECT_URL_PATH` | 第二次确认 POST 的默认路径。 |
| `CONNECT_TIMEOUT` | curl 连接超时时间。 |
| `MAX_TIME` | curl 单次请求总超时时间。 |
| `USER_AGENT` | 模拟浏览器请求时使用的 User-Agent。 |
| `LOCK_FILE` | 防止并发运行的锁文件路径。 |

一般只需要修改 `USERNAME` 和 `PASSWORD`。除非你的门户路径、探测地址或请求超时时间不同，否则不建议改动其它参数。

## 故障排查

### 日志显示已经联网，但实际不能上网

检查 204 探测地址是否在你的网络中被特殊处理，也可以临时调整 `CHECK_204_URLS` 或 `CHECK_HTTPS_URLS`。

### 无法获取 `Location`

确认未认证状态下访问 `PROBE_URL` 是否会被校园网劫持到登录页。如果该地址没有触发重定向，可以换成其它 HTTP 明文探测地址。

### 无法提取 `userip` 或 `basip`

说明你的门户重定向 URL 参数名可能不同。请用浏览器开发者工具查看真实跳转地址，并按实际参数名修改脚本。

### 无法提取 `portalLogin`

说明登录页 HTML 结构或隐藏字段名与脚本预期不一致。请确认登录页里是否存在：

```html
<input name="portalLogin" ...>
```

脚本已经兼容 `value="xxx"` 和 `value = "xxx"`。如果字段名变化，需要同步修改 `extract_input_value "portalLogin"` 的调用。

### 无法从框架页提取 `portal.wlan`

脚本会优先查找 `name="input"` 的 frame，再兜底查找包含 `portal.wlan` 的 frame。如果你的门户使用 `iframe`、其它 frame 名称，或直接返回登录页，需要按实际 HTML 修改 `extract_frame_src` 或登录页兜底路径。

### 第一次 POST 成功但仍未联网

新版门户通常还需要浏览器自动提交第二个表单。请检查日志中是否有第二次确认请求，以及第一次响应中是否能提取 `submitForm` 的 `action`。

### 第二次确认请求失败

确认第一次响应里是否包含 `validperiod`、`logonsessid`、`encryUser`、`cookies` 等隐藏字段。如果字段缺失，可能是密码错误、账号状态异常、门户版本不同，或学校认证系统返回了错误页面。

### 脚本重复运行

脚本会使用 `/var/run/campus_login.lock` 作为锁文件。如果路由器异常断电后残留锁文件，脚本会检查 PID 是否还存在，并自动移除无效锁。

## 本地检查

如果在电脑上修改脚本，可以先做语法检查：

```bash
sh -n campus_login.sh
```

检查 README 和脚本是否存在明显空白错误：

```bash
git diff --check
```

## 注意事项

* 脚本中的账号密码是明文，请不要提交真实账号密码。
* 不同学校的 CMCC 门户可能字段不同，脚本不能保证通用。
* 抓包或记录响应时不要公开包含账号、会话、Cookie、加密用户名等敏感字段的内容。
* 如果认证系统再次升级，应优先以浏览器开发者工具中的真实请求顺序为准。

## 免责声明

本项目仅用于在个人可管理的网络环境中自动化校园网登录。请遵守学校、运营商和网络管理方的相关规定。作者不对使用本脚本造成的账号、网络、设备或合规问题负责。
