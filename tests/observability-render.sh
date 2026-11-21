#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/observability-render-test.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

public_key_file="$tmp_dir/id_ed25519.pub"
rendered_ignition="$tmp_dir/scrypted-nvr.ign"
baseline_template="$tmp_dir/baseline-template.json"
printf '%s\n' 'ssh-ed25519 TEST-ONLY-KEY observability-render-test' > "$public_key_file"

baseline_fixture="$repo_dir/tests/fixtures/observability-render-baseline.json"
jq -e . "$baseline_fixture" >/dev/null
baseline_template="$baseline_fixture"
if [ "${1:-}" = --atomic-test ]; then
	atomic_root="$tmp_dir/atomic-repo"
	mkdir -p "$atomic_root/config" "$atomic_root/scripts" "$tmp_dir/atomic-output"
	cp "$repo_dir/config/scrypted-nvr.ign.template.json" "$atomic_root/config/scrypted-nvr.ign.template.json"
	cp -R "$repo_dir/config/observability" "$atomic_root/config/observability"
	cp "$repo_dir/scripts/render-ignition" "$atomic_root/scripts/render-ignition"
	rm "$atomic_root/config/observability/images.env"
	atomic_key="$tmp_dir/atomic-key.pub"
	atomic_output="$tmp_dir/atomic-output/output.ign"
	printf '%s\n' 'SENTINEL-OUTPUT-MUST-SURVIVE' > "$atomic_output"
	printf '%s\n' 'ssh-ed25519 TEST-ONLY-KEY observability-render-atomic-test' > "$atomic_key"
	if "$atomic_root/scripts/render-ignition" "$atomic_key" "$atomic_output" >/dev/null 2>&1; then
		echo 'renderer unexpectedly succeeded with a missing rawfile input' >&2
		exit 1
	fi
	printf '%s\n' 'SENTINEL-OUTPUT-MUST-SURVIVE' > "$tmp_dir/atomic-expected"
	cmp -s "$tmp_dir/atomic-expected" "$atomic_output" || {
		echo 'renderer failure replaced the existing output' >&2
		exit 1
	}
	if find "$tmp_dir/atomic-output" -maxdepth 1 -name '.*.tmp.*' -print -quit | grep -q .; then
		echo 'renderer failure left a temporary output file' >&2
		exit 1
	fi
	echo 'atomic renderer failure contract: PASS'
	exit 0
fi
if [ "${1:-}" = --self-test ]; then
	"$repo_dir/scripts/render-ignition" "$public_key_file" "$rendered_ignition"
	mutations='duplicate-approved-directory
extra-directory
extra-file
extra-unit
altered-baseline-object
extra-observability-file'
	while IFS= read -r mutation; do
		case "$mutation" in
			duplicate-approved-directory)
				jq '.storage.directories += [{"path": "/etc/observability", "mode": 493}]' "$rendered_ignition" > "$tmp_dir/$mutation.ign"
				;;
			extra-directory)
				jq '.storage.directories += [{"path": "/var/lib/unexpected", "mode": 488}]' "$rendered_ignition" > "$tmp_dir/$mutation.ign"
				;;
			extra-file)
				jq '.storage.files += [{"overwrite": true, "path": "/etc/unexpected", "contents": {"compression": "", "source": "data:,unexpected"}, "mode": 420}]' "$rendered_ignition" > "$tmp_dir/$mutation.ign"
				;;
			extra-unit)
				jq '.systemd.units += [{"contents": "", "name": "unexpected.service"}]' "$rendered_ignition" > "$tmp_dir/$mutation.ign"
				;;
			altered-baseline-object)
				jq '(.storage.directories[] | select(.path == "/etc/scrypted").mode) = 0' "$rendered_ignition" > "$tmp_dir/$mutation.ign"
				;;
			extra-observability-file)
				jq '.storage.files += [{"overwrite": true, "path": "/etc/observability/unexpected", "contents": {"compression": "", "source": "data:,unexpected"}, "mode": 420}]' "$rendered_ignition" > "$tmp_dir/$mutation.ign"
				;;
		esac
		if OBSERVABILITY_RENDERED_IGNITION="$tmp_dir/$mutation.ign" "$0" >/dev/null 2>&1; then
			echo "render mutation accepted: $mutation" >&2
			exit 1
		fi
	done <<EOF
$mutations
EOF
	echo 'observability render mutation contract: PASS'
	exit 0
fi
if [ -n "${OBSERVABILITY_RENDERED_IGNITION:-}" ]; then
	rendered_ignition=$OBSERVABILITY_RENDERED_IGNITION
else
	"$repo_dir/scripts/render-ignition" "$public_key_file" "$rendered_ignition"
fi
jq -e . "$rendered_ignition" >/dev/null
if find "$tmp_dir" -maxdepth 1 -name '.*.tmp.*' -print -quit | grep -q .; then
	echo 'renderer left a temporary output file after success' >&2
	exit 1
fi
jq -e '
  (.storage.directories | map(.path) | length == (unique | length)) and
  (.storage.files | map(.path) | length == (unique | length)) and
  (.systemd.units | map(.name) | length == (unique | length))
' "$rendered_ignition" >/dev/null || {
	echo 'rendered Ignition contains duplicate directory, file, or unit names' >&2
	exit 1
}

assert_dir_mode() {
	path=$1
	expected_mode=$2
	actual_mode=$(jq -er --arg path "$path" 'first(.storage.directories[] | select(.path == $path) | .mode)' "$rendered_ignition")
	[ "$actual_mode" = "$expected_mode" ] || {
		echo "directory $path mode $actual_mode, expected $expected_mode" >&2
		exit 1
	}
}

assert_dir_mode /etc/observability 493
assert_dir_mode /etc/observability/secrets 448
assert_dir_mode /var/lib/openobserve 488
assert_dir_mode /var/lib/observability 488
assert_dir_mode /var/lib/observability/caddy 488
assert_dir_mode /var/lib/observability/caddy/data 488
assert_dir_mode /var/lib/observability/caddy/config 488
assert_dir_mode /var/lib/otelcol 488

source_paths='
/etc/observability/images.env|config/observability/images.env|420|config
/etc/observability/openobserve.env|config/observability/openobserve.env|420|config
/etc/observability/Caddyfile|config/observability/Caddyfile|420|config
/etc/observability/otel-gateway.yaml|config/observability/otel-gateway.yaml|420|config
/etc/observability/otel-gateway-systemd.yaml|config/observability/otel-gateway-systemd.yaml|420|config
/etc/observability/otel-docker-agent.yaml|config/observability/otel-docker-agent.yaml|420|config
/etc/observability/bin/run-otel-collector|config/observability/bin/run-otel-collector|493|runner
/etc/observability/bin/emit-host-storage-metrics|config/observability/bin/emit-host-storage-metrics|493|runner
/etc/observability/systemd/openobserve.service|config/observability/systemd/openobserve.service|420|unit
/etc/observability/systemd/observe-proxy.service|config/observability/systemd/observe-proxy.service|420|unit
/etc/observability/systemd/otel-collector.service|config/observability/systemd/otel-collector.service|420|unit
/etc/observability/systemd/otel-docker-agent.service|config/observability/systemd/otel-docker-agent.service|420|unit
/etc/observability/systemd/otelcol-queue-prepare.service|config/observability/systemd/otelcol-queue-prepare.service|420|unit
/etc/observability/systemd/var-lib-otelcol.mount|config/observability/systemd/var-lib-otelcol.mount|420|unit
/etc/observability/systemd/observability-storage-metrics.service|config/observability/systemd/observability-storage-metrics.service|420|unit
/etc/observability/systemd/observability-storage-metrics.timer|config/observability/systemd/observability-storage-metrics.timer|420|unit'

printf '%s\n' "$source_paths" | while IFS='|' read -r ignition_path source_path expected_mode kind; do
	[ -n "$ignition_path" ] || continue
	jq -e --arg path "$ignition_path" --argjson mode "$expected_mode" \
		'any(.storage.files[]; .path == $path and .mode == $mode and .contents.compression == "" and (.contents.source | startswith("data:text/plain;charset=utf-8;base64,")))' \
		"$rendered_ignition" >/dev/null || {
		echo "missing or malformed rendered $kind: $ignition_path" >&2
		exit 1
	}
	decoded="$tmp_dir/$(printf '%s' "$ignition_path" | tr '/.' '__')"
	encoded=$(jq -er --arg path "$ignition_path" 'first(.storage.files[] | select(.path == $path) | .contents.source | sub("^data:text/plain;charset=utf-8;base64,"; ""))' "$rendered_ignition")
	printf '%s' "$encoded" | base64 -D > "$decoded"
	cmp -s "$repo_dir/$source_path" "$decoded" || {
		echo "decoded bytes differ for $source_path" >&2
		exit 1
	}
	if [ "$kind" = unit ]; then
		unit_name=${ignition_path##*/}
		unit_content="$tmp_dir/unit-$(printf '%s' "$unit_name" | tr '/.' '__')"
		jq -ej --arg name "$unit_name" 'first(.systemd.units[] | select(.name == $name) | .contents)' "$rendered_ignition" > "$unit_content"
		cmp -s "$repo_dir/$source_path" "$unit_content" || {
			echo "rendered unit object differs for $source_path" >&2
			exit 1
		}
	fi
done

expected_observability_files='["/etc/observability/Caddyfile", "/etc/observability/bin/emit-host-storage-metrics", "/etc/observability/bin/run-otel-collector", "/etc/observability/images.env", "/etc/observability/openobserve.env", "/etc/observability/otel-docker-agent.yaml", "/etc/observability/otel-gateway-systemd.yaml", "/etc/observability/otel-gateway.yaml", "/etc/observability/systemd/observability-storage-metrics.service", "/etc/observability/systemd/observability-storage-metrics.timer", "/etc/observability/systemd/observe-proxy.service", "/etc/observability/systemd/openobserve.service", "/etc/observability/systemd/otel-collector.service", "/etc/observability/systemd/otel-docker-agent.service", "/etc/observability/systemd/otelcol-queue-prepare.service", "/etc/observability/systemd/var-lib-otelcol.mount"]'
jq -c '[.storage.files[] | select(.path | startswith("/etc/observability/")) | .path] | sort' "$rendered_ignition" > "$tmp_dir/actual-observability-files.json"
jq -cn --argjson expected "$expected_observability_files" '$expected | sort' > "$tmp_dir/expected-observability-files.json"
cmp -s "$tmp_dir/expected-observability-files.json" "$tmp_dir/actual-observability-files.json" || {
	echo 'observability file set contains an unexpected or missing path' >&2
	exit 1
}

expected_units='openobserve.service
observe-proxy.service
otel-collector.service
otel-docker-agent.service
otelcol-queue-prepare.service
var-lib-otelcol.mount
observability-storage-metrics.service
observability-storage-metrics.timer'
actual_units=$(jq -r '.systemd.units[] | select(.name | test("^(openobserve|observe-proxy|otel-collector|otel-docker-agent|otelcol-queue-prepare|var-lib-otelcol|observability-storage-metrics)")) | .name' "$rendered_ignition")
[ "$actual_units" = "$expected_units" ] || {
	echo 'observability unit set differs from the eight approved sources' >&2
	exit 1
}

for unit in openobserve.service observe-proxy.service otel-collector.service otel-docker-agent.service var-lib-otelcol.mount observability-storage-metrics.timer; do
	jq -e --arg name "$unit" 'any(.systemd.units[]; .name == $name and .enabled == true)' "$rendered_ignition" >/dev/null || {
		echo "expected enabled observability unit: $unit" >&2
		exit 1
	}
done
for unit in otelcol-queue-prepare.service observability-storage-metrics.service; do
	if jq -e --arg name "$unit" 'any(.systemd.units[]; .name == $name and .enabled == true)' "$rendered_ignition" >/dev/null; then
		echo "helper oneshot must not be enabled directly: $unit" >&2
		exit 1
	fi
done

for secret in openobserve.env observe-proxy.env otel-collector.env; do
	if jq -e --arg path "/etc/observability/secrets/$secret" 'any(.storage.files[]; .path == $path)' "$rendered_ignition" >/dev/null; then
		echo "runtime secret file must not be rendered: $secret" >&2
		exit 1
	fi
done

for condition in \
	'openobserve.service|ConditionPathExists=/etc/observability/secrets/openobserve.env' \
	'observe-proxy.service|ConditionPathExists=/etc/observability/secrets/observe-proxy.env' \
	'otel-collector.service|ConditionPathExists=/etc/observability/secrets/otel-collector.env' \
	'otel-docker-agent.service|ConditionPathExists=/etc/observability/secrets/otel-collector.env'; do
	unit=${condition%%|*}
	line=${condition#*|}
	jq -e --arg name "$unit" --arg line "$line" 'any(.systemd.units[]; .name == $name and (.contents | contains($line)))' "$rendered_ignition" >/dev/null || {
		echo "missing readiness condition $line in $unit" >&2
		exit 1
	}
done

observability_text=$(jq -r '[.storage.files[] | select(.path | startswith("/etc/observability/")) | .contents.source | sub("^data:text/plain;charset=utf-8;base64,"; "")] | .[]' "$rendered_ignition" | while IFS= read -r encoded; do printf '%s' "$encoded" | base64 -D; done)
if printf '%s\n' "$observability_text" | grep -Eq '(^|[[:space:]])(ZO_ROOT_USER_EMAIL|ZO_ROOT_USER_PASSWORD|CLOUDFLARE_API_TOKEN|HOMELAB_OTLP_TOKEN|AI_OTLP_TOKEN|OPENOBSERVE_INGEST_AUTH_HEADER)='; then
	echo 'rendered observability content contains a secret assignment' >&2
	exit 1
fi
image_lines=$(printf '%s\n' "$observability_text" | grep -E '^[A-Z]+_IMAGE=' || true)
[ "$(printf '%s\n' "$image_lines" | sed '/^$/d' | wc -l | tr -d ' ')" = 3 ] || {
	echo 'rendered observability image lock set is incomplete' >&2
	exit 1
}
if printf '%s\n' "$image_lines" | grep -Ev '@sha256:[0-9a-f]{64}$' >/dev/null; then
	echo 'rendered observability image is not pinned by a digest' >&2
	exit 1
fi

observability_units=$(jq -r '.systemd.units[] | select(.name | test("^(openobserve|observe-proxy|otel-collector|otel-docker-agent|otelcol-queue-prepare|var-lib-otelcol|observability-storage-metrics)")) | .contents' "$rendered_ignition")
for forbidden in scrypted.service scrypted-watchtower.service var-lib-scrypted-nvr.mount var-lib-scrypted-nvr2.mount scrypted-recovery.timer com.centurylinklabs.watchtower.scope WATCHTOWER_SCOPE; do
	if printf '%s\n' "$observability_units" | grep -Fq -- "$forbidden"; then
		echo "observability unit contains forbidden dependency or scope: $forbidden" >&2
		exit 1
	fi
done
if printf '%s\n' "$observability_units" | grep -Eq -- '--mount[^\n]*?/var/lib/scrypted/nvr|--mount[^\n]*?/var/lib/scrypted/nvr2'; then
	echo 'observability container bind references an NVR mount' >&2
	exit 1
fi
container_units=$(jq -r '.systemd.units[] | select(.name | test("^(openobserve|observe-proxy|otel-collector|otel-docker-agent)$")) | .contents' "$rendered_ignition")
if printf '%s\n' "$container_units" | grep -Fq '/var/lib/scrypted/nvr'; then
	echo 'observability container state or output path is under an NVR mount' >&2
	exit 1
fi

storage_probe=$(jq -r --arg path "/etc/observability/bin/emit-host-storage-metrics" 'first(.storage.files[] | select(.path == $path) | .contents.source | sub("^data:text/plain;charset=utf-8;base64,"; ""))' "$rendered_ignition" | base64 -D)
if printf '%s\n' "$storage_probe" | grep -Eq '(^|[[:space:]])(mount|umount|fsck|e2fsck|find|ls|du)([[:space:]]|$)'; then
	echo 'storage probe contains a mount, repair, or directory-enumeration command' >&2
	exit 1
fi
storage_service=$(jq -r --arg name observability-storage-metrics.service 'first(.systemd.units[] | select(.name == $name) | .contents)' "$rendered_ignition")
printf '%s\n' "$storage_service" | grep -Fqx 'Type=oneshot' || {
	echo 'storage probe must be a oneshot' >&2
	exit 1
}
printf '%s\n' "$storage_service" | grep -Fqx 'TimeoutStartSec=10s' || {
	echo 'storage probe timeout changed' >&2
	exit 1
}

for unit in scrypted.service scrypted-watchtower.service var-lib-scrypted-nvr.mount var-lib-scrypted-nvr2.mount scrypted-recovery.timer; do
	if jq -e --arg name "$unit" 'any(.systemd.units[]; .name == $name and ((.contents // "") | test("openobserve.service|observe-proxy.service|otel-collector.service|otel-docker-agent.service|otelcol-queue-prepare.service|var-lib-otelcol.mount|observability-storage-metrics.service|observability-storage-metrics.timer")))' "$rendered_ignition" >/dev/null; then
		echo "existing Scrypted/storage unit references observability" >&2
		exit 1
	fi
done

expected_observability_dirs='["/etc/observability", "/etc/observability/secrets", "/var/lib/openobserve", "/var/lib/observability", "/var/lib/observability/caddy", "/var/lib/observability/caddy/data", "/var/lib/observability/caddy/config", "/var/lib/otelcol"]'
jq -c '[.storage.directories[] | select(.path | startswith("/etc/observability") or startswith("/var/lib/observability") or . == "/var/lib/openobserve" or . == "/var/lib/otelcol")] | sort_by(.path)' "$rendered_ignition" > "$tmp_dir/actual-observability-directories.json"
jq -cn --argjson expected "$expected_observability_dirs" '$expected | map({path: ., mode: (if . == "/etc/observability" then 493 elif . == "/etc/observability/secrets" then 448 else 488 end)}) | sort_by(.path)' > "$tmp_dir/expected-observability-directories.json"
cmp -s "$tmp_dir/expected-observability-directories.json" "$tmp_dir/actual-observability-directories.json" || {
	echo 'observability directory set differs from the approved set' >&2
	exit 1
}
jq -c '[.storage.directories[] | select((.path | startswith("/etc/observability") or startswith("/var/lib/observability") or . == "/var/lib/openobserve" or . == "/var/lib/otelcol") | not)]' "$rendered_ignition" > "$tmp_dir/actual-scrypted-directories.json"
jq -c '.directories' "$baseline_template" > "$tmp_dir/expected-scrypted-directories.json"
cmp -s "$tmp_dir/expected-scrypted-directories.json" "$tmp_dir/actual-scrypted-directories.json" || {
	echo 'baseline storage directory objects changed' >&2
	exit 1
}
jq -c '[.storage.files[] | select((.path | startswith("/etc/observability/")) | not)]' "$rendered_ignition" > "$tmp_dir/actual-scrypted-files.json"
jq -c '.files' "$baseline_template" > "$tmp_dir/expected-scrypted-files.json"
cmp -s "$tmp_dir/expected-scrypted-files.json" "$tmp_dir/actual-scrypted-files.json" || {
	echo 'baseline storage file objects changed' >&2
	exit 1
}
jq -c '[.systemd.units[] | select((.name | test("^(openobserve|observe-proxy|otel-collector|otel-docker-agent|otelcol-queue-prepare|var-lib-otelcol|observability-storage-metrics)")) | not)]' "$rendered_ignition" > "$tmp_dir/actual-scrypted-units.json"
jq -c '.units' "$baseline_template" > "$tmp_dir/expected-scrypted-units.json"
cmp -s "$tmp_dir/expected-scrypted-units.json" "$tmp_dir/actual-scrypted-units.json" || {
	echo 'baseline systemd unit objects changed' >&2
	exit 1
}

echo 'observability Ignition render contract: PASS'
