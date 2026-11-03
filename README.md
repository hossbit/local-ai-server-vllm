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

Compare this managed vLLM server with running vLLM directly, SGLang's
server-focused inference framework, and Ollama's local model runner.

| Feature | **locallvllm** | Raw vLLM | SGLang | Ollama |
| --- | :---: | :---: | :---: | :---: |
| Easy setup | ✅ Guided CLI | ⚠️ Manual | ⚠️ Manual | ✅ Simple CLI |
| Text and multimodal | ✅ vLLM + Omni | ✅ Supported models | ✅ Supported models | ✅ Supported models |
| OpenAI-compatible API | ✅ | ✅ | ✅ | ✅ Subset |
| Linux service | ✅ Managed | ⚠️ Configure | ⚠️ Configure | ✅ Service |
| Separate vLLM + Omni | ✅ Managed | ⚠️ Separate setup | — Different engine | — Different engine |
| Monitoring | ✅ CLI + metrics | ✅ Metrics + tools | ✅ Server tools | ✅ CLI + API |
| Staged update rollback | ✅ Built in | ⚠️ Self-managed | ⚠️ Self-managed | — |

✅ Available or included · ⚠️ Requires extra setup or management · — Not a
matching feature in this comparison.

API endpoints, model support, hardware requirements, and performance vary by
version and configuration. Model downloads need network access; local inference
can run offline once the required files are available.

Sources: [vLLM documentation](https://docs.vllm.ai/),
[SGLang documentation](https://sgl-project.github.io/), and
[Ollama documentation](https://docs.ollama.com/).

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

[Hossbit installer hub](https://hossbit.github.io/#localvllm) · [Install script](https://hossbit.github.io/localvllm/install.sh)


**[Open the Local vLLM wiki guide](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md)** for installation options,
models, backend configuration, API examples, updates, and troubleshooting.

- [Model setup](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md#add-models) · [Full command reference](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM-Advanced.md#commands)
- [Configuration](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM-Advanced.md#configuration) · [Troubleshooting](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md#troubleshooting)
- [vLLM documentation](https://docs.vllm.ai/) · [vLLM-Omni documentation](https://docs.vllm.ai/projects/vllm-omni/)
- [Report an issue](https://github.com/hossbit/local-ai-server-vllm/issues)

## License

MIT. See [LICENSE](LICENSE).
