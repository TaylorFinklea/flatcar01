#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
config_dir="$repo_dir/config/observability"

fail() {
	echo "OTel Docker agent contract: $1" >&2
	exit 1
}

require_file() {
	[ -f "$1" ] || fail "missing $1"
}

config_file="$config_dir/otel-docker-agent.yaml"
unit_file="$config_dir/systemd/otel-docker-agent.service"
gateway_file="$config_dir/otel-gateway.yaml"

if [ "${1:-}" = "--self-test" ]; then
	test_dir=$(mktemp -d "${TMPDIR:-/tmp}/otel-docker-agent.XXXXXX")
	trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
	ruby - "$config_file" "$unit_file" "$gateway_file" "$test_dir" <<'RUBY'
config_path, unit_path, gateway_path, output_dir = ARGV
config = File.read(config_path)
unit = File.read(unit_path)
gateway = File.read(gateway_path)

backslash = 92.chr
continuation = ->(value) { "  #{value} #{backslash}\n" }
mutations = {
  "unit-privileged" => [unit, unit.sub(continuation.call("--pull=never"), continuation.call("--privileged") + continuation.call("--pull=never"))],
  "unit-cap-add" => [unit, unit.sub(continuation.call("--cap-drop=ALL"), continuation.call("--cap-drop=ALL") + continuation.call("--cap-add=NET_ADMIN"))],
  "unit-volume" => [unit, unit.sub(continuation.call("--read-only"), continuation.call("--read-only") + continuation.call("--volume /tmp:/var/lib/agent"))],
  "unit-mount-equals" => [unit, unit.sub(continuation.call("--mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock,readonly"), "  --mount=type=bind,source=/tmp,target=/tmp,readonly #{backslash}\n" + continuation.call("--mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock,readonly"))],
  "unit-publish-all" => [unit, unit.sub(continuation.call("--network host"), continuation.call("--network host") + continuation.call("--publish-all"))],
  "unit-uppercase-p" => [unit, unit.sub(continuation.call("--network host"), continuation.call("--network host") + continuation.call("-P"))],
  "unit-pid-host" => [unit, unit.sub(continuation.call("--network host"), continuation.call("--network host") + continuation.call("--pid=host"))],
  "unit-ipc-host" => [unit, unit.sub(continuation.call("--network host"), continuation.call("--network host") + continuation.call("--ipc=host"))],
  "unit-uts-host" => [unit, unit.sub(continuation.call("--network host"), continuation.call("--network host") + continuation.call("--uts=host"))],
  "unit-device" => [unit, unit.sub(continuation.call("--network host"), continuation.call("--network host") + continuation.call("--device=/dev/kmsg"))],
  "unit-extra-exec" => [unit, "#{unit}ExecStart=/usr/bin/evil-agent\n"],
  "unit-extra-pre" => [unit, "#{unit}ExecStartPre=/usr/bin/docker inspect otel-docker-agent\n"],
  "unit-environment" => [unit, unit.sub("[Service]\n", "[Service]\nEnvironment=OTELCOL_IMAGE=evil:latest\n")],
  "unit-pass-environment" => [unit, unit.sub("[Service]\n", "[Service]\nPassEnvironment=OTELCOL_IMAGE\n")],
  "unit-exec-start-post" => [unit, unit.sub("[Service]\n", "[Service]\nExecStartPost=/usr/bin/evil\n")],
  "unit-exec-reload" => [unit, unit.sub("[Service]\n", "[Service]\nExecReload=/usr/bin/evil\n")],
  "unit-exec-condition" => [unit, unit.sub("[Service]\n", "[Service]\nExecCondition=/usr/bin/evil\n")],
  "unit-set-credential" => [unit, unit.sub("[Service]\n", "[Service]\nSetCredential=evil:value\n")],
  "unit-load-credential" => [unit, unit.sub("[Service]\n", "[Service]\nLoadCredential=evil\n")],
  "unit-import-credential" => [unit, unit.sub("[Service]\n", "[Service]\nImportCredential=evil\n")],
  "yaml-extra-condition" => [config, config.sub('      - resource.attributes["telemetry.synthetic"] != nil and IsBool(resource.attributes["telemetry.synthetic"]) == false') { |line| "#{line}\n      - metric.name != \"container.unknown\"" }],
  "yaml-extra-statement" => [config, config.sub('          - keep_keys(datapoint.attributes, ["operation"])') { |line| "#{line}\n          - delete_key(datapoint.attributes, \"unexpected\")" }],
  "yaml-extra-exporter-key" => [config, config.sub('    metrics_endpoint: http://127.0.0.1:4320/v1/metrics') { |line| "#{line}\n    timeout: 5s" }],
  "yaml-duplicate-key" => [config, config.sub('    metrics_endpoint: http://127.0.0.1:4320/v1/metrics') { |line| "#{line}\n    metrics_endpoint: http://127.0.0.1:4320/v1/metrics" }],
  "gateway-extra-condition" => [gateway, gateway.sub('      - metric.name == "container.blockio.io_service_bytes_recursive" and datapoint.attributes["operation"] != "read" and datapoint.attributes["operation"] != "write"') { |line| "#{line}\n      - metric.name != \"container.unknown\"" }],
  "gateway-extra-statement" => [gateway, gateway.sub('          - keep_keys(datapoint.attributes, ["operation"])') { |line| "#{line}\n          - delete_key(datapoint.attributes, \"unexpected\")" }],
  "gateway-altered-schema" => [gateway, gateway.sub('resource.attributes["container.name"] != "scrypted-watchtower"', 'resource.attributes["container.name"] != "evil-container"')],
}

