#!/usr/bin/env bash
# qianli Hysteria 2 installer. Original installation/orchestration logic.
# Hysteria binaries are downloaded from the official project, not bundled here.
set -Eeuo pipefail
umask 077

readonly QIANLI_VERSION='1.0.1'
readonly REPOSITORY_ID='257434373'
readonly API_ROOT="https://api.github.com/repositories/${REPOSITORY_ID}"
readonly UNIT='qianli-hysteria-server.service'
readonly SERVICE_USER='qianli-hysteria'
readonly CONFIG_DIR='/etc/qianli-hysteria'
readonly STATE_DIR='/var/lib/qianli-hysteria'
readonly BIN_DIR='/usr/local/lib/qianli-hysteria'
readonly BINARY='/usr/local/lib/qianli-hysteria/hysteria'
readonly MANAGER='/usr/local/sbin/qianli-hy2'
readonly UNIT_FILE='/etc/systemd/system/qianli-hysteria-server.service'
readonly LOCK_FILE='/run/qianli-hysteria-installer.lock'
readonly MARKER='/etc/qianli-hysteria/.managed-by-qianli'

COMMAND='menu'
CERT_MODE='acme'
HOST=''
EMAIL=''
PORT='443'
RELEASE='latest'
ASSUME_YES=0
DRY_RUN=0
PURGE=0
HOST_SET=0
PORT_SET=0
MODE_SET=0
WORK_DIR=''
NEW_INSTALL_TRANSACTION=0
UPDATE_TRANSACTION=0
UPDATE_PREVIOUS_STATE='inactive'
RELEASE_TAG=''
ASSET_URL=''
ASSET_DIGEST=''
ARCH=''

say() { printf '%s\n' "$*"; }
die() { printf 'qianli: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'HELP'
qianli Hysteria 2 管理器

用法：bash install.sh [命令] [选项]
命令：install、update、status、logs、show-client、start、stop、restart、uninstall
无参数在交互终端打开菜单。

安装选项：
  --domain NAME          ACME 域名，也可写 --host NAME
  --host NAME_OR_IPV4    自签模式的连接地址（DNS 名称或 IPv4）
  --email ADDRESS       ACME 联系邮箱
  --port NUMBER         Hysteria UDP 入站端口，默认 443
  --cert-mode MODE      acme（默认）或 self-signed
  --release TAG         官方版本，如 app/v2.13.0；默认 latest
  --yes                 跳过确认，安装参数必须已完整提供
  --purge               仅用于卸载，同时删除本脚本的配置与状态目录
  --dry-run             只打印计划，不下载、不安装依赖、不写入系统
  --help                显示帮助，不需要 root 或 Linux
  --version             显示 qianli 脚本版本

示例：
  sudo bash install.sh install --domain hy2.example.com --email admin@example.com
  sudo bash install.sh install --cert-mode self-signed --host 203.0.113.10
  bash install.sh install --domain hy2.example.com --email admin@example.com --dry-run
  sudo qianli-hy2 update --release app/v2.13.0
  sudo qianli-hy2 show-client
  sudo qianli-hy2 uninstall

目标系统：Debian/Ubuntu，systemd，amd64/arm64。
不会修改 SSH、Caddy、全局防火墙或已有的官方 Hysteria 配置。
卸载默认保留配置和证书；仅 --purge 明确请求才清理本脚本专属目录。
HELP
}

