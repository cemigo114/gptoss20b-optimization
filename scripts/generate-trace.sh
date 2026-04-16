#!/usr/bin/env bash
set -euo pipefail

# Generate a synthetic trace matching the customer's classification/extraction workload.
# Adjust parameters below to match your actual traffic pattern.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

python3 "${SCRIPT_DIR}/generate_customer_trace.py" \
  --num-requests "${NUM_REQUESTS:-2000}" \
  --num-customers "${NUM_CUSTOMERS:-50}" \
  --system-prompt-blocks "${SYSTEM_PROMPT_BLOCKS:-10}" \
  --input-min "${INPUT_MIN:-3000}" \
  --input-max "${INPUT_MAX:-7000}" \
  --output-min "${OUTPUT_MIN:-10}" \
  --output-max "${OUTPUT_MAX:-50}" \
  --arrival-rate "${ARRIVAL_RATE:-22}" \
  --seed "${SEED:-42}" \
  --output "${OUTPUT:-${SCRIPT_DIR}/../customer_workload_trace.jsonl}"
