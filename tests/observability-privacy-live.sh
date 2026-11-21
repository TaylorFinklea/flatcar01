#!/bin/sh
# Gate-C-only live verifier. --self-test uses a curl stub and no network.
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_dir/scripts/observability-operation-lib"
tmp_base=${TMPDIR:-/tmp}

usage() { echo "usage: bws-project run -- $0 <https-base-url> <preflight-receipt>" >&2; exit 2; }
fail() { echo "$1" >&2; exit 1; }

require_value() {
	name=$1 value=$2
	[ -n "$value" ] || fail "missing $name"
	newline='
'
	carriage=$(printf '\r')
	case "$value" in *"$newline"*|*"$carriage"*) fail "unsafe newline in $name";; esac
}

curl_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
curl_config() {
	printf 'header = "Authorization: %s"\n' "$(curl_escape "$1")"
	printf 'silent\nshow-error\n'
}
http_post() { curl_config "$1" | curl --config - --connect-timeout 5 --max-time 15 --max-filesize 1048576 --request POST --header 'Content-Type: application/json' --data-binary "@$3" --output "$4" --write-out '%{http_code}' "$2"; }
http_get() { curl_config "$1" | curl --config - --connect-timeout 5 --max-time 15 --max-filesize 1048576 --request GET --output "$3" --write-out '%{http_code}' "$2"; }
require_200() { [ "$1" = 200 ]; }
require_accepted() { case "$1" in 200|202) return 0;; *) return 1;; esac; }
require_rejected() { case "$1" in 400|401|403|404|405|415|422) return 0;; *) return 1;; esac; }

validate_fixtures() {
	for fixture in homelab-metrics homelab-traces ai-metrics ai-traces ai-logs; do
		path="$repo_dir/tests/fixtures/observability/$fixture.json"
		jq -e '(.canaries | type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z0-9._-]{1,128}$"))) and (.input | type == "object") and (.expected | type == "object")' "$path" >/dev/null || fail "invalid synthetic fixture $fixture"
	done
}

tmp_dir=
cleanup() { [ -z "$tmp_dir" ] || rm -rf "$tmp_dir"; }
trap cleanup EXIT HUP INT TERM
setup() {
	[ -z "$tmp_dir" ] || return 0
	umask 077
	tmp_dir=$(mktemp -d "$tmp_base/observability-privacy.XXXXXX") || fail 'cannot create private parser directory'
	inventory_file=$tmp_dir/inventory
	response_file=$tmp_dir/response
	query_file=$tmp_dir/query
}

# The tracked files are contract wrappers. Convert their schema-checked input
# into OTLP/JSON in a private temp file; never post the wrapper itself.
make_otlp() {
	fixture=$1 output=$2
	now_nanos="$(date +%s)000000000"
	case "$fixture" in
	*-metrics)
		jq --arg now "$now_nanos" 'def attrs: to_entries | map({key:.key,value:(if (.value|type) == "boolean" then {boolValue:.value} elif (.value|type) == "number" then {doubleValue:.value} else {stringValue:(.value|tostring)} end)}); {resourceMetrics:[{resource:{attributes:(.input.resource.attributes|attrs)},scopeMetrics:[{scope:{name:"observability-privacy-live"},metrics:[.input.metrics[] | {name:.name,gauge:{dataPoints:[{attributes:(.attributes|attrs),asDouble:(.value|tonumber),timeUnixNano:$now}]}}]}]}]}' "$repo_dir/tests/fixtures/observability/$fixture.json" > "$output" ;;
	*-traces)
		jq --arg now "$now_nanos" 'def attrs: to_entries | map({key:.key,value:(if (.value|type) == "boolean" then {boolValue:.value} elif (.value|type) == "number" then {doubleValue:.value} else {stringValue:(.value|tostring)} end)}); {resourceSpans:[{resource:{attributes:(.input.resource.attributes|attrs)},scopeSpans:[{scope:{name:"observability-privacy-live"},spans:[.input.spans | to_entries[] | .value as $span | {traceId:"0123456789abcdef0123456789abcdef",spanId:(if .key == 0 then "0123456789abcdef" else "fedcba9876543210" end),name:$span.name,startTimeUnixNano:$now,endTimeUnixNano:$now,attributes:($span.attributes|attrs),traceState:($span.trace_state // ""),status:{message:($span.status_message // "")},events:[($span.events // [])[] | {timeUnixNano:$now,name:.name,attributes:(.attributes|attrs)}],links:[($span.links // [])[] | {traceId:"11111111111111111111111111111111",spanId:"2222222222222222",attributes:(.attributes|attrs)}]}]}]}]}' "$repo_dir/tests/fixtures/observability/$fixture.json" > "$output" ;;
	*-logs)
		jq --arg now "$now_nanos" 'def attrs: to_entries | map({key:.key,value:(if (.value|type) == "boolean" then {boolValue:.value} elif (.value|type) == "number" then {doubleValue:.value} else {stringValue:(.value|tostring)} end)}); {resourceLogs:[{resource:{attributes:(.input.resource.attributes|attrs)},scopeLogs:[{scope:{name:"observability-privacy-live"},logRecords:[.input.logs[] | {timeUnixNano:$now,body:{stringValue:(.body // "")},attributes:(.attributes|attrs)}]}]}]}' "$repo_dir/tests/fixtures/observability/$fixture.json" > "$output" ;;
	*) return 1 ;;
	esac
	jq -e 'type == "object" and (has("resourceMetrics") or has("resourceSpans") or has("resourceLogs"))' "$output" >/dev/null
}

