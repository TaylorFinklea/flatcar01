#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
probe="$repo_dir/config/observability/bin/emit-host-storage-metrics"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/observability-host-probe.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

fail() {
	echo "host storage probe contract: $1" >&2
	exit 1
}

assert() {
	if ! "$@"; then
		fail "assertion failed: $*"
	fi
}

assert_file() {
	[ -f "$1" ] || fail "missing $1"
}

assert_file "$probe"

real_jq=$(command -v jq 2>/dev/null || true)
[ -n "$real_jq" ] || fail "jq is required for the controlled payload assertions"

test_root="$tmp_dir/root"
stub_bin="$test_root/bin"
sysfs_root="$test_root/sys/class/block"
mkdir -p "$stub_bin" "$sysfs_root/sdb" "$sysfs_root/sdc"

cat > "$stub_bin/findmnt" <<'STUB'
#!/bin/sh
if [ "${PROBE_CASE:-happy}" = toctou ]; then
  case "$*" in
    *nvr2*)
      count_file=${PROBE_FINDMNT_COUNT:?}
      count=0
      [ -f "$count_file" ] && count=$(cat "$count_file")
      count=$((count + 1))
      printf '%s\n' "$count" > "$count_file"
      if [ "$count" -ge 2 ]; then
        printf '%s\n' '/dev/disk/by-id/wwn-0xREMOUNTED-part1'
        exit 0
      fi
      ;;
  esac
fi
case "${PROBE_CASE:-happy}" in
  alias)
    case "$*" in *nvr2*) printf '%s\n' /dev/sdc1; exit 0;; esac
    ;;
  absent)
    case "$*" in *nvr2*) exit 1;; esac
    ;;
  wrong)
    case "$*" in *nvr2*) printf '%s\n' '/dev/disk/by-id/wwn-0xWRONG-part1'; exit 0;; esac
    ;;
esac
case "$*" in
  *nvr2*) printf '%s\n' '/dev/disk/by-id/wwn-0x5000000000000002-part1' ;;
  *nvr*) printf '%s\n' '/dev/disk/by-id/wwn-0x5000000000000001-part1' ;;
  *) printf '%s\n' '/' ;;
esac
STUB

cat > "$stub_bin/readlink" <<'STUB'
#!/bin/sh
case "$*" in
  *5000000000000001*) printf '%s\n' /dev/sdb1 ;;
  *5000000000000002*) printf '%s\n' /dev/sdc1 ;;
  *' /') printf '%s\n' /dev/sda3 ;;
  *) printf '%s\n' "$2" ;;
esac
STUB

cat > "$stub_bin/lsblk" <<'STUB'
#!/bin/sh
case "$*" in
  */dev/sdb1*) printf '%s\n' sdb ;;
  */dev/sdc1*) printf '%s\n' sdc ;;
  */dev/sda3*) printf '%s\n' sda ;;
  *) exit 1 ;;
esac
STUB

cat > "$stub_bin/stat" <<'STUB'
#!/bin/sh
case "${PROBE_CASE:-happy}:$*" in
  disappearing:*nvr2*) exit 1 ;;
  overflow-block:*/var/lib/scrypted/nvr2) printf '%s\n' '999999999999999999999 1 4096'; exit 0 ;;
  overflow-free:*/var/lib/scrypted/nvr2) printf '%s\n' '999999999999999999999 999999999999999999998 4096'; exit 0 ;;
  boundary:*/var/lib/scrypted/nvr2) printf '%s\n' '1000000000 1 4096'; exit 0 ;;
  malformed:*/sys/class/block/sdc/stat) exit 0 ;;
  */sys/class/block/sdb/stat|*/sys/class/block/sdc/stat) exit 0 ;;
esac
printf '%s\n' '1000 400 4096'
STUB

cat > "$stub_bin/awk" <<'STUB'
#!/bin/sh
case "${PROBE_CASE:-happy}:$*" in
  malformed:*/sys/class/block/sdc/stat) printf '%s\n' 'bad bad' ;;
  overflow-sectors:*/sys/class/block/sdc/stat) printf '%s\n' '11 21 999999999999999999999 41' ;;
  boundary:*/sys/class/block/sdc/stat) printf '%s\n' '11 21 1000000000 41' ;;
  */sys/class/block/sdb/stat) printf '%s\n' '10 20 30 40' ;;
  */sys/class/block/sdc/stat) printf '%s\n' '11 21 31 41' ;;
  */sys/class/block/sda/stat) printf '%s\n' '12 22 32 42' ;;
  *) exit 1 ;;
esac
STUB

cat > "$stub_bin/date" <<'STUB'
#!/bin/sh
printf '%s\n' 1725000000000000000
STUB

cat > "$stub_bin/jq" <<'STUB'
#!/bin/sh
exec "$PROBE_REAL_JQ" "$@"
STUB

