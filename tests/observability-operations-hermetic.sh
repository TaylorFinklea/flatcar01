#!/bin/sh
# Executes the remote transaction logic against a temporary root and stubs.
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/observability-hermetic.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
fail() { echo "hermetic observability operations: $1" >&2; exit 1; }

[ -x "$repo_dir/scripts/observability-operation-lib" ] || fail 'missing canonical operation library'
[ -x "$repo_dir/scripts/observability-remote" ] || fail 'missing shared remote executor'
stub_bin=$tmp_dir/bin
remote_root=$tmp_dir/root
mkdir -p "$stub_bin" "$remote_root/var/lib/scrypted/nvr" "$remote_root/var/lib/scrypted/nvr2"
mkdir -p "$remote_root/etc/observability"
printf 'preexisting-images\n' > "$remote_root/etc/observability/images.env"
chmod 0640 "$remote_root/etc/observability/images.env"
: > "$tmp_dir/calls"

cat > "$stub_bin/mv" <<'STUB'
#!/bin/sh
set -eu
destination=
for argument in "$@"; do destination=$argument; done
if [ "${1:-}" = -T ] && [ "${2:-}" = -n ]; then shift 2; fi
if [ "${OBS_MV_CRASH_AFTER_STAGE_PUBLISH:-}" = 1 ] && [ "$destination" = "${OBS_MV_STAGE_PUBLISH_PATH:-}" ]; then
	/bin/mv "$@"
	exit 1
fi
if [ "${OBS_MV_CRASH_AFTER_PENDING:-}" = 1 ] && [ "$destination" = "${OBS_MV_PENDING_PATH:-}" ]; then
	/bin/mv "$@"
	exit 1
fi
case "$destination" in
*/var/lib/observability/deploy-state/current)
	if [ "${OBS_MV_BARRIER:-}" = 1 ]; then
		barrier_dir=${OBS_MV_BARRIER_DIR:-}
		[ -n "$barrier_dir" ] || exit 2
		mkdir -p "$barrier_dir"
		: > "$barrier_dir/reached"
		iterations=0
		while [ ! -e "$barrier_dir/release" ]; do
			iterations=$((iterations + 1))
			[ "$iterations" -le 10000 ] || exit 2
			/bin/sleep 0.01
		done
	fi
	/bin/mv "$@"
	if [ "${OBS_MV_CRASH_AFTER_CURRENT:-}" = 1 ]; then exit 1; fi
	exit 0
	;;
*) exec /bin/mv "$@";;
esac
STUB

cat > "$stub_bin/rm" <<'STUB'
#!/bin/sh
set -eu
pending=
pending_stage=
for argument in "$@"; do
	case "$argument" in */var/lib/observability/deploy-state/pending) pending=$argument;; esac
done
if [ -n "$pending" ] && [ -f "$pending" ]; then
	IFS='|' read -r pending_source pending_baseline pending_stage_ref pending_extra < "$pending" || :
	case "$pending_stage_ref" in
		stages/*)
			case "$pending_stage_ref" in *..*|*//* ) : ;; *) pending_stage=${pending%/pending}/$pending_stage_ref ;; esac
			;;
	esac
fi
/bin/rm "$@"
if [ -n "$pending" ] && [ "${OBS_RM_CRASH_AFTER_ROLLBACK_PENDING_CLEAR:-}" = 1 ]; then
	if [ -n "$pending_stage" ] && [ -f "$pending_stage/phase" ] && [ "$(/bin/cat "$pending_stage/phase")" = rollback-success ]; then exit 1; fi
fi
exit 0
STUB

cat > "$stub_bin/flock" <<'STUB'
#!/bin/sh
set -eu
[ "${1:-}" = -n ] || exit 2
shift
conflict=1
if [ "${1:-}" = -E ]; then conflict=$2; shift 2; fi
[ "${1:-}" = 9 ] || exit 2
[ -x /usr/bin/python3 ] || exit 2
/usr/bin/python3 - "$conflict" <<'PY'
import fcntl
import sys

try:
    fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit(int(sys.argv[1]))
PY
STUB

cat > "$stub_bin/systemctl" <<'STUB'
#!/bin/sh
case "$1" in
show)
	unit=
	for argument in "$@"; do unit=$argument; done
	active=active pid=42
	[ "${OBS_INACTIVE_UNIT:-}" != "$unit" ] || active=inactive
	[ "${OBS_SCRYPTED_ZERO_PID:-}" != 1 ] || pid=0
	[ "${OBS_SYSTEMCTL_DRIFT:-}" != 1 ] || pid=43
	printf 'ActiveState=%s\nSubState=running\nMainPID=%s\nExecMainStartTimestamp=Sat 2026-01-01\n' "$active" "$pid";;
cat) [ -f "$OBSERVABILITY_REMOTE_ROOT/etc/systemd/system/$2" ];;
is-enabled)
	unit=; for argument in "$@"; do unit=$argument; done
	case ",${OBS_PRIOR_ENABLED:-}," in *,"$unit",*) exit 0;; *) exit 1;; esac;;
is-active)
	unit=; for argument in "$@"; do unit=$argument; done
	[ "${OBS_UNIT_DOWN:-}" != 1 ] || exit 1
	if [ -n "${OBS_PRIOR_ACTIVE:-}" ]; then case ",$OBS_PRIOR_ACTIVE," in *,"$unit",*) exit 0;; *) exit 1;; esac; fi
	exit 0;;
daemon-reload|disable|enable) printf '%s\n' "$*" >> "$OBS_CALLS";;
start)
	printf '%s\n' "$*" >> "$OBS_CALLS"
	if [ "$2" = observability-storage-metrics.timer ] && [ "${OBS_CURRENT_APPEARS_BEFORE_CURRENT_COMMIT:-}" = 1 ]; then
		printf '%s\n' "$OBS_FOREIGN_CURRENT" > "$OBSERVABILITY_REMOTE_ROOT/var/lib/observability/deploy-state/current"
	fi
	;;
*) exit 0;;
esac
STUB
cat > "$stub_bin/docker" <<'STUB'
#!/bin/sh
case "$1" in
inspect)
	case "$*" in
	*scrypted*)
		pid=42 running=true
		[ "${OBS_SCRYPTED_ZERO_PID:-}" != 1 ] || pid=0
		[ "${OBS_SCRYPTED_STOPPED:-}" != 1 ] || running=false
		case "$*" in *'State.Running'*) printf '%s %s\n' "$running" "$pid";; *) printf 'sha256:scrypted %s 2026-01-01T00:00:00Z 0\n' "$pid";; esac;;
	*openobserve*) memory=3221225472; [ "${OBS_BAD_CAP:-}" != 1 ] || memory=3221225471; printf '%s 2000000000\n' "$memory";;
	*otel-collector*) printf '536870912 1000000000\n';;
	*otel-docker-agent*) printf '402653184 500000000\n';;
	*observe-proxy*) printf '268435456 500000000\n';;
	*) exit 1;; esac;;
pull) printf '%s\n' "$*" >> "$OBS_CALLS"; [ "${OBS_DOCKER_FAIL:-}" != 1 ];;
ps) [ "${OBS_POSTFLIGHT:-}" != 1 ] || printf 'openobserve\notel-collector\notel-docker-agent\nobserve-proxy\n';;
*) exit 0;;
esac
STUB
cat > "$stub_bin/findmnt" <<'STUB'
#!/bin/sh
case "$*" in
*nvr2*) source=/dev/sdc1; target=/var/lib/scrypted/nvr2; [ "${OBS_WRONG_WWN:-}" != 1 ] || source=/dev/disk/by-id/wwn-wrong;;
*) source=/dev/sdb1; target=/var/lib/scrypted/nvr; [ "${OBS_WRONG_WWN:-}" != 1 ] || source=/dev/disk/by-id/wwn-wrong;;
esac
[ "${OBS_BAD_MOUNT_TARGET:-}" != 1 ] || target=/var/lib/scrypted/wrong-target
options=rw,relatime
[ "${OBS_BAD_MOUNT_RW:-}" != 1 ] || options=ro,relatime
printf '%s %s %s\n' "$target" "$source" "$options"
STUB
cat > "$stub_bin/stat" <<'STUB'
#!/bin/sh
case "$*" in
*images.env*) printf '640|501|20\n';;
*nvr*) tick=$(cat "$OBS_STAT_TICK" 2>/dev/null || printf 0); tick=$((tick + 1)); printf '%s\n' "$tick" > "$OBS_STAT_TICK"; printf '170000000%s\n' "$tick";;
*) printf '644|0|0\n';;
esac
STUB
cat > "$stub_bin/chown" <<'STUB'
#!/bin/sh
printf 'chown %s\n' "$*" >> "$OBS_CALLS"
STUB
for name in free df ss getent journalctl systemd-analyze curl; do
	cat > "$stub_bin/$name" <<'STUB'
#!/bin/sh
case "$(basename "$0")" in
free) available=${OBS_MEMORY_AVAILABLE:-8589934592}; printf '              total        used        free      shared  buff/cache   available\nMem: 8589934592 1 1 1 1 %s\n' "$available";;
df) available=${OBS_DISK_AVAILABLE:-17179869184}; printf 'Filesystem 1B-blocks Used Available Capacity Mounted on\nroot 34359738368 1 %s 1%% /\n' "$available";;
ss) printf 'State Recv-Q Send-Q Local Address:Port\n'; case "$*" in *-lun*) [ "${OBS_UDP_443:-}" != 1 ] || printf 'UNCONN 0 0 10.10.10.50:443 0.0.0.0:*\n'; exit 0;; esac; if [ "${OBS_POSTFLIGHT:-}" = 1 ]; then printf 'LISTEN 0 4096 10.10.10.50:443 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:4318 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:4319 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:4320 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:5080 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:5081 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:8888 0.0.0.0:*\nLISTEN 0 4096 10.10.10.50:22 0.0.0.0:*\n'; [ "${OBS_BAD_LISTENER:-}" != 1 ] || printf 'LISTEN 0 4096 10.10.10.50:5080 0.0.0.0:*\n'; else [ "${OBS_PORT_443:-}" != 1 ] || printf 'LISTEN 0 4096 10.10.10.50:443 0.0.0.0:*\n'; [ "${OBS_PORT_4318:-}" != 1 ] || printf 'LISTEN 0 4096 127.0.0.1:4318 0.0.0.0:*\n'; [ "${OBS_PORT_4319:-}" != 1 ] || printf 'LISTEN 0 4096 127.0.0.1:4319 0.0.0.0:*\n'; [ "${OBS_PORT_4320:-}" != 1 ] || printf 'LISTEN 0 4096 127.0.0.1:4320 0.0.0.0:*\n'; [ "${OBS_PORT_5080:-}" != 1 ] || printf 'LISTEN 0 4096 127.0.0.1:5080 0.0.0.0:*\n'; [ "${OBS_PORT_5081:-}" != 1 ] || printf 'LISTEN 0 4096 127.0.0.1:5081 0.0.0.0:*\n'; [ "${OBS_PORT_8888:-}" != 1 ] || printf 'LISTEN 0 4096 127.0.0.1:8888 0.0.0.0:*\n'; fi;;
getent) printf '10.10.10.50 STREAM observe.example.com\n';;
journalctl) [ "${OBS_KERNEL_WARN:-}" = 1 ] && printf 'I/O error\n';;
systemd-analyze)
	case "${1:-}" in
		--root=*) verify_root=${1#--root=};; *) exit 1;;
	esac
	[ "${2:-}" = verify ] || exit 1
	for unit in openobserve.service observe-proxy.service otel-collector.service otel-docker-agent.service observability-storage-metrics.service observability-storage-metrics.timer var-lib-otelcol.mount otelcol-queue-prepare.service; do
		[ -f "$verify_root/etc/systemd/system/$unit" ] || exit 1
	done
	[ -x "$verify_root/etc/observability/bin/run-otel-collector" ] || exit 1
	[ -x "$verify_root/etc/observability/bin/emit-host-storage-metrics" ] || exit 1
	[ "${OBS_SYSTEMD_VERIFY_FAIL:-}" != 1 ] || exit 1
	if [ "${OBS_CURRENT_APPEARS_DURING_STAGE:-}" = 1 ]; then
		printf '%s\n' "$OBS_FOREIGN_CURRENT" > "$OBSERVABILITY_REMOTE_ROOT/var/lib/observability/deploy-state/current"
	fi
	;;
curl) out=; for arg in "$@"; do :; done; while [ "$#" -gt 0 ]; do case "$1" in --output) out=$2; shift 2;; *) url=$1; shift;; esac; done; case "${url:-}" in *8888/metrics) printf 'otelcol_receiver_accepted_metric_points{receiver="otlp",data_type="metric",server_address="127.0.0.1",server_port="4318",service_name="otelcol",service_version="0.159.0",url_path="/v1/metrics"} 1\notelcol_exporter_sent_metric_points{exporter="otlphttp"} 1\notelcol_process_uptime 1\n' > "$out"; [ "${OBS_BAD_METRIC_ATTR:-}" != 1 ] || printf 'otelcol_exporter_queue_size{not_allowed="x"} 1\n' >> "$out";; esac;;
*) exit 0;;
esac
STUB
	chmod 0755 "$stub_bin/$name"
done
cat > "$stub_bin/uname" <<'STUB'
#!/bin/sh
printf 'x86_64\n'
STUB
cat > "$stub_bin/readlink" <<'STUB'
#!/bin/sh
case "$*" in *5000000000000001*|*/dev/sdb1*) printf '%s\n' /dev/sdb1;; *5000000000000002*|*/dev/sdc1*) printf '%s\n' /dev/sdc1;; *) exit 1;; esac
STUB
cat > "$stub_bin/lsblk" <<'STUB'
#!/bin/sh
case "$*" in */dev/sdb1*) printf '%s\n' sdb;; */dev/sdc1*) printf '%s\n' sdc;; *) exit 1;; esac
STUB
cat > "$stub_bin/awk" <<'STUB'
#!/bin/sh
case "$*" in
*/sys/class/block/sdb/stat*) value=31;;
*/sys/class/block/sdc/stat*) value=41;;
*) exec /usr/bin/awk "$@";;
esac
if [ "${OBS_RECORDING_AFTER_STACK_STATIC:-}" = 1 ] && grep -Fqx 'start observability-storage-metrics.timer' "$OBS_CALLS"; then
	value=999999