inventory() {
	type=$1
	case "$type" in logs) min=0;; metrics|traces) min=1;; *) return 1;; esac
	status=$(http_get "$query_header" "$base_url/api/default/streams?type=$type&fetchSchema=true" "$inventory_file") || return 1
	require_200 "$status" || return 1
	# A tab is IFS whitespace: POSIX read collapses consecutive tabs and would
	# shift later fields when OpenObserve reports an empty list.  Every emitted
	# column therefore has a nonempty sentinel; ! is outside the accepted name
	# alphabet and cannot collide with server data.
	jq -e --arg type "$type" --argjson min "$min" '(type == "object") and (.total | type == "number" and . >= $min and . <= 128) and (.list | type == "array" and length >= $min and length <= 128) and ((.list | length) == .total) and all(.list[]; (type == "object") and (.name | type == "string" and test("^[A-Za-z0-9_.-]{1,128}$")) and (.stream_type == $type) and (.schema | type == "array" and length <= 256) and all(.schema[]?; type == "object" and (.name | type == "string" and test("^[A-Za-z0-9_.-]{1,128}$"))) and (.settings.full_text_search_keys | type == "array" and length <= 64) and all(.settings.full_text_search_keys[]; type == "string" and test("^[A-Za-z0-9_.-]{1,128}$")))' "$inventory_file" >/dev/null || return 1
	jq -r 'def nonempty: if . == "" then "!" else . end; .list[] | [.name, ((.settings.full_text_search_keys // []) | join(",") | nonempty), ([.schema[]? | select((.data_type // .type // "") == "Utf8") | .name] | join(",") | nonempty), ([.schema[]? | .name] | join(",") | nonempty)] | @tsv' "$inventory_file"
}

where_clause() {
	canary=$1 keys=$2 utf8=$3
	[ -n "$utf8" ] || return 1
	case "$canary" in ''|*[!A-Za-z0-9._:-]*) return 1;; esac
	first=true clause=
	if [ -n "$keys" ]; then
		for key in $(printf '%s' "$keys" | tr ',' ' '); do
			case "$key" in ''|*[!A-Za-z0-9_.-]*) return 1;; esac
			if "$first"; then clause="match_all('$canary')"; first=false; else clause="$clause OR match_all('$canary')"; fi
		done
	fi
	old_ifs=$IFS; IFS=,
	for field in $utf8; do
		case "$field" in ''|*[!A-Za-z0-9_.-]*) IFS=$old_ifs; return 1;; esac
		# OpenObserve 0.92.2 exposes Utf8 columns but rejects str_match on
		# ordinary stream fields.  A typed CAST plus LIKE preserves substring
		# canary coverage without relying on a full-text index.
		term="CAST(\"$field\" AS VARCHAR) LIKE '%$canary%'"
		if "$first"; then clause=$term; first=false; else clause="$clause OR $term"; fi
	done
	IFS=$old_ifs
	[ -n "$clause" ] && printf '%s' "$clause"
}