cat > "$stub_bin/curl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$PROBE_CURL_CALLS"
case "${PROBE_CASE:-happy}" in
  post-failure|timeout) exit 28 ;;
esac
for arg in "$@"; do
  case "$arg" in
    @*) cp "${arg#@}" "$PROBE_PAYLOAD" ;;
  esac
done
exit 0
STUB

chmod 0755 "$stub_bin"/*

for tool in findmnt readlink lsblk stat awk date jq curl; do
	assert_file "$stub_bin/$tool"
done

for forbidden in '(^|[[:space:]])mount([[:space:]]|$)' '(^|[[:space:]])umount([[:space:]]|$)' '(^|[[:space:]])fsck([[:space:]]|$)' '(^|[[:space:]])find([[:space:]]|$)' '(^|[[:space:]])ls([[:space:]]|$)' '(^|[[:space:]])du([[:space:]]|$)' '(^|[[:space:]])&([[:space:]]|$)'; do
	if grep -Eq "$forbidden" "$probe"; then
		fail "probe contains forbidden operation: $forbidden"
	fi
done

run_case() {
	case_name=$1
	run_output="$tmp_dir/$case_name.output"
	run_status=0
	: > "$tmp_dir/payload"
	: > "$tmp_dir/curl-calls"
	: > "$tmp_dir/findmnt-count"
	if OBSERVABILITY_HOST_PROBE_TEST_MODE=1 \
		OBSERVABILITY_HOST_PROBE_TEST_ROOT="$test_root" \
		PROBE_REAL_JQ="$real_jq" \
		PROBE_CASE="$case_name" \
		PROBE_PAYLOAD="$tmp_dir/payload" \
		PROBE_CURL_CALLS="$tmp_dir/curl-calls" \
		PROBE_FINDMNT_COUNT="$tmp_dir/findmnt-count" \
		sh "$probe" --test-root "$test_root" >"$run_output" 2>&1; then
		run_status=0
	else
		run_status=$?
	fi
	printf '%s\n' "$run_status"
}

status=$(run_case happy)
[ "$status" -eq 0 ] || fail "happy path failed"
[ "$(wc -l < "$tmp_dir/curl-calls" | tr -d ' ')" -eq 1 ] || fail "happy path must POST exactly once"
grep -Fq -- '--max-time 8' "$tmp_dir/curl-calls" || fail "POST must have a bounded timeout"
grep -Fq -- '--output /dev/null' "$tmp_dir/curl-calls" || fail "POST response body must be discarded"
grep -Fq -- 'http://127.0.0.1:4318/v1/metrics' "$tmp_dir/curl-calls" || fail "POST must target only the loopback homelab gateway"

for forbidden in '/var/lib/scrypted/nvr' '/var/lib/scrypted/nvr2' '5000000000000001' '5000000000000002' '/dev/sdb' '/dev/sdc'; do
	if grep -Fq "$forbidden" "$tmp_dir/payload" || grep -Fq "$forbidden" "$tmp_dir/happy.output"; then
		fail "happy path leaked forbidden source data: $forbidden"
	fi
done

assert "$real_jq" -e '
  (.resourceMetrics | length) == 1 and
  (.resourceMetrics[0].resource.attributes | map(.key) | sort) == ["host.name", "telemetry.synthetic"] and
  (.resourceMetrics[0].resource.attributes[] | select(.key == "host.name").value.stringValue) == "scrypted-nvr" and
  (.resourceMetrics[0].resource.attributes[] | select(.key == "telemetry.synthetic").value.boolValue) == false and
  ([.resourceMetrics[0].scopeMetrics[].metrics[].name] | unique | sort) == [
    "homelab.disk.read.bytes", "homelab.disk.read.operations",
    "homelab.disk.write.bytes", "homelab.disk.write.operations",
    "homelab.filesystem.available.bytes", "homelab.filesystem.capacity.bytes",
    "homelab.filesystem.used.bytes", "homelab.storage.mount.valid"
  ] and
  ([.resourceMetrics[0].scopeMetrics[].metrics[].gauge.dataPoints[].attributes[]?.key] | unique) == ["storage.role"] and
  ([.resourceMetrics[0].scopeMetrics[].metrics[].gauge.dataPoints[].attributes[]?.value.stringValue] | unique | sort) == ["nvr_primary", "nvr_secondary", "os"] and
  all(.resourceMetrics[0].scopeMetrics[].metrics[].gauge.dataPoints[]; ([.asInt, .asDouble] | any(. != null and (type == "number"))))
' "$tmp_dir/payload" >/dev/null || fail "happy path payload contract failed"

status=$(run_case alias)
[ "$status" -eq 0 ] || fail "canonical alias for an approved WWN must be accepted"
assert "$real_jq" -e '
  ([.resourceMetrics[0].scopeMetrics[].metrics[] | select(.name == "homelab.storage.mount.valid") | .gauge.dataPoints[] | select(.attributes[0].value.stringValue == "nvr_secondary") | .asInt] | . == [1]) and
  ([.resourceMetrics[0].scopeMetrics[].metrics[] | select(.name == "homelab.filesystem.capacity.bytes") | .gauge.dataPoints[] | select(.attributes[0].value.stringValue == "nvr_secondary")] | length == 1)
' "$tmp_dir/payload" >/dev/null || fail "canonical alias must emit the approved secondary storage sample"

for case_name in absent wrong disappearing toctou; do
	status=$(run_case "$case_name")
	[ "$status" -eq 0 ] || fail "$case_name must produce a sanitized partial sample"
	assert "$real_jq" -e --arg role nvr_secondary '
    ([.resourceMetrics[0].scopeMetrics[].metrics[] | select(.name == "homelab.storage.mount.valid") | .gauge.dataPoints[] | select(.attributes[0].value.stringValue == $role) | .asInt] | . == [0]) and
    ([.resourceMetrics[0].scopeMetrics[].metrics[] | select(.name != "homelab.storage.mount.valid") | .gauge.dataPoints[] | select(.attributes[0].value.stringValue == $role)] | length == 0)
  ' "$tmp_dir/payload" >/dev/null || fail "$case_name must emit only mount.valid=0 for the failed role"
done

for case_name in malformed post-failure timeout overflow-block overflow-free overflow-sectors; do
	status=$(run_case "$case_name")
	[ "$status" -ne 0 ] || fail "$case_name must fail closed"
	[ ! -s "$tmp_dir/payload" ] || fail "$case_name must not retain a payload"
done

status=$(run_case boundary)
[ "$status" -eq 0 ] || fail "safe numeric boundary must remain representable"
assert "$real_jq" -e 'all(.resourceMetrics[0].scopeMetrics[].metrics[].gauge.dataPoints[]; ([.asInt, .asDouble] | any(. != null and (type == "number") and . >= 0)))' "$tmp_dir/payload" >/dev/null || fail "boundary values must not wrap or become negative"

service="$repo_dir/config/observability/systemd/observability-storage-metrics.service"
timer="$repo_dir/config/observability/systemd/observability-storage-metrics.timer"
if [ -f "$service" ] && [ -f "$timer" ]; then
	[ "$(stat -f '%Lp' "$probe")" = 755 ] || fail "probe must be mode 0755"
	[ "$(stat -f '%Lp' "$service")" = 644 ] || fail "service must be mode 0644"
	[ "$(stat -f '%Lp' "$timer")" = 644 ] || fail "timer must be mode 0644"
	grep -Fqx 'TimeoutStartSec=10s' "$service" || fail "service timeout must be 10 seconds"
	grep -Fqx 'ExecStart=/etc/observability/bin/emit-host-storage-metrics' "$service" || fail "deployed service must use the fixed production invocation"
	if grep -Eq '^(Environment|EnvironmentFile)=' "$service"; then
		fail "deployed service must not expose the test seam or credentials through environment"
	fi
	grep -Fqx 'CapabilityBoundingSet=' "$service" || fail "service must have an empty capability bounding set"
	grep -Fqx 'NoNewPrivileges=true' "$service" || fail "service must set no-new-privileges"
	grep -Fqx 'RestrictAddressFamilies=AF_INET' "$service" || fail "service must restrict address families"
	grep -Fqx 'IPAddressAllow=127.0.0.1' "$service" || fail "service must allow only localhost"
	grep -Fqx 'IPAddressDeny=any' "$service" || fail "service must deny non-localhost addresses"
	grep -Fqx 'MemoryMax=64M' "$service" || fail "service memory cap must be 64 MiB"
	grep -Fqx 'CPUQuota=10%' "$service" || fail "service CPU cap must be 10 percent"
	grep -Fqx 'InaccessiblePaths=/etc/observability/secrets /var/lib/openobserve /var/lib/scrypted/volume' "$service" || fail "service must hide sensitive paths"
	if grep -Eq '^(After|Before|Requires|Wants)=.*(scrypted|nvr|watchtower)' "$service" "$timer"; then
		fail "storage units must not depend on Scrypted, NVR, Watchtower, or recovery"
	fi
	grep -Fqx 'OnBootSec=45s' "$timer" || fail "timer boot delay must be 45 seconds"
	grep -Fqx 'OnUnitActiveSec=30s' "$timer" || fail "timer interval must be 30 seconds"
	grep -Fqx 'AccuracySec=5s' "$timer" || fail "timer accuracy must be 5 seconds"
else
	fail "storage service and timer are missing"
fi

echo 'host storage probe contract: PASS'
