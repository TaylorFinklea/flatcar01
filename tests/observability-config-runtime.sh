#!/bin/sh
# Disposable, pinned-image validation. It never contacts the Flatcar host.
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_base=${TMPDIR:-/tmp}
tmp_dir=
runtime_started=false
runtime_id=
runtime_network=
openobserve_name=
gateway_name=
sink_name=
openobserve_volume=
capture_volume=
tmpfs_probe_name=
queue_usage_method=unavailable
sanitized_carrier_queues_entered=false
sanitized_carrier_queues_drained=false
unsanitized_carrier_queues_entered=false
unsanitized_carrier_queues_drained=false

fail() { printf '%s\n' "$1" >&2; exit 1; }
usage() { printf 'usage: %s [--self-test]\n' "$0" >&2; exit 2; }

safe_remove_tmp() {
	case "$1" in
	"$tmp_base"/observability-runtime.*) rm -rf "$1" ;;
	*) return 1 ;;
	esac
}

docker_quiet() {
	docker "$@" >"$tmp_dir/docker.stdout" 2>"$tmp_dir/docker.stderr"
}

cleanup() {
	if [ "$runtime_started" = true ]; then
		[ -z "$gateway_name" ] || docker_quiet rm --force "$gateway_name" || :
		[ -z "$sink_name" ] || docker_quiet rm --force "$sink_name" || :
		[ -z "$openobserve_name" ] || docker_quiet rm --force "$openobserve_name" || :
		[ -z "$capture_volume" ] || docker_quiet volume rm "$capture_volume" || :
		[ -z "$openobserve_volume" ] || docker_quiet volume rm "$openobserve_volume" || :
		[ -z "$tmpfs_probe_name" ] || docker_quiet rm --force "$tmpfs_probe_name" || :
		[ -z "$runtime_network" ] || docker_quiet network rm "$runtime_network" || :
	fi
	[ -z "$tmp_dir" ] || safe_remove_tmp "$tmp_dir" || :
}
trap cleanup EXIT HUP INT TERM

fixture_inventory() {
	for fixture in homelab-metrics homelab-traces ai-metrics ai-traces ai-logs; do
		path=$repo_dir/tests/fixtures/observability/$fixture.json
		jq -e '(.canaries | type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z0-9._-]{1,128}$"))) and (.input | type == "object") and (.expected | type == "object")' "$path" >/dev/null || return 1
	done
}

make_private_tmp() {
	umask 077
	tmp_dir=$(mktemp -d "$tmp_base/observability-runtime.XXXXXX") || fail 'cannot create private runtime directory'
}

parse_args() {
	case "$#:$*" in
	1:--self-test) printf '%s\n' self-test ;;
	0:) printf '%s\n' runtime ;;
	*) return 2 ;;
	esac
}