query_count() {
	type=$1 stream=$2 keys=$3 utf8=$4 canary=$5 expect=$6
	clause=$(where_clause "$canary" "$keys" "$utf8") || return 1
	query_sql "$type" "$stream" "$clause" "$expect"
}

query_sql() {
	type=$1 stream=$2 clause=$3 expect=$4
	sql=$(printf 'SELECT COUNT(*) AS count FROM "%s" WHERE %s' "$stream" "$clause")
	query_end_seconds=$(date +%s) || return 1
	case "$query_end_seconds" in ''|*[!0-9]*) return 1;; esac
	query_start_seconds=$((query_end_seconds - 2592000))
	[ "$query_start_seconds" -ge 0 ] || query_start_seconds=0
	query_start_time=$((query_start_seconds * 1000000))
	query_end_time=$((query_end_seconds * 1000000))
	jq -n --arg sql "$sql" --argjson start_time "$query_start_time" --argjson end_time "$query_end_time" '{query:{sql:$sql,start_time:$start_time,end_time:$end_time,from:0,size:0}}' > "$query_file" || return 1
	jq -e '.query | keys == ["end_time","from","size","sql","start_time"] and (.sql | strings)' "$query_file" >/dev/null || return 1
	status=$(http_post "$query_header" "$base_url/api/default/_search?type=$type" "$query_file" "$response_file") || return 1
	require_200 "$status" || return 1
	count=$(jq -er '.hits[0].count | if type == "number" and floor == . and . >= 0 then . else error("count") end' "$response_file") || return 1
	case "$expect" in present) [ "$count" -gt 0 ];; absent) [ "$count" -eq 0 ];; *) return 1;; esac
}

allowed_clause() {
	terms=$1 keys=$2 utf8=$3
	[ -n "$terms" ] || return 1
	if [ -n "$keys" ]; then
		first=true
		for term in $terms; do
			case "$term" in ''|*[!A-Za-z0-9._:-]*) return 1;; esac
			if "$first"; then printf "match_all('%s')" "$term"; first=false; else printf " AND match_all('%s')" "$term"; fi
		done
		return
	fi
	# Without server-declared full-text keys, a record cannot be proven to retain
	# all approved metadata unless the inventory offers searchable strings.
	[ -n "$utf8" ] || return 1
	old_ifs=$IFS; IFS=,
	set -- $utf8
	IFS=$old_ifs
	[ "$#" -le 64 ] || return 1
	first_term=true
	for term in $terms; do
		case "$term" in ''|*[!A-Za-z0-9._:-]*) return 1;; esac
		if "$first_term"; then first_term=false; else printf ' AND '; fi
		printf '('
		first_field=true
		for field in $utf8; do
			case "$field" in ''|*[!A-Za-z0-9_.-]*) return 1;; esac
			if "$first_field"; then first_field=false; else printf ' OR '; fi
			printf 'CAST("%s" AS VARCHAR) LIKE '\''%%%s%%'\''' "$field" "$term"
		done
		printf ')'
	done
}

allowed_terms() {
	fixture=$1 record=$2
	printf '%s\n' "$record" | jq -er '[.name, ((.resource // {}) | to_entries[] | .value), ((.attributes // {}) | to_entries[] | .value)] | .[] | if type == "boolean" then tostring elif type == "number" then tostring else . end | select(type == "string" and test("^[A-Za-z0-9._:-]{1,128}$"))' > "$tmp_dir/terms"
	[ -s "$tmp_dir/terms" ]
}

normalized_name() { printf '%s' "$1" | tr '[:upper:].' '[:lower:]_'; }

schema_has() {
	schema=$1 required=$2
	old_ifs=$IFS; IFS=,
	for wanted in $required; do
		case ",$schema," in *,"$wanted",*) ;; *) IFS=$old_ifs; return 1;; esac
	done
	IFS=$old_ifs
}

