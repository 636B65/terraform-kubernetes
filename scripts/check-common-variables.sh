#!/usr/bin/env bash
# Checks that the common variables (everything in variables.tf before the last
# "# ---" banner, which starts the platform's own variables) are identical in
# every platform directory. They are copies of each other by design.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
platforms=(proxmox vcenter esxi workstation libvirt virtualbox)

common() { # common <file>: print the file up to its last banner
  awk '{ line[NR] = $0 } /^# -{75}$/ { banner[++n] = NR }
       END { stop = (n >= 2 ? banner[n - 1] : NR + 1); for (i = 1; i < stop; i++) print line[i] }' "$1"
}

status=0
for platform in "${platforms[@]:1}"; do
  if ! diff -u --label "${platforms[0]}/variables.tf" --label "$platform/variables.tf" \
      <(common "${platforms[0]}/variables.tf") <(common "$platform/variables.tf"); then
    status=1
  fi
done
if [[ "$status" == 0 ]]; then
  echo "Common variables are identical in: ${platforms[*]}"
else
  echo "The common variables differ (see above). Keep them identical in every platform." >&2
fi
exit "$status"
