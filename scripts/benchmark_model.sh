#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# Benchmark a single model: deploy, warmup, concurrency sweep, teardown
#
# Usage:
#   ./benchmark_model.sh <model_name> <tp_size> [max_model_len] [image_override]
#
# Example:
#   ./benchmark_model.sh google/gemma-3-1b-it 1 8192
#   ./benchmark_model.sh google/gemma-3-27b-it 2 8192
#   ./benchmark_model.sh RedHatAI/gpt-oss-120b 4 8192
##############################################################################

MODEL="${1:?Usage: $0 <model_name> <tp_size> [max_model_len] [image]}"
TP="${2:?Usage: $0 <model_name> <tp_size>}"
MAX_MODEL_LEN="${3:-8192}"
IMAGE="${4:-vllm/vllm-openai:v0.18.0}"
NAMESPACE="${NAMESPACE:-kpouget-dev}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

# Derive safe names
SAFE_NAME=$(echo "$MODEL" | tr '/' '-' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | head -c 50)
REPLICAS=$((16 / TP))
RESULTS_DIR="$ROOT/results/${SAFE_NAME}"
mkdir -p "$RESULTS_DIR"

echo "================================================================"
echo "  MODEL: $MODEL"
echo "  TP=$TP, Replicas=$REPLICAS, GPUs=16"
echo "  Image: $IMAGE"
echo "  Results: $RESULTS_DIR"
echo "================================================================"

# Generate Helm values
HELM_VALUES="$RESULTS_DIR/values.yaml"
cat > "$HELM_VALUES" << VALEOF
multinode: false
modelArtifacts:
  uri: "hf://${MODEL}"
  name: "${MODEL}"
  size: 100Gi
  authSecretName: "llm-d-hf-token"
  labels:
    llm-d.ai/inference-serving: "true"
    llm-d.ai/guide: "multi-model-bench"
    llm-d.ai/model: "${SAFE_NAME}"
routing:
  proxy:
    enabled: false
    targetPort: 8000
accelerator:
  type: nvidia
decode:
  create: true
  parallelism:
    tensor: ${TP}
    data: 1
  replicas: ${REPLICAS}
  containers:
    - name: "vllm"
      image: ${IMAGE}
      modelCommand: vllmServe
      args:
        - "--disable-uvicorn-access-log"
        - "--gpu-memory-utilization=0.9"
        - "--enable-prefix-caching"
        - "--max-model-len=${MAX_MODEL_LEN}"
        - "--max-num-seqs=512"
        - "--max-num-batched-tokens=16384"
      ports:
        - containerPort: 8000
          name: vllm
          protocol: TCP
      resources:
        limits:
          cpu: '8'
          memory: 100Gi
        requests:
          cpu: '8'
          memory: 100Gi
      mountModelVolume: true
      volumeMounts:
        - name: shm
          mountPath: /dev/shm
        - name: cache
          mountPath: /.cache
      startupProbe:
        httpGet:
          path: /v1/models
          port: vllm
        initialDelaySeconds: 15
        periodSeconds: 30
        timeoutSeconds: 5
        failureThreshold: 120
      livenessProbe:
        httpGet:
          path: /health
          port: vllm
        periodSeconds: 10
        timeoutSeconds: 5
        failureThreshold: 3
      readinessProbe:
        httpGet:
          path: /v1/models
          port: vllm
        periodSeconds: 5
        timeoutSeconds: 2
        failureThreshold: 3
  volumes:
    - name: shm
      emptyDir:
        medium: Memory
        sizeLimit: 20Gi
    - name: cache
      emptyDir: {}
prefill:
  create: false
VALEOF

# Teardown any existing deployment
echo "[1/6] Cleaning up..."
helm uninstall ms-bench -n "$NAMESPACE" 2>/dev/null || true
kubectl delete svc model-direct -n "$NAMESPACE" 2>/dev/null || true
sleep 10

# Deploy
echo "[2/6] Deploying ${MODEL} (${REPLICAS}×TP=${TP})..."
helm install ms-bench llm-d-modelservice/llm-d-modelservice \
  -n "$NAMESPACE" -f "$HELM_VALUES"

kubectl apply -n "$NAMESPACE" -f - <<SVCEOF
apiVersion: v1
kind: Service
metadata:
  name: model-direct
spec:
  selector:
    llm-d.ai/inference-serving: "true"
    llm-d.ai/guide: "multi-model-bench"
  ports:
  - port: 8000
    targetPort: 8000
SVCEOF

echo "[3/6] Waiting for ${REPLICAS} pods..."
kubectl wait --for=condition=Ready pod -l 'llm-d.ai/guide=multi-model-bench' \
  -n "$NAMESPACE" --timeout=900s || {
    echo "WARNING: Not all pods ready. Proceeding with available pods."
    kubectl get pods -n "$NAMESPACE" -l 'llm-d.ai/guide=multi-model-bench' --no-headers | head -5
}

# Verify model is serving
ENDPOINT="http://model-direct.${NAMESPACE}.svc.cluster.local:8000"
echo "[4/6] Verifying model..."
kubectl exec bench-runner -n "$NAMESPACE" -- python3 -c "
import urllib.request, json
r = urllib.request.urlopen('${ENDPOINT}/v1/models', timeout=30)
print('Model serving:', json.load(r)['data'][0]['id'])
" || { echo "ERROR: Model not serving"; exit 1; }

# Generate trace for this model
echo "[5/6] Running concurrency sweep..."
TRACE="/bench/customer_trace.jsonl"

# Warmup
kubectl exec bench-runner -n "$NAMESPACE" -- python3 /bench/benchmark_stage.py \
  --trace "$TRACE" --endpoint "$ENDPOINT" --model "$MODEL" \
  --stage warmup --rate-scale 0.00001 --max-requests 200 --max-concurrency 32 --max-input-tokens 2000 \
  --output /bench/results/warmup.json 2>&1 | grep "Results:" || true

# Concurrency sweep
for conc in 4 8 16 32 64 128; do
  echo "  conc=$conc..."
  kubectl exec bench-runner -n "$NAMESPACE" -- python3 /bench/benchmark_stage.py \
    --trace "$TRACE" --endpoint "$ENDPOINT" --model "$MODEL" \
    --stage "${SAFE_NAME}-conc-${conc}" --rate-scale 0.00001 \
    --max-requests 500 --max-concurrency "$conc" --max-input-tokens 2000 \
    --output "/bench/results/${SAFE_NAME}_conc_${conc}.json" 2>&1 | \
    grep -E "Results:|Throughput|TTFT.*P99|ITL.*P50|TPSU" || echo "  (run may have had errors)"
done

# Copy results
echo "[6/6] Copying results..."
for f in $(kubectl exec bench-runner -n "$NAMESPACE" -- ls /bench/results/ | grep "$SAFE_NAME"); do
  kubectl cp "$NAMESPACE/bench-runner:/bench/results/$f" "$RESULTS_DIR/$f" 2>/dev/null
done

# Generate report for this model
python3 "$SCRIPT_DIR/generate_optimization_report.py" "$RESULTS_DIR" 500 2>/dev/null || true

# Teardown
echo "Tearing down..."
helm uninstall ms-bench -n "$NAMESPACE" 2>/dev/null || true
kubectl delete svc model-direct -n "$NAMESPACE" 2>/dev/null || true
sleep 10

echo "================================================================"
echo "  DONE: $MODEL → $RESULTS_DIR"
echo "================================================================"
