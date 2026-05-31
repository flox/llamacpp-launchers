# VRAM Optimizer — Design Brief

## Problem

When running LLMs locally on a GPU with limited VRAM, the user must manually tune interdependent parameters that trade off inference speed vs usable context. Setting values too high causes OOM. Setting them too low degrades performance. The user currently guesses and iterates, which is slow and error-prone.

Different inference engines expose different knobs:
- **llama.cpp**: `gpu_layers` (partial CPU offload) + `ctx_size` (static KV cache)
- **vLLM**: `gpu_memory_utilization` (fraction of VRAM to use) + `max_model_len` (max sequence length)

The core problem is the same: allocate limited VRAM across model weights and working memory (KV cache / paged attention) to maximize both speed and usable context.

## Goal

Build a single Rust CLI tool (`vram-optimizer`) that, given a model and GPU, outputs optimal engine-specific parameters. It supports multiple inference engines via hardcoded cost models.

**Repo**: `/home/daedalus/dev/vram-optimizer` (standalone Rust crate)

## Platform Note

The tool itself is cross-platform (pure computation + HTTP for HF API). VRAM values (`--vram-total-mib`, `--vram-used-mib`) are passed as flags by the calling wrapper, which queries `nvidia-smi` on Linux. On macOS (no NVIDIA GPU), the wrapper bypasses the tool entirely. The tool may optionally auto-detect VRAM via nvidia-smi as a best-effort convenience for direct invocation, but this is not the primary path.

## Interface

```
vram-optimizer \
  --engine <llamacpp|vllm>       \  # which cost model to use
  --model <path_or_hf_repo>      \  # local GGUF/dir or HuggingFace repo ID
  --quant <Q4_K_M|Q8_0|...>     \  # quantization level (for HF repo file selection)
  --vram-total-mib <N>          \  # total GPU VRAM (required; wrapper gets from nvidia-smi)
  --vram-used-mib <N>           \  # current VRAM usage (required; wrapper gets from nvidia-smi)
  --safety-margin-mib <N>      \  # VRAM headroom to reserve (default: 500; user's responsibility)
  --max-ctx-size <N>            \  # upper bound for context (default: 131072)
  --min-ctx-size <N>            \  # lower bound for context (default: 32768)
  --min-gpu-layers <N>          \  # minimum acceptable GPU layers (default: 1, llamacpp only)
  --kv-cache-type <f16|q8_0|q4_0>  \  # KV cache precision (default: f16)
  --fixed-gpu-layers <N>        \  # user override (llamacpp): use exactly this value
  --fixed-ctx-size <N>          \  # user override: use exactly this context size
  --hf-token <TOKEN>            \  # HuggingFace token (also reads HF_TOKEN env var)
  --json                        \  # output as JSON instead of key=value

Output (stdout, machine-readable):
  engine=llamacpp
  gpu_layers=<N>
  ctx_size=<N>
  vram_model_mib=<N>
  vram_kv_cache_mib=<N>
  vram_total_estimated_mib=<N>
  vram_headroom_mib=<N>
```

## Model Metadata Sources

The tool resolves model architecture metadata from multiple sources:

### When model is local:
- **GGUF file** (llamacpp): Parse the GGUF header for `block_count`, `embedding_length`, `attention.key_length`, etc. File size from `stat`.
- **Directory with config.json** (vLLM): Parse `config.json` for `num_hidden_layers`, `hidden_size`, `num_key_value_heads`, etc. Estimate model size from safetensors file sizes.

### When model is remote (HuggingFace repo):
- Fetch `config.json` via HF API (small file, always available)
- For GGUF: get file listing to determine GGUF file size for the requested quantization
- For safetensors: sum file sizes from the repo listing

### HuggingFace Authentication

For private repos or rate-limited access:
1. `--hf-token <TOKEN>` flag (highest priority)
2. `HF_TOKEN` environment variable
3. If interactive (`VRAM_OPTIMIZER_INTERACTIVE=1` env var is set): prompt the user for a token, encrypt it, and cache locally for future use (`~/.config/vram-optimizer/token`)

Non-interactive mode (no env var set) never prompts — fails with a clear message if auth is needed.

## Engine: llama.cpp

### Parameters to optimize
- `gpu_layers`: 0 to n_layers (partial offload, more = faster)
- `ctx_size`: min_ctx_size to max_ctx_size (KV cache allocation)