else
	case "${OBS_RECORDING_STALE:-}:${OBS_RECORDING_STATIC:-}:${OBS_RECORDING_STATIC_HIGH:-}" in
	1:*:*|*:1:*) :;;
	*:*:1) value=999999;;
	*) value=$((value + $(cat "$OBS_RECORDING_TICK" 2>/dev/null || printf 0))); printf '%s\n' "$(( $(cat "$OBS_RECORDING_TICK" 2>/dev/null || printf 0) + 1 ))" > "$OBS_RECORDING_TICK";;
	esac
fi
printf '%s\n' "$value"
STUB
cat > "$stub_bin/sleep" <<'STUB'
#!/bin/sh
[ "${1:-}" = 0.01 ] && exec /bin/sleep 0.01
exit 0
STUB
chmod 0755 "$stub_bin/mv" "$stub_bin/rm" "$stub_bin/flock" "$stub_bin/systemctl" "$stub_bin/docker" "$stub_bin/findmnt" "$stub_bin/stat" "$stub_bin/uname" "$stub_bin/chown" "$stub_bin/readlink" "$stub_bin/lsblk" "$stub_bin/awk" "$stub_bin/sleep"
cat > "$stub_bin/du" <<'STUB'
#!/bin/sh
printf '256000 %s\n' "$2"
STUB
cat > "$stub_bin/openssl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$OBS_CALLS"
case "$1" in s_client) printf 'certificate\n';; x509) printf 'notAfter=Dec 31 00:00:00 2030 GMT\n';; *) exit 1;; esac
STUB
cat > "$stub_bin/date" <<'STUB'
#!/bin/sh
printf '1893456000\n'
STUB
chmod 0755 "$stub_bin/du" "$stub_bin/openssl" "$stub_bin/date"

export PATH="$stub_bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export OBS_CALLS="$tmp_dir/calls"
export OBS_STAT_TICK="$tmp_dir/stat-tick"
export OBS_RECORDING_TICK="$tmp_dir/recording-tick"
gtar_bin=/opt/homebrew/bin/gtar
[ -x "$gtar_bin" ] || fail 'GNU tar is required for traversal fixture'
run_remote() { OBSERVABILITY_REMOTE_ROOT="$remote_root" OBSERVABILITY_REMOTE_LIB="$repo_dir/scripts/observability-operation-lib" "$repo_dir/scripts/observability-remote" "$@"; }

# This is the exact program body shipped by the SSH controller: library first,
# then executor. It must not rely on a separately installed library file.
cat "$repo_dir/scripts/observability-operation-lib" "$repo_dir/scripts/observability-remote" > "$tmp_dir/runner"
chmod 0700 "$tmp_dir/runner"
OBSERVABILITY_REMOTE_ROOT="$remote_root" "$tmp_dir/runner" preflight >/dev/null || fail 'concatenated SSH runner rejected'

# Preflight must reject failed Scrypted health, non-progressing exact-device
# write counters, occupied OpenObserve ports, and insufficient headroom.
if (OBS_WRONG_WWN=1 run_remote preflight >/dev/null 2>&1); then fail 'wrong NVR WWN accepted'; fi
if (OBS_BAD_MOUNT_TARGET=1 run_remote preflight >/dev/null 2>&1); then fail 'wrong NVR mount target accepted'; fi
if (OBS_BAD_MOUNT_RW=1 run_remote preflight >/dev/null 2>&1); then fail 'read-only NVR mount accepted'; fi
if (OBS_INACTIVE_UNIT=scrypted.service run_remote preflight >/dev/null 2>&1); then fail 'inactive Scrypted service accepted'; fi
if (OBS_INACTIVE_UNIT=scrypted-watchtower.service run_remote preflight >/dev/null 2>&1); then fail 'inactive Scrypted Watchtower accepted'; fi
if (OBS_SCRYPTED_ZERO_PID=1 run_remote preflight >/dev/null 2>&1); then fail 'zero Scrypted PID accepted'; fi
if (OBS_SCRYPTED_STOPPED=1 run_remote preflight >/dev/null 2>&1); then fail 'stopped Scrypted container accepted'; fi
if (OBS_RECORDING_STALE=1 run_remote preflight >/dev/null 2>&1); then fail 'stale recording counter accepted'; fi
if (OBS_RECORDING_STATIC=1 run_remote preflight >/dev/null 2>&1); then fail 'non-progressing recording counter accepted'; fi
if (OBS_PORT_443=1 run_remote preflight >/dev/null 2>&1); then fail 'occupied 443 accepted'; fi
if (OBS_PORT_4318=1 run_remote preflight >/dev/null 2>&1); then fail 'occupied 4318 accepted'; fi
if (OBS_PORT_4319=1 run_remote preflight >/dev/null 2>&1); then fail 'occupied 4319 accepted'; fi
if (OBS_PORT_4320=1 run_remote preflight >/dev/null 2>&1); then fail 'occupied 4320 accepted'; fi
if (OBS_PORT_5080=1 run_remote preflight >/dev/null 2>&1); then fail 'occupied 5080 accepted'; fi
if (OBS_PORT_5081=1 run_remote preflight >/dev/null 2>&1); then fail 'occupied 5081 accepted'; fi
if (OBS_PORT_8888=1 run_remote preflight >/dev/null 2>&1); then fail 'occupied 8888 accepted'; fi
if (OBS_UDP_443=1 run_remote preflight >/dev/null 2>&1); then fail 'occupied UDP 443 accepted'; fi
if (OBS_MEMORY_AVAILABLE=5502926847 run_remote preflight >/dev/null 2>&1); then fail 'memory below four-container and host-headroom floor accepted'; fi
if (OBS_DISK_AVAILABLE=8858370047 run_remote preflight >/dev/null 2>&1); then fail 'disk below OpenObserve and queue floor accepted'; fi

preflight=$(run_remote preflight)
baseline=$(printf '%s\n' "$preflight" | sed -n 's/^baseline=//p')
preflight_evidence=$(printf '%s\n' "$preflight" | sed -n 's/^preflight_digest=//p')
recording_nvr=$(printf '%s\n' "$preflight" | sed -n 's/^recording_nvr=//p')
recording_nvr2=$(printf '%s\n' "$preflight" | sed -n 's/^recording_nvr2=//p')
[ "$(printf '%s' "$baseline" | wc -c | tr -d ' ')" = 64 ] || fail 'preflight did not create digest'
[ "$(printf '%s' "$preflight_evidence" | wc -c | tr -d ' ')" = 64 ] || fail 'preflight did not bind prerequisite evidence'
[ -n "$recording_nvr" ] && [ -n "$recording_nvr2" ] || fail 'preflight did not create recording baseline'
manifest=$tmp_dir/manifest
. "$repo_dir/scripts/observability-operation-lib"
ops_manifest "$repo_dir" > "$manifest"
source_digest=$(ops_manifest_digest "$manifest")
receipt_contract=$tmp_dir/receipt-contract
printf 'format=observability-preflight-v3\ntarget=test@flatcar.invalid\nsource_digest=%s\nbaseline=%s\npreflight_digest=%s\nrecording_nvr=%s\nrecording_nvr2=%s\norigin=https://observe.example.com\ncertificate_name=observe.example.com\n' "$source_digest" "$baseline" "$preflight_evidence" "$recording_nvr" "$recording_nvr2" > "$receipt_contract"
ops_receipt "$receipt_contract" || fail 'valid receipt rejected'
head -n 8 "$receipt_contract" > "$tmp_dir/receipt-missing"
ops_receipt "$tmp_dir/receipt-missing" >/dev/null 2>&1 && fail 'missing receipt line accepted'
{ sed -n '1,4p' "$receipt_contract"; sed -n '5p' "$receipt_contract"; sed -n '5p' "$receipt_contract"; sed -n '6,9p' "$receipt_contract"; } > "$tmp_dir/receipt-duplicate"
ops_receipt "$tmp_dir/receipt-duplicate" >/dev/null 2>&1 && fail 'duplicate receipt line accepted'
{ sed -n '1,4p' "$receipt_contract"; sed -n '6p' "$receipt_contract"; sed -n '5p' "$receipt_contract"; sed -n '7,9p' "$receipt_contract"; } > "$tmp_dir/receipt-swapped"
ops_receipt "$tmp_dir/receipt-swapped" >/dev/null 2>&1 && fail 'swapped receipt line accepted'
stage_dir=$tmp_dir/stage
mkdir "$stage_dir"
cp "$manifest" "$stage_dir/.observability-manifest"
set --
while IFS='|' read -r source ignored; do set -- "$@" "$source"; done <<EOF
$(ops_map)
EOF
archive=$tmp_dir/artifacts.tar
(cd "$repo_dir" && tar -cf "$archive" "$@" -C "$stage_dir" .observability-manifest)

