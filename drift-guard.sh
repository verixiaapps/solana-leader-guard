#!/bin/bash
# drift-guard: alert when a watched config file changes hash unexpectedly.
# Catches accidental edits, package-managed overwrites, and config rot on
# validator boxes where a silently-changed unit file only shows up as missed
# blocks later. Run from cron every few minutes; learn a baseline first.
#
#   drift-guard.sh --learn   # snapshot current hashes as the baseline
#   drift-guard.sh           # compare against baseline, alert on drift
#
# Configure via /etc/drift-guard.env:
#   DRIFT_FILES    space-separated paths to watch
#   DRIFT_STATE    baseline store (default /etc/drift-guard.golden)
#   ALERT_URL      webhook to POST {"message":"..."} on drift
#   ALERT_KEY      optional bearer token
#   ALERT_BOX      label in alerts (default $HOSTNAME)

ENV=${DRIFT_GUARD_ENV:-/etc/drift-guard.env}
[ -f "$ENV" ] && . "$ENV"
DRIFT_FILES=${DRIFT_FILES:-/etc/systemd/system/sfdp-validator.service}
DRIFT_STATE=${DRIFT_STATE:-/etc/drift-guard.golden}
ALERT_URL=${ALERT_URL:-}
ALERT_KEY=${ALERT_KEY:-}
ALERT_BOX=${ALERT_BOX:-$HOSTNAME}

alert() {
  [ -n "$ALERT_URL" ] || return 0
  local esc
  esc=$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ' | tr -d '\r' | cut -c1-500)
  curl -s -o /dev/null --max-time 3 -X POST "$ALERT_URL" \
    -H "Content-Type: application/json" \
    ${ALERT_KEY:+-H "Authorization: Bearer $ALERT_KEY"} \
    -d "{\"message\":\"$esc\"}" &
}

if [ "${1:-}" = "--learn" ]; then
  : >"$DRIFT_STATE"
  for f in $DRIFT_FILES; do
    [ -f "$f" ] && sha256sum "$f" >>"$DRIFT_STATE"
  done
  echo "learned $(wc -l <"$DRIFT_STATE") baseline hashes -> $DRIFT_STATE"
  exit 0
fi

[ -f "$DRIFT_STATE" ] || { echo "no baseline; run --learn first" >&2; exit 1; }

drifted=""
while read -r hash path; do
  [ -n "$hash" ] || continue
  if [ ! -f "$path" ]; then
    drifted="$drifted missing:$path"
    continue
  fi
  cur=$(sha256sum "$path" | awk '{print $1}')
  [ "$cur" != "$hash" ] && drifted="$drifted changed:$path"
done <"$DRIFT_STATE"

# watched file added later but never baselined
for f in $DRIFT_FILES; do
  grep -q " $f\$" "$DRIFT_STATE" 2>/dev/null || drifted="$drifted unbaselined:$f"
done

if [ -n "$drifted" ]; then
  alert "DRIFT-GUARD $ALERT_BOX config drift:$drifted"
  echo "$(date -u +%FT%TZ) DRIFT:$drifted" >>/var/log/drift-guard.log
  exit 1
fi
exit 0