self_test() {
	fixture_inventory || fail 'synthetic fixture inventory is invalid'
	make_private_tmp
	expected_capture_contract > "$tmp_dir/expected-capture.json" || fail 'fixture-specific structural capture contract is invalid'
	jq -e '(.metrics | type == "array" and length > 0) and (.traces | type == "array" and length > 0)' "$tmp_dir/expected-capture.json" >/dev/null || fail 'fixture-specific structural capture contract is incomplete'
	printf '%s\n' 'HTTP/1.1 202 Accepted' > "$tmp_dir/http-header"
	printf '%s\n' 'wget: server returned error: HTTP/1.1 401 Unauthorized' > "$tmp_dir/http-error"
	[ "$(http_status_from_wget "$tmp_dir/http-header")" = 202 ] || fail 'HTTP-header parser rejected an accepted response'
	[ "$(http_status_from_wget "$tmp_dir/http-error")" = 401 ] || fail 'HTTP-error parser did not extract the rejected response status'
	printf '%s\n' \
		'otelcol_exporter_queue_size{exporter="otlp_http/homelab_metrics"} 17' \
		'otelcol_exporter_queue_size{exporter="otlp_http/ai_metrics"} 29' \
		'otelcol_exporter_queue_size{exporter="otlp_http/ai_traces"} 31' > "$tmp_dir/gateway-self.prom"
	[ "$(gateway_self_metric_total_from_snapshot otelcol_exporter_queue_size otlp_http/homelab_metrics)" = 17 ] || fail 'per-exporter queue parser collapsed homelab exporter into an aggregate'
	[ "$(gateway_self_metric_total_from_snapshot otelcol_exporter_queue_size otlp_http/ai_metrics)" = 29 ] || fail 'per-exporter queue parser collapsed AI-metrics exporter into an aggregate'
	[ "$(gateway_self_metric_total_from_snapshot otelcol_exporter_queue_size otlp_http/ai_traces)" = 31 ] || fail 'per-exporter queue parser collapsed AI-traces exporter into an aggregate'
	[ "$(gateway_self_metric_total_from_snapshot otelcol_exporter_queue_size)" = 77 ] || fail 'aggregate Collector queue metric parser no longer sums intentionally unscoped calls'
	assert_exporter_queue_state_from_snapshot otlp_http/homelab_metrics nonzero || fail 'nonzero per-exporter queue proof rejected a populated exact exporter queue'
	printf '%s\n' \
		'otelcol_exporter_queue_size{exporter="otlp_http/homelab_metrics"} 0' \
		'otelcol_exporter_queue_size{exporter="otlp_http/ai_metrics"} 0' \
		'otelcol_exporter_queue_size{exporter="otlp_http/ai_traces"} 0' > "$tmp_dir/gateway-self.prom"
	if assert_exporter_queue_state_from_snapshot otlp_http/homelab_metrics nonzero; then fail 'nonzero per-exporter queue proof accepted a drained exact exporter queue'; fi
	assert_exporter_queue_state_from_snapshot otlp_http/homelab_metrics empty || fail 'drain per-exporter queue proof rejected an empty exact exporter queue'
	if assert_exporter_queue_state_from_snapshot otlp_http/missing_exporter nonzero; then fail 'nonzero per-exporter queue proof accepted a missing exact exporter series'; fi
	if assert_exporter_queue_state_from_snapshot otlp_http/missing_exporter empty; then fail 'drain per-exporter queue proof accepted a missing exact exporter series'; fi
	printf '%s\n' '{"canary":"self-test-canary"}' '{"safe":true}' > "$tmp_dir/canary-documents.json"
	if capture_excludes_literal "$tmp_dir/canary-documents.json" self-test-canary; then fail 'all-document canary check ignored an earlier JSON document'; fi
	make_contract_capture "$tmp_dir/mutation-input.json" || fail 'structural control capture could not be generated'
	assert_capture_contract "$tmp_dir/mutation-input.json" || fail 'structural control capture was rejected'
	if sanitized_carrier_queue_proofs_complete; then fail 'sanitized capture proof gate accepted a skipped carrier queue phase'; fi
	sanitized_carrier_queues_entered=true
	sanitized_carrier_queues_drained=true
	sanitized_carrier_queue_proofs_complete || fail 'sanitized capture proof gate rejected completed carrier queue phases'
	make_unsanitized_carrier_control_otlp "$tmp_dir/unsanitized-carrier-control.json"
	if unsanitized_carrier_queue_proofs_complete; then fail 'unsanitized capture proof gate accepted a skipped carrier queue phase'; fi
	unsanitized_carrier_queues_entered=true
	unsanitized_carrier_queues_drained=true
	unsanitized_carrier_queue_proofs_complete || fail 'unsanitized capture proof gate rejected completed carrier queue phases'
	if split_unsanitized_carrier_control_otlp "$tmp_dir/unsanitized-carrier-control.json" "$tmp_dir/unsanitized-metrics-only.json" "$tmp_dir/unsanitized-traces-only.json" >/dev/null 2>&1 &&
		jq -e 'keys == ["resourceMetrics"] and (.resourceMetrics | length == 2)' "$tmp_dir/unsanitized-metrics-only.json" >/dev/null &&
		jq -e 'keys == ["resourceSpans"] and (.resourceSpans | length == 2)' "$tmp_dir/unsanitized-traces-only.json" >/dev/null; then
		:
	else
		fail 'unsanitized carrier control did not split metrics and traces into protocol-valid OTLP documents'
	fi
	jq -s '.[]' "$tmp_dir/unsanitized-metrics-only.json" "$tmp_dir/unsanitized-traces-only.json" > "$tmp_dir/unsanitized-carrier-capture.json"
	unsanitized_carrier_capture_matches "$tmp_dir/unsanitized-carrier-capture.json" || fail 'unsanitized carrier structural control was rejected'
	jq -e '
		def resource_has_entity_ref_attributes:
			([.attributes[]?.key] | unique) as $attribute_keys |
			all(.entityRefs[]?; (.idKeys + .descriptionKeys) | all(.[]; . as $key | ($attribute_keys | index($key) != null)));
		[.resourceMetrics[].resource, .resourceSpans[].resource] | all(.[]; resource_has_entity_ref_attributes)
	' "$tmp_dir/unsanitized-carrier-control.json" >/dev/null || fail 'unsanitized carrier control omitted Resource attributes required by entity reference keys'
	jq -s 'map(if .resourceMetrics? then del(.resourceMetrics[0].resource.attributes[0]) else . end)[]' "$tmp_dir/unsanitized-carrier-capture.json" > "$tmp_dir/unsanitized-metrics-attribute-lost.json"
	if unsanitized_carrier_capture_matches "$tmp_dir/unsanitized-metrics-attribute-lost.json"; then fail 'unsanitized exact oracle accepted missing metrics Resource attribute'; fi
	jq -s 'map(if .resourceMetrics? then (.resourceMetrics[0].resource.attributes[0].value.stringValue = "runtime-unsanitized-metrics-value-mutated") else . end)[]' "$tmp_dir/unsanitized-carrier-capture.json" > "$tmp_dir/unsanitized-metrics-attribute-changed.json"
	if unsanitized_carrier_capture_matches "$tmp_dir/unsanitized-metrics-attribute-changed.json"; then fail 'unsanitized exact oracle accepted changed metrics Resource attribute value'; fi
	jq -s 'map(if .resourceSpans? then del(.resourceSpans[0].resource.attributes[0]) else . end)[]' "$tmp_dir/unsanitized-carrier-capture.json" > "$tmp_dir/unsanitized-traces-attribute-lost.json"
	if unsanitized_carrier_capture_matches "$tmp_dir/unsanitized-traces-attribute-lost.json"; then fail 'unsanitized exact oracle accepted missing traces Resource attribute'; fi
	jq -s 'map(if .resourceSpans? then (.resourceSpans[0].resource.attributes[0].value.stringValue = "runtime-unsanitized-traces-value-mutated") else . end)[]' "$tmp_dir/unsanitized-carrier-capture.json" > "$tmp_dir/unsanitized-traces-attribute-changed.json"
	if unsanitized_carrier_capture_matches "$tmp_dir/unsanitized-traces-attribute-changed.json"; then fail 'unsanitized exact oracle accepted changed traces Resource attribute value'; fi
	jq -s '(map(select(.resourceSpans?))[0].resourceSpans[0].resource) as $source | map(if .resourceMetrics? then (.resourceMetrics[0].resource = $source) else . end)[]' "$tmp_dir/unsanitized-carrier-capture.json" > "$tmp_dir/unsanitized-traces-normal-relocated-to-metrics.json"
	if unsanitized_carrier_capture_matches "$tmp_dir/unsanitized-traces-normal-relocated-to-metrics.json"; then fail 'unsanitized exact oracle accepted traces-normal Resource relocation into metrics'; fi
	jq -s '(map(select(.resourceMetrics?))[0].resourceMetrics[0].resource) as $source | map(if .resourceSpans? then (.resourceSpans[0].resource = $source) else . end)[]' "$tmp_dir/unsanitized-carrier-capture.json" > "$tmp_dir/unsanitized-metrics-normal-relocated-to-traces.json"
	if unsanitized_carrier_capture_matches "$tmp_dir/unsanitized-metrics-normal-relocated-to-traces.json"; then fail 'unsanitized exact oracle accepted metrics-normal Resource relocation into traces'; fi
	jq -s '(map(select(.resourceSpans?))[0].resourceSpans[1].resource) as $source | map(if .resourceMetrics? then (.resourceMetrics[1].resource = $source) else . end)[]' "$tmp_dir/unsanitized-carrier-capture.json" > "$tmp_dir/unsanitized-traces-empty-relocated-to-metrics.json"
	if unsanitized_carrier_capture_matches "$tmp_dir/unsanitized-traces-empty-relocated-to-metrics.json"; then fail 'unsanitized exact oracle accepted traces-empty Resource relocation into metrics'; fi
	jq -s '(map(select(.resourceMetrics?))[0].resourceMetrics[1].resource) as $source | map(if .resourceSpans? then (.resourceSpans[1].resource = $source) else . end)[]' "$tmp_dir/unsanitized-carrier-capture.json" > "$tmp_dir/unsanitized-metrics-empty-relocated-to-traces.json"
	if unsanitized_carrier_capture_matches "$tmp_dir/unsanitized-metrics-empty-relocated-to-traces.json"; then fail 'unsanitized exact oracle accepted metrics-empty Resource relocation into traces'; fi
	jq -s '(map(select(.resourceSpans?))[0].resourceSpans[0].resource) as $source | map(if .resourceMetrics? then (.resourceMetrics[0].resource |= (.attributes += $source.attributes | .entityRefs += $source.entityRefs)) else . end)[]' "$tmp_dir/unsanitized-carrier-capture.json" > "$tmp_dir/unsanitized-traces-normal-appended-to-metrics.json"
	if unsanitized_carrier_capture_matches "$tmp_dir/unsanitized-traces-normal-appended-to-metrics.json"; then fail 'unsanitized exact oracle accepted traces-normal Resource identity appended to metrics'; fi
	jq -s '(map(select(.resourceMetrics?))[0].resourceMetrics[0].resource) as $source | map(if .resourceSpans? then (.resourceSpans[0].resource |= (.attributes += $source.attributes | .entityRefs += $source.entityRefs)) else . end)[]' "$tmp_dir/unsanitized-carrier-capture.json" > "$tmp_dir/unsanitized-metrics-normal-appended-to-traces.json"
	if unsanitized_carrier_capture_matches "$tmp_dir/unsanitized-metrics-normal-appended-to-traces.json"; then fail 'unsanitized exact oracle accepted metrics-normal Resource identity appended to traces'; fi
	jq -s '(map(select(.resourceSpans?))[0].resourceSpans[1].resource) as $source | map(if .resourceMetrics? then (.resourceMetrics[1].resource |= (.attributes += $source.attributes | .entityRefs += $source.entityRefs)) else . end)[]' "$tmp_dir/unsanitized-carrier-capture.json" > "$tmp_dir/unsanitized-traces-empty-appended-to-metrics.json"
	if unsanitized_carrier_capture_matches "$tmp_dir/unsanitized-traces-empty-appended-to-metrics.json"; then fail 'unsanitized exact oracle accepted traces-empty Resource identity appended to metrics'; fi
	jq -s '(map(select(.resourceMetrics?))[0].resourceMetrics[1].resource) as $source | map(if .resourceSpans? then (.resourceSpans[1].resource |= (.attributes += $source.attributes | .entityRefs += $source.entityRefs)) else . end)[]' "$tmp_dir/unsanitized-carrier-capture.json" > "$tmp_dir/unsanitized-metrics-empty-appended-to-traces.json"
	if unsanitized_carrier_capture_matches "$tmp_dir/unsanitized-metrics-empty-appended-to-traces.json"; then fail 'unsanitized exact oracle accepted metrics-empty Resource identity appended to traces'; fi
	jq -s 'map(if .resourceMetrics? then (.resourceMetrics[1].scopeMetrics = [{scope: {}, metrics: []}]) else . end)[]' "$tmp_dir/unsanitized-carrier-capture.json" > "$tmp_dir/unsanitized-metrics-empty-scope-nonempty.json"
	if unsanitized_carrier_capture_matches "$tmp_dir/unsanitized-metrics-empty-scope-nonempty.json"; then fail 'unsanitized exact oracle accepted a nonempty formerly-empty metrics scope'; fi
	jq -s 'map(if .resourceSpans? then (.resourceSpans[1].scopeSpans = [{scope: {}, spans: []}]) else . end)[]' "$tmp_dir/unsanitized-carrier-capture.json" > "$tmp_dir/unsanitized-traces-empty-scope-nonempty.json"
	if unsanitized_carrier_capture_matches "$tmp_dir/unsanitized-traces-empty-scope-nonempty.json"; then fail 'unsanitized exact oracle accepted a nonempty formerly-empty traces scope'; fi
	jq -s 'map(if .resourceMetrics? then (.resourceMetrics[1].resource.attributes += [{key: "runtime.unsanitized.unexpected", value: {stringValue: "unexpected"}}]) else . end)[]' "$tmp_dir/unsanitized-carrier-capture.json" > "$tmp_dir/unsanitized-metrics-empty-resource-malformed.json"
	if unsanitized_carrier_capture_matches "$tmp_dir/unsanitized-metrics-empty-resource-malformed.json"; then fail 'unsanitized exact oracle accepted a malformed formerly-empty metrics Resource'; fi
	jq -s 'map(if .resourceSpans? then (.resourceSpans[1].resource.droppedAttributesCount = 1) else . end)[]' "$tmp_dir/unsanitized-carrier-capture.json" > "$tmp_dir/unsanitized-traces-empty-resource-malformed.json"
	if unsanitized_carrier_capture_matches "$tmp_dir/unsanitized-traces-empty-resource-malformed.json"; then fail 'unsanitized exact oracle accepted a malformed formerly-empty traces Resource'; fi
	jq -s 'map(if .resourceMetrics? then (.resourceMetrics[0].scopeMetrics[0].metrics[0].metadata = []) else . end)[]' "$tmp_dir/unsanitized-carrier-capture.json" > "$tmp_dir/unsanitized-metadata-mutated.json"
	if unsanitized_carrier_capture_matches "$tmp_dir/unsanitized-metadata-mutated.json"; then fail 'unsanitized carrier structural control accepted missing metric metadata'; fi
	jq -s 'map(if .resourceSpans? then (.resourceSpans[0].resource.entityRefs = []) else . end)[]' "$tmp_dir/unsanitized-carrier-capture.json" > "$tmp_dir/unsanitized-entity-mutated.json"
	if unsanitized_carrier_capture_matches "$tmp_dir/unsanitized-entity-mutated.json"; then fail 'unsanitized carrier structural control accepted missing populated resource entity references'; fi
	mutate_capture_attribute "$tmp_dir/mutation-input.json" "$tmp_dir/mutation-output.json" || fail 'structural mutation fixture could not be generated'
	jq -s -e 'length > 1 and ([.[] | select(.resourceSpans?) | .resourceSpans[0].scopeSpans[0].spans[0].attributes[] | select(.key == "mutation.forbidden")] | length) == 1' "$tmp_dir/mutation-output.json" >/dev/null || fail 'structural mutation did not preserve every JSON document'
	if assert_capture_contract "$tmp_dir/mutation-output.json"; then fail 'structural contract reported success for a false capture'; fi
	mutate_capture_metric_metadata "$tmp_dir/mutation-input.json" "$tmp_dir/metadata-mutation-output.json" || fail 'metric metadata mutation fixture could not be generated'
	if assert_capture_contract "$tmp_dir/metadata-mutation-output.json"; then fail 'structural contract accepted forbidden metric metadata'; fi
	mutate_capture_metric_entity_refs "$tmp_dir/mutation-input.json" "$tmp_dir/metric-entity-mutation-output.json" || fail 'metric entity-reference mutation fixture could not be generated'
	assert_capture_entity_ref_mutation "$tmp_dir/mutation-input.json" "$tmp_dir/metric-entity-mutation-output.json" resourceMetrics resourceSpans || fail 'metric-only entity-reference mutation changed an untouched document or was not protocol-valid'
	if assert_capture_contract "$tmp_dir/metric-entity-mutation-output.json"; then fail 'structural contract accepted forbidden metric resource entity references'; fi
	mutate_capture_trace_entity_refs "$tmp_dir/mutation-input.json" "$tmp_dir/trace-entity-mutation-output.json" || fail 'trace entity-reference mutation fixture could not be generated'
	assert_capture_entity_ref_mutation "$tmp_dir/mutation-input.json" "$tmp_dir/trace-entity-mutation-output.json" resourceSpans resourceMetrics || fail 'trace-only entity-reference mutation changed an untouched document or was not protocol-valid'
	if assert_capture_contract "$tmp_dir/trace-entity-mutation-output.json"; then fail 'structural contract accepted forbidden trace resource entity references'; fi
	[ "$(stat -f '%Lp' "$tmp_dir")" = 700 ] || fail 'runtime temporary directory is not private'
	test_secret='RUNTIME_TEST_ONLY_REDACTED'
	printf '%s\n' "$test_secret" > "$tmp_dir/literal-test-credential"
	chmod 0600 "$tmp_dir/literal-test-credential"
	[ "$(stat -f '%Lp' "$tmp_dir/literal-test-credential")" = 600 ] || fail 'literal test credential is not private'
	printf '%s\n' 'runtime self-test: test credentials are redacted' > "$tmp_dir/self-test.log"
	if rg -F -- "$test_secret" "$tmp_dir/self-test.log" >/dev/null; then fail 'literal test credential escaped redaction'; fi
	stub_dir=$tmp_dir/stub-bin
	stub_tmp=$tmp_dir/full-subprocess-tmp
	mkdir "$stub_dir" "$stub_tmp"
	printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "RUNTIME_TEST_ONLY_REDACTED" >&2' 'exit 99' > "$stub_dir/docker"
	chmod 0755 "$stub_dir/docker"
	PATH="$stub_dir:$PATH" parse_args --self-test >/dev/null || fail 'self-test argument parsing failed'
	if (parse_args --invalid) >/dev/null 2>&1; then fail 'invalid argument was accepted'; fi
	set +e
	PATH="$stub_dir:$PATH" TMPDIR="$stub_tmp" "$repo_dir/tests/observability-config-runtime.sh" > "$tmp_dir/full-stub.stdout" 2> "$tmp_dir/full-stub.stderr"
	full_stub_status=$?
	set -e
	[ "$full_stub_status" -ne 0 ] || fail 'full runtime mode unexpectedly succeeded with a failing Docker stub'
	if rg -F -- 'RUNTIME_TEST_ONLY_REDACTED' "$tmp_dir/full-stub.stdout" "$tmp_dir/full-stub.stderr" >/dev/null; then fail 'full runtime failure leaked the literal test secret'; fi
	if find "$stub_tmp" -name 'observability-runtime.*' -print -quit | rg -q .; then fail 'full runtime failure left a temporary directory behind'; fi
	cleanup_probe=$(mktemp -d "$tmp_base/observability-runtime.XXXXXX") || fail 'cannot create cleanup probe'
	safe_remove_tmp "$cleanup_probe" || fail 'cleanup probe was outside the permitted temporary scope'
	[ ! -e "$cleanup_probe" ] || fail 'temporary cleanup did not remove its target'
	printf '%s\n' 'runtime self-test: fixtures, parsing, cleanup, literal-test isolation, redaction, and no-daemon exit handling passed'
}

require_docker() {
	command -v docker >/dev/null 2>&1 || fail 'Docker is unavailable; full runtime validation is pending Gate C'
	docker version --format '{{.Server.Version}}' > "$tmp_dir/docker-version" 2> "$tmp_dir/docker-version.err" || fail 'Docker daemon is unavailable; full runtime validation is pending Gate C'
}