# A receipt-era counter can be higher than a fresh static counter. Every
# mutation boundary must nevertheless take a new two-sample advancing proof.
if (OBS_RECORDING_STATIC_HIGH=1 run_remote stage "$source_digest" "$baseline" "$preflight_evidence" "$recording_nvr" "$recording_nvr2" < "$archive" >/dev/null 2>&1); then fail 'fresh-static recording accepted before stage'; fi
[ ! -e "$remote_root/var/lib/observability/deploy-state/stages/$source_digest" ] && [ ! -e "$remote_root/var/lib/observability/deploy-state/pending" ] || fail 'static recording check mutated deploy state before stage'
mismatched_source=$(printf '%064d' 3)
if run_remote stage "$mismatched_source" "$baseline" "$preflight_evidence" "$recording_nvr" "$recording_nvr2" < "$archive" >/dev/null 2>&1; then fail 'source digest mismatch accepted'; fi
[ ! -e "$remote_root/var/lib/observability/deploy-state/stages/$mismatched_source" ] || fail 'source digest mismatch retained stage'
# Unit validation is performed against a root-shaped copy of the incoming
# artifacts. A verifier failure must leave the installed target untouched and
# must not publish a pending transaction.
if (OBS_SYSTEMD_VERIFY_FAIL=1 run_remote stage "$source_digest" "$baseline" "$preflight_evidence" "$recording_nvr" "$recording_nvr2" < "$archive" >/dev/null 2>&1); then fail 'failed staged unit verification accepted'; fi
[ "$(cat "$remote_root/etc/observability/images.env")" = preexisting-images ] || fail 'failed staged unit verification installed artifact'
[ ! -e "$remote_root/etc/systemd/system/openobserve.service" ] || fail 'failed staged unit verification installed unit'
[ ! -e "$remote_root/var/lib/observability/deploy-state/stages/$source_digest" ] && [ ! -e "$remote_root/var/lib/observability/deploy-state/pending" ] || fail 'failed staged unit verification published transaction'
run_remote stage "$source_digest" "$baseline" "$preflight_evidence" "$recording_nvr" "$recording_nvr2" < "$archive" >/dev/null || fail 'valid stage rejected'
[ -f "$remote_root/var/lib/observability/deploy-state/pending" ] || fail 'verified stage did not create pending marker'
ops_pointer "$remote_root/var/lib/observability/deploy-state/pending" || fail 'verified stage created malformed pending marker'
[ -f "$remote_root/var/lib/observability/deploy-state/stages/$source_digest/unit-state" ] || fail 'stage did not capture prior unit state'
grep -Fqx 'openobserve.service|absent|0|0' "$remote_root/var/lib/observability/deploy-state/stages/$source_digest/unit-state" >/dev/null || fail 'stage did not record absent OpenObserve unit'
# A valid regenerated manifest for a changed incoming artifact must still be
# bound to the original source digest. Update transaction-manifest column 5 so
# every other stage/transaction check remains valid; only digest binding can
# reject this fixture before bootstrap mutation.
tampered_stage=$remote_root/var/lib/observability/deploy-state/stages/$source_digest
cp "$tampered_stage/manifest" "$tmp_dir/staged-manifest"
cp "$tampered_stage/incoming/config/observability/images.env" "$tmp_dir/staged-images.env"
cp "$tampered_stage/transaction-manifest" "$tmp_dir/staged-transaction-manifest"
printf '# source-digest-specific drift\n' >> "$tampered_stage/incoming/config/observability/images.env"
ops_manifest "$tampered_stage/incoming" > "$tampered_stage/manifest" || fail 'could not regenerate tampered manifest'
tampered_artifact_digest=$(awk -F '|' '$1 == "config/observability/images.env" { print $4 }' "$tampered_stage/manifest")
[ -n "$tampered_artifact_digest" ] || fail 'tampered artifact digest missing'
tampered_source_digest=$(ops_manifest_digest "$tampered_stage/manifest")
[ "$tampered_source_digest" != "$source_digest" ] || fail 'tampered source digest did not change'
ops_manifest "$tampered_stage/incoming" > "$tmp_dir/tampered-expected-manifest" || fail 'tampered manifest source was not valid'
cmp -s "$tampered_stage/manifest" "$tmp_dir/tampered-expected-manifest" || fail 'tampered manifest did not match incoming source'
awk -F '|' -v OFS='|' -v digest="$tampered_artifact_digest" '$1 == "config/observability/images.env" { $5 = digest } { print }' "$tampered_stage/transaction-manifest" > "$tmp_dir/tampered-transaction-manifest"
mv -f "$tmp_dir/tampered-transaction-manifest" "$tampered_stage/transaction-manifest"
awk -F '|' -v digest="$tampered_artifact_digest" '$1 == "config/observability/images.env" { if ($5 != digest) exit 1; found++ } END { exit (found == 1 ? 0 : 1) }' "$tampered_stage/transaction-manifest" || fail 'tampered transaction manifest digest mismatch'
[ "$(cat "$tampered_stage/source.digest")" = "$source_digest" ] || fail 'tamper changed source receipt'
before=$(wc -c < "$tmp_dir/calls")
run_remote start-bootstrap "$source_digest" "$baseline" "$preflight_evidence" >/dev/null 2>&1 && fail 'source-specific manifest drift accepted'
[ "$before" = "$(wc -c < "$tmp_dir/calls")" ] || fail 'source-specific manifest drift mutated target'
mv -f "$tmp_dir/staged-manifest" "$tampered_stage/manifest"
mv -f "$tmp_dir/staged-images.env" "$tampered_stage/incoming/config/observability/images.env"
mv -f "$tmp_dir/staged-transaction-manifest" "$tampered_stage/transaction-manifest"
wrong_preflight=$(printf '%064d' 9)
before=$(wc -c < "$tmp_dir/calls")
run_remote start-bootstrap "$source_digest" "$baseline" "$wrong_preflight" >/dev/null 2>&1 && fail 'substituted preflight receipt accepted'
[ "$before" = "$(wc -c < "$tmp_dir/calls")" ] || fail 'substituted preflight receipt mutated target'
run_remote start-stack "$source_digest" "$baseline" "$preflight_evidence" < /dev/null >/dev/null 2>&1 && fail 'out-of-order stack start accepted'
if (OBS_RECORDING_STATIC_HIGH=1 run_remote start-bootstrap "$source_digest" "$baseline" "$preflight_evidence" >/dev/null 2>&1); then fail 'fresh-static recording accepted before bootstrap'; fi
run_remote start-bootstrap "$source_digest" "$baseline" "$preflight_evidence" >/dev/null || fail 'bootstrap rejected'
if (OBS_RECORDING_STATIC_HIGH=1 run_remote start-stack "$source_digest" "$baseline" "$preflight_evidence" >/dev/null 2>&1); then fail 'fresh-static recording accepted before stack'; fi
run_remote start-stack "$source_digest" "$baseline" "$preflight_evidence" >/dev/null || fail 'stack rejected'
[ -f "$remote_root/var/lib/observability/deploy-state/current" ] || fail 'current marker missing after success'
grep -Eq '^pull docker.io/openobserve/openobserve:v0\.92\.2@sha256:[0-9a-f]{64}$' "$tmp_dir/calls" || fail 'pinned bootstrap pull missing'
grep -Fqx 'enable var-lib-otelcol.mount' "$tmp_dir/calls" >/dev/null || fail 'bootstrap did not enable queue mount'
grep -Fqx 'enable openobserve.service' "$tmp_dir/calls" >/dev/null || fail 'bootstrap did not enable OpenObserve'
for unit in otel-collector.service otel-docker-agent.service observe-proxy.service observability-storage-metrics.timer; do grep -Fqx "enable $unit" "$tmp_dir/calls" >/dev/null || fail "stack did not enable $unit"; done

# Postflight must derive each bounded datum from active probes, including the
# exact configured container caps, listener set, queue upper bound, and TLS
# connection identity. The expected report fields are intentionally absent
# before the remote reporter is implemented.
postflight_report=$(OBS_POSTFLIGHT=1 run_remote postflight "$source_digest" "$baseline" "$preflight_evidence") || fail 'derived postflight rejected healthy fixture'
grep -Fx 'container_caps=openobserve:3221225472:2000000000,otel-collector:536870912:1000000000,otel-docker-agent:402653184:500000000,observe-proxy:268435456:500000000' <<EOF >/dev/null || fail 'postflight did not report exact container caps'
$postflight_report
EOF
grep -Fx 'dns_prerequisite=1' <<EOF >/dev/null || fail 'postflight did not report DNS prerequisite'
$postflight_report
EOF
grep -Fqx 'listener_addresses=10.10.10.50:443,127.0.0.1:4318,127.0.0.1:4319,127.0.0.1:4320,127.0.0.1:5080,127.0.0.1:5081,127.0.0.1:8888' <<EOF >/dev/null || fail 'postflight listener set was not exact'
$postflight_report
EOF
grep -Fqx "s_client -connect 10.10.10.50:443 -servername observe.example.com -verify_return_error -verify_hostname observe.example.com" "$tmp_dir/calls" || fail 'certificate probe did not bind approved LAN identity'
if (OBS_POSTFLIGHT=1 OBS_BAD_LISTENER=1 run_remote postflight "$source_digest" "$baseline" "$preflight_evidence" >/dev/null 2>&1); then fail 'non-loopback observability listener accepted'; fi
if (OBS_POSTFLIGHT=1 OBS_UDP_443=1 run_remote postflight "$source_digest" "$baseline" "$preflight_evidence" >/dev/null 2>&1); then fail 'UDP 443 listener accepted'; fi
if (OBS_POSTFLIGHT=1 OBS_BAD_METRIC_ATTR=1 run_remote postflight "$source_digest" "$baseline" "$preflight_evidence" >/dev/null 2>&1); then fail 'unapproved collector attribute accepted'; fi
OBSERVABILITY_REMOTE_ROOT="$remote_root" OBS_POSTFLIGHT=1 "$repo_dir/scripts/verify-observability-live" postflight test@flatcar.invalid "$receipt_contract" >/dev/null || fail 'local postflight schema parser rejected bounded report'
if (OBSERVABILITY_REMOTE_ROOT="$remote_root" OBS_POSTFLIGHT=1 OBS_BAD_CAP=1 "$repo_dir/scripts/verify-observability-live" postflight test@flatcar.invalid "$receipt_contract" >/dev/null 2>&1); then fail 'postflight parser accepted cap drift'; fi

