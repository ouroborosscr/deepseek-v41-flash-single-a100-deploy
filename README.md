# DeepSeek-V4.1-Flash on a Single A100 80GB

English | [简体中文](README.zh-CN.md)

A reproducible, evidence-bounded deployment of the text-only DeepSeek-V4.1-Flash checkpoint on one NVIDIA A100-SXM4-80GB. MoE experts are tiered across VRAM, pinned host memory, the Linux page cache, and storage.

This repository contains deployment scripts and measured results. It does not contain model weights, converted GGUF files, credentials, or llama.cpp source.

## Result

The deployment was completed and validated on September 15, 2026:

- one A100-SXM4-80GB, fixed to a single physical GPU;
- 1 TiB system RAM (768 GiB recommended minimum);
- 60 GiB VRAM expert cache;
- 120 GiB pinned host expert cache;
- 8,192-token initial serving context;
- OpenAI-compatible HTTP API;
- measured generation of 8.20 tokens/s on first content, 16.58 tokens/s when resident, and 11.48 tokens/s for a 200-token reasoning response.

This proves that a **tiered single-card deployment is feasible**. It does not mean the model fits in 80GB VRAM. The normal full-resident vLLM path is not a single-A100 configuration: the current vLLM recipe budgets roughly 614GB of aggregate VRAM.

## Precision and Feature Scope

This is a **no-additional-low-bit-quantization deployment**: it does not apply a
second 2-bit/3-bit/4-bit compression pass, prune experts, or zero the Engram.
The released mixed-precision weights are retained as MXFP4 routed experts,
FP8 Engram bytes, Q8_0 attention/dense tensors, BF16 embeddings, and F32 norms.
Therefore, “no quantization” here means no extra low-bit quantization beyond the
released checkpoint representation; it does not mean every tensor is FP16/BF16.

To make the single-card text runtime fit, two model features are deliberately
excluded from the converted GGUF: the vision encoder/aligner and the DSpark
speculative-draft head. The resulting service is a high-fidelity text model, not
the complete multimodal + DSpark release.

## Why It Works

DeepSeek-V4.1-Flash has a 552B backbone, about 196.6B Engram parameters, and activates roughly 8B parameters per prompt token and 16B per output token. Activation sparsity reduces compute, but all experts still need a storage tier.

```text
A100 resident weights and workspaces
  -> 60 GiB VRAM expert cache
      -> 120 GiB pinned-RAM expert cache
          -> Linux file page cache
              -> sharded GGUF on storage
```

See [Architecture](docs/architecture.zh-CN.md) for the full memory accounting.

## Tested Requirements

- NVIDIA A100 80GB (`sm_80`)
- approximately 1 TiB RAM; 768 GiB is the guarded minimum in the preflight script
- at least 1.1 TiB free disk when retaining both source weights and converted GGUF
- CUDA 12.8 and a compatible host compiler
- CMake, Ninja, curl, patch, tar, Python, tmux, and ModelScope
- an experimental V4.1-aware llama.cpp fork pinned by commit

Other GPUs, smaller RAM configurations, network filesystems, multimodal serving, and multi-request throughput are not validated by this repository.

## Repository Layout

```text
config/env.example           configurable paths and resource budgets
patches/include-cmath.patch  build fix required by the tested fork commit
scripts/01-check-host.sh     RAM, GPU, and disk preflight
scripts/02-download-model.sh ModelScope download plus shard validation
scripts/03-build-runtime.sh  pinned llama.cpp source and sm_80 build
scripts/04-convert-model.sh  full dry-run and sharded GGUF conversion
scripts/05-serve.sh          guarded single-GPU server startup
scripts/06-smoke-test.sh     health, model-list, and inference checks
docs/                        architecture, benchmark, and troubleshooting notes
```

## Quick Start

### 1. Configure

```bash
cp config/env.example .env
${EDITOR:-vi} .env
source .env
export CONFIG_FILE=$PWD/.env
```

Do not commit `.env`. Use absolute paths on a filesystem with sufficient space.

### 2. Check the host

```bash
./scripts/01-check-host.sh
```

### 3. Download the official checkpoint from ModelScope

```bash
tmux new-session -d -s dsv41-download \
  "CONFIG_FILE='$PWD/.env' '$PWD/scripts/02-download-model.sh' \
   >'$PWD/download.log' 2>&1"
```

The tested checkpoint contained 96,085 indexed tensors in 48 safetensors shards, totalling 510,296,708,312 bytes.

### 4. Build the runtime

```bash
./scripts/03-build-runtime.sh
```

The script downloads `JigSawPT/llama.cpp` at commit `3b6fcfe4f7e2c282076f0c159278d3acfa3ad4e5`, applies the documented `<cmath>` fix when needed, and builds CUDA code for `sm_80`.