mutations.each do |name, (source, mutated)|
  raise "mutation source missing: #{name}" if source == mutated
  File.write(File.join(output_dir, "#{name}.txt"), mutated)
end
RUBY

	# Unit mutations use the unit override; YAML mutations use the config override.
	for mutation in unit-privileged unit-cap-add unit-volume unit-mount-equals unit-publish-all unit-uppercase-p unit-pid-host unit-ipc-host unit-uts-host unit-device unit-extra-exec unit-extra-pre unit-environment unit-pass-environment unit-exec-start-post unit-exec-reload unit-exec-condition unit-set-credential unit-load-credential unit-import-credential; do
		if OTEL_DOCKER_AGENT_UNIT="$test_dir/$mutation.txt" "$0" >/dev/null 2>&1; then
			fail "self-test mutation accepted: $mutation"
		fi
	done
	for mutation in yaml-extra-condition yaml-extra-statement yaml-extra-exporter-key yaml-duplicate-key; do
		if OTEL_DOCKER_AGENT_CONFIG="$test_dir/$mutation.txt" "$0" >/dev/null 2>&1; then
			fail "self-test mutation accepted: $mutation"
		fi
	done
	for mutation in gateway-extra-condition gateway-extra-statement gateway-altered-schema; do
		if OTEL_DOCKER_AGENT_GATEWAY="$test_dir/$mutation.txt" "$0" >/dev/null 2>&1; then
			fail "self-test mutation accepted: $mutation"
		fi
	done
	echo "OTel Docker agent mutation contract: PASS"
	exit 0
fi

config_file=${OTEL_DOCKER_AGENT_CONFIG:-$config_file}
unit_file=${OTEL_DOCKER_AGENT_UNIT:-$unit_file}
gateway_file=${OTEL_DOCKER_AGENT_GATEWAY:-$gateway_file}

require_file "$config_file"
require_file "$unit_file"
require_file "$gateway_file"

	ruby -ryaml -rshellwords - "$config_file" "$unit_file" "$gateway_file" <<'RUBY'
config_path, unit_path, gateway_path = ARGV

def assert!(condition, message)
  raise "OTel Docker agent contract: #{message}" unless condition
end

def yaml(path)
  tree = Psych.parse_stream(File.read(path))
  walk = lambda do |node|
    if node.is_a?(Psych::Nodes::Mapping)
      keys = node.children.each_slice(2).map { |key, _value| key.value }
      raise "OTel Docker agent contract: duplicate YAML key in #{path}" unless keys.uniq.length == keys.length
    end
    children = node.children if node.respond_to?(:children)
    children.each { |child| walk.call(child) } if children
  end
  walk.call(tree)
  YAML.safe_load(File.read(path), aliases: false)
