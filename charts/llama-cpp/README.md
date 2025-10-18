# Llama.cpp Helm Chart

A Helm chart for deploying Llama.cpp server on Kubernetes with GPU support.

## Introduction

This chart bootstraps a Llama.cpp deployment on a Kubernetes cluster using the Helm package manager.

## Prerequisites

- Kubernetes 1.19+
- Helm 3+
- NVIDIA GPU Operator (for GPU support)
- GPU-enabled nodes with nvidia.com/gpu resource available

## Installing the Chart

To install the chart with the release name `my-release`:

```bash
helm install my-release ./charts/llama-cpp
```

## Configuration

The following table lists the configurable parameters of the chart and their default values:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `llm.host` | Hostname for the LLM service | `llm.hnatekmar.dev` |
| `llm.vllm.image` | Docker image for vLLM | `gitea.hnatekmar.xyz/public/vllm:qwen3-vl` |
| `llm.llama_cpp.image` | Docker image for Llama.cpp (GPU) | `ghcr.io/ggml-org/llama.cpp:server-cuda` |
| `llm.llama_cpp.cpuImage` | Docker image for Llama.cpp (CPU) | `ghcr.io/ggml-org/llama.cpp:server` |
| `ingress.host` | Hostname for ingress controller | `llama.hnatekmar.dev` |

### Model Configuration

Multiple models can be configured under the `models` section. Each model supports the following parameters:

- `name`: Name of the model
- `args`: Arguments to pass to the Llama.cpp server
- `selector`: Node selector for scheduling
- `replicas`: Number of replica pods
- `resources`: Resource requests and limits (GPU)
- `cpuResources`: Resource requests and limits (CPU)
- `device`: Device type ('gpu' or 'cpu')
- `cooldownPeriod`: Time in seconds to wait before scaling down

## Usage Examples

### GPU Model Configuration

```yaml
models:
  - name: qwen3
    args:
      - --jinja
      - "-m"
      - "/models/gguf/Qwen3-32B-Q5_K_M.gguf"
      - "-ngl"
      - "99"
    replicas: 3
    resources:
      requests:
        nvidia.com/gpu: 1
      limits:
        nvidia.com/gpu: 1
    cooldownPeriod: 120
```

### CPU Model Configuration

```yaml
models:
  - name: qwen3-cpu
    device: cpu
    args:
      - --jinja
      - "-m"
      - "/models/gguf/Qwen3-32B-Q5_K_M.gguf"
    cpuResources:
      requests:
        cpu: "4"
        memory: "16Gi"
      limits:
        cpu: "8"
        memory: "32Gi"
    replicas: 3
    cooldownPeriod: 120
```

## Uninstalling the Chart

To uninstall the `my-release` deployment:

```bash
helm uninstall my-release
```