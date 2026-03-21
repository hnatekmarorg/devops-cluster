# vllm-proxy Helm Chart

Deploys a keep-alive proxy for vLLM servers with automatic TLS certificate management and ingress configuration.

## Description

This chart deploys a Node.js-based HTTP proxy that:
- Proxies requests to vLLM backend servers
- Injects SSE keep-alive comments for streaming responses to prevent SDK watchdog timeouts
- Automatically provisions TLS certificates via cert-manager
- Supports multiple vLLM endpoints with separate ingress domains

## Installation

```bash
helm install my-vllm-proxy ./charts/vllm-proxy -f values.yaml
```

## Configuration

### Basic Usage - Single Endpoint

```yaml
proxyEndpoints:
  - endpoint: http://vllm-model-1:8080
    ingress:
      host: model1.hnatekmar.dev
```

### Multiple Endpoints

```yaml
proxyEndpoints:
  - endpoint: http://vllm-model-1:8080
    ingress:
      host: model1.hnatekmar.dev

  - endpoint: http://vllm-model-2:8080
    ingress:
      host: model2.hnatekmar.dev

  - endpoint: http://vllm-model-3:8080
    ingress:
      host: model3.hnatekmar.dev
      path: /api
      pathType: Prefix
```

### Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `proxyEndpoints` | List of vLLM endpoints to proxy | See below |
| `proxyEndpoints[].endpoint` | URL of the vLLM server | Required |
| `proxyEndpoints[].ingress.host` | Domain name for the endpoint | Required |
| `proxyEndpoints[].ingress.path` | Ingress path prefix | `/` |
| `proxyEndpoints[].ingress.pathType` | Ingress path type | `Prefix` |
| `proxy.image` | Proxy container image | `node:20-alpine` |
| `proxy.port` | Port the proxy listens on | `8001` |
| `proxy.replicas` | Number of proxy replicas | `1` |
| `proxy.resources` | Resource requests/limits | See values.yaml |
| `ingress.annotations` | Ingress annotations | See values.yaml |
| `ingress.className` | Ingress class name | `nginx` |
| `ingress.clusterIssuer` | cert-manager cluster issuer | `letsencrypt-cloudflare` |
| `ingress.tlsSecretName` | Custom TLS secret name | `{host}-tls` |

## How It Works

The proxy maintains a mapping of ingress hosts to vLLM endpoints. When a request arrives:

1. It extracts the `Host` header from the incoming request
2. Looks up the corresponding vLLM endpoint from the configuration
3. Forwards the request to the vLLM server
4. For streaming responses (`text/event-stream`), injects keep-alive comments every 5 seconds to prevent SDK watchdog timeouts
5. Pipes all other data transparently between client and vLLM

## Example: Deploying with Custom Values

```bash
# Create a custom values file
cat > my-values.yaml << EOF
proxyEndpoints:
  - endpoint: http://vllm-qwen:8080
    ingress:
      host: qwen.hnatekmar.dev
  - endpoint: http://vllm-llama:8080
    ingress:
      host: llama.hnatekmar.dev

proxy:
  replicas: 2
  resources:
    requests:
      cpu: "200m"
      memory: "256Mi"
    limits:
      cpu: "1"
      memory: "512Mi"
EOF

# Install the chart
helm install my-proxy ./charts/vllm-proxy -f my-values.yaml
```

## Troubleshooting

### Proxy not connecting to vLLM

Check that the vLLM service is reachable from the proxy pod:

```bash
kubectl exec -it <proxy-pod> -- wget -qO- http://vllm-model-1:8080/health
```

### TLS certificate not issued

Check cert-manager logs:

```bash
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager
```

### Streaming issues

Verify the proxy is injecting keep-alives:

```bash
kubectl logs -l app.kubernetes.io/name=vllm-proxy
```
