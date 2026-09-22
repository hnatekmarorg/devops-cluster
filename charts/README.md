# Charts Overview
- **`cluster-base`**: Deploys the foundational infrastructure for a cluster (cert-manager, External Secrets, MetalLB, nginx ingress, storage, Crossplane, RBAC) — and monitoring + alerting, per cluster (see `cluster-base/README.md`).
- **`llama-cpp`**: Deploys llm models with GPU/CPU support, including automatic scaling and ingress integration.
- **`vllm-proxy`**: Deploys a keep-alive proxy for vLLM servers with automatic TLS and ingress configuration per endpoint.
