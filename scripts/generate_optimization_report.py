#!/usr/bin/env python3
"""Generate optimization report from benchmark results."""

import json
import os
import sys


def pct(lst, p):
    return lst[int(len(lst) * p / 100)] if lst else 0


def analyze(path):
    with open(path) as f:
        data = json.load(f)
    ok = [r for r in data["requests"] if r.get("status") == "ok"]
    ttfts = sorted([r["ttft"] for r in ok if r.get("ttft")])
    itls = sorted([r["itl"] for r in ok if r.get("itl")])
    wall = data["wall_time_s"]
    tokens = sum(r.get("output_tokens", 0) for r in ok)
    return {
        "ok": len(ok), "total": len(data["requests"]),
        "throughput": tokens / wall,
        "ttft_p50": pct(ttfts, 50) * 1000, "ttft_p99": pct(ttfts, 99) * 1000,
        "itl_p50": pct(itls, 50) * 1000, "itl_p99": pct(itls, 99) * 1000,
        "tpsu": 1000 / (pct(itls, 50) * 1000) if pct(itls, 50) > 0 else 0,
    }


def main():
    results_dir = sys.argv[1] if len(sys.argv) > 1 else "results/optimization"
    sla_ttft_p99 = float(sys.argv[2]) if len(sys.argv) > 2 else 500  # ms

    conc_files = sorted([
        f for f in os.listdir(results_dir)
        if f.startswith("conc_") and f.endswith(".json")
    ], key=lambda f: int(f.split("_")[1].split(".")[0]))

    print(f"gpt-oss-20b Optimization Report")
    print(f"SLA target: TTFT P99 < {sla_ttft_p99}ms")
    print("=" * 110)
    print(f"{'Conc':>5} {'Throughput':>12} {'TTFT P50':>10} {'TTFT P99':>10} {'ITL P50':>9} {'ITL P99':>9} {'TPSU':>7} {'SLA':>6}")
    print("-" * 110)

    best_within_sla = None
    for f in conc_files:
        m = analyze(os.path.join(results_dir, f))
        conc = f.split("_")[1].split(".")[0]
        sla_ok = "OK" if m["ttft_p99"] < sla_ttft_p99 else "BREACH"
        if sla_ok == "OK" and (best_within_sla is None or m["throughput"] > best_within_sla[1]):
            best_within_sla = (conc, m["throughput"], m)
        print(f"{conc:>5} {m['throughput']:>10,.0f}t/s {m['ttft_p50']:>7.0f}ms {m['ttft_p99']:>7.0f}ms {m['itl_p50']:>6.2f}ms {m['itl_p99']:>6.2f}ms {m['tpsu']:>5.0f} {sla_ok:>6}")

    if best_within_sla:
        c, t, m = best_within_sla
        avg_out = 30
        rps = t / avg_out
        print(f"\nRECOMMENDATION: concurrency={c}")
        print(f"  Throughput: {t:,.0f} tok/s = {rps:.0f} req/s = {rps*86400/1e6:.1f}M req/day (per 16 GPUs)")
        print(f"  TTFT P99: {m['ttft_p99']:.0f}ms (within {sla_ttft_p99}ms SLA)")
        print(f"  100M req/day: ~{100e6/86400/rps*16*1.3:.0f} GPUs (with 30% buffer)")
        print(f"  200M req/day: ~{200e6/86400/rps*16*1.3:.0f} GPUs (with 30% buffer)")


if __name__ == "__main__":
    main()
