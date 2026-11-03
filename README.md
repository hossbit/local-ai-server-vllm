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

## Get started

On a supported Linux computer with an NVIDIA GPU and working driver, run:

```bash
curl -fsSL https://hossbit.github.io/localvllm/install.sh | bash
```

The installer automatically creates the Python environment and installs the text
engine; you do not need to install vLLM yourself. It may ask for sudo and can
take time and disk space. Then open a new terminal and run:

```bash
localvllm setup
```

The guided setup helps you choose text or multimodal, installs the multimodal
engine if needed, and asks for a model. Model weights download on first start;
choose a model that fits your GPU. Use `localvllm status` to check the server
and `localvllm ui` to find its API documentation. The project currently provides
a command-line interface and API documentation, not a graphical chat app.

For AMD, CPU, or advanced setups, see the [installation guide](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md#install).

## Why Local AI Server for vLLM?

Compare this managed vLLM server with running vLLM directly, SGLang's
server-focused inference framework, and Ollama's local model runner.

| Feature | **locallvllm** | Raw vLLM | SGLang | Ollama |
| --- | --- | --- | --- | --- |
| Best for | Easier vLLM server management | Direct vLLM control | Scalable model serving | Simple local model running |
| Setup | Guided CLI; installs the engine | Manual installation and configuration | Manual installation and configuration | Install and run a model |
| Text and multimodal | vLLM + optional vLLM-Omni | Supported vLLM models; Omni separate | Supported models; Omni separate | Depends on model |
| OpenAI-compatible API | Yes | Yes | Yes | Yes; subset |
| Linux service management | Built-in service setup and CLI | Configure separately | Configure separately | Linux service |
| Monitoring and recovery | Status, logs, benchmark, metrics and update rollback | Metrics and benchmark tools | Server monitoring tools | CLI and API information |

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

- Linux x86-64 or ARM64, Python 3.10+ with `venv`, and enough disk space.
- An NVIDIA GPU with a working driver and enough VRAM for your chosen model is
  recommended. ROCm needs compatible wheels; CPU support is experimental.
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
which uses llama.cpp. [GGUF details](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md#gguf-models).

## Security

Servers listen on `127.0.0.1` by default. API keys do not protect every vLLM
endpoint. For network access, use a TLS reverse proxy with authentication.
Read the [security guide](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md#security) before exposing a server.

## Documentation

[Hossbit installer hub](https://hossbit.github.io/#localvllm) · [Install script](https://hossbit.github.io/localvllm/install.sh)


**[Open the Local vLLM wiki guide](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md)** for installation options,
models, backend configuration, API examples, updates, and troubleshooting.

- [Model setup](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md#add-models) · [Full command reference](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md#commands)
- [Configuration](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md#configuration) · [Troubleshooting](https://github.com/hossbit/comai-linux-assistant-wiki/blob/main/Local-vLLM.md#troubleshooting)
- [vLLM documentation](https://docs.vllm.ai/) · [vLLM-Omni documentation](https://docs.vllm.ai/projects/vllm-omni/)
- [Report an issue](https://github.com/hossbit/local-ai-server-vllm/issues)

## Support

If this project is useful, you can [support its development](https://buymeacoffee.com/mirhh).

## License

MIT. See [LICENSE](LICENSE).
