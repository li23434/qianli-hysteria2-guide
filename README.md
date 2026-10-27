# qianli 的 Hysteria 2 VPS 部署笔记

作者：**qianli**  
资料核对：2026-10-27

这份教程把安装、配置和验证分开写清楚。提供两条路线：参考教程所用的第三方交互脚本，以及官方安装器配合手动配置。**选一条路线完成即可，不要在同一台服务器上接着叠加另一套安装。**

本文是 qianli 重新撰写的操作说明，不是安装脚本项目。本仓库不镜像第三方安装器，也未在用户 VPS 上执行安装或进行速度实测。文中的 `hy2.example.com`、邮箱和口令均为占位值；博客域名已经注册，不等于代理子域名已经配置完成。

## 先准备这些

- 一台自己能够通过 SSH 管理的 Linux VPS，记下系统、CPU 架构和公网地址
- 能访问服务器控制台或其他恢复入口
- 已有网站、监听端口、转发规则的清单，以及相关配置备份
- 一份独立保存的长随机口令，不要把真实口令放进 GitHub
- 若采用下面的可信证书示例，准备指向 VPS 的子域名，例如 `hy2.example.com`

先在服务器上确认当前环境：

```bash
cat /etc/os-release
uname -m
systemctl --version
ss -lntup
```

DNS 的 A/AAAA 记录应指向对应公网地址。只有真实可用的 IPv6 才配置 AAAA。普通网站 CDN 的 HTTP 代理开关不能替代 Hysteria 的 UDP 直连入口。

安全组和系统防火墙需要允许**实际选择的 UDP 端口**。TCP 443、UDP 443 是两个不同的规则；证书验证所需的 TCP 端口也要另外核对。

## 路线 A：参考教程中的第三方交互脚本

