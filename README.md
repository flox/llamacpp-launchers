# llamacpp

A Flox environment for running local GGUF models via llama-server and connecting them to coding agent harnesses. Models are automatically downloaded from HuggingFace, VRAM is auto-configured for your GPU, and a translation proxy handles protocol differences so every harness works out of the box.

## Requirements

- NVIDIA GPU with CUDA support (tested on RTX 5090 32GB)
- [Flox](https://flox.dev) package manager

## Quick start

```bash
flox activate
llamacpp launch claude --model qwen3-coder
```

This will:
1. Search HuggingFace for the best GGUF match
2. Query your GPU's available VRAM
3. Auto-configure optimal GPU layers and context size
4. Download the model (cached for future runs)
5. Start llama-server as a Flox service
6. Start the translation proxy
7. Launch Claude Code pointed at the local model

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

## VRAM auto-configuration

When `--gpu-layers` and `--ctx-size` are not specified, the wrapper calls `vram-optimizer` to determine the best balance between inference speed (GPU layers) and context window size. The optimizer reads the GGUF tensor table for precise per-layer VRAM estimates.

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

### Components

- **bin/llamacpp** — Shell wrapper sourced in `[profile]`. Defines the `llamacpp` function with model management, server lifecycle, VRAM optimization, and harness launch subcommands.
- **llama-server** — Flox service. Reads model and config from `$FLOX_ENV_CACHE/llama-server.model` and `$FLOX_ENV_CACHE/llama-server.env`.
- **llamacpp-proxy** — Flox service. Translates Codex namespace tools, Claude Code schemas, Gemini protocol, and Ollama API to formats llama-server accepts.
- **vram-optimizer** — Rust CLI. Reads GGUF tensor tables and GPU VRAM to recommend `gpu_layers` and `ctx_size`.

### External repos

| Repo | Description |
|------|-------------|
| `/home/daedalus/dev/vram-optimizer` | VRAM budget calculator (Rust) |
| `/home/daedalus/dev/llamacpp-proxy` | API translation proxy (Rust) |

Both will be packaged as Flox packages and available on PATH from the nix store. The current dev paths in `[profile]` are temporary.

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

## Auto re-source

The wrapper tracks its own file modification time. If `bin/llamacpp` is edited while the shell is active, the next `llamacpp` invocation automatically re-sources the updated script. No need to exit and re-enter the environment.

## Tested configurations

| Model | GPU | Layers | Context | Status |
|-------|-----|--------|---------|--------|
| Qwen3-Coder-Next Q4_K_M (235B MoE) | RTX 5090 32GB | 30 | 73K | Balanced default |
| Qwen3-Coder-Next Q4_K_M (235B MoE) | RTX 5090 32GB | 27 | 262K | Max context |
| Qwen3-Coder-Next Q4_K_M (235B MoE) | RTX 5090 32GB | 31 | 65K | Manual override |
| Qwen3-Coder-30B-A3B Q4_K_M | RTX 5090 32GB | 40 (all) | 131K | Fits entirely in VRAM |