rescue Psych::Exception => error
  raise "OTel Docker agent contract: invalid YAML #{path}: #{error.message}"
end

config = yaml(config_path)
gateway = yaml(gateway_path)
unit = File.read(unit_path)

assert!(config.is_a?(Hash), "agent config root must be a mapping")
assert!(config.keys.sort == %w[exporters processors receivers service], "agent config must contain only the approved component sections")

receivers = config.fetch("receivers")
assert!(receivers.keys == ["docker_stats"], "agent must expose only the docker_stats receiver")
assert!(receivers.fetch("docker_stats") == {"endpoint" => "unix:///var/run/docker.sock", "collection_interval" => "30s", "timeout" => "5s"}, "docker_stats must use only the fixed socket, interval, and timeout")

processors = config.fetch("processors")
assert!(processors.keys.sort == ["batch/metrics", "filter/drop_unapproved_docker_metrics", "memory_limiter", "transform/normalize_docker_metrics"].sort, "agent must have only bounded Docker sanitization processors")
assert!(processors.fetch("memory_limiter") == {"check_interval" => "1s", "limit_mib" => 256, "spike_limit_mib" => 48}, "agent memory limiter must be 256 MiB with a 48 MiB spike allowance")

docker_metric_names = %w[
  container.cpu.usage.total
  container.cpu.utilization
  container.memory.usage.total
  container.memory.usage.limit
  container.network.io.usage.rx_bytes
  container.network.io.usage.tx_bytes
  container.blockio.io_service_bytes_recursive
]

filter = processors.fetch("filter/drop_unapproved_docker_metrics")
expected_filter_conditions = [
  'metric.name != "container.cpu.usage.total" and metric.name != "container.cpu.utilization" and metric.name != "container.memory.usage.total" and metric.name != "container.memory.usage.limit" and metric.name != "container.network.io.usage.rx_bytes" and metric.name != "container.network.io.usage.tx_bytes" and metric.name != "container.blockio.io_service_bytes_recursive"',
  'resource.attributes["container.name"] != "scrypted" and resource.attributes["container.name"] != "scrypted-watchtower" and resource.attributes["container.name"] != "openobserve" and resource.attributes["container.name"] != "observe-proxy" and resource.attributes["container.name"] != "otel-collector" and resource.attributes["container.name"] != "otel-docker-agent"',
  'metric.name == "container.blockio.io_service_bytes_recursive" and datapoint.attributes["operation"] != "read" and datapoint.attributes["operation"] != "write"',
  'resource.attributes["telemetry.synthetic"] != nil and IsBool(resource.attributes["telemetry.synthetic"]) == false',
]
assert!(filter == {"error_mode" => "propagate", "metric_conditions" => expected_filter_conditions}, "Docker filtering must have the exact fail-closed condition set and order")
conditions = expected_filter_conditions.join("\n")
docker_metric_names.each do |name|
  assert!(conditions.include?(%Q{metric.name != "#{name}"}), "Docker filtering must reject unknown metric #{name}")
end
%w[scrypted scrypted-watchtower openobserve observe-proxy otel-collector otel-docker-agent].each do |name|
  assert!(conditions.include?(%Q{resource.attributes["container.name"] != "#{name}"}), "Docker filtering must allow only the approved container #{name}")
end
assert!(conditions.include?('metric.name == "container.blockio.io_service_bytes_recursive" and datapoint.attributes["operation"] != "read" and datapoint.attributes["operation"] != "write"'), "Docker filtering must allow only read/write block-I/O operations")
assert!(conditions.include?('resource.attributes["telemetry.synthetic"] != nil and IsBool(resource.attributes["telemetry.synthetic"]) == false'), "Docker filtering must retain telemetry.synthetic only when boolean")