require_image() {
	image=$1
	digest=${image##*@}
	docker_quiet image inspect "$image" || fail 'required pinned image is unavailable locally; image pulls are forbidden'
	jq -e --arg digest "$digest" '.[0] | .Os == "linux" and .Architecture == "amd64" and ((.RepoDigests // []) | any(contains($digest)))' "$tmp_dir/docker.stdout" >/dev/null || fail 'required image is not the exact linux/amd64 digest'
}

load_images() {
	# The tracked file is non-secret and separately lock-tested.
	. "$repo_dir/config/observability/images.env"
	: "${OPENOBSERVE_IMAGE:?}" "${OTELCOL_IMAGE:?}" "${CADDY_IMAGE:?}"
}

write_test_environment() {
	printf '%s\n' 'OPENOBSERVE_INGEST_AUTH_HEADER=Bearer RUNTIME_TEST_ONLY' > "$tmp_dir/collector.env"
	printf '%s\n' \
		'CLOUDFLARE_API_TOKEN=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn' \
		'HOMELAB_OTLP_TOKEN=RUNTIME_TEST_ONLY' \
		'AI_OTLP_TOKEN=RUNTIME_TEST_ONLY' > "$tmp_dir/caddy.env"
	cp "$repo_dir/config/observability/openobserve.env" "$tmp_dir/openobserve.env"
	printf '%s\n' \
		'ZO_ROOT_USER_EMAIL=runtime-test@example.invalid' \
		'ZO_ROOT_USER_PASSWORD=Runtime-test1!' >> "$tmp_dir/openobserve.env"
	chmod 0600 "$tmp_dir/collector.env" "$tmp_dir/caddy.env" "$tmp_dir/openobserve.env"
}

validate_collector_config() {
	config_path=$1
	output_path=$2
	error_path=$3
	docker run --rm --pull=never --platform linux/amd64 --network none \
		--user 10001:10001 --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=32m \
		--env-file "$tmp_dir/collector.env" \
		--mount type=bind,source="$config_path",target=/etc/otelcol/config.yaml,readonly \
		"$OTELCOL_IMAGE" validate --config=/etc/otelcol/config.yaml --feature-gates=+ottl.set.allowNil > "$output_path" 2> "$error_path"
}

validate_collectors() {
	pids=
	index=1
	for config_path in "$repo_dir/config/observability/otel-gateway.yaml" "$repo_dir/config/observability/otel-gateway-systemd.yaml" "$repo_dir/config/observability/otel-docker-agent.yaml"; do
		validate_collector_config "$config_path" "$tmp_dir/collector-validate-$index.stdout" "$tmp_dir/collector-validate-$index.stderr" &
		pids="$pids $!"
		index=$((index + 1))
	done
	status=0
	for pid in $pids; do wait "$pid" || status=1; done
	[ "$status" -eq 0 ] || fail 'pinned Collector rejected a tracked configuration'
}

validate_caddy() {
	caddyfile=$repo_dir/config/observability/Caddyfile
	docker run --rm --pull=never --platform linux/amd64 --network none \
		--user 20002:20002 --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=32m \
		--env-file "$tmp_dir/caddy.env" \
		--mount type=bind,source="$caddyfile",target=/etc/caddy/Caddyfile,readonly \
		"$CADDY_IMAGE" caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile > "$tmp_dir/caddy-adapted.json" 2> "$tmp_dir/caddy-adapt.stderr" &
	adapt_pid=$!
	docker run --rm --pull=never --platform linux/amd64 --network none \
		--user 20002:20002 --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=32m \
		--env-file "$tmp_dir/caddy.env" \
		--mount type=bind,source="$caddyfile",target=/etc/caddy/Caddyfile,readonly \
		"$CADDY_IMAGE" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile > "$tmp_dir/caddy-validate.stdout" 2> "$tmp_dir/caddy-validate.stderr" &
	validate_pid=$!
	wait "$adapt_pid" || fail 'pinned Caddy could not adapt the tracked Caddyfile'
	jq -e '
		(.apps.http.servers | type == "object") and
		([.apps.http.servers[] | .listen[]?] == ["10.10.10.50:443"]) and
		(.admin.disabled == true) and
		([.. | strings | select(. == "h3")] | length == 0) and
		([.. | objects | .dial? // empty] | sort == ["127.0.0.1:4318", "127.0.0.1:4319", "127.0.0.1:5080"])
	' "$tmp_dir/caddy-adapted.json" >/dev/null || fail 'adapted Caddy topology differs from the LAN-only contract'
	wait "$validate_pid" || fail 'pinned Caddy rejected the tracked Caddyfile'
}

create_volume_for_uid() {
	volume=$1
	uid=$2
	case "$uid" in
	''|*[!0-9]*) fail 'disposable volume owner must be numeric' ;;
	esac
	docker_quiet volume create "$volume" || fail 'cannot create disposable Docker volume'
	docker_quiet run --rm --pull=never --platform linux/amd64 --network none --user 0 \
		--mount type=volume,source="$volume",target=/work \
		--entrypoint /bin/sh "$CADDY_IMAGE" -c "chown $uid:$uid /work && test \"\$(stat -c '%u:%g' /work)\" = '$uid:$uid'" || fail 'cannot initialize disposable Docker volume with its required owner'
}

container_inspect() {
	docker inspect "$1" > "$tmp_dir/inspect.json" 2> "$tmp_dir/inspect.stderr" || return 1
}

wait_openobserve_health() {
	attempt=1
	while [ "$attempt" -le 30 ]; do
		if docker run --rm --pull=never --platform linux/amd64 --network "container:$openobserve_name" \
			--read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m \
			--entrypoint /bin/sh "$CADDY_IMAGE" -c 'wget -q -T 2 -O - http://127.0.0.1:5080/healthz' > "$tmp_dir/openobserve-health" 2> "$tmp_dir/openobserve-health.stderr"; then
			return 0
		fi
		attempt=$((attempt + 1))
		sleep 1
	done
	return 1
}

write_openobserve_durable_data() {
	docker_quiet run --rm --pull=never --platform linux/amd64 --network none --user 20001:20001 \
		--read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m \
		--mount type=volume,source="$openobserve_volume",target=/work \
		--entrypoint /bin/sh "$CADDY_IMAGE" -c 'umask 077; : > /work/.task9-uid20001-write; test -f /work/.task9-uid20001-write' || fail 'UID 20001 cannot write the durable OpenObserve volume'
	verify_openobserve_durable_data 'initial write'
}

verify_openobserve_durable_data() {
	phase=$1
	docker_quiet run --rm --pull=never --platform linux/amd64 --network none --user 0 \
		--read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m \
		--mount type=volume,source="$openobserve_volume",target=/work,readonly \
		--entrypoint /bin/sh "$CADDY_IMAGE" -c 'test "$(stat -c "%u:%g:%a" /work/.task9-uid20001-write)" = "20001:20001:600"' || fail "OpenObserve durable UID 20001 data did not survive $phase"
}

validate_openobserve_runtime() {
	openobserve_volume="$runtime_id-openobserve"
	openobserve_name="$runtime_id-openobserve"
	create_volume_for_uid "$openobserve_volume" 20001
	docker_quiet run --detach --pull=never --platform linux/amd64 --name "$openobserve_name" \
		--network "$runtime_network" --user 20001:20001 --read-only --cap-drop=ALL \
		--security-opt no-new-privileges --memory=3g --cpus=2.0 --pids-limit=512 \
		--env-file "$tmp_dir/openobserve.env" \
		--mount type=volume,source="$openobserve_volume",target=/data \
		--tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m,uid=20001,gid=20001,mode=0700 \
		"$OPENOBSERVE_IMAGE" || fail 'pinned OpenObserve did not start under the production hardening flags'
	container_inspect "$openobserve_name" || fail 'cannot inspect disposable OpenObserve container'
	jq -e '
		.[0] as $c |
		$c.Config.User == "20001:20001" and $c.HostConfig.ReadonlyRootfs == true and
		$c.HostConfig.Memory == 3221225472 and $c.HostConfig.NanoCpus == 2000000000 and
		$c.HostConfig.PidsLimit == 512 and $c.HostConfig.CapDrop == ["ALL"] and
		$c.HostConfig.SecurityOpt == ["no-new-privileges"] and
		([ $c.Mounts[] | select(.Destination == "/data" and .Type == "volume") ] | length == 1) and
		([ $c.Config.Env[] | select(. == "ZO_HTTP_ADDR=127.0.0.1" or . == "ZO_HTTP_PORT=5080" or . == "ZO_WEB_URL=https://observe.example.com" or . == "ZO_COOKIE_SECURE_ONLY=true" or . == "ZO_COOKIE_SAME_SITE_LAX=true") ] | length == 5)
	' "$tmp_dir/inspect.json" >/dev/null || fail 'disposable OpenObserve drifted from its required identity, isolation, bounds, or secure URL settings'
	wait_openobserve_health || fail 'disposable OpenObserve did not become healthy on its loopback listener'
	write_openobserve_durable_data
	if docker run --rm --pull=never --platform linux/amd64 --network "$runtime_network" \
		--read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m \
		--entrypoint /bin/sh "$CADDY_IMAGE" -c "wget -q -T 2 -O /dev/null http://$openobserve_name:5080/healthz" > "$tmp_dir/openobserve-nonloopback" 2> "$tmp_dir/openobserve-nonloopback.stderr"; then
		fail 'OpenObserve was reachable outside its loopback network namespace'
	fi
	docker_quiet rm --force "$openobserve_name" || fail 'cannot stop disposable OpenObserve container'
	docker_quiet run --detach --pull=never --platform linux/amd64 --name "$openobserve_name" \
		--network "$runtime_network" --user 20001:20001 --read-only --cap-drop=ALL \
		--security-opt no-new-privileges --memory=3g --cpus=2.0 --pids-limit=512 \
		--env-file "$tmp_dir/openobserve.env" \
		--mount type=volume,source="$openobserve_volume",target=/data \
		--tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m,uid=20001,gid=20001,mode=0700 \
		"$OPENOBSERVE_IMAGE" || fail 'pinned OpenObserve did not restart with its durable volume'
	wait_openobserve_health || fail 'restarted disposable OpenObserve did not become healthy'
	verify_openobserve_durable_data 'restart'
	docker_quiet rm --force "$openobserve_name" || fail 'cannot stop restarted disposable OpenObserve container'
	openobserve_name=
}

make_otlp() {
	fixture=$1
	output=$2
	now_nanos="$(date +%s)000000000"
	case "$fixture" in
	*-metrics)
		jq --arg now "$now_nanos" '
			def attrs:
				to_entries |
				map({
					key: .key,
					value: (
						if (.value | type) == "boolean" then {boolValue: .value}
						elif (.value | type) == "number" then {doubleValue: .value}
						else {stringValue: (.value | tostring)}
						end
					)
				});
			{
				resourceMetrics: [{
					schemaUrl: "https://runtime.invalid/resource-schema-canary",
					resource: {
						attributes: ((.input.resource.attributes + {
							"runtime.entity-id-key-canary": "runtime-entity-id-value-canary",
							"runtime.entity-description-key-canary": "runtime-entity-description-value-canary"
						}) | attrs),
						droppedAttributesCount: 7,
						entityRefs: [{
							schemaUrl: "https://runtime.invalid/entity-schema-canary",
							type: "runtime.entity-type-canary",
							idKeys: ["runtime.entity-id-key-canary"],
							descriptionKeys: ["runtime.entity-description-key-canary"]
						}]
					},
					scopeMetrics: [{
						schemaUrl: "https://runtime.invalid/scope-schema-canary",
						scope: {
							name: "runtime-envelope-canary",
							version: "runtime-envelope-canary",
							attributes: [{key: "runtime.scope.canary", value: {stringValue: "runtime-envelope-canary"}}],
							droppedAttributesCount: 7
						},
						metrics: [
							.input.metrics[] |
							{
								name: .name,
								description: "runtime-metric-description-canary",
								unit: "runtime-metric-unit-canary",
								metadata: [{key: "runtime.metric.metadata-key-canary", value: {stringValue: "runtime-metric-metadata-value-canary"}}],
								gauge: {
									dataPoints: [{
										attributes: (.attributes | attrs),
										asDouble: (.value | tonumber),
										timeUnixNano: $now,
										flags: 255,
										exemplars: [{
											filteredAttributes: [{key: "runtime.exemplar.canary", value: {stringValue: "runtime-exemplar-canary"}}],
											timeUnixNano: $now,
											asDouble: 1,
											spanId: "1111111111111111",
											traceId: "22222222222222222222222222222222"
										}]
									}]
								}
							}
						]
					}]
				}, {
					resource: {
						attributes: [
							{key: "runtime.entity-empty-id-key-canary", value: {stringValue: "runtime-entity-empty-id-value-canary"}},
							{key: "runtime.entity-empty-description-key-canary", value: {stringValue: "runtime-entity-empty-description-value-canary"}}
						],
						entityRefs: [{
							schemaUrl: "https://runtime.invalid/entity-empty-schema-canary",
							type: "runtime.entity-empty-type-canary",
							idKeys: ["runtime.entity-empty-id-key-canary"],
							descriptionKeys: ["runtime.entity-empty-description-key-canary"]
						}]
					},
					scopeMetrics: []
				}]
			}
		' "$repo_dir/tests/fixtures/observability/$fixture.json" > "$output" ;;
	*-traces)
		jq --arg now "$now_nanos" 'def attrs: to_entries | map({key:.key,value:(if (.value|type) == "boolean" then {boolValue:.value} elif (.value|type) == "number" then {doubleValue:.value} else {stringValue:(.value|tostring)} end)}); {resourceSpans:[{schemaUrl:"https://runtime.invalid/resource-schema-canary",resource:{attributes:((.input.resource.attributes+{"runtime.entity-id-key-canary":"runtime-entity-id-value-canary","runtime.entity-description-key-canary":"runtime-entity-description-value-canary"})|attrs),droppedAttributesCount:7,entityRefs:[{schemaUrl:"https://runtime.invalid/entity-schema-canary",type:"runtime.entity-type-canary",idKeys:["runtime.entity-id-key-canary"],descriptionKeys:["runtime.entity-description-key-canary"]}]},scopeSpans:[{schemaUrl:"https://runtime.invalid/scope-schema-canary",scope:{name:"runtime-envelope-canary",version:"runtime-envelope-canary",attributes:[{key:"runtime.scope.canary",value:{stringValue:"runtime-envelope-canary"}}],droppedAttributesCount:7},spans:[.input.spans | to_entries[] | .value as $span | {traceId:"0123456789abcdef0123456789abcdef",spanId:(if .key == 0 then "0123456789abcdef" else "fedcba9876543210" end),parentSpanId:"aaaaaaaaaaaaaaaa",name:$span.name,startTimeUnixNano:$now,endTimeUnixNano:$now,attributes:($span.attributes|attrs),traceState:($span.trace_state // ""),kind:2,flags:255,droppedAttributesCount:7,droppedEventsCount:7,droppedLinksCount:7,status:{code:2,message:($span.status_message // "")},events:[($span.events // [])[] | {timeUnixNano:$now,name:.name,attributes:(.attributes|attrs)}],links:[($span.links // [])[] | {traceId:"11111111111111111111111111111111",spanId:"2222222222222222",attributes:(.attributes|attrs)}]}]}]},{resource:{attributes:[{key:"runtime.entity-empty-id-key-canary",value:{stringValue:"runtime-entity-empty-id-value-canary"}},{key:"runtime.entity-empty-description-key-canary",value:{stringValue:"runtime-entity-empty-description-value-canary"}}],entityRefs:[{schemaUrl:"https://runtime.invalid/entity-empty-schema-canary",type:"runtime.entity-empty-type-canary",idKeys:["runtime.entity-empty-id-key-canary"],descriptionKeys:["runtime.entity-empty-description-key-canary"]}]},scopeSpans:[]}]}' "$repo_dir/tests/fixtures/observability/$fixture.json" > "$output" ;;
	*-logs)
		jq --arg now "$now_nanos" 'def attrs: to_entries | map({key:.key,value:(if (.value|type) == "boolean" then {boolValue:.value} elif (.value|type) == "number" then {doubleValue:.value} else {stringValue:(.value|tostring)} end)}); {resourceLogs:[{resource:{attributes:(.input.resource.attributes|attrs)},scopeLogs:[{scope:{name:"observability-runtime"},logRecords:[.input.logs[] | {timeUnixNano:$now,body:{stringValue:(.body // "")},attributes:(.attributes|attrs)}]}]}]}' "$repo_dir/tests/fixtures/observability/$fixture.json" > "$output" ;;
	*) return 1 ;;
	esac
	jq -e 'type == "object" and (has("resourceMetrics") or has("resourceSpans") or has("resourceLogs"))' "$output" >/dev/null
}

