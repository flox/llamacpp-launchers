# llamacpp launchers

A Flox environment for running local GGUF models via llama-server and connecting them to coding agent harnesses. Runs on **Linux (x86_64, aarch64) with NVIDIA CUDA** and **macOS (Apple Silicon)**. Models are automatically downloaded from HuggingFace, GPU memory is auto-configured, and a translation proxy handles protocol differences so every harness works out of the box.

## Requirements

- [Flox](https://flox.dev) package manager
- **Linux**: NVIDIA GPU with CUDA support
- **macOS**: Apple Silicon (M1/M2/M3/M4/M5) with unified memory

## Quick start

```bash
flox activate
llamacpp launch claude --model qwen3-coder
```

This will:
1. Search HuggingFace for the best GGUF match and pin it for reproducibility
2. Query your GPU's available VRAM
3. Auto-configure optimal GPU layers and context size
4. Download the model (cached for future runs)
5. Start llama-server as a Flox service
6. Start the translation proxy
7. Launch Claude Code pointed at the local model (OAuth bypassed via `--bare`)

### Non-interactive usage

```bash
flox activate -- llamacpp launch claude --model qwen3-coder
```

The `llamacpp` command works both as an interactive shell function and as an executable on PATH.

## Supported harnesses

| Harness | Command | Protocol | Proxy? |
|---------|---------|----------|--------|
| Claude Code | `llamacpp launch claude --model <spec>` | Anthropic Messages | Yes |
| Codex | `llamacpp launch codex --model <spec>` | OpenAI Responses | Yes |
| Gemini CLI | `llamacpp launch gemini --model <spec>` | Gemini native | Yes |
| Crush | `llamacpp launch crush --model <spec>` | OpenAI-compat | Yes |
| DeepSeek TUI | `llamacpp launch deepseek --model <spec>` | OpenAI Chat | No |
| Aider | `llamacpp launch aider --model <spec>` | OpenAI Chat | No |
| OpenCode | `llamacpp launch opencode --model <spec>` | OpenAI Chat | No |

Harnesses that use standard OpenAI Chat Completions with function tools (aider, OpenCode, DeepSeek) talk directly to llama-server. The rest route through `llamacpp-proxy` which translates tool schemas and protocol formats.

### Passing harness-specific flags

Flags for the harness itself go after `--`:

```bash
llamacpp launch claude --model qwen3-coder -- --allowedTools "Bash(git *) Edit Read"
llamacpp launch codex --model qwen3-coder -- --sandbox workspace-write
llamacpp launch gemini --model qwen3-coder -- --sandbox=false
llamacpp launch deepseek --model qwen3-coder -- --yolo
```

### Claude Code

Claude Code is always launched with `--bare` to prevent OAuth conflicts when using local models. This disables OAuth/keychain lookups (irrelevant for local inference) and avoids the "Auth conflict" warning.

## Model management

```bash
llamacpp model search qwen3              # search HuggingFace for GGUF models
llamacpp model search devstral           # try different model families
llamacpp model pull unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_M
llamacpp model list                      # list downloaded models + active model
llamacpp model set <spec>                # set the active model for llama-server
llamacpp model remove <filename>         # delete a local GGUF
```

### Model spec formats

- `qwen3-coder` — search term, auto-resolves to best GGUF repo (prefers unsloth, bartowski)
- `unsloth/Qwen3-Coder-Next-GGUF:Q4_K_M` — HuggingFace repo with quantization
- `unsloth/Qwen3-Coder-Next-GGUF` — HuggingFace repo, defaults to Q4_K_M
- `/path/to/model.gguf` — local file

### Model pinning

When you use a search term (e.g., `qwen3-coder`), the first successful resolution is pinned to `$FLOX_ENV_CACHE/model-locks/`. Subsequent runs reuse the pinned result without re-searching HuggingFace, ensuring reproducible workflows.

```bash
llamacpp model pin qwen3-coder           # explicitly pin a search term
llamacpp model locks                     # list pinned search terms
```

## VRAM auto-configuration

Your GPU has a fixed amount of VRAM. Two things compete for it:

- **GPU layers** — how much of the model runs on GPU vs CPU. More layers on GPU = faster inference, but uses more VRAM. Layers that don't fit on GPU spill to CPU RAM and are much slower.
- **Context window** — how many tokens the model can see at once (conversation history + system prompt + files). Coding agents need at least 32K just for their system prompt. More context = the model can work with larger codebases, but uses more VRAM.

When `--gpu-layers` and `--ctx-size` are not specified, the wrapper calls `vram-optimizer` to find the best balance. The optimizer reads the GGUF tensor table for precise per-layer VRAM estimates, queries available memory (`nvidia-smi` on Linux/CUDA, unified memory on Apple Silicon), and scores candidate configurations.

### Context priority

```bash
llamacpp launch claude --model qwen3-coder                  # balanced (default)
llamacpp launch claude --model qwen3-coder --big-context    # prefer more context
llamacpp launch claude --model qwen3-coder --max-context    # maximum context window
```

| Flag | Effect |
|------|--------|
| (default) | Sweet spot between speed and context. Capped at 128K. |
| `--big-context` | Heavier context weight. Ceiling lifts to model's training context. |
| `--max-context` | Maximum context. Linear scoring, aggressively trades GPU layers for context. |

### Manual override

```bash
llamacpp launch claude --model qwen3-coder --gpu-layers 25 --ctx-size 65536
```

When you specify `--gpu-layers` or `--ctx-size`, the optimizer is bypassed and your values are used directly.

## Architecture

```
                              ┌──────────────┐
   Claude Code ──► Anthropic  │              │
   Codex ────────► Responses  │  llamacpp-   │     ┌──────────────┐
   Gemini CLI ──► Gemini API  │    proxy     │────►│ llama-server │
   Crush ────────► OpenAI     │  (port 8081) │     │  (port 8080) │
                              └──────────────┘     └──────────────┘
                                     ▲
   Aider ─────────────────────────────┘ (pass-through)
   OpenCode ──────────────────────────┘
   DeepSeek ──────────────────────────┘
```

### Packages

All components are published Flox packages installed via the manifest:

| Package | Source | Description |
|---------|--------|-------------|
| `flox-labs/llamacpp` | [flox-labs](https://flox.dev) | llama-server inference engine |
| `flox-labs/vram-optimizer` | Rust crate | VRAM budget calculator for gpu_layers + ctx_size |
| `flox-labs/llamacpp-proxy` | Rust crate | API translation proxy (Codex, Claude, Gemini, Ollama) |
| `llamacpp-launchers` | This repo (.flox/pkgs/) | Shell wrapper for model management and harness launch |

The launcher is installed as both:
- `$FLOX_ENV/share/llamacpp-launchers/llamacpp.sh` — sourced in `[profile]` for interactive shell functions
- `$FLOX_ENV/bin/llamacpp` — executable wrapper for non-interactive use

## Service management

```bash
flox services status                     # check running services
flox services logs llama-server          # server logs
flox services logs llamacpp-proxy        # proxy logs
flox services stop llama-server          # stop the server
flox services restart llama-server       # restart with new config
```

## Environment variables

All are optional. Set at activation time or via flags on `llamacpp launch`.

| Variable | Default | Description |
|----------|---------|-------------|
| `LLAMACPP_HOST` | `127.0.0.1` | Server bind address |
| `LLAMACPP_PORT` | `8080` | Server port |
| `LLAMACPP_PROXY_PORT` | `8081` | Proxy port |
| `LLAMACPP_MODEL_DIR` | `$FLOX_ENV_CACHE/models` | Model storage directory |
| `LLAMACPP_DEFAULT_QUANT` | `Q4_K_M` | Default quantization for HF downloads |
| `LLAMACPP_CTX_SIZE` | `65536` | Default context size |
| `LLAMACPP_GPU_LAYERS` | `99` | Default GPU layers |
| `LLAMACPP_API_KEY` | `llamacpp-local` | API key for server auth |
| `LLAMACPP_PREFERRED_ORGS` | `unsloth,bartowski,QuantFactory` | Preferred HF orgs for model search |
| `LLAMACPP_HEALTH_TIMEOUT` | `900` | Max seconds to wait for server ready |

## Getting help

```bash
readme                                   # display this README with syntax highlighting
llamacpp help                            # built-in command reference
```

## Choosing a model

Not sure which model to use? Here's a rough guide by VRAM:

| VRAM | Good fits | Notes |
|------|-----------|-------|
| 8-12 GB | 7B models (Q4_K_M) | Fast, fits entirely on GPU |
| 16-24 GB | 7-32B models (Q4_K_M) | Sweet spot for most coding tasks |
| 32 GB | 30-70B models (Q4_K_M), 235B MoE (partial) | Larger models need partial CPU offload |
| 48+ GB | 70B+ models (Q4_K_M-Q8_0) | Full GPU offload for large models |

Start with a model that fits entirely in VRAM for the best experience. Partial CPU offload works but slows inference significantly.

```bash
llamacpp model search qwen3-coder       # coding-focused models
llamacpp model search devstral          # Mistral's coding model
llamacpp model search deepseek-coder    # DeepSeek coding models
```

## Troubleshooting

**Model won't load (OOM)**
The model + context window exceeds GPU VRAM. Options:
- Let the optimizer decide: remove `--gpu-layers` and `--ctx-size` flags
- Use a smaller quantization: `--model <repo>:Q3_K_M`
- Reduce context: `--ctx-size 32768`
- Use a smaller model

**"Server ready" but harness errors on tool use**
The translation proxy may not be running. Check:
```bash
flox services status
flox services logs llamacpp-proxy
```

**Stale logs showing old errors**
`flox services logs` shows the full log history. Check `flox services status` for the actual current state — the server may be running fine despite old error lines in the log.

**"No model configured"**
Run `llamacpp model set <spec>` or use `llamacpp launch` which sets the model automatically.

**HuggingFace search fails**
Network issues or API rate limits. Use a pinned repo spec instead:
```bash
llamacpp launch claude --model unsloth/Qwen3-Coder-Next-GGUF:Q4_K_M
```

## Tested configurations

| Model | GPU | Layers | Context | Status |
|-------|-----|--------|---------|--------|
| Qwen3-Coder-Next Q4_K_M (235B MoE) | RTX 5090 32GB | 30 | 73K | Balanced default |
| Qwen3-Coder-Next Q4_K_M (235B MoE) | RTX 5090 32GB | 27 | 262K | Max context |
| Qwen3-Coder-Next Q4_K_M (235B MoE) | RTX 5090 32GB | 31 | 65K | Manual override |
| Qwen3-Coder-30B-A3B Q4_K_M | RTX 5090 32GB | 40 (all) | 131K | Fits entirely in VRAM |