transform = processors.fetch("transform/normalize_docker_metrics")
expected_transform = {
  "error_mode" => "propagate",
  "metric_statements" => [
    {
      "context" => "resource",
      "statements" => [
        'set(resource.attributes["host.name"], "scrypted-nvr")',
        'set(resource.attributes["telemetry.synthetic"], false) where resource.attributes["telemetry.synthetic"] == nil',
        'keep_keys(resource.attributes, ["host.name", "container.name", "telemetry.synthetic"])',
      ],
    },
    {
      "context" => "datapoint",
      "statements" => ['keep_keys(datapoint.attributes, ["operation"])'],
    },
  ],
}
assert!(transform == expected_transform, "Docker normalization must have the exact statement groups, order, and terminal keep_keys operations")
statements = expected_transform.fetch("metric_statements").flat_map { |group| group.fetch("statements") }
[
  'set(resource.attributes["host.name"], "scrypted-nvr")',
  'set(resource.attributes["telemetry.synthetic"], false) where resource.attributes["telemetry.synthetic"] == nil',
  'keep_keys(resource.attributes, ["host.name", "container.name", "telemetry.synthetic"])',
  'keep_keys(datapoint.attributes, ["operation"])',
].each { |statement| assert!(statements.include?(statement), "Docker normalization must contain #{statement}") }

batch = processors.fetch("batch/metrics")
assert!(batch == {"send_batch_size" => 512, "send_batch_max_size" => 512, "timeout" => "5s"}, "Docker batches must be bounded after sanitization")

exporters = config.fetch("exporters")
assert!(exporters.keys == ["otlp_http/docker_agent"], "agent must expose only one OTLP/HTTP exporter")
exporter = exporters.fetch("otlp_http/docker_agent")
assert!(exporter == {"metrics_endpoint" => "http://127.0.0.1:4320/v1/metrics"}, "agent exporter must have exactly the loopback metrics endpoint and no queue, headers, or other settings")

service = config.fetch("service")
assert!(service.keys.sort == ["pipelines", "telemetry"], "agent service must contain only telemetry and pipelines")
assert!(service.fetch("telemetry") == {"metrics" => {"level" => "none"}}, "agent telemetry metrics must be disabled with no listener configuration")
assert!(!service.key?("extensions"), "agent must not enable extensions")
pipelines = service.fetch("pipelines")
assert!(pipelines.keys == ["metrics/docker"], "agent must expose only the Docker metrics pipeline")
pipeline = pipelines.fetch("metrics/docker")
assert!(pipeline == {"receivers" => ["docker_stats"], "processors" => ["memory_limiter", "filter/drop_unapproved_docker_metrics", "transform/normalize_docker_metrics", "batch/metrics"], "exporters" => ["otlp_http/docker_agent"]}, "Docker pipeline must have exactly the approved receivers, processor order, and exporter")

gateway_filter = gateway.fetch("processors").fetch("filter/drop_unapproved_docker_metrics")
gateway_transform = gateway.fetch("processors").fetch("transform/normalize_docker_metrics")
assert!(gateway_filter == {"error_mode" => "propagate", "metric_conditions" => expected_filter_conditions}, "gateway Docker filtering must have the exact fail-closed condition set and order")
expected_gateway_transform = {
  "error_mode" => "propagate",
  "metric_statements" => [
    {
      "context" => "resource",
      "statements" => [
        'set(resource.schema_url, "")',
        'set(resource.dropped_attributes_count, 0)',
        'set(resource.attributes["host.name"], "scrypted-nvr")',
        'set(resource.attributes["telemetry.synthetic"], false) where resource.attributes["telemetry.synthetic"] == nil',
        'keep_keys(resource.attributes, ["host.name", "container.name", "telemetry.synthetic"])',
      ],
    },
    {
      "context" => "scope",
      "statements" => [
        'set(scope.name, "")',
        'set(scope.version, "")',
        'set(scope.schema_url, "")',
        'set(scope.dropped_attributes_count, 0)',
        'delete_matching_keys(scope.attributes, ".*")',
      ],
    },
    {
      "context" => "metric",
      "statements" => [
        'set(metric.description, "")',
        'set(metric.unit, "")',
        'delete_matching_keys(metric.metadata, ".*")',
      ],
    },
    {
      "context" => "datapoint",
      "statements" => [
        'set(datapoint.flags, 0)',
        'set(datapoint.exemplars, nil)',
        'keep_keys(datapoint.attributes, ["operation"])',
      ],
    },
  ],
}
assert!(gateway_transform == expected_gateway_transform, "gateway Docker normalization must clear every non-contract carrier before the terminal attribute allowlists")

