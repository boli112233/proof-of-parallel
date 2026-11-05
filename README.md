# Proof of Parallel

**proofofparallel.com** · How fast can one rented GPU check Solana signatures?

Every Solana transaction carries ed25519 signatures, and checking them is one of the heaviest jobs a validator does. Solana was designed with GPU signature verification from day one ([solana-perf-libs](https://github.com/anza-xyz/solana-perf-libs)). This repo makes that easy to measure on any NVIDIA GPU, next to a fair CPU baseline on the same machine, with one command.

## Run it

On a Linux machine with an NVIDIA GPU and the CUDA toolkit (for example the `nvidia/cuda:12.6.0-devel-ubuntu22.04` image):

```bash
git clone <this repo> && cd proof-of-parallel
./scripts/run.sh
```

It prints a table and writes `results/results.json` and `results/results.md`.

## What it measures

| mode | how |
|---|---|
| CPU, 1 core | ed25519-dalek, one signature at a time |
| CPU, all cores | ed25519-dalek on every thread (rayon) |
| CPU, all cores, batch of 64 | ed25519-dalek batch verification, falls back to single checks when a batch fails |
| GPU | solana-perf-libs `cuda_ed25519_verify`, one signature per packet, batches of 64k, 256k and 1M |

Packets look like Solana transactions: one signature over a 176 byte message, 256 different signers. On the CPU side 1% of the signatures are tampered with after signing and every result is checked against the expected answer, so a fast but wrong verifier cannot pass. The GPU binary asserts that every signature it was given verifies.

The GPU code is pinned to a specific solana-perf-libs commit and used unchanged, so anyone can reproduce the numbers.

## Notes

- Numbers depend on the GPU, the CPU it is paired with, and the batch size. Always publish both sides from the same machine.
- Throughput here is pure signature checking. A validator also has to move packets to the GPU and back; `ITER` and `SIZES` can be changed to explore that (`SIZES="16384 65536" ITER=10 ./scripts/run.sh`).

## License

Apache 2.0. See `NOTICE` for the solana-perf-libs credit.