write_sink_config() {
	{
		printf '%s\n' 'receivers:' '  otlp:' '    protocols:' '      http:' '        endpoint: 0.0.0.0:4318'
		printf '%s\n' 'exporters:' '  file:' '    path: /capture/sink.json'
		printf '%s\n' 'service:' '  pipelines:' '    metrics:' '      receivers: [otlp]' '      exporters: [file]' '    traces:' '      receivers: [otlp]' '      exporters: [file]'
	} > "$tmp_dir/sink.yaml"
	chmod 0644 "$tmp_dir/sink.yaml"
}

write_gateway_runtime_config() {
	sed \
		-e 's/endpoint: 127\.0\.0\.1:/endpoint: 0.0.0.0:/g' \
		-e 's#http://127\.0\.0\.1:5080/api/default/v1/metrics#http://task9-sink:4318/v1/metrics#g' \
		-e 's#http://127\.0\.0\.1:5080/api/default/v1/traces#http://task9-sink:4318/v1/traces#g' \
		"$repo_dir/config/observability/otel-gateway.yaml" > "$tmp_dir/otel-gateway-runtime.yaml"
	chmod 0644 "$tmp_dir/otel-gateway-runtime.yaml"
}

write_gateway_fixture_runtime_config() {
	# The production host/self pipelines stay enabled for pinned validation and
	# queue-pressure recovery. Omit only their periodic source traffic while the
	# sink captures the exact authenticated fixture contract.
	awk '
		$0 == "    metrics/host:" || $0 == "    metrics/self:" { skip = 1; next }
		skip && $0 ~ /^    (metrics|traces)\// { skip = 0 }
		!skip { print }
	' "$tmp_dir/otel-gateway-runtime.yaml" > "$tmp_dir/otel-gateway-fixture.yaml"
	mv "$tmp_dir/otel-gateway-fixture.yaml" "$tmp_dir/otel-gateway-runtime.yaml"
	chmod 0644 "$tmp_dir/otel-gateway-runtime.yaml"
}

write_unsanitized_carrier_control_config() {
	{
		printf '%s\n' \
			'extensions:' \
			'  file_storage/unsanitized_metrics:' \
			'    directory: /var/lib/otelcol/queue/unsanitized_metrics' \
			'    create_directory: true' \
			'    directory_permissions: "0750"' \
			'    max_size: 33554432' \
			'  file_storage/unsanitized_traces:' \
			'    directory: /var/lib/otelcol/queue/unsanitized_traces' \
			'    create_directory: true' \
			'    directory_permissions: "0750"' \
			'    max_size: 33554432' \
			'receivers:' \
			'  otlp:' \
			'    protocols:' \
			'      http:' \
			'        endpoint: 0.0.0.0:4318' \
			'processors:' \
			'  batch/metrics:' \
			'    send_batch_size: 512' \
			'    send_batch_max_size: 512' \
			'    timeout: 5s' \
			'  batch/traces:' \
			'    send_batch_size: 128' \
			'    send_batch_max_size: 128' \
			'    timeout: 5s' \
			'exporters:' \
			'  otlp_http/unsanitized_metrics:' \
			'    metrics_endpoint: http://task9-sink:4318/v1/metrics' \
			'    retry_on_failure:' \
			'      max_elapsed_time: 0' \
			'    sending_queue:' \
			'      enabled: true' \
			'      storage: file_storage/unsanitized_metrics' \
			'      sizer: bytes' \
			'      queue_size: 25165824' \
			'      block_on_overflow: false' \
			'  otlp_http/unsanitized_traces:' \
			'    traces_endpoint: http://task9-sink:4318/v1/traces' \
			'    retry_on_failure:' \
			'      max_elapsed_time: 0' \
			'    sending_queue:' \
			'      enabled: true' \
			'      storage: file_storage/unsanitized_traces' \
			'      sizer: bytes' \
			'      queue_size: 25165824' \
			'      block_on_overflow: false' \
			'service:' \
			'  telemetry:' \
			'    metrics:' \
			'      level: detailed' \
			'      readers:' \
			'        - pull:' \
			'            exporter:' \
			'              prometheus:' \
			'                host: 127.0.0.1' \
			'                port: 8888' \
			'                without_scope_info: true' \
			'                without_type_suffix: true' \
			'                without_units: true' \
			'                with_resource_constant_labels:' \
			'                  included: []' \
			'  extensions: [file_storage/unsanitized_metrics, file_storage/unsanitized_traces]' \
			'  pipelines:' \
			'    metrics:' \
			'      receivers: [otlp]' \
			'      processors: [batch/metrics]' \
			'      exporters: [otlp_http/unsanitized_metrics]' \
			'    traces:' \
			'      receivers: [otlp]' \
			'      processors: [batch/traces]' \
			'      exporters: [otlp_http/unsanitized_traces]'
	} > "$tmp_dir/otel-unsanitized-carrier-control.yaml"
	chmod 0644 "$tmp_dir/otel-unsanitized-carrier-control.yaml"
}

make_unsanitized_carrier_control_otlp() {
	output=$1
	now_nanos="$(date +%s)000000000"
	jq -n --arg now "$now_nanos" '
		def entity_ref($kind): {
			schemaUrl: ("https://runtime.invalid/unsanitized-" + $kind + "-entity-schema"),
			type: ("runtime.unsanitized." + $kind + ".entity"),
			idKeys: [("runtime.unsanitized." + $kind + ".id")],
			descriptionKeys: [("runtime.unsanitized." + $kind + ".description")]
		};
		def resource($kind): {
			attributes: [
				{key: ("runtime.unsanitized." + $kind + ".id"), value: {stringValue: ("runtime-unsanitized-" + $kind + "-id-value")}},
				{key: ("runtime.unsanitized." + $kind + ".description"), value: {stringValue: ("runtime-unsanitized-" + $kind + "-description-value")}}
			],
			entityRefs: [entity_ref($kind)]
		};
		{
			resourceMetrics: [
				{
					resource: resource("metrics-normal"),
					scopeMetrics: [{
						scope: {name: "runtime-unsanitized-carrier-control"},
						metrics: [{
							name: "runtime.unsanitized.metric",
							metadata: [{key: "runtime.unsanitized.metadata", value: {stringValue: "runtime-unsanitized-metadata-value"}}],
							gauge: {dataPoints: [{asDouble: 1, timeUnixNano: $now}]}
						}]
					}]
				},
				{resource: resource("metrics-empty"), scopeMetrics: []}
			],
			resourceSpans: [
				{
					resource: resource("traces-normal"),
					scopeSpans: [{
						scope: {name: "runtime-unsanitized-carrier-control"},
						spans: [{
							traceId: "0123456789abcdef0123456789abcdef",
							spanId: "0123456789abcdef",
							name: "runtime.unsanitized.trace",
							startTimeUnixNano: $now,
							endTimeUnixNano: $now
						}]
					}]
				},
				{resource: resource("traces-empty"), scopeSpans: []}
			]
		}
	' > "$output"
	jq -e 'type == "object" and (.resourceMetrics | length == 2) and (.resourceSpans | length == 2)' "$output" >/dev/null || fail 'cannot build unsanitized carrier control payload'
}

split_unsanitized_carrier_control_otlp() {
	input=$1
	metrics_output=$2
	traces_output=$3
	jq -e 'type == "object" and (keys | sort) == ["resourceMetrics", "resourceSpans"] and (.resourceMetrics | type == "array" and length == 2) and (.resourceSpans | type == "array" and length == 2)' "$input" >/dev/null || return 1
	jq -e '{resourceMetrics}' "$input" > "$metrics_output" || return 1
	jq -e '{resourceSpans}' "$input" > "$traces_output" || return 1
	jq -e 'keys == ["resourceMetrics"] and (.resourceMetrics | length == 2)' "$metrics_output" >/dev/null || return 1
	jq -e 'keys == ["resourceSpans"] and (.resourceSpans | length == 2)' "$traces_output" >/dev/null || return 1
}

