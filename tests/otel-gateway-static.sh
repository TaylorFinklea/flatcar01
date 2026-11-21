#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
config_dir="$repo_dir/config/observability"
fixture_dir="$repo_dir/tests/fixtures/observability"

fail() {
	echo "OTel gateway contract: $1" >&2
	exit 1
}

require_file() {
	[ -f "$1" ] || fail "missing $1"
}

for required_file in \
	"$config_dir/otel-gateway.yaml" \
	"$config_dir/otel-gateway-systemd.yaml" \
	"$config_dir/bin/run-otel-collector" \
	"$config_dir/systemd/otel-collector.service" \
	"$config_dir/systemd/otelcol-queue-prepare.service" \
	"$config_dir/systemd/var-lib-otelcol.mount" \
	"$fixture_dir/homelab-metrics.json" \
	"$fixture_dir/homelab-traces.json" \
	"$fixture_dir/ai-metrics.json" \
	"$fixture_dir/ai-traces.json" \
	"$fixture_dir/ai-logs.json"
do
	require_file "$required_file"
done

ruby -rjson -ryaml - "$repo_dir" <<'RUBY'
repo = ARGV.fetch(0)
config_dir = File.join(repo, "config/observability")
fixture_dir = File.join(repo, "tests/fixtures/observability")

def assert!(condition, message)
  raise "OTel gateway contract: #{message}" unless condition
end

def yaml(path)
  YAML.safe_load(File.read(path), aliases: false)
rescue Psych::Exception => error
  raise "OTel gateway contract: invalid YAML #{path}: #{error.message}"
end

def deep_copy(value)
  Marshal.load(Marshal.dump(value))
end

def processor_conditions(processors, name, signal)
  processor = processors.fetch(name)
  assert!(processor.fetch("error_mode") == "propagate", "#{name} must fail closed")
  processor.fetch("#{signal}_conditions").join("\n")
end

def transform_statements(processors, name, signal)
  processors.fetch(name).fetch("#{signal}_statements").flat_map { |group| group.fetch("statements") }
end

def contains_all_statements?(processors, name, signal, required)
  statements = transform_statements(processors, name, signal)
  required.all? { |statement| statements.include?(statement) }
end

def pipeline_contract?(gateway, name, expected)
  pipeline = gateway.fetch("service").fetch("pipelines").fetch(name)
  pipeline.fetch("processors") == expected[0, expected.length - 1] && pipeline.fetch("exporters") == [expected.fetch(-1)]
end

baseline = yaml(File.join(config_dir, "otel-gateway.yaml"))
systemd = yaml(File.join(config_dir, "otel-gateway-systemd.yaml"))