required_unit_fragments = [
  "ConditionPathExists=/etc/observability/images.env",
  "ConditionPathExists=/etc/observability/otel-docker-agent.yaml",
  "ConditionPathExists=/etc/observability/secrets/otel-collector.env",
  "EnvironmentFile=/etc/observability/images.env",
  "--pull=never",
  "--network host",
  "--user 10001:10001",
  "--group-add=233",
  "--read-only",
  "--cap-drop=ALL",
  "--security-opt no-new-privileges",
  "--memory=384m",
  "--cpus=0.5",
  "--env GOMEMLIMIT=256MiB",
  "--mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock,readonly",
  "--mount type=bind,source=/etc/observability/otel-docker-agent.yaml,target=/etc/otelcol/config.yaml,readonly",
  "--tmpfs /tmp:rw,noexec,nosuid,nodev,size=32m,uid=10001,gid=10001,mode=0700",
]
required_unit_fragments.each { |fragment| assert!(unit.include?(fragment), "unit must contain #{fragment}") }
assert!(unit.include?("ExecStart=/usr/bin/docker run"), "unit must run the pinned image in the foreground")
assert!(unit.include?("${OTELCOL_IMAGE}"), "unit must use the pinned OTELCOL_IMAGE variable")
assert!(unit.include?("After=network-online.target docker.service") && unit.include?("Requires=docker.service"), "unit may depend only on network readiness and Docker")
assert!(unit.include?("Restart=on-failure"), "unit must restart only after failure")
assert!(unit.scan("/etc/observability/secrets/otel-collector.env").length == 1, "collector secret path may occur only as the readiness marker")
assert!(!unit.include?("--env-file"), "Docker agent must not read a secret env file")

continuation_suffix = 92.chr
section_order = []
section_directives = Hash.new { |hash, key| hash[key] = [] }
current_section = nil
continuation = false
unit.lines.each do |raw_line|
  line = raw_line.chomp
  next if line.empty? || line.start_with?("#")
  if line.start_with?("[")
    assert!(line.match?(/\A\[(Unit|Service|Install)\]\z/), "unit contains an unapproved section")
    current_section = line[1...-1]
    assert!(!section_order.include?(current_section), "unit must not repeat a section")
    section_order << current_section
    continuation = false
    next
  end
  if line.start_with?(" ") || line.start_with?("\t")
    assert!(continuation, "unit contains an indented line outside a continued ExecStart")
    continuation = line.end_with?(continuation_suffix)
    next
  end
  assert!(!current_section.nil? && line.include?("="), "unit contains a malformed directive")
  key, value = line.split("=", 2)
  section_directives[current_section] << [key, value]
  continuation = value.end_with?(continuation_suffix)
end
expected_directives = {
  "Unit" => [
    ["Description", "Isolated Docker metrics agent"],
    ["Wants", "network-online.target"],
    ["After", "network-online.target docker.service"],
    ["Requires", "docker.service"],
    ["ConditionPathExists", "/etc/observability/images.env"],
    ["ConditionPathExists", "/etc/observability/otel-docker-agent.yaml"],
    ["ConditionPathExists", "/etc/observability/secrets/otel-collector.env"],
  ],
  "Service" => [
    ["Type", "simple"],
    ["EnvironmentFile", "/etc/observability/images.env"],
    ["TimeoutStartSec", "0"],
    ["TimeoutStopSec", "45"],
    ["UMask", "0077"],
    ["ExecStartPre", "-/usr/bin/docker rm --force otel-docker-agent"],
    ["ExecStart", "/usr/bin/docker run --name otel-docker-agent #{continuation_suffix}"],
    ["ExecStop", "-/usr/bin/docker stop --time 30 otel-docker-agent"],
    ["Restart", "on-failure"],
    ["RestartSec", "10"],
    ["StandardOutput", "journal"],
    ["StandardError", "journal"],
  ],
  "Install" => [["WantedBy", "multi-user.target"]],
}
assert!(section_order == ["Unit", "Service", "Install"], "unit must contain exactly the Unit, Service, and Install sections in order")
assert!(section_directives == expected_directives, "unit must contain exactly the approved directive names, counts, values, and order")