### VRAM cost model

**Model weights:**
```
base_mib = non-layer tensors (embeddings, output head) + CUDA scratch
per_layer_mib = marginal cost of one additional layer on GPU
model_vram = base_mib + gpu_layers * per_layer_mib
```

Non-layer tensors are always on GPU regardless of `gpu_layers`. CUDA compute buffers scale with model architecture (larger for MoE).

**KV cache (precise formula, when architecture details are known):**
```
kv_elements_per_attn_layer_per_token = (key_length + value_length) * head_count_kv
n_attn_layers_on_gpu = floor(gpu_layers / full_attention_interval)
kv_cache_mib = n_attn_layers_on_gpu * ctx_size * kv_elements * kv_bytes / (1024^2)
```

Note: `(key_length + value_length)` already accounts for both K and V — no extra `2×` multiplier.

**KV cache (fallback, MHA assumed):**
```
kv_cache_mib = gpu_layers * ctx_size * 2 * n_embd * kv_bytes / (1024^2)
```

This overestimates for GQA/MQA models — use the precise formula when metadata is available.

**KV cache precision options:**
| Type | Bytes per element |
|------|-------------------|
| f16  | 2 |
| bf16 | 2 |
| q8_0 | 1 |
| q4_0 | 0.5 |
| q4_1 | 0.5 |
| q5_0 | 0.625 |
| q5_1 | 0.625 |

**Constraint:**
```
base_mib + (gpu_layers × per_layer_mib) + kv_cache_mib <= available_vram
```

### GGUF metadata fields

**Required:**
- `<arch>.block_count` — n_layers
- `<arch>.embedding_length` — n_embd
- `<arch>.context_length` — max training context

**Optional (refine KV cache estimate):**
- `<arch>.attention.key_length` — per-head key dimension
- `<arch>.attention.value_length` — per-head value dimension
- `<arch>.attention.head_count_kv` — KV heads (for GQA/MQA)
- `<arch>.full_attention_interval` — hybrid Mamba+Attention (only every Nth layer has KV cache)
- `<arch>.expert_count` — MoE indicator (affects base cost estimate)

## Engine: vLLM

### Parameters to optimize
- `max_model_len`: maximum sequence length (analogous to ctx_size)
- `gpu_memory_utilization`: fraction of VRAM vLLM is allowed to use (0.0-1.0, default 0.9)

### VRAM cost model

vLLM uses PagedAttention — KV cache is dynamically allocated in pages, not pre-allocated statically. The cost model is different:

**Model weights** (always fully on GPU — no partial offload in single-GPU mode):
```
model_vram_mib ≈ sum of safetensors/model file sizes on disk
```

vLLM keeps weights in their on-disk format on GPU — quantized weights (GPTQ, AWQ, FP8) stay quantized. A 4-bit quantized 70B model uses ~35GB VRAM for weights, not the 140GB it would take at fp16. VRAM for weights ≈ on-disk model file size.