start_sink() {
	[ -n "$sink_name" ] && return 0
	sink_name="$runtime_id-sink"
	docker_quiet run --detach --pull=never --platform linux/amd64 --name "$sink_name" --network "$runtime_network" \
		--network-alias task9-sink --user 10001:10001 --read-only --cap-drop=ALL --security-opt no-new-privileges \
		--memory=256m --cpus=0.5 --pids-limit=256 --tmpfs /tmp:rw,noexec,nosuid,nodev,size=32m,uid=10001,gid=10001,mode=0700 \
		--mount type=bind,source="$tmp_dir/sink.yaml",target=/etc/otelcol/config.yaml,readonly \
		--mount type=volume,source="$capture_volume",target=/capture \
		"$OTELCOL_IMAGE" --config=/etc/otelcol/config.yaml || fail 'cannot start disposable pinned Collector sink'
	container_inspect "$sink_name" || fail 'cannot inspect disposable pinned Collector sink'
	jq -e '.[0].State.Running == true' "$tmp_dir/inspect.json" >/dev/null || fail 'disposable pinned Collector sink did not remain running'
}

start_gateway() {
	runtime_config=${1:-"$tmp_dir/otel-gateway-runtime.yaml"}
	gateway_name="$runtime_id-gateway"
	docker_quiet run --detach --pull=never --platform linux/amd64 --name "$gateway_name" --network "$runtime_network" --network-alias task9-gateway \
		--publish 127.0.0.1:14318:4318 --publish 127.0.0.1:14319:4319 --publish 127.0.0.1:14320:4320 \
		--user 10001:10001 --read-only --cap-drop=ALL --security-opt no-new-privileges --memory=512m --cpus=1.0 --pids-limit=512 \
		--env-file "$tmp_dir/collector.env" \
		--tmpfs /var/lib/otelcol:rw,noexec,nosuid,nodev,size=256m,uid=10001,gid=10001,mode=0750 \
		--tmpfs /tmp:rw,noexec,nosuid,nodev,size=32m,uid=10001,gid=10001,mode=0700 \
		--mount type=bind,source="$runtime_config",target=/etc/otelcol/config.yaml,readonly \
		"$OTELCOL_IMAGE" --config=/etc/otelcol/config.yaml --feature-gates=+ottl.set.allowNil || fail 'cannot start disposable pinned gateway'
	container_inspect "$gateway_name" || fail 'cannot inspect disposable gateway container'
	jq -e '.[0] | .State.Running == true and .Config.User == "10001:10001" and .HostConfig.ReadonlyRootfs == true and .HostConfig.Memory == 536870912 and .HostConfig.NanoCpus == 1000000000 and .HostConfig.PidsLimit == 512 and .HostConfig.CapDrop == ["ALL"] and .HostConfig.SecurityOpt == ["no-new-privileges"] and (.HostConfig.Tmpfs["/var/lib/otelcol"] | contains("size=256m")) and (.HostConfig.PortBindings | keys | sort == ["4318/tcp", "4319/tcp", "4320/tcp"]) and .HostConfig.PortBindings["4318/tcp"] == [{"HostIp":"127.0.0.1","HostPort":"14318"}] and .HostConfig.PortBindings["4319/tcp"] == [{"HostIp":"127.0.0.1","HostPort":"14319"}] and .HostConfig.PortBindings["4320/tcp"] == [{"HostIp":"127.0.0.1","HostPort":"14320"}]' "$tmp_dir/inspect.json" >/dev/null || fail 'gateway runtime hardening, loopback-only publishes, or physical 256 MiB temporary filesystem cap is absent'
	wait_for_gateway_ready || fail 'disposable pinned gateway did not expose loopback self-metrics'
}

post_fixture() {
	port=$1
	path=$2
	fixture=$3
	expectation=$4
	payload=$tmp_dir/$fixture.otlp
	make_otlp "$fixture" "$payload" || fail 'cannot convert synthetic fixture to OTLP/JSON'
	post_payload "$port" "$path" "$payload" "$expectation"
}

copy_capture() {
	docker run --rm --pull=never --platform linux/amd64 --network none --user 0 \
		--mount type=volume,source="$capture_volume",target=/capture,readonly \
		--entrypoint /bin/cat "$CADDY_IMAGE" /capture/sink.json > "$tmp_dir/capture.json" 2> "$tmp_dir/capture.stderr"
}

wait_for_capture() {
	attempt=1
	while [ "$attempt" -le 30 ]; do
		if copy_capture && assert_capture_contract "$tmp_dir/capture.json" >/dev/null 2>&1; then
			return 0
		fi
		attempt=$((attempt + 1))
		sleep 1
	done
	return 1
}

wait_for_unsanitized_carrier_capture() {
	attempt=1
	while [ "$attempt" -le 30 ]; do
		if copy_capture && assert_unsanitized_carrier_capture "$tmp_dir/capture.json" >/dev/null 2>&1; then
			return 0
		fi
		attempt=$((attempt + 1))
		sleep 1
	done
	return 1
}

expected_capture_contract() {
	jq -n \
		--slurpfile homelab "$repo_dir/tests/fixtures/observability/homelab-metrics.json" \
		--slurpfile ai_metrics "$repo_dir/tests/fixtures/observability/ai-metrics.json" \
		--slurpfile ai_traces "$repo_dir/tests/fixtures/observability/ai-traces.json" '
		{
			metrics: (
				([
					$homelab[0].expected.records[] |
					{name, resource, attributes, value}
				] + [
					$ai_metrics[0].expected.records[] as $expected |
					$ai_metrics[0].input.metrics[] |
					select(.name == $expected.name) |
					{name, resource: $expected.resource, attributes, value}
				]) | sort_by([.name, (.attributes | tojson), .value])
			),
			traces: ($ai_traces[0].expected.records | sort_by([.name, (.attributes | tojson)]))
		}
	'
}

make_contract_capture() {
	output_path=$1
	expected_capture_contract > "$tmp_dir/expected-capture.json"
	jq -n --slurpfile expected "$tmp_dir/expected-capture.json" --arg now '1770000000000000000' '
		def attrs:
			to_entries | map({key: .key, value: (if (.value | type) == "boolean" then {boolValue: .value} elif (.value | type) == "number" then {doubleValue: .value} else {stringValue: (.value | tostring)} end)});
		[
			($expected[0].metrics[] as $record |
				{resourceMetrics: [{resource: {attributes: ($record.resource | attrs)}, scopeMetrics: [{scope: {}, metrics: [{name: $record.name, gauge: {dataPoints: [{attributes: ($record.attributes | attrs), asDouble: $record.value, timeUnixNano: $now}]}}]}]}]}),
			($expected[0].traces[] as $record |
				{resourceSpans: [{resource: {attributes: ($record.resource | attrs)}, scopeSpans: [{scope: {}, spans: [{traceId: "0123456789abcdef0123456789abcdef", spanId: "0123456789abcdef", parentSpanId: "aaaaaaaaaaaaaaaa", name: $record.name, startTimeUnixNano: $now, endTimeUnixNano: $now, attributes: ($record.attributes | attrs)}]}]}]})
		][]
	' > "$output_path"
}

