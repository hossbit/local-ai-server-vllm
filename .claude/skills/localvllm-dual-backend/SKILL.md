---
name: localvllm-dual-backend
description: Work on the Local vLLM manager (plain vLLM + vLLM-Omni as two isolated backends). Use for changes to the installer, CLI, per-backend paths, launcher generation, systemd services, keys, model discovery, doctor, suggest, update, or uninstall.
---

# Local vLLM dual-backend architecture

One manager (`localvllm`) owns two isolated engines:

| | `vllm` | `omni` |
| --- | --- | --- |
| package | `vllm` | `vllm-omni` |
| flag | plain `vllm serve` | `vllm serve ... --omni` |
| models | `<ai>/models/vllm` | `<ai>/models/omni` |
| state | `<ai>/conf/backends/vllm` | `<ai>/conf/backends/omni` |
| venv | `<ai>/venv/vllm` | `<ai>/venv/omni` |
| port | `LOCALVLLM_VLLM_PORT` (8000) | `LOCALVLLM_OMNI_PORT` (8091) |
| service | `localvllm.service` | `localvllm-omni.service` |

Global config: `conf/localvllm.conf`.
Backend defaults: `conf/backends.d/<backend>.conf`.
Per-model tuning: `conf/backends/<backend>/models.d/<model-id>.conf`.

## Invariants

1. **Activate a backend before using per-backend globals.**
   `localvllm_use_backend NAME` sets `CONF_DIR`, `MODELS_DIR`, `VENV_DIR`,
   `LOG_FILE`, `PORT_FILE`, `PID_FILE`, `SERVE_SH`, `SERVE_ENV`,
   `ACTIVE_MODEL_FILE`, `OVERRIDES_DIR`, `SERVICE_NAME`, `SERVICE_FILE`, and
   `LOCALVLLM_DEFAULT_PORT`. Do not hardcode a backend path elsewhere.

2. **Capture global runtime values once, before profiles.**
   `localvllm_capture_global_runtime` snapshots `VLLM_*` defaults. Each
   `localvllm_use_backend` resets those keys and then sources the backend
   profile, so switching backends cannot leak settings across engines.

3. **Backend identity is not a tuning knob.**
   `omni` always sets `VLLM_OMNI=1`; `vllm` always sets it to `0`. A single
   omni-backend model may opt out with `OMNI=0` in its override.

4. **Only one active API key per backend.** vLLM supports one key per server.
   `key create` refuses a second active key; `rotate` replaces one. Secrets are
   rendered only into `serve.sh` (mode 0700) and never into `serve.env`.

5. **vLLM serves one model per process.** `use` selects, `reload` regenerates,
   `stop` releases the GPU. `unload` sleeps (when `ENABLE_SLEEP=1`) or stops.

6. **Validate before writing.** `rebuild-config.sh` writes candidates and only
   `mv`s them into place after validation. Keep that property; a broken
   override must never truncate the working launcher.

7. **vLLM API keys do not protect `/health`, `/docs`, or `/sleep`.** Keep the
   listener on loopback or require a reverse proxy; `doctor` warns otherwise.

## Launcher generation

`rebuild-config.sh [--backend NAME] [SERVE_SH] [SERVE_ENV]`:

- resolves the active model and sources its override;
- validates model, TP, memory, context, dtype, quantization, KV cache, task,
  extra args, extra env, and API-key registry;
- emits a self-contained `serve.sh` that `exec`s the backend venv's `vllm`;
- emits `serve.env` with metadata (no secrets).

`serve.sh` is the only place that should contain `VLLM_API_KEY` or `HF_TOKEN`.

## Testing

```bash
shellcheck -x localvllm install.sh install-localvllm.sh start.sh stop.sh \
  rebuild-config.sh update-localvllm.sh uninstall-localvllm.sh \
  lib/*.sh lib/cli/*.sh
bats tests
```

Useful manual smokes:

- Create a temp `LOCALVLLM_DIR`, fake model directories, and run
  `./localvllm models`, `use`, `suggest`, `key create`.
- Fake a venv (`venv/<backend>/bin/{python,pip,vllm}`) to exercise the
  installer/update paths without downloading vLLM.
- Fake a `vllm` executable that serves `/health` and `/v1/models` to exercise
  `start.sh`/`stop.sh`/`check` without a GPU.

## Common pitfalls

- `SCRIPT_DIR` in installed scripts is `<ai>/bin`; config is in
  `<ai>/conf` and libraries in `<ai>/lib`. Source both `../conf` and `../lib`.
- `localvllm backend install` calls the installed installer with `--skip-system`
  and `--dir <ai>`; keep that behavior.
- `localvllm update` must preserve the configured default backend and runtime
  tuning. `append_runtime_tuning` skips `${...}` expressions and only carries
  forward concrete user values.
- The `omni` backend's venv contains both `vllm` and `vllm-omni`; keep their
  versions on the same release line.