# A live config change must be detected before another phase mutates target.
printf '# drift\n' >> "$remote_root/etc/observability/images.env"
run_remote postflight "$source_digest" "$baseline" "$preflight_evidence" >/dev/null 2>&1 && fail 'live artifact drift accepted'
: > "$tmp_dir/calls"
run_remote rollback "$source_digest" "$baseline" "$preflight_evidence" >/dev/null || fail 'rollback rejected'
[ "$(cat "$remote_root/etc/observability/images.env")" = preexisting-images ] || fail 'rollback did not restore prior content'
[ "$(/usr/bin/stat -f '%Lp' "$remote_root/etc/observability/images.env")" = 640 ] || fail 'rollback did not restore prior mode'
grep -Fqx "chown 501:20 $remote_root/etc/observability/images.env" "$tmp_dir/calls" >/dev/null || fail 'rollback did not restore prior owner/group'
for unit in openobserve.service observe-proxy.service otel-collector.service otel-docker-agent.service observability-storage-metrics.timer observability-storage-metrics.service var-lib-otelcol.mount otelcol-queue-prepare.service; do grep -Fqx "disable --now $unit" "$tmp_dir/calls" >/dev/null || fail "rollback did not stop absent-prior $unit"; done
grep -E '^(enable|start) ' "$tmp_dir/calls" >/dev/null && fail 'rollback recreated absent-prior enabled or active unit state'
[ ! -e "$remote_root/var/lib/observability/deploy-state/current" ] || fail 'rollback with no prior current left a stale current marker'
[ ! -e "$remote_root/var/lib/observability/deploy-state/pending" ] || fail 'rollback with no prior current left pending marker'

new_root() {
	remote_root=$1
	mkdir -p "$remote_root/var/lib/scrypted/nvr" "$remote_root/var/lib/scrypted/nvr2"
}

# Protected-state drift is an observability rollout failure, but not a reason
# to leave a receipt-bound deployment installed. Rollback restores artifacts
# and unit state first, then reports each protected check without raw state.
new_root "$tmp_dir/rollback-drift"
mkdir -p "$remote_root/etc/observability"
printf 'rollback-drift-original\n' > "$remote_root/etc/observability/images.env"
drift_rollback_preflight=$(run_remote preflight)
drift_rollback_baseline=$(printf '%s\n' "$drift_rollback_preflight" | sed -n 's/^baseline=//p')
drift_rollback_evidence=$(printf '%s\n' "$drift_rollback_preflight" | sed -n 's/^preflight_digest=//p')
drift_rollback_nvr=$(printf '%s\n' "$drift_rollback_preflight" | sed -n 's/^recording_nvr=//p')
drift_rollback_nvr2=$(printf '%s\n' "$drift_rollback_preflight" | sed -n 's/^recording_nvr2=//p')
run_remote stage "$source_digest" "$drift_rollback_baseline" "$drift_rollback_evidence" "$drift_rollback_nvr" "$drift_rollback_nvr2" < "$archive" >/dev/null || fail 'rollback-drift stage rejected'
run_remote start-bootstrap "$source_digest" "$drift_rollback_baseline" "$drift_rollback_evidence" >/dev/null || fail 'rollback-drift bootstrap rejected'
run_remote start-stack "$source_digest" "$drift_rollback_baseline" "$drift_rollback_evidence" >/dev/null || fail 'rollback-drift stack rejected'
: > "$tmp_dir/calls"
rollback_drift_report=$tmp_dir/rollback-drift-report
if (OBS_SYSTEMCTL_DRIFT=1 OBS_WRONG_WWN=1 OBS_KERNEL_WARN=1 OBS_RECORDING_STATIC_HIGH=1 run_remote rollback "$source_digest" "$drift_rollback_baseline" "$drift_rollback_evidence" > "$rollback_drift_report" 2>&1); then fail 'protected-state drift rollback was not reported'; fi
[ "$(cat "$remote_root/etc/observability/images.env")" = rollback-drift-original ] || fail 'protected-state drift vetoed artifact restoration'
for unit in openobserve.service observe-proxy.service otel-collector.service otel-docker-agent.service observability-storage-metrics.timer observability-storage-metrics.service var-lib-otelcol.mount otelcol-queue-prepare.service; do grep -Fqx "disable --now $unit" "$tmp_dir/calls" >/dev/null || fail "protected-state drift did not stop $unit"; done
grep -Fqx 'rollback=restored-protected-drift' "$rollback_drift_report" >/dev/null || fail 'protected-state drift was not reported after restoration'
grep -Fqx 'scrypted_pid_start_restart_match=0' "$rollback_drift_report" >/dev/null || fail 'rollback did not report Scrypted drift'
grep -Fqx 'mount_identity_rw_match=0' "$rollback_drift_report" >/dev/null || fail 'rollback did not report mount drift'
grep -Fqx 'kernel_warning_delta=1' "$rollback_drift_report" >/dev/null || fail 'rollback did not report kernel drift'
grep -Fqx 'recording_progress=0' "$rollback_drift_report" >/dev/null || fail 'rollback did not report stopped recording after restoration'
[ ! -e "$remote_root/var/lib/observability/deploy-state/current" ] || fail 'protected-state rollback left stale current marker'
[ -f "$remote_root/var/lib/observability/deploy-state/pending" ] || fail 'protected-state rollback lost recovery pending marker'
[ "$(cat "$remote_root/var/lib/observability/deploy-state/stages/$source_digest/phase")" != rollback-success ] || fail 'protected-state rollback committed success marker despite drift'
if run_remote rollback "$source_digest" "$drift_rollback_baseline" "$drift_rollback_evidence" >/dev/null 2>&1; then :; else fail 'protected-state rollback recovery rejected after drift cleared'; fi
[ ! -e "$remote_root/var/lib/observability/deploy-state/pending" ] || fail 'protected-state rollback recovery left pending marker'
[ "$(cat "$remote_root/var/lib/observability/deploy-state/stages/$source_digest/phase")" = rollback-success ] || fail 'protected-state rollback recovery did not commit success marker'

# Existing observability units are not assumed to have the new deployment's
# enablement or activity. Capture each exact unit before install and restore
# its prior state after the tracked files are restored.
new_root "$tmp_dir/unit-state-restore"
for unit in openobserve.service observe-proxy.service otel-collector.service otel-docker-agent.service observability-storage-metrics.timer observability-storage-metrics.service var-lib-otelcol.mount otelcol-queue-prepare.service; do
	mkdir -p "$remote_root/etc/systemd/system"
	printf 'prior-%s\n' "$unit" > "$remote_root/etc/systemd/system/$unit"
done
unit_preflight=$(run_remote preflight)
unit_baseline=$(printf '%s\n' "$unit_preflight" | sed -n 's/^baseline=//p')
unit_evidence=$(printf '%s\n' "$unit_preflight" | sed -n 's/^preflight_digest=//p')
unit_recording_nvr=$(printf '%s\n' "$unit_preflight" | sed -n 's/^recording_nvr=//p')
unit_recording_nvr2=$(printf '%s\n' "$unit_preflight" | sed -n 's/^recording_nvr2=//p')
unit_enabled='var-lib-otelcol.mount,openobserve.service,otel-collector.service,observability-storage-metrics.timer'
unit_active='openobserve.service,observe-proxy.service,otel-docker-agent.service,observability-storage-metrics.service'
OBS_PRIOR_ENABLED="$unit_enabled" OBS_PRIOR_ACTIVE="$unit_active" run_remote stage "$source_digest" "$unit_baseline" "$unit_evidence" "$unit_recording_nvr" "$unit_recording_nvr2" < "$archive" >/dev/null || fail 'prior-unit-state stage rejected'
grep -Fqx 'openobserve.service|present|1|1' "$remote_root/var/lib/observability/deploy-state/stages/$source_digest/unit-state" >/dev/null || fail 'stage did not capture enabled active prior unit'
grep -Fqx 'observe-proxy.service|present|0|1' "$remote_root/var/lib/observability/deploy-state/stages/$source_digest/unit-state" >/dev/null || fail 'stage did not capture disabled active prior unit'
run_remote start-bootstrap "$source_digest" "$unit_baseline" "$unit_evidence" >/dev/null || fail 'prior-unit-state bootstrap rejected'
run_remote start-stack "$source_digest" "$unit_baseline" "$unit_evidence" >/dev/null || fail 'prior-unit-state stack rejected'
: > "$tmp_dir/calls"
run_remote rollback "$source_digest" "$unit_baseline" "$unit_evidence" >/dev/null || fail 'prior-unit-state rollback rejected'
for unit in var-lib-otelcol.mount openobserve.service otel-collector.service observability-storage-metrics.timer; do grep -Fqx "enable $unit" "$tmp_dir/calls" >/dev/null || fail "rollback did not restore enabled $unit"; done
for unit in openobserve.service observe-proxy.service otel-docker-agent.service observability-storage-metrics.service; do grep -Fqx "start $unit" "$tmp_dir/calls" >/dev/null || fail "rollback did not restore active $unit"; done
for unit in observe-proxy.service otel-docker-agent.service observability-storage-metrics.service otelcol-queue-prepare.service; do grep -Fqx "enable $unit" "$tmp_dir/calls" >/dev/null && fail "rollback enabled previously disabled $unit"; done
[ "$(cat "$remote_root/etc/systemd/system/openobserve.service")" = prior-openobserve.service ] || fail 'rollback did not restore prior unit file'

