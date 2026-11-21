#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/observability-operations.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
fail() { echo "observability operations contract: $1" >&2; exit 1; }
for script in scripts/deploy-observability-secrets scripts/deploy-observability scripts/rollback-observability scripts/verify-observability-live scripts/observability-operation-lib scripts/observability-remote; do [ -x "$repo_dir/$script" ] || fail "missing executable $script"; done

stub_bin=$tmp_dir/bin; mkdir "$stub_bin"; : > "$tmp_dir/calls"
cat > "$stub_bin/bws-project" <<'STUB'
#!/bin/sh
[ "$1" = run ] && [ "$2" = -- ] || exit 90
shift 2; exec "$@"
STUB
cat > "$stub_bin/ssh" <<'STUB'
#!/bin/sh
set -eu
for arg in "$@"; do case "$arg" in *TEST_SECRET*) exit 91;; esac; done
body=$(cat)
docker_env_value() {
	name=$1
	printf '%s\n' "$body" | awk -v name="$name" '
		$0 == "" || substr($0, 1, 1) == "#" || index($0, "=") == 0 { exit 81 }
		substr($0, 1, index($0, "=") - 1) == name {
			if (++found != 1) exit 82
			value = substr($0, index($0, "=") + 1)
		}
		END { if (found != 1) exit 83; printf "%s", value }
	'
}
require_stream() {
	expected_count=$#
	actual_count=$(printf '%s\n' "$body" | awk 'NF { count++ } END { print count + 0 }')
	[ "$actual_count" = "$expected_count" ] || exit 84
	for name in "$@"; do
		expected=$(printenv "$name")
		actual=$(docker_env_value "$name") || exit 85
		[ "$actual" = "$expected" ] || exit 86
	done
}
case "$body" in
*'ZO_ROOT_USER_EMAIL='*) require_stream ZO_ROOT_USER_EMAIL ZO_ROOT_USER_PASSWORD; printf 'bootstrap-openobserve\n' >> "$OBS_CALLS";;
*'CLOUDFLARE_API_TOKEN='*) require_stream CLOUDFLARE_API_TOKEN HOMELAB_OTLP_TOKEN AI_OTLP_TOKEN; printf 'bootstrap-proxy\n' >> "$OBS_CALLS";;
*'OPENOBSERVE_INGEST_AUTH_HEADER='*) require_stream OPENOBSERVE_INGEST_AUTH_HEADER; printf 'collector\n' >> "$OBS_CALLS";;
*) exit 92;;
esac
STUB
cat > "$stub_bin/tar" <<'STUB'
#!/bin/sh
for arg in "$@"; do case "$arg" in *TEST_SECRET*) exit 94;; esac; done
exit 95
STUB
cat > "$stub_bin/docker" <<'STUB'
#!/bin/sh
exit 96
STUB
chmod 0755 "$stub_bin"/*
export PATH="$stub_bin:$PATH" OBS_CALLS="$tmp_dir/calls"
export ZO_ROOT_USER_EMAIL=' TEST_SECRET_ROOT_EMAIL # = "quoted" \ value'
export ZO_ROOT_USER_PASSWORD='TEST_SECRET_ROOT_PASSWORD # = "quoted" \ value '
export CLOUDFLARE_API_TOKEN='#TEST_SECRET_CLOUDFLARE = "quoted" \ value'
export HOMELAB_OTLP_TOKEN='  TEST_SECRET_HOMELAB # = "quoted" \ value'
export AI_OTLP_TOKEN='TEST_SECRET_AI # = "quoted" \ value'
export OPENOBSERVE_INGEST_AUTH_HEADER='TEST_SECRET_INGEST # = "quoted" \ value'

run_ok() { "$@" > "$tmp_dir/out" 2>&1 || fail "failed: $*"; grep -R -F -q TEST_SECRET "$tmp_dir/out" "$tmp_dir/calls" && fail 'secret escaped stdout or call log'; return 0; }
run_fail() { "$@" > "$tmp_dir/out" 2>&1 && fail "unexpected success: $*"; grep -R -F -q TEST_SECRET "$tmp_dir/out" "$tmp_dir/calls" && fail 'secret escaped failure output'; return 0; }

run_ok bws-project run -- "$repo_dir/scripts/deploy-observability-secrets" bootstrap test@flatcar.invalid
grep -Fqx bootstrap-openobserve "$tmp_dir/calls" >/dev/null || fail 'bootstrap OpenObserve stream missing'
grep -Fqx bootstrap-proxy "$tmp_dir/calls" >/dev/null || fail 'bootstrap proxy stream missing'
: > "$tmp_dir/calls"
run_ok bws-project run -- "$repo_dir/scripts/deploy-observability-secrets" collector test@flatcar.invalid
[ "$(cat "$tmp_dir/calls")" = collector ] || fail 'collector stream missing'
: > "$tmp_dir/calls"
run_ok "$repo_dir/scripts/deploy-observability-secrets" bootstrap --check-only
[ ! -s "$tmp_dir/calls" ] || fail 'check-only invoked SSH'
export ZO_ROOT_USER_PASSWORD="$(printf 'bad\nvalue')"
run_fail "$repo_dir/scripts/deploy-observability-secrets" bootstrap --check-only
export ZO_ROOT_USER_PASSWORD='TEST_SECRET_ROOT_PASSWORD # = "quoted" \ value '

# The SSH stub consumes only fixed NAME=value records using Docker's raw
# env-file grammar; all literal test bytes round-trip without local files.
"$repo_dir/tests/observability-privacy-live.sh" --self-test
"$repo_dir/tests/observability-operations-hermetic.sh"
echo 'observability operations contract: PASS'
