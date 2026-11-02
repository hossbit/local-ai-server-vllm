# Local AI Server for vLLM

<div align="center">

![Linux](https://img.shields.io/badge/Linux-x86--64%20%7C%20ARM64-111827)
![vLLM](https://img.shields.io/badge/Engine-vLLM-6C5CE7)
![vLLM-Omni](https://img.shields.io/badge/Engine-vLLM--Omni-8B5CF6)
![CUDA](https://img.shields.io/badge/CUDA-supported-76B900)
![API](https://img.shields.io/badge/API-OpenAI--compatible-111827)
![Service](https://img.shields.io/badge/Service-systemd%20user-F59E0B)
![License](https://img.shields.io/badge/License-MIT-10B981)

</div>

Run [vLLM](https://github.com/vllm-project/vllm) and
[vLLM-Omni](https://github.com/vllm-project/vllm-omni) as two isolated local
OpenAI-compatible servers, managed by one small Bash CLI and two systemd user
services.

The repository directory is `localaivllm`; the installed command is
`localvllm`.

This project is deliberately vLLM-only. It borrows the operational
conveniences of [Local AI Server](https://github.com/hossbit/local-ai-server)
— installer, CLI, model discovery, per-model overrides, API keys, doctor,
suggestions, benchmarks, systemd — but uses vLLM's native server instead of
llama.cpp/llama-swap.

## Why Local AI Server for vLLM?

| Feature | **This project** | Raw vLLM | Ollama | LM Studio |
| --- | :---: | :---: | :---: | :---: |
| Runs fully locally and privately | ✅ | ✅ | ✅ | ✅ |
| Linux server + systemd user service | ✅ | ⚠️ manual | ⚠️ usually system-wide | ❌ desktop |
| Two isolated engines (text + omni) | ✅ | ⚠️ two manual servers | ⚠️ model-dependent | ❌ |
| Separate venv, models, ports, keys per backend | ✅ | ❌ | ❌ | ❌ |
| Per-model tuning files | ✅ | ⚠️ flags only | ⚠️ limited | ⚠️ GUI |
| Hardware-aware suggestions | ✅ | ❌ | ❌ | ⚠️ GUI |
| Live benchmark and Prometheus metrics | ✅ | ⚠️ flags/API | ⚠️ | ⚠️ |
| Atomic launcher + staged upgrades with rollback | ✅ | ❌ | ⚠️ | ❌ |
| Readable Bash, no extra runtime | ✅ | ❌ Python service | ❌ Go binary | ❌ Electron |
| OpenAI-compatible API | ✅ | ✅ | ✅ | ✅ |
| No API fees | ✅ | ✅ | ✅ | ✅ |

### Main advantage

> One small, auditable Bash manager gives you **plain vLLM for text and
> vLLM-Omni for multimodal generation**, each with its own environment,
> models, port, service, API key, and tuning — without hand-writing pip
> commands or systemd units.

## Support

If this project is useful, you can support its continued development:

<div align="center">
  <a href="https://buymeacoffee.com/mirhh">
    <img src="https://raw.githubusercontent.com/hossbit/mirassets/main/images/bmc-button.webp" alt="Buy me a coffee" width="300">
  </a>
</div>

⭐ Starring, sharing, and reporting reproducible issues also helps.

Repository: <https://github.com/hossbit/local-ai-server-vllm>

## Two isolated backends

| | `vllm` backend | `omni` backend |
| --- | --- | --- |
| Engine package | `vllm` | `vllm-omni` |
| Server flag | plain `vllm serve` | `vllm serve ... --omni` |
| Model root | `~/ai-vllm/models/vllm` | `~/ai-vllm/models/omni` |
| State/config | `conf/backends/vllm` | `conf/backends/omni` |
| Virtualenv | `venv/vllm` | `venv/omni` |
| Default port | `8000` | `8091` |
| systemd service | `localvllm.service` | `localvllm-omni.service` |
| API keys | independent | independent |
| Typical models | text, embeddings, reranking | text, image, audio, video, action |

Both can run at the same time if the GPU has enough VRAM for both. Every
command can target one backend:

```bash
localvllm --backend vllm models
localvllm --backend omni models
localvllm start all
localvllm status all
```

`localvllm` without `--backend` uses the configured default backend (`vllm`
unless changed with `localvllm backend default omni`).

## What it provides

- Two isolated vLLM environments with no shared Python packages
- OpenAI-compatible chat, completion, embedding, and (where supported) reranking APIs
- Optional vLLM-Omni serving through the same `vllm serve` entrypoint
- Per-backend model registries and per-model override files
- Automatic model discovery from each backend's model directory
- A systemd user service per backend
- A single `localvllm` CLI for start/stop, models, keys, doctor, update, uninstall
- Hardware-aware setting suggestions and a small live benchmark
- Optional vLLM sleep mode for releasing VRAM without stopping the process
- Atomic launcher generation and transactional `use` / key changes
- A global operation lock that prevents concurrent install/update/start/stop races
- Staged virtualenv upgrades with verification, `pip check`, and rollback
- Rotated per-backend logs instead of truncating the previous failure
- JSON output for `status`, `models`, and `doctor`; Prometheus metrics via `localvllm metrics`
- Explicit security refusal for insecure public listeners

## Requirements

- Linux x86-64 or ARM64 (Ubuntu, Debian, Fedora, RHEL, or compatible; hardware support depends on the vLLM wheel)
- Python 3.10 or newer with the `venv` module
- An NVIDIA GPU with a working driver for normal GPU serving
- ROCm is possible with a matching vLLM wheel; CPU is experimental
- For ROCm/CPU, set the vendor wheel index in `VLLM_PIP_ARGS` (and
  `VLLM_OMNI_PIP_ARGS` for Omni) before installing
- `sudo` access during installation for system packages
- Enough disk for two virtualenvs and the model weights
- Enough VRAM for the model(s) you select

The installer creates a virtualenv per backend and installs vLLM with `pip`.
It does not install a GPU driver or CUDA Toolkit.

## Install

From this checkout:

```bash
./install-localvllm.sh --all
```

Install only the plain vLLM backend:

```bash
./install-localvllm.sh --backend vllm
```

Install only vLLM-Omni:

```bash
./install-localvllm.sh --backend omni
```

Custom directory:

```bash
./install-localvllm.sh --dir ~/ai-vllm --all
```

One-line install from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/hossbit/local-ai-server-vllm/main/install.sh | bash -s -- --all
```

The default install directory is `~/ai-vllm`.

After installation:

```bash
localvllm backend list
localvllm doctor all
```

If the command is not found in the current terminal, run
`source ~/.bashrc` (or open a new terminal); the installer adds
`~/.local/bin` to PATH when needed.

## Add models

### Local Hugging Face models

For the `vllm` backend, put a complete Hugging Face model directory under:

```text
~/ai-vllm/models/vllm/
`-- Qwen3-8B/
    |-- config.json
    |-- tokenizer.json
    |-- tokenizer_config.json
    `-- model-00001-of-00004.safetensors ...
```

For the `omni` backend, use its own model root:

```text
~/ai-vllm/models/omni/
`-- Qwen3-Omni-30B-A3B-Instruct/
    |-- config.json
    `-- ...
```

vLLM-Omni models often have their own deployment recipes and stage
configuration. Keep any extra deployment files with the model directory and
pass model-specific flags through `EXTRA_ARGS` when needed.

List and select:

```bash
localvllm models
localvllm use Qwen3-8B
localvllm start

localvllm --backend omni models
localvllm --backend omni use Qwen3-Omni-30B-A3B-Instruct
localvllm start omni
```

### Hugging Face repo IDs

Selecting a repo id creates a small models.d entry and lets vLLM download it on
first start:

```bash
localvllm use Qwen/Qwen3-8B
localvllm --backend omni use Qwen/Qwen3-Omni-30B-A3B-Instruct
```

`/v1/models` uses the selected model ID as the served model name by default.
Override it per model with `SERVED_MODEL_NAME=...`.

For gated repositories, set a token in `conf/localvllm.conf`:

```bash
LOCALVLLM_HF_TOKEN="hf_..."
```

or export `HF_TOKEN` when starting the service.

### Local paths outside the model root

`localvllm use /absolute/path/to/model` works too. The path is written to the
backend's `models.d` entry, so it survives reloads.

### GGUF

vLLM has experimental GGUF support. Put a `.gguf` file in the backend's model
root and select it. If vLLM cannot infer the tokenizer, add:

```bash
TOKENIZER=/path/to/tokenizer
```

in the model override. For serious GGUF use, llama.cpp remains the better
engine; this project intentionally does not pretend otherwise.

## Commands

| Command | Purpose |
| --- | --- |
| `localvllm start [BACKEND\|all]` | Start one or both services. |
| `localvllm stop [BACKEND\|all]` | Stop services and release GPU memory. |
| `localvllm restart [BACKEND\|all]` | Restart services. |
| `localvllm reload [BACKEND\|all]` | Rescan models; restart only if a launcher changed. |
| `localvllm status [--json] [BACKEND\|all]` | Show service, process, model, port, and API status. |
| `localvllm check [--chat] [BACKEND\|all]` | Check `/health`, `/v1/models`, optionally chat. |
| `localvllm logs [BACKEND]` | Follow one service's current log (previous logs are rotated). |
| `localvllm metrics [--watch] [BACKEND]` | Show vLLM Prometheus metrics: queue, KV cache, throughput. |
| `localvllm models [--json] [BACKEND]` | List that backend's models. |
| `localvllm use MODEL` | Select the model for the current backend. |
| `localvllm load [MODEL]` | Start the service, or wake it from sleep mode. |
| `localvllm unload` | Sleep the model when sleep mode is on, else stop the service. |
| `localvllm ui [--open]` | Print vLLM API docs and OpenAI base URL. |
| `localvllm suggest [MODEL]` | Suggest TP, memory, context, and batching settings. |
| `localvllm suggest --benchmark MODEL` | Measure the running server. |
| `localvllm key ...` | Manage the current backend's active API key. |
| `localvllm backend list` | Show both backends, versions, ports, services, models. |
| `localvllm backend install NAME` | Install/repair one backend. |
| `localvllm backend default NAME` | Change the default backend. |
| `localvllm doctor [--json] [BACKEND\|all]` | Diagnose Python, vLLM, GPU, model, port, keys, pip consistency. |
| `localvllm update [--backend NAME\|all]` | Update packages and helper scripts. |
| `localvllm version [BACKEND\|all]` | Show versions and active models. |
| `localvllm uninstall` | Remove both backends; models are kept by default. |

Machine-readable output:

```bash
localvllm status --json all
localvllm models --json
localvllm doctor --json all
```

### Backend management

```bash
localvllm backend list
localvllm backend install omni
localvllm backend default omni
```

`backend list` shows an asterisk next to the default backend. Installing a
backend does not change the default. `backend install` is intended for an
existing installation and skips system-package installation; for a fresh
machine, run `install-localvllm.sh` instead.

### Running both at once

```bash
localvllm --backend vllm use Qwen/Qwen3-8B
localvllm --backend omni use Qwen/Qwen3-Omni-30B-A3B-Instruct
localvllm start all
localvllm check all
localvllm status all
```

Both services listen on loopback by default, on different ports. Check
`nvidia-smi` before starting both: two models can easily exceed one GPU's VRAM.

## Configuration

### Global defaults

Edit `~/ai-vllm/conf/localvllm.conf` for settings shared by both backends.
Per-backend ports and service names also live there:

```bash
LOCALVLLM_VLLM_PORT=8000
LOCALVLLM_OMNI_PORT=8091
LOCALVLLM_LISTEN_HOST=127.0.0.1
```

### Backend profiles

Backend-specific defaults live in:

```text
~/ai-vllm/conf/backends.d/vllm.conf
~/ai-vllm/conf/backends.d/omni.conf
```

They are sourced after the global config whenever that backend is activated.
Use them for differences between the two engines, for example:

```bash
# conf/backends.d/omni.conf
VLLM_OMNI=1
VLLM_MAX_MODEL_LEN=""
VLLM_TENSOR_PARALLEL_SIZE=1
VLLM_GPU_MEMORY_UTILIZATION=0.90
```

The backend identity is enforced: the `omni` backend always passes `--omni`,
and the `vllm` backend never does. A single omni-backend model can opt out with
`OMNI=0` in its override if it is really a text-only model.

### Per-model overrides

Create:

```text
~/ai-vllm/conf/backends/vllm/models.d/<model-id>.conf
~/ai-vllm/conf/backends/omni/models.d/<model-id>.conf
```

Example for a large text model:

```bash
TENSOR_PARALLEL_SIZE=2
GPU_MEMORY_UTILIZATION=0.92
MAX_MODEL_LEN=32768
MAX_NUM_SEQS=128
DTYPE=bfloat16
KV_CACHE_DTYPE=fp8
SERVED_MODEL_NAME="my-model"
REVISION="main"          # optional HF revision/branch/tag
CODE_REVISION="main"     # optional code revision for remote-code models
EXTRA_ARGS=(--enable-prefix-caching)
```

Example for an embedding model:

```bash
MODEL_TYPE=embedding
TASK=embed
MAX_MODEL_LEN=8192
MAX_NUM_BATCHED_TOKENS=2048
```

Example for a reranking model:

```bash
MODEL_TYPE=reranking
TASK=score
```

`EXTRA_ARGS` can be a plain string (`EXTRA_ARGS="--foo bar"`) or a Bash array
when a value contains spaces:

```bash
EXTRA_ARGS=(--rope-scaling '{"type":"yarn","factor":2.0}')
```

Use `EXTRA_ENV` for environment variables:

```bash
EXTRA_ENV=(VLLM_ATTENTION_BACKEND=FLASH_ATTN)
```

After editing, run:

```bash
localvllm --backend vllm reload
```

### Multi-GPU

```bash
TENSOR_PARALLEL_SIZE=2
LOCALVLLM_CUDA_VISIBLE_DEVICES=0,1
```

`LOCALVLLM_CUDA_VISIBLE_DEVICES` is global. A per-model `CUDA_VISIBLE_DEVICES`
override also works.

### Sleep mode (fast unload/wake)

vLLM can release GPU memory while keeping the process alive:

```bash
ENABLE_SLEEP=1
```

Then:

```bash
localvllm unload   # POST /sleep?level=1
localvllm load     # POST /wake_up
```

Sleep mode sets `VLLM_SERVER_DEV_MODE=1` in the generated launcher. That exposes
vLLM development endpoints; keep the listener on loopback and do not expose it
to an untrusted network.

### Model type and task

For names that do not make the model's purpose obvious:

```bash
MODEL_TYPE=chat|completion|embedding|reranking
TASK=auto|generate|embed|score|...
```

If `TASK` is empty, `embedding` models get `--task embed` and `reranking`
models get `--task score`. Set `TASK=auto` to let vLLM choose.

## Use the server

Each backend has its own base URL:

```text
vllm: http://127.0.0.1:8000/v1
omni: http://127.0.0.1:8091/v1
```

```bash
curl http://127.0.0.1:8000/v1/models

curl http://127.0.0.1:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3-8B",
    "messages": [{"role": "user", "content": "Reply with OK"}],
    "max_tokens": 16
  }'
```

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:8000/v1",
    api_key="not-needed",
)

response = client.chat.completions.create(
    model="Qwen3-8B",
    messages=[{"role": "user", "content": "Hello"}],
)
print(response.choices[0].message.content)
```

For the omni backend, use port `8091` and its served model name. vLLM-Omni's
supported request shapes depend on the model (chat, image, audio, video); see
the [vLLM-Omni documentation](https://docs.vllm.ai/projects/vllm-omni/).
`localvllm check` (without `--chat`) and `localvllm models` work for every
backend. The chat round-trip and benchmark helpers are text/embedding/rerank
oriented; for image, audio, or video generation use the endpoint documented by
that model's recipe.

### Web UI

vLLM does not ship a chat UI. `localvllm ui` prints:

- API docs: `http://127.0.0.1:8000/docs`
- OpenAI base URL: `http://127.0.0.1:8000/v1`

Point Open WebUI, LibreChat, or any OpenAI-compatible client at the base URL.

### Metrics

vLLM exposes Prometheus metrics. The CLI filters the useful vLLM series:

```bash
localvllm metrics vllm
localvllm metrics --watch omni
```

This shows request queue depth, running requests, KV-cache usage, and
throughput. Use it together with `nvidia-smi` when checking whether both
backends can coexist on one GPU.

## API keys

Each backend has its own key registry under
`conf/backends/<backend>/api-keys.tsv` (mode `0600`). vLLM supports one active
API key per server, so `create` refuses to add a second active key:

```bash
localvllm key create work-laptop
localvllm key list
localvllm key rotate <id>
localvllm key revoke <id>

localvllm --backend omni key create omni-laptop
```

The secret is printed once. Once a key is active, every `/v1` request needs:

```text
Authorization: Bearer sk-localvllm-...
```

Important vLLM limitation: the API key protects `/v1`, `/v2`, `/inference`, and
`/cohere`, but **not** `/health`, `/docs`, or development endpoints such as
`/sleep`. Keep `LOCALVLLM_LISTEN_HOST=127.0.0.1` unless you add TLS and a
reverse proxy with its own authentication.

`LOCALVLLM_REQUIRE_API_KEY=1` makes config generation refuse to produce an
unauthenticated launcher.

## Suggest and benchmark

```bash
localvllm suggest
localvllm suggest Qwen3-8B
localvllm suggest --benchmark Qwen3-8B --runs 3 --tokens 128
localvllm suggest --benchmark Qwen3-8B --json
```

Suggestions use the actual model directory size and detected RAM/VRAM. They
are starting points, not exact predictions: context length, KV cache type,
batching, CUDA graphs, and other workloads all change memory use.

The benchmark measures the running server with one warm-up and repeated
requests, and reports median wall time plus tokens/second from vLLM's `usage`
counts.

## Update

```bash
localvllm update                  # all installed backends + scripts
localvllm update --backend omni
localvllm update --scripts-only
localvllm update --vllm-only
```

vLLM and vLLM-Omni use separate virtualenvs, so upgrading one does not modify
the other. When pinning versions, keep vLLM-Omni on the matching vLLM release
line:

```bash
VLLM_VERSION=0.32.0 VLLM_OMNI_VERSION=0.32.0 localvllm backend install omni
```

Updates are staged into a copy of the backend virtualenv, verified with
`pip check` and an import test, then swapped in. If the new environment or the
restarted service fails, the previous environment is restored and restarted.
Running services are never pip-installed in place.

While developing from this checkout, point updates at it instead of the
repository URL:

```bash
LOCALVLLM_LOCAL_SOURCE_DIR="$PWD" localvllm update --scripts-only
```

The default update source is
`https://github.com/hossbit/local-ai-server-vllm.git`; override
`LOCALVLLM_REPO_URL` for a fork or mirror.

## Uninstall

```bash
localvllm uninstall                 # both backends; models are kept
localvllm uninstall --backend omni  # only the omni backend
localvllm uninstall --remove-models --remove-hf-cache --force
localvllm uninstall --keep-venv
```

## Troubleshooting

### `nvidia-smi` works but vLLM cannot use the GPU

Check the driver and the installed torch/CUDA build:

```bash
localvllm doctor all
venv/vllm/bin/python -c 'import torch; print(torch.cuda.is_available())'
```

### Out of memory during startup

Lower one or more of:

```bash
GPU_MEMORY_UTILIZATION=0.85
MAX_MODEL_LEN=4096
MAX_NUM_SEQS=64
```

For a model that still does not fit, use more GPUs:

```bash
TENSOR_PARALLEL_SIZE=2
```

or CPU offload:

```bash
CPU_OFFLOAD_GB=8
```

### Port already in use

The active port is stored per backend in
`conf/backends/<backend>/port`. Edit that file, or delete it and set the
default in `conf/localvllm.conf`:

```bash
LOCALVLLM_VLLM_PORT=8001
LOCALVLLM_OMNI_PORT=8092
```

Then run `localvllm reload` (or `localvllm restart <backend>`). The port is
read before the service starts, so changing the global default alone does not
move an already-installed backend.

### Model not found

```bash
localvllm models
localvllm use MODEL
```

For the omni backend, remember it reads `models/omni`, not `models/vllm`.

### vLLM-Omni installation or version mismatch

vLLM-Omni releases are aligned with vLLM minor versions. Check the
[vLLM-Omni installation guide](https://docs.vllm.ai/projects/vllm-omni/en/latest/getting_started/installation/)
and pin both versions when needed. The pip log is at
`~/ai-vllm/logs/pip-install-omni.log`.

### `use` succeeds but the launcher will not generate

The model must be a Hugging Face directory with `config.json` or a `.gguf`
file. Run `localvllm models` to see what was discovered. For remote models,
the first start downloads weights and can take a long time.

### Inspect logs

```bash
localvllm logs vllm
localvllm logs omni
localvllm --backend omni doctor
```

## Security

- Both services bind to `127.0.0.1` by default.
- vLLM's API key does not protect `/health`, `/docs`, or development endpoints.
- `start.sh` refuses a non-loopback listener without an active API key and
  `LOCALVLLM_ALLOW_INSECURE_PUBLIC=1`.
- Sleep/dev mode is refused on non-loopback listeners because `/sleep` and
  `/wake_up` are not protected by vLLM's API key.
- For LAN/WAN access, put a TLS-terminating reverse proxy in front and add
  authentication at the proxy.
- API keys are stored under `conf/backends/<backend>/` with mode `0600`; the
  generated launcher is mode `0700`.
- Request logging is disabled by default (`VLLM_DISABLE_LOG_REQUESTS=1`) so
  prompts are not written to logs unless you explicitly enable it.

## Documentation

- [vLLM documentation](https://docs.vllm.ai/)
- [vLLM-Omni documentation](https://docs.vllm.ai/projects/vllm-omni/)
- [vLLM-Omni recipes](https://recipes.vllm.ai)
- [Repository](https://github.com/hossbit/local-ai-server-vllm)
- [Issues](https://github.com/hossbit/local-ai-server-vllm/issues)

## Credits

This project is built on:

- [vLLM](https://github.com/vllm-project/vllm)
- [vLLM-Omni](https://github.com/vllm-project/vllm-omni)
- Operational patterns inspired by
  [Local AI Server](https://github.com/hossbit/local-ai-server)

## License

MIT. See [LICENSE](LICENSE).