predicate() {
	field=$1 value=$2
	case "$field" in ''|*[!A-Za-z0-9_.-]*) return 1;; esac
	case "$value" in true|false) printf '"%s" = '\''%s'\''' "$field" "$value"; return;; esac
	if printf '%s\n' "$value" | grep -Eq '^-?[0-9]+([.][0-9]+)?$'; then printf '"%s" = %s' "$field" "$value"; return; fi
	case "$value" in *[!A-Za-z0-9._:-]*|'') return 1;; *) printf '"%s" = '\''%s'\''' "$field" "$value";; esac
}

metric_clause() {
	fixture=$1 name=$2
	record=$(jq -c --arg name "$name" '.expected.records[] | select(.name == $name)' "$repo_dir/tests/fixtures/observability/$fixture.json") || return 1
	input=$(jq -c --arg name "$name" '.input.metrics[] | select(.name == $name)' "$repo_dir/tests/fixtures/observability/$fixture.json") || return 1
	host=$(printf '%s\n' "$record" | jq -er '.resource["host.name"]')
	synthetic=$(printf '%s\n' "$record" | jq -er '.resource["telemetry.synthetic"]')
	value=$(printf '%s\n' "$input" | jq -er '.value')
	required='__name__,value,host_name,telemetry_synthetic'
	clause="$(predicate __name__ "$(normalized_name "$name")") AND $(predicate value "$value") AND $(predicate host_name "$host") AND $(predicate telemetry_synthetic "$synthetic")"
	# Explicit expected attributes take priority. AI metrics deliberately list
	# only normalized records in expected, so their approved dimensions come
	# from the fixture input after its schema has been validated.
	if [ "$(printf '%s\n' "$record" | jq '.attributes | length')" -gt 0 ]; then attrs_source=$record; else attrs_source=$input; fi
	printf '%s\n' "$attrs_source" | jq -r '.attributes | to_entries[] | [.key, (.value | tostring)] | @tsv' > "$tmp_dir/metric-attrs"
	while IFS="$(printf '\t')" read -r key value_item; do field=$(normalized_name "$key"); required=$required,$field; clause="$clause AND $(predicate "$field" "$value_item")"; done < "$tmp_dir/metric-attrs"
	printf '%s|%s\n' "$required" "$clause"
}

trace_clause() {
	record=$(jq -c '.expected.records[0]' "$repo_dir/tests/fixtures/observability/ai-traces.json") || return 1
	operation=$(printf '%s\n' "$record" | jq -er '.name')
	host=$(printf '%s\n' "$record" | jq -er '.resource["host.name"]')
	synthetic=$(printf '%s\n' "$record" | jq -er '.resource["telemetry.synthetic"]')
	required='operation_name,service_host_name,service_telemetry_synthetic'
	clause="$(predicate operation_name "$operation") AND $(predicate service_host_name "$host") AND $(predicate service_telemetry_synthetic "$synthetic")"
	printf '%s\n' "$record" | jq -r '.attributes | to_entries[] | [.key, (.value|tostring)] | @tsv' > "$tmp_dir/trace-attrs"
	while IFS="$(printf '\t')" read -r key value_item; do field=$(normalized_name "$key"); required=$required,$field; clause="$clause AND $(predicate "$field" "$value_item")"; done < "$tmp_dir/trace-attrs"
	printf '%s|%s\n' "$required" "$clause"
}

await_allowed_records() {
	type=$1 streams=$tmp_dir/$type.streams
	case "$type" in metrics) fixtures='homelab-metrics ai-metrics';; traces) fixtures='ai-traces';; *) return 0;; esac
	for fixture in $fixtures; do
		jq -r '.expected.records[].name' "$repo_dir/tests/fixtures/observability/$fixture.json" | while IFS= read -r expected_name; do
			matched=false attempt=1
			while [ "$attempt" -le 3 ] && ! "$matched"; do
				while IFS="$(printf '\t')" read -r stream keys utf8 schema; do
					[ "$keys" = '!' ] && keys=
					[ "$utf8" = '!' ] && utf8=
					[ "$schema" = '!' ] && schema=
					case "$type" in
					metrics) [ "$stream" = "$(normalized_name "$expected_name")" ] || continue; packed=$(metric_clause "$fixture" "$expected_name") || exit 1 ;;
					traces) packed=$(trace_clause) || exit 1 ;;
					esac
					required=${packed%%|*}; clause=${packed#*|}
					schema_has "$schema" "$required" || exit 1
					if query_sql "$type" "$stream" "$clause" present; then matched=true; break; fi
				done < "$streams"
				[ "$matched" = true ] || { attempt=$((attempt + 1)); [ "$attempt" -le 3 ] && sleep 1; }
			done
			[ "$matched" = true ] || exit 1
		done || fail "approved $type record or exact metadata was not queryable"
	done
}