**KV cache budget** (what's left after model + overhead):
```
kv_budget = (vram_total * gpu_memory_utilization) - model_vram - activation_overhead
max_model_len = kv_budget / kv_per_token
```

Where `kv_per_token` depends on architecture (same formulas as llamacpp KV section).

**Output:**
```
engine=vllm
gpu_memory_utilization=<0.0-1.0>
max_model_len=<N>
vram_model_mib=<N>
vram_kv_budget_mib=<N>
vram_total_estimated_mib=<N>
```

### config.json fields (HuggingFace format)
- `num_hidden_layers` — n_layers
- `hidden_size` — n_embd
- `num_key_value_heads` — KV heads
- `num_attention_heads` — Q heads
- `head_dim` — per-head dimension (if present)
- `max_position_embeddings` — max training context
- `model_type` — architecture family

## Optimization Strategy

The tool must find the best **balance** between speed and context within the VRAM budget. Neither is strictly more important — they are in tension and both have diminishing returns.

**The tradeoff (applies to both engines):**
- More VRAM for model weights (gpu_layers / full model loading) = faster inference
- More VRAM for KV cache (ctx_size / max_model_len) = larger usable context window
- Coding agents need at least ~32K context just for their system prompt
- Beyond ~65K context, additional context has diminishing value for most coding tasks
- Beyond ~80% of layers on GPU (llamacpp), additional layers have diminishing speed benefit

**Domain context for coding agents:**
- System prompts are ~30K tokens. Context under ~32K is completely unusable.
- The 32K-65K range is functional but tight. 65K-131K is comfortable.
- Interactive coding tools are latency-sensitive — CPU-bound layers are painful
- A model with 50% layers on GPU but 64K context is more useful than 100% GPU with 16K context, but 100% GPU with 32K context might beat 50% GPU with 128K context

The tool should find the sweet spot on this tradeoff curve, not simply maximize one parameter at the expense of the other.

## Operating Modes

1. **Neither value fixed:** Optimize both — find the best balance.
2. **One fixed (e.g., `--fixed-gpu-layers 31`):** Treat as hard constraint, optimize the other.
3. **Both fixed:** Validate only — exit 0 if it fits, exit non-zero with diagnostics if not.

When a fixed value is provided, the tool respects it exactly. If it causes OOM even with the other parameter minimized, fail with a clear message showing VRAM needed vs available.

## Hard Constraints

1. `ctx_size >= min_ctx_size` (default 32768) — below this, coding agents are unusable
2. `ctx_size <= max_ctx_size` (default 131072) — no benefit exceeding this
3. `gpu_layers >= min_gpu_layers` (default 1, llamacpp only) — at least some GPU acceleration
4. `gpu_layers <= n_layers` — can't offload more layers than exist
5. Total estimated VRAM <= available VRAM (with safety margin)
6. User-provided fixed values override optimization but not physics

## Success Criteria

1. The tool produces values that do NOT cause the inference engine to OOM on startup
2. The tool finds a balanced tradeoff between speed and context — not simply maximizing one
3. The tool ensures usable context for coding agents (≥32K)
4. User-provided `--fixed-*` values are respected exactly
5. Runs in <10ms (called before every server start)
6. Output is machine-parseable (key=value or JSON)
7. Exits non-zero with diagnostic message if no valid configuration exists
8. Works with models not yet downloaded (fetches metadata from HF API)

## Empirical Data (for validation)

### Validated test case: llama.cpp on RTX 5090

| Field | Value |
|-------|-------|
| GPU | RTX 5090, 32607 MiB total, 163 MiB used by system |
| Model | Qwen3-Coder-Next Q4_K_M |
| model_size_bytes | 48,522,331,136 |
| n_layers | 48 |
| n_embd | 2048 |
| key_length | 256 |
| value_length | 256 |
| head_count_kv | 2 |
| full_attention_interval | 4 |
| kv_cache_type | f16 |
| Empirical: 30 layers, ctx 65536 | 30,508 MiB VRAM — works |
| Empirical: 31 layers, ctx 65536 | 31,344 MiB VRAM — works (ceiling) |
| Empirical: 40 layers, ctx 65536 | 37,176 MiB allocation — OOM |
| Empirical: 99 layers, ctx 65536 | 46,108 MiB allocation — OOM |
| Marginal per-layer cost | ~836 MiB (31344 - 30508) |
| Base cost (extrapolated to 0 layers) | ~5,428 MiB (includes KV + scratch) |
| KV cache at 64K (7 attn layers on GPU) | ~448 MiB |

The tool's output should be **at or below** empirical ceilings — conservative is a success, OOM is a failure.

### Approximate test cases (directional validation)

| Scenario | VRAM total (used) | Model Size | Layers | n_embd | Expected |
|----------|-------------------|------------|--------|--------|----------|
| RTX 5090, Qwen3-Coder-30B Q4_K_M | 32607 (163) | ~17000 MB | ~40 | ~4096 | all layers on GPU, large ctx |
| RTX 4090, Qwen3-32B Q4_K_M | 24576 (200) | ~19000 MB | ~64 | ~5120 | partial offload, ctx ≥ 32K |
| RTX 3060, 7B Q4_K_M | 12288 (300) | ~4500 MB | ~32 | ~4096 | all layers on GPU, large ctx |

## Non-Goals (explicit scope boundaries)

- Multi-GPU / tensor parallelism (v1 is single-GPU only)
- Runtime VRAM monitoring during inference
- Model recommendation ("which model fits my GPU?")
- Downloading models — the calling wrapper handles that
- Continuous/automatic rebalancing as VRAM usage changes
