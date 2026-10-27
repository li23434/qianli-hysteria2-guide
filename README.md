# qianli 的 Hysteria 2 部署工作单

作者：**qianli**  
资料核对：2026-10-27

装好一个程序，只完成了部署的一小部分。这份工作单的终点是：能解释服务器用了什么配置，拿出一条确实经过本地代理的请求，并知道下次故障从哪里查。

主线采用**官方安装器、可信证书、单 UDP 端口**。先按工作单填自己的参数，再完成四项验收。不比较速度，不堆叠调优，也不照搬某个平台的客户端界面。文末另留第三方一键入口，供需要交互菜单的人自行选择。

本文由 qianli 独立整理，示例没有在用户 VPS 上执行。仓库只存教程和脱敏配置，不包含第三方安装脚本副本。

## 开始前，填完这张单

请在自己的私有记录中填写“我的值”，不要将真实口令、私钥或完整节点链接提交到这个仓库。

| 项目 | 本文示例 | 我的值 |
| --- | --- | --- |
| VPS 系统 / 架构 | systemd Linux / 按实际架构选程序 | 待填 |
| 公网 IPv4 / IPv6 | 不提供真实地址 | 待填 |
| 代理子域名 | `hy2.example.com` | 待填 |
| Hysteria 入站 | `443/UDP` | 待填 |
| 证书获取 / 续期 | Hysteria 内置 ACME | 待填 |
| ACME 联系邮箱 | `admin@example.com` | 待填 |
| 认证口令 | `REPLACE_WITH_YOUR_OWN_LONG_RANDOM_PASSWORD` | 私密保存 |
| 本地 SOCKS5 入口 | `127.0.0.1:12808` | 待填 |
| 本地 HTTP 入口 | `127.0.0.1:12809` | 待填 |
| 已有网站 / 转发规则 | 先盘点，不能假定为空 | 待填 |
| 恢复入口 | 云控制台或其他管理通道 | 待填 |

`hy2.example.com` 只表示一个待替换的域名。注册了博客域名，并不意味着它的代理子域名已经解析到 VPS。只有确实可用的 IPv6 才填写对应的 AAAA 记录。

这张单里有三种端口，别混在一起：VPS 上用于传输的 UDP 端口、证书验证可能用到的 TCP 端口，以及只在客户端本机监听的 HTTP/SOCKS5 端口。后两者不是替代关系。

## 把主线配置落到自己的机器

### 先确认运行条件

在 VPS 的 SSH 终端检查环境和已有监听：

```bash
cat /etc/os-release
uname -m
systemctl --version
ss -lntup
```