# The post-start check is independent of the receipt-era counter. If writes
# stop while the stack is being started, leave the transaction recoverable and
# require rollback rather than committing current.
new_root "$tmp_dir/post-stack-recording"
post_stack_preflight=$(run_remote preflight)
post_stack_baseline=$(printf '%s\n' "$post_stack_preflight" | sed -n 's/^baseline=//p')
post_stack_evidence=$(printf '%s\n' "$post_stack_preflight" | sed -n 's/^preflight_digest=//p')
post_stack_nvr=$(printf '%s\n' "$post_stack_preflight" | sed -n 's/^recording_nvr=//p')
post_stack_nvr2=$(printf '%s\n' "$post_stack_preflight" | sed -n 's/^recording_nvr2=//p')
run_remote stage "$source_digest" "$post_stack_baseline" "$post_stack_evidence" "$post_stack_nvr" "$post_stack_nvr2" < "$archive" >/dev/null || fail 'post-stack recording stage rejected'
run_remote start-bootstrap "$source_digest" "$post_stack_baseline" "$post_stack_evidence" >/dev/null || fail 'post-stack recording bootstrap rejected'
: > "$tmp_dir/calls"
if (OBS_RECORDING_AFTER_STACK_STATIC=1 run_remote start-stack "$source_digest" "$post_stack_baseline" "$post_stack_evidence" >/dev/null 2>&1); then fail 'fresh-static recording accepted after stack start'; fi
grep -Fqx 'start observability-storage-metrics.timer' "$tmp_dir/calls" >/dev/null || fail 'after-stack recording fixture did not reach final start'
[ -f "$remote_root/var/lib/observability/deploy-state/pending" ] || fail 'after-stack recording failure lost pending recovery marker'
[ ! -e "$remote_root/var/lib/observability/deploy-state/current" ] || fail 'after-stack recording failure committed current marker'
run_remote rollback "$source_digest" "$post_stack_baseline" "$post_stack_evidence" >/dev/null || fail 'after-stack recording rollback rejected'

# A crash after committing a new current pointer but before clearing pending
# must restore the previous legitimate current transaction, not leave a marker
# for artifacts that were just rolled back.
new_root "$tmp_dir/pointer-recovery"
prior_preflight=$(run_remote preflight)
prior_baseline=$(printf '%s\n' "$prior_preflight" | sed -n 's/^baseline=//p')
prior_evidence=$(printf '%s\n' "$prior_preflight" | sed -n 's/^preflight_digest=//p')
prior_recording_nvr=$(printf '%s\n' "$prior_preflight" | sed -n 's/^recording_nvr=//p')
prior_recording_nvr2=$(printf '%s\n' "$prior_preflight" | sed -n 's/^recording_nvr2=//p')
run_remote stage "$source_digest" "$prior_baseline" "$prior_evidence" "$prior_recording_nvr" "$prior_recording_nvr2" < "$archive" >/dev/null || fail 'prior-current stage rejected'
run_remote start-bootstrap "$source_digest" "$prior_baseline" "$prior_evidence" >/dev/null || fail 'prior-current bootstrap rejected'
run_remote start-stack "$source_digest" "$prior_baseline" "$prior_evidence" >/dev/null || fail 'prior-current stack rejected'
prior_current=$(cat "$remote_root/var/lib/observability/deploy-state/current")

new_source_root=$tmp_dir/new-source
mkdir -p "$new_source_root/config"
cp -R "$repo_dir/config/observability" "$new_source_root/config/"
printf '# pointer-recovery generation\n' >> "$new_source_root/config/observability/images.env"
new_manifest=$tmp_dir/new-manifest
ops_manifest "$new_source_root" > "$new_manifest"
new_source_digest=$(ops_manifest_digest "$new_manifest")
new_stage_dir=$tmp_dir/new-stage
mkdir "$new_stage_dir"
cp "$new_manifest" "$new_stage_dir/.observability-manifest"
set --
while IFS='|' read -r source ignored; do set -- "$@" "$source"; done <<EOF
$(ops_map)
EOF
new_archive=$tmp_dir/new-artifacts.tar
(cd "$new_source_root" && tar -cf "$new_archive" "$@" -C "$new_stage_dir" .observability-manifest)
new_preflight=$(run_remote preflight)
new_baseline=$(printf '%s\n' "$new_preflight" | sed -n 's/^baseline=//p')
new_evidence=$(printf '%s\n' "$new_preflight" | sed -n 's/^preflight_digest=//p')
new_recording_nvr=$(printf '%s\n' "$new_preflight" | sed -n 's/^recording_nvr=//p')
new_recording_nvr2=$(printf '%s\n' "$new_preflight" | sed -n 's/^recording_nvr2=//p')
run_remote stage "$new_source_digest" "$new_baseline" "$new_evidence" "$new_recording_nvr" "$new_recording_nvr2" < "$new_archive" >/dev/null || fail 'replacement stage rejected'
[ -f "$remote_root/var/lib/observability/deploy-state/stages/$new_source_digest/prior-current-state" ] || fail 'replacement stage did not record prior current state'
[ -f "$remote_root/var/lib/observability/deploy-state/stages/$new_source_digest/prior-current" ] || fail 'replacement stage did not retain prior current pointer'
[ "$(cat "$remote_root/var/lib/observability/deploy-state/stages/$new_source_digest/prior-current-state")" = present ] || fail 'replacement stage did not record prior current state'
[ "$(cat "$remote_root/var/lib/observability/deploy-state/stages/$new_source_digest/prior-current")" = "$prior_current" ] || fail 'replacement stage did not retain prior current pointer'
run_remote start-bootstrap "$new_source_digest" "$new_baseline" "$new_evidence" >/dev/null || fail 'replacement bootstrap rejected'
if (OBS_MV_CRASH_AFTER_CURRENT=1 run_remote start-stack "$new_source_digest" "$new_baseline" "$new_evidence" >/dev/null 2>&1); then fail 'forced pointer interruption was accepted'; fi
[ -f "$remote_root/var/lib/observability/deploy-state/pending" ] || fail 'interrupted stack lost pending marker'
[ "$(cat "$remote_root/var/lib/observability/deploy-state/current")" != "$prior_current" ] || fail 'interrupted stack did not commit replacement current marker'
run_remote rollback "$new_source_digest" "$new_baseline" "$new_evidence" >/dev/null || fail 'interrupted replacement rollback rejected'
[ "$(cat "$remote_root/var/lib/observability/deploy-state/current")" = "$prior_current" ] || fail 'rollback did not restore prior current marker'
[ ! -e "$remote_root/var/lib/observability/deploy-state/pending" ] || fail 'interrupted rollback left pending marker'
[ "$(cat "$remote_root/etc/observability/images.env")" = "$(cat "$repo_dir/config/observability/images.env")" ] || fail 'interrupted rollback did not restore prior artifacts'

# A failure after final-stage publication but before pending leaves a complete
# unpointed receipt, which an identical-source retry must reclaim safely.
new_root "$tmp_dir/stage-publish-crash"
publish_crash_preflight=$(run_remote preflight)
publish_crash_baseline=$(printf '%s\n' "$publish_crash_preflight" | sed -n 's/^baseline=//p')
publish_crash_evidence=$(printf '%s\n' "$publish_crash_preflight" | sed -n 's/^preflight_digest=//p')
publish_crash_nvr=$(printf '%s\n' "$publish_crash_preflight" | sed -n 's/^recording_nvr=//p')
publish_crash_nvr2=$(printf '%s\n' "$publish_crash_preflight" | sed -n 's/^recording_nvr2=//p')
publish_crash_stage=$remote_root/var/lib/observability/deploy-state/stages/$source_digest
publish_crash_pending=$remote_root/var/lib/observability/deploy-state/pending
if (OBS_MV_CRASH_AFTER_STAGE_PUBLISH=1 OBS_MV_STAGE_PUBLISH_PATH="$publish_crash_stage" run_remote stage "$source_digest" "$publish_crash_baseline" "$publish_crash_evidence" "$publish_crash_nvr" "$publish_crash_nvr2" < "$archive" >/dev/null 2>&1); then fail 'stage publish interruption was accepted'; fi
[ -d "$publish_crash_stage" ] && [ ! -L "$publish_crash_stage" ] || fail 'stage publish interruption lost final receipt'
[ "$(cat "$publish_crash_stage/phase")" = staged ] || fail 'stage publish interruption left wrong phase'
[ ! -e "$publish_crash_pending" ] && [ ! -L "$publish_crash_pending" ] || fail 'stage publish interruption created pending marker'
publish_retry_preflight=$(run_remote preflight)
publish_retry_baseline=$(printf '%s\n' "$publish_retry_preflight" | sed -n 's/^baseline=//p')
publish_retry_evidence=$(printf '%s\n' "$publish_retry_preflight" | sed -n 's/^preflight_digest=//p')
publish_retry_nvr=$(printf '%s\n' "$publish_retry_preflight" | sed -n 's/^recording_nvr=//p')
publish_retry_nvr2=$(printf '%s\n' "$publish_retry_preflight" | sed -n 's/^recording_nvr2=//p')
run_remote stage "$source_digest" "$publish_retry_baseline" "$publish_retry_evidence" "$publish_retry_nvr" "$publish_retry_nvr2" < "$archive" >/dev/null || fail 'identical-source retry did not reclaim published stage'
find "$remote_root/var/lib/observability/deploy-state/retired" -type f -path '*/stage/phase' -print -quit | grep -q . || fail 'published staged evidence was not retired'
grep -Fqx "$source_digest|$publish_retry_baseline|stages/$source_digest" "$publish_crash_pending" || fail 'reclaimed retry pending pointer mismatch'
run_remote rollback "$source_digest" "$publish_retry_baseline" "$publish_retry_evidence" >/dev/null || fail 'reclaimed retry rollback rejected'

# A failure after pending publication preserves both receipt and pending;
# rollback must recover that durable transaction.
new_root "$tmp_dir/pending-mv-crash"
pending_crash_preflight=$(run_remote preflight)
pending_crash_baseline=$(printf '%s\n' "$pending_crash_preflight" | sed -n 's/^baseline=//p')
pending_crash_evidence=$(printf '%s\n' "$pending_crash_preflight" | sed -n 's/^preflight_digest=//p')
pending_crash_nvr=$(printf '%s\n' "$pending_crash_preflight" | sed -n 's/^recording_nvr=//p')
pending_crash_nvr2=$(printf '%s\n' "$pending_crash_preflight" | sed -n 's/^recording_nvr2=//p')
pending_crash_stage=$remote_root/var/lib/observability/deploy-state/stages/$source_digest
pending_crash_pointer=$remote_root/var/lib/observability/deploy-state/pending
if (OBS_MV_CRASH_AFTER_PENDING=1 OBS_MV_PENDING_PATH="$pending_crash_pointer" run_remote stage "$source_digest" "$pending_crash_baseline" "$pending_crash_evidence" "$pending_crash_nvr" "$pending_crash_nvr2" < "$archive" >/dev/null 2>&1); then fail 'pending publish interruption was accepted'; fi
[ -d "$pending_crash_stage" ] && [ ! -L "$pending_crash_stage" ] || fail 'pending publish interruption lost stage'
[ "$(cat "$pending_crash_stage/phase")" = staged ] || fail 'pending publish interruption changed stage phase'
grep -Fqx "$source_digest|$pending_crash_baseline|stages/$source_digest" "$pending_crash_pointer" || fail 'pending publish interruption lost pending pointer'
run_remote rollback "$source_digest" "$pending_crash_baseline" "$pending_crash_evidence" >/dev/null || fail 'pending publish interruption rollback rejected'
[ ! -e "$pending_crash_pointer" ] && [ ! -L "$pending_crash_pointer" ] || fail 'pending publish interruption rollback left pending'
[ "$(cat "$pending_crash_stage/phase")" = rollback-success ] || fail 'pending publish interruption rollback did not commit success'

