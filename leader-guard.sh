#!/bin/bash
# leader-guard: 1-second tick. Before each leader window, max the validator's
# IO/CPU priority and choke competing disk users; after the window, verify
# blocks were produced — on a confirmed miss, log loudly and fire the webhook.
#
# Designed for shared boxes where other services (databases, containers,
# a second validator) can steal IO/CPU during your leader slots and turn a
# replay stall into missed blocks. All tunables are env vars with sane defaults.

VALIDATOR_UNIT=${LEADER_GUARD_VALIDATOR_UNIT:-sfdp-validator.service}
VALIDATOR_PROC=${LEADER_GUARD_VALIDATOR_PROC:-agave-validator}
IDENT=${LEADER_GUARD_IDENT:?set LEADER_GUARD_IDENT to your vote/identity pubkey}
RPC=${LEADER_GUARD_RPC:-http://localhost:8899}
LOG=${LEADER_GUARD_LOG:-/var/log/leader-guard.log}
STATE=${LEADER_GUARD_STATE:-/run/leader-guard.prev}
MISS_CONFIRM_STATE=${LEADER_GUARD_MISS_CONFIRM_STATE:-/run/leader-guard.miss-confirm}
PARK_STATE=${LEADER_GUARD_PARK_STATE:-/run/leader-guard.parked-units}
RESTORE_STATE=${LEADER_GUARD_RESTORE_STATE:-/run/leader-guard.restore-units}
PARK_ACTIVE=${LEADER_GUARD_PARK_ACTIVE:-/run/leader-guard.parked-active}
PARK_FORMAT=${LEADER_GUARD_PARK_FORMAT:-/run/leader-guard.parked-units.v2}
RESTORING_STATE=${LEADER_GUARD_RESTORING_STATE:-/run/leader-guard.restoring}

# Units stopped entirely during a leader window, then restored afterwards.
CONFLICT_UNITS=${LEADER_GUARD_CONFLICT_UNITS:-""}
# Units kept running but IO-choked during the window (cgroup io.max — ionice
# is a no-op under the 'none' scheduler on fast NVMe).
CHOKE_UNITS=${LEADER_GUARD_CHOKE_UNITS:-""}
# Docker containers to choke at scope level (docker.service itself untouched).
CHOKE_CONTAINERS=${LEADER_GUARD_CHOKE_CONTAINERS:-""}
BOOST_SLOTS=${LEADER_GUARD_BOOST_SLOTS:-6000}
CHOKE_SLOTS=${LEADER_GUARD_CHOKE_SLOTS:-150}
# Epoch-boundary protection: stake/reward-certificate churn at each epoch
# rollover leaves replay a few slots behind; the deficit surfaces at the
# first leader window as ReplayIsBehind. Hold boost + choke through the
# first N slots of each epoch.
EPOCH_PROTECT_SLOTS=${LEADER_GUARD_EPOCH_PROTECT_SLOTS:-3000}
CHOKE_DEV=${LEADER_GUARD_CHOKE_DEV:-/dev/nvme0n1}
CHOKE_RMAX=${LEADER_GUARD_CHOKE_RMAX:-15M}
CHOKE_WMAX=${LEADER_GUARD_CHOKE_WMAX:-6M}
RPC_MAX=${LEADER_GUARD_RPC_MAX:-0.2}
PUB_RPC_MAX=${LEADER_GUARD_PUB_RPC_MAX:-3}
MISS_CONFIRM_SECONDS=${LEADER_GUARD_MISS_CONFIRM_SECONDS:-30}
# Block production is unavailable on stripped/local RPC builds — read the
# official feed for monitoring only, after our leader slots only.
PUB_RPC=${LEADER_GUARD_PUB_RPC:-https://api.testnet.solana.com}
# Generic outbound alert: POST {"message": "..."} to a webhook you control.
ALERT_URL=${LEADER_GUARD_ALERT_URL:-}
ALERT_KEY=${LEADER_GUARD_ALERT_KEY:-}
ALERT_BOX=${LEADER_GUARD_ALERT_BOX:-validator}

mkdir -p /run
touch "$LOG"

log() { echo "$(date -u +%FT%TZ) $*" >>"$LOG"; }

alert() {
  local text="$1" esc
  [ -n "$ALERT_URL" ] || return 0
  esc=$(printf '%s' "$text" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ' | tr -d '\r' | cut -c1-500)
  curl -s -o /dev/null --max-time 3 -X POST "$ALERT_URL" \
    -H "Content-Type: application/json" \
    ${ALERT_KEY:+-H "Authorization: Bearer $ALERT_KEY"} \
    -d "{\"message\":\"$esc\"}" &
}

tick_sleep() {
  local t1 el rem
  t1=$(date +%s%N); el=$(( (t1-T0)/1000000 )); rem=$((1000-el))
  [ "$rem" -gt 0 ] && sleep "$(echo "$rem" | awk '{printf "%.3f", $1/1000}')" || true
}

park_conflicts() {
  # PARK_ACTIVE marks an active park. PARK_STATE lists every unit watchdogs
  # must leave alone; RESTORE_STATE is the exact set that may be started when
  # the window ends. PARK_FORMAT marks PARK_STATE as suppression-list format
  # rather than a legacy restore list.
  if [ ! -e "$PARK_ACTIVE" ]; then
    if [ -e "$RESTORE_STATE" ]; then
      : >"$PARK_ACTIVE"
    elif [ -e "$PARK_STATE" ] && [ ! -e "$PARK_FORMAT" ]; then
      cp "$PARK_STATE" "$RESTORE_STATE"
      : >"$PARK_ACTIVE"
    else
      : >"$RESTORE_STATE"
      for u in $CONFLICT_UNITS; do
        if systemctl is-active --quiet "$u" 2>/dev/null; then
          echo "$u" >>"$RESTORE_STATE"
        fi
      done
      : >"$PARK_ACTIVE"
    fi
  elif [ ! -e "$RESTORE_STATE" ]; then
    : >"$RESTORE_STATE"
    log "PARK: restore state missing; leaving all conflicting units off"
  fi
  printf '%s\n' $CONFLICT_UNITS >"$PARK_STATE"
  : >"$PARK_FORMAT"
  for u in $CONFLICT_UNITS; do
    if systemctl is-active --quiet "$u" 2>/dev/null; then
      systemctl stop "$u" 2>/dev/null || true
      log "PARK: stopped competing unit $u"
    fi
  done
}

restore_conflicts() {
  if [ ! -e "$PARK_ACTIVE" ] && [ -e "$PARK_STATE" ] && [ -e "$PARK_FORMAT" ]; then
    local residual tmp
    tmp=$(mktemp /run/leader-guard.residual.XXXXXX)
    : >"$tmp"
    while read -r residual; do
      [ -n "$residual" ] || continue
      systemctl is-active --quiet "$residual" 2>/dev/null || echo "$residual" >>"$tmp"
    done <"$PARK_STATE"
    if [ -s "$tmp" ]; then
      mv "$tmp" "$PARK_STATE"
    else
      rm -f "$tmp" "$PARK_STATE" "$PARK_FORMAT"
    fi
  fi
  if [ ! -e "$PARK_ACTIVE" ]; then
    if [ -e "$PARK_STATE" ] && [ ! -e "$PARK_FORMAT" ] && [ ! -e "$RESTORE_STATE" ]; then
      cp "$PARK_STATE" "$RESTORE_STATE"
    elif [ ! -e "$RESTORE_STATE" ]; then
      return 0
    fi
  fi
  local keep_off restore_ok
  keep_off=$(mktemp /run/leader-guard.keep-off.XXXXXX)
  restore_ok=$(mktemp /run/leader-guard.restore-ok.XXXXXX)
  : >"$keep_off"
  : >"$restore_ok"
  for u in $CONFLICT_UNITS; do
    if ! grep -qxF "$u" "$RESTORE_STATE" 2>/dev/null; then
      echo "$u" >>"$keep_off"
    fi
  done
  if [ -e "$RESTORE_STATE" ]; then
    while read -r u; do
      [ -n "$u" ] || continue
      if systemctl start "$u" 2>/dev/null; then
        echo "$u" >>"$restore_ok"
      else
        log "RESTORE FAIL: $u"
      fi
    done <"$RESTORE_STATE"
  fi
  if [ -s "$keep_off" ]; then
    mv "$keep_off" "$PARK_STATE"
    : >"$PARK_FORMAT"
  else
    rm -f "$keep_off" "$PARK_STATE" "$PARK_FORMAT"
  fi
  if [ -s "$restore_ok" ]; then mv "$restore_ok" "$RESTORING_STATE"; else rm -f "$restore_ok" "$RESTORING_STATE"; fi
  rm -f "$RESTORE_STATE" "$PARK_ACTIVE"
  log "RESTORE: competing units returned to their prior running state"
}

if [ "${1:-}" = "--test-park-restore" ]; then
  cleanup_test() {
    for u in $CONFLICT_UNITS; do
      if [ -f "$EXPECTED" ] && grep -qxF "$u" "$EXPECTED"; then
        systemctl start "$u" 2>/dev/null || true
      else
        systemctl stop "$u" 2>/dev/null || true
      fi
    done
    rm -f "$EXPECTED" "$PARK_STATE" "$RESTORE_STATE" "$PARK_ACTIVE" "$PARK_FORMAT" "$RESTORING_STATE"
  }
  PARK_STATE=$(mktemp /run/leader-guard.test-park.XXXXXX)
  RESTORE_STATE=$(mktemp /run/leader-guard.test-restore.XXXXXX)
  PARK_ACTIVE=$(mktemp /run/leader-guard.test-active.XXXXXX)
  PARK_FORMAT=$(mktemp /run/leader-guard.test-format.XXXXXX)
  RESTORING_STATE=$(mktemp /run/leader-guard.test-restoring.XXXXXX)
  EXPECTED=$(mktemp)
  rm -f "$PARK_STATE" "$RESTORE_STATE" "$PARK_ACTIVE" "$PARK_FORMAT" "$RESTORING_STATE"
  trap cleanup_test EXIT
  for u in $CONFLICT_UNITS; do
    systemctl is-active --quiet "$u" 2>/dev/null && echo "$u" >>"$EXPECTED"
  done
  park_conflicts
  for u in $CONFLICT_UNITS; do
    systemctl is-active --quiet "$u" 2>/dev/null && {
      echo "FAIL: $u still active after park"; cleanup_test; exit 1; }
  done
  restore_conflicts
  for u in $CONFLICT_UNITS; do
    if grep -qxF "$u" "$EXPECTED"; then
      systemctl is-active --quiet "$u" 2>/dev/null || {
        echo "FAIL: $u did not return active after restore"; cleanup_test; exit 1; }
      grep -qxF "$u" "$PARK_STATE" && {
        echo "FAIL: restored unit $u still marked parked"; cleanup_test; exit 1; }
    else
      systemctl is-active --quiet "$u" 2>/dev/null && {
        echo "FAIL: $u was restored despite being inactive before park"; cleanup_test; exit 1; }
      grep -qxF "$u" "$PARK_STATE" || {
        echo "FAIL: previously inactive unit $u lost park suppression"; cleanup_test; exit 1; }
    fi
  done
  if [ -f "$PARK_STATE" ]; then
    while read -r u; do
      [ -n "$u" ] || continue
      systemctl start "$u" 2>/dev/null || true
    done <"$PARK_STATE"
    restore_conflicts
    for u in $CONFLICT_UNITS; do
      if ! grep -qxF "$u" "$EXPECTED" && grep -qxF "$u" "$PARK_STATE" 2>/dev/null; then
        echo "FAIL: manually started unit $u stayed suppression-listed"; cleanup_test; exit 1
      fi
    done
  fi
  cleanup_test
  trap - EXIT
  echo "PASS: stop-and-restore self-heal"
  exit 0
fi

if [ "${1:-}" = "--test-alert" ]; then
  alert "LEADER-GUARD $ALERT_BOX WIRE-TEST — direct miss-alert delivery verified"
  wait
  exit 0
fi

choke_shared_disk() {
  # $1=read cap $2=write cap on CHOKE_DEV for every live unit plus each
  # container scope (docker.service itself is never touched).
  local r="$1" w="$2" u cid
  for u in $CHOKE_UNITS; do
    systemctl is-active --quiet "$u" 2>/dev/null || continue
    systemctl set-property --runtime "$u" IOWeight=1 "IOReadBandwidthMax=$CHOKE_DEV $r" "IOWriteBandwidthMax=$CHOKE_DEV $w" 2>/dev/null
  done
  for u in $CHOKE_CONTAINERS; do
    cid=$(docker inspect -f "{{.Id}}" "$u" 2>/dev/null) || continue
    [ -n "$cid" ] && systemctl set-property --runtime "docker-$cid.scope" IOWeight=1 "IOReadBandwidthMax=$CHOKE_DEV $r" "IOWriteBandwidthMax=$CHOKE_DEV $w" 2>/dev/null
  done
}
# Baseline io.max/IOWeight per unit — matches each unit's drop-in.
# set-property --runtime is used instead of `systemctl revert`: revert
# DELETES hand-written drop-in files under /etc/systemd/system/<unit>.service.d/,
# so restore is explicit, per-unit. Format "unit:readmax:writemax".
CHOKE_BASE=${LEADER_GUARD_CHOKE_BASE:-""}
unchoke_shared_disk() {
  local u r w spec cid
  for spec in $CHOKE_BASE; do
    u=${spec%%:*}; spec=${spec#*:}; r=${spec%%:*}; w=${spec#*:}
    systemctl is-active --quiet "$u" 2>/dev/null || continue
    systemctl set-property --runtime "$u" IOWeight=30 "IOReadBandwidthMax=$CHOKE_DEV $r" "IOWriteBandwidthMax=$CHOKE_DEV $w" 2>/dev/null
  done
  for u in $CHOKE_CONTAINERS; do
    cid=$(docker inspect -f "{{.Id}}" "$u" 2>/dev/null) || continue
    [ -n "$cid" ] && systemctl set-property --runtime "docker-$cid.scope" IOWeight=100 "IOReadBandwidthMax=$CHOKE_DEV infinity" "IOWriteBandwidthMax=$CHOKE_DEV infinity" 2>/dev/null
  done
}

# Startup sweep: if the previous run died mid-choke the caps it set would
# persist silently. Always start from an un-choked baseline.
unchoke_shared_disk
HOT=0
CHOKED=0
LAST_BP_CHECK=0
while :; do
  T0=$(date +%s%N)
  EP=$(curl -s --max-time "$RPC_MAX" "$RPC" -X POST -H "Content-Type: application/json" -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getEpochInfo\"}")
  CUR=$(echo "$EP" | python3 -c "import json,sys;d=json.load(sys.stdin)[\"result\"];print(d[\"slotIndex\"])" 2>/dev/null)
  [ -z "$CUR" ] && { tick_sleep; continue; }
  SCHED=$(curl -s --max-time "$RPC_MAX" "$RPC" -X POST -H "Content-Type: application/json" -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getLeaderSchedule\",\"params\":[null,{\"identity\":\"$IDENT\"}]}" | python3 -c "import json,sys;print(\" \".join(map(str,json.load(sys.stdin)[\"result\"][\"$IDENT\"])))" 2>/dev/null)
  NEXT=""
  PREV=""
  for s in $SCHED; do
    if [ "$s" -gt "$CUR" ]; then NEXT=$s; break; fi
    PREV=$s
  done
  pid=$(pgrep -f "$VALIDATOR_PROC" | head -1)
  if [ "$CUR" -lt "$EPOCH_PROTECT_SLOTS" ] || { [ -n "$NEXT" ] && [ $((NEXT - CUR)) -le "$BOOST_SLOTS" ]; }; then
    [ "$HOT" = 0 ] && echo "$(date -u +%FT%TZ) ENTER boost zone next=$NEXT cur=$CUR" >>"$LOG"
    HOT=1
    park_conflicts
    [ -n "$pid" ] && ionice -c1 -n0 -p "$pid" 2>/dev/null && renice -n -20 -p "$pid" >/dev/null 2>&1
    systemctl set-property "$VALIDATOR_UNIT" CPUWeight=10000 IOWeight=10000 2>/dev/null
  else
    if [ "$HOT" = 1 ]; then
      echo "$(date -u +%FT%TZ) EXIT boost zone cur=$CUR" >>"$LOG"
      HOT=0
    fi
    [ ! -f /run/leader-guard.heal ] && restore_conflicts
    [ -n "$pid" ] && ionice -c2 -n0 -p "$pid" 2>/dev/null
    systemctl set-property "$VALIDATOR_UNIT" CPUWeight=3000 IOWeight=3000 2>/dev/null
  fi
  # Precision choke: only CHOKE_SLOTS (~35s) around the window — boost is ~85%
  # of the epoch so a zone-wide cap would starve the other services; the disk
  # only needs to be quiet for the seconds replay+creation actually run.
  if [ "$CUR" -lt "$EPOCH_PROTECT_SLOTS" ] || { [ -n "$NEXT" ] && [ $((NEXT - CUR)) -le "$CHOKE_SLOTS" ]; }; then
    if [ "$CHOKED" = 0 ]; then
      choke_shared_disk "$CHOKE_RMAX" "$CHOKE_WMAX"
      echo "$(date -u +%FT%TZ) CHOKE window $NEXT-$((NEXT+3)) cur=$CUR caps=${CHOKE_RMAX}/${CHOKE_WMAX}" >>"$LOG"
      CHOKED=1
    fi
  elif [ "$CHOKED" = 1 ]; then
    unchoke_shared_disk
    CHOKED=0
    echo "$(date -u +%FT%TZ) UNCHOKE cur=$CUR" >>"$LOG"
  fi
  # Production accounting is deliberately slower than the 1s resource guard:
  # polling the public endpoint every second caused its own 429 responses.
  # Only query after one of our leader slots so the official feed stays out
  # of the validator path.
  NOW_BP=$(date +%s)
  if [ -n "$PREV" ] && [ $((CUR - PREV)) -le 450 ] && \
     [ $((NOW_BP - LAST_BP_CHECK)) -ge 10 ]; then
    LAST_BP_CHECK=$NOW_BP
    BP=$(curl -s --max-time "$PUB_RPC_MAX" "$PUB_RPC" \
      -X POST -H "Content-Type: application/json" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getBlockProduction\",\"params\":[{\"identity\":\"$IDENT\"}]}" |
      python3 -c "import json,sys;d=json.load(sys.stdin)[\"result\"][\"value\"][\"byIdentity\"][\"$IDENT\"];print(d[0],d[1])" 2>/dev/null)
    if [ -n "$BP" ]; then
      read -r ASG PRD <<<"$BP"
      PREV=$(cat "$STATE" 2>/dev/null || echo "$ASG $PRD")
      read -r PASG PPRD <<<"$PREV"
      MISSED=$((ASG - PRD))
      PREV_MISSED=$((PASG - PPRD))
      # Epoch rollover: byIdentity counters reset each epoch, so ASG shrinks.
      # Reset the miss baseline to 0 — otherwise early misses in the new
      # epoch hide under the previous epoch's total and never alert.
      if [ "$ASG" -lt "$PASG" ] 2>/dev/null; then
        PREV_MISSED=0
        rm -f "$MISS_CONFIRM_STATE"
      fi
      if [ "$MISSED" -gt "$PREV_MISSED" ] 2>/dev/null; then
        NEW_MISSES=$((MISSED - PREV_MISSED))
        NOW=$(date +%s)
        CANDIDATE_MISSED=""
        CANDIDATE_SINCE=""
        [ -f "$MISS_CONFIRM_STATE" ] &&
          read -r CANDIDATE_MISSED CANDIDATE_SINCE <"$MISS_CONFIRM_STATE"
        if [ "$CANDIDATE_MISSED" = "$MISSED" ] &&
           [ $((NOW - CANDIDATE_SINCE)) -ge "$MISS_CONFIRM_SECONDS" ] 2>/dev/null; then
          MSG="LEADER-GUARD $ALERT_BOX SKIP — confirmed missed count increased by $NEW_MISSES (assigned=$ASG produced=$PRD total_missed=$MISSED)"
          echo "$(date -u +%FT%TZ) MISS: $MSG idx~$CUR" >>"$LOG"
          alert "$MSG"
          rm -f "$MISS_CONFIRM_STATE"
          echo "$ASG $PRD" >"$STATE"
        elif [ "$CANDIDATE_MISSED" != "$MISSED" ]; then
          echo "$MISSED $NOW" >"$MISS_CONFIRM_STATE"
          echo "$(date -u +%FT%TZ) MISS candidate total=$MISSED; awaiting ${MISS_CONFIRM_SECONDS}s stable confirmation" >>"$LOG"
        fi
      else
        rm -f "$MISS_CONFIRM_STATE"
        echo "$ASG $PRD" >"$STATE"
      fi
    fi
  fi
  tick_sleep
done