run_queries() {
	type=$1
	inventory "$type" > "$tmp_dir/$type.streams" || fail "invalid or unavailable $type inventory"
	[ -s "$tmp_dir/$type.streams" ] || { [ "$type" = logs ] && return 0; fail "empty $type inventory"; }
	await_allowed_records "$type"
	while IFS="$(printf '\t')" read -r stream keys utf8 schema; do
		[ "$keys" = '!' ] && keys=
		[ "$utf8" = '!' ] && utf8=
		[ "$schema" = '!' ] && schema=
		for fixture in homelab-metrics homelab-traces ai-metrics ai-traces ai-logs; do
			jq -r '.canaries[]' "$repo_dir/tests/fixtures/observability/$fixture.json" | while IFS= read -r canary; do query_count "$type" "$stream" "$keys" "$utf8" "$canary" absent || exit 1; done || fail "canary query failed for $type/$stream"
		done
	done < "$tmp_dir/$type.streams"
}

assert_no_real_ai_senders() {
	# Synthetic validation is required to leave an honest initial state: no
	# accepted AI metric or trace may claim telemetry.synthetic=false yet.
	while IFS="$(printf '\t')" read -r stream ignored ignored2 schema; do
		[ "$schema" = '!' ] && schema=
		case "$stream" in
		ai_*)
			schema_has "$schema" telemetry_synthetic || fail "AI metric stream lacks telemetry.synthetic schema: $stream"
			query_sql metrics "$stream" '"telemetry_synthetic" = '\''false'\''' absent || fail "real AI metric sender unexpectedly present: $stream"
			;;
		esac
	done < "$tmp_dir/metrics.streams"
	while IFS="$(printf '\t')" read -r stream ignored ignored2 schema; do
		[ "$schema" = '!' ] && schema=
		[ "$stream" = default ] || continue
		schema_has "$schema" service_telemetry_synthetic || fail 'AI trace stream lacks telemetry.synthetic schema'
		query_sql traces "$stream" '"service_telemetry_synthetic" = '\''false'\''' absent || fail 'real AI trace sender unexpectedly present'
	done < "$tmp_dir/traces.streams"
}