valid_port() {
  [[ ${1:-} =~ ^[0-9]{1,5}$ ]] || return 1
  local number=$((10#$1))
  (( number >= 1 && number <= 65535 ))
}

valid_ipv4() {
  [[ ${1:-} =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local part
  local -a octets
  IFS='.' read -r -a octets <<< "$1"
  for part in "${octets[@]}"; do
    [[ ${#part} -eq 1 || ${part:0:1} != 0 ]] || return 1
    (( 10#$part <= 255 )) || return 1
  done
}

valid_domain() {
  local domain=${1:-} label
  [[ ${#domain} -ge 3 && ${#domain} -le 253 ]] || return 1
  [[ $domain =~ ^[A-Za-z0-9.-]+$ && $domain == *.* ]] || return 1
  [[ $domain != .* && $domain != *. && $domain != *..* ]] || return 1
  [[ ${domain##*.} =~ [A-Za-z] ]] || return 1
  local -a labels
  IFS='.' read -r -a labels <<< "$domain"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
    [[ $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

valid_host() { valid_domain "${1:-}" || valid_ipv4 "${1:-}"; }

valid_email() {
  local email=${1:-}
  [[ ${#email} -le 254 && $email == *@* ]] || return 1
  [[ ${email%@*} =~ ^[A-Za-z0-9._%+-]+$ ]] || return 1
  valid_domain "${email##*@}"
}

normalize_release() {
  local tag=${1:-latest}
  if [[ $tag == latest ]]; then printf '%s\n' latest; return; fi
  [[ $tag == app/* ]] || tag="app/$tag"
  [[ $tag =~ ^app/v2\.[0-9]+\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9.-]*)?$ ]] || return 1
  printf '%s\n' "$tag"
}

valid_pin() { [[ ${1:-} =~ ^([A-Fa-f0-9]{2}:){31}[A-Fa-f0-9]{2}$ ]]; }

require_linux_root() {
  [[ $(uname -s) == Linux ]] || die '实际安装和管理需要 Linux；可先使用 --dry-run。'
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die '请在 root 会话执行，或使用 sudo bash install.sh。'
  [[ -r /etc/os-release ]] || die '找不到 /etc/os-release。'
  # This is the operating system's own root-controlled metadata, not a download.
  local ID=''
  . /etc/os-release
  case "$ID" in debian|ubuntu) ;; *) die '当前版本仅面向 Debian/Ubuntu。' ;; esac
  command -v systemctl >/dev/null || die '需要 systemd/systemctl。'
  [[ -d /run/systemd/system ]] || die 'systemd 不是当前运行的服务管理器。'
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' amd64 ;;
    aarch64|arm64) printf '%s\n' arm64 ;;
    *) return 1 ;;
  esac
}

confirm() {
  (( ASSUME_YES )) && return 0
  [[ -t 0 ]] || die '非交互环境需要 --yes 和完整参数。'
  local answer
  read -r -p "$1 [y/N] " answer
  [[ $answer == y || $answer == Y ]] || die '已取消，未执行该操作。'
}

assert_no_symlink() {
  local path
  for path in "$CONFIG_DIR" "$STATE_DIR" "$BIN_DIR" "$BINARY" "$MANAGER" "$UNIT_FILE" "$LOCK_FILE"; do
    [[ ! -L $path ]] || die "专属路径不应是符号链接：$path"
  done
}

managed_install() {
  [[ -f $MARKER && ! -L $MARKER ]] && [[ $(cat "$MARKER") == qianli-hy2-v1 ]]
}

require_managed() {
  assert_no_symlink
  managed_install || die '没有找到 qianli 管理的安装，未操作其他 Hysteria 服务。'
  if [[ -e $UNIT_FILE ]]; then
    grep -Fxq 'ExecStart=/usr/local/lib/qianli-hysteria/hysteria server --config /etc/qianli-hysteria/config.yaml' "$UNIT_FILE" || die '同名服务单元不符合 qianli 专属模板，未操作。'
  fi
}

install_dependencies() {
  local missing=0 name
  for name in curl python3 openssl sha256sum ss flock useradd getent install; do
    command -v "$name" >/dev/null || missing=1
  done
  [[ -f /etc/ssl/certs/ca-certificates.crt ]] || missing=1
  if (( missing )); then
    say '安装所需系统工具：ca-certificates curl openssl python3 iproute2 util-linux passwd'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl openssl python3 iproute2 util-linux passwd
  fi
  for name in curl python3 openssl sha256sum ss flock useradd getent install; do
    command -v "$name" >/dev/null || die "工具仍不可用：$name"
  done
}

acquire_lock() {
  [[ ! -L $LOCK_FILE ]] || die '锁文件不应是符号链接。'
  exec 9>"$LOCK_FILE"
  flock -n 9 || die '另一个 qianli 管理操作正在运行。'
}

create_work_dir() {
  WORK_DIR=$(mktemp -d /var/tmp/qianli-hy2.XXXXXXXX)
  chmod 0700 "$WORK_DIR"
}

remove_own_directory() {
  case "$1" in "$CONFIG_DIR"|"$STATE_DIR"|"$BIN_DIR") ;; *) die '拒绝清理非 qianli 专属目录。' ;; esac
  [[ ! -L $1 ]] || die '拒绝递归清理符号链接。'
  rm -rf -- "$1"
}

rollback_new_install() {
  systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
  rm -f -- "$UNIT_FILE" "$MANAGER"
  systemctl daemon-reload >/dev/null 2>&1 || true
  remove_own_directory "$BIN_DIR"
  remove_own_directory "$STATE_DIR"
  remove_own_directory "$CONFIG_DIR"
  say '新安装未完成，已移除本次创建的专属文件；没有改动其他服务。' >&2
}

cleanup_exit() {
  local status=$?
  trap - EXIT INT TERM
  set +e
  if (( status != 0 && NEW_INSTALL_TRANSACTION )); then rollback_new_install; fi
  if (( status != 0 && UPDATE_TRANSACTION )); then
    if rollback_binary "$WORK_DIR/previous.bin" "$UPDATE_PREVIOUS_STATE"; then
      install -m 0600 -o root -g root "$WORK_DIR/previous-meta.json" "$CONFIG_DIR/install.json" || true
      say '更新未完成，已恢复原程序与之前的服务运行状态。' >&2
    else
      say '更新未完成，原程序恢复未成功，请保留现有配置并检查服务日志。' >&2
    fi
  fi
  if [[ -n $WORK_DIR && $WORK_DIR == /var/tmp/qianli-hy2.* && ! -L $WORK_DIR ]]; then rm -rf -- "$WORK_DIR"; fi
  exit "$status"
}

download_https() {
  curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 15 --max-time 240 --retry 2 --silent --show-error \
    --user-agent "qianli-hy2/${QIANLI_VERSION}" "$1" --output "$2"
}

# Pure metadata selection helper: reads an API JSON file, writes tag/url/digest.
# The immutable repository ID prevents silently switching to an unrelated repo.
select_release_asset() {
  python3 - "$1" "$2" <<'PY'
import json,re,sys,urllib.parse
with open(sys.argv[1],encoding='utf-8') as f: release=json.load(f)
arch=sys.argv[2]
if arch not in ('amd64','arm64'): raise SystemExit('Unsupported architecture')
tag=release.get('tag_name','')
if not re.fullmatch(r'app/v2\.\d+\.\d+(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?',tag): raise SystemExit('Not a Hysteria v2 release')
if release.get('draft'): raise SystemExit('Draft release rejected')
name='hysteria-linux-'+arch
assets=[a for a in release.get('assets',[]) if a.get('name')==name]
if len(assets)!=1: raise SystemExit('Expected one official binary asset')
asset=assets[0]; url=asset.get('browser_download_url',''); parsed=urllib.parse.urlparse(url)
expected=['/'+owner+'/hysteria/releases/download/'+tag+'/'+name for owner in ('HyNetworks','apernet')]
if parsed.scheme!='https' or parsed.netloc!='github.com' or parsed.path not in expected or parsed.query or parsed.fragment: raise SystemExit('Non-official asset URL rejected')
digest=asset.get('digest','')
if not isinstance(digest,str) or not re.fullmatch(r'sha256:[0-9a-fA-F]{64}',digest): raise SystemExit('Missing official SHA256 digest; no binary installed')
size=asset.get('size',0)
if not isinstance(size,int) or not 0<size<134217728: raise SystemExit('Unexpected asset size')
print(tag); print(url); print(digest[7:].lower())
PY
}

fetch_binary() {
  local request_url tag_encoded
  if [[ $RELEASE == latest ]]; then request_url="$API_ROOT/releases/latest"
  else tag_encoded=${RELEASE//\//%2F}; request_url="$API_ROOT/releases/tags/$tag_encoded"; fi
  say '读取官方版本与 SHA256 元数据…'
  download_https "$request_url" "$WORK_DIR/release.json"
  select_release_asset "$WORK_DIR/release.json" "$ARCH" >"$WORK_DIR/asset.txt"
  mapfile -t ASSET_FIELDS <"$WORK_DIR/asset.txt"
  [[ ${#ASSET_FIELDS[@]} -eq 3 ]] || die '官方版本元数据不完整。'
  RELEASE_TAG=${ASSET_FIELDS[0]}; ASSET_URL=${ASSET_FIELDS[1]}; ASSET_DIGEST=${ASSET_FIELDS[2]}
  [[ $RELEASE == latest || $RELEASE_TAG == "$RELEASE" ]] || die '返回的版本与请求不一致。'
  say "下载官方 $RELEASE_TAG / $ARCH，并校验完整文件。"
  download_https "$ASSET_URL" "$WORK_DIR/hysteria"
  printf '%s  %s\n' "$ASSET_DIGEST" "$WORK_DIR/hysteria" | sha256sum --check --status || die '官方 SHA256 校验失败。'
  python3 - "$WORK_DIR/hysteria" "$ARCH" <<'PY'
import struct,sys
with open(sys.argv[1],'rb') as f: header=f.read(20)
if len(header)<20 or header[:4]!=b'\x7fELF' or header[4]!=2 or header[5]!=1: raise SystemExit('Expected a 64-bit little-endian Linux ELF binary')
machine=struct.unpack('<H',header[18:20])[0]
if machine!={'amd64':62,'arm64':183}[sys.argv[2]]: raise SystemExit('Binary CPU architecture mismatch')
PY
  chmod 0755 "$WORK_DIR/hysteria"
  "$WORK_DIR/hysteria" version >"$WORK_DIR/binary-version.txt"
}

ensure_service_user() {
  if id "$SERVICE_USER" >/dev/null 2>&1; then
    local home shell
    [[ $(id -u "$SERVICE_USER") -ne 0 ]] || die '拒绝将 root UID 用作专用服务用户。'
    home=$(getent passwd "$SERVICE_USER" | cut -d: -f6)
    shell=$(getent passwd "$SERVICE_USER" | cut -d: -f7)
    [[ $home == "$STATE_DIR" && ( $shell == /usr/sbin/nologin || $shell == /sbin/nologin || $shell == /bin/false ) ]] || die '同名用户不是预期的专用非登录用户。'
    [[ $(id -gn "$SERVICE_USER") == "$SERVICE_USER" ]] || die '专用用户的主组不匹配。'
  else
    useradd --system --user-group --home-dir "$STATE_DIR" --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  fi
}

# Pure rendering helper for tests: only writes to the explicitly supplied stage.
# The password is passed to Python on a private descriptor, not in process args.
render_configs() {
  local stage=$1 mode=$2 host=$3 port=$4 email=$5 password=$6 fingerprint=${7:-}
  valid_host "$host" && valid_port "$port" || return 1
  [[ $password =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
  case "$mode" in
    acme) valid_domain "$host" && valid_email "$email" || return 1 ;;
    self-signed) valid_pin "$fingerprint" || return 1 ;;
    *) return 1 ;;
  esac
  python3 - "$stage" "$mode" "$host" "$port" "$email" "$fingerprint" 3<<<"$password" <<'PY'
import json,os,pathlib,sys
stage=pathlib.Path(sys.argv[1]); mode,host,port,email,pin=sys.argv[2:]
password=os.fdopen(3).read().strip(); q=lambda s:json.dumps(str(s),ensure_ascii=False)
server='listen: '+q(':'+str(int(port)))+'\n\n'
if mode=='acme':
    server+='acme:\n  domains:\n    - '+q(host)+'\n  email: '+q(email)+'\n  ca: letsencrypt\n  type: http\n  dir: "/var/lib/qianli-hysteria/acme"\n'
else:
    server+='tls:\n  cert: "/etc/qianli-hysteria/server.crt"\n  key: "/etc/qianli-hysteria/server.key"\n'
server+='\nauth:\n  type: password\n  password: '+q(password)+'\n'
client='# qianli — keep this file private; it contains the authentication secret.\n'
client+='server: '+q(host+':'+str(int(port)))+'\nauth: '+q(password)+'\n\ntls:\n  sni: '+q(host)+'\n'
if mode=='self-signed':
    client+='  # Certificate-chain verification is replaced by the mandatory certificate pin.\n  # Do not remove or change pinSHA256 without verifying the server certificate.\n  insecure: true\n  pinSHA256: '+q(pin)+'\n'
else: client+='  insecure: false\n'
client+='\nsocks5:\n  listen: "127.0.0.1:12808"\n\nhttp:\n  listen: "127.0.0.1:12809"\n'
for name,text in [('config.yaml',server),('client.yaml',client)]:
    file=stage/name
    fd=os.open(file,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w',encoding='utf-8') as f:f.write(text)
PY
}

write_unit() {
  cat >"$WORK_DIR/$UNIT" <<'UNIT'
[Unit]
Description=qianli Hysteria 2 server
Documentation=https://github.com/li23434/qianli-hysteria2-guide
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=qianli-hysteria
Group=qianli-hysteria
WorkingDirectory=/var/lib/qianli-hysteria
ExecStart=/usr/local/lib/qianli-hysteria/hysteria server --config /etc/qianli-hysteria/config.yaml
Restart=on-failure
RestartSec=5s
TimeoutStopSec=20s
UMask=0077
StateDirectory=qianli-hysteria
StateDirectoryMode=0700
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/qianli-hysteria
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
UNIT
}

wait_for_active() {
  # Type=simple is active before TLS/ACME initialization finishes. Only the
  # ready message from this exact systemd invocation confirms server startup.
  local attempt invocation current state
  invocation=$(systemctl show --property=InvocationID --value "$UNIT") || return 1
  [[ $invocation =~ ^[a-fA-F0-9]{32}$ ]] || return 1
  for ((attempt=1; attempt<=300; attempt++)); do
    current=$(systemctl show --property=InvocationID --value "$UNIT") || return 1
    [[ $current == "$invocation" ]] || return 1
    state=$(systemctl show --property=ActiveState --value "$UNIT") || return 1
    case "$state" in active|activating) ;; *) return 1 ;; esac
    if [[ $state == active ]] && journalctl --quiet --no-pager --output=cat \
      --unit "$UNIT" "_SYSTEMD_INVOCATION_ID=$invocation" | grep -F 'server up and running' >/dev/null; then
      # Guard against a crash/restart while reading the journal.
      current=$(systemctl show --property=InvocationID --value "$UNIT") || return 1
      [[ $current == "$invocation" ]] && systemctl is-active --quiet "$UNIT" && return 0
      return 1
    fi
    sleep 1
  done
  say '等待本次服务就绪超时（300 秒），未把进程 active 当作安装成功。' >&2
  return 1
}

write_metadata() {
  python3 - "$WORK_DIR/install.json" "$HOST" "$PORT" "$CERT_MODE" "$RELEASE_TAG" "$ASSET_DIGEST" "$QIANLI_VERSION" <<'PY'
import json,os,sys
file,host,port,mode,release,digest,version=sys.argv[1:]
with open(file,'w',encoding='utf-8') as f:json.dump({'managed_by':'qianli','host':host,'port':int(port),'cert_mode':mode,'release':release,'sha256':digest,'installer_version':version},f,indent=2);f.write('\n')
os.chmod(file,0o600)
PY
}

collect_install_options() {
  local input
  if (( ! ASSUME_YES )) && [[ -t 0 ]]; then
    if (( ! MODE_SET )); then
      read -r -p '证书方式：1 可信域名 ACME；2 自签证书加指纹 [1]：' input
      case "${input:-1}" in 1) CERT_MODE=acme ;; 2) CERT_MODE=self-signed ;; *) die '证书选项无效。' ;; esac
    fi
    if (( ! HOST_SET )); then read -r -p '服务器域名（自签模式也可填写 IPv4）：' HOST; fi
    if [[ $CERT_MODE == acme && -z $EMAIL ]]; then read -r -p 'ACME 联系邮箱：' EMAIL; fi
    if (( ! PORT_SET )); then read -r -p 'Hysteria UDP 端口 [443]：' input; PORT=${input:-443}; fi
  fi
  valid_host "$HOST" || die '服务器地址须是有效 DNS 名称或 IPv4；当前不支持直接填写 IPv6。'
  valid_port "$PORT" || die '端口必须在 1–65535 之间。'
  PORT=$((10#$PORT))
  if [[ $CERT_MODE == acme ]]; then
    valid_domain "$HOST" || die 'ACME 模式需要域名，不接受 IP 地址。'
    valid_email "$EMAIL" || die 'ACME 模式需要有效联系邮箱。'
  fi
}

install_server() {
  collect_install_options
  assert_no_symlink
  [[ -f ${BASH_SOURCE[0]} ]] || die '请先把 install.sh 下载为普通文件，再用 bash 执行；不支持管道或进程替换安装。'
  managed_install && die '已有 qianli 安装；更新程序请使用 update，不覆盖已有配置。'
  [[ ! -e $CONFIG_DIR && ! -e $STATE_DIR && ! -e $BIN_DIR && ! -e $MANAGER && ! -e $UNIT_FILE ]] || die '某个专属路径已存在但不受本脚本管理，未覆盖。'
  ARCH=$(detect_arch) || die '当前只提供 amd64 和 arm64 安装。'
  say "qianli：$HOST / $PORT UDP / $CERT_MODE / $ARCH / $RELEASE"
  say 'ACME 使用 HTTP 验证，需要域名正确解析、公网 80/TCP 可达且未被其他服务占用。'
  say '本脚本不会改动防火墙；请自行放行实际 UDP 端口。'
  confirm '开始安装到 qianli 专属路径？'
  install_dependencies
  acquire_lock
  # A different installer may have completed while this process was preparing
  # dependencies. Recheck ownership and empty paths while holding the lock.
  assert_no_symlink
  managed_install && die '另一个进程已完成 qianli 安装；未覆盖其配置。'
  [[ ! -e $CONFIG_DIR && ! -e $STATE_DIR && ! -e $BIN_DIR && ! -e $MANAGER && ! -e $UNIT_FILE ]] || die '等待锁期间专属路径已被创建，未覆盖。'
  [[ -z $(ss -H -lun "sport = :$PORT") ]] || die '该 UDP 端口已有监听，请换端口。'
  if [[ $CERT_MODE == acme ]]; then
    [[ -z $(ss -H -ltn 'sport = :80') ]] || die '80/TCP 已有监听，未停止现有网站；可改用自签模式或自行安排证书。'
    timeout 15 getent ahosts "$HOST" >/dev/null || die '域名尚不能解析，请先配置 DNS。'
  fi
  create_work_dir
  fetch_binary
  local password fingerprint='' san
  password=$(openssl rand -hex 32)
  if [[ $CERT_MODE == self-signed ]]; then
    if valid_ipv4 "$HOST"; then san="IP:$HOST"; else san="DNS:$HOST"; fi
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -nodes \
      -days 365 -subj "/CN=$HOST" -addext "subjectAltName=$san" \
      -keyout "$WORK_DIR/server.key" -out "$WORK_DIR/server.crt" >/dev/null 2>&1
    fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "$WORK_DIR/server.crt")
    fingerprint=${fingerprint#*=}
    valid_pin "$fingerprint" || die '证书指纹生成失败。'
  fi
  render_configs "$WORK_DIR" "$CERT_MODE" "$HOST" "$PORT" "$EMAIL" "$password" "$fingerprint"
  unset password
  write_unit
  write_metadata
  ensure_service_user
  NEW_INSTALL_TRANSACTION=1
  install -d -m 0750 -o root -g "$SERVICE_USER" "$CONFIG_DIR"
  install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$STATE_DIR"
  install -d -m 0755 -o root -g root "$BIN_DIR"
  install -m 0755 -o root -g root "$WORK_DIR/hysteria" "$BINARY"
  install -m 0640 -o root -g "$SERVICE_USER" "$WORK_DIR/config.yaml" "$CONFIG_DIR/config.yaml"
  install -m 0600 -o root -g root "$WORK_DIR/client.yaml" "$CONFIG_DIR/client.yaml"
  install -m 0600 -o root -g root "$WORK_DIR/install.json" "$CONFIG_DIR/install.json"
  if [[ $CERT_MODE == self-signed ]]; then
    install -m 0644 -o root -g root "$WORK_DIR/server.crt" "$CONFIG_DIR/server.crt"
    install -m 0640 -o root -g "$SERVICE_USER" "$WORK_DIR/server.key" "$CONFIG_DIR/server.key"
  fi
  printf '%s\n' qianli-hy2-v1 >"$MARKER"
  install -m 0644 -o root -g root "$WORK_DIR/$UNIT" "$UNIT_FILE"
  install -m 0755 -o root -g root "${BASH_SOURCE[0]}" "$MANAGER"
  systemctl daemon-reload
  systemctl enable --now "$UNIT"
  if ! wait_for_active; then
    journalctl -u "$UNIT" --no-pager -n 30 >&2 || true
    die '服务未保持运行，正在回滚本次新安装。'
  fi
  NEW_INSTALL_TRANSACTION=0
  say "已安装官方 Hysteria $RELEASE_TAG，独立服务：$UNIT"
  say "服务进程运行不代表客户端端到端连接已验收。配置：$CONFIG_DIR/config.yaml"
  say '使用 sudo qianli-hy2 show-client 查看私有客户端配置。'
  if [[ $CERT_MODE == self-signed ]]; then say '自签证书有效期 365 天；导出的 pinSHA256 必须保留，更换证书后同步更新客户端。'; fi
}

rollback_binary() {
  [[ -f $1 && ! -L $1 ]] || return 1
  install -m 0755 -o root -g root "$1" "$BINARY" || return 1
  if [[ $2 == active ]]; then
    systemctl restart "$UNIT" || return 1
    wait_for_active || return 1
  else
    systemctl stop "$UNIT" >/dev/null 2>&1 || true
  fi
}

update_server() {
  require_managed
  [[ -f $BINARY && -f $UNIT_FILE ]] || die '安装不完整，未进行更新。'
  ARCH=$(detect_arch) || die '不支持该架构。'
  confirm "更新官方 Hysteria 程序到 $RELEASE，并保留配置和证书？"
  install_dependencies
  acquire_lock
  require_managed
  [[ -f $BINARY && -f $UNIT_FILE ]] || die '等待锁期间安装已改变，未进行更新。'
  create_work_dir
  fetch_binary
  local previous_state=inactive
  systemctl is-active --quiet "$UNIT" && previous_state=active
  cp --preserve=mode,ownership,timestamps -- "$BINARY" "$WORK_DIR/previous.bin"
  cp --preserve=mode,ownership,timestamps -- "$CONFIG_DIR/install.json" "$WORK_DIR/previous-meta.json"
  python3 - "$CONFIG_DIR/install.json" "$WORK_DIR/updated-meta.json" "$RELEASE_TAG" "$ASSET_DIGEST" <<'PY'
import json,os,sys
file,target,tag,digest=sys.argv[1:]
with open(file,encoding='utf-8') as f: data=json.load(f)
data['release']=tag;data['sha256']=digest
with open(target,'w',encoding='utf-8') as f:json.dump(data,f,indent=2);f.write('\n')
os.chmod(target,0o600)
PY
  UPDATE_PREVIOUS_STATE=$previous_state
  UPDATE_TRANSACTION=1
  if [[ $previous_state == active ]]; then systemctl stop "$UNIT"; fi
  install -m 0755 -o root -g root "$WORK_DIR/hysteria" "$BINARY"
  if [[ $previous_state == active ]]; then
    systemctl start "$UNIT"
    wait_for_active || die '新版本未保持运行，正在恢复原程序。'
  fi
  install -m 0755 -o root -g root "$WORK_DIR/previous.bin" "$BIN_DIR/hysteria.previous"
  install -m 0600 -o root -g root "$WORK_DIR/updated-meta.json" "$CONFIG_DIR/.install.next"
  mv -f -- "$CONFIG_DIR/.install.next" "$CONFIG_DIR/install.json"
  UPDATE_TRANSACTION=0
  say "已更新到 $RELEASE_TAG；配置和证书保持不变，旧程序保存在 $BIN_DIR/hysteria.previous。"
  [[ $previous_state == active ]] || say '更新前服务未运行，因此未自动启动。'
}

uninstall_server() {
  require_managed
  if (( PURGE )); then confirm '卸载程序并永久清理 qianli 专属配置、口令、证书与状态？'
  else confirm '卸载 qianli 程序和服务，保留配置、口令与证书？'; fi
  command -v flock >/dev/null || die '需要 flock，未进行卸载。'
  acquire_lock
  require_managed
  if [[ -f $UNIT_FILE ]]; then systemctl disable --now "$UNIT"; fi
  rm -f -- "$UNIT_FILE" "$MANAGER"
  systemctl daemon-reload
  systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
  remove_own_directory "$BIN_DIR"
  if (( PURGE )); then
    remove_own_directory "$STATE_DIR"
    remove_own_directory "$CONFIG_DIR"
    say '已清理 qianli 专属文件；未删除任何其他 Hysteria/Caddy/SSH 配置。'
  else
    say "程序已卸载；私有配置仍保留在 $CONFIG_DIR，状态与证书缓存保留在 $STATE_DIR。"
    say '保留的专用非登录用户未删除。若需完整清理，可再次下载本脚本运行 uninstall --purge。'
  fi
}

show_client() {
  require_managed
  [[ -f $CONFIG_DIR/client.yaml && ! -L $CONFIG_DIR/client.yaml ]] || die '没有找到客户端配置。'
  say '# 以下含认证口令，请只保存到自己的客户端，不要公开上传。'
  cat "$CONFIG_DIR/client.yaml"
}

menu() {
  [[ -t 0 ]] || die '请使用 install/update 等明确命令；--help 可查看用法。'
  say "qianli Hysteria 2 管理器 $QIANLI_VERSION"
  say '1 安装  2 更新  3 状态  4 日志  5 客户端配置  6 重启  7 卸载  0 退出'
  local choice
  read -r -p '请选择：' choice
  case "$choice" in
    1) COMMAND=install ;; 2) COMMAND=update ;; 3) COMMAND=status ;;
    4) COMMAND=logs ;; 5) COMMAND=show-client ;; 6) COMMAND=restart ;;
    7) COMMAND=uninstall ;; 0) return 1 ;; *) die '菜单选项无效。' ;;
  esac
}

parse_args() {
  local seen_command=0
  while (( $# )); do
    case "$1" in
      install|update|status|logs|show-client|start|stop|restart|uninstall|menu)
        (( seen_command == 0 )) || die '一次只接受一个命令。'
        COMMAND=$1; seen_command=1; shift ;;
      --domain|--host) (( $# >= 2 )) || die "$1 缺少参数。"; HOST=$2; HOST_SET=1; shift 2 ;;
      --email) (( $# >= 2 )) || die '--email 缺少参数。'; EMAIL=$2; shift 2 ;;
      --port) (( $# >= 2 )) || die '--port 缺少参数。'; PORT=$2; PORT_SET=1; shift 2 ;;
      --cert-mode) (( $# >= 2 )) || die '--cert-mode 缺少参数。'; CERT_MODE=$2; MODE_SET=1; shift 2 ;;
      --release) (( $# >= 2 )) || die '--release 缺少参数。'; RELEASE=$2; shift 2 ;;
      --yes) ASSUME_YES=1; shift ;;
      --purge) PURGE=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --help|-h) usage; return 10 ;;
      --version) printf 'qianli-hy2 %s\n' "$QIANLI_VERSION"; return 10 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  [[ $CERT_MODE == acme || $CERT_MODE == self-signed ]] || die '证书方式只能是 acme 或 self-signed。'
  valid_port "$PORT" || die '端口必须在 1–65535 之间。'
  if (( HOST_SET )); then
    valid_host "$HOST" || die '服务器地址须是 DNS 名称或 IPv4。'
    if [[ $CERT_MODE == acme ]]; then valid_domain "$HOST" || die 'ACME 模式需要域名。'; fi
  fi
  [[ -z $EMAIL ]] || valid_email "$EMAIL" || die '联系邮箱格式无效。'
  RELEASE=$(normalize_release "$RELEASE") || die '版本格式应为 app/v2.x.y 或 latest。'
  if [[ $COMMAND == menu ]] && (( HOST_SET || PORT_SET || MODE_SET )) || { [[ $COMMAND == menu ]] && [[ -n $EMAIL ]]; }; then COMMAND=install; fi
  if [[ $COMMAND != install && $COMMAND != menu ]] && { (( HOST_SET || PORT_SET || MODE_SET )) || [[ -n $EMAIL ]]; }; then die '域名、邮箱、端口和证书选项只用于 install。'; fi
  (( ! PURGE )) || [[ $COMMAND == uninstall ]] || die '--purge 只能用于 uninstall。'
}

print_dry_run() {
  say "qianli-hy2 $QIANLI_VERSION：仅计划，不执行系统修改。"
  say "命令：$COMMAND；官方仓库 ID：$REPOSITORY_ID；版本：$RELEASE"
  say "地址：${HOST:-<安装时填写>}；UDP 端口：$PORT；证书方式：$CERT_MODE"
  say "程序：$BINARY"
  say "配置：$CONFIG_DIR/config.yaml；客户端：$CONFIG_DIR/client.yaml"
  say "状态：$STATE_DIR；独立服务：$UNIT；管理入口：$MANAGER"
  say '安装将读取官方 API digest 并验证 SHA256；缺少有效 digest 时中止。'
  say '本次未下载、未安装依赖、未创建目录、未生成口令、未写配置、未启动服务。'
  if (( PURGE )); then say '正式执行将仅清理 qianli 专属路径，需明确确认。'; fi
}

main() {
  local parse_status=0
  parse_args "$@" || parse_status=$?
  (( parse_status != 10 )) || return 0
  (( parse_status == 0 )) || return "$parse_status"
  if (( DRY_RUN )); then print_dry_run; return; fi
  if [[ $COMMAND == menu ]]; then menu || return 0; fi
  require_linux_root
  trap cleanup_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  case "$COMMAND" in
    install) install_server ;;
    update) update_server ;;
    uninstall) uninstall_server ;;
    show-client) show_client ;;
    status) require_managed; systemctl status "$UNIT" --no-pager ;;
    logs) require_managed; journalctl -u "$UNIT" --no-pager -n 80 ;;
    start|stop|restart) require_managed; systemctl "$COMMAND" "$UNIT" ;;
    *) die '未知操作。' ;;
  esac
}

# Sourcing this file only defines helpers; it never executes an installation.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