assert_capture_contract() {
	capture_path=$1
	expected_capture_contract > "$tmp_dir/expected-capture.json"
	jq -s -e --slurpfile expected "$tmp_dir/expected-capture.json" '
		def exact_keys($keys):
			(keys_unsorted | sort) == ($keys | sort);
		def scalar:
			if exact_keys(["stringValue"]) then .stringValue
			elif exact_keys(["boolValue"]) then .boolValue
			elif exact_keys(["intValue"]) then (.intValue | tonumber)
			elif exact_keys(["doubleValue"]) then .doubleValue
			else error("unsupported OTLP scalar") end;
		def attribute:
			type == "object" and exact_keys(["key", "value"]) and
			(.key | type == "string") and (.value | scalar | . != null);
		def attributes:
			type == "array" and all(.[]?; attribute) and
			([.[].key] | unique | length) == length;
		def attr_obj:
			if attributes then reduce .[]? as $attribute ({}; . + {($attribute.key): ($attribute.value | scalar)}) else error("invalid OTLP attribute shape") end;
		def point_value:
			if exact_keys(["attributes", "asDouble", "timeUnixNano"]) then .asDouble
			elif exact_keys(["attributes", "asInt", "timeUnixNano"]) then (.asInt | tonumber)
			else error("missing metric point value") end;
		def valid_metric_document:
			type == "object" and exact_keys(["resourceMetrics"]) and
			(.resourceMetrics | type == "array" and length > 0 and all(.[];
				type == "object" and exact_keys(["resource", "scopeMetrics"]) and
				(.resource | type == "object" and exact_keys(["attributes"]) and (.attributes | attributes)) and
				(.scopeMetrics | type == "array" and length > 0 and all(.[];
					type == "object" and exact_keys(["scope", "metrics"]) and
					(.scope == {}) and
					(.metrics | type == "array" and length > 0 and all(.[];
						type == "object" and exact_keys(["name", "gauge"]) and
						(.name | type == "string") and
						(.gauge | type == "object" and exact_keys(["dataPoints"]) and
							(.dataPoints | type == "array" and length > 0 and all(.[];
								type == "object" and (exact_keys(["attributes", "asDouble", "timeUnixNano"]) or exact_keys(["attributes", "asInt", "timeUnixNano"])) and
								(.attributes | attributes) and
								(.timeUnixNano | type == "string" and test("^[0-9]+$"))
							))
					))
				))
		)));
		def valid_trace_document:
			type == "object" and exact_keys(["resourceSpans"]) and
			(.resourceSpans | type == "array" and length > 0 and all(.[];
				type == "object" and exact_keys(["resource", "scopeSpans"]) and
				(.resource | type == "object" and exact_keys(["attributes"]) and (.attributes | attributes)) and
				(.scopeSpans | type == "array" and length > 0 and all(.[];
					type == "object" and exact_keys(["scope", "spans"]) and
					(.scope == {}) and
					(.spans | type == "array" and length > 0 and all(.[];
						type == "object" and
							(keys_unsorted - ["traceId", "spanId", "parentSpanId", "name", "startTimeUnixNano", "endTimeUnixNano", "attributes", "status", "traceState", "events", "links"] | length == 0) and
							has("traceId") and has("spanId") and has("name") and has("startTimeUnixNano") and has("endTimeUnixNano") and has("attributes") and
							(.traceId | type == "string" and test("^[0-9a-f]{32}$")) and
							(.spanId | type == "string" and test("^[0-9a-f]{16}$")) and
							(if has("parentSpanId") then (.parentSpanId | type == "string" and test("^[0-9a-f]{16}$")) else true end) and
							(.name | type == "string") and
							(.startTimeUnixNano | type == "string" and test("^[0-9]+$")) and
							(.endTimeUnixNano | type == "string" and test("^[0-9]+$")) and
							(.attributes | attributes) and
							((has("status") | not) or .status == {}) and
							((has("traceState") | not) or .traceState == "") and
							((has("events") | not) or .events == []) and
							((has("links") | not) or .links == [])
					))
				))
			));
		def metrics:
			[
				.[] | .resourceMetrics[]? | . as $resource_metrics |
				($resource_metrics.resource.attributes | attr_obj) as $resource |
				$resource_metrics.scopeMetrics[]? |
				.metrics[]? | . as $metric |
				$metric.gauge.dataPoints[]? |
				{name: $metric.name, resource: $resource, attributes: (.attributes | attr_obj), value: point_value}
			] | sort_by([.name, (.attributes | tojson), .value]);
		def traces:
			[
				.[] | .resourceSpans[]? | . as $resource_spans |
				($resource_spans.resource.attributes | attr_obj) as $resource |
				$resource_spans.scopeSpans[]? |
				.spans[]? |
				{name, resource: $resource, attributes: (.attributes | attr_obj), events: (.events // []), links: (.links // []), trace_state: (.traceState // ""), status_message: (.status.message // "")}
			] | sort_by([.name, (.attributes | tojson)]);
		([.[] | if has("resourceMetrics") then valid_metric_document elif has("resourceSpans") then valid_trace_document else false end] | all) and
		({metrics: metrics, traces: traces} == $expected[0])
	' "$capture_path" >/dev/null
}

assert_sanitized_capture() {
	sanitized_carrier_queue_proofs_complete || fail 'sanitized carrier capture bypassed its per-exporter persistent-queue entry or drain proof'
	assert_capture_contract "$tmp_dir/capture.json" || fail 'fixture-specific sanitized OTLP records differ from the exact metadata-only contract'
	for fixture in homelab-metrics homelab-traces ai-metrics ai-traces ai-logs; do
		jq -r '.canaries[]' "$repo_dir/tests/fixtures/observability/$fixture.json" | while IFS= read -r canary; do
			capture_excludes_literal "$tmp_dir/capture.json" "$canary" || exit 1
		done || fail 'forbidden fixture canary reached the disposable sink'
	done
	for canary in runtime-envelope-canary runtime-metric-description-canary runtime-metric-unit-canary runtime-metric-metadata-value-canary runtime-exemplar-canary resource-schema-canary scope-schema-canary entity-schema-canary entity-type-canary entity-id-key-canary entity-description-key-canary entity-id-value-canary entity-description-value-canary entity-empty-schema-canary entity-empty-type-canary entity-empty-id-key-canary entity-empty-description-key-canary entity-empty-id-value-canary entity-empty-description-value-canary; do
		capture_excludes_literal "$tmp_dir/capture.json" "$canary" || fail 'forbidden OTLP envelope canary reached the disposable sink'
	done
	mutate_capture_attribute "$tmp_dir/capture.json" "$tmp_dir/capture-mutated.json" || fail 'forbidden span-attribute mutation could not be generated'
	if assert_capture_contract "$tmp_dir/capture-mutated.json"; then fail 'structural capture contract accepted a forbidden span-attribute mutation'; fi
	mutate_capture_metric_metadata "$tmp_dir/capture.json" "$tmp_dir/capture-metadata-mutated.json" || fail 'forbidden metric metadata mutation could not be generated'
	if assert_capture_contract "$tmp_dir/capture-metadata-mutated.json"; then fail 'structural capture contract accepted forbidden metric metadata'; fi
	mutate_capture_metric_entity_refs "$tmp_dir/capture.json" "$tmp_dir/capture-metric-entity-mutated.json" || fail 'forbidden metric entity-reference mutation could not be generated'
	assert_capture_entity_ref_mutation "$tmp_dir/capture.json" "$tmp_dir/capture-metric-entity-mutated.json" resourceMetrics resourceSpans || fail 'metric-only entity-reference mutation changed an untouched runtime document or was not protocol-valid'
	if assert_capture_contract "$tmp_dir/capture-metric-entity-mutated.json"; then fail 'structural capture contract accepted forbidden metric resource entity references'; fi
	mutate_capture_trace_entity_refs "$tmp_dir/capture.json" "$tmp_dir/capture-trace-entity-mutated.json" || fail 'forbidden trace entity-reference mutation could not be generated'
	assert_capture_entity_ref_mutation "$tmp_dir/capture.json" "$tmp_dir/capture-trace-entity-mutated.json" resourceSpans resourceMetrics || fail 'trace-only entity-reference mutation changed an untouched runtime document or was not protocol-valid'
	if assert_capture_contract "$tmp_dir/capture-trace-entity-mutated.json"; then fail 'structural capture contract accepted forbidden trace resource entity references'; fi
}

sanitized_carrier_queue_proofs_complete() {
	[ "$sanitized_carrier_queues_entered" = true ] && [ "$sanitized_carrier_queues_drained" = true ]
}

unsanitized_carrier_queue_proofs_complete() {
	[ "$unsanitized_carrier_queues_entered" = true ] && [ "$unsanitized_carrier_queues_drained" = true ]
}

unsanitized_carrier_capture_matches() {
	capture_path=$1
	jq -s -e '
		def exact_keys($keys):
			(keys_unsorted | sort) == ($keys | sort);
		def entity_ref($kind):
			type == "object" and
			exact_keys(["descriptionKeys", "idKeys", "schemaUrl", "type"]) and
			.schemaUrl == ("https://runtime.invalid/unsanitized-" + $kind + "-entity-schema") and
			.type == ("runtime.unsanitized." + $kind + ".entity") and
			.idKeys == [("runtime.unsanitized." + $kind + ".id")] and
			.descriptionKeys == [("runtime.unsanitized." + $kind + ".description")];
		def attribute($key; $value):
			type == "object" and exact_keys(["key", "value"]) and
			.key == $key and .value == {stringValue: $value};
		def resource($kind):
			type == "object" and exact_keys(["attributes", "entityRefs"]) and
			(.attributes | type == "array" and length == 2 and
				([.[] | select(attribute("runtime.unsanitized." + $kind + ".id"; "runtime-unsanitized-" + $kind + "-id-value"))] | length) == 1 and
				([.[] | select(attribute("runtime.unsanitized." + $kind + ".description"; "runtime-unsanitized-" + $kind + "-description-value"))] | length) == 1) and
			(.entityRefs | type == "array" and length == 1 and (.[0] | entity_ref($kind)));
		def metadata:
			type == "array" and length == 1 and
			(.[0] | type == "object" and exact_keys(["key", "value"]) and
				.key == "runtime.unsanitized.metadata" and
				.value == {stringValue: "runtime-unsanitized-metadata-value"});
		def metric:
			type == "object" and exact_keys(["gauge", "metadata", "name"]) and
			.name == "runtime.unsanitized.metric" and (.metadata | metadata) and
			(.gauge | type == "object" and exact_keys(["dataPoints"]) and
				(.dataPoints | type == "array" and length == 1 and
					(.[0] | type == "object" and exact_keys(["asDouble", "timeUnixNano"]) and
						.asDouble == 1 and (.timeUnixNano | type == "string" and test("^[0-9]+$")))));
		def metric_scope:
			type == "object" and exact_keys(["metrics", "scope"]) and
			.scope == {name: "runtime-unsanitized-carrier-control"} and
			(.metrics | type == "array" and length == 1 and (.[0] | metric));
		def trace_span:
			type == "object" and
			(exact_keys(["endTimeUnixNano", "name", "spanId", "startTimeUnixNano", "traceId"]) or
				exact_keys(["endTimeUnixNano", "name", "spanId", "startTimeUnixNano", "status", "traceId"])) and
			.traceId == "0123456789abcdef0123456789abcdef" and
			.spanId == "0123456789abcdef" and
			.name == "runtime.unsanitized.trace" and
			(.startTimeUnixNano | type == "string" and test("^[0-9]+$")) and
			(.endTimeUnixNano | type == "string" and test("^[0-9]+$")) and
			((has("status") | not) or .status == {});
		def trace_scope:
			type == "object" and exact_keys(["scope", "spans"]) and
			.scope == {name: "runtime-unsanitized-carrier-control"} and
			(.spans | type == "array" and length == 1 and (.[0] | trace_span));
		def metric_resource($kind):
			type == "object" and
			(if $kind == "normal" then exact_keys(["resource", "scopeMetrics"]) else (exact_keys(["resource"]) or exact_keys(["resource", "scopeMetrics"])) end) and
			(.resource | resource("metrics-" + $kind)) and
			(if $kind == "normal" then (.scopeMetrics | type == "array" and length == 1 and (.[0] | metric_scope)) else ((has("scopeMetrics") | not) or .scopeMetrics == []) end);
		def trace_resource($kind):
			type == "object" and
			(if $kind == "normal" then exact_keys(["resource", "scopeSpans"]) else (exact_keys(["resource"]) or exact_keys(["resource", "scopeSpans"])) end) and
			(.resource | resource("traces-" + $kind)) and
			(if $kind == "normal" then (.scopeSpans | type == "array" and length == 1 and (.[0] | trace_scope)) else ((has("scopeSpans") | not) or .scopeSpans == []) end);
		def metric_document:
			type == "object" and exact_keys(["resourceMetrics"]) and
			(.resourceMetrics | type == "array" and length == 2 and
				([.[] | select(metric_resource("normal"))] | length) == 1 and
				([.[] | select(metric_resource("empty"))] | length) == 1);
		def trace_document:
			type == "object" and exact_keys(["resourceSpans"]) and
			(.resourceSpans | type == "array" and length == 2 and
				([.[] | select(trace_resource("normal"))] | length) == 1 and
				([.[] | select(trace_resource("empty"))] | length) == 1);
		length == 2 and
		([.[] | select(metric_document)] | length) == 1 and
		([.[] | select(trace_document)] | length) == 1
	' "$capture_path" >/dev/null
}

assert_unsanitized_carrier_capture() {
	capture_path=$1
	unsanitized_carrier_queue_proofs_complete || fail 'unsanitized carrier capture bypassed its persistent-queue entry or drain proof'
	unsanitized_carrier_capture_matches "$capture_path" || fail 'pinned unsanitized control did not structurally preserve normal and empty resource entity references plus metric metadata through its persistent queue'
}

capture_excludes_literal() {
	capture_path=$1
	forbidden=$2
	jq -s -e --arg forbidden "$forbidden" '[.[] | .. | strings | select(. == $forbidden)] | length == 0' "$capture_path" >/dev/null
}

mutate_capture_attribute() {
	capture_path=$1
	output_path=$2
	jq -s '
		map(
			if .resourceSpans? then
				(.resourceSpans[0].scopeSpans[0].spans[0].attributes += [{key: "mutation.forbidden", value: {stringValue: "must-not-pass"}}])
			else . end
		)[]
	' "$capture_path" > "$output_path"
}

mutate_capture_metric_metadata() {
	capture_path=$1
	output_path=$2
	jq -s '
		map(
			if .resourceMetrics? then
				(.resourceMetrics[0].scopeMetrics[0].metrics[0].metadata = [{key: "mutation.metadata", value: {stringValue: "must-not-pass"}}])
			else . end
		)[]
	' "$capture_path" > "$output_path"
}

mutate_capture_metric_entity_refs() {
	capture_path=$1
	output_path=$2
	jq -s '
		map(
			if .resourceMetrics? then
				(.resourceMetrics[0].resource.entityRefs = [{schemaUrl: "https://mutation.invalid", type: "mutation.entity", idKeys: ["mutation.id"], descriptionKeys: ["mutation.description"]}])
			else . end
		)[]
	' "$capture_path" > "$output_path"
}

mutate_capture_trace_entity_refs() {
	capture_path=$1
	output_path=$2
	jq -s '
		map(
			if .resourceSpans? then
				(.resourceSpans[0].resource.entityRefs = [{schemaUrl: "https://mutation.invalid", type: "mutation.entity", idKeys: ["mutation.id"], descriptionKeys: ["mutation.description"]}])
			else . end
		)[]
	' "$capture_path" > "$output_path"
}

assert_capture_entity_ref_mutation() {
	capture_path=$1
	mutated_path=$2
	target_signal=$3
	untouched_signal=$4
	jq -n -e --slurpfile original "$capture_path" --slurpfile mutated "$mutated_path" \
		--arg target_signal "$target_signal" --arg untouched_signal "$untouched_signal" '
		def exact_keys($keys):
			(keys_unsorted | sort) == ($keys | sort);
		def valid_entity_ref:
			type == "object" and
			exact_keys(["descriptionKeys", "idKeys", "schemaUrl", "type"]) and
			(.schemaUrl | type == "string") and
			(.type | type == "string") and
			(.idKeys | type == "array" and length > 0 and all(.[]; type == "string")) and
			(.descriptionKeys | type == "array" and length > 0 and all(.[]; type == "string"));
		def without_entity_refs:
			if $target_signal == "resourceMetrics" then del(.resourceMetrics[]?.resource.entityRefs)
			else del(.resourceSpans[]?.resource.entityRefs)
			end;
		def target_documents:
			map(select(has($target_signal)));
		def untouched_documents:
			map(select(has($untouched_signal)));
		def target_resources_have_valid_entity_refs:
			if $target_signal == "resourceMetrics" then
				all(.resourceMetrics[]?.resource;
					has("entityRefs") and (.entityRefs | type == "array" and length == 1 and all(.[]; valid_entity_ref)))
			else
				all(.resourceSpans[]?.resource;
					has("entityRefs") and (.entityRefs | type == "array" and length == 1 and all(.[]; valid_entity_ref)))
			end;
		def untouched_resources_have_no_entity_refs:
			if $untouched_signal == "resourceMetrics" then
				all(.resourceMetrics[]?.resource; has("entityRefs") | not)
			else
				all(.resourceSpans[]?.resource; has("entityRefs") | not)
			end;
		$original as $original_documents |
		$mutated as $mutated_documents |
		($original_documents | target_documents) as $original_targets |
		($mutated_documents | target_documents) as $mutated_targets |
		($original_documents | untouched_documents) as $original_untouched |
		($mutated_documents | untouched_documents) as $mutated_untouched |
		($original_documents | length) == ($mutated_documents | length) and
		($original_targets | length) > 0 and
		($original_targets | length) == ($mutated_targets | length) and
		($original_targets | map(without_entity_refs)) == ($mutated_targets | map(without_entity_refs)) and
		($mutated_targets | all(.[]; target_resources_have_valid_entity_refs)) and
		($mutated_untouched | all(.[]; untouched_resources_have_no_entity_refs)) and
		($original_untouched == $mutated_untouched)
	' \
		>/dev/null
}

post_payload() {
	port=$1
	path=$2
	payload=$3
	expectation=$4
	sender_name=$port-${path##*/}
	set +e
	docker run --rm --pull=never --platform linux/amd64 --network "$runtime_network" --user 20002:20002 \
		--read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m,uid=20002,gid=20002,mode=0700 \
		--mount type=bind,source="$payload",target=/payload,readonly \
		--entrypoint /bin/sh "$CADDY_IMAGE" -c "wget -S -T 15 -O /tmp/response --header='Content-Type: application/json' --post-file=/payload http://task9-gateway:$port$path" > "$tmp_dir/sender-$sender_name.stdout" 2> "$tmp_dir/sender-$sender_name.stderr"
	sender_status=$?
	set -e
	http_status=$(http_status_from_wget "$tmp_dir/sender-$sender_name.stderr")
	case "$expectation:$http_status:$sender_status" in
	accepted:200:0|accepted:202:0) ;;
	rejected:4*:*) ;;
	*) fail "gateway signal acceptance policy differs from the source contract ($expectation:$http_status:$sender_status)" ;;
	esac
}