assert!(unit.lines.grep(/\AConditionPathExists=/).map(&:chomp) == [
  "ConditionPathExists=/etc/observability/images.env",
  "ConditionPathExists=/etc/observability/otel-docker-agent.yaml",
  "ConditionPathExists=/etc/observability/secrets/otel-collector.env",
], "unit must have exactly the three approved readiness conditions")
assert!(unit.lines.grep(/\AEnvironmentFile=/).map(&:chomp) == ["EnvironmentFile=/etc/observability/images.env"], "unit must read only the non-secret image lock")
assert!(unit.lines.grep(/\AExecStartPre=/).map(&:chomp) == ["ExecStartPre=-/usr/bin/docker rm --force otel-docker-agent"], "unit must have only the expected stale-container cleanup command")
assert!(unit.lines.grep(/\AExecStop=/).map(&:chomp) == ["ExecStop=-/usr/bin/docker stop --time 30 otel-docker-agent"], "unit must have only the expected stop command")

exec_start_lines = unit.lines.each_index.select { |index| unit.lines[index].start_with?("ExecStart=") }
assert!(exec_start_lines.length == 1, "unit must contain exactly one Docker ExecStart command")
start_index = exec_start_lines.fetch(0)
command = unit.lines.fetch(start_index).chomp.delete_prefix("ExecStart=")
line_index = start_index
while command.end_with?(92.chr)
  command = command[0...-1]
  line_index += 1
  assert!(line_index < unit.lines.length, "Docker ExecStart continuation must have a following line")
  command += " #{unit.lines.fetch(line_index).strip}"
end
argv = Shellwords.split(command)
expected_argv = [
  "/usr/bin/docker", "run", "--name", "otel-docker-agent", "--pull=never", "--network", "host",
  "--user", "10001:10001", "--group-add=233", "--read-only", "--cap-drop=ALL", "--security-opt",
  "no-new-privileges", "--memory=384m", "--cpus=0.5", "--pids-limit=256", "--env", "GOMEMLIMIT=256MiB",
  "--mount", "type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock,readonly",
  "--mount", "type=bind,source=/etc/observability/otel-docker-agent.yaml,target=/etc/otelcol/config.yaml,readonly",
  "--tmpfs", "/tmp:rw,noexec,nosuid,nodev,size=32m,uid=10001,gid=10001,mode=0700",
  "--log-driver", "journald", "${OTELCOL_IMAGE}", "--config=/etc/otelcol/config.yaml",
]
assert!(argv == expected_argv, "Docker ExecStart must match the exact ordered hardened command surface")

forbidden = [
  /docker-socket-proxy/i,
  /CONTAINERS=1/,
  /chmod/,
  /socket.?mode/i,
  /docker pull/i,
  /--publish(?:=|\s)|\s-p\d|\s-p\s/i,
  /nvr_primary|nvr_secondary|\/var\/lib\/scrypted/i,
  /CLOUDFLARE|OPENOBSERVE|HOMELAB_OTLP|AI_OTLP|Authorization|Bearer/,
]
forbidden.each do |pattern|
  assert!(!unit.match?(pattern), "unit contains forbidden #{pattern}")
  assert!(!File.read(config_path).match?(pattern), "agent config contains forbidden #{pattern}")
end
assert!(!unit.match?(/Watchtower|com\.centurylinklabs\.watchtower\.scope/i), "unit contains a Watchtower dependency or label")
assert!(!unit.match?(/scrypted|nvr_primary|nvr_secondary|\/var\/lib\/scrypted/i), "unit contains an appliance dependency or path")

mounts = unit.scan(/--mount ([^\n\\]+)/).flatten.map { |value| value.strip }
assert!(mounts.length == 2, "unit must have exactly two bind mounts")
assert!(mounts.all? { |mount| mount.end_with?(",readonly") }, "all agent bind mounts must be read-only")
assert!(!unit.match?(/(?:-p\s|--publish|ports:)/), "unit must expose no ports")
RUBY
