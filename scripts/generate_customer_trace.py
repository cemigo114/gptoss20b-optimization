#!/usr/bin/env python3
"""Generate a synthetic trace for classification/extraction workloads.

Configurable parameters allow matching to actual production traffic patterns.
Output is a JSONL file compatible with the benchmark_stage.py replay script.
"""

import argparse
import json
import random


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--num-requests", type=int, default=2000)
    parser.add_argument("--num-customers", type=int, default=50,
                        help="Number of distinct customer prefixes")
    parser.add_argument("--system-prompt-blocks", type=int, default=10,
                        help="Number of 512-token blocks in the shared system prompt")
    parser.add_argument("--input-min", type=int, default=3000, help="Min input tokens")
    parser.add_argument("--input-max", type=int, default=7000, help="Max input tokens")
    parser.add_argument("--output-min", type=int, default=10, help="Min output tokens")
    parser.add_argument("--output-max", type=int, default=50, help="Max output tokens")
    parser.add_argument("--arrival-rate", type=float, default=22, help="Avg req/s (Poisson)")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--output", default="customer_workload_trace.jsonl")
    args = parser.parse_args()

    rng = random.Random(args.seed)
    requests = []
    ts = 0

    for i in range(args.num_requests):
        if i > 0:
            ts += int(rng.expovariate(args.arrival_rate) * 1000)

        customer_id = rng.randint(0, args.num_customers - 1)

        # System prompt (shared by all) + customer prefix + unique document
        hash_ids = list(range(args.system_prompt_blocks))
        hash_ids += list(range(100 + customer_id * 5, 100 + customer_id * 5 + 5))
        doc_blocks = rng.randint(5, 15)
        hash_ids += list(range(10000 + i * 20, 10000 + i * 20 + doc_blocks))

        requests.append({
            "timestamp": ts,
            "input_length": rng.randint(args.input_min, args.input_max),
            "output_length": rng.randint(args.output_min, args.output_max),
            "hash_ids": hash_ids,
        })

    with open(args.output, "w") as f:
        for r in requests:
            f.write(json.dumps(r) + "\n")

    input_lens = [r["input_length"] for r in requests]
    output_lens = [r["output_length"] for r in requests]
    print(f"Generated {len(requests)} requests to {args.output}")
    print(f"  Input: {min(input_lens)}-{max(input_lens)} tokens (avg {sum(input_lens)//len(input_lens)})")
    print(f"  Output: {min(output_lens)}-{max(output_lens)} tokens (avg {sum(output_lens)//len(output_lens)})")
    print(f"  ISL:OSL ratio: {sum(input_lens)//sum(output_lens)}:1")
    print(f"  System prompt: {args.system_prompt_blocks} blocks ({args.system_prompt_blocks*512} tokens)")
    print(f"  Customer prefixes: {args.num_customers}")
    print(f"  Arrival rate: {args.arrival_rate} req/s")


if __name__ == "__main__":
    main()
