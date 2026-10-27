#!/usr/bin/env bash
# Actual install/service/client test, restricted to disposable GitHub-hosted VMs.
set -Eeuo pipefail
umask 077
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]] || {
  printf 'This test only runs on a disposable GitHub-hosted runner.\n' >&2
  exit 1
}
[[ $EUID -eq 0 && -d /run/systemd/system ]] || {
  printf 'Root and a running systemd are required.\n' >&2
  exit 1
}
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
STAGE=$(mktemp -d "${RUNNER_TEMP:?}/qianli-systemd.XXXXXXXX")
UNIT=qianli-hysteria-server.service
BINARY=/usr/local/lib/qianli-hysteria/hysteria
CONFIG=/etc/qianli-hysteria
CLIENT_PID=''
HTTP_PID=''
cleanup() {
  local result=$?
  trap - EXIT
  set +e
  [[ -z $CLIENT_PID ]] || { kill "$CLIENT_PID" 2>/dev/null; wait "$CLIENT_PID" 2>/dev/null; }
  [[ -z $HTTP_PID ]] || { kill "$HTTP_PID" 2>/dev/null; wait "$HTTP_PID" 2>/dev/null; }
  if [[ -f $CONFIG/.managed-by-qianli ]]; then
    bash "$ROOT/install.sh" uninstall --purge --yes
  fi
  # Do not print client configs or private-key/authentication material to CI logs.
  if (( result != 0 )); then
    systemctl status "$UNIT" --no-pager 2>/dev/null || true
    printf 'systemd end-to-end test failed at the last reported phase.\n' >&2
  fi
  case "$STAGE" in "$RUNNER_TEMP"/qianli-systemd.*) rm -rf -- "$STAGE" ;; esac
  exit "$result"
}
trap cleanup EXIT
stop_client() {
  if [[ -n $CLIENT_PID ]]; then
    kill "$CLIENT_PID" 2>/dev/null || true
    wait "$CLIENT_PID" 2>/dev/null || true
    CLIENT_PID=''
  fi
}
start_client() {
  "$BINARY" client --config "$CONFIG/client.yaml" >"$STAGE/client.log" 2>&1 &
  CLIENT_PID=$!
}
check_proxy() {
  local attempt response=''
  for ((attempt=1; attempt<=30; attempt++)); do
    kill -0 "$CLIENT_PID" 2>/dev/null || { printf 'Client exited before handshake.\n' >&2; return 1; }
    response=$(curl --fail --silent --show-error --noproxy '' --max-time 3 \
      --proxy http://127.0.0.1:12809 http://127.0.0.1:18080/probe.txt 2>/dev/null) || response=''
    if [[ $response == "$EXPECTED" ]]; then
      response=$(curl --fail --silent --show-error --noproxy '' --max-time 5 \
        --socks5-hostname 127.0.0.1:12808 http://127.0.0.1:18080/probe.txt)
      [[ $response == "$EXPECTED" ]] && return 0
    fi
    sleep 1
  done
  printf 'HTTP/SOCKS5 request did not complete through the generated Hysteria configuration.\n' >&2
  return 1
}

printf 'Phase: real dependency/download/digest/ELF/install/systemd startup\n'
bash "$ROOT/install.sh" install --cert-mode self-signed --host 127.0.0.1 --port 18443 --yes
systemctl is-active --quiet "$UNIT"
systemctl is-enabled --quiet "$UNIT"
[[ $(systemctl show --property=User --value "$UNIT") == qianli-hysteria ]]
[[ $(stat -c '%a' "$CONFIG/client.yaml") == 600 ]]
[[ $(stat -c '%a' "$CONFIG/server.key") == 640 ]]
[[ $(stat -c '%U:%G' "$CONFIG/server.key") == root:qianli-hysteria ]]
qianli-hy2 --version
openssl x509 -checkend 86400 -noout -in "$CONFIG/server.crt" >/dev/null

printf 'Phase: generated TLS pin/authentication and HTTP/SOCKS5 loopback\n'
mkdir "$STAGE/htdocs"
EXPECTED="qianli-e2e-$(openssl rand -hex 16)"
printf '%s\n' "$EXPECTED" >"$STAGE/htdocs/probe.txt"
python3 -m http.server 18080 --bind 127.0.0.1 --directory "$STAGE/htdocs" >"$STAGE/http.log" 2>&1 &
HTTP_PID=$!
start_client
check_proxy

printf 'Phase: official binary update with unchanged private configuration\n'
stop_client
BEFORE=$(sha256sum "$CONFIG/config.yaml" "$CONFIG/client.yaml" "$CONFIG/server.crt" "$CONFIG/server.key")
RELEASE=$(python3 -c 'import json;print(json.load(open("/etc/qianli-hysteria/install.json"))["release"])')
qianli-hy2 update --release "$RELEASE" --yes
AFTER=$(sha256sum "$CONFIG/config.yaml" "$CONFIG/client.yaml" "$CONFIG/server.crt" "$CONFIG/server.key")
[[ $BEFORE == "$AFTER" ]]
start_client
check_proxy

printf 'Phase: inactive-service update does not silently start it\n'
stop_client
qianli-hy2 stop
qianli-hy2 update --release "$RELEASE" --yes
if systemctl is-active --quiet "$UNIT"; then
  printf 'Inactive update unexpectedly started the service.\n' >&2
  exit 1
fi
qianli-hy2 start
start_client
check_proxy

printf 'Phase: retain uninstall and explicit purge\n'
stop_client
qianli-hy2 uninstall --yes
[[ -f $CONFIG/client.yaml && -f $CONFIG/.managed-by-qianli ]]
[[ -d /var/lib/qianli-hysteria ]]
[[ ! -e $BINARY && ! -e /usr/local/sbin/qianli-hy2 ]]
[[ ! -e /etc/systemd/system/$UNIT ]]
bash "$ROOT/install.sh" uninstall --purge --yes
[[ ! -e $CONFIG && ! -e /var/lib/qianli-hysteria && ! -e /usr/local/lib/qianli-hysteria ]]
printf 'PASS: actual systemd install, pinned TLS/auth/proxies, active/inactive update, retain uninstall and purge\n'
