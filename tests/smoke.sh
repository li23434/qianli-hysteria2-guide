#!/usr/bin/env bash
# Local isolated checks only. Never install a service or contact a VPS.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
mkdir -p "$ROOT/.test-output"
TMP=$(mktemp -d "$ROOT/.test-output/smoke.XXXXXXXX")
cleanup() {
  # Keep removal within the verified, absolute project-owned test directory.
  case "$TMP" in "$ROOT"/.test-output/smoke.*) rm -rf -- "$TMP" ;; *) return 1 ;; esac
}
trap cleanup EXIT
# The installer is separately checked; sourcing defines functions, never main.
# shellcheck disable=SC1091
source "$ROOT/install.sh"
passed=0
ok() { if "$@"; then passed=$((passed+1)); else printf 'FAIL: %s\n' "$*" >&2; exit 1; fi; }
bad() { if "$@"; then printf 'UNEXPECTED SUCCESS: %s\n' "$*" >&2; exit 1; else passed=$((passed+1)); fi; }

ok valid_port 1
ok valid_port 443
ok valid_port 65535
bad valid_port 0
bad valid_port 65536
bad valid_port 999999999999999999999
bad valid_port '443;exit'
ok valid_domain hy2.example.com
ok valid_domain xn--bcher-kva.example
bad valid_domain '-bad.example'
bad valid_domain 'bad..example'
bad valid_domain 'hy2.example.com;touch /tmp/nope'
bad valid_domain $'hy2.example.com\nauth: injected'
ok valid_ipv4 203.0.113.10
bad valid_ipv4 256.0.0.1
bad valid_ipv4 01.2.3.4
ok valid_email admin@example.com
bad valid_email 'a@example.com;whoami'
bad valid_email $'admin@example.com\npassword: injected'
ok test "$(normalize_release v2.13.0)" = app/v2.13.0
ok test "$(normalize_release app/v2.13.0)" = app/v2.13.0
bad normalize_release v1.3.5
bad normalize_release '../../other'
PIN=$(printf 'AB:%.0s' {1..31})AB
ok valid_pin "$PIN"
bad valid_pin 'AB:CD'

python3 - "$TMP" <<'PY'
import copy,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
base={'tag_name':'app/v2.13.0','draft':False,'assets':[{'name':'hysteria-linux-amd64','browser_download_url':'https://github.com/HyNetworks/hysteria/releases/download/app/v2.13.0/hysteria-linux-amd64','digest':'sha256:'+'a'*64,'size':1000}]}
cases={'valid':base}
x=copy.deepcopy(base);x['assets'][0]['digest']=None;cases['missing-digest']=x
x=copy.deepcopy(base);x['assets'][0]['browser_download_url']='https://evil.example/hysteria-linux-amd64';cases['foreign-url']=x
x=copy.deepcopy(base);x['assets'][0]['browser_download_url']=x['assets'][0]['browser_download_url'].replace('https:','http:');cases['plain-http']=x
x=copy.deepcopy(base);x['assets'].append(copy.deepcopy(x['assets'][0]));cases['duplicate']=x
x=copy.deepcopy(base);x['tag_name']='app/v1.3.5';cases['wrong-major']=x
x=copy.deepcopy(base);x['assets'][0]['size']=999999999;cases['oversize']=x
for name,data in cases.items():(p/(name+'.json')).write_text(json.dumps(data),encoding='utf-8')
PY
asset=$(select_release_asset "$TMP/valid.json" amd64)
asset=${asset//$'\r'/}
ok test "${asset%%$'\n'*}" = app/v2.13.0
for fixture in missing-digest foreign-url plain-http duplicate wrong-major oversize; do
  bad select_release_asset "$TMP/$fixture.json" amd64 2>/dev/null
done
bad select_release_asset "$TMP/valid.json" arm64 2>/dev/null

mkdir "$TMP/mock-bin"
export QIANLI_TEST_LOG="$TMP/side-effects.log"
for cmd in curl apt-get install useradd systemctl journalctl openssl sha256sum; do
  cat >"$TMP/mock-bin/$cmd" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >>"$QIANLI_TEST_LOG"
exit 99
MOCK
  chmod +x "$TMP/mock-bin/$cmd"
done
ok env PATH="$TMP/mock-bin:$PATH" bash --noprofile --norc "$ROOT/install.sh" --help >"$TMP/help.txt"
ok env PATH="$TMP/mock-bin:$PATH" bash --noprofile --norc "$ROOT/install.sh" --version >"$TMP/version.txt"
ok env PATH="$TMP/mock-bin:$PATH" bash --noprofile --norc "$ROOT/install.sh" install --domain hy2.example.com --email admin@example.com --dry-run >"$TMP/plan.txt"
bad env PATH="$TMP/mock-bin:$PATH" bash --noprofile --norc "$ROOT/install.sh" install --domain 'bad;example.com' --email admin@example.com --dry-run >/dev/null 2>&1
bad env PATH="$TMP/mock-bin:$PATH" bash --noprofile --norc "$ROOT/install.sh" install --port 0 --dry-run >/dev/null 2>&1
ok test ! -e "$QIANLI_TEST_LOG"

case "$(uname -s)" in
  Linux)
    mkdir "$TMP/acme" "$TMP/self-signed"
    PASSWORD=$(printf 'a%.0s' {1..64})
    ok render_configs "$TMP/acme" acme hy2.example.com 443 admin@example.com "$PASSWORD" ''
    ok render_configs "$TMP/self-signed" self-signed 203.0.113.10 4443 '' "$PASSWORD" "$PIN"
    python3 - "$TMP" "$PIN" <<'PY'
import pathlib,stat,sys
p=pathlib.Path(sys.argv[1]);pin=sys.argv[2]
server=(p/'acme/config.yaml').read_text(); client=(p/'acme/client.yaml').read_text()
assert 'acme:' in server and 'type: http' in server and '\ntls:' not in server
assert 'insecure: false' in client
server=(p/'self-signed/config.yaml').read_text();client=(p/'self-signed/client.yaml').read_text()
assert '\ntls:' in server and '\nacme:' not in server
assert 'insecure: true' in client and f'pinSHA256: "{pin}"' in client
assert 'sni: "203.0.113.10"' in client
for f in p.glob('*/client.yaml'):assert stat.S_IMODE(f.stat().st_mode)==0o600
for f in p.glob('*/config.yaml'):assert stat.S_IMODE(f.stat().st_mode)==0o600
PY
    passed=$((passed+1))
    ;;
  *) printf 'SKIP: native Windows Python cannot inherit Bash fd 3; Linux CI runs configuration rendering checks.\n' ;;
esac
printf 'PASS: %s checks; no installer, VPS, firewall or service changes executed\n' "$passed"
