#!/usr/bin/env bash
# ECN A/B Throughput Test
#
# Runs two identical chaos scenarios — one with ECN enabled, one disabled —
# and compares iperf3 throughput and congestion counter results.
#
# Usage: ./ecn-ab-test.sh [--seed N] [--duration N]

set -euo pipefail
cd "$(dirname "$0")"

EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --seed|--duration)
            EXTRA_ARGS+=("$1" "$2"); shift 2 ;;
        *)
            echo "Unknown arg: $1"; exit 1 ;;
    esac
done

echo "=== ECN A/B Throughput Test ==="
echo ""

# --- Run A: ECN ON ---
echo "--- Phase A: ECN ENABLED ---"
sudo python3 -m sim scenarios/ecn-ab-on.yaml "${EXTRA_ARGS[@]}" || true
echo ""

# --- Run B: ECN OFF ---
echo "--- Phase B: ECN DISABLED ---"
sudo python3 -m sim scenarios/ecn-ab-off.yaml "${EXTRA_ARGS[@]}" || true
echo ""

# --- Compare results ---
echo "=== Results ==="
echo ""

python3 - <<'PYEOF'
import json
import os
import sys

def load_results(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return json.load(f)

def extract_throughput(results):
    """Extract per-session throughput in Mbps from iperf3 JSON."""
    sessions = []
    for r in results:
        meta = r.get("_meta", {})
        end = r.get("end", {})
        # sum_sent / sum_received contain aggregate stats
        sent = end.get("sum_sent", {})
        recv = end.get("sum_received", {})
        sent_mbps = sent.get("bits_per_second", 0) / 1e6
        recv_mbps = recv.get("bits_per_second", 0) / 1e6
        sessions.append({
            "client": meta.get("client", "?"),
            "server": meta.get("server", "?"),
            "sent_mbps": sent_mbps,
            "recv_mbps": recv_mbps,
        })
    return sessions

def load_congestion(path):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        return json.load(f)

def print_sessions(label, sessions):
    # Filter out incomplete sessions (killed at teardown, no valid data)
    valid = [s for s in sessions if s["recv_mbps"] > 0]
    incomplete = len(sessions) - len(valid)
    if not valid:
        print(f"  {label}: no completed iperf3 sessions ({incomplete} incomplete)")
        return 0
    print(f"  {label}:")
    total_sent = 0
    total_recv = 0
    for s in valid:
        print(f"    {s['client']:>4} -> {s['server']:<4}  "
              f"sent={s['sent_mbps']:7.2f} Mbps  recv={s['recv_mbps']:7.2f} Mbps")
        total_sent += s["sent_mbps"]
        total_recv += s["recv_mbps"]
    n = len(valid)
    print(f"    {'':>14}  avg sent={total_sent/n:7.2f} Mbps  avg recv={total_recv/n:7.2f} Mbps")
    print(f"    {'':>14}  completed={n}  incomplete={incomplete}")
    return total_recv / n

on_results = load_results("sim-results/ecn-ab-on/iperf3-results.json")
off_results = load_results("sim-results/ecn-ab-off/iperf3-results.json")

on_sessions = extract_throughput(on_results)
off_sessions = extract_throughput(off_results)

print("Throughput:")
avg_on = print_sessions("ECN ON", on_sessions) or 0
print()
avg_off = print_sessions("ECN OFF", off_sessions) or 0
print()

if avg_on and avg_off:
    delta_pct = ((avg_on - avg_off) / avg_off) * 100
    print(f"  Delta: ECN ON vs OFF = {delta_pct:+.1f}% avg recv throughput")
    print()

# Congestion counters
print("Congestion Counters (final snapshot):")
for label, path in [("ECN ON", "sim-results/ecn-ab-on/congestion-snapshot-final.json"),
                     ("ECN OFF", "sim-results/ecn-ab-off/congestion-snapshot-final.json")]:
    snap = load_congestion(path)
    if not snap:
        print(f"  {label}: no snapshot")
        continue
    totals = {"ce_forwarded": 0, "ce_received": 0, "congestion_detected": 0, "kernel_drop_events": 0}
    for node_id, data in sorted(snap.items()):
        cong = data.get("congestion", {})
        for k in totals:
            totals[k] += cong.get(k, 0)
    print(f"  {label}: ce_fwd={totals['ce_forwarded']}  ce_recv={totals['ce_received']}  "
          f"cong_detect={totals['congestion_detected']}  kern_drops={totals['kernel_drop_events']}")
PYEOF
