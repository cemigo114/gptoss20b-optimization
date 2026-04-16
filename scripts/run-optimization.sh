#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# gpt-oss-20b Optimization Benchmark
#
# Reproduces the throughput optimization study for classification/extraction
# workloads on gpt-oss-20b. Tests concurrency sweep and batch tuning to find
# the optimal operating point within TTFT P99 SLA constraints.
#
# Prerequisites:
#   - KUBECONFIG pointing to cluster with 16+ GPUs
#   - NAMESPACE set
#   - llm-d-hf-token secret in namespace
#   - Helm repos: llm-d-modelservice
#   - pip install aiohttp (for benchmark script)
#
# Usage:
#   export NAMESPACE=kpouget-dev
#   ./scripts/run-optimization.sh
##############################################################################

NAMESPACE="${NAMESPACE:-kpouget-dev}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RESULTS="$ROOT/results/optimization"
TRACE="$ROOT/customer_workload_trace.jsonl"
BENCH="$SCRIPT_DIR/../../llm-d-tuning-mooncake/benchmarks/scripts/benchmark_stage.py"

mkdir -p "$RESULTS"

# Generate trace if not present
if [ ! -f "$TRACE" ]; then
  echo "Generating customer workload trace..."
  python3 "$SCRIPT_DIR/generate_customer_trace.py" --output "$TRACE"
fi

echo "============================================================"
echo "  gpt-oss-20b Optimization — Classification/Extraction"
echo "  Cluster: $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')"
echo "  GPUs: $(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{" "}{end}')"
echo "============================================================"

# Deploy 4×TP=4 (customer baseline)
echo ""
echo "[1/4] Deploying customer baseline: 4×TP=4..."
helm install ms-customer llm-d-modelservice/llm-d-modelservice \
  -n "$NAMESPACE" -f "$ROOT/ms-customer-baseline.yaml" 2>/dev/null || \
  helm upgrade ms-customer llm-d-modelservice/llm-d-modelservice \
  -n "$NAMESPACE" -f "$ROOT/ms-customer-baseline.yaml"

kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: customer-direct
spec:
  selector:
    llm-d.ai/inference-serving: "true"
    llm-d.ai/guide: "customer-models"
  ports:
  - port: 8000
    targetPort: 8000
EOF

kubectl wait --for=condition=Ready pod -l 'llm-d.ai/guide=customer-models' \
  -n "$NAMESPACE" --timeout=600s

# Create in-cluster bench runner
echo ""
echo "[2/4] Setting up benchmark runner..."
kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: bench-runner
spec:
  restartPolicy: Never
  containers:
  - name: bench
    image: python:3.12-slim
    command: ["sleep", "86400"]
    volumeMounts:
    - name: data
      mountPath: /bench
  volumes:
  - name: data
    emptyDir: {}
EOF

kubectl wait --for=condition=Ready pod/bench-runner -n "$NAMESPACE" --timeout=120s
kubectl exec bench-runner -n "$NAMESPACE" -- pip install -q aiohttp
kubectl exec bench-runner -n "$NAMESPACE" -- mkdir -p /bench/results
kubectl cp "$BENCH" "$NAMESPACE/bench-runner:/bench/benchmark_stage.py"
kubectl cp "$TRACE" "$NAMESPACE/bench-runner:/bench/customer_trace.jsonl"

ENDPOINT="http://customer-direct.${NAMESPACE}.svc.cluster.local:8000"

# Concurrency sweep
echo ""
echo "[3/4] Concurrency sweep (4, 8, 16, 32, 64, 128)..."
for conc in 4 8 16 32 64 128; do
  echo "  Concurrency: $conc"
  kubectl exec bench-runner -n "$NAMESPACE" -- python3 /bench/benchmark_stage.py \
    --trace /bench/customer_trace.jsonl \
    --endpoint "$ENDPOINT" \
    --model openai/gpt-oss-20b \
    --stage "conc-${conc}" \
    --rate-scale 0.00001 --max-requests 500 --max-concurrency "$conc" --max-input-tokens 3500 \
    --output "/bench/results/conc_${conc}.json" 2>&1 | grep -E "Throughput|TTFT.*P99|ITL.*P50|TPSU"
done

# Sustained test at conc=32
echo ""
echo "[4/4] Sustained load test (2000 req, conc=32, with warmup)..."
kubectl exec bench-runner -n "$NAMESPACE" -- python3 /bench/benchmark_stage.py \
  --trace /bench/customer_trace.jsonl --endpoint "$ENDPOINT" --model openai/gpt-oss-20b \
  --stage warmup --rate-scale 0.0001 --max-requests 200 --max-concurrency 32 --max-input-tokens 3500 \
  --output /bench/results/warmup.json 2>&1 | grep "Results:"

kubectl exec bench-runner -n "$NAMESPACE" -- python3 /bench/benchmark_stage.py \
  --trace /bench/customer_trace.jsonl --endpoint "$ENDPOINT" --model openai/gpt-oss-20b \
  --stage "sustained-conc32" --rate-scale 0.0005 --max-requests 2000 --max-concurrency 32 --max-input-tokens 3500 \
  --output /bench/results/sustained_conc32.json 2>&1 | tail -7

# Copy results
echo ""
echo "Copying results..."
for f in $(kubectl exec bench-runner -n "$NAMESPACE" -- ls /bench/results/ | grep -v warmup); do
  kubectl cp "$NAMESPACE/bench-runner:/bench/results/$f" "$RESULTS/$f" 2>/dev/null
done

kubectl delete pod bench-runner -n "$NAMESPACE"

echo ""
echo "============================================================"
echo "  Results saved to: $RESULTS/"
echo "  Generate report: python3 scripts/generate_optimization_report.py $RESULTS/"
echo "============================================================"
