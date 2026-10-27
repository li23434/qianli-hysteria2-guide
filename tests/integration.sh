#!/usr/bin/env bash
# Linux integration checks. All installation paths are relocated to a temporary
# tree; systemd/user creation are mocked. No host service or account is changed.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
[[ $(uname -s) == Linux ]] || { printf 'SKIP: integration.sh requires Linux\n'; exit 0; }
for tool in bash python3 openssl sha256sum install flock; do
  command -v "$tool" >/dev/null || { printf 'Missing test dependency: %s\n' "$tool" >&2; exit 1; }
done
mkdir -p "$ROOT/.test-output"
TMP=$(mktemp -d "$ROOT/.test-output/integration.XXXXXXXX")
PIDS=()
cleanup() {
  local status=$? pid
  trap - EXIT INT TERM
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
  if (( status != 0 )); then
    printf 'Integration failed. Recent diagnostic output (no client secrets):\n' >&2
    if [[ -f $TMP/operation.log ]]; then tail -n 20 "$TMP/operation.log" >&2; fi
  fi
  case "$TMP" in "$ROOT"/.test-output/integration.*) rm -rf -- "$TMP" ;; *) exit 1 ;; esac
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export QIANLI_TEST_ROOT="$TMP/root"
export QIANLI_TEST_MAPPED="$TMP/install-relocated.sh"
export QIANLI_TEST_FIXTURE="$TMP/hysteria.fixture"
export QIANLI_TEST_STATE="$TMP/mock-state"
mkdir -p "$QIANLI_TEST_ROOT"/{etc/systemd/system,usr/local/sbin,run,var/tmp}
printf 'unrelated data\n' >"$QIANLI_TEST_ROOT/unrelated.sentinel"
printf 'inactive\n' >"$QIANLI_TEST_STATE"

# Only the test copy is rewritten. Keep the real installer's guards, rendering,
# filesystem operations, main dispatcher and EXIT rollback behavior intact.
python3 - "$ROOT/install.sh" "$QIANLI_TEST_MAPPED" "$QIANLI_TEST_ROOT" <<'PY'
import pathlib,sys
source,target,root=sys.argv[1:]
text=pathlib.Path(source).read_text()
paths=['/etc/qianli-hysteria','/var/lib/qianli-hysteria',
       '/usr/local/lib/qianli-hysteria','/usr/local/sbin/qianli-hy2',
       '/etc/systemd/system/qianli-hysteria-server.service',
       '/run/qianli-hysteria-installer.lock','/var/tmp/qianli-hy2.']
for path in paths:
    assert path in text, 'Installer path changed: '+path
    text=text.replace(path,root+path)
pathlib.Path(target).write_text(text)
PY

# Deliberately fake executable: this suite tests orchestration and rollback, not
# protocol compatibility. tests/systemd-e2e.sh exercises the real binary/service.
printf '#!/bin/sh\nprintf "integration fixture\\n"\n' >"$QIANLI_TEST_FIXTURE"
chmod 0755 "$QIANLI_TEST_FIXTURE"

cat >"$TMP/run-operation.sh" <<'RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck disable=SC1090
source "$QIANLI_TEST_MAPPED"
require_linux_root() { :; }
install_dependencies() { :; }
ensure_service_user() { :; }
ss() { :; }
getent() { printf '127.0.0.1 STREAM test.example.com\n'; }
timeout() { shift; "$@"; }
journalctl() {
  if [[ ${QIANLI_TEST_READY_MODE:-ready} == no-ready ]]; then
    printf 'server is still initializing\n'
  else
    printf 'server up and running\n'
  fi
}
sleep() { :; }
install() {
  local -a args=()
  while (( $# )); do
    case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
  done
  command install "${args[@]}"
}
systemctl() {
  local operation=$1
  case "$operation" in
    is-active) [[ $(cat "$QIANLI_TEST_STATE") == active ]] ;;
    show)
      case "$2" in
        --property=InvocationID)
          if [[ ${QIANLI_TEST_READY_MODE:-ready} == changed-invocation && -e $QIANLI_TEST_ROOT/invocation-seen ]]; then
            printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
          else
            touch "$QIANLI_TEST_ROOT/invocation-seen"
            printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
          fi ;;
        --property=ActiveState) cat "$QIANLI_TEST_STATE" ;;
        *) printf 'Unexpected systemctl property: %s\n' "$*" >&2; return 99 ;;
      esac ;;
    start|restart|enable)
      if [[ -f $QIANLI_TEST_ROOT/fail-next-start ]]; then
        rm -- "$QIANLI_TEST_ROOT/fail-next-start"
        printf 'inactive\n' >"$QIANLI_TEST_STATE"
        return 1
      fi
      printf 'active\n' >"$QIANLI_TEST_STATE" ;;
    stop|disable) printf 'inactive\n' >"$QIANLI_TEST_STATE" ;;
    daemon-reload|reset-failed|status) : ;;
    *) printf 'Unexpected systemctl operation: %s\n' "$*" >&2; return 99 ;;
  esac
}
fetch_binary() {
  cp -- "$QIANLI_TEST_FIXTURE" "$WORK_DIR/hysteria"
  # Distinguish update generations so binary rollback cannot pass accidentally.
  if [[ ${QIANLI_TEST_GENERATION:-0} != 0 ]]; then
    printf '\nqianli-test-generation-%s\n' "$QIANLI_TEST_GENERATION" >>"$WORK_DIR/hysteria"
  fi
  RELEASE_TAG='app/v2.13.0'
  ASSET_DIGEST=$(sha256sum "$WORK_DIR/hysteria"); ASSET_DIGEST=${ASSET_DIGEST%% *}
}
main "$@"
RUNNER

