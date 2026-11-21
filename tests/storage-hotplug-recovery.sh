#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/scrypted-hotplug-test.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

public_key_file="$tmp_dir/id_ed25519.pub"
rendered_ignition="$tmp_dir/scrypted-nvr.ign"
printf '%s\n' 'ssh-ed25519 TEST-ONLY-KEY storage-hotplug-recovery-test' > "$public_key_file"
"$repo_dir/scripts/render-ignition" "$public_key_file" "$rendered_ignition"

unit_contents() {
  jq -er --arg name "$1" \
    '.systemd.units[] | select(.name == $name) | .contents' \
    "$rendered_ignition"
}

assert_enabled_unit() {
  jq -e --arg name "$1" \
    'any(.systemd.units[]; .name == $name and .enabled == true)' \
    "$rendered_ignition" >/dev/null || {
      echo "expected enabled unit: $1" >&2
      exit 1
    }
}

assert_line() {
  unit_name=$1
  expected_line=$2
  contents=$(unit_contents "$unit_name")
  printf '%s\n' "$contents" | grep -Fqx -- "$expected_line" || {
    echo "expected $unit_name to contain: $expected_line" >&2
    exit 1
  }
}

disk1_fsck='systemd-fsck@dev-disk-by\x2did-wwn\x2d0x5000000000000001\x2dpart1.service'
disk2_fsck='systemd-fsck@dev-disk-by\x2did-wwn\x2d0x5000000000000002\x2dpart1.service'

assert_line var-lib-scrypted-nvr.mount "Requires=$disk1_fsck"
assert_line var-lib-scrypted-nvr.mount "After=$disk1_fsck"
assert_line var-lib-scrypted-nvr2.mount "Requires=$disk2_fsck"
assert_line var-lib-scrypted-nvr2.mount "After=$disk2_fsck"

assert_line scrypted.service 'ConditionPathExists=/dev/disk/by-id/wwn-0x5000000000000001-part1'
assert_line scrypted.service 'ConditionPathExists=/dev/disk/by-id/wwn-0x5000000000000002-part1'
assert_line scrypted.service 'ConditionPathExists=!/etc/scrypted/disable-auto-recovery'
assert_line scrypted.service 'ExecStartPre=/usr/bin/mountpoint --quiet /var/lib/scrypted/nvr'
assert_line scrypted.service 'ExecStartPre=/usr/bin/mountpoint --quiet /var/lib/scrypted/nvr2'

assert_enabled_unit scrypted-recovery.timer
assert_line scrypted-recovery.timer 'OnCalendar=minutely'
assert_line scrypted-recovery.timer 'AccuracySec=1s'
assert_line scrypted-recovery.timer 'Unit=scrypted.service'
assert_line scrypted-recovery.timer 'WantedBy=timers.target'

jq -e '
  all(.systemd.units[];
    ((.contents // "") | test("(^|[[:space:]])e2fsck[[:space:]].*[[:space:]]-y([[:space:]]|$)")) | not
  )
' "$rendered_ignition" >/dev/null || {
  echo 'automatic destructive e2fsck -y must not appear in rendered units' >&2
  exit 1
}

echo 'storage hotplug recovery contract: PASS'