# A different completed transaction is not this stage's captured prior current.
# Refuse it before unit or artifact mutation rather than overwriting its marker.
different_source_root=$tmp_dir/different-source
mkdir -p "$different_source_root/config"
cp -R "$new_source_root/config/observability" "$different_source_root/config/"
printf '# different-current generation\n' >> "$different_source_root/config/observability/images.env"
different_manifest=$tmp_dir/different-manifest
ops_manifest "$different_source_root" > "$different_manifest"
different_source_digest=$(ops_manifest_digest "$different_manifest")
different_stage_dir=$tmp_dir/different-stage
mkdir "$different_stage_dir"
cp "$different_manifest" "$different_stage_dir/.observability-manifest"
different_archive=$tmp_dir/different-artifacts.tar
(cd "$different_source_root" && tar -cf "$different_archive" "$@" -C "$different_stage_dir" .observability-manifest)
different_preflight=$(run_remote preflight)
different_baseline=$(printf '%s\n' "$different_preflight" | sed -n 's/^baseline=//p')
different_evidence=$(printf '%s\n' "$different_preflight" | sed -n 's/^preflight_digest=//p')
different_recording_nvr=$(printf '%s\n' "$different_preflight" | sed -n 's/^recording_nvr=//p')
different_recording_nvr2=$(printf '%s\n' "$different_preflight" | sed -n 's/^recording_nvr2=//p')
run_remote stage "$different_source_digest" "$different_baseline" "$different_evidence" "$different_recording_nvr" "$different_recording_nvr2" < "$different_archive" >/dev/null || fail 'different-current stage rejected'
printf '%s|%s|stages/%s\n' "$new_source_digest" "$new_baseline" "$new_source_digest" > "$remote_root/var/lib/observability/deploy-state/current"
before=$(wc -c < "$tmp_dir/calls")
if run_remote rollback "$different_source_digest" "$different_baseline" "$different_evidence" >/dev/null 2>&1; then fail 'rollback accepted a different completed current marker'; fi
[ "$before" = "$(wc -c < "$tmp_dir/calls")" ] || fail 'different completed current rollback mutated units'

# Malformed pointer and non-regular archive entries must fail before mutation.
printf 'bad\n' > "$remote_root/var/lib/observability/deploy-state/current"
before=$(wc -c < "$tmp_dir/calls")
run_remote rollback "$source_digest" "$baseline" "$preflight_evidence" >/dev/null 2>&1 && fail 'malformed pointer accepted'
[ "$before" = "$(wc -c < "$tmp_dir/calls")" ] || fail 'malformed pointer mutated units'
ln -s "$repo_dir/config/observability/images.env" "$stage_dir/link"
tar -cf "$tmp_dir/link.tar" -C "$stage_dir" link
run_remote stage "$source_digest" "$baseline" "$preflight_evidence" "$recording_nvr" "$recording_nvr2" < "$tmp_dir/link.tar" >/dev/null 2>&1 && fail 'symlink archive accepted'

# Each adversarial archive receives a fresh target so the failure necessarily
# occurs in stage, not because a prior transaction/pointer is present.
bad_stage() {
	name=$1 archive_file=$2
	new_root "$tmp_dir/bad-$name"
	bad_preflight=$(run_remote preflight)
	bad_baseline=$(printf '%s\n' "$bad_preflight" | sed -n 's/^baseline=//p')
	bad_evidence=$(printf '%s\n' "$bad_preflight" | sed -n 's/^preflight_digest=//p')
	bad_recording_nvr=$(printf '%s\n' "$bad_preflight" | sed -n 's/^recording_nvr=//p')
	bad_recording_nvr2=$(printf '%s\n' "$bad_preflight" | sed -n 's/^recording_nvr2=//p')
	run_remote stage "$source_digest" "$bad_baseline" "$bad_evidence" "$bad_recording_nvr" "$bad_recording_nvr2" < "$archive_file" >/dev/null 2>&1 && fail "malicious archive accepted: $name"
	state="$remote_root/var/lib/observability/deploy-state"
	[ -d "$state/stages" ] || fail "stage was not reached: $name"
	[ ! -e "$state/stages/$source_digest" ] && [ ! -e "$state/pending" ] || fail "failed stage was not cleaned: $name"
}

# Duplicate and traversal members are rejected before extraction. Nonregular
# replacements retain the exact canonical member set, exercising tar-type
# rejection rather than only an extra-member check.
cp "$archive" "$tmp_dir/duplicate.tar"
tar -rf "$tmp_dir/duplicate.tar" -C "$repo_dir" config/observability/images.env
bad_stage duplicate "$tmp_dir/duplicate.tar"
(cd "$repo_dir" && "$gtar_bin" -cf "$tmp_dir/traversal.tar" --transform='s,^,../,' "$@" -C "$stage_dir" .observability-manifest 2>/dev/null)
tar -tf "$tmp_dir/traversal.tar" | grep -q '^../' || fail 'traversal fixture was not created'
bad_stage traversal "$tmp_dir/traversal.tar"
mkdir -p "$tmp_dir/nonregular/config/observability"
cp -R "$repo_dir/config/observability/." "$tmp_dir/nonregular/config/observability"
rm "$tmp_dir/nonregular/config/observability/images.env"
mkfifo "$tmp_dir/nonregular/config/observability/images.env"
cp "$manifest" "$tmp_dir/nonregular/.observability-manifest"
(cd "$tmp_dir/nonregular" && tar -cf "$tmp_dir/fifo.tar" "$@" .observability-manifest)
bad_stage fifo "$tmp_dir/fifo.tar"
rm "$tmp_dir/nonregular/config/observability/images.env"
ln -s /dev/null "$tmp_dir/nonregular/config/observability/images.env"
(cd "$tmp_dir/nonregular" && tar -cf "$tmp_dir/symlink.tar" "$@" .observability-manifest)
bad_stage symlink "$tmp_dir/symlink.tar"

# A bootstrap pull failure leaves a valid pending transaction. An unrelated
# current marker is rejected before mutation rather than being clobbered; once
# absent, pending rollback restores the captured absent-current state.
new_root "$tmp_dir/partial"
partial_preflight=$(run_remote preflight)
partial_baseline=$(printf '%s\n' "$partial_preflight" | sed -n 's/^baseline=//p')
partial_evidence=$(printf '%s\n' "$partial_preflight" | sed -n 's/^preflight_digest=//p')
partial_recording_nvr=$(printf '%s\n' "$partial_preflight" | sed -n 's/^recording_nvr=//p')
partial_recording_nvr2=$(printf '%s\n' "$partial_preflight" | sed -n 's/^recording_nvr2=//p')
run_remote stage "$source_digest" "$partial_baseline" "$partial_evidence" "$partial_recording_nvr" "$partial_recording_nvr2" < "$archive" >/dev/null || fail 'partial stage rejected'
stale_source=$(printf '%064d' 7)
printf '%s|%s|stages/%s\n' "$stale_source" "$partial_baseline" "$stale_source" > "$remote_root/var/lib/observability/deploy-state/current"
if (OBS_DOCKER_FAIL=1 run_remote start-bootstrap "$source_digest" "$partial_baseline" "$partial_evidence" >/dev/null 2>&1); then fail 'partial bootstrap unexpectedly succeeded'; fi
[ -f "$remote_root/var/lib/observability/deploy-state/pending" ] || fail 'partial bootstrap lost pending marker'
before=$(wc -c < "$tmp_dir/calls")
if run_remote rollback "$source_digest" "$partial_baseline" "$partial_evidence" >/dev/null 2>&1; then fail 'rollback accepted unrelated current marker'; fi
[ "$before" = "$(wc -c < "$tmp_dir/calls")" ] || fail 'unrelated current marker rollback mutated units'
rm -f "$remote_root/var/lib/observability/deploy-state/current"
if (OBS_RM_CRASH_AFTER_ROLLBACK_PENDING_CLEAR=1 run_remote rollback "$source_digest" "$partial_baseline" "$partial_evidence" >/dev/null 2>&1); then fail 'rollback interruption unexpectedly succeeded'; fi
[ ! -e "$remote_root/var/lib/observability/deploy-state/pending" ] || fail 'interrupted rollback did not clear pending marker'
[ ! -e "$remote_root/var/lib/observability/deploy-state/current" ] || fail 'interrupted rollback left stale current marker'
[ "$(cat "$remote_root/var/lib/observability/deploy-state/stages/$source_digest/phase")" = rollback-success ] || fail 'interrupted rollback did not commit success marker'

# A failed bootstrap can retry the exact same reviewed source after rollback.
# The fresh preflight receipt binds the retry to current protected state, while
# the successful retry must leave only its completed current pointer.
partial_retry_preflight=$(OBS_SYSTEMCTL_DRIFT=1 run_remote preflight)
partial_retry_baseline=$(printf '%s\n' "$partial_retry_preflight" | sed -n 's/^baseline=//p')
partial_retry_evidence=$(printf '%s\n' "$partial_retry_preflight" | sed -n 's/^preflight_digest=//p')
partial_retry_recording_nvr=$(printf '%s\n' "$partial_retry_preflight" | sed -n 's/^recording_nvr=//p')
partial_retry_recording_nvr2=$(printf '%s\n' "$partial_retry_preflight" | sed -n 's/^recording_nvr2=//p')
(OBS_SYSTEMCTL_DRIFT=1 run_remote stage "$source_digest" "$partial_retry_baseline" "$partial_retry_evidence" "$partial_retry_recording_nvr" "$partial_retry_recording_nvr2" < "$archive") >/dev/null || fail 'identical-source retry stage rejected'
[ -d "$remote_root/var/lib/observability/deploy-state/retired" ] || fail 'identical-source retry did not preserve retired rollback evidence'
find "$remote_root/var/lib/observability/deploy-state/retired" -type f -name rollback-recovery -print -quit | grep -q . || fail 'identical-source retry did not atomically retire rollback evidence'
grep -Fqx "$source_digest|$partial_retry_baseline|stages/$source_digest" "$remote_root/var/lib/observability/deploy-state/pending" || fail 'identical-source retry pending pointer mismatch'
(OBS_SYSTEMCTL_DRIFT=1 run_remote start-bootstrap "$source_digest" "$partial_retry_baseline" "$partial_retry_evidence") >/dev/null || fail 'identical-source retry bootstrap rejected'
(OBS_SYSTEMCTL_DRIFT=1 run_remote start-stack "$source_digest" "$partial_retry_baseline" "$partial_retry_evidence") >/dev/null || fail 'identical-source retry stack rejected'
grep -Fqx "$source_digest|$partial_retry_baseline|stages/$source_digest" "$remote_root/var/lib/observability/deploy-state/current" || fail 'identical-source retry current pointer mismatch'
[ ! -e "$remote_root/var/lib/observability/deploy-state/pending" ] || fail 'identical-source retry left pending marker'
[ "$(cat "$remote_root/var/lib/observability/deploy-state/stages/$source_digest/phase")" = stack-success ] || fail 'identical-source retry did not complete transaction'

