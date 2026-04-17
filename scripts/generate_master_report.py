#!/usr/bin/env python3
"""Generate master report across all models."""
import json, os, sys

def pct(lst, p):
    return lst[int(len(lst)*p/100)] if lst else 0

def analyze(path):
    with open(path) as f:
        data = json.load(f)
    ok = [r for r in data.get("requests", []) if r.get("status")=="ok"]
    if not ok: return None
    ttfts = sorted([r["ttft"] for r in ok if r.get("ttft")])
    itls = sorted([r["itl"] for r in ok if r.get("itl")])
    wall = data.get("wall_time_s", 1)
    tokens = sum(r.get("output_tokens",0) for r in ok)
    return {
        "ok": len(ok), "total": len(data.get("requests",[])),
        "throughput": tokens/wall,
        "ttft_p50": pct(ttfts,50)*1000 if ttfts else 0,
        "ttft_p99": pct(ttfts,99)*1000 if ttfts else 0,
        "itl_p50": pct(itls,50)*1000 if itls else 0,
        "itl_p99": pct(itls,99)*1000 if itls else 0,
        "tpsu": 1000/(pct(itls,50)*1000) if itls and pct(itls,50)>0 else 0,
    }

def main():
    base = sys.argv[1] if len(sys.argv)>1 else "results"
    sla = float(sys.argv[2]) if len(sys.argv)>2 else 500

    print("MULTI-MODEL BENCHMARK REPORT")
    print(f"SLA target: TTFT P99 < {sla}ms")
    print("=" * 140)
    print(f"{'Model':<45} {'Best Conc':>9} {'Throughput':>12} {'TTFT P50':>10} {'TTFT P99':>10} {'ITL P50':>9} {'ITL P99':>9} {'TPSU':>7}")
    print("-" * 140)

    for model_dir in sorted(os.listdir(base)):
        model_path = os.path.join(base, model_dir)
        if not os.path.isdir(model_path): continue

        best = None
        for f in sorted(os.listdir(model_path)):
            if not f.endswith(".json") or "values" in f: continue
            m = analyze(os.path.join(model_path, f))
            if m and m["ttft_p99"] <= sla and (best is None or m["throughput"] > best["throughput"]):
                best = m
                best["conc"] = f.split("conc_")[1].split(".")[0] if "conc_" in f else "?"

        if best:
            print(f"{model_dir:<45} {best['conc']:>9} {best['throughput']:>10,.0f}t/s {best['ttft_p50']:>7.0f}ms {best['ttft_p99']:>7.0f}ms {best['itl_p50']:>6.2f}ms {best['itl_p99']:>6.2f}ms {best['tpsu']:>5.0f}")
        else:
            # Show best available even if SLA breached
            best_any = None
            for f in sorted(os.listdir(model_path)):
                if not f.endswith(".json") or "values" in f: continue
                m = analyze(os.path.join(model_path, f))
                if m and (best_any is None or m["throughput"] > best_any["throughput"]):
                    best_any = m
                    best_any["conc"] = f.split("conc_")[1].split(".")[0] if "conc_" in f else "?"
            if best_any:
                print(f"{model_dir:<45} {best_any['conc']:>9} {best_any['throughput']:>10,.0f}t/s {best_any['ttft_p50']:>7.0f}ms {best_any['ttft_p99']:>7.0f}ms {best_any['itl_p50']:>6.2f}ms {best_any['itl_p99']:>6.2f}ms {best_any['tpsu']:>5.0f} *SLA BREACH*")
            else:
                print(f"{model_dir:<45} {'NO DATA':>9}")

if __name__ == "__main__":
    main()