脚本项目是 [flame1ce/hysteria2-install](https://github.com/flame1ce/hysteria2-install)，不是 Hysteria 官方安装器，也不是 qianli 编写的程序。

### 1. 获取并运行

以下以 Debian / Ubuntu 的 `root` SSH 会话为例，先准备下载工具：

```bash
apt-get update && apt-get install -y ca-certificates wget
```

先下载、阅读，再决定运行：

```bash
wget -O hysteria.sh https://raw.githubusercontent.com/flame1ce/hysteria2-install/main/hysteria2-install-main/hy2/hysteria.sh
less hysteria.sh
bash hysteria.sh
```

确认要直接使用时，对应的一行入口是：

```bash
wget -O hysteria.sh https://raw.githubusercontent.com/flame1ce/hysteria2-install/main/hysteria2-install-main/hy2/hysteria.sh && bash hysteria.sh
```

上面保留 `wget` 默认的 HTTPS 证书校验。下载地址的 `main` 会随上游更新，运行前应重新核对源码，而不是把本文日期当作脚本的固定版本。

### 2. 按实际菜单填写

主菜单选择 `1` 安装。记录自己选择的证书方式、UDP 端口、认证口令和输出配置。端口输入留空时，上游会从 `2000–65535` 随机选择，并非固定使用 443。证书菜单留空采用自签证书，不能与下文可信证书配置混用。

安装后按脚本输出保存客户端文件或节点链接；当前源码使用 `/root/hy/` 保存导出文件。节点的客户端显示名称可以自行改为 `qianli`，这不会改变服务器、认证口令或上游脚本归属。

### 3. 知道脚本会改什么

核对日期所见的 [上游源码](https://raw.githubusercontent.com/flame1ce/hysteria2-install/main/hysteria2-install-main/hy2/hysteria.sh) 有这些行为：

| 部分 | 实际行为 |
| --- | --- |
| 端口设置、卸载 | 清空 IPv4 NAT 的 `PREROUTING` 链，可能移除其他服务的转发规则 |
| 默认自签分支 | 生成自签证书；源码对证书和私钥使用 `777` 文件权限 |
| 客户端导出 | 默认包含 `insecure: true`，不会正常校验证书信任链 |
| 修改伪装网站 | 涉及 `/etc/caddy/Caddyfile`，不能假定与现有网站配置互不影响 |

已有网站或转发规则的 VPS，不适合把这套脚本当作无副作用的通用安装器。若要自己维护证书、权限和服务，下面的官方路线更直观。

## 路线 B：官方安装器加最小配置

**这是路线 A 的替代方案。** 官方安装器负责程序和 systemd 服务，配置仍需自己完成。[官方安装器文档](https://v2.hysteria.network/docs/getting-started/Server-Installation-Script/) 列出了系统与工具要求；以下假定 VPS 使用 systemd，并具备 Bash、curl 等常规工具。

### 1. 安装程序

```bash
curl -fsSL https://get.hy2.sh/ -o install-hysteria.sh
less install-hysteria.sh
sudo bash install-hysteria.sh
```

安装器生成示例不代表服务已配置成功。后续编辑 `/etc/hysteria/config.yaml`，不要再运行路线 A 的管理脚本覆盖它。

### 2. 配置服务端

本仓库的 [服务端示例](configs/server.example.yaml) 使用域名和 ACME 获取可信证书。替换域名、联系邮箱和口令后再部署：

```yaml
listen: :443

acme:
  domains:
    - hy2.example.com
  email: admin@example.com
  ca: letsencrypt

auth:
  type: password
  password: REPLACE_WITH_YOUR_OWN_LONG_RANDOM_PASSWORD
```

`listen` 是实际传输的 UDP 端口。ACME 的验证方式还有独立要求，须按自己的网络、端口占用与 [完整服务端配置](https://v2.hysteria.network/docs/advanced/Full-Server-Config/#tls) 核对。若 80/443 TCP 已被网站占用，应先设计证书方案，而不是直接停掉网站。

已经由其他程序管理证书时，使用 `tls.cert` 和 `tls.key` 的文件路径代替整段 `acme`；两种方式不能同时保留。私钥权限应只允许必要的用户读取，并确认 Hysteria 服务用户具有访问权限。不要通过把私钥改成 `777` 来解决权限问题。

本例没有配置 `masquerade`，也不会自动创建一个可在浏览器中访问的博客页面。站点托管与 Hysteria 服务是两个独立服务。

### 3. 启动、观察、再设置开机启动

```bash
sudo systemctl start hysteria-server.service
sudo systemctl status hysteria-server.service
sudo journalctl --no-pager -e -u hysteria-server.service
```

确认进程持续运行、没有配置或证书错误，再设置开机启动：

```bash
sudo systemctl enable hysteria-server.service
```

修改配置后重启，并重新查看日志：

```bash
sudo systemctl restart hysteria-server.service
```

## 配置自己的客户端

如果选的是路线 A，先使用那套脚本实际导出的地址、端口、认证与证书参数；不要套入本节的可信证书示例。自签证书可显式信任对应 CA，或按官方说明结合证书指纹校验，而不是长期只保留 `insecure: true`。[客户端 TLS 说明](https://v2.hysteria.network/docs/getting-started/Client/#tls)

路线 B 可以从 [客户端示例](configs/client.example.yaml) 开始。将它另存为客户端目录中的 `client.yaml`，再替换地址与口令：

```yaml
server: hy2.example.com:443
auth: REPLACE_WITH_YOUR_OWN_LONG_RANDOM_PASSWORD

socks5:
  listen: 127.0.0.1:12808

http:
  listen: 127.0.0.1:12809
```

这里是官方 Hysteria 客户端的配置格式，不是任意图形客户端的通用导入文件。把客户端程序放到合适目录，使用它的实际文件名启动，例如：

```bash
./hysteria-linux-amd64 client -c client.yaml
```

服务端与客户端口令必须一致；域名要与证书对应。SOCKS5、HTTP 端口只监听本机回环地址，不会自动修改系统或浏览器的代理设置。暂不填写带宽和复杂分流参数，先验证基础连接。

## 怎样判断确实通了

按这条顺序检查：

1. 域名解析到了计划使用的 VPS 地址
2. 服务运行，日志没有配置、权限或证书错误
3. 安全组与防火墙允许实际 UDP 入站端口
4. 客户端能与服务器完成连接，认证与证书匹配
5. 让一个测试应用明确使用本地 SOCKS5 或 HTTP 端口，验证该应用的请求

只看到服务为 `active`，不能证明客户端已经连接；能打开一个网页或测通 TCP，也不能证明目标 UDP 端口可用。

| 现象 | 先查这里 |
| --- | --- |
| 服务启动后退出 | 日志首个错误、YAML 缩进、文件路径与权限 |
| 证书获取失败 | 域名指向、验证方式、所需 TCP 端口或 DNS 验证配置 |
| 客户端超时 | 实际服务器地址、UDP 端口、安全组、防火墙 |
| 认证失败 | 两端口令是否一致，是否误用了另一套配置 |
| 已连接但测试应用无网络 | 应用是否使用了正确的本地代理端口 |
| 连接不稳定 | 两端网络质量、链路丢包及实际可用带宽，不先堆叠调参 |

## 给下次维护留一页记录

记录安装来源、程序版本、配置路径、证书续期方式、端口和验证日期。保存脱敏模板，真实口令、私钥和完整节点链接另存，不提交到教程仓库。升级前备份有效配置，阅读对应版本说明；升级后重新检查日志与客户端连接。

## 参考资料与归属

- [参考教程 · Hysteria 2 VPS](https://haiy.space/posts/hysteria-2-vps)：选题与第三方脚本入口参考
- [flame1ce/hysteria2-install](https://github.com/flame1ce/hysteria2-install)：第三方安装器归属；本文只链接其源码
- [Hysteria 官方安装方式](https://v2.hysteria.network/docs/getting-started/Installation/)
- [Hysteria 官方安装器与服务管理](https://v2.hysteria.network/docs/getting-started/Server-Installation-Script/)
- [Hysteria 官方服务端入门](https://v2.hysteria.network/docs/getting-started/Server/)
- [Hysteria 官方客户端入门](https://v2.hysteria.network/docs/getting-started/Client/)
- [完整服务端配置](https://v2.hysteria.network/docs/advanced/Full-Server-Config/)
- [完整客户端配置](https://v2.hysteria.network/docs/advanced/Full-Client-Config/)

教程作者与整理：**qianli**。Hysteria 软件、第三方安装器及参考资料分别属于原项目；仓库中不包含第三方安装脚本的副本。
