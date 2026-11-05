#!/usr/bin/env bash
# Proof of Parallel: one command on any Linux box with an NVIDIA GPU (CUDA toolkit with nvcc, e.g. image nvidia/cuda:12.6.0-devel-ubuntu22.04).
# Builds the CPU baseline (Rust, ed25519-dalek) and Solana's open-source CUDA ed25519 verifier (anza-xyz/solana-perf-libs),
# runs both on the same machine, writes results/results.json and results/results.md, and prints a short summary.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD; OUT=$ROOT/results; mkdir -p "$OUT"
PERF_COMMIT=233c4457fd8d425da99cb3db46b2be8eb8b98997   # pinned, reproducible
SIZES=${SIZES:-"65536 262144 1048576"}
ITER=${ITER:-5}

echo "== machine"
GPU=$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "none")
CPU=$(lscpu | sed -n 's/^Model name:\s*//p' | head -1); CORES=$(nproc)
echo "GPU: $GPU"; echo "CPU: $CPU ($CORES threads)"

echo "== CPU baseline"
command -v cargo >/dev/null || { curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal; . "$HOME/.cargo/env"; }
(cd cpu && cargo build --release -q)
CPU_JSON=$(./cpu/target/release/Proof of Parallel-cpu 1048576)
echo "$CPU_JSON"

echo "== GPU (solana-perf-libs CUDA ed25519)"
GPU_JSON="[]"
if command -v nvcc >/dev/null && [ "$GPU" != "none" ]; then
  [ -d gpu/solana-perf-libs ] || git clone -q https://github.com/anza-xyz/solana-perf-libs gpu/solana-perf-libs
  (cd gpu/solana-perf-libs && git checkout -q $PERF_COMMIT)
  CC=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | tr -d .)
  ARCH="sm_${CC}"
  make -s -C gpu/solana-perf-libs/src V=release GPU_ARCHS=$ARCH GPU_PTX_ARCH=compute_${CC} HOST_CFLAGS="-Wall -fPIC -Wno-strict-aliasing" release/cuda_ed25519_verify
  BIN=gpu/solana-perf-libs/src/release/cuda_ed25519_verify
  export LD_LIBRARY_PATH=$ROOT/gpu/solana-perf-libs/src/release:${LD_LIBRARY_PATH:-}
  GPU_JSON="["; first=1
  for n in $SIZES; do
    # args: num_signatures num_elems sigs_per_packet threads iterations non_default_stream
    line=$($BIN $n 1 1 1 $ITER 0 | grep 'verifies/sec')
    rate=$(echo "$line" | sed -E 's/.*verifies\/sec: ([0-9.]+).*/\1/')
    [ $first = 1 ] || GPU_JSON+=","; first=0
    GPU_JSON+="{\"batch\":$n,\"sigs_per_s\":${rate%.*}}"
    echo "batch $n: $rate sigs/s"
  done
  GPU_JSON+="]"
else
  echo "no nvcc or no NVIDIA GPU found: GPU part skipped"
fi

python3 - "$OUT" "$GPU" "$CPU" "$CORES" "$CPU_JSON" "$GPU_JSON" "$PERF_COMMIT" <<'PY'
import json, sys, datetime
out, gpu, cpu, cores, cj, gj, commit = sys.argv[1:]
c, g = json.loads(cj), json.loads(gj)
best = max([x["sigs_per_s"] for x in g], default=0)
cpu_best = max(c["all_cores_sigs_per_s"], c["all_cores_batch64_sigs_per_s"])
r = {"date": datetime.datetime.utcnow().isoformat() + "Z", "gpu": gpu, "cpu_model": cpu, "cpu_threads": int(cores), "cpu": c, "gpu_runs": g,
     "gpu_best_sigs_per_s": best, "cpu_best_sigs_per_s": cpu_best, "speedup_vs_all_cores": round(best / cpu_best, 2) if best else None,
     "speedup_vs_one_core": round(best / c["single_core_sigs_per_s"], 1) if best else None, "solana_perf_libs_commit": commit}
json.dump(r, open(f"{out}/results.json", "w"), indent=1)
md = [f"# Proof of Parallel results ({r['date'][:10]})", "", f"GPU: {gpu}", f"CPU: {cpu} ({cores} threads)", "",
      "| mode | signatures / second |", "|---|---|",
      f"| CPU, 1 core | {c['single_core_sigs_per_s']:,.0f} |", f"| CPU, all cores | {c['all_cores_sigs_per_s']:,.0f} |",
      f"| CPU, all cores, batch of 64 | {c['all_cores_batch64_sigs_per_s']:,.0f} |"]
md += [f"| GPU, batch {x['batch']:,} | {x['sigs_per_s']:,.0f} |" for x in g]
md += ["", f"CPU results checked against 1% tampered signatures: {'all correct' if c['results_correct'] else 'MISMATCH'}.",
       f"GPU verifier: anza-xyz/solana-perf-libs @ {commit[:10]} (asserts every signature verified)."]
open(f"{out}/results.md", "w").write("\n".join(md) + "\n")
print("\n".join(md))
if best: print(f"\nGPU best: {best:,.0f} sigs/s = {r['speedup_vs_all_cores']}x all {cores} CPU threads, {r['speedup_vs_one_core']}x one core")
PY
