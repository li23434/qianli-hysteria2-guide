# qianli Hysteria 2 一键部署脚本

作者与维护：**qianli**  
脚本入口：[install.sh](install.sh)

这是 qianli 独立编写的 Bash 安装与管理脚本，不是原教程的改名版，也不是调用其他安装器的包装脚本。它自行准备依赖、下载并校验官方 Hysteria 二进制、生成配置和独立 systemd 服务，再提供更新、状态、日志、客户端配置与卸载入口。

Hysteria 协议与程序仍来自 [官方项目 HyNetworks/hysteria](https://github.com/HyNetworks/hysteria)。本仓库不把官方软件称为 qianli 自研，也不附带其他项目的安装脚本副本。

## 一行打开安装菜单

在自己 VPS 的 **root SSH 会话**中运行：

```bash
curl -fsSL https://raw.githubusercontent.com/li23434/qianli-hysteria2-guide/main/install.sh -o qianli-hy2-install.sh && bash qianli-hy2-install.sh
```

这条命令先把脚本保存为文件，再打开菜单。选择 `1` 安装，按提示填写证书方式、域名或 IPv4 地址、联系邮箱和 UDP 端口，最后确认。端口默认是 **443/UDP**，不是随机端口。

无 root 登录时，先下载同一个文件，再使用：

```bash
sudo bash qianli-hy2-install.sh
```

使用文件式入口，不要改成 `curl ... | bash`：菜单需要交互终端，安装时也会把当前脚本保存为本地管理命令。希望先看清楚内容，可以在运行前执行 `less qianli-hy2-install.sh`。

## 运行条件

- Debian 或 Ubuntu，且当前由 systemd 管理服务
- 64 位 `amd64` 或 `arm64` 架构
- SSH 登录后能使用 Bash；下载入口需要 curl
- VPS 能访问 GitHub API 和官方 Release 下载地址
- 操作前确认已有网站、代理服务与端口占用

脚本会按缺项准备 `ca-certificates`、`curl`、`openssl`、`python3`、`iproute2`、`util-linux`、`passwd` 等系统工具。实际安装与管理需要 root 权限；`--help`、`--version` 和 `--dry-run` 不需要 root 或 Linux。

脚本**不修改 DNS、SSH、Caddy、全局防火墙或已有的官方 Hysteria 配置，不清空 iptables 规则**。因此端口放行、域名指向和公网可达性仍由你确认；它不会为了安装而停止现有网站。

## 两种证书方式

### 默认：域名与 ACME 可信证书

示例域名和邮箱都需要替换：

```bash
sudo bash qianli-hy2-install.sh install --cert-mode acme --domain hy2.example.com --email admin@example.com --port 443
```

当前脚本使用 **ACME HTTP 验证**。域名应指向 VPS，公网 **80/TCP** 必须可达且没有其他程序监听；传输所用的 **443/UDP** 则是另一条需要放行的规则。80/TCP 已被网站占用时，脚本会中止，不会停止网站。

该模式生成正常校验证书的客户端配置。不要把示例域名理解为已经替你创建了 DNS 记录。

### 可选：自签证书与固定指纹

没有可用域名，或者想自行选择自签方式时：

```bash
sudo bash qianli-hy2-install.sh install --cert-mode self-signed --host 203.0.113.10 --port 443
```

`203.0.113.10` 是示例地址，必须换成自己的 VPS 地址。当前接受 DNS 名称或 IPv4，**不接受直接填写 IPv6 地址**。

脚本生成带对应 SAN 的自签证书。导出的客户端同时包含 `tls.insecure: true`、`tls.sni` 和非空的 **`tls.pinSHA256`**：信任链验证由固定证书指纹替代，不能只保留 `insecure: true` 而删除指纹。证书有效期为 365 天；更换证书后，需要核对并同步新的客户端指纹。[官方客户端 TLS 说明](https://v2.hysteria.network/docs/getting-started/Client/#tls)

## 安装完成后怎样管理

安装成功后，使用保存到系统里的 `qianli-hy2`，不必每次重新下载脚本：

| 操作 | 命令 |
| --- | --- |
| 打开菜单 | `sudo qianli-hy2` |
| 查看服务状态 | `sudo qianli-hy2 status` |
| 查看最近日志 | `sudo qianli-hy2 logs` |
| 启动 / 停止 / 重启 | `sudo qianli-hy2 start` / `sudo qianli-hy2 stop` / `sudo qianli-hy2 restart` |
| 显示私有客户端 YAML | `sudo qianli-hy2 show-client` |
| 更新到官方最新版本 | `sudo qianli-hy2 update` |
| 更新到指定官方版本 | `sudo qianli-hy2 update --release app/v2.13.0` |
| 卸载程序与服务，保留私有资料 | `sudo qianli-hy2 uninstall` |

这里的 `app/v2.13.0` 是版本参数格式示例，不代表永久推荐版本。**`--release` 选择 Hysteria 程序版本，`--version` 只显示 qianli 安装脚本自身版本。**

`show-client` 当前只输出 YAML，不生成订阅服务或可分享的节点 URI。输出里有真实认证口令，只复制到自己的客户端，不要发到公开仓库、Issue 或截图里。该文件使用官方 Hysteria 客户端配置格式，并非所有图形客户端通用的导入格式。

生成的本地入口为 `127.0.0.1:12808`（SOCKS5）和 `127.0.0.1:12809`（HTTP）。服务保持运行不等于客户端已经连通，仍需从客户端做一次实际请求验证。

### 在自己的电脑启动客户端

在 VPS 上执行 `sudo qianli-hy2 show-client`，把输出私有保存为自己电脑上的 `client.yaml`，不要把服务端 `config.yaml` 当作客户端配置。

从 [Hysteria 官方 Release](https://github.com/HyNetworks/hysteria/releases) 准备与自己电脑系统和架构对应的 Hysteria 2 客户端。下面 Linux/macOS 示例假设程序已命名为 `hysteria` 并在 PATH 中；Windows 示例假设将下载的程序命名为 `hysteria.exe`，与 `client.yaml` 放在同一个目录。

Linux / macOS：

```bash
hysteria client --config ./client.yaml
```

Windows PowerShell：

```powershell
.\hysteria.exe client --config .\client.yaml
```

保持客户端运行，另开同一台电脑的终端测试：

```bash
curl --proxy http://127.0.0.1:12809 --noproxy localhost,127.0.0.1 --connect-timeout 10 --max-time 20 --fail --show-error https://example.com/
```

Windows PowerShell 把上述 `curl` 改为 `curl.exe`。这里连接的是自己电脑上已启动的客户端，不是在 VPS 上直接访问不存在的本地代理。请求成功才说明这一条代理链路完成了应用层验证；不是速度测试或公网 UDP 可达性的独立证明。

## 指定参数与只看执行计划

完整查看命令帮助：

```bash
bash qianli-hy2-install.sh --help
bash qianli-hy2-install.sh --version
```

不下载、不准备依赖、不创建系统目录、不生成口令，也不启动服务，只打印计划：

```bash
bash qianli-hy2-install.sh install --domain hy2.example.com --email admin@example.com --port 443 --dry-run
```

`--dry-run` 不是远端连通性测试，也不能证明 DNS、证书验证或真实 VPS 安装将会成功。

需要无交互安装时，完整提供参数并显式加上 `--yes`：

```bash
sudo bash qianli-hy2-install.sh install --cert-mode acme --domain hy2.example.com --email admin@example.com --port 443 --yes
```

参数可以放在命令前后；一次只执行一个管理命令。

## 脚本创建了哪些文件

| 用途 | 专属位置 |
| --- | --- |
| 官方 Hysteria 可执行文件 | `/usr/local/lib/qianli-hysteria/hysteria` |
| 本地管理入口 | `/usr/local/sbin/qianli-hy2` |
| 服务端配置 | `/etc/qianli-hysteria/config.yaml` |
| 私有客户端配置 | `/etc/qianli-hysteria/client.yaml` |
| 安装版本与摘要记录 | `/etc/qianli-hysteria/install.json` |
| 自签证书 / 私钥（仅该模式） | `/etc/qianli-hysteria/server.crt` / `server.key` |
| 运行状态与 ACME 缓存 | `/var/lib/qianli-hysteria/` |
| 独立 systemd 服务 | `qianli-hysteria-server.service` |
| 服务单元文件 | `/etc/systemd/system/qianli-hysteria-server.service` |

服务使用专用的非登录系统用户 `qianli-hysteria`，不以 root 身份长期运行。客户端配置仅 root 可读；服务端配置与自签私钥只向必要的服务用户开放读取权限，不采用 `777`。

已有安装或专属路径冲突时，脚本会拒绝覆盖。不要把旧教程的 `/etc/hysteria/` 配置直接复制过来覆盖本项目文件。

默认卸载后保留的配置不会被新的安装直接覆盖。当前不提供自动恢复重装；需要重装时，先私有备份，再明确清理并安装。

## 二进制来源、更新与回滚

脚本通过官方 GitHub 仓库 ID `257434373` 获取 Release 元数据，选择对应架构的 `hysteria-linux-amd64` 或 `hysteria-linux-arm64` 资产，再校验官方元数据提供的 SHA256、ELF 架构和程序版本。缺少有效摘要或校验不匹配时中止，不跳过检查，也不执行任何外部安装器。

更新保留配置和证书，只替换官方二进制。写入新程序或更新前正在运行的服务启动检查失败时，脚本尝试恢复旧程序；恢复本身失败也会报错，需要查看日志。更新前未运行的服务，更新后不会擅自启动。成功更新时旧程序保存在同一目录的 `hysteria.previous`。

服务检查应等待当前 systemd 启动实例的 Hysteria 就绪日志，不只判断 `active`。ACME 申请可能需要等待，最长等待 300 秒；即使服务已就绪，仍要按上面的客户端步骤验证真实连接。

这些是当前代码的处理逻辑，不是对所有网络、系统与故障场景的零中断承诺。更新前仍应把有效私有配置保存在自己控制的备份位置，不要上传真实口令或私钥。

## 卸载与完整清理

默认卸载只移除程序、管理命令与服务，保留配置、证书、状态目录以及专用非登录用户：

```bash
sudo qianli-hy2 uninstall
```

确认不再需要这些私有资料时，才执行：

```bash
sudo qianli-hy2 uninstall --purge
```

`--purge` 仅允许用于卸载，删除范围限定为本项目固定的专属目录。若已经做过默认卸载，本地管理命令也已被移除；可以重新下载本脚本，再运行 `sudo bash qianli-hy2-install.sh uninstall --purge`。不要把 `--yes` 随手加到清理命令中。

## 验证范围

在 Linux 开发环境中运行：

```bash
bash -n install.sh
shellcheck --severity=warning install.sh tests/smoke.sh
bash tests/smoke.sh
```

隔离测试只调用参数校验、发布元数据选择、临时目录中的配置生成和 dry-run，不执行服务器安装。自动检查及每次运行的实际结果见 [GitHub Actions](https://github.com/li23434/qianli-hysteria2-guide/actions/workflows/verify.yml)。Linux 集成验收应覆盖真实 systemd 安装、客户端本地代理握手、更新与卸载；只有对应工作流成功的项目才算通过，不能从隔离测试推断集成成功。

开发检查与真实服务器验收是两回事。语法、帮助/参数解析、`--dry-run`、隔离样例中的配置生成、版本元数据校验或故障分支测试，只能验证这些对应代码路径，不能替代真实 systemd、ACME、UDP 网络与客户端端到端连接。

**当前尚未在用户真实 VPS 上执行安装，没有真实节点、速度测试或生产可用性实测结论。** 安装后应核对 DNS、80/TCP 验证条件、实际 UDP 入站、服务日志和客户端请求结果。`configs/` 中保留的是脱敏参考文件；实际使用以脚本生成的私有配置为准。

## 归属与参考

- 安装编排与项目维护：**qianli**
- Hysteria 程序与协议：[官方项目](https://github.com/HyNetworks/hysteria)
- 配置字段：[官方服务端文档](https://v2.hysteria.network/docs/advanced/Full-Server-Config/)、[官方客户端文档](https://v2.hysteria.network/docs/advanced/Full-Client-Config/)

本项目不调用官方 `get.hy2.sh`，也不调用或镜像第三方一键安装器。官方软件、文档与其他被引用项目仍分别属于各自原作者。
