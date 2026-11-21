#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
config_dir="$repo_dir/config/observability"
images_file="$config_dir/images.env"
openobserve_file="$config_dir/openobserve.env"

fail() {
	echo "observability image lock contract: $1" >&2
	exit 1
}

require_file() {
	[ -f "$1" ] || fail "missing $1"
}

assert_no_duplicate_keys() {
	awk -F= '
    /^[[:space:]]*(#|$)/ { next }
    {
      if ($1 !~ /^[A-Z][A-Z0-9_]*$/ || seen[$1]++) {
        exit 1
      }
    }
  ' "$1" || fail "invalid or duplicate key in $1"
}

value_for() {
	awk -F= -v wanted="$2" '
    $1 == wanted {
      count++
      value = substr($0, index($0, "=") + 1)
    }
    END {
      if (count != 1) {
        exit 1
      }
      print value
    }
  ' "$1"
}

assert_value() {
	actual=$(value_for "$1" "$2") || fail "missing or duplicate $2 in $1"
	[ "$actual" = "$3" ] || fail "unexpected value for $2 in $1"
}

assert_key_count() {
	actual=$(awk -F= '/^[A-Z][A-Z0-9_]*=/{count++} END{print count + 0}' "$1")
	[ "$actual" -eq "$2" ] || fail "unexpected key count in $1"
}

require_file "$images_file"
require_file "$openobserve_file"
assert_no_duplicate_keys "$images_file"
assert_no_duplicate_keys "$openobserve_file"

assert_key_count "$images_file" 7
assert_value "$images_file" OPENOBSERVE_IMAGE 'docker.io/openobserve/openobserve:v0.92.2@sha256:e48df7b318a94541c81f8d2f27860f25a041432c3636b687eaac790b4e76dad6'
assert_value "$images_file" OTELCOL_IMAGE 'docker.io/otel/opentelemetry-collector-contrib:0.159.0@sha256:4f4276c07cee9055f2ab630a86330243f85e208c388ee697bea2a44dab896c3f'
assert_value "$images_file" CADDY_IMAGE 'ghcr.io/caddy-dns/cloudflare:v0.2.4@sha256:f46799052f9dfcf7e634326d279d47a58c1ea598f8330c0b77921971f14aeaf0'
assert_value "$images_file" OPENOBSERVE_VERSION 'v0.92.2'
assert_value "$images_file" OTELCOL_VERSION '0.159.0'
assert_value "$images_file" CADDY_VERSION 'v2.11.2'
assert_value "$images_file" CADDY_CLOUDFLARE_VERSION 'v0.2.4'

assert_key_count "$openobserve_file" 24
assert_value "$openobserve_file" ZO_DATA_DIR '/data'
assert_value "$openobserve_file" ZO_LOCAL_MODE 'true'
assert_value "$openobserve_file" ZO_LOCAL_MODE_STORAGE 'disk'
assert_value "$openobserve_file" ZO_HTTP_ADDR '127.0.0.1'
assert_value "$openobserve_file" ZO_HTTP_PORT '5080'
assert_value "$openobserve_file" ZO_GRPC_ADDR '127.0.0.1'
assert_value "$openobserve_file" ZO_GRPC_PORT '5081'
assert_value "$openobserve_file" ZO_WEB_URL 'https://observe.example.com'
assert_value "$openobserve_file" ZO_CORS_ALLOWED_ORIGINS 'https://observe.example.com'
assert_value "$openobserve_file" ZO_SWAGGER_ENABLED 'false'
assert_value "$openobserve_file" ZO_COOKIE_SECURE_ONLY 'true'
assert_value "$openobserve_file" ZO_COOKIE_SAME_SITE_LAX 'true'
assert_value "$openobserve_file" ZO_TELEMETRY 'false'
assert_value "$openobserve_file" O2_AI_ENABLED 'false'
assert_value "$openobserve_file" ZO_COMPACT_DATA_RETENTION_DAYS '30'
assert_value "$openobserve_file" ZO_IGNORE_FILE_RETENTION_BY_STREAM 'true'
assert_value "$openobserve_file" ZO_COMPACT_FAST_MODE 'false'
assert_value "$openobserve_file" ZO_MEM_TABLE_MAX_SIZE '256'
assert_value "$openobserve_file" ZO_MAX_FILE_SIZE_IN_MEMORY '64'
assert_value "$openobserve_file" ZO_MAX_FILE_SIZE_ON_DISK '32'
assert_value "$openobserve_file" ZO_HTTP_WORKER_NUM '2'
assert_value "$openobserve_file" ZO_JSON_LIMIT '4194304'
assert_value "$openobserve_file" ZO_PAYLOAD_LIMIT '4194304'
assert_value "$openobserve_file" ZO_METRICS_CACHE_ENABLED 'false'

if grep -R -q -E '^(ZO_ROOT_USER_EMAIL|ZO_ROOT_USER_PASSWORD|CLOUDFLARE_API_TOKEN|HOMELAB_OTLP_TOKEN|AI_OTLP_TOKEN|OPENOBSERVE_INGEST_AUTH_HEADER)=' "$config_dir"; then
	fail 'tracked observability config contains a runtime secret assignment'
fi

if grep -R -q -F 'com.centurylinklabs.watchtower.scope=scrypted' "$config_dir"; then
	fail 'observability config joins the Scrypted Watchtower scope'
fi

if grep -R -q -E '(^|[/:])latest(@|$|[[:space:]])' "$config_dir"; then
	fail 'observability config contains a latest image reference'
fi

echo 'observability image lock contract: PASS'