http_status_from_wget() {
	awk '{ for (field = 1; field <= NF; field++) if ($field ~ /^HTTP\/[0-9.]+$/ && $(field + 1) ~ /^[0-9][0-9][0-9]$/) code = $(field + 1) } END { print code }' "$1"
}

preload_injectable_queues() {
	for target in '4318 /v1/metrics homelab-metrics' '4319 /v1/metrics ai-metrics' '4319 /v1/traces ai-traces' '4320 /v1/metrics docker-metrics'; do
		set -- $target
		make_queue_otlp "$3" "$tmp_dir/queue-$3.otlp" 512
	done
	pids=
	for target in '4318 /v1/metrics homelab-metrics' '4319 /v1/metrics ai-metrics' '4319 /v1/traces ai-traces' '4320 /v1/metrics docker-metrics'; do
		set -- $target
		(post_payload "$1" "$2" "$tmp_dir/queue-$3.otlp" accepted) &
		pids="$pids $!"
	done
	status=0
	for pid in $pids; do wait "$pid" || status=1; done
	[ "$status" -eq 0 ] || fail 'gateway did not accept every injectable allowed queue fixture'
}

post_allowed_payload_repeated() {
	port=$1
	path=$2
	payload=$3
	repeats=$4
	case "$repeats" in
	''|*[!0-9]*) fail 'synthetic queue repeat count must be numeric' ;;
	esac
	docker run --rm --pull=never --platform linux/amd64 --network "$runtime_network" --user 20002:20002 \
		--read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m,uid=20002,gid=20002,mode=0700 \
		--mount type=bind,source="$payload",target=/payload,readonly \
		--entrypoint /bin/sh "$CADDY_IMAGE" -c "i=0; while [ \$i -lt $repeats ]; do wget -q -T 15 -O /tmp/response --header='Content-Type: application/json' --post-file=/payload http://task9-gateway:$port$path || exit 1; i=\$((i + 1)); done" > "$tmp_dir/sender-repeated.stdout" 2> "$tmp_dir/sender-repeated.stderr" || fail 'gateway did not accept repeated allowed synthetic queue traffic'
}

make_queue_otlp() {
	fixture=$1
	output=$2
	points=$3
	now_nanos="$(date +%s)000000000"
	case "$fixture" in
	docker-metrics)
		jq -n --arg now "$now_nanos" --argjson points "$points" '
			{resourceMetrics:[{resource:{attributes:[{key:"container.name",value:{stringValue:"scrypted"}},{key:"telemetry.synthetic",value:{boolValue:true}}]},scopeMetrics:[{scope:{name:"observability-runtime"},metrics:[{name:"container.cpu.utilization",gauge:{dataPoints:[range(0;$points) | {asDouble:0.42,timeUnixNano:$now}]}}]}]}]}
		' > "$output" ;;
	*-metrics)
		jq --arg now "$now_nanos" --argjson points "$points" '
			def attrs: to_entries | map({key:.key,value:(if (.value|type) == "boolean" then {boolValue:.value} elif (.value|type) == "number" then {doubleValue:.value} else {stringValue:(.value|tostring)} end)});
			. as $fixture |
			{resourceMetrics:[{resource:{attributes:($fixture.expected.records[0].resource|attrs)},scopeMetrics:[{scope:{name:"observability-runtime"},metrics:[
				$fixture.expected.records[] as $expected |
				$fixture.input.metrics[] as $input |
				select($input.name == $expected.name) |
				{name:$expected.name,gauge:{dataPoints:[range(0;$points) | {attributes:(($expected.attributes // $input.attributes)|attrs),asDouble:($input.value|tonumber),timeUnixNano:$now}]}}
			]}]}]}
		' "$repo_dir/tests/fixtures/observability/$fixture.json" > "$output" ;;
	ai-traces)
		jq --arg now "$now_nanos" --argjson points "$points" '
			def attrs: to_entries | map({key:.key,value:{stringValue:(.value|tostring)}});
			. as $fixture |
			{resourceSpans:[{resource:{attributes:($fixture.expected.records[0].resource|attrs)},scopeSpans:[{scope:{name:"observability-runtime"},spans:[range(0;$points) | {traceId:"0123456789abcdef0123456789abcdef",spanId:"0123456789abcdef",name:"queued metadata trace",startTimeUnixNano:$now,endTimeUnixNano:$now,attributes:($fixture.expected.records[0].attributes|attrs)}]}]}]}
		' "$repo_dir/tests/fixtures/observability/$fixture.json" > "$output" ;;
	*) fail 'unsupported synthetic queue fixture' ;;
	esac
	jq -e 'type == "object" and (has("resourceMetrics") or has("resourceSpans"))' "$output" >/dev/null || fail 'cannot build synthetic queue payload'
}

read_gateway_self_metrics() {
	docker run --rm --pull=never --platform linux/amd64 --network "container:$gateway_name" \
		--read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m \
		--entrypoint /bin/sh "$CADDY_IMAGE" -c 'wget -q -T 2 -O - http://127.0.0.1:8888/metrics' > "$tmp_dir/gateway-self.prom" 2> "$tmp_dir/gateway-self.stderr"
}

wait_for_gateway_ready() {
	attempt=1
	while [ "$attempt" -le 10 ]; do
		if read_gateway_self_metrics; then return 0; fi
		attempt=$((attempt + 1))
		sleep 1
	done
	return 1
}

gateway_self_metric_total_from_snapshot() {
	metric=$1
	exporter=${2:-}
	awk -v metric="$metric" -v exporter="$exporter" '
		index($1, metric) == 1 &&
		(length($1) == length(metric) || substr($1, length(metric) + 1, 1) == "{") &&
		(exporter == "" || index($1, "exporter=\"" exporter "\"") > 0) {
			sum += $NF
		}
		END { printf "%.0f\n", sum + 0 }
	' "$tmp_dir/gateway-self.prom"
}

gateway_self_metric_series_count_from_snapshot() {
	metric=$1
	exporter=${2:-}
	awk -v metric="$metric" -v exporter="$exporter" '
		index($1, metric) == 1 &&
		(length($1) == length(metric) || substr($1, length(metric) + 1, 1) == "{") &&
		(exporter == "" || index($1, "exporter=\"" exporter "\"") > 0) {
			count += 1
		}
		END { printf "%d\n", count }
	' "$tmp_dir/gateway-self.prom"
}

gateway_self_metric_total() {
	read_gateway_self_metrics || fail 'cannot read Collector loopback self-metrics'
	gateway_self_metric_total_from_snapshot "$1"
}

exporter_queue_size_from_snapshot() {
	exporter=$1
	gateway_self_metric_total_from_snapshot otelcol_exporter_queue_size "$exporter"
}

assert_exporter_queue_state_from_snapshot() {
	exporter=$1
	expected_state=$2
	series_count=$(gateway_self_metric_series_count_from_snapshot otelcol_exporter_queue_size "$exporter")
	case "$series_count" in
	''|*[!0-9]*|0) return 1 ;;
	esac
	queue_size=$(exporter_queue_size_from_snapshot "$exporter")
	case "$queue_size" in
	''|*[!0-9]*) return 2 ;;
	esac
	case "$expected_state" in
	nonzero) [ "$queue_size" -gt 0 ] ;;
	empty) [ "$queue_size" -eq 0 ] ;;
	*) return 2 ;;
	esac
}

wait_for_exporter_queue_state() {
	exporter=$1
	expected_state=$2
	phase=$3
	attempt=1
	while [ "$attempt" -le 30 ]; do
		read_gateway_self_metrics || fail "cannot read Collector loopback self-metrics while proving $phase"
		if assert_exporter_queue_state_from_snapshot "$exporter" "$expected_state"; then
			queue_size=$(exporter_queue_size_from_snapshot "$exporter")
			printf '%s\n' "runtime queue proof: $phase $exporter queue_size=$queue_size"
			return 0
		fi
		attempt=$((attempt + 1))
		sleep 1
	done
	return 1
}

prove_sanitized_carrier_queues_entered() {
	sanitized_carrier_queues_entered=false
	for exporter in otlp_http/homelab_metrics otlp_http/ai_metrics otlp_http/ai_traces; do
		wait_for_exporter_queue_state "$exporter" nonzero 'sanitized carrier entered' || fail "sanitized carrier did not enter the exact $exporter persistent queue before the sink started"
	done
	sanitized_carrier_queues_entered=true
}

prove_sanitized_carrier_queues_drained() {
	sanitized_carrier_queues_drained=false
	for exporter in otlp_http/homelab_metrics otlp_http/ai_metrics otlp_http/ai_traces; do
		wait_for_exporter_queue_state "$exporter" empty 'sanitized carrier drained' || fail "sanitized carrier did not drain the exact $exporter persistent queue after the sink started"
	done
	sanitized_carrier_queues_drained=true
}

prove_unsanitized_carrier_queues_entered() {
	unsanitized_carrier_queues_entered=false
	for exporter in otlp_http/unsanitized_metrics otlp_http/unsanitized_traces; do
		wait_for_exporter_queue_state "$exporter" nonzero 'unsanitized carrier entered' || fail "unsanitized carrier did not enter the exact $exporter persistent queue before the sink started"
	done
	unsanitized_carrier_queues_entered=true
}

prove_unsanitized_carrier_queues_drained() {
	unsanitized_carrier_queues_drained=false
	for exporter in otlp_http/unsanitized_metrics otlp_http/unsanitized_traces; do
		wait_for_exporter_queue_state "$exporter" empty 'unsanitized carrier drained' || fail "unsanitized carrier did not drain the exact $exporter persistent queue after the sink started"
	done
	unsanitized_carrier_queues_drained=true
}

