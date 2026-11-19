#!/usr/bin/env bash
set -euo pipefail

# Self-contained test suite for dokku-backup-heartbeat.
# Compatible with Bash 3.2+ and Bash 5.x.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_ROOT="$(mktemp -d)"
STALL_SERVER_PID=""

cleanup() {
  if [[ -n "$STALL_SERVER_PID" ]]; then
    kill "$STALL_SERVER_PID" 2>/dev/null || true
    wait "$STALL_SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

PASS_COUNT=0
FAIL_COUNT=0

# Ensure host environment variables do not interfere with isolated test runs.
unset PLUGIN_CORE_AVAILABLE_PATH || true
unset DOKKU_TRACE || true
unset BACKUP_HEARTBEAT_TIMEOUT || true

export BACKUP_HEARTBEAT_DATA_ROOT="$TMP_ROOT/data"
STUB_STATE_DIR="$TMP_ROOT/stub-state"
STUB_CURL_BIN="$TMP_ROOT/curl-stub"
mkdir -p "$STUB_STATE_DIR"

cat >"$STUB_CURL_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${STUB_STATE_DIR:?}"
count_file="$state_dir/call_count"

count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s' "$count" >"$count_file"

printf '%s\n' "$@" >"$state_dir/last_args"
if [[ -n "${HEARTBEAT_URL+x}" ]]; then
  printf '%s' "$HEARTBEAT_URL" >"$state_dir/last_env_url"
else
  rm -f "$state_dir/last_env_url"
fi

printf '%s' "${STUB_CURL_HTTP_CODE:-200}"
exit "${STUB_CURL_EXIT:-0}"
EOF
chmod 0755 "$STUB_CURL_BIN"

export STUB_STATE_DIR
export BACKUP_HEARTBEAT_CURL_BIN="$STUB_CURL_BIN"

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS: %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

get_mode() {
  local path="$1"
  if stat -f '%Lp' "$path" >/dev/null 2>&1; then
    stat -f '%Lp' "$path"
  else
    stat -c '%a' "$path"
  fi
}

reset_stub() {
  printf '0' >"$STUB_STATE_DIR/call_count"
  rm -f "$STUB_STATE_DIR/last_args" "$STUB_STATE_DIR/last_env_url"
  export STUB_CURL_EXIT=0
  export STUB_CURL_HTTP_CODE=200
}

stub_call_count() {
  if [[ -f "$STUB_STATE_DIR/call_count" ]]; then
    cat "$STUB_STATE_DIR/call_count"
  else
    printf '0'
  fi
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$label"
  else
    fail "$label (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label (missing '$needle')"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label (unexpectedly contained '$needle')"
  fi
}

# ---------------------------------------------------------------------------
# 1. install & update create 0700 data/targets dirs cleanly and idempotently
# ---------------------------------------------------------------------------
"$PLUGIN_DIR/install" >/dev/null
assert_eq "700" "$(get_mode "$BACKUP_HEARTBEAT_DATA_ROOT")" "install creates data root with mode 0700"
assert_eq "700" "$(get_mode "$BACKUP_HEARTBEAT_DATA_ROOT/targets")" "install creates targets dir with mode 0700"

"$PLUGIN_DIR/install" >/dev/null
"$PLUGIN_DIR/update" >/dev/null
assert_eq "700" "$(get_mode "$BACKUP_HEARTBEAT_DATA_ROOT")" "install/update idempotently preserve data root mode 0700"
assert_eq "700" "$(get_mode "$BACKUP_HEARTBEAT_DATA_ROOT/targets")" "install/update idempotently preserve targets dir mode 0700"

# ---------------------------------------------------------------------------
# 2. set / report / unset happy paths
# ---------------------------------------------------------------------------
PRIMARY_DS="postgres"
PRIMARY_SVC="militia_media_app_postgres"
PRIMARY_BUCKET="movie-tickets-database-backups/dokku-postgres"
PRIMARY_SECRET_1="token-alpha-secret-111"
PRIMARY_URL_1="https://uptime.example.com/api/push/${PRIMARY_SECRET_1}?status=up&msg=OK"

set_out="$(
  printf '%s\n' "$PRIMARY_URL_1" |
    "$PLUGIN_DIR/subcommands/set" "$PRIMARY_DS" "$PRIMARY_SVC" "$PRIMARY_BUCKET" 2>&1
)"
assert_not_contains "$set_out" "$PRIMARY_SECRET_1" "set output does not leak secret token"
assert_not_contains "$set_out" "https://" "set output does not leak URL"

