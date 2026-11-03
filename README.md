# Local AI Server for vLLM

<div align="center">
  <img src="https://raw.githubusercontent.com/hossbit/mirassets/main/images/localvllm-hero.webp" alt="Local vLLM: two engines, one simple CLI" width="900">
</div>

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

Use it on a supported workstation or GPU server, including multi-GPU systems
for large models. Context length, batching, GPU placement, and parallelism are
configurable per model; the defaults are starting points. See the
[large-model and multi-GPU guide](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM-Advanced.md#multi-gpu).

This project is deliberately vLLM-only. It borrows the operational
conveniences of [Local AI Server](https://github.com/hossbit/local-ai-server)
— installer, CLI, model discovery, per-model overrides, API keys, doctor,
suggestions, benchmarks, systemd — but uses vLLM's native server instead of
llama.cpp/llama-swap.

<div align="center">
  <a href="https://github.com/hossbit/local-ai-server-vllm/releases/latest"><img src="https://raw.githubusercontent.com/hossbit/mirassets/main/images/localvllm-badge-release.svg" alt="Latest release" height="68"></a>
  <a href="https://github.com/hossbit/local-ai-server-vllm/pulse"><img src="https://raw.githubusercontent.com/hossbit/mirassets/main/images/localvllm-badge-download.svg" alt="Recorded repository clones" height="68"></a>
  <a href="https://github.com/hossbit/local-ai-server-vllm/stargazers"><img src="https://raw.githubusercontent.com/hossbit/mirassets/main/images/localvllm-badge-stars.svg" alt="GitHub stars" height="68"></a>
</div>

The clone badge counts recorded repository clones, not unique users or release
asset downloads. Its total starts when badge tracking began.

## ❤️ Support

If you find Local vLLM useful, you can support its continued development:

<div align="center">
  <a href="https://buymeacoffee.com/mirhh">
    <img src="https://raw.githubusercontent.com/hossbit/mirassets/main/images/bmc-button.webp" alt="Buy me a coffee" width="300">
  </a>
</div>

⭐ Starring and sharing the repository also helps.

## Get started

On a supported Linux computer with an NVIDIA GPU and working driver, run:

```bash
curl -fsSL https://hossbit.github.io/localvllm/install.sh | bash
```

The installer sets up the text engine automatically. If a compatible Python is
missing, it also downloads an isolated Python 3.12 without changing your system
Python. Installation may request sudo and needs internet and disk space. Then open a new terminal and run:

```bash
localvllm setup
```

The guided setup helps you choose text or multimodal, installs the multimodal
engine if needed, and asks for a model. Model weights download on first start;
choose a model that fits your GPU. Use `localvllm status` to check the server
and `localvllm ui` to find its API documentation. The project currently provides
a command-line interface and API documentation, not a graphical chat app.

Already installed and Omni reports a Python error? Run `localvllm update
--scripts-only`, then retry `localvllm backend install omni`.

For AMD, CPU, ARM64, or advanced setups, see the [installation guide](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md#amd-and-cpu-installation).

## Why Local AI Server for vLLM?

Compare this managed vLLM server with vLLM, SGLang, Ollama, and Unsloth.
Unsloth also focuses on model training, while this project focuses on serving.

| Feature | **locallvllm** | Raw vLLM | SGLang | Ollama | Unsloth |
| --- | :---: | :---: | :---: | :---: | :---: |
| Easy setup | ✅ Guided CLI | ⚠️ Manual | ⚠️ Manual | ✅ Simple CLI | ✅ Studio UI |
| Text and multimodal | ✅ vLLM + Omni | ✅ Supported models | ✅ Supported models | ✅ Supported models | ✅ Supported models |
| OpenAI-compatible API | ✅ | ✅ | ✅ | ✅ Subset | ✅ Studio |
| Fine-tuning | — External tools | — External tools | ⚠️ Training integrations | — External tools | ✅ Built in |
| Linux service | ✅ Managed | ⚠️ Configure | ⚠️ Configure | ✅ Service | ⚠️ Configure |
| Separate vLLM + Omni | ✅ Managed | ⚠️ Separate setup | — Different engine | — Different engine | — Different workflow |
| Monitoring | ✅ CLI + metrics | ✅ Metrics + tools | ✅ Server tools | ✅ CLI + API | ✅ Training UI |
| Staged update rollback | ✅ Built in | ⚠️ Self-managed | ⚠️ Self-managed | — | — |

✅ Available or included · ⚠️ Requires extra setup or management · — Not a
matching feature here or handled by separate tools.

API endpoints, model support, hardware requirements, and performance vary by
version and configuration. Model downloads need network access; local inference
can run offline once the required files are available.

Sources: [vLLM documentation](https://docs.vllm.ai/),
[SGLang documentation](https://sgl-project.github.io/),
[Ollama documentation](https://docs.ollama.com/), and
[Unsloth](https://github.com/unslothai/unsloth).

### Main advantage

> One small, auditable Bash manager gives you **plain vLLM for text and
> vLLM-Omni for multimodal generation**, each with its own environment,
> models, port, service, API key, and tuning — without hand-writing pip
> commands or systemd units.

## Requirements

- Linux x86-64 or ARM64 and enough disk space. New environments use Python
  3.11–3.13; the installer can provide an isolated Python 3.12 if needed.
- An NVIDIA GPU with a working driver and enough VRAM for your chosen model is
  recommended. ROCm needs compatible wheels; CPU support is experimental.
  Fedora/RHEL and ARM64 availability depends on upstream packages and drivers.
- The installer may need `sudo` for system packages. It does not install GPU
  drivers. See the [full requirements](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md#requirements).

## Common commands

```bash
localvllm setup                 # Guided setup and model selection
localvllm status                # Check the selected backend
localvllm models                # List models
localvllm start                 # Start the server
localvllm stop                  # Stop the server
localvllm ui                    # Print API and documentation URLs
localvllm doctor all            # Diagnose both backends
localvllm backend install omni  # Add vLLM-Omni later
```

The default backend is `vllm`. Use `localvllm --backend omni` to target Omni.
For GGUF models, consider [Local AI Server](https://github.com/hossbit/local-ai-server),
which uses llama.cpp. [GGUF details](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM-Advanced.md#gguf-models).

## Security

Servers listen on `127.0.0.1` by default. API keys do not protect every vLLM
endpoint. For network access, use a TLS reverse proxy with authentication.
Read the [security guide](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md#security) before exposing a server.

## Documentation

- [Getting started](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md) — install, choose a model, and run the server.
- [AMD, CPU, and ARM64 setup](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md#amd-and-cpu-installation) — hardware-specific guidance.
- [Commands](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM-Advanced.md#commands) and [configuration](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM-Advanced.md#configuration) — full reference and tuning options.
- [Troubleshooting](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md#troubleshooting) — installation and runtime help.
- [vLLM](https://docs.vllm.ai/) and [vLLM-Omni](https://docs.vllm.ai/projects/vllm-omni/) — upstream documentation.

[Installer hub](https://hossbit.github.io/#localvllm) · [Report an issue](https://github.com/hossbit/local-ai-server-vllm/issues)

## License

MIT. See [LICENSE](LICENSE).
