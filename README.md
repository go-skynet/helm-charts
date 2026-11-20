# Overview
Helm charts for go-skynet projects.

| Chart | Description |
|---|---|
| [local-ai](charts/local-ai) | [LocalAI](https://localai.io): standalone, distributed (frontends + workers) and P2P/federated deployments |

## LocalAI Installation

```bash
helm repo add go-skynet https://go-skynet.github.io/helm-charts/
helm repo update
helm show values go-skynet/local-ai > values.yaml   # edit as needed
helm install local-ai go-skynet/local-ai -f values.yaml
```

See the [chart README](charts/local-ai/README.md) for examples (GPU, distributed mode, P2P) and the
notes on upgrading from chart 3.x.

## Development

```bash
helm lint charts/local-ai --strict
ct lint --config ct.yaml                 # https://github.com/helm/chart-testing
helm template t charts/local-ai -f charts/local-ai/ci/distributed-values.yaml | kubeconform -strict -ignore-missing-schemas
```

Pull requests run `ct lint` and `ct install` on a kind cluster (`.github/workflows/lint-test.yaml`) with
the values files in `charts/local-ai/ci/`, and validate the renders of those and of
`charts/local-ai/ci-render/` (features kind can't run) with kubeconform, for the newest and the
oldest supported Kubernetes. Bump the chart `version` with every change.
