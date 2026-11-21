#!/bin/sh
# Static dashboard contract test. Live API behavior is verified only at Gate C.
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dash_dir=$repo_dir/config/observability/dashboards
provisioner=$repo_dir/scripts/provision-observability-dashboards
tmp_dir=

fail() { echo "$1" >&2; exit 1; }
cleanup() { [ -z "$tmp_dir" ] || rm -rf "$tmp_dir"; }
trap cleanup EXIT HUP INT TERM

allowed_streams='system_cpu_utilization system_cpu_load_average_1m system_memory_usage system_network_io homelab_filesystem_used_bytes homelab_filesystem_available_bytes homelab_disk_read_bytes container_cpu_utilization container_memory_usage_total otelcol_exporter_sent_metric_points ai_run_count ai_run_duration ai_tokens_input ai_tokens_output ai_cost default'
forbidden_names='prompt response conversation user_text system_instruction tool_arguments tool_results shell_command command file_path working_directory repository project branch url http_request http_response header body secret env exception stacktrace status_message events links baggage'

is_allowed_stream() {
	case " $allowed_streams " in *" $1 "*) return 0;; *) return 1;; esac
}

validate_dashboard() {
	dashboard=$1
	[ -f "$dashboard" ] && [ ! -L "$dashboard" ] || return 1
	jq -e '
		(type == "object") and
		(.version == 8) and (.folder_id == "default") and
		(.title | type == "string" and length > 0 and length <= 128) and
		(.description | type == "string" and length > 0 and length <= 512) and
		((has("owner") or has("created") or has("updatedAt") or has("updated_at") or has("dashboardId") or has("dashboard_id") or has("hash")) | not) and
		(.tabs | type == "array" and length == 1) and
		([.tabs[] | (.tabId | type == "string" and test("^[A-Za-z0-9._-]{1,64}$")) and (.name | type == "string" and length > 0) and (.panels | type == "array" and length > 0)] | all)
	' "$dashboard" >/dev/null || return 1
	panel_ids=$(jq -r '.tabs[].panels[].id' "$dashboard") || return 1
	[ -n "$panel_ids" ] || return 1
	[ "$(printf '%s\n' "$panel_ids" | LC_ALL=C sort | uniq | wc -l | tr -d ' ')" = "$(printf '%s\n' "$panel_ids" | wc -l | tr -d ' ')" ] || return 1
	jq -e '
		[.tabs[].panels[] |
		(.id | type == "string" and test("^[A-Za-z0-9._-]{1,64}$")) and
		(.type | type == "string" and test("^(line|bar|table|markdown)$")) and
		(.title | type == "string" and length > 0 and length <= 128) and
		(.description | type == "string" and length > 0 and length <= 512) and
		(.config | type == "object" and ((has("showLegends") or has("legendsPosition")) | not) and has("show_legends")) and
		(.layout | type == "object" and (.x | type == "number" and . >= 0 and . < 192) and (.y | type == "number" and . >= 0) and (.w | type == "number" and . >= 32 and . <= 192) and (.h | type == "number" and . > 0) and (.i | type == "number" and . > 0)) and
		(if .type == "markdown" then (.queries == [] and (.markdownContent | type == "string" and length > 0)) else
			(.queryType == "sql") and (.queries | type == "array" and length > 0) and
			([.queries[] |
				(.query | type == "string" and length > 0 and length <= 4096) and
				(.vrlFunctionQuery == null) and (.customQuery == true) and
				(.fields | type == "object" and (has("streamType") | not) and (.stream | type == "string") and (.stream_type == "metrics" or .stream_type == "traces") and (.x | type == "array" and length > 0) and (.y | type == "array" and length > 0) and (.z | type == "array") and (.filter | type == "object")) and
				(.config | type == "object" and (.promql_legend | type == "string"))
			] | all)
		end)] | all
	' "$dashboard" >/dev/null || return 1
	jq -r '.tabs[].panels[] | select(.type != "markdown") | .queries[] | .fields.stream' "$dashboard" | while IFS= read -r stream; do is_allowed_stream "$stream" || exit 1; done || return 1
	jq -r '.tabs[].panels[] | select(.type != "markdown") | .queries[] | [.query, (.fields | tojson)] | join(" ")' "$dashboard" | while IFS= read -r text; do
		for forbidden in $forbidden_names; do case "$text" in *"$forbidden"*) exit 1;; esac; done
	done || return 1
	case "$(jq -r '.title' "$dashboard")" in
	'AI Tool Usage')
		jq -e '
			[.tabs[].panels[] | select(.type != "markdown") | .queries[] |
				if .fields.stream == "default" then (.query | test("service_telemetry_synthetic[[:space:]]*=[[:space:]]*'\''false'\''"))
				else (.query | test("telemetry_synthetic[[:space:]]*=[[:space:]]*'\''false'\''")) end
			] | all
		' "$dashboard" >/dev/null || return 1
		jq -e '[.tabs[].panels[] | select(.type == "markdown") | .markdownContent] | join(" ") | test("No real AI senders")' "$dashboard" >/dev/null || return 1
		;;
	'Homelab Foundation')
		jq -e '[.tabs[].panels[] | .title] | join(" ") | test("Host CPU") and test("NVR capacity") and test("Collector export health") and test("OpenObserve ingestion")' "$dashboard" >/dev/null || return 1
		jq -e '[.tabs[].panels[] | .title] | join(" ") | test("systemd"; "i") | not' "$dashboard" >/dev/null || return 1
		;;
	*) return 1 ;;
	esac
}

