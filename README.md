# solana-leader-guard

Production guard machinery for Solana validators that share a box with other
workloads — the tooling we run to keep a testnet validator near-zero missed
blocks on a host that also earns elsewhere.

The failure mode it prevents: other services (databases, containers, a second
validator, CI jobs) steal IO/CPU during your 4-slot leader windows. Replay
falls a few slots behind, `ReplayIsBehind` shows up in the log, and the
window's blocks never get built. The guard makes the disk and CPU quiet for
exactly the seconds replay+creation run — nothing else changes.

## What it does

- **Leader-window awareness** — reads `getLeaderSchedule` from the local RPC
  every tick; knows your next window to the slot.
- **Boost zone** — ~`BOOST_SLOTS` before each window: validator gets
  `CPUWeight=10000 IOWeight=10000`, `ionice -c1`, `renice -20`.
- **Precision choke** — ~`CHOKE_SLOTS` around the window only: competing
  units get cgroup `IOReadBandwidthMax`/`IOWriteBandwidthMax` caps on the
  shared device. The rest of the epoch they run at their baseline, so
  co-located earners aren't starved. (cgroup io.max, not ionice — ionice is a
  no-op under the `none` scheduler on fast NVMe.)
- **Park/restore** — units that must not run at all during the window are
  stopped, then restored to exactly their prior state afterwards (including
  units that were already off — suppression list, not a blanket restart).
- **Epoch-boundary protection** — stake/reward-certificate churn at each
  epoch rollover leaves replay behind; boost+choke is held through the first
  `EPOCH_PROTECT_SLOTS` of every epoch.
- **Production accounting** — after each leader slot, `getBlockProduction`
  is read once (from the official cluster feed, never hammering your own
  RPC). A miss has to persist `MISS_CONFIRM_SECONDS` before it alerts —
  blocks indexed late don't page you. Counters reset correctly at epoch
  rollover.
- **Outbound alert** — a confirmed miss POSTs `{"message": "..."}` to any
  webhook you point it at.

## drift-guard

`drift-guard.sh` — cron job that hashes your watched config files
(validator unit, env files) against a learned baseline and alerts on any
change. Catches the silent drift that shows up later as missed blocks.

```
drift-guard.sh --learn    # snapshot baseline
# then in cron: drift-guard.sh
```

## Install

```bash
sudo install -m755 leader-guard.sh /usr/local/bin/
sudo install -m644 leader-guard.service /etc/systemd/system/
sudo install -m600 alert-target.env.example /etc/leader-guard.env
$EDITOR /etc/leader-guard.env      # set IDENT, units, alert webhook
sudo systemctl daemon-reload
sudo systemctl enable --now leader-guard
```

Self-test the park/restore path without touching production:

```bash
LEADER_GUARD_CONFLICT_UNITS="some-noncritical.service" \
  /usr/local/bin/leader-guard.sh --test-park-restore
```

## Design rules baked in

- Never restarts the validator — the guard only moves resources and
  competitors, it doesn't touch the process.
- Alert only on *confirmed* misses; late-indexed blocks are not alerts.
- Every cap is restored explicitly — `systemctl revert` deletes hand-written
  drop-ins, so baseline restore is per-unit `set-property`.
- Nothing goes on the ledger disk path beyond what the validator itself needs.

MIT licensed. Built by [HostDeFi](https://hostdefi.com) — a Solana DEX and
free token-safety scanner — for our own fleet; published because the failure
mode is generic.