target_dirs=("$BACKUP_HEARTBEAT_DATA_ROOT/targets"/*)
assert_eq "1" "${#target_dirs[@]}" "set creates exactly one target directory"
PRIMARY_TARGET_DIR="${target_dirs[0]}"
assert_eq "700" "$(get_mode "$PRIMARY_TARGET_DIR")" "target directory has mode 0700"

for fname in datastore service bucket url; do
  assert_eq "600" "$(get_mode "$PRIMARY_TARGET_DIR/$fname")" "target file $fname has mode 0600"
done

assert_eq "$PRIMARY_DS" "$(cat "$PRIMARY_TARGET_DIR/datastore")" "datastore file matches"
assert_eq "$PRIMARY_SVC" "$(cat "$PRIMARY_TARGET_DIR/service")" "service file matches"
assert_eq "$PRIMARY_BUCKET" "$(cat "$PRIMARY_TARGET_DIR/bucket")" "bucket file matches"
assert_eq "$PRIMARY_URL_1" "$(cat "$PRIMARY_TARGET_DIR/url")" "url file matches"

# report with 0, 1, 2, 3 filters
report_0="$("$PLUGIN_DIR/subcommands/report")"
assert_contains "$report_0" "$PRIMARY_DS $PRIMARY_SVC $PRIMARY_BUCKET (url configured)" "report (0 filters) lists configured target"
assert_not_contains "$report_0" "$PRIMARY_SECRET_1" "report (0 filters) never outputs URL"

report_1="$("$PLUGIN_DIR/subcommands/report" "$PRIMARY_DS")"
assert_contains "$report_1" "$PRIMARY_DS $PRIMARY_SVC $PRIMARY_BUCKET (url configured)" "report (1 filter) matches datastore"
assert_not_contains "$report_1" "$PRIMARY_SECRET_1" "report (1 filter) never outputs URL"

report_1_miss="$("$PLUGIN_DIR/subcommands/report" "redis")"
assert_contains "$report_1_miss" "No backup heartbeats configured" "report (1 filter miss) returns empty state"

report_2="$("$PLUGIN_DIR/subcommands/report" "$PRIMARY_DS" "$PRIMARY_SVC")"
assert_contains "$report_2" "$PRIMARY_DS $PRIMARY_SVC $PRIMARY_BUCKET (url configured)" "report (2 filters) matches datastore+service"
assert_not_contains "$report_2" "$PRIMARY_SECRET_1" "report (2 filters) never outputs URL"

report_2_miss="$("$PLUGIN_DIR/subcommands/report" "$PRIMARY_DS" "other_service")"
assert_contains "$report_2_miss" "No backup heartbeats configured" "report (2 filter miss) returns empty state"

report_3="$("$PLUGIN_DIR/subcommands/report" "$PRIMARY_DS" "$PRIMARY_SVC" "$PRIMARY_BUCKET")"
assert_contains "$report_3" "$PRIMARY_DS $PRIMARY_SVC $PRIMARY_BUCKET (url configured)" "report (3 filters) matches exact target"
assert_not_contains "$report_3" "$PRIMARY_SECRET_1" "report (3 filters) never outputs URL"

report_3_miss="$("$PLUGIN_DIR/subcommands/report" "$PRIMARY_DS" "$PRIMARY_SVC" "movie-tickets-database-backups")"
assert_contains "$report_3_miss" "No backup heartbeats configured" "report (3 filter prefix miss) does not match"

# Re-running set rotates the URL atomically without breaking the target
PRIMARY_SECRET_2="token-rotated-secret-222"
PRIMARY_URL_2="https://uptime.example.com/api/push/${PRIMARY_SECRET_2}?status=up"
printf '%s\n' "$PRIMARY_URL_2" |
  "$PLUGIN_DIR/subcommands/set" "$PRIMARY_DS" "$PRIMARY_SVC" "$PRIMARY_BUCKET" >/dev/null

target_dirs_after_rotate=("$BACKUP_HEARTBEAT_DATA_ROOT/targets"/*)
assert_eq "1" "${#target_dirs_after_rotate[@]}" "rotating URL keeps single target directory"
assert_eq "$PRIMARY_URL_2" "$(cat "$PRIMARY_TARGET_DIR/url")" "rotating URL updates url file"
assert_eq "600" "$(get_mode "$PRIMARY_TARGET_DIR/url")" "rotated url file keeps mode 0600"

# Multiple targets (same service + different bucket, and different datastore)
SECONDARY_BUCKET="movie-tickets-database-backups/dokku-postgres-secondary"
SECONDARY_URL="https://uptime.example.com/api/push/token-secondary-333"
REDIS_DS="redis"
REDIS_SVC="cache_redis"
REDIS_BUCKET="movie-tickets-database-backups/dokku-redis"
REDIS_URL="https://uptime.example.com/api/push/token-redis-444"

printf '%s\n' "$SECONDARY_URL" |
  "$PLUGIN_DIR/subcommands/set" "$PRIMARY_DS" "$PRIMARY_SVC" "$SECONDARY_BUCKET" >/dev/null
printf '%s\n' "$REDIS_URL" |
  "$PLUGIN_DIR/subcommands/set" "$REDIS_DS" "$REDIS_SVC" "$REDIS_BUCKET" >/dev/null

report_multi="$("$PLUGIN_DIR/subcommands/report")"
assert_contains "$report_multi" "$PRIMARY_DS $PRIMARY_SVC $PRIMARY_BUCKET (url configured)" "report lists primary target"
assert_contains "$report_multi" "$PRIMARY_DS $PRIMARY_SVC $SECONDARY_BUCKET (url configured)" "report lists same-service secondary bucket target"
assert_contains "$report_multi" "$REDIS_DS $REDIS_SVC $REDIS_BUCKET (url configured)" "report lists different-datastore target"
assert_not_contains "$report_multi" "token-" "report with multiple targets never outputs any URL"

# Verify independent dispatch across coexisting targets
reset_stub
"$PLUGIN_DIR/service-action" post-backup "$PRIMARY_DS" "$PRIMARY_SVC" "$SECONDARY_BUCKET" success >/dev/null
assert_eq "1" "$(stub_call_count)" "secondary bucket target dispatches once"
assert_eq "$SECONDARY_URL" "$(cat "$STUB_STATE_DIR/last_env_url")" "secondary bucket target receives its own URL"

reset_stub
"$PLUGIN_DIR/service-action" post-backup "$REDIS_DS" "$REDIS_SVC" "$REDIS_BUCKET" success >/dev/null
assert_eq "1" "$(stub_call_count)" "redis target dispatches once"
assert_eq "$REDIS_URL" "$(cat "$STUB_STATE_DIR/last_env_url")" "redis target receives its own URL"

# unset removes target and subsequent unset fails nonzero
"$PLUGIN_DIR/subcommands/unset" "$PRIMARY_DS" "$PRIMARY_SVC" "$SECONDARY_BUCKET" >/dev/null
report_after_unset="$("$PLUGIN_DIR/subcommands/report")"
assert_not_contains "$report_after_unset" "$SECONDARY_BUCKET" "unset removes target from report"

if "$PLUGIN_DIR/subcommands/unset" "$PRIMARY_DS" "$PRIMARY_SVC" "$SECONDARY_BUCKET" >/dev/null 2>&1; then
  fail "subsequent unset on removed target should fail nonzero"
else
  pass "subsequent unset on removed target fails nonzero"
fi

# ---------------------------------------------------------------------------
# 3. set validation & leak resistance
# ---------------------------------------------------------------------------
ARGV_SECRET="https://uptime.example.com/api/push/leaked-argv-secret-999"
argv_rc=0
argv_out="$(
  "$PLUGIN_DIR/subcommands/set" "$PRIMARY_DS" "$PRIMARY_SVC" "$PRIMARY_BUCKET" "$ARGV_SECRET" </dev/null 2>&1
)" || argv_rc=$?
if [[ "$argv_rc" -ne 0 ]]; then
  pass "set with 4th argument fails nonzero"
else
  fail "set with 4th argument should fail nonzero"
fi
assert_not_contains "$argv_out" "leaked-argv-secret-999" "set error on 4th arg does not leak secret URL"

run_bad_set_stdin() {
  local label="$1"
  local input_data="$2"
  local secret_marker="$3"
  local ds="${4:-$PRIMARY_DS}"
  local svc="${5:-$PRIMARY_SVC}"
  local bkt="${6:-test-bad-bucket}"
  local rc=0
  local out=""

  out="$(
    printf '%b' "$input_data" |
      "$PLUGIN_DIR/subcommands/set" "$ds" "$svc" "$bkt" 2>&1
  )" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    pass "$label fails nonzero"
  else
    fail "$label should fail nonzero"
  fi
  if [[ -n "$secret_marker" ]]; then
    assert_not_contains "$out" "$secret_marker" "$label does not echo secret input"
  fi
}

run_bad_set_stdin "set rejects http:// URL" "http://uptime.example.com/api/push/secret-http-1\n" "secret-http-1"
run_bad_set_stdin "set rejects bare https://" "https://\n" ""
run_bad_set_stdin "set rejects https:// without host" "https:///secret-nohost-1\n" "secret-nohost-1"
run_bad_set_stdin "set rejects empty stdin" "" ""
run_bad_set_stdin "set rejects whitespace in URL" "https://uptime.example.com/api/push/secret space\n" "secret space"
run_bad_set_stdin "set rejects multiline URL" "https://uptime.example.com/secret-multi-1\nhttps://uptime.example.com/secret-multi-2\n" "secret-multi-"
run_bad_set_stdin "set rejects invalid datastore" "https://uptime.example.com/api/push/secret-ds-1\n" "secret-ds-1" "Bad_DS" "$PRIMARY_SVC" "bkt"
run_bad_set_stdin "set rejects invalid service" "https://uptime.example.com/api/push/secret-svc-1\n" "secret-svc-1" "$PRIMARY_DS" ".." "bkt"
run_bad_set_stdin "set rejects invalid bucket" "https://uptime.example.com/api/push/secret-bkt-1\n" "secret-bkt-1" "$PRIMARY_DS" "$PRIMARY_SVC" "bad bucket"

# Closed/empty stdin fails immediately without hanging
empty_rc=0
"$PLUGIN_DIR/subcommands/set" "$PRIMARY_DS" "$PRIMARY_SVC" "empty-stdin-bucket" </dev/null >/dev/null 2>&1 || empty_rc=$?
if [[ "$empty_rc" -ne 0 ]]; then
  pass "set fails cleanly on closed/empty stdin"
else
  fail "set should fail on closed/empty stdin"
fi

# TTY stdin fails cleanly without hanging (via python3 pty with short timeout)
tty_result="$(
  python3 - "$PLUGIN_DIR/subcommands/set" "$PRIMARY_DS" "$PRIMARY_SVC" "tty-bucket" <<'PY'
import os
import pty
import subprocess
import sys

cmd = sys.argv[1:]
master_fd, slave_fd = pty.openpty()
try:
    proc = subprocess.Popen(
        cmd,
        stdin=slave_fd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        close_fds=True,
    )
    os.close(slave_fd)
    try:
        out, err = proc.communicate(timeout=5)
        print(f"RC={proc.returncode}")
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        print("TIMEOUT")
finally:
    try:
        os.close(master_fd)
    except OSError:
        pass
PY
)"
if [[ "$tty_result" == RC=* && "$tty_result" != "RC=0" ]]; then
  pass "set fails cleanly without hanging when stdin is a TTY ($tty_result)"
else
  fail "set should fail without hanging when stdin is a TTY (got '$tty_result')"
fi

# ---------------------------------------------------------------------------
# 4. service-action matching & stub HTTP client verification
# ---------------------------------------------------------------------------
reset_stub
match_err_file="$TMP_ROOT/match.err"
match_out="$(
  "$PLUGIN_DIR/service-action" post-backup "$PRIMARY_DS" "$PRIMARY_SVC" "$PRIMARY_BUCKET" success 2>"$match_err_file"
)"
match_err="$(cat "$match_err_file")"
assert_eq "1" "$(stub_call_count)" "matching post-backup success makes exactly 1 curl call"
assert_contains "$match_out" "200" "matching post-backup logs HTTP status"
assert_not_contains "$match_out" "$PRIMARY_SECRET_2" "matching post-backup stdout does not contain URL token"
assert_not_contains "$match_err" "$PRIMARY_SECRET_2" "matching post-backup stderr does not contain URL token"
assert_eq "$PRIMARY_URL_2" "$(cat "$STUB_STATE_DIR/last_env_url")" "HEARTBEAT_URL env var contains exact target URL"

expected_args=(
  "--silent"
  "--fail"
  "--globoff"
  "--request"
  "GET"
  "--proto"
  "=https"
  "--proto-redir"
  "=https"
  "--max-time"
  "10"
  "--output"
  "/dev/null"
  "--write-out"
  "%{http_code}"
  "--variable"
  "%HEARTBEAT_URL"
  "--expand-url"
  "{{HEARTBEAT_URL}}"
)

actual_args=()
while IFS= read -r line; do
  actual_args+=("$line")
done <"$STUB_STATE_DIR/last_args"

assert_eq "${#expected_args[@]}" "${#actual_args[@]}" "curl receives exact expected argument count"
args_match=true
for idx in "${!expected_args[@]}"; do
  if [[ "${actual_args[$idx]:-}" != "${expected_args[$idx]}" ]]; then
    args_match=false
    fail "curl arg[$idx] expected '${expected_args[$idx]}', got '${actual_args[$idx]:-}'"
  fi
done
if [[ "$args_match" == true ]]; then
  pass "curl receives exact expected flags and expand-url placeholders"
fi
assert_not_contains "$(cat "$STUB_STATE_DIR/last_args")" "$PRIMARY_SECRET_2" "URL secret is never in curl CLI arguments"

# Verify HTTP 204 No Content is accepted as success
reset_stub
export STUB_CURL_EXIT=0
export STUB_CURL_HTTP_CODE=204
rc204=0
out204="$(
  "$PLUGIN_DIR/service-action" post-backup "$PRIMARY_DS" "$PRIMARY_SVC" "$PRIMARY_BUCKET" success 2>&1
)" || rc204=$?
assert_eq "0" "$rc204" "HTTP 204 returns exit 0"
assert_contains "$out204" "HTTP 204" "HTTP 204 logs success status"
assert_not_contains "$out204" "$PRIMARY_SECRET_2" "HTTP 204 output does not contain URL token"

# Non-matching invocations: 0 calls and exit 0
check_no_dispatch() {
  local label="$1"
  shift
  reset_stub
  local rc=0
  "$PLUGIN_DIR/service-action" "$@" >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "$label exits 0"
  assert_eq "0" "$(stub_call_count)" "$label makes 0 curl calls"
}

check_no_dispatch "failure status" post-backup "$PRIMARY_DS" "$PRIMARY_SVC" "$PRIMARY_BUCKET" failure
check_no_dispatch "event post-create" post-create "$PRIMARY_DS" "$PRIMARY_SVC" "$PRIMARY_BUCKET" success
check_no_dispatch "event pre-backup" pre-backup "$PRIMARY_DS" "$PRIMARY_SVC" "$PRIMARY_BUCKET" success
check_no_dispatch "event post-link" post-link "$PRIMARY_DS" "$PRIMARY_SVC" "$PRIMARY_BUCKET" success
check_no_dispatch "wrong datastore" post-backup redis "$PRIMARY_SVC" "$PRIMARY_BUCKET" success
check_no_dispatch "wrong service" post-backup "$PRIMARY_DS" other_service "$PRIMARY_BUCKET" success
check_no_dispatch "wrong bucket" post-backup "$PRIMARY_DS" "$PRIMARY_SVC" other-bucket success
check_no_dispatch "prefix bucket" post-backup "$PRIMARY_DS" "$PRIMARY_SVC" "movie-tickets-database-backups" success
check_no_dispatch "superstring bucket" post-backup "$PRIMARY_DS" "$PRIMARY_SVC" "${PRIMARY_BUCKET}-other" success
check_no_dispatch "0 args"
check_no_dispatch "1 arg" post-backup
check_no_dispatch "4 args" post-backup "$PRIMARY_DS" "$PRIMARY_SVC" "$PRIMARY_BUCKET"
check_no_dispatch "6 args" post-backup "$PRIMARY_DS" "$PRIMARY_SVC" "$PRIMARY_BUCKET" success extra
check_no_dispatch "empty args" "" "" "" "" ""
check_no_dispatch "unconfigured/unset target" post-backup "$PRIMARY_DS" "$PRIMARY_SVC" "$SECONDARY_BUCKET" success

# ---------------------------------------------------------------------------
# 5. Error & timeout handling + zero leakage under DOKKU_TRACE=1
# ---------------------------------------------------------------------------
# Stub HTTP 500
reset_stub
export STUB_CURL_EXIT=22
export STUB_CURL_HTTP_CODE=500
err500_file="$TMP_ROOT/err500.log"
out500_file="$TMP_ROOT/out500.log"
rc500=0
DOKKU_TRACE=1 "$PLUGIN_DIR/service-action" post-backup "$PRIMARY_DS" "$PRIMARY_SVC" "$PRIMARY_BUCKET" success >"$out500_file" 2>"$err500_file" || rc500=$?
if [[ "$rc500" -ne 0 ]]; then
  pass "stub HTTP 500 causes service-action to exit nonzero"
else
  fail "stub HTTP 500 should cause service-action to exit nonzero"
fi
err500="$(cat "$err500_file")"
out500="$(cat "$out500_file")"
assert_contains "$err500" "500" "stub HTTP 500 logs warning to stderr"
assert_not_contains "$err500" "$PRIMARY_SECRET_2" "stub HTTP 500 stderr does not leak URL under DOKKU_TRACE=1"
assert_not_contains "$out500" "$PRIMARY_SECRET_2" "stub HTTP 500 stdout does not leak URL under DOKKU_TRACE=1"

# Stub HTTP 302 (exit 0 from curl, stdout 302 -> non-2xx must fail!)
reset_stub
export STUB_CURL_EXIT=0
export STUB_CURL_HTTP_CODE=302
err302_file="$TMP_ROOT/err302.log"
out302_file="$TMP_ROOT/out302.log"
rc302=0
DOKKU_TRACE=1 "$PLUGIN_DIR/service-action" post-backup "$PRIMARY_DS" "$PRIMARY_SVC" "$PRIMARY_BUCKET" success >"$out302_file" 2>"$err302_file" || rc302=$?
if [[ "$rc302" -ne 0 ]]; then
  pass "stub HTTP 302 causes service-action to exit nonzero"
else
  fail "stub HTTP 302 should cause service-action to exit nonzero"
fi
err302="$(cat "$err302_file")"
out302="$(cat "$out302_file")"
assert_contains "$err302" "302" "stub HTTP 302 logs warning to stderr"
assert_not_contains "$err302" "$PRIMARY_SECRET_2" "stub HTTP 302 stderr does not leak URL under DOKKU_TRACE=1"
assert_not_contains "$out302" "$PRIMARY_SECRET_2" "stub HTTP 302 stdout does not leak URL under DOKKU_TRACE=1"

# Stub timeout (exit 28, stdout 000)
reset_stub
export STUB_CURL_EXIT=28
export STUB_CURL_HTTP_CODE=000
err28_file="$TMP_ROOT/err28.log"
out28_file="$TMP_ROOT/out28.log"
rc28=0
DOKKU_TRACE=1 "$PLUGIN_DIR/service-action" post-backup "$PRIMARY_DS" "$PRIMARY_SVC" "$PRIMARY_BUCKET" success >"$out28_file" 2>"$err28_file" || rc28=$?
if [[ "$rc28" -ne 0 ]]; then
  pass "stub timeout causes service-action to exit nonzero"
else
  fail "stub timeout should cause service-action to exit nonzero"
fi
err28="$(cat "$err28_file")"
out28="$(cat "$out28_file")"
assert_contains "$err28" "timed out" "stub timeout logs timeout warning to stderr"
assert_not_contains "$err28" "$PRIMARY_SECRET_2" "stub timeout stderr does not leak URL under DOKKU_TRACE=1"
assert_not_contains "$out28" "$PRIMARY_SECRET_2" "stub timeout stdout does not leak URL under DOKKU_TRACE=1"

# Real curl timeout test against local Python TCP socket stall server
STALL_PORT_FILE="$TMP_ROOT/stall_port"
python3 - "$STALL_PORT_FILE" <<'PY' &
import socket
import sys
import time

port_file = sys.argv[1]
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(5)
port = srv.getsockname()[1]
with open(port_file, "w", encoding="utf-8") as fh:
    fh.write(str(port))

conns = []
try:
    while True:
        conn, _ = srv.accept()
        conns.append(conn)
except Exception:
    pass
finally:
    for c in conns:
        try:
            c.close()
        except Exception:
            pass
    srv.close()
PY
STALL_SERVER_PID=$!

for _ in $(seq 1 50); do
  if [[ -s "$STALL_PORT_FILE" ]]; then
    break
  fi
  sleep 0.1
done

if [[ ! -s "$STALL_PORT_FILE" ]]; then
  fail "python TCP stall server failed to bind port"
else
  STALL_PORT="$(cat "$STALL_PORT_FILE")"
  STALL_SECRET="super-secret-token-never-leak"
  STALL_URL="https://127.0.0.1:${STALL_PORT}/${STALL_SECRET}"
  printf '%s\n' "$STALL_URL" |
    "$PLUGIN_DIR/subcommands/set" postgres stall_test_db stall-bucket >/dev/null

  stall_out_file="$TMP_ROOT/stall.out"
  stall_err_file="$TMP_ROOT/stall.err"
  stall_rc=0
  DOKKU_TRACE=1 BACKUP_HEARTBEAT_CURL_BIN=curl BACKUP_HEARTBEAT_TIMEOUT=1 \
    "$PLUGIN_DIR/service-action" post-backup postgres stall_test_db stall-bucket success \
    >"$stall_out_file" 2>"$stall_err_file" || stall_rc=$?

  if [[ "$stall_rc" -ne 0 ]]; then
    pass "real curl timeout against stall server exits nonzero"
  else
    fail "real curl timeout against stall server should exit nonzero"
  fi
  stall_out="$(cat "$stall_out_file")"
  stall_err="$(cat "$stall_err_file")"
  assert_contains "$stall_err" "timed out" "real curl timeout logs timeout warning"
  assert_contains "$stall_err" "curl exit 28" "real curl timeout reports curl exit 28"
  assert_not_contains "$stall_out" "$STALL_SECRET" "real curl timeout stdout does not leak URL under DOKKU_TRACE=1"
  assert_not_contains "$stall_err" "$STALL_SECRET" "real curl timeout stderr does not leak URL under DOKKU_TRACE=1"

  # Verify --globoff prevents curl globbing failures on '['/']'/'{'/'}' in URLs
  GLOB_SECRET="globoff-secret-token-777"
  GLOB_URL="https://127.0.0.1:${STALL_PORT}/push?meta[env]=prod&x={a,b}&t=${GLOB_SECRET}"
  printf '%s\n' "$GLOB_URL" |
    "$PLUGIN_DIR/subcommands/set" postgres stall_glob_db stall-glob-bucket >/dev/null
  glob_out_file="$TMP_ROOT/glob.out"
  glob_err_file="$TMP_ROOT/glob.err"
  glob_rc=0
  DOKKU_TRACE=1 BACKUP_HEARTBEAT_CURL_BIN=curl BACKUP_HEARTBEAT_TIMEOUT=1 \
    "$PLUGIN_DIR/service-action" post-backup postgres stall_glob_db stall-glob-bucket success \
    >"$glob_out_file" 2>"$glob_err_file" || glob_rc=$?
  if [[ "$glob_rc" -ne 0 ]]; then
    pass "real curl with glob chars against stall server exits nonzero on timeout"
  else
    fail "real curl with glob chars against stall server should exit nonzero on timeout"
  fi
  glob_out="$(cat "$glob_out_file")"
  glob_err="$(cat "$glob_err_file")"
  assert_contains "$glob_err" "curl exit 28" "real curl with '['/']'/'{'/'}' reaches timeout (exit 28) instead of globbing error (exit 3)"
  assert_not_contains "$glob_out" "$GLOB_SECRET" "real curl globoff stdout does not leak URL under DOKKU_TRACE=1"
  assert_not_contains "$glob_err" "$GLOB_SECRET" "real curl globoff stderr does not leak URL under DOKKU_TRACE=1"
fi

kill "$STALL_SERVER_PID" 2>/dev/null || true
wait "$STALL_SERVER_PID" 2>/dev/null || true
STALL_SERVER_PID=""

# Simulated dokku-datastore backup caller pattern
reset_stub
export STUB_CURL_EXIT=22
export STUB_CURL_HTTP_CODE=500
sim_backup_caller() {
  local warn_msg=""
  if ! "$PLUGIN_DIR/service-action" post-backup "$PRIMARY_DS" "$PRIMARY_SVC" "$PRIMARY_BUCKET" success 2>"$TMP_ROOT/sim.err"; then
    warn_msg="backup warning: heartbeat failed"
  fi
  printf '%s\n' "$warn_msg"
  return 0
}
sim_rc=0
sim_out="$(sim_backup_caller)" || sim_rc=$?
assert_eq "0" "$sim_rc" "simulated dokku-datastore caller preserves exit code 0 on heartbeat failure"
assert_contains "$sim_out" "backup warning: heartbeat failed" "simulated dokku-datastore caller records non-fatal warning"

# ---------------------------------------------------------------------------
# 6. commands and subcommands/default
# ---------------------------------------------------------------------------
cmd_help="$("$PLUGIN_DIR/commands" help)"
assert_contains "$cmd_help" "    backup-heartbeat:set <datastore> <service> <bucket>," "commands help lists backup-heartbeat:set"
assert_contains "$cmd_help" "    backup-heartbeat:unset <datastore> <service> <bucket>," "commands help lists backup-heartbeat:unset"
assert_contains "$cmd_help" "    backup-heartbeat:report [<datastore> [<service> [<bucket>]]]," "commands help lists backup-heartbeat:report"

plugin_help="$("$PLUGIN_DIR/commands" backup-heartbeat:help)"
assert_contains "$plugin_help" "backup-heartbeat:set" "commands backup-heartbeat:help prints usage"

default_help="$("$PLUGIN_DIR/subcommands/default")"
assert_contains "$default_help" "backup-heartbeat:set" "subcommands/default prints usage"

unknown_rc=0
"$PLUGIN_DIR/commands" backup-heartbeat:nonexistent >/dev/null 2>&1 || unknown_rc=$?
assert_eq "10" "$unknown_rc" "unknown command exits 10 by default"

custom_unknown_rc=0
DOKKU_NOT_IMPLEMENTED_EXIT=42 "$PLUGIN_DIR/commands" backup-heartbeat:nonexistent >/dev/null 2>&1 || custom_unknown_rc=$?
assert_eq "42" "$custom_unknown_rc" "unknown command honors DOKKU_NOT_IMPLEMENTED_EXIT"

# ---------------------------------------------------------------------------
# 7. Edge cases: CRLF, 8192-byte URL boundary, DOKKU_TRACE=1 on set, Dokku argv
# ---------------------------------------------------------------------------
# CRLF (\r\n) stdin handling
CRLF_SECRET="crlf-secret-token-888"
CRLF_URL="https://uptime.example.com/api/push/${CRLF_SECRET}"
printf '%s\r\n' "$CRLF_URL" |
  "$PLUGIN_DIR/subcommands/set" postgres crlf_db crlf-bucket >/dev/null
reset_stub
"$PLUGIN_DIR/service-action" post-backup postgres crlf_db crlf-bucket success >/dev/null
assert_eq "$CRLF_URL" "$(cat "$STUB_STATE_DIR/last_env_url")" "CRLF stdin strips CR and dispatches clean URL"

# Exact 8192-byte URL with \r\n succeeds; 8193-byte URL fails without leaking
URL_PREFIX="https://uptime.example.com/api/push/"
URL_8192_PAD_LEN=$((8192 - ${#URL_PREFIX}))
URL_8192_PAD="$(python3 -c "print('a' * ${URL_8192_PAD_LEN})")"
URL_8192="${URL_PREFIX}${URL_8192_PAD}"
URL_8193="${URL_8192}z"

rc_8192=0
printf '%s\r\n' "$URL_8192" |
  "$PLUGIN_DIR/subcommands/set" postgres max_len_db max-len-bucket >/dev/null 2>&1 || rc_8192=$?
assert_eq "0" "$rc_8192" "exact 8192-byte URL with CRLF succeeds on set"
reset_stub
"$PLUGIN_DIR/service-action" post-backup postgres max_len_db max-len-bucket success >/dev/null
assert_eq "$URL_8192" "$(cat "$STUB_STATE_DIR/last_env_url")" "exact 8192-byte URL dispatches intact"

rc_8193=0
out_8193="$(
  printf '%s\n' "$URL_8193" |
    "$PLUGIN_DIR/subcommands/set" postgres over_len_db over-len-bucket 2>&1
)" || rc_8193=$?
if [[ "$rc_8193" -ne 0 ]]; then
  pass "8193-byte URL fails nonzero on set"
else
  fail "8193-byte URL should fail nonzero on set"
fi
assert_not_contains "$out_8193" "$URL_8192_PAD" "8193-byte URL rejection does not leak URL"

# DOKKU_TRACE=1 during subcommands/set does not leak URL
TRACE_SET_SECRET="trace-set-secret-token-999"
TRACE_SET_URL="https://uptime.example.com/api/push/${TRACE_SET_SECRET}"
trace_set_out_file="$TMP_ROOT/trace_set.out"
trace_set_err_file="$TMP_ROOT/trace_set.err"
trace_set_rc=0
printf '%s\n' "$TRACE_SET_URL" |
  DOKKU_TRACE=1 "$PLUGIN_DIR/subcommands/set" postgres trace_set_db trace-set-bucket \
    >"$trace_set_out_file" 2>"$trace_set_err_file" || trace_set_rc=$?
assert_eq "0" "$trace_set_rc" "subcommands/set succeeds with DOKKU_TRACE=1"
assert_not_contains "$(cat "$trace_set_out_file")" "$TRACE_SET_SECRET" "subcommands/set stdout does not leak URL under DOKKU_TRACE=1"
assert_not_contains "$(cat "$trace_set_err_file")" "$TRACE_SET_SECRET" "subcommands/set stderr does not leak URL under DOKKU_TRACE=1"

# Dokku-style subcommand argv dispatch (leading subcommand name)
DOKKU_STYLE_SECRET="dokku-argv-secret-101"
DOKKU_STYLE_URL="https://uptime.example.com/api/push/${DOKKU_STYLE_SECRET}"
printf '%s\n' "$DOKKU_STYLE_URL" |
  "$PLUGIN_DIR/subcommands/set" backup-heartbeat:set postgres dokku_argv_db dokku-argv-bucket >/dev/null
dokku_style_report="$("$PLUGIN_DIR/subcommands/report" backup-heartbeat:report postgres dokku_argv_db dokku-argv-bucket)"
assert_contains "$dokku_style_report" "postgres dokku_argv_db dokku-argv-bucket (url configured)" "Dokku-style subcommands/report works"
assert_not_contains "$dokku_style_report" "$DOKKU_STYLE_SECRET" "Dokku-style subcommands/report never leaks URL"
"$PLUGIN_DIR/subcommands/unset" backup-heartbeat:unset postgres dokku_argv_db dokku-argv-bucket >/dev/null
dokku_style_after_unset="$("$PLUGIN_DIR/subcommands/report" backup-heartbeat:report postgres dokku_argv_db dokku-argv-bucket)"
assert_contains "$dokku_style_after_unset" "No backup heartbeats configured" "Dokku-style subcommands/unset removes target"

# ---------------------------------------------------------------------------
# 8. Dokku core common/functions integration (DOKKU_TRACE unset & DOKKU_TRACE=1)
# ---------------------------------------------------------------------------
MOCK_DOKKU_CORE="$TMP_ROOT/dokku-core"
mkdir -p "$MOCK_DOKKU_CORE/common"
cat >"$MOCK_DOKKU_CORE/common/functions" <<'EOF'
#!/usr/bin/env bash
set -eo pipefail
[[ $DOKKU_TRACE ]] && set -x

dokku_log_info1() {
  echo "-----> $*"
}
dokku_log_verbose() {
  echo "       $*"
}
dokku_log_warn() {
  echo " !     $*" >&2
}
dokku_log_fail() {
  echo " !     $*" >&2
  exit 1
}
EOF

run_dokku_core_suite() {
  local trace_mode="$1"
  local secret="core-funcs-secret-${trace_mode}"
  local url="https://uptime.example.com/api/push/${secret}"
  local core_data="$TMP_ROOT/core-data-${trace_mode}"
  local out_file="$TMP_ROOT/core-${trace_mode}.out"
  local err_file="$TMP_ROOT/core-${trace_mode}.err"
  local rc=0

  (
    export PLUGIN_CORE_AVAILABLE_PATH="$MOCK_DOKKU_CORE"
    export BACKUP_HEARTBEAT_DATA_ROOT="$core_data"
    if [[ "$trace_mode" == "trace" ]]; then
      export DOKKU_TRACE=1
    else
      unset DOKKU_TRACE || true
    fi

    "$PLUGIN_DIR/install"
    "$PLUGIN_DIR/commands" help >/dev/null
    printf '%s\n' "$url" | "$PLUGIN_DIR/subcommands/set" postgres core_db core-bucket
    "$PLUGIN_DIR/subcommands/report" postgres core_db core-bucket
    reset_stub
    "$PLUGIN_DIR/service-action" post-backup postgres core_db core-bucket success
    "$PLUGIN_DIR/subcommands/unset" postgres core_db core-bucket
  ) >"$out_file" 2>"$err_file" || rc=$?

  assert_eq "0" "$rc" "Dokku common/functions suite ($trace_mode) exits 0"
  assert_eq "1" "$(stub_call_count)" "Dokku common/functions suite ($trace_mode) dispatches heartbeat"
  assert_not_contains "$(cat "$out_file")" "$secret" "Dokku common/functions suite ($trace_mode) stdout never leaks URL"
  assert_not_contains "$(cat "$err_file")" "$secret" "Dokku common/functions suite ($trace_mode) stderr never leaks URL"
}

run_dokku_core_suite "unset"
run_dokku_core_suite "trace"

printf '\nSummary: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
if [[ "$FAIL_COUNT" -ne 0 ]]; then
  exit 1
fi
