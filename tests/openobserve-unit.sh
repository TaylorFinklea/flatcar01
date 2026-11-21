#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
unit_file="$repo_dir/config/observability/systemd/openobserve.service"

fail() {
	echo "OpenObserve unit contract: $1" >&2
	exit 1
}

[ -f "$unit_file" ] || fail "missing $unit_file"

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

exec_start_count=$(printf '%s\n' "$normalized_unit" | awk '/^ExecStart=/{count++} END{print count + 0}')
[ "$exec_start_count" -eq 1 ] || fail 'expected exactly one ExecStart directive'
exec_start=$(printf '%s\n' "$normalized_unit" | awk '/^ExecStart=/{sub(/^ExecStart=/, ""); print}')

assert_line 'ConditionPathExists=/etc/observability/images.env'
assert_line 'ConditionPathExists=/etc/observability/openobserve.env'
assert_line 'ConditionPathExists=/etc/observability/secrets/openobserve.env'
assert_line 'EnvironmentFile=/etc/observability/images.env'
assert_line 'Restart=on-failure'
assert_line 'ExecStartPre=/usr/bin/install -d -m 0750 -o 20001 -g 20001 /var/lib/openobserve'
assert_line 'ExecStartPre=/bin/sh -ec '\''test "$(/usr/bin/stat -c "%%u:%%g:%%a" /var/lib/openobserve)" = "20001:20001:750"'\'''
assert_line 'ExecStartPre=/bin/sh -ec '\''test "$(/usr/bin/stat -c "%%u:%%g:%%a" /etc/observability/secrets/openobserve.env)" = "0:0:600"'\'''
assert_line 'ExecStartPre=-/usr/bin/docker rm --force openobserve'

assert_exec_arg '/usr/bin/docker run'
assert_exec_arg '--name openobserve'
assert_exec_arg '--pull=never'
assert_exec_arg '--network host'
assert_exec_arg '--user 20001:20001'
assert_exec_arg '--read-only'
assert_exec_arg '--cap-drop=ALL'
assert_exec_arg '--security-opt no-new-privileges'
assert_exec_arg '--memory=3g'
assert_exec_arg '--cpus=2.0'
assert_exec_arg '--pids-limit=512'
assert_exec_arg '--env-file /etc/observability/openobserve.env'
assert_exec_arg '--env-file /etc/observability/secrets/openobserve.env'
assert_exec_arg '--mount type=bind,source=/var/lib/openobserve,target=/data'
assert_exec_arg '--tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m,uid=20001,gid=20001,mode=0700'

case "$exec_start" in
*' ${OPENOBSERVE_IMAGE}') ;;
*) fail 'ExecStart must end with ${OPENOBSERVE_IMAGE}' ;;
esac

mount_count=$(printf '%s\n' "$exec_start" | awk '{count = gsub(/--mount[[:space:]]+/, "&"); print count}')
[ "$mount_count" -eq 1 ] || fail 'OpenObserve must have exactly one bind mount'

if printf '%s\n' "$normalized_unit" | grep -Eq 'docker[[:space:]]+pull'; then
	fail 'unit must not pull images'
fi

if printf '%s\n' "$normalized_unit" | grep -Eq '^EnvironmentFile=/etc/observability/(openobserve|secrets/)'; then
	fail 'runtime secrets and application settings must only enter through Docker --env-file'
fi

if printf '%s\n' "$exec_start" | grep -Eq '(^|[[:space:]])(--publish(=|[[:space:]])|--publish-all([[:space:]]|$)|-p([^[:space:]]|[[:space:]])|-P([[:space:]]|$))'; then
	fail 'unit must not publish a container port'
fi

case "$normalized_unit" in
*watchtower* | *Watchtower*) fail 'unit must not join Watchtower management' ;;
esac

case "$normalized_unit" in
*'/var/lib/scrypted'* | *'scrypted.service'* | *'scrypted-watchtower.service'* | *'scrypted-recovery.timer'* | *'var-lib-scrypted-nvr'*)
	fail 'unit must not reference Scrypted storage or units'
	;;
esac

case "$normalized_unit" in
*'docker.io/'* | *'ghcr.io/'* | *'openobserve/openobserve:'*) fail 'unit must use the pinned image variable, not a literal image' ;;
esac

if printf '%s\n' "$exec_start" | grep -Eq '(^|[[:space:]])(--volume(=|[[:space:]])|--volumes-from(=|[[:space:]])|--use-api-socket([[:space:]]|$)|-v([^[:space:]]|[[:space:]]))'; then
	fail 'unit must not add an unreviewed volume bind'
fi

docker_rm_count=$(printf '%s\n' "$normalized_unit" | awk '/docker[[:space:]]+rm[[:space:]]/{count++} END{print count + 0}')
[ "$docker_rm_count" -eq 1 ] || fail 'expected exactly one old-container removal'

printf '%s\n' "$normalized_unit" | awk '
  /docker[[:space:]]+rm[[:space:]]/ && !/^ExecStartPre=/ { exit 1 }
' || fail 'old-container removal is only allowed in ExecStartPre'

echo 'OpenObserve unit contract: PASS'
