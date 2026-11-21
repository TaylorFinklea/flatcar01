#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
config_dir="$repo_dir/config/observability"
caddyfile="$config_dir/Caddyfile"
unit_file="$config_dir/systemd/observe-proxy.service"

fail() {
	echo "observability proxy contract: $1" >&2
	exit 1
}

require_file() {
	[ -f "$1" ] || fail "missing $1"
}

require_file "$caddyfile"
require_file "$unit_file"

assert_block_line() {
	awk -v start="$1" -v expected="$2" '
    function clean(value) {
      sub(/[[:space:]]*#.*/, "", value)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    {
      line = clean($0)
      if (!inside && line == start) {
        starts++
        inside = 1
        depth = 1
        next
      }
      if (inside) {
        if (line == expected) {
          found = 1
        }
        opens = gsub(/\{/, "", line)
        closes = gsub(/\}/, "", line)
        depth += opens - closes
        if (depth <= 0) {
          inside = 0
        }
      }
    }
    END {
      exit !(starts == 1 && found)
    }
  ' "$caddyfile" || fail "missing scoped Caddy line: $2 in $1"
}

assert_site_surface() {
	awk '
    function clean(value) {
      sub(/[[:space:]]*#.*/, "", value)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    {
      line = clean($0)
      if (depth == 0 && line != "{" && line ~ /\{$/) {
        sites++
        if (line != "observe.example.com:443 {") {
          bad = 1
        }
      }
      opens = gsub(/\{/, "", line)
      closes = gsub(/\}/, "", line)
      depth += opens - closes
    }
    END {
      exit !(sites == 1 && !bad)
    }
  ' "$caddyfile" || fail 'Caddyfile must contain only the exact HTTPS site address'
}

assert_global_server_contract() {
	awk '
    function clean(value) {
      sub(/[[:space:]]*#.*/, "", value)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    {
      line = clean($0)
      if (depth == 0 && line == "{") {
        global_blocks++
      }
      if (line ~ /^servers([[:space:]]|$)/ && line ~ /\{$/) {
        servers++
        if (line != "servers 10.10.10.50:443 {" || depth != 1) {
          bad = 1
        }
      }
      if (line ~ /^protocols([[:space:]]|$)/) {
        protocols++
        if (line != "protocols h1 h2" || depth != 2) {
          bad = 1
        }
      }
      opens = gsub(/\{/, "", line)
      closes = gsub(/\}/, "", line)
      depth += opens - closes
    }
    END {
      exit !(global_blocks == 1 && servers == 1 && protocols == 1 && !bad)
    }
  ' "$caddyfile" || fail 'Caddyfile must have only one explicit h1/h2 server policy'
}

assert_no_import() {
	awk '
    function clean(value) {
      sub(/[[:space:]]*#.*/, "", value)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    {
      line = clean($0)
      if (line ~ /^import([[:space:]]|$)/) {
        exit 1
      }
    }
  ' "$caddyfile" || fail 'Caddyfile must not import external policy'
}

assert_site_surface
assert_global_server_contract
assert_no_import
assert_block_line '{' 'admin off'
assert_block_line '{' 'auto_https disable_redirects'
assert_block_line '{' 'servers 10.10.10.50:443 {'
assert_block_line 'servers 10.10.10.50:443 {' 'protocols h1 h2'
assert_block_line 'observe.example.com:443 {' 'bind 10.10.10.50'
assert_block_line 'observe.example.com:443 {' 'tls {'
assert_block_line 'tls {' 'dns cloudflare {env.CLOUDFLARE_API_TOKEN}'
assert_block_line 'tls {' 'resolvers 1.1.1.1'
assert_block_line 'observe.example.com:443 {' 'request_body {'
assert_block_line 'request_body {' 'max_size 4MiB'

assert_block_line '@homelab {' 'path /otlp/homelab/*'
assert_block_line '@homelab {' 'header Authorization "Bearer {env.HOMELAB_OTLP_TOKEN}"'
assert_block_line '@ai {' 'path /otlp/ai/*'
assert_block_line '@ai {' 'header Authorization "Bearer {env.AI_OTLP_TOKEN}"'
assert_block_line 'handle @homelab {' 'uri strip_prefix /otlp/homelab'
assert_block_line 'handle @homelab {' 'reverse_proxy 127.0.0.1:4318 {'
assert_block_line 'reverse_proxy 127.0.0.1:4318 {' 'header_up -Authorization'
assert_block_line 'handle @ai {' 'uri strip_prefix /otlp/ai'
assert_block_line 'handle @ai {' 'reverse_proxy 127.0.0.1:4319 {'
assert_block_line 'reverse_proxy 127.0.0.1:4319 {' 'header_up -Authorization'
assert_block_line 'handle @homelab_path {' 'respond "Unauthorized" 401'
assert_block_line 'handle @ai_path {' 'respond "Unauthorized" 401'
assert_block_line 'handle @otlp_path {' 'respond "Not Found" 404'
assert_block_line 'handle {' 'reverse_proxy 127.0.0.1:5080'

homelab_auth_line=$(grep -n -m1 '^[[:space:]]*handle @homelab {' "$caddyfile" | cut -d: -f1)
homelab_denial_line=$(grep -n -m1 '^[[:space:]]*handle @homelab_path {' "$caddyfile" | cut -d: -f1)
ai_auth_line=$(grep -n -m1 '^[[:space:]]*handle @ai {' "$caddyfile" | cut -d: -f1)
ai_denial_line=$(grep -n -m1 '^[[:space:]]*handle @ai_path {' "$caddyfile" | cut -d: -f1)
[ "$homelab_auth_line" -lt "$homelab_denial_line" ] || fail 'homelab auth handler must precede path-only denial'
[ "$ai_auth_line" -lt "$ai_denial_line" ] || fail 'AI auth handler must precede path-only denial'

if grep -Fq -- 'header -Authorization' "$caddyfile"; then
	fail 'response-header deletion cannot replace request-header deletion'
fi

if grep -Eq 'Bearer[[:space:]]+(test|secret|token|change|example)|CLOUDFLARE_API_TOKEN[=:][^ {]+' "$caddyfile"; then
	fail 'Caddyfile contains a secret literal'
fi

normalized_unit=$(awk '
  {
    if (continuing) {
      sub(/^[[:space:]]*/, "")
      logical = logical $0
    } else {
      logical = $0
    }

    if (logical ~ /\\$/) {
      sub(/\\$/, " ", logical)
      continuing = 1
      next
    }

    print logical
    logical = ""
    continuing = 0
  }
  END {
    if (continuing) {
      exit 1
    }
  }
' "$unit_file") || fail 'invalid line continuation'

assert_line() {
	printf '%s\n' "$normalized_unit" | grep -Fqx -- "$1" || fail "missing directive: $1"
}

assert_exec_arg() {
	case " $exec_start " in
	*" $1 "*) ;;
	*) fail "ExecStart is missing: $1" ;;
	esac
}

assert_line 'ConditionPathExists=/etc/observability/images.env'
assert_line 'ConditionPathExists=/etc/observability/Caddyfile'
assert_line 'ConditionPathExists=/etc/observability/secrets/observe-proxy.env'
assert_line 'EnvironmentFile=/etc/observability/images.env'
assert_line 'Restart=on-failure'
assert_line 'ExecStartPre=/usr/bin/install -d -m 0750 -o 0 -g 0 /var/lib/observability/caddy'
assert_line 'ExecStartPre=/usr/bin/install -d -m 0750 -o 20002 -g 20002 /var/lib/observability/caddy/data'
assert_line 'ExecStartPre=/usr/bin/install -d -m 0750 -o 20002 -g 20002 /var/lib/observability/caddy/config'
assert_line 'ExecStartPre=/bin/sh -ec '\''test "$(/usr/bin/stat -c "%%u:%%g:%%a" /var/lib/observability/caddy)" = "0:0:750"'\'''
assert_line 'ExecStartPre=/bin/sh -ec '\''test "$(/usr/bin/stat -c "%%u:%%g:%%a" /var/lib/observability/caddy/data)" = "20002:20002:750"'\'''
assert_line 'ExecStartPre=/bin/sh -ec '\''test "$(/usr/bin/stat -c "%%u:%%g:%%a" /var/lib/observability/caddy/config)" = "20002:20002:750"'\'''
assert_line 'ExecStartPre=/bin/sh -ec '\''test "$(/usr/bin/stat -c "%%u:%%g:%%a" /etc/observability/secrets/observe-proxy.env)" = "0:0:600"'\'''

exec_start_count=$(printf '%s\n' "$normalized_unit" | awk '/^ExecStart=/{count++} END{print count + 0}')
[ "$exec_start_count" -eq 1 ] || fail 'expected exactly one ExecStart directive'
exec_start=$(printf '%s\n' "$normalized_unit" | awk '/^ExecStart=/{sub(/^ExecStart=/, ""); print}')

assert_exec_arg '/usr/bin/docker run'
assert_exec_arg '--name observe-proxy'
assert_exec_arg '--pull=never'
assert_exec_arg '--network host'
assert_exec_arg '--user 20002:20002'
assert_exec_arg '--read-only'
assert_exec_arg '--cap-drop=ALL'
assert_exec_arg '--cap-add=NET_BIND_SERVICE'
assert_exec_arg '--security-opt no-new-privileges'
assert_exec_arg '--memory=256m'
assert_exec_arg '--cpus=0.5'
assert_exec_arg '--env-file /etc/observability/secrets/observe-proxy.env'
assert_exec_arg '--mount type=bind,source=/var/lib/observability/caddy/data,target=/data'
assert_exec_arg '--mount type=bind,source=/var/lib/observability/caddy/config,target=/config'
assert_exec_arg '--mount type=bind,source=/etc/observability/Caddyfile,target=/etc/caddy/Caddyfile,readonly'
assert_exec_arg '--tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m,uid=20002,gid=20002,mode=0700'

case "$exec_start" in
*' ${CADDY_IMAGE}') ;;
*) fail 'ExecStart must end with ${CADDY_IMAGE}' ;;
esac

mount_count=$(printf '%s\n' "$exec_start" | awk '{count = gsub(/--mount[[:space:]]+/, "&"); print count}')
[ "$mount_count" -eq 3 ] || fail 'proxy must have exactly three bind mounts'

cap_add_count=$(printf '%s\n' "$exec_start" | awk '{count = gsub(/--cap-add=/, "&"); print count}')
[ "$cap_add_count" -eq 1 ] || fail 'proxy must add only NET_BIND_SERVICE'

if printf '%s\n' "$normalized_unit" | grep -Eq 'docker[[:space:]]+pull|--publish(=|[[:space:]])|--publish-all([[:space:]]|$)|(^|[[:space:]])-p([^[:space:]]|[[:space:]])|(^|[[:space:]])-P([[:space:]]|$)|docker\.sock|watchtower|Watchtower'; then
	fail 'unit contains a forbidden pull, port publication, socket mount, or management label'
fi

if printf '%s\n' "$normalized_unit" | grep -Eq '(^|[[:space:]])(CLOUDFLARE_API_TOKEN|HOMELAB_OTLP_TOKEN|AI_OTLP_TOKEN)='; then
	fail 'unit contains a secret literal assignment'
fi

case "$normalized_unit" in
*'/var/lib/scrypted'* | *'scrypted.service'* | *'scrypted-watchtower.service'* | *'scrypted-recovery.timer'* | *'var-lib-scrypted-nvr'* | *'NVR'* | *'Scrypted'*)
	fail 'unit references Scrypted or NVR'
	;;
esac

case "$normalized_unit" in
*'docker.io/'* | *'ghcr.io/'* | *'caddy-dns/cloudflare:'*) fail 'unit must use the pinned image variable, not a literal image' ;;
esac

printf '%s\n' "$normalized_unit" | awk '
  /docker[[:space:]]+rm[[:space:]]/ && !/^ExecStartPre=/ { exit 1 }
' || fail 'old-container removal is only allowed in ExecStartPre'

echo 'observability proxy contract: PASS'
