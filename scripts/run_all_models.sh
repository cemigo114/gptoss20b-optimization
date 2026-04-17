#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# Run the full benchmark pipeline for all models
# Deploys each model, runs concurrency sweep, collects results, tears down
#
# Usage:
#   export NAMESPACE=kpouget-dev
#   ./scripts/run_all_models.sh
##############################################################################

NAMESPACE="${NAMESPACE:-kpouget-dev}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
LOG="$ROOT/run_all.log"

echo "Starting multi-model benchmark at $(date)" | tee "$LOG"
echo "Namespace: $NAMESPACE" | tee -a "$LOG"

# Ensure bench-runner exists with tools
echo "Setting up bench runner..." | tee -a "$LOG"
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
    emptyDir:
      sizeLimit: 2Gi
EOF

kubectl wait --for=condition=Ready pod/bench-runner -n "$NAMESPACE" --timeout=120s
kubectl exec bench-runner -n "$NAMESPACE" -- pip install -q aiohttp 2>&1 | tail -1
kubectl exec bench-runner -n "$NAMESPACE" -- mkdir -p /bench/results

# Copy benchmark script and trace
kubectl cp "$ROOT/../llm-d-tuning-mooncake/benchmarks/scripts/benchmark_stage.py" \
  "$NAMESPACE/bench-runner:/bench/benchmark_stage.py" 2>/dev/null || \
kubectl cp "$SCRIPT_DIR/../estimator/../scripts/../benchmarks/scripts/benchmark_stage.py" \
  "$NAMESPACE/bench-runner:/bench/benchmark_stage.py" 2>/dev/null || true

# Generate a general-purpose trace (moderate sharing, classification-style)
kubectl exec bench-runner -n "$NAMESPACE" -- python3 -c "
import json, random
rng = random.Random(42)
reqs = []
ts = 0
for i in range(1000):
    if i > 0: ts += int(rng.expovariate(22) * 1000)
    cust = rng.randint(0, 49)
    hids = list(range(2)) + list(range(100+cust*3, 100+cust*3+3)) + list(range(10000+i*10, 10000+i*10+rng.randint(2,4)))
    reqs.append({'timestamp':ts, 'input_length':rng.randint(2000,5000), 'output_length':rng.randint(10,50), 'hash_ids':hids})
with open('/bench/customer_trace.jsonl','w') as f:
    for r in reqs: f.write(json.dumps(r)+'\n')
print(f'Generated {len(reqs)} requests')
"

# Model list: (model_name, tp_size, max_model_len, notes)
declare -a MODELS=(
  "google/gemma-3-1b-it|1|4096|tiny"
  "ibm-granite/granite-guardian-3.2-5b|1|8192|small"
  "meta-llama/Llama-2-7b-chat-hf|1|4096|small"
  "RedHatAI/Llama-3.1-8B-Instruct|1|8192|small"
  "RedHatAI/Foundation-Sec-8B|1|8192|small"
  "RedHatAI/Llama-Guard-4-12B|1|8192|medium"
  "RedHatAI/gemma-3-12b-it|1|8192|medium"
  "RedHatAI/Phi-4-reasoning|1|8192|medium"
  "google/gemma-3-27b-it|2|8192|large"
  "RedHatAI/gemma-4-26B-A4B-it-FP8-Dynamic|1|8192|MoE-FP8"
  "RedHatAI/gemma-4-31B-it-FP8-Dynamic|2|8192|large-FP8"
  "RedHatAI/gpt-oss-120b|4|8192|MoE-large"
)

TOTAL=${#MODELS[@]}
COMPLETED=0
FAILED=0
SKIPPED=0

for entry in "${MODELS[@]}"; do
  IFS='|' read -r MODEL TP MAX_LEN NOTES <<< "$entry"
  COMPLETED=$((COMPLETED + 1))

  echo "" | tee -a "$LOG"
  echo "========================================" | tee -a "$LOG"
  echo "  [$COMPLETED/$TOTAL] $MODEL (TP=$TP, $NOTES)" | tee -a "$LOG"
  echo "  Started: $(date)" | tee -a "$LOG"
  echo "========================================" | tee -a "$LOG"

  if "$SCRIPT_DIR/benchmark_model.sh" "$MODEL" "$TP" "$MAX_LEN" 2>&1 | tee -a "$LOG"; then
    echo "  ✓ $MODEL completed" | tee -a "$LOG"
  else
    echo "  ✗ $MODEL FAILED" | tee -a "$LOG"
    FAILED=$((FAILED + 1))
  fi
done

# Cleanup
kubectl delete pod bench-runner -n "$NAMESPACE" 2>/dev/null || true
helm uninstall ms-bench -n "$NAMESPACE" 2>/dev/null || true
kubectl delete svc model-direct -n "$NAMESPACE" 2>/dev/null || true

echo "" | tee -a "$LOG"
echo "========================================" | tee -a "$LOG"
echo "  ALL MODELS COMPLETE" | tee -a "$LOG"
echo "  Total: $TOTAL, Completed: $((TOTAL - FAILED)), Failed: $FAILED" | tee -a "$LOG"
echo "  Finished: $(date)" | tee -a "$LOG"
echo "========================================" | tee -a "$LOG"

# Generate master report
echo "Generating master report..." | tee -a "$LOG"
python3 "$SCRIPT_DIR/generate_master_report.py" "$ROOT/results" 2>&1 | tee -a "$LOG"