### 5. Prepare conversion Python

```bash
python3 -m venv "$DEPLOY_ROOT/venv-convert"
"$DEPLOY_ROOT/venv-convert/bin/pip" install \
  -r "$RUNTIME_DIR/requirements/requirements-convert_hf_to_gguf.txt"
export CONVERT_PYTHON="$DEPLOY_ROOT/venv-convert/bin/python"
```

Persist `CONVERT_PYTHON` in `.env` after creating the environment.

### 6. Run a full dry-run before writing 500GB

```bash
./scripts/04-convert-model.sh --dry-run
```

The dry-run traverses and repacks all 40 expert layers, validates Engram metadata, and prints the 11-shard output plan without writing GGUF data.

### 7. Convert in tmux

```bash
tmux new-session -d -s dsv41-convert \
  "CONFIG_FILE='$PWD/.env' '$PWD/scripts/04-convert-model.sh' --convert \
   >'$PWD/convert.log' 2>&1"
```

The tested output was 11 files and 501,809,981,440 bytes. The converter streams the large Engram tables through memory maps instead of expanding them to FP32.

### 8. Start the server

The safe default is loopback-only:

```bash
tmux new-session -d -s dsv41-server \
  "CONFIG_FILE='$PWD/.env' '$PWD/scripts/05-serve.sh' \
   >'$PWD/server.log' 2>&1"
```

Wait for:

```text
MoE L2 host tier = 120.00 GiB PINNED
model loaded
```

For a network listener, set `HOST=0.0.0.0` and an `API_KEY`. Deliberately running without authentication additionally requires `ALLOW_UNAUTHENTICATED_PUBLIC=1`.

### 9. Verify

```bash
./scripts/06-smoke-test.sh
```

The smoke test checks `/health`, `/v1/models`, and a deterministic request whose expected answer is `899`.

## API Example

Use the OpenAI top-level field `reasoning_effort: "none"` for a clean non-reasoning response:

```bash
curl http://127.0.0.1:7888/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "DeepSeek-V4.1-Flash",
    "messages": [{"role":"user","content":"What is 29*31? Return only the integer."}],
    "reasoning_effort": "none",
    "temperature": 0,
    "max_tokens": 32
  }'
```

Omit `reasoning_effort: "none"` to use the model's reasoning path. The tested parser places thought text in `message.reasoning_content` and the final answer in `message.content`.

Do not use `chat_template_kwargs.thinking=false` with the pinned fork: it leaves an orphan `</think>` marker in content. See [Troubleshooting](docs/troubleshooting.zh-CN.md).

## Limitations

- **Text only:** the tested converter excludes the vision encoder and aligner.
- **No DSpark draft head:** the 2,398 MTP/DSpark tensors are skipped; normal
  autoregressive text generation remains available.
- **Experimental runtime:** this is not upstream llama.cpp or a standard vLLM path.
- **Context is workload- and allocator-dependent:** the public service stays at
  8,192 tokens as the conservative profile. In isolated tests, 786,432 tokens
  completed a short end-to-end generation, while 849,920 tokens could initialize
  but OOMed on the first generation. A 1,048,576-token configuration failed during
  compute-buffer reservation and needed an additional ~9.77 GiB on the 80GB card.
  The model advertises up to 1M, but this single-card deployment should be described
  as **786K experimentally service-validated**, not as a 1M production guarantee.
- **Single request slot:** concurrency can increase expert-cache churn and needs workload-specific testing.
- **120 GiB page-locked RAM:** verify the log says `PINNED`; pageable fallback is slower.
- **No DSpark:** the 5090 study found neutral-to-negative results for mixed content under expert streaming.

## Security

Never commit `.env`, API keys, SSH credentials, model files, or service logs. Keep the listener on loopback unless an authenticated reverse proxy, firewall, VPN, or allowlist protects it. Read [SECURITY.md](SECURITY.md) before exposing the API.

## Evidence and References

- [Measured benchmark](docs/benchmark.zh-CN.md)
- [Troubleshooting record](docs/troubleshooting.zh-CN.md)
- [DeepSeek model page on ModelScope](https://www.modelscope.cn/models/deepseek-ai/DeepSeek-V4.1-Flash)
- [vLLM recipe](https://recipes.vllm.ai/deepseek-ai/DeepSeek-V4.1-Flash)
- [Single-RTX-5090 technical report](https://github.com/JigSawPT/deepseek-v41-flash-on-5090)
- [V4.1 GGUF model card](https://huggingface.co/JigSawPT/DeepSeek-V4.1-Flash-GGUF)

## License

The scripts and documentation in this repository are released under the MIT License. DeepSeek model weights and llama.cpp are separate upstream works under their own license terms; this repository does not redistribute either one.