probe_tmpfs_archive_observability() {
	tmpfs_probe_name="$runtime_id-tmpfs-probe"
	docker_quiet run --detach --pull=never --platform linux/amd64 --name "$tmpfs_probe_name" --network none \
		--read-only --tmpfs /probe:rw,noexec,nosuid,nodev,size=8m \
		--entrypoint /bin/sh "$CADDY_IMAGE" -c 'printf marker > /probe/marker; sleep 30' || fail 'cannot start disposable tmpfs archive probe'
	if docker run --rm --pull=never --platform linux/amd64 --network none --read-only --volumes-from "$tmpfs_probe_name:ro" \
		--entrypoint /bin/sh "$CADDY_IMAGE" -c 'test -f /probe/marker' > "$tmp_dir/tmpfs-sidecar.stdout" 2> "$tmp_dir/tmpfs-sidecar.stderr"; then
		queue_usage_method=sidecar
	else
		probe_copy=$tmp_dir/tmpfs-archive-probe
		docker cp "$tmpfs_probe_name:/probe" "$probe_copy" > "$tmp_dir/tmpfs-archive.stdout" 2> "$tmp_dir/tmpfs-archive.stderr" || :
		if [ -f "$probe_copy/marker" ]; then queue_usage_method=archive; fi
	fi
	docker_quiet rm --force "$tmpfs_probe_name" || fail 'cannot remove disposable tmpfs archive probe'
	tmpfs_probe_name=
}

gateway_queue_kib() {
	case "$queue_usage_method" in
	sidecar)
		docker run --rm --pull=never --platform linux/amd64 --network none --read-only --volumes-from "$gateway_name:ro" \
			--entrypoint /bin/sh "$CADDY_IMAGE" -c 'du -sk /var/lib/otelcol' > "$tmp_dir/gateway-queue-usage" 2> "$tmp_dir/gateway-queue-usage.stderr" || fail 'cannot read the active Collector queue filesystem through a verified read-only sidecar'
		queue_kib=$(awk 'NR == 1 { print $1; exit }' "$tmp_dir/gateway-queue-usage") ;;
	archive)
		queue_copy=$tmp_dir/gateway-queue-copy
		[ ! -e "$queue_copy" ] || rm -rf "$queue_copy"
		docker cp "$gateway_name:/var/lib/otelcol" "$queue_copy" > "$tmp_dir/gateway-queue-copy.stdout" 2> "$tmp_dir/gateway-queue-copy.stderr" || fail 'cannot archive the active Collector queue filesystem read-only'
		queue_kib=$(du -sk "$queue_copy" | awk 'NR == 1 { print $1; exit }') ;;
	*) return 2 ;;
	esac
	case "$queue_kib" in
	''|*[!0-9]*) fail 'active Collector queue usage is not numeric' ;;
	esac
	printf '%s\n' "$queue_kib"
}

assert_gateway_memory_usage() {
	docker stats --no-stream --format '{{.MemUsage}}|{{.MemPerc}}' "$gateway_name" > "$tmp_dir/gateway-memory" 2> "$tmp_dir/gateway-memory.stderr" || fail 'cannot read gateway memory usage'
	memory_usage=$(tr -d '\n' < "$tmp_dir/gateway-memory")
	case "$memory_usage" in
*' / 512MiB|'*) ;;
*) fail "gateway memory hard-cap report is invalid ($memory_usage)" ;;
	esac
	memory_percent=${memory_usage##*|}
	case "$memory_percent" in
	*[!0-9.%]*|*.*.*|.|''|*%%*) fail "gateway memory percentage report is invalid ($memory_usage)" ;;
	[0-9]*%) ;;
	*) fail "gateway memory percentage report is invalid ($memory_usage)" ;;
	esac
	memory_percent=${memory_percent%%%}
	awk -v percent="$memory_percent" 'BEGIN { exit !(percent < 100) }' || fail "gateway memory usage reached or exceeded its 512 MiB hard cap ($memory_usage)"
}

assert_source_queue_backing_image() {
	rg -F -- 'ExecStart=/usr/bin/truncate --size=268435456 /var/lib/otelcol-queue.img' "$repo_dir/config/observability/systemd/otelcol-queue-prepare.service" >/dev/null || fail 'source queue backing image is not exactly 268435456 bytes'
}

exercise_injectable_queues() {
	preload_injectable_queues
	sleep 1
	read_gateway_self_metrics || fail 'cannot read Collector loopback self-metrics during backend outage'
	queue_capacity=$(gateway_self_metric_total_from_snapshot otelcol_exporter_queue_capacity)
	queue_size=$(gateway_self_metric_total_from_snapshot otelcol_exporter_queue_size)
	[ "$queue_capacity" -gt 0 ] || fail 'Collector did not report durable queue capacity during backend outage'
	[ "$queue_size" -gt 0 ] || fail 'Collector did not report queued telemetry during backend outage'
	enqueue_before=$(gateway_self_metric_total_from_snapshot otelcol_exporter_enqueue_failed_metric_points)
	make_queue_otlp ai-metrics "$tmp_dir/queue-pressure.otlp" 1024
	post_allowed_payload_repeated 4319 /v1/metrics "$tmp_dir/queue-pressure.otlp" 12
	read_gateway_self_metrics || fail 'cannot read Collector loopback self-metrics after overflow pressure'
	enqueue_after=$(gateway_self_metric_total_from_snapshot otelcol_exporter_enqueue_failed_metric_points)
	[ "$enqueue_after" -gt "$enqueue_before" ] || fail 'real AI-metrics durable queue did not report enqueue/drop overflow under bounded outage pressure'
	if [ "$queue_usage_method" != unavailable ]; then
		sleep 5
		queue_peak_kib=$(gateway_queue_kib)
		[ "$queue_peak_kib" -gt 16384 ] || fail "active Collector queue only stored $queue_peak_kib KiB before overflow"
		[ "$queue_peak_kib" -le 262144 ] || fail 'active Collector queue exceeded its 256 MiB temporary filesystem cap'
	else
		queue_peak_kib=
	fi
	assert_gateway_memory_usage
}

wait_for_queue_recovery() {
	attempt=1
	while [ "$attempt" -le 60 ]; do
		read_gateway_self_metrics || fail 'cannot read Collector loopback self-metrics during recovery'
		queue_size=$(gateway_self_metric_total_from_snapshot otelcol_exporter_queue_size)
		if [ -n "$queue_peak_kib" ]; then
			queue_now_kib=$(gateway_queue_kib)
			if [ "$queue_size" -eq 0 ] && [ "$queue_now_kib" -lt "$queue_peak_kib" ]; then return 0; fi
		elif [ "$queue_size" -eq 0 ]; then
			return 0
		fi
		attempt=$((attempt + 1))
		sleep 1
	done
	return 1
}

stop_gateway_sink_and_capture() {
	[ -z "$gateway_name" ] || docker_quiet rm --force "$gateway_name" || fail 'cannot stop disposable gateway'
	[ -z "$sink_name" ] || docker_quiet rm --force "$sink_name" || fail 'cannot stop disposable sink'
	[ -z "$capture_volume" ] || docker_quiet volume rm "$capture_volume" || fail 'cannot remove disposable capture volume'
	gateway_name=
	sink_name=
	capture_volume=
}

validate_unsanitized_carrier_runtime() {
	printf '%s\n' 'runtime phase: unsanitized pinned receiver, batch, persistent-queue carrier control'
	write_unsanitized_carrier_control_config
	make_unsanitized_carrier_control_otlp "$tmp_dir/unsanitized-carrier.otlp"
	split_unsanitized_carrier_control_otlp "$tmp_dir/unsanitized-carrier.otlp" "$tmp_dir/unsanitized-carrier-metrics.otlp" "$tmp_dir/unsanitized-carrier-traces.otlp" || fail 'cannot split unsanitized carrier control into protocol-valid metrics and traces payloads'
	unsanitized_carrier_queues_entered=false
	unsanitized_carrier_queues_drained=false
	capture_volume="$runtime_id-unsanitized-carrier-capture"
	create_volume_for_uid "$capture_volume" 10001
	start_gateway "$tmp_dir/otel-unsanitized-carrier-control.yaml"
	post_payload 4318 /v1/metrics "$tmp_dir/unsanitized-carrier-metrics.otlp" accepted
	post_payload 4318 /v1/traces "$tmp_dir/unsanitized-carrier-traces.otlp" accepted
	prove_unsanitized_carrier_queues_entered
	start_sink
	prove_unsanitized_carrier_queues_drained
	wait_for_unsanitized_carrier_capture || fail 'pinned unsanitized carrier control did not reach the sink after its exact exporter queues drained'
	printf '%s\n' 'runtime phase: unsanitized carrier control passed'
	stop_gateway_sink_and_capture
}

validate_gateway_runtime() {
	assert_source_queue_backing_image
	write_sink_config
	write_gateway_runtime_config
	capture_volume="$runtime_id-queue-capture"
	create_volume_for_uid "$capture_volume" 10001
	start_gateway
	printf '%s\n' 'runtime phase: queue outage receives all injectable paths'
	exercise_injectable_queues
	start_sink
	wait_for_queue_recovery || fail 'Collector queue did not drain after the disposable sink returned'
	assert_gateway_memory_usage
	stop_gateway_sink_and_capture
	validate_unsanitized_carrier_runtime
	printf '%s\n' 'runtime phase: fixture sanitizer capture and structural contract'
	write_gateway_fixture_runtime_config
	sanitized_carrier_queues_entered=false
	sanitized_carrier_queues_drained=false
	capture_volume="$runtime_id-fixture-capture"
	create_volume_for_uid "$capture_volume" 10001
	start_gateway
	post_fixture 4318 /v1/metrics homelab-metrics accepted
	post_fixture 4319 /v1/metrics ai-metrics accepted
	post_fixture 4319 /v1/traces ai-traces accepted
	post_fixture 4318 /v1/traces homelab-traces rejected
	post_fixture 4319 /v1/logs ai-logs rejected
	prove_sanitized_carrier_queues_entered
	start_sink
	prove_sanitized_carrier_queues_drained
	wait_for_capture || fail 'gateway did not drain queued sanitized telemetry after the disposable sink returned'
	assert_sanitized_capture
	printf '%s\n' 'runtime phase: sanitized fixture capture passed'
}

full_run() {
	make_private_tmp
	runtime_started=true
	runtime_id=task9-$$
	runtime_network=$runtime_id-network
	load_images
	require_docker
	require_image "$OPENOBSERVE_IMAGE"
	require_image "$OTELCOL_IMAGE"
	require_image "$CADDY_IMAGE"
	write_test_environment
	printf '%s\n' 'runtime phase: pinned config and internal-network checks'
	docker_quiet network create --internal "$runtime_network" || fail 'cannot create isolated disposable Docker network'
	docker inspect "$runtime_network" > "$tmp_dir/network-inspect.json" 2> "$tmp_dir/network-inspect.stderr" || fail 'cannot inspect isolated disposable Docker network'
	jq -e '.[0].Internal == true' "$tmp_dir/network-inspect.json" >/dev/null || fail 'disposable Docker network is not internal'
	probe_tmpfs_archive_observability
	validate_collectors
	validate_caddy
	printf '%s\n' 'runtime phase: disposable OpenObserve isolation and durable UID 20001 volume'
	validate_openobserve_runtime
	printf '%s\n' 'runtime phase: gateway sanitized egress and bounded-queue outage/recovery'
	validate_gateway_runtime
	printf '%s\n' 'runtime validation: exact pinned linux/amd64 images, Collector variants, Caddy topology, OpenObserve durable isolation, structural sanitized egress, real injectable-queue pressure/drop metrics, and recovery passed'
	if [ "$queue_usage_method" = unavailable ]; then
		printf '%s\n' 'Gate C pending: Docker Desktop exposes neither tmpfs sidecars nor archive contents, so this host proves active queue capacity/size/overflow and recovery but not physical tmpfs usage; Flatcar must prove the 256 MiB filesystem usage.'
	fi
	printf '%s\n' 'Gate C pending: Flatcar systemd/storage-probe sandbox, real loop-image mount and all-five-queue saturation (the host queue is not safely injectable here), host loopback delivery into an internal Docker network, plus Docker-agent metrics against a dedicated disposable Docker API socket; macOS validation never reads the host Docker socket'
}

mode=$(parse_args "$@") || usage
case "$mode" in
self-test) self_test ;;
runtime) full_run ;;
*) usage ;;
esac