run_live() {
	[ "$base_url" = "$(ops_origin)" ] || fail 'base URL does not match receipt-approved origin'
	ops_receipt "$receipt" || fail 'invalid target receipt'
	[ "$OPS_RECEIPT_ORIGIN" = "$base_url" ] || fail 'base URL does not match target receipt'
	validate_fixtures
	setup
	ops_manifest "$repo_dir" > "$tmp_dir/source.manifest" || fail 'invalid canonical artifact map'
	[ "$(ops_manifest_digest "$tmp_dir/source.manifest")" = "$OPS_RECEIPT_SOURCE" ] || fail 'receipt source mismatch'
	homelab_token=$(printenv HOMELAB_OTLP_TOKEN || :)
	ai_token=$(printenv AI_OTLP_TOKEN || :)
	root_email=$(printenv ZO_ROOT_USER_EMAIL || :)
	root_password=$(printenv ZO_ROOT_USER_PASSWORD || :)
	require_value HOMELAB_OTLP_TOKEN "$homelab_token"; require_value AI_OTLP_TOKEN "$ai_token"; require_value ZO_ROOT_USER_EMAIL "$root_email"; require_value ZO_ROOT_USER_PASSWORD "$root_password"
	homelab_header="Bearer $homelab_token"; ai_header="Bearer $ai_token"
	basic=$(printf '%s:%s' "$root_email" "$root_password" | base64 | tr -d '\n')
	query_header="Basic $basic"
	for item in "homelab_header|/otlp/homelab/v1/metrics|homelab-metrics|accepted" "ai_header|/otlp/ai/v1/metrics|ai-metrics|accepted" "ai_header|/otlp/ai/v1/traces|ai-traces|accepted" "homelab_header|/otlp/homelab/v1/traces|homelab-traces|rejected" "ai_header|/otlp/ai/v1/logs|ai-logs|rejected"; do
		IFS='|' read -r header_name path fixture outcome <<EOF
$item
EOF
		eval header=\$$header_name
		payload=$tmp_dir/$fixture.otlp
		make_otlp "$fixture" "$payload" || fail 'invalid OTLP fixture conversion'
		status=$(http_post "$header" "$base_url$path" "$payload" "$response_file") || fail 'synthetic transport indeterminate'
		case "$outcome" in accepted) require_accepted "$status";; rejected) require_rejected "$status";; esac || fail 'synthetic endpoint policy indeterminate'
	done
	for type in logs metrics traces; do run_queries "$type"; done
	assert_no_real_ai_senders
	echo 'privacy live contract: synthetic fixtures and all discovered stream canaries passed'
}

self_test() {
	validate_fixtures; setup
	stub_bin=$tmp_dir/bin; mkdir -p "$stub_bin"
	cat > "$stub_bin/curl" <<'STUB'
#!/bin/sh
set -eu
config=$(cat)
case "$config" in *'Authorization: Basic '*|*'Authorization: Bearer '*) ;; *) exit 91;; esac
for arg in "$@"; do case "$arg" in *SELF_SECRET*|*Authorization:*) exit 92;; esac; done
out= body= url=
while [ "$#" -gt 0 ]; do case "$1" in --output) out=$2; shift 2;; --data-binary) body=$(printf '%s' "$2" | sed 's/^@//'); shift 2;; --connect-timeout|--max-time|--max-filesize|--config|--request|--header|--write-out) shift 2;; --*) shift;; *) url=$1; shift;; esac; done
case "$url" in
*'/streams?type='*)
	type=$(printf '%s' "$url" | sed 's/.*type=//; s/&.*//')
	case "${OBS_PRIVACY_CASE:-}" in empty-inventory) printf '{"list":[],"total":0}' > "$out";; malformed) printf '{' > "$out";; *)
		ai_fields='[{"name":"__name__","data_type":"Utf8"},{"name":"value","data_type":"Float64"},{"name":"host_name","data_type":"Utf8"},{"name":"telemetry_synthetic","data_type":"Utf8"},{"name":"ai_tool","data_type":"Utf8"},{"name":"ai_harness","data_type":"Utf8"},{"name":"ai_role","data_type":"Utf8"},{"name":"ai_provider","data_type":"Utf8"},{"name":"ai_model","data_type":"Utf8"},{"name":"ai_lane","data_type":"Utf8"},{"name":"ai_operation","data_type":"Utf8"},{"name":"ai_status","data_type":"Utf8"},{"name":"ai_error_class","data_type":"Utf8"},{"name":"ai_instrumentation_version","data_type":"Utf8"},{"name":"ai_currency","data_type":"Utf8"},{"name":"ai_run_id","data_type":"Utf8"},{"name":"ai_task_id","data_type":"Utf8"}]'
		[ "${OBS_PRIVACY_CASE:-}" != missing-field ] || ai_fields=$(printf '%s' "$ai_fields" | sed 's/,{"name":"ai_task_id","data_type":"Utf8"}//')
		case "$type" in
		metrics) jq -n --argjson ai "$ai_fields" '{list:[{name:"system_cpu_utilization",stream_type:"metrics",schema:[{name:"__name__",data_type:"Utf8"},{name:"value",data_type:"Float64"},{name:"host_name",data_type:"Utf8"},{name:"telemetry_synthetic",data_type:"Utf8"},{name:"state",data_type:"Utf8"}],settings:{full_text_search_keys:[]}},{name:"ai_run_count",stream_type:"metrics",schema:$ai,settings:{full_text_search_keys:[]}},{name:"ai_run_duration",stream_type:"metrics",schema:$ai,settings:{full_text_search_keys:[]}},{name:"ai_tokens_input",stream_type:"metrics",schema:$ai,settings:{full_text_search_keys:[]}},{name:"ai_tokens_output",stream_type:"metrics",schema:$ai,settings:{full_text_search_keys:[]}},{name:"ai_cost",stream_type:"metrics",schema:$ai,settings:{full_text_search_keys:[]}}],total:6}' > "$out";;
		traces) jq -n --argjson ai "$ai_fields" '{list:[{name:"default",stream_type:"traces",schema:([{name:"operation_name",data_type:"Utf8"},{name:"service_host_name",data_type:"Utf8"},{name:"service_telemetry_synthetic",data_type:"Utf8"},{name:"events",data_type:"Utf8"},{name:"links",data_type:"Utf8"},{name:"status_message",data_type:"Utf8"}] + $ai[4:]),settings:{full_text_search_keys:[]}}],total:1}' > "$out";;
		logs) printf '{"list":[],"total":0}' > "$out";;
		esac
	;; esac;;