对照 [官方安装器要求](https://v2.hysteria.network/docs/getting-started/Server-Installation-Script/#environment-requirements)，确认 systemd、Bash、curl 等工具可用。安全组和主机防火墙应允许工作单填写的 UDP 入站端口；是否放行过 TCP 443 不能代替这一步。

### 程序与配置分开处理

官方下载入口先取到本地检查，再运行：

```bash
curl -fsSL https://get.hy2.sh/ -o install-hysteria.sh
less install-hysteria.sh
sudo bash install-hysteria.sh
```

安装器负责程序和 systemd 服务，不会替你完成一份适合当前环境的服务端配置。

把 [服务端示例](configs/server.example.yaml) 的内容保存到 VPS 的 `/etc/hysteria/config.yaml`，填写工作单中的域名、邮箱和独立长随机口令。这个示例明确监听 `:443`，使用内置 ACME；若改端口，两端与防火墙规则必须一起改。

证书获取依赖域名指向和所选验证方式。如果网站已经占用了相关 TCP 端口，先核对 [官方 TLS / ACME 配置](https://v2.hysteria.network/docs/advanced/Full-Server-Config/#tls)，决定合适的验证方式，不要为了套示例直接停掉网站。已有证书由别的程序续期时，可以用 `tls.cert`、`tls.key` 替代 `acme`，但两段不能并存。证书路径与服务用户的读取权限也要对应。

接着在**客户端所在的设备**保存 [客户端示例](configs/client.example.yaml)，命名为 `client.yaml`，把地址和口令改成相同的一组值。它是官方 Hysteria 客户端格式，不是所有图形客户端的通用导入文件。本例保留正常的可信证书校验，没有 `insecure: true`。

启动命令中的程序文件名要与实际下载的架构版本对应，例如：

```bash
./hysteria-linux-amd64 client -c client.yaml
```

本地监听地址保持 `127.0.0.1`。启动客户端不会自动改变整台设备的代理设置；下面只让 curl 的测试请求显式使用这两个本地入口。

## 四项验收：每一项都留一条证据

### 验收一：入口确实指向这台服务器

**要留下的证据**：域名当前的 A/AAAA 结果、工作单中的公网地址、实际放行的 UDP 端口三者能够对应。

可以使用 DNS 管理控制台或自己的查询工具核对。普通网站 CDN 的 HTTP 代理不等于该 UDP 入口；不要把“浏览器能打开域名”当作这一项已经通过。

**不通过就停在这里**：先修正错误记录、失效的 AAAA 或端口规则，不重装程序。

### 验收二：服务读到了这份配置

在 VPS 上启动并查看状态与日志：

```bash
sudo systemctl start hysteria-server.service
sudo systemctl status hysteria-server.service
sudo journalctl --no-pager -e -u hysteria-server.service
```

**要留下的证据**：服务持续运行，日志中没有配置解析、证书申请、文件权限或端口绑定错误。仅有安装器的“完成”提示不算证据。

**不通过就停在这里**：先处理日志出现的第一条有效错误。修改后重启，再看同一组日志，不同时改多项配置。

### 验收三：客户端的地址、认证与证书吻合

保持客户端运行，核对它使用的是工作单中的域名和 UDP 端口，且认证口令与服务端一致。

**要留下的证据**：客户端出现成功连接的日志，没有证书或认证错误，本地配置的 HTTP/SOCKS5 入口可用。日志本身可能包含完整节点链接，公开分享时只保留错误类型和必要上下文。

**不通过就停在这里**：超时优先查 UDP 路径；认证失败核对两端口令；证书错误核对域名、证书信任链和有效期。不要通过关闭校验把错误掩盖掉。

### 验收四：一个 HTTPS 请求确实经过本地入口

以下命令在**运行客户端的同一台电脑**执行，不是在 VPS 的 SSH 终端执行。Windows PowerShell 请把命令开头的 `curl` 写成 `curl.exe`，避免被 `Invoke-WebRequest` 别名接管；Linux / macOS 使用 `curl`。先保留客户端终端，再开一个终端测试。HTTP 和 SOCKS5 两条按本次使用的入口任选一条，独立执行，不合并参数。

通过本地 HTTP 代理发起请求：

```bash
curl --proxy http://127.0.0.1:12809 --noproxy localhost,127.0.0.1 --connect-timeout 10 --max-time 20 --fail --silent --show-error --write-out "\nHTTP=%{http_code}\n" https://example.com/
```

如果本次使用本地 SOCKS5 入口，选择下面这条做同一项检查：

```bash
curl --proxy socks5h://127.0.0.1:12808 --noproxy localhost,127.0.0.1 --connect-timeout 10 --max-time 20 --fail --silent --show-error --write-out "\nHTTP=%{http_code}\n" https://example.com/
```

`socks5h` 让目标域名经 SOCKS5 代理解析；`--noproxy` 在这两条命令中只排除回环目标，避免环境变量里的其他豁免规则让 `example.com` 绕开指定代理。命令保留 HTTPS 证书校验，不使用 `-k`。相关选项含义见 [curl 官方手册](https://curl.se/docs/manpage.html)。

**要留下的证据**：收到目标网页内容，结尾有正常的目标 HTTP 状态，并且没有 curl 错误。`HTTP=000`、连接本地端口失败或超时都不算通过。若收到 4xx/5xx，应区分目标网站响应与链路失败，不能一律归因于 VPS。

这项验收验证的是“指定本地代理承载了一次 HTTPS 请求”，不是直接探测服务器 UDP 端口。它也不代表系统里所有应用都已走代理，更不构成速度、稳定性或隐私效果的测评。

## 排错时，用证据卡而不是猜测

每次只填一张卡，修正后重新跑对应的验收，不从头重装：

```text
未通过的验收编号：
发生时间：
实际执行的命令（去掉秘密）：
首个错误类型 / 关键日志：
本次只改动了什么：
复测结果：
```

| 手里的证据 | 下一步只查这一层 |
| --- | --- |
| DNS 结果与工作单不符 | 权威 DNS 记录、记录名称、失效的 AAAA |
| 服务启动立即退出 | 日志首错、YAML 缩进、路径、权限或监听冲突 |
| 客户端认证失败 | 当前实际加载的配置与两端口令 |
| 客户端证书错误 | 连接域名、证书域名、信任链、到期时间 |
| curl 连不上 `127.0.0.1` | 客户端是否运行、本地监听端口是否与命令一致 |
| 本地端口存在但请求超时 | 客户端连接日志、UDP 入站、服务器出口与目标可达性 |
| 只有某个应用不能访问 | 该应用有没有明确使用已验收的本地代理入口 |

分享证据卡前，移除口令、私钥、完整订阅/节点链接与不必要的个人网络信息。保留错误类型、时间和脱敏后的字段关系就够了。

## 维护：留下能恢复的东西，而不是一堆截图

四项验收通过后，再设置服务器开机启动：

```bash
sudo systemctl enable hysteria-server.service
```

更改配置后，使用 `sudo systemctl restart hysteria-server.service`，重新查看状态与日志，并至少复测一次本地代理请求。

把记录分成两份：

- **私有备份**：当前有效配置、口令、证书续期安排、必要的恢复资料，存入自己控制的私密位置
- **可提交仓库的资料**：本文工作单的空表、示例域名、占位口令、脱敏证据卡和变更说明

不要把 `/etc/hysteria/` 或客户端配置目录整个打包推到 GitHub；其中可能含真实口令和私钥。升级前记录版本与有效配置，阅读对应版本变更，升级后重新验收。这里不提供会把私密文件自动上传的备份命令。

## 可选：第三方交互菜单入口

如果确定要用菜单式安装，可以选择 [flame1ce/hysteria2-install](https://github.com/flame1ce/hysteria2-install)。它与上面的官方主线是**替代关系**，不要在同一套已运行配置上叠加执行。

以 Debian / Ubuntu 的 `root` 会话为例，先准备 `ca-certificates`、`wget` 等工具，再取回脚本阅读：

```bash
wget -O hysteria.sh https://raw.githubusercontent.com/flame1ce/hysteria2-install/main/hysteria2-install-main/hy2/hysteria.sh
less hysteria.sh
bash hysteria.sh
```

已经检查过当前源码，需要一行入口时：

```bash
wget -O hysteria.sh https://raw.githubusercontent.com/flame1ce/hysteria2-install/main/hysteria2-install-main/hy2/hysteria.sh && bash hysteria.sh
```

主菜单 `1` 为安装；端口留空会随机取 `2000–65535`，证书菜单默认自签。当前源码在端口设置和卸载时会清空 IPv4 NAT `PREROUTING`；自签分支对证书与私钥使用 `777` 权限；导出的客户端包含 `insecure: true`；修改伪装站涉及 `/etc/caddy/Caddyfile`。这些行为必须与自己的已有服务、转发规则和证书方案一起判断。

采用它的导出参数后，不要混用本仓库的可信证书配置。自签连接的信任方式应另按 [官方客户端 TLS 文档](https://v2.hysteria.network/docs/getting-started/Client/#tls) 处理。节点在自己客户端里的显示名称可以写成 `qianli`，不代表上游脚本变成了 qianli 自研程序。

这个入口直接指向原项目，没有镜像或重新署名它的安装脚本；`main` 上的内容可能变化，运行前需重新检查。

## 资料与归属

- [Hysteria 官方安装器与服务管理](https://v2.hysteria.network/docs/getting-started/Server-Installation-Script/)
- [Hysteria 官方服务端入门](https://v2.hysteria.network/docs/getting-started/Server/)
- [完整服务端配置](https://v2.hysteria.network/docs/advanced/Full-Server-Config/)
- [Hysteria 官方客户端入门](https://v2.hysteria.network/docs/getting-started/Client/)
- [curl 官方选项手册](https://curl.se/docs/manpage.html)
- [第三方脚本项目 · flame1ce/hysteria2-install](https://github.com/flame1ce/hysteria2-install)
- [参考教程](https://haiy.space/posts/hysteria-2-vps)：选题和历史脚本入口参考，未复制其图片与正文

教程撰写与整理：**qianli**。协议、软件及第三方安装器分别属于原项目。本文采用独立的工作单、验收和维护结构，不是原参考文章的改名版本。