must_reject_mutation() {
	name=$1 file=$2 filter=$3
	mutated=$tmp_dir/$name.json
	jq "$filter" "$file" > "$mutated" || fail "cannot make $name mutation"
	if validate_dashboard "$mutated"; then fail "dashboard mutation accepted: $name"; fi
}

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/observability-dashboards.XXXXXX") || fail 'cannot create test directory'
for dashboard in "$dash_dir/homelab-foundation.json" "$dash_dir/ai-tool-usage.json"; do validate_dashboard "$dashboard" || fail "invalid dashboard contract: ${dashboard##*/}"; done
[ -x "$provisioner" ] && sh -n "$provisioner" || fail 'dashboard provisioner is not executable POSIX shell'
grep -F 'require_bws_runtime' "$provisioner" >/dev/null || fail 'dashboard provisioner lacks managed BWS runtime guard'
grep -F 'printenv ZO_ROOT_USER_EMAIL' "$provisioner" >/dev/null || fail 'dashboard provisioner does not read root email from environment'
grep -F 'printenv ZO_ROOT_USER_PASSWORD' "$provisioner" >/dev/null || fail 'dashboard provisioner does not read root password from environment'
grep -F 'curl --config -' "$provisioner" >/dev/null || fail 'dashboard provisioner places authorization outside curl config'
grep -F 'OPENOBSERVE_INGEST_AUTH_HEADER' "$provisioner" >/dev/null && fail 'dashboard provisioner reuses ingestion-only credentials'
grep -F '409)' "$provisioner" >/dev/null || fail 'dashboard provisioner does not retry one conflict'
grep -F 'POST' "$provisioner" >/dev/null && grep -F 'PUT' "$provisioner" >/dev/null && grep -F 'GET' "$provisioner" >/dev/null || fail 'dashboard provisioner lacks create-get-update flow'
if [ "${OBS_DASHBOARD_PROVISIONER_SELF_TEST_ACTIVE:-}" != 1 ]; then
	"$provisioner" --self-test >/dev/null || fail 'dashboard provisioner mock create-get-update test failed'
fi

must_reject_mutation generated_metadata "$dash_dir/homelab-foundation.json" '.created = "2026-01-01T00:00:00Z"'
must_reject_mutation unsupported_version "$dash_dir/homelab-foundation.json" '.version = 7'
must_reject_mutation duplicate_panel "$dash_dir/homelab-foundation.json" '.tabs[0].panels[1].id = .tabs[0].panels[0].id'
must_reject_mutation old_grid "$dash_dir/homelab-foundation.json" '.tabs[0].panels[0].layout.w = 24'
must_reject_mutation array_filter "$dash_dir/homelab-foundation.json" '.tabs[0].panels[0].queries[0].fields.filter = []'
must_reject_mutation unknown_stream "$dash_dir/homelab-foundation.json" '.tabs[0].panels[0].queries[0].fields.stream = "unapproved_stream"'
must_reject_mutation forbidden_attribute "$dash_dir/ai-tool-usage.json" '.tabs[0].panels[1].queries[0].query += " AND prompt = '\''forbidden'\''"'
must_reject_mutation synthetic_total "$dash_dir/ai-tool-usage.json" '.tabs[0].panels[1].queries[0].query |= sub("telemetry_synthetic = '\''false'\''"; "telemetry_synthetic = '\''true'\''")'

echo 'dashboard contract: two v8 dashboards passed static schema and privacy checks'