*'/_search?type='*)
	jq -e '.query | keys == ["end_time","from","size","sql","start_time"]' "$body" >/dev/null
	now_seconds=$(date +%s)
	now_microseconds=$((now_seconds * 1000000))
	jq -e --argjson now "$now_microseconds" '.query | (.start_time | type == "number" and floor == . and . >= 0) and (.end_time | type == "number" and floor == . and . <= $now and . >= ($now - 1000000)) and (.end_time - .start_time == 2592000000000)' "$body" >/dev/null
	sql=$(jq -r '.query.sql' "$body")
	case "$sql" in
	*CANARY*)
		# Every inventory Utf8 field, including serialized trace event/link/status
		# columns outside the FTS keys, must participate in canary absence queries.
		case "$url" in *'type=traces'*) case "$sql" in *'CAST("events" AS VARCHAR) LIKE'*'CAST("links" AS VARCHAR) LIKE'*'CAST("status_message" AS VARCHAR) LIKE'*) ;; *) exit 94;; esac;; esac
		count=0;;
	*'"telemetry_synthetic" = '\''false'\'''*|*'"service_telemetry_synthetic" = '\''false'\'''*)
		case "${OBS_PRIVACY_CASE:-}" in real-ai-present) count=1;; *) count=0;; esac;;
	*'FROM "ai_'*|*'FROM "default"'*)
		for term in '"ai_tool" = '\''codex'\''' '"ai_harness" = '\''codex'\''' '"ai_role" = '\''lead'\''' '"ai_provider" = '\''openai'\''' '"ai_model" = '\''gpt-5.6'\''' '"ai_lane" = '\''local'\''' '"ai_operation" = '\''run'\''' '"ai_status" = '\''ok'\''' '"ai_error_class" = '\''none'\''' '"ai_instrumentation_version" = '\''v1'\''' '"ai_currency" = '\''USD'\''' '"ai_run_id" = '\''run_123'\''' '"ai_task_id" = '\''task_456'\'''; do case "$sql" in *"$term"*) ;; *) exit 95;; esac; done
		case "$sql" in *'FROM "ai_'*) normalized=$(printf '%s' "$sql" | sed -n 's/.*"__name__" = '\''\([^'\'' ]*\)'\''.*/\1/p'); case "$normalized" in ai_run_count|ai_run_duration|ai_tokens_input|ai_tokens_output|ai_cost) ;; *) exit 96;; esac;; *'FROM "default"'*) case "$sql" in *'"operation_name" = '\''ai.run'\'''*'"service_host_name" = '\''scrypted-nvr'\'''*'"service_telemetry_synthetic" = '\''true'\'''*) ;; *) exit 97;; esac;; esac
		case "${OBS_PRIVACY_CASE:-}" in omit-allowed) count=0;; *) count=1;; esac;;
	*) count=1;;
	esac
	case "${OBS_PRIVACY_CASE:-}" in malformed-search) printf '{' > "$out";; canary-present) printf '{"hits":[{"count":1}]}' > "$out";; delayed) if [ "$count" = 1 ] && [ ! -e "$OBS_PRIVACY_STATE" ]; then : > "$OBS_PRIVACY_STATE"; count=0; fi; printf '{"hits":[{"count":%s}]}' "$count" > "$out";; *) printf '{"hits":[{"count":%s}]}' "$count" > "$out";; esac;;