# A structurally valid but unrelated current marker appearing during any
# pending phase is rejected without replacing it or losing the pending work.
new_root "$tmp_dir/current-guards"
guard_preflight=$(run_remote preflight)
guard_baseline=$(printf '%s\n' "$guard_preflight" | sed -n 's/^baseline=//p')
guard_evidence=$(printf '%s\n' "$guard_preflight" | sed -n 's/^preflight_digest=//p')
guard_recording_nvr=$(printf '%s\n' "$guard_preflight" | sed -n 's/^recording_nvr=//p')
guard_recording_nvr2=$(printf '%s\n' "$guard_preflight" | sed -n 's/^recording_nvr2=//p')
run_remote stage "$new_source_digest" "$guard_baseline" "$guard_evidence" "$guard_recording_nvr" "$guard_recording_nvr2" < "$new_archive" >/dev/null || fail 'current guard foreign stage rejected'
run_remote start-bootstrap "$new_source_digest" "$guard_baseline" "$guard_evidence" >/dev/null || fail 'current guard foreign bootstrap rejected'
run_remote start-stack "$new_source_digest" "$guard_baseline" "$guard_evidence" >/dev/null || fail 'current guard foreign stack rejected'
guard_current_a=$(cat "$remote_root/var/lib/observability/deploy-state/current")
# Build the unrelated current fixture through its own complete transaction;
# a relabeled copy of another stage cannot prove pointer identity.
guard_foreign_source_root=$tmp_dir/guard-foreign-source
mkdir -p "$guard_foreign_source_root/config"
cp -R "$new_source_root/config/observability" "$guard_foreign_source_root/config/"
printf '# current-guard foreign generation\n' >> "$guard_foreign_source_root/config/observability/images.env"
guard_foreign_manifest=$tmp_dir/guard-foreign-manifest
ops_manifest "$guard_foreign_source_root" > "$guard_foreign_manifest"
guard_foreign_source=$(ops_manifest_digest "$guard_foreign_manifest")
guard_foreign_stage_dir=$tmp_dir/guard-foreign-stage
mkdir "$guard_foreign_stage_dir"
cp "$guard_foreign_manifest" "$guard_foreign_stage_dir/.observability-manifest"
guard_foreign_archive=$tmp_dir/guard-foreign-artifacts.tar
(cd "$guard_foreign_source_root" && tar -cf "$guard_foreign_archive" "$@" -C "$guard_foreign_stage_dir" .observability-manifest)
guard_foreign_preflight=$(run_remote preflight)
guard_foreign_baseline=$(printf '%s\n' "$guard_foreign_preflight" | sed -n 's/^baseline=//p')
guard_foreign_evidence=$(printf '%s\n' "$guard_foreign_preflight" | sed -n 's/^preflight_digest=//p')
guard_foreign_recording_nvr=$(printf '%s\n' "$guard_foreign_preflight" | sed -n 's/^recording_nvr=//p')
guard_foreign_recording_nvr2=$(printf '%s\n' "$guard_foreign_preflight" | sed -n 's/^recording_nvr2=//p')
run_remote stage "$guard_foreign_source" "$guard_foreign_baseline" "$guard_foreign_evidence" "$guard_foreign_recording_nvr" "$guard_foreign_recording_nvr2" < "$guard_foreign_archive" >/dev/null || fail 'distinct foreign stage rejected'
run_remote start-bootstrap "$guard_foreign_source" "$guard_foreign_baseline" "$guard_foreign_evidence" >/dev/null || fail 'distinct foreign bootstrap rejected'
run_remote start-stack "$guard_foreign_source" "$guard_foreign_baseline" "$guard_foreign_evidence" >/dev/null || fail 'distinct foreign stack rejected'
guard_foreign_current=$(cat "$remote_root/var/lib/observability/deploy-state/current")
[ "$guard_foreign_current" = "$guard_foreign_source|$guard_foreign_baseline|stages/$guard_foreign_source" ] || fail 'distinct foreign current pointer mismatch'
guard_foreign_pointer=$guard_foreign_current
before=$(wc -c < "$tmp_dir/calls")
if (OBS_CURRENT_APPEARS_DURING_STAGE=1 OBS_FOREIGN_CURRENT="$guard_current_a" run_remote stage "$source_digest" "$guard_baseline" "$guard_evidence" "$guard_recording_nvr" "$guard_recording_nvr2" < "$archive" >/dev/null 2>&1); then fail 'stage accepted current pointer race'; fi
[ "$before" = "$(wc -c < "$tmp_dir/calls")" ] || fail 'stage current race mutated units'
[ ! -e "$remote_root/var/lib/observability/deploy-state/pending" ] || fail 'stage current race created pending marker'
 [ "$(cat "$remote_root/var/lib/observability/deploy-state/current")" = "$guard_current_a" ] || fail 'stage current race did not preserve foreign current'
printf '%s\n' "$guard_foreign_pointer" > "$remote_root/var/lib/observability/deploy-state/current"
run_remote stage "$source_digest" "$guard_baseline" "$guard_evidence" "$guard_recording_nvr" "$guard_recording_nvr2" < "$archive" >/dev/null || fail 'current guard stage setup rejected'
guard_foreign_current=$guard_current_a
printf '%s\n' "$guard_foreign_current" > "$remote_root/var/lib/observability/deploy-state/current"
before=$(wc -c < "$tmp_dir/calls")
if run_remote start-bootstrap "$source_digest" "$guard_baseline" "$guard_evidence" >/dev/null 2>&1; then fail 'bootstrap accepted unrelated current'; fi
[ "$before" = "$(wc -c < "$tmp_dir/calls")" ] || fail 'bootstrap current guard mutated units'
[ -f "$remote_root/var/lib/observability/deploy-state/pending" ] || fail 'bootstrap current guard lost pending marker'
[ "$(cat "$remote_root/var/lib/observability/deploy-state/current")" = "$guard_foreign_current" ] || fail 'bootstrap current guard replaced foreign current'
printf '%s\n' "$guard_foreign_pointer" > "$remote_root/var/lib/observability/deploy-state/current"
run_remote rollback "$source_digest" "$guard_baseline" "$guard_evidence" >/dev/null || fail 'bootstrap current guard rollback rejected'

guard_preflight=$(run_remote preflight)
guard_baseline=$(printf '%s\n' "$guard_preflight" | sed -n 's/^baseline=//p')
guard_evidence=$(printf '%s\n' "$guard_preflight" | sed -n 's/^preflight_digest=//p')
guard_recording_nvr=$(printf '%s\n' "$guard_preflight" | sed -n 's/^recording_nvr=//p')
guard_recording_nvr2=$(printf '%s\n' "$guard_preflight" | sed -n 's/^recording_nvr2=//p')
(run_remote stage "$source_digest" "$guard_baseline" "$guard_evidence" "$guard_recording_nvr" "$guard_recording_nvr2" < "$archive") >/dev/null || fail 'stack guard stage setup rejected'
(run_remote start-bootstrap "$source_digest" "$guard_baseline" "$guard_evidence") >/dev/null || fail 'stack guard bootstrap setup rejected'
guard_foreign_current=$guard_current_a
printf '%s\n' "$guard_foreign_current" > "$remote_root/var/lib/observability/deploy-state/current"
before=$(wc -c < "$tmp_dir/calls")
if run_remote start-stack "$source_digest" "$guard_baseline" "$guard_evidence" >/dev/null 2>&1; then fail 'stack accepted unrelated current'; fi
[ "$before" = "$(wc -c < "$tmp_dir/calls")" ] || fail 'stack current guard mutated units'
[ -f "$remote_root/var/lib/observability/deploy-state/pending" ] || fail 'stack current guard lost pending marker'
[ "$(cat "$remote_root/var/lib/observability/deploy-state/current")" = "$guard_foreign_current" ] || fail 'stack current guard replaced foreign current'
printf '%s\n' "$guard_foreign_pointer" > "$remote_root/var/lib/observability/deploy-state/current"
run_remote rollback "$source_digest" "$guard_baseline" "$guard_evidence" >/dev/null || fail 'stack current guard rollback rejected'

guard_preflight=$(run_remote preflight)
guard_baseline=$(printf '%s\n' "$guard_preflight" | sed -n 's/^baseline=//p')
guard_evidence=$(printf '%s\n' "$guard_preflight" | sed -n 's/^preflight_digest=//p')
guard_recording_nvr=$(printf '%s\n' "$guard_preflight" | sed -n 's/^recording_nvr=//p')
guard_recording_nvr2=$(printf '%s\n' "$guard_preflight" | sed -n 's/^recording_nvr2=//p')
(run_remote stage "$source_digest" "$guard_baseline" "$guard_evidence" "$guard_recording_nvr" "$guard_recording_nvr2" < "$archive") >/dev/null || fail 'stack commit guard stage setup rejected'
(run_remote start-bootstrap "$source_digest" "$guard_baseline" "$guard_evidence") >/dev/null || fail 'stack commit guard bootstrap setup rejected'
guard_foreign_current=$guard_current_a
before=$(wc -c < "$tmp_dir/calls")
if (OBS_CURRENT_APPEARS_BEFORE_CURRENT_COMMIT=1 OBS_FOREIGN_CURRENT="$guard_foreign_current" run_remote start-stack "$source_digest" "$guard_baseline" "$guard_evidence" >/dev/null 2>&1); then fail 'stack commit accepted current race'; fi
[ -f "$remote_root/var/lib/observability/deploy-state/pending" ] || fail 'stack commit current race lost pending marker'
[ "$(cat "$remote_root/var/lib/observability/deploy-state/current")" = "$guard_foreign_current" ] || fail 'stack commit current race replaced foreign current'
printf '%s\n' "$guard_foreign_pointer" > "$remote_root/var/lib/observability/deploy-state/current"
run_remote rollback "$source_digest" "$guard_baseline" "$guard_evidence" >/dev/null || fail 'stack commit current race rollback rejected'