[baseline, systemd].each do |gateway|
  assert!(gateway.is_a?(Hash), "gateway root must be a mapping")
  assert!(gateway.fetch("service").fetch("pipelines").keys.sort == ["metrics/ai", "metrics/docker", "metrics/homelab", "metrics/host", "metrics/self", "traces/ai"], "gateway must expose exactly the approved metrics and AI-traces pipelines")
  assert!(!gateway.fetch("service").fetch("pipelines").keys.any? { |name| name.include?("logs") }, "logs pipeline is forbidden")
  assert!(!gateway.fetch("exporters").keys.any? { |name| name.include?("log") }, "logs exporter is forbidden")
  assert!(!gateway.fetch("receivers").keys.any? { |name| name.include?("log") }, "logs receiver is forbidden")

  telemetry = gateway.fetch("service").fetch("telemetry").fetch("metrics")
  assert!(telemetry.fetch("level") == "detailed", "collector self metrics must be detailed")
  pull = telemetry.fetch("readers").fetch(0).fetch("pull").fetch("exporter").fetch("prometheus")
  assert!(pull == {"host" => "127.0.0.1", "port" => 8888, "without_scope_info" => true, "without_type_suffix" => true, "without_units" => true, "with_resource_constant_labels" => {"included" => []}}, "collector self metrics must bind only to loopback with no constant resource labels")

  receivers = gateway.fetch("receivers")
  {
    "otlp/homelab" => "127.0.0.1:4318",
    "otlp/ai" => "127.0.0.1:4319",
    "otlp/docker" => "127.0.0.1:4320",
  }.each do |name, endpoint|
    protocols = receivers.fetch(name).fetch("protocols")
    assert!(protocols.keys == ["http"], "#{name} must expose OTLP/HTTP only")
    assert!(protocols.fetch("http") == {"endpoint" => endpoint}, "#{name} must bind #{endpoint}")
  end
  scrape = receivers.fetch("prometheus/self").fetch("config").fetch("scrape_configs")
  assert!(scrape == [{"job_name" => "otel-collector", "scrape_interval" => "30s", "static_configs" => [{"targets" => ["127.0.0.1:8888"]}]}], "self scrape must target only loopback collector metrics")

  hostmetrics = receivers.fetch("hostmetrics")
  assert!(hostmetrics.fetch("collection_interval") == "30s", "host collection interval must be bounded")
  scrapers = hostmetrics.fetch("scrapers")
  assert!(scrapers.keys.sort == ["cpu", "load", "memory", "network"], "host receiver must not enable filesystem, disk, process, or other scrapers")
  assert!(scrapers.fetch("cpu").fetch("metrics").fetch("system.cpu.utilization") == {"enabled" => true}, "host CPU utilization must be enabled")
  assert!(scrapers.fetch("cpu").fetch("metrics").fetch("system.cpu.logical.count") == {"enabled" => true}, "host CPU logical count must be enabled")
  assert!(scrapers.fetch("memory").fetch("metrics").fetch("system.memory.usage") == {"enabled" => true}, "host memory usage must be enabled")
  assert!(scrapers.fetch("network").fetch("metrics").fetch("system.network.io") == {"enabled" => true}, "host network I/O must be enabled")

  extensions = gateway.fetch("extensions")
  queue_budgets = {
    "host_metrics" => [50_331_648, 41_943_040],
    "homelab_metrics" => [33_554_432, 25_165_824],
    "docker_metrics" => [41_943_040, 33_554_432],
    "ai_metrics" => [33_554_432, 25_165_824],
    "ai_traces" => [41_943_040, 33_554_432],
  }
  assert!(extensions.keys.sort == queue_budgets.keys.map { |name| "file_storage/#{name}" }.sort, "exactly five independent file-storage extensions are required")
  queue_budgets.each do |name, (max_size, queue_size)|
    extension = extensions.fetch("file_storage/#{name}")
    assert!(extension == {"directory" => "/var/lib/otelcol/queue/#{name}", "create_directory" => true, "directory_permissions" => "0750", "max_size" => max_size}, "#{name} file storage must have the approved bounded directory and size")
  end
  assert!(gateway.fetch("service").fetch("extensions").sort == extensions.keys.sort, "all and only queue extensions must be enabled")

  exporters = gateway.fetch("exporters")
  assert!(exporters.keys.sort == queue_budgets.keys.map { |name| "otlp_http/#{name}" }.sort, "exactly five independent OTLP/HTTP exporters are required")
  queue_budgets.each do |name, (_max_size, queue_size)|
    exporter = exporters.fetch("otlp_http/#{name}")
    expected_endpoint_key = name == "ai_traces" ? "traces_endpoint" : "metrics_endpoint"
    expected_endpoint = "http://127.0.0.1:5080/api/default/v1/#{name == "ai_traces" ? "traces" : "metrics"}"
    assert!(exporter.fetch(expected_endpoint_key) == expected_endpoint, "#{name} must use its explicit loopback OpenObserve #{expected_endpoint_key}")
    assert!(!exporter.key?(name == "ai_traces" ? "metrics_endpoint" : "traces_endpoint"), "#{name} may not export the wrong signal")
    assert!(exporter.fetch("headers") == {"Authorization" => "${env:OPENOBSERVE_INGEST_AUTH_HEADER}"}, "#{name} must use the complete collector authorization header environment reference")
    assert!(exporter.fetch("retry_on_failure").fetch("max_elapsed_time") == 0, "#{name} retry must not silently expire")
    queue = exporter.fetch("sending_queue")
    assert!(queue == {"enabled" => true, "storage" => "file_storage/#{name}", "sizer" => "bytes", "queue_size" => queue_size, "block_on_overflow" => false}, "#{name} queue must be byte-sized, persistent, and nonblocking without exporter batching")
  end

  processors = gateway.fetch("processors")
  assert!(processors.fetch("memory_limiter") == {"check_interval" => "1s", "limit_mib" => 384, "spike_limit_mib" => 64}, "memory limiter must reserve the approved 384 MiB plus 64 MiB spike budget")
  assert!(processors.fetch("batch/metrics") == {"send_batch_size" => 512, "send_batch_max_size" => 512, "timeout" => "5s"}, "metrics batch must be bounded")
  assert!(processors.fetch("batch/traces") == {"send_batch_size" => 128, "send_batch_max_size" => 128, "timeout" => "5s"}, "trace batch must be bounded")
  assert!(processors.fetch("groupbyattrs/rebuild_resource") == {"keys" => ["telemetry.private.resource.rebuild"]}, "resource rebuilding must use one fixed private grouping key")
  rebuild = processors.fetch("transform/mark_resource_rebuild")
  assert!(rebuild.fetch("error_mode") == "propagate", "resource rebuild marker must fail closed")
  assert!(transform_statements(processors, "transform/mark_resource_rebuild", "metric") == ['set(datapoint.attributes["telemetry.private.resource.rebuild"], true)'], "every metric datapoint must be marked for resource rebuilding")
  assert!(transform_statements(processors, "transform/mark_resource_rebuild", "trace") == ['set(span.attributes["telemetry.private.resource.rebuild"], true)'], "every AI span must be marked for resource rebuilding")

  expected_pipelines = {
    "metrics/host" => ["memory_limiter", "filter/drop_unapproved_host_metrics", "transform/mark_resource_rebuild", "groupbyattrs/rebuild_resource", "transform/normalize_host_metrics", "batch/metrics", "otlp_http/host_metrics"],
    "metrics/homelab" => ["memory_limiter", "filter/drop_unapproved_homelab_metrics", "transform/mark_resource_rebuild", "groupbyattrs/rebuild_resource", "transform/normalize_homelab_metrics", "batch/metrics", "otlp_http/homelab_metrics"],
    "metrics/docker" => ["memory_limiter", "filter/drop_unapproved_docker_metrics", "transform/mark_resource_rebuild", "groupbyattrs/rebuild_resource", "transform/normalize_docker_metrics", "batch/metrics", "otlp_http/docker_metrics"],
    "metrics/ai" => ["memory_limiter", "filter/drop_unapproved_ai_metrics", "transform/mark_resource_rebuild", "groupbyattrs/rebuild_resource", "transform/normalize_ai_metrics", "batch/metrics", "otlp_http/ai_metrics"],
    "metrics/self" => ["memory_limiter", "filter/drop_unapproved_self_metrics", "transform/mark_resource_rebuild", "groupbyattrs/rebuild_resource", "transform/normalize_self_metrics", "batch/metrics", "otlp_http/host_metrics"],
    "traces/ai" => ["memory_limiter", "filter/drop_unapproved_ai_traces", "transform/mark_resource_rebuild", "groupbyattrs/rebuild_resource", "transform/normalize_ai_traces", "batch/traces", "otlp_http/ai_traces"],
  }
  expected_pipelines.each do |name, expected|
    pipeline = gateway.fetch("service").fetch("pipelines").fetch(name)
    assert!(pipeline.fetch("processors") == expected[0, 6], "#{name} must limit memory, reject unknown values, rebuild its resource, normalize, then batch")
    assert!(pipeline.fetch("exporters") == [expected.fetch(6)], "#{name} must export only after its sanitizer and batch")
    assert!(pipeline.fetch("processors").first == "memory_limiter", "#{name} must limit memory before telemetry handling")
  end

  host_metrics = %w[system.cpu.logical.count system.cpu.time system.cpu.utilization system.cpu.load_average.1m system.cpu.load_average.5m system.cpu.load_average.15m system.memory.usage system.network.io systemd.unit.state]
  homelab_metrics = host_metrics - ["systemd.unit.state"]
  storage_metrics = %w[homelab.storage.mount.valid homelab.filesystem.capacity.bytes homelab.filesystem.used.bytes homelab.filesystem.available.bytes homelab.disk.read.bytes homelab.disk.write.bytes homelab.disk.read.operations homelab.disk.write.operations]
  homelab_metrics += storage_metrics
  docker_metrics = %w[container.cpu.usage.total container.cpu.utilization container.memory.usage.total container.memory.usage.limit container.network.io.usage.rx_bytes container.network.io.usage.tx_bytes container.blockio.io_service_bytes_recursive]
  ai_metrics = %w[ai.run.count ai.run.duration ai.tokens.input ai.tokens.output ai.cost]
  self_metrics = %w[otelcol_receiver_accepted_metric_points otelcol_receiver_refused_metric_points otelcol_exporter_sent_metric_points otelcol_exporter_send_failed_metric_points otelcol_exporter_enqueue_failed_metric_points otelcol_exporter_queue_size otelcol_exporter_queue_capacity]
  {
    "filter/drop_unapproved_host_metrics" => ["metric", host_metrics],
    "filter/drop_unapproved_homelab_metrics" => ["metric", homelab_metrics],
    "filter/drop_unapproved_docker_metrics" => ["metric", docker_metrics],
    "filter/drop_unapproved_ai_metrics" => ["metric", ai_metrics],
    "filter/drop_unapproved_self_metrics" => ["metric", self_metrics],
  }.each do |name, (signal, metrics)|
    conditions = processor_conditions(processors, name, signal)
    metrics.each { |metric| assert!(conditions.include?(%Q{metric.name != "#{metric}"}), "#{name} must reject unknown metric names outside the v0.159.0 allowlist") }
  end

  host_statements = processors.fetch("transform/normalize_host_metrics").fetch("metric_statements").flat_map { |group| group.fetch("statements") }
  [
    'set(resource.attributes["host.name"], "scrypted-nvr")',
    'set(datapoint.attributes["network.interface"], "lan") where metric.name == "system.network.io" and datapoint.attributes["device"] == "enp0s31f6"',
    'set(datapoint.attributes["network.direction"], datapoint.attributes["direction"]) where metric.name == "system.network.io"',
    'keep_keys(resource.attributes, ["host.name", "systemd.unit.name", "telemetry.synthetic"])',
    'keep_keys(datapoint.attributes, ["state", "network.interface", "network.direction"])',
  ].each { |statement| assert!(host_statements.include?(statement), "host normalization must contain #{statement}") }

  metric_envelope_privacy = [
    'set(resource.schema_url, "")',
    'set(resource.dropped_attributes_count, 0)',
    'set(scope.name, "")',
    'set(scope.version, "")',
    'set(scope.schema_url, "")',
    'set(scope.dropped_attributes_count, 0)',
    'delete_matching_keys(scope.attributes, ".*")',
    'set(metric.description, "")',
    'set(metric.unit, "")',
    'delete_matching_keys(metric.metadata, ".*")',
    'set(datapoint.flags, 0)',
    'set(datapoint.exemplars, nil)',
  ]
  %w[transform/normalize_host_metrics transform/normalize_homelab_metrics transform/normalize_docker_metrics transform/normalize_ai_metrics transform/normalize_self_metrics].each do |name|
    assert!(contains_all_statements?(processors, name, "metric", metric_envelope_privacy), "#{name} must clear every noncontract metric, resource, scope, and exemplar carrier")
  end
  host_conditions = processor_conditions(processors, "filter/drop_unapproved_host_metrics", "metric")
  [
    'IsMatch(datapoint.attributes["state"], "^(idle|user|system|nice|iowait|irq|softirq|steal|guest|guest_nice)$") == false',
    'IsMatch(datapoint.attributes["state"], "^(used|free|cached|buffers)$") == false',
    'datapoint.attributes["direction"] != "receive" and datapoint.attributes["direction"] != "transmit"',
    'IsMatch(datapoint.attributes["state"], "^(active|activating|deactivating|inactive|failed)$") == false',
  ].each { |value_guard| assert!(host_conditions.include?(value_guard), "host filter must reject unapproved dimension values: #{value_guard}") }
  homelab_conditions = processor_conditions(processors, "filter/drop_unapproved_homelab_metrics", "metric")
  storage_metrics.each { |metric| assert!(homelab_conditions.include?(%Q{metric.name != "#{metric}"}), "homelab filter must allow fixed storage metric #{metric}") }
  ["os", "nvr_primary", "nvr_secondary"].each { |role| assert!(homelab_conditions.include?(%Q{datapoint.attributes["storage.role"] != "#{role}"}), "homelab storage filter must reject unknown role #{role}") }
  homelab_statements = processors.fetch("transform/normalize_homelab_metrics").fetch("metric_statements").flat_map { |group| group.fetch("statements") }
  storage_names = storage_metrics.map { |metric| %Q{metric.name == "#{metric}"} }.join(" or ")
  assert!(homelab_statements.include?(%Q{keep_keys(datapoint.attributes, ["storage.role"]) where #{storage_names}}), "homelab storage normalization must retain only storage.role")
  assert!(homelab_statements.include?(%Q{keep_keys(datapoint.attributes, ["state", "network.interface", "network.direction"]) where not (#{storage_names})}), "homelab non-storage normalization must retain only its own dimensions")
  [
    'IsMatch(datapoint.attributes["state"], "^(idle|user|system|nice|iowait|irq|softirq|steal|guest|guest_nice)$") == false',
    'IsMatch(datapoint.attributes["state"], "^(used|free|cached|buffers)$") == false',
    'datapoint.attributes["direction"] != "receive" and datapoint.attributes["direction"] != "transmit"',
  ].each { |value_guard| assert!(homelab_conditions.include?(value_guard), "homelab filter must reject unapproved dimension values: #{value_guard}") }
  docker_statements = processors.fetch("transform/normalize_docker_metrics").fetch("metric_statements").flat_map { |group| group.fetch("statements") }
  [
    'set(resource.attributes["host.name"], "scrypted-nvr")',
    'keep_keys(resource.attributes, ["host.name", "container.name", "telemetry.synthetic"])',
    'keep_keys(datapoint.attributes, ["operation"])',
  ].each { |statement| assert!(docker_statements.include?(statement), "Docker normalization must contain #{statement}") }
  docker_conditions = processor_conditions(processors, "filter/drop_unapproved_docker_metrics", "metric")
  assert!(docker_conditions.include?('metric.name == "container.blockio.io_service_bytes_recursive" and datapoint.attributes["operation"] != "read" and datapoint.attributes["operation"] != "write"'), "Docker filter must allow only read/write block-I/O operations")

  ai_metric_conditions = processor_conditions(processors, "filter/drop_unapproved_ai_metrics", "metric")
  %w[ai.tool ai.harness ai.role ai.provider ai.model ai.lane ai.operation ai.status ai.error.class ai.instrumentation.version ai.currency ai.run.id ai.task.id].each do |key|
    assert!(ai_metric_conditions.include?(%Q{datapoint.attributes["#{key}"]}), "AI metric filter must validate #{key}")
  end
  ai_metric_statements = processors.fetch("transform/normalize_ai_metrics").fetch("metric_statements").flat_map { |group| group.fetch("statements") }
  assert!(ai_metric_statements.include?('keep_keys(resource.attributes, ["host.name", "telemetry.synthetic"])'), "AI metric resources must be allowlisted")
  assert!(ai_metric_statements.include?('keep_keys(datapoint.attributes, ["ai.tool", "ai.harness", "ai.role", "ai.provider", "ai.model", "ai.lane", "ai.operation", "ai.status", "ai.error.class", "ai.instrumentation.version", "ai.currency", "ai.run.id", "ai.task.id"])'), "AI metric attributes must be allowlisted")

  trace_conditions = processor_conditions(processors, "filter/drop_unapproved_ai_traces", "trace")
  %w[run tool inference].each { |operation| assert!(trace_conditions.include?(%Q{span.attributes["ai.operation"] != "#{operation}"}), "AI trace filter must drop unapproved operation #{operation}") }
  %w[ai.tool ai.harness ai.role ai.provider ai.model ai.lane ai.operation ai.status ai.error.class ai.instrumentation.version ai.currency ai.run.id ai.task.id].each do |key|
    assert!(trace_conditions.include?(%Q{span.attributes["#{key}"]}), "AI trace filter must validate #{key}")
  end
  trace_statements = transform_statements(processors, "transform/normalize_ai_traces", "trace")
  default_span_index = trace_statements.index('set(span.name, "ai.other")')
  assert!(!default_span_index.nil?, "AI traces require an unconditional ai.other default")
  [
    'set(span.name, "ai.run") where span.attributes["ai.operation"] == "run"',
    'set(span.name, "ai.tool") where span.attributes["ai.operation"] == "tool"',
    'set(span.name, "ai.inference") where span.attributes["ai.operation"] == "inference"',
  ].each do |statement|
    index = trace_statements.index(statement)
    assert!(!index.nil? && default_span_index < index, "AI trace mapping #{statement} must follow ai.other")
  end
  [
    'set(resource.schema_url, "")',
    'set(resource.dropped_attributes_count, 0)',
    'set(scope.name, "")',
    'set(scope.version, "")',
    'set(scope.schema_url, "")',
    'set(scope.dropped_attributes_count, 0)',
    'set(span.events, nil)',
    'set(span.links, nil)',
    'set(span.trace_state, "")',
    'set(span.kind, 0)',
    'set(span.flags, 0)',
    'set(span.dropped_attributes_count, 0)',
    'set(span.dropped_events_count, 0)',
    'set(span.dropped_links_count, 0)',
    'set(span.status.code, 0)',
    'set(span.status.message, "")',
    'keep_keys(resource.attributes, ["host.name", "telemetry.synthetic"])',
    'delete_matching_keys(scope.attributes, ".*")',
    'keep_keys(span.attributes, ["ai.tool", "ai.harness", "ai.role", "ai.provider", "ai.model", "ai.lane", "ai.operation", "ai.status", "ai.error.class", "ai.instrumentation.version", "ai.currency", "ai.run.id", "ai.task.id"])',
  ].each { |statement| assert!(trace_statements.include?(statement), "AI trace privacy normalization must contain #{statement}") }
  assert!(!trace_statements.include?('set(span.events, [])'), "AI trace privacy normalization must not assign an untyped event slice")
  assert!(!trace_statements.include?('set(span.links, [])'), "AI trace privacy normalization must not assign an untyped link slice")
  assert!(!trace_statements.include?('delete_index(span.events, 0, Len(span.events))'), "AI trace privacy normalization must not apply pcommon slice deletion to typed events")
  assert!(!trace_statements.include?('delete_index(span.links, 0, Len(span.links))'), "AI trace privacy normalization must not apply pcommon slice deletion to typed links")

  mutated_processors = deep_copy(processors)
  mutated_processors.fetch("transform/normalize_ai_metrics").fetch("metric_statements").last.fetch("statements").delete('set(datapoint.exemplars, nil)')
  assert!(!contains_all_statements?(mutated_processors, "transform/normalize_ai_metrics", "metric", metric_envelope_privacy), "static privacy mutation must be rejected when exemplar clearing is removed")
  mutated_processors = deep_copy(processors)
  mutated_processors.fetch("transform/normalize_ai_metrics").fetch("metric_statements").find { |group| group.fetch("context") == "metric" }.fetch("statements").delete('delete_matching_keys(metric.metadata, ".*")')
  assert!(!contains_all_statements?(mutated_processors, "transform/normalize_ai_metrics", "metric", metric_envelope_privacy), "static privacy mutation must be rejected when metric metadata clearing is removed")
  mutated_gateway = deep_copy(gateway)
  mutated_gateway.fetch("service").fetch("pipelines").fetch("metrics/ai").fetch("processors").delete("groupbyattrs/rebuild_resource")
  assert!(!pipeline_contract?(mutated_gateway, "metrics/ai", expected_pipelines.fetch("metrics/ai")), "static privacy mutation must be rejected when resource rebuilding is removed")
end

normalized_systemd = deep_copy(systemd)
normalized_systemd.fetch("receivers").delete("systemd")
normalized_systemd.fetch("service").fetch("pipelines").fetch("metrics/host").fetch("receivers").delete("systemd")
assert!(baseline == normalized_systemd, "gateway variants may differ only by the reviewed systemd receiver and host pipeline receiver list")
systemd_receiver = systemd.fetch("receivers").fetch("systemd")
assert!(systemd_receiver == {"collection_interval" => "30s", "scope" => "system", "units" => ["openobserve.service", "observe-proxy.service", "otel-collector.service", "otel-docker-agent.service"]}, "systemd variant must scrape only approved observability units")
assert!(systemd.fetch("service").fetch("pipelines").fetch("metrics/host").fetch("receivers") == ["hostmetrics", "systemd"], "systemd receiver must only join the host metrics pipeline")

fixture_names = %w[homelab-metrics homelab-traces ai-metrics ai-traces ai-logs]
fixture_names.each do |name|
  fixture = JSON.parse(File.read(File.join(fixture_dir, "#{name}.json")))
  canaries = fixture.fetch("canaries")
  input_json = JSON.generate(fixture.fetch("input"))
  expected_json = JSON.generate(fixture.fetch("expected"))
  assert!(!canaries.empty?, "#{name} fixture must contain privacy canaries")
  canaries.each do |canary|
    assert!(input_json.include?(canary), "#{name} fixture must place canary #{canary} in incoming telemetry")
    assert!(!expected_json.include?(canary), "#{name} fixture expected output may not retain canary #{canary}")
  end
  assert!(fixture.fetch("expected").fetch("dropped_records").is_a?(Array), "#{name} fixture must document rejected records")
end
homelab_record = JSON.parse(File.read(File.join(fixture_dir, "homelab-metrics.json"))).fetch("expected").fetch("records").fetch(0)
assert!(homelab_record.fetch("name") == "system.cpu.utilization" && homelab_record.fetch("attributes") == {"state" => "user"}, "homelab fixture must retain only an approved host metric and state")
assert!(JSON.parse(File.read(File.join(fixture_dir, "ai-metrics.json"))).fetch("expected").fetch("records").map { |record| record.fetch("name") }.sort == %w[ai.cost ai.run.count ai.run.duration ai.tokens.input ai.tokens.output], "AI metrics fixture must retain exactly approved metadata metrics")
ai_trace_record = JSON.parse(File.read(File.join(fixture_dir, "ai-traces.json"))).fetch("expected").fetch("records").fetch(0)
assert!(ai_trace_record.fetch("name") == "ai.run" && ai_trace_record.fetch("events") == [] && ai_trace_record.fetch("links") == [] && ai_trace_record.fetch("trace_state") == "" && ai_trace_record.fetch("status_message") == "", "AI trace fixture must prove metadata-only normalization")
assert!(JSON.parse(File.read(File.join(fixture_dir, "ai-logs.json"))).fetch("expected").fetch("records") == [], "AI logs fixture must prove logs are rejected")

runner = File.read(File.join(config_dir, "bin/run-otel-collector"))
assert!(runner.include?('--feature-gates=+ottl.set.allowNil'), "Collector launch wrapper must enable typed-nil OTTL setters for trace privacy")
unit = File.read(File.join(config_dir, "systemd/otel-collector.service"))
queue_prepare = File.read(File.join(config_dir, "systemd/otelcol-queue-prepare.service"))
mount_unit = File.read(File.join(config_dir, "systemd/var-lib-otelcol.mount"))

assert!(runner.start_with?("#!/bin/sh\nset -eu\n"), "collector runner must be a strict POSIX shell program")
assert!(runner.include?("marker_path=/etc/observability/systemd-metrics-approved"), "runner must use the fixed root-owned approval marker")
assert!(runner.include?("marker_mode=0:0:644"), "runner must require the documented root-owned 0644 marker mode")
assert!(runner.include?("config_file=/etc/observability/otel-gateway-systemd.yaml") && runner.include?("config_file=/etc/observability/otel-gateway.yaml"), "runner must select exactly the approved gateway variants")
assert!(runner.include?("source=/run/dbus/system_bus_socket,target=/run/dbus/system_bus_socket,readonly"), "runner must have the gated system bus mount")
assert!(runner.include?("if [ -e \"$marker_path\" ] || [ -L \"$marker_path\" ]; then"), "runner must inspect present and dangling marker paths")
marker_validation = 'if [ ! -f "$marker_path" ] || [ -L "$marker_path" ] || [ "$(/usr/bin/stat -c "%u:%g:%a" "$marker_path")" != "$marker_mode" ]; then'
assert!(runner.include?(marker_validation), "runner must reject a non-regular, symlinked, non-root-owned, or writable marker")
marker_guard_index = runner.index(marker_validation)
marker_abort_index = runner.index("exit 1", marker_guard_index)
systemd_config_index = runner.index("config_file=/etc/observability/otel-gateway-systemd.yaml")
assert!(!marker_abort_index.nil? && marker_abort_index < systemd_config_index, "invalid marker presence must abort before the systemd gateway is selected")
assert!(runner.include?("if [ \"$systemd_metrics_approved\" = true ]; then"), "runner must mount D-Bus only after marker validation succeeds")
assert!(runner.include?("--env GOMEMLIMIT=384MiB"), "runner must set the collector Go memory limit")
assert!(runner.include?("--user 10001:10001") && runner.include?("--memory=512m") && runner.include?("--cpus=1.0") && runner.include?("--read-only") && runner.include?("--cap-drop=ALL") && runner.include?("--security-opt no-new-privileges") && runner.include?("--network host") && runner.include?("--pull=never"), "runner must launch the hardened collector container")
%w[/proc/stat /proc/meminfo /proc/loadavg /proc/uptime].each do |source|
  assert!(runner.include?("source=#{source},target=#{source},readonly"), "runner must mount only required host numeric source #{source}")
end
assert!(!runner.include?("source=/proc/net/dev,target=/proc/net/dev,readonly"), "runner must rely on host networking for network interface counters instead of mounting /proc/net/dev")
assert!(runner.scan(%r{--mount\s+type=bind,source=/}).length == 6, "runner must contain four numeric host binds, the queue, and the gated system bus")
assert!(runner.include?("--mount type=bind,source=\"$config_file\",target=/etc/otelcol/config.yaml,readonly"), "runner baseline must bind exactly the selected tracked configuration")
%w[/var/lib/scrypted /proc,/ /sys,/ source=/dev docker.sock --privileged --cap-add --device --publish --volume].each do |forbidden|
  assert!(!runner.include?(forbidden), "runner must not expose #{forbidden}")
end

[
  "ConditionPathExists=/etc/observability/images.env",
  "ConditionPathExists=/etc/observability/otel-gateway.yaml",
  "ConditionPathExists=/etc/observability/otel-gateway-systemd.yaml",
  "ConditionPathExists=/etc/observability/secrets/otel-collector.env",
  "Requires=docker.service var-lib-otelcol.mount",
  "After=docker.service var-lib-otelcol.mount",
  "ExecStart=/etc/observability/bin/run-otel-collector",
  "Restart=on-failure",
].each { |line| assert!(unit.lines.map(&:strip).include?(line), "collector unit must contain #{line}") }
assert!(unit.include?("/usr/bin/stat -c \"%%u:%%g:%%a\" /etc/observability/secrets/otel-collector.env") && unit.include?("0:0:600"), "collector secret file must be root-owned mode 0600")
queue_prepare_line = "ExecStartPre=/usr/bin/install -d -m 0750 -o 10001 -g 10001 /var/lib/otelcol/queue"
queue_verify_line = 'ExecStartPre=/bin/sh -ec \'test "$(/usr/bin/stat -c "%%u:%%g:%%a" /var/lib/otelcol/queue)" = "10001:10001:750"\''
assert!(unit.lines.map(&:strip).include?(queue_prepare_line), "collector service must create only the queue directory after its mount dependency")
assert!(unit.lines.map(&:strip).include?(queue_verify_line), "collector service must verify exact queue ownership and mode before Docker starts")
assert!(unit.index(queue_prepare_line) < unit.index("ExecStart=/etc/observability/bin/run-otel-collector") && unit.index(queue_verify_line) < unit.index("ExecStart=/etc/observability/bin/run-otel-collector"), "queue preparation and verification must run before Docker")
assert!(!unit.match?(/scrypted|nvr|watchtower/i), "collector unit must not depend on Scrypted or NVR units")

[
  "ConditionPathExists=!/var/lib/otelcol-queue.img",
  "ExecStart=/usr/bin/install -d -m 0750 -o 0 -g 0 /var/lib/otelcol",
  'ExecStart=/bin/sh -ec \'test "$(/usr/bin/stat -c "%%u:%%g:%%a" /var/lib/otelcol)" = "0:0:750"\'',
  "ExecStart=/usr/bin/truncate --size=268435456 /var/lib/otelcol-queue.img",
  "ExecStart=/usr/sbin/mkfs.ext4 -F /var/lib/otelcol-queue.img",
].each { |line| assert!(queue_prepare.lines.map(&:strip).include?(line), "queue prepare unit must contain #{line}") }
assert!(!queue_prepare.lines.any? { |line| line.start_with?("ExecStart=") && line.match?(/\b(dev|lsblk|blkid|mount|umount|fdisk)\b/i) }, "queue prepare unit must never inspect or mount a block device")
assert!(!queue_prepare.lines.any? { |line| line.start_with?("ExecStart=") && line.match?(%r{\b(install|chmod|chown)\b.*(?:^|\s)/var/lib(?:\s|$)}) }, "queue prepare unit must never mutate the broad /var/lib directory")
[
  "What=/var/lib/otelcol-queue.img",
  "Where=/var/lib/otelcol",
  "Type=ext4",
  "Options=loop,nodev,nosuid,noexec,noatime",
  "Requires=otelcol-queue-prepare.service",
  "After=otelcol-queue-prepare.service",
  "Before=otel-collector.service",
].each { |line| assert!(mount_unit.lines.map(&:strip).include?(line), "queue mount unit must contain #{line}") }
assert!(!mount_unit.match?(/scrypted|nvr|watchtower/i), "queue mount unit must not reference Scrypted or NVR")

puts "OTel gateway contract: PASS"
RUBY