*'/otlp/ai/v1/traces'*) now=$(date +%s); jq -e --argjson min "$((now - 5))000000000" '.resourceSpans[0].resource.attributes[] | select(.key == "telemetry.synthetic" and .value.boolValue == true)' "$body" >/dev/null; jq -e --argjson min "$((now - 5))000000000" '.resourceSpans[0].scopeSpans[0].spans as $spans | (($spans | length) > 0 and (($spans | map(.spanId) | unique | length) == ($spans | length))) and all($spans[]; (.startTimeUnixNano | tonumber) >= $min and (.endTimeUnixNano | tonumber) >= $min) and any($spans[]; (.events | length > 0) and (.links | length > 0) and (.traceState | contains("CANARY")) and (.status.message | contains("CANARY")))' "$body" >/dev/null;;
*'/otlp/'*) jq -e 'has("resourceMetrics") or has("resourceSpans") or has("resourceLogs")' "$body" >/dev/null;;
*) : > "$out";;
esac
case "${OBS_PRIVACY_CASE:-}" in non-200) printf 403;; *) case "$url" in *'/otlp/homelab/v1/traces'|*'/otlp/ai/v1/logs') printf 403;; *) printf 200;; esac;; esac
STUB
	chmod 0755 "$stub_bin/curl"
	receipt=$tmp_dir/receipt
	ops_manifest "$repo_dir" > "$tmp_dir/self.manifest"
	self_source=$(ops_manifest_digest "$tmp_dir/self.manifest")
	printf 'format=observability-preflight-v3\ntarget=test@flatcar.invalid\nsource_digest=%s\nbaseline=%064d\npreflight_digest=%064d\nrecording_nvr=1700000000\nrecording_nvr2=1700000001\norigin=%s\ncertificate_name=%s\n' "$self_source" 0 1 "$(ops_origin)" "$(ops_certificate_name)" > "$receipt"
	base_url=$(ops_origin)
	HOMELAB_OTLP_TOKEN='SELF_SECRET_HOMELAB'; AI_OTLP_TOKEN='SELF_SECRET_AI'; ZO_ROOT_USER_EMAIL='SELF_SECRET_USER'; ZO_ROOT_USER_PASSWORD='SELF_SECRET_PASSWORD'
	export HOMELAB_OTLP_TOKEN AI_OTLP_TOKEN ZO_ROOT_USER_EMAIL ZO_ROOT_USER_PASSWORD
	PATH="$stub_bin:$PATH" run_live
	predicate field '1not-a-number' | grep -F "'1not-a-number'" >/dev/null || fail 'non-numeric literal was not quoted'
	# Active parser/transport mutations must fail closed; a delayed allowed
	# record is retried and then succeeds without printing any response body.
	for mutation in empty-inventory malformed malformed-search missing-field omit-allowed canary-present non-200 real-ai-present; do
		if (OBS_PRIVACY_CASE=$mutation PATH="$stub_bin:$PATH" run_live >/dev/null 2>&1); then fail "privacy mutation accepted: $mutation"; fi
	done
	if (base_url=https://wrong.example.invalid PATH="$stub_bin:$PATH" run_live >/dev/null 2>&1); then fail 'wrong receipt origin accepted'; fi
	base_url=$(ops_origin)
	rm -f "$tmp_dir/delayed"
	OBS_PRIVACY_CASE=delayed OBS_PRIVACY_STATE="$tmp_dir/delayed" PATH="$stub_bin:$PATH" run_live >/dev/null
}

if [ "$#" -eq 1 ] && [ "$1" = --self-test ]; then self_test; exit 0; fi
[ "$#" -eq 2 ] || usage
base_url=$1; receipt=$2
run_live