passed=0
check() { if "$@"; then passed=$((passed+1)); else printf 'FAIL: %s\n' "$*" >&2; exit 1; fi; }
run() { bash --noprofile --norc "$TMP/run-operation.sh" "$@" >"$TMP/operation.log" 2>&1; }
fails() { if run "$@"; then printf 'UNEXPECTED SUCCESS: %s\n' "$*" >&2; exit 1; else passed=$((passed+1)); fi; }
digest() { local value; value=$(sha256sum "$1"); printf '%s\n' "${value%% *}"; }
CONFIG="$QIANLI_TEST_ROOT/etc/qianli-hysteria"
STATE="$QIANLI_TEST_ROOT/var/lib/qianli-hysteria"
BIN="$QIANLI_TEST_ROOT/usr/local/lib/qianli-hysteria"
MANAGER="$QIANLI_TEST_ROOT/usr/local/sbin/qianli-hy2"
UNIT_FILE="$QIANLI_TEST_ROOT/etc/systemd/system/qianli-hysteria-server.service"
PORT=18443

# Force service-start failure after files have been installed: EXIT must roll
# back this installation and leave unrelated files untouched.
touch "$QIANLI_TEST_ROOT/fail-next-start"
fails install --cert-mode self-signed --host 127.0.0.1 --port "$PORT" --yes
for path in "$CONFIG" "$STATE" "$BIN" "$MANAGER" "$UNIT_FILE"; do check test ! -e "$path"; done
check test -f "$QIANLI_TEST_ROOT/unrelated.sentinel"

# Neither an active process without the ready event nor an automatic restart
# (new InvocationID) may be reported as a successful first installation.
for mode in no-ready changed-invocation; do
  export QIANLI_TEST_READY_MODE=$mode
  rm -f -- "$QIANLI_TEST_ROOT/invocation-seen"
  fails install --cert-mode self-signed --host 127.0.0.1 --port "$PORT" --yes
  for path in "$CONFIG" "$STATE" "$BIN" "$MANAGER" "$UNIT_FILE"; do check test ! -e "$path"; done
done
export QIANLI_TEST_READY_MODE=ready
rm -f -- "$QIANLI_TEST_ROOT/invocation-seen"

run install --cert-mode self-signed --host 127.0.0.1 --port "$PORT" --yes
for path in "$CONFIG/config.yaml" "$CONFIG/client.yaml" "$CONFIG/install.json" "$CONFIG/server.crt" "$CONFIG/server.key" "$MANAGER" "$UNIT_FILE" "$BIN/hysteria"; do check test -s "$path"; done
check test "$(stat -c %a "$CONFIG/client.yaml")" = 600
check test "$(stat -c %a "$CONFIG/config.yaml")" = 640
check test "$(stat -c %a "$CONFIG/server.key")" = 640
check test "$(cat "$QIANLI_TEST_STATE")" = active
CONFIG_DIGEST=$(digest "$CONFIG/config.yaml")
CERT_DIGEST=$(digest "$CONFIG/server.crt")
INITIAL_BINARY=$(digest "$BIN/hysteria")
INITIAL_META=$(digest "$CONFIG/install.json")

# An update that fails to start must restore both the old binary and metadata,
# and return an initially running service to its prior running state.
export QIANLI_TEST_GENERATION=1
touch "$QIANLI_TEST_ROOT/fail-next-start"
fails update --yes
check test "$(digest "$BIN/hysteria")" = "$INITIAL_BINARY"
check test "$(digest "$CONFIG/install.json")" = "$INITIAL_META"
check test "$(cat "$QIANLI_TEST_STATE")" = active
check test "$(digest "$CONFIG/config.yaml")" = "$CONFIG_DIGEST"
check test "$(digest "$CONFIG/server.crt")" = "$CERT_DIGEST"

run update --yes
check test "$(digest "$BIN/hysteria")" != "$INITIAL_BINARY"
check test "$(digest "$BIN/hysteria.previous")" = "$INITIAL_BINARY"
check test "$(digest "$CONFIG/config.yaml")" = "$CONFIG_DIGEST"
check test "$(digest "$CONFIG/server.crt")" = "$CERT_DIGEST"
check test "$(cat "$QIANLI_TEST_STATE")" = active
printf 'inactive\n' >"$QIANLI_TEST_STATE"
export QIANLI_TEST_GENERATION=2
run update --yes
check test "$(cat "$QIANLI_TEST_STATE")" = inactive

run uninstall --yes
for path in "$BIN" "$MANAGER" "$UNIT_FILE"; do check test ! -e "$path"; done
for path in "$CONFIG/client.yaml" "$CONFIG/server.key" "$CONFIG/.managed-by-qianli" "$STATE"; do check test -e "$path"; done
fails install --cert-mode self-signed --host 127.0.0.1 --port "$PORT" --yes
check test "$(digest "$CONFIG/config.yaml")" = "$CONFIG_DIGEST"
run uninstall --purge --yes
check test ! -e "$CONFIG"
check test ! -e "$STATE"
check test -f "$QIANLI_TEST_ROOT/unrelated.sentinel"

# ACME orchestration/rendering only. This intentionally never requests a public
# certificate: public DNS, TCP80 reachability and CA issuance need a real VPS.
run install --domain test.example.com --email admin@example.com --port "$PORT" --yes
check grep -q '^acme:' "$CONFIG/config.yaml"
check grep -q 'type: http' "$CONFIG/config.yaml"
check grep -q 'insecure: false' "$CONFIG/client.yaml"
check test ! -e "$CONFIG/server.key"
run uninstall --purge --yes
check test ! -e "$CONFIG"
check test ! -e "$STATE"
check test -f "$QIANLI_TEST_ROOT/unrelated.sentinel"
printf 'PASS: %s isolated orchestration checks; fake systemd/binary; no host service/account/firewall changes\n' "$passed"
