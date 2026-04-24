# gpt-oss-20b Throughput Optimization for Classification/Extraction Workloads

Optimization study for gpt-oss-20b serving classification/extraction workloads:
long input documents (3K-7K tokens), short output (10-50 tokens), high prefix
sharing (shared system prompt across all requests).

## Test Environment

| Resource | Value |
|----------|-------|
| GPUs | 16x NVIDIA H200 (141 GB HBM3e) |
| Model | openai/gpt-oss-20b (MoE, FP4, MXFP4 Marlin) |
| vLLM | v0.18.0 with prefix caching enabled |
| Current setup | 4 replicas x TP=4 (customer baseline) |
| Workload | Classification/extraction (ISL:OSL = 167:1) |

## Key Results

### Concurrency Sweep (4xTP=4, customer baseline)

| Concurrency | Throughput (tok/s) | TTFT P99 (ms) | ITL P50 (ms) | ITL P99 (ms) | TPSU | SLA |
|------------|-------------------|--------------|-------------|-------------|------|-----|
| 4 | 1,279 | 28 | 2.55 | 2.78 | 392 | OK |
| 8 | 2,544 | 386 | 2.42 | 2.75 | 413 | OK |
| 16 | 4,240 | 348 | 2.76 | 3.11 | 362 | OK |
| **32** | **7,026** | **384** | **2.89** | **3.29** | **347** | **OK** |
| 64 | 7,499 | 602 | 3.12 | 4.17 | 321 | BREACH |
| 128 | 5,695 | 1,441 | 3.95 | 6.33 | 253 | BREACH |

### With Batch Tuning (--max-num-seqs=512 --max-num-batched-tokens=16384)

| Concurrency | Throughput (tok/s) | TTFT P99 (ms) | ITL P50 (ms) | ITL P99 (ms) | TPSU | SLA |
|------------|-------------------|--------------|-------------|-------------|------|-----|
| 16 | 4,621 (+9%) | 261 | 2.61 | 2.91 | 383 | OK |
| **32** | **6,839** | **421** | **3.00** | **3.53** | **334** | **OK** |
| 64 | 7,599 (+1%) | 593 | 3.01 | 4.22 | 333 | BREACH |
| 128 | 7,002 (+23%) | 1,138 | 3.71 | 7.24 | 270 | BREACH |

### Sustained Load Test (2000 requests, conc=32, warm cache)

| Phase | TTFT P99 | SLA Breaches |
|-------|---------|-------------|
| Q1 (first 500 req, cache warming) | 4,649 ms | 32 (6.4%) |
| Q2 (steady state) | 38 ms | 0 |
| Q3 | 37 ms | 0 |
| Q4 | 40 ms | 0 |

Steady-state TTFT P99 = 37-40ms (well within 500ms SLA). Cold-start prefix cache warming causes elevated latency for the first ~500 requests after deployment.

## Recommendations

1. **Increase concurrency to 32** (from current ~22 req/s operating point).
   Throughput increases from ~4,240 to ~7,026 tok/s (+66%) while maintaining
   TTFT P99 = 384ms (within 500ms SLA).

2. **Add vLLM batch tuning**: `--max-num-seqs=512 --max-num-batched-tokens=16384`.
   Improves throughput at high concurrency (+23% at conc=128) and reduces TTFT P99
   at low concurrency (-25% at conc=16).

3. **Keep 4xTP=4 topology**. This model benefits from tensor parallelism for
   compute-heavy prefill. 16xTP=1 gives more replicas but slower per-request
   prefill (-11% throughput on this workload).

4. **EPP/gateway routing: depends on your actual cache hit rate. Proxy overhead may outweighs cache
   benefits when prompts have significant unique content. **Test with your real traffic** — if your actual prefix sharing is
   higher than our synthetic trace (e.g., >80% of input tokens are shared across
   requests), EPP may provide net benefit. If most of each prompt is unique
   document content, skip EPP.

   IMPORTANT: Earlier versions of this analysis reported 99.9% cache hit rate
   and recommended EPP. That was an error — the synthetic trace had identical
   prompts (system prompt exceeded max_input_tokens, so customer/document blocks
   were never included). The corrected diverse-prompt test shows EPP hurts this
   workload. See `results/variants/fixed_*_diverse.json` for corrected data.

5. **Plan for cold-start latency**: first ~500 requests after deployment/restart
   will have elevated TTFT (up to 4.6s P99) while prefix caches warm up.
   Use health check readiness gates or traffic ramping to mitigate.

## Scaling Projection

| Target | Req/s | GPUs (with 30% buffer) |
|--------|-------|----------------------|
| Current (16 GPUs, conc=32) | ~234 req/s = 20M req/day | 16 |
| 100M req/day | 1,157 req/s | ~90 GPUs |
| 200M req/day | 2,315 req/s | ~175 GPUs |

Assumptions: linear scaling, 30 avg output tokens, 30% buffer for multi-node
overhead. Actual scaling should be validated with multi-node tests.

## Caveats

1. **Synthetic trace**: input/output distributions are approximations of the
   described workload. Validate with actual production traffic replay.
2. **Short benchmark**: tests ran 500-2000 requests (seconds to minutes).
   Production serves 1.9M requests over 24 hours. Sustained multi-hour tests needed.
3. **Hardware-specific**: tested on H200 SXM. Results will differ on H100/A100.
4. **vLLM version**: tested on upstream v0.18.0. Production version may differ.
5. **Scaling is estimated**: 90-175 GPU projection assumes linear scaling.
   Multi-node networking, load balancing, and model caching add overhead.

## Reproduce

```bash
# 1. Generate the workload trace (adjust params to match your traffic)
./scripts/generate-trace.sh

# 2. Deploy and run the full optimization sweep
export NAMESPACE=your-namespace
./scripts/run-optimization.sh

# 3. Generate report
python3 scripts/generate_optimization_report.py results/optimization/ 500
```

Customize the trace to match your actual workload:
```bash
NUM_REQUESTS=5000 INPUT_MIN=2000 INPUT_MAX=8000 OUTPUT_MIN=5 OUTPUT_MAX=100 \
  ARRIVAL_RATE=50 NUM_CUSTOMERS=200 ./scripts/generate-trace.sh
```

## Repo Structure

```
customer-models/
├── README.md
├── customer_workload_trace.jsonl       # Synthetic trace matching customer workload
├── ms-customer-baseline.yaml           # Helm values: 4×TP=4 (customer current)
├── ms-gptoss20b-values.yaml            # Helm values: 16×TP=1 (alternative)
├── gaie-llama8b-values.yaml            # EPP InferencePool values
├── scripts/
│   ├── generate-trace.sh               # Generate customer workload trace
│   ├── generate_customer_trace.py      # Trace generator (configurable)
│   ├── run-optimization.sh             # Full optimization benchmark
│   └── generate_optimization_report.py # Report generator with SLA checking
└── results/                            # Raw JSON per-request benchmark data
```