# Two concurrent mutators must serialize on one deploy-state lock. Process A
# pauses deterministically after the final current-pointer guard and before
# committing current; process B must fail at lock acquisition, not merely lose
# a later phase check or mutate services.
new_root "$tmp_dir/concurrent-lock"
concurrent_preflight=$(run_remote preflight)
concurrent_baseline=$(printf '%s\n' "$concurrent_preflight" | sed -n 's/^baseline=//p')
concurrent_evidence=$(printf '%s\n' "$concurrent_preflight" | sed -n 's/^preflight_digest=//p')
concurrent_recording_nvr=$(printf '%s\n' "$concurrent_preflight" | sed -n 's/^recording_nvr=//p')
concurrent_recording_nvr2=$(printf '%s\n' "$concurrent_preflight" | sed -n 's/^recording_nvr2=//p')
run_remote stage "$source_digest" "$concurrent_baseline" "$concurrent_evidence" "$concurrent_recording_nvr" "$concurrent_recording_nvr2" < "$archive" >/dev/null || fail 'concurrent-lock stage rejected'
run_remote start-bootstrap "$source_digest" "$concurrent_baseline" "$concurrent_evidence" >/dev/null || fail 'concurrent-lock bootstrap rejected'
concurrent_barrier=$tmp_dir/concurrent-barrier
mkdir "$concurrent_barrier"
concurrent_first_log=$tmp_dir/concurrent-first.log
concurrent_second_log=$tmp_dir/concurrent-second.log
: > "$tmp_dir/calls"
(OBS_MV_BARRIER=1 OBS_MV_BARRIER_DIR="$concurrent_barrier" run_remote start-stack "$source_digest" "$concurrent_baseline" "$concurrent_evidence" > "$concurrent_first_log" 2>&1) &
concurrent_first_pid=$!
concurrent_iterations=0
while [ ! -e "$concurrent_barrier/reached" ]; do
	concurrent_iterations=$((concurrent_iterations + 1))
	[ "$concurrent_iterations" -le 10000 ] || fail 'concurrent-lock barrier was not reached'
	sleep 0.01
done
concurrent_calls_before=$(wc -c < "$tmp_dir/calls")
if run_remote start-stack "$source_digest" "$concurrent_baseline" "$concurrent_evidence" > "$concurrent_second_log" 2>&1; then fail 'concurrent second mutator unexpectedly succeeded'; fi
grep -Fqx 'deploy-state is busy' "$concurrent_second_log" || fail 'concurrent second mutator did not fail at lock acquisition'
[ "$concurrent_calls_before" = "$(wc -c < "$tmp_dir/calls")" ] || fail 'concurrent second mutator changed services'
: > "$concurrent_barrier/release"
if wait "$concurrent_first_pid"; then :; else fail 'concurrent first mutator failed'; fi
grep -Fqx 'start-stack=verified' "$concurrent_first_log" || fail 'concurrent first mutator did not complete'
[ "$(cat "$remote_root/var/lib/observability/deploy-state/current")" = "$source_digest|$concurrent_baseline|stages/$source_digest" ] || fail 'concurrent lock current pointer mismatch'
[ ! -e "$remote_root/var/lib/observability/deploy-state/pending" ] || fail 'concurrent lock left pending marker'

# An invalid pending marker fails before any service mutation, even if a stale
# current pointer looks structurally valid.
new_root "$tmp_dir/malformed-pending"
mkdir -p "$remote_root/var/lib/observability/deploy-state"
printf 'malformed\n' > "$remote_root/var/lib/observability/deploy-state/pending"
printf '%s|%s|stages/%s\n' "$stale_source" "$baseline" "$stale_source" > "$remote_root/var/lib/observability/deploy-state/current"
before=$(wc -c < "$tmp_dir/calls")
run_remote rollback "$source_digest" "$baseline" "$preflight_evidence" >/dev/null 2>&1 && fail 'malformed pending accepted'
[ "$before" = "$(wc -c < "$tmp_dir/calls")" ] || fail 'malformed pending mutated units'

# Baseline identity rejects both a protected-service mutation and a newly
# observed kernel storage warning before any transaction marker is created.
new_root "$tmp_dir/baseline-drift"
drift_preflight=$(run_remote preflight)
drift_baseline=$(printf '%s\n' "$drift_preflight" | sed -n 's/^baseline=//p')
drift_evidence=$(printf '%s\n' "$drift_preflight" | sed -n 's/^preflight_digest=//p')
drift_recording_nvr=$(printf '%s\n' "$drift_preflight" | sed -n 's/^recording_nvr=//p')
drift_recording_nvr2=$(printf '%s\n' "$drift_preflight" | sed -n 's/^recording_nvr2=//p')
if OBS_SYSTEMCTL_DRIFT=1 run_remote stage "$source_digest" "$drift_baseline" "$drift_evidence" "$drift_recording_nvr" "$drift_recording_nvr2" < "$archive" >/dev/null 2>&1; then fail 'Scrypted baseline drift accepted'; fi
if OBS_KERNEL_WARN=1 run_remote stage "$source_digest" "$drift_baseline" "$drift_evidence" "$drift_recording_nvr" "$drift_recording_nvr2" < "$archive" >/dev/null 2>&1; then fail 'new kernel warning accepted'; fi
[ ! -e "$remote_root/var/lib/observability/deploy-state/pending" ] || fail 'baseline rejection created pending marker'

# A valid stage whose incoming payload is changed after manifest validation is
# rejected before bootstrap installs any target artifact.
new_root "$tmp_dir/staged-drift"
staged_preflight=$(run_remote preflight)
staged_baseline=$(printf '%s\n' "$staged_preflight" | sed -n 's/^baseline=//p')
staged_evidence=$(printf '%s\n' "$staged_preflight" | sed -n 's/^preflight_digest=//p')
staged_recording_nvr=$(printf '%s\n' "$staged_preflight" | sed -n 's/^recording_nvr=//p')
staged_recording_nvr2=$(printf '%s\n' "$staged_preflight" | sed -n 's/^recording_nvr2=//p')
run_remote stage "$source_digest" "$staged_baseline" "$staged_evidence" "$staged_recording_nvr" "$staged_recording_nvr2" < "$archive" >/dev/null || fail 'staged-drift setup failed'
printf '# staged drift\n' >> "$remote_root/var/lib/observability/deploy-state/stages/$source_digest/incoming/config/observability/images.env"
before=$(wc -c < "$tmp_dir/calls")
run_remote start-bootstrap "$source_digest" "$staged_baseline" "$staged_evidence" >/dev/null 2>&1 && fail 'corrupt staged artifact accepted'
[ "$before" = "$(wc -c < "$tmp_dir/calls")" ] || fail 'corrupt staged artifact started or pulled'

# Exercise the controller's real two-SSH upload/execution shape. The fake SSH
# receives the concatenated runner on stdin, then executes that exact runner
# with the archive stdin; it cannot fall through to a host or network command.
fake_ssh_bin=$tmp_dir/fake-ssh
mkdir "$fake_ssh_bin"
controller_tar=$(command -v tar)
controller_tar_args=$tmp_dir/controller-tar-args
cat > "$fake_ssh_bin/tar" <<'STUB'
#!/bin/sh
set -eu
creating=0
no_xattrs=0
no_mac_metadata=0
for argument in "$@"; do
	case "$argument" in
		--no-xattrs) no_xattrs=1;;
		--no-mac-metadata) no_mac_metadata=1;;
		-c|-c*) creating=1;;
	esac
done
if [ "$creating" = 1 ]; then
	printf '%s\n' "$@" > "$OBS_CONTROLLER_TAR_ARGS"
	[ "$no_xattrs" = 1 ] || exit 97
	[ "$no_mac_metadata" = 1 ] || exit 98
fi
exec "$OBS_CONTROLLER_REAL_TAR" "$@"
STUB
cat > "$fake_ssh_bin/ssh" <<'STUB'
#!/bin/sh
set -eu
last=
for argument in "$@"; do last=$argument; done
case "$last" in
*'install -m 0700 /dev/stdin /run/observability-operation/runner'*) cat > "$OBS_FAKE_ROOT/runner"; chmod 0700 "$OBS_FAKE_ROOT/runner";;
*'/run/observability-operation/runner '*) args=$(printf '%s' "$last" | sed 's/.*\/runner //'); OBSERVABILITY_REMOTE_ROOT="$OBS_FAKE_ROOT" "$OBS_FAKE_ROOT/runner" $args;;
*) exit 90;;
esac
STUB
chmod 0755 "$fake_ssh_bin/ssh" "$fake_ssh_bin/tar"
new_root "$tmp_dir/controller"
controller_preflight=$(run_remote preflight)
controller_baseline=$(printf '%s\n' "$controller_preflight" | sed -n 's/^baseline=//p')
controller_evidence=$(printf '%s\n' "$controller_preflight" | sed -n 's/^preflight_digest=//p')
controller_recording_nvr=$(printf '%s\n' "$controller_preflight" | sed -n 's/^recording_nvr=//p')
controller_recording_nvr2=$(printf '%s\n' "$controller_preflight" | sed -n 's/^recording_nvr2=//p')
controller_receipt=$tmp_dir/controller-receipt
printf 'format=observability-preflight-v3\ntarget=fake@flatcar.invalid\nsource_digest=%s\nbaseline=%s\npreflight_digest=%s\nrecording_nvr=%s\nrecording_nvr2=%s\norigin=https://observe.example.com\ncertificate_name=observe.example.com\n' "$source_digest" "$controller_baseline" "$controller_evidence" "$controller_recording_nvr" "$controller_recording_nvr2" > "$controller_receipt"
if OBS_FAKE_ROOT="$remote_root" PATH="$fake_ssh_bin:$PATH" "$repo_dir/scripts/deploy-observability" stage other@flatcar.invalid "$controller_receipt" >/dev/null 2>&1; then fail 'controller accepted substituted receipt target'; fi
sed "s/^source_digest=$source_digest$/source_digest=$(printf '%064d' 8)/" "$controller_receipt" > "$tmp_dir/controller-source-substitution"
if OBS_FAKE_ROOT="$remote_root" PATH="$fake_ssh_bin:$PATH" "$repo_dir/scripts/deploy-observability" stage fake@flatcar.invalid "$tmp_dir/controller-source-substitution" >/dev/null 2>&1; then fail 'controller accepted substituted receipt source'; fi
OBS_FAKE_ROOT="$remote_root" OBS_CONTROLLER_REAL_TAR="$controller_tar" OBS_CONTROLLER_TAR_ARGS="$controller_tar_args" PATH="$fake_ssh_bin:$PATH" "$repo_dir/scripts/deploy-observability" stage fake@flatcar.invalid "$controller_receipt" >/dev/null || fail 'controller SSH runner stage rejected'
[ "$(sed -n '1p' "$controller_tar_args")" = --no-xattrs ] || fail 'controller archive omitted no-xattrs'
[ "$(sed -n '2p' "$controller_tar_args")" = --no-mac-metadata ] || fail 'controller archive omitted no-mac-metadata'
[ -f "$remote_root/var/lib/observability/deploy-state/pending" ] || fail 'controller SSH runner did not stage transaction'

echo 'hermetic observability operations: PASS'
