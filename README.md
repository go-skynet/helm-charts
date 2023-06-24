# Overview
Helm charts for go-skynet projects.

## LocalAI Installation
Add the go-skynet helm repo:
```bash
helm repo add go-skynet https://go-skynet.github.io/helm-charts/
```

Create a `values.yaml` file for the LocalAI chart and customize as needed:
```bash
cat <<EOF > values.yaml
deployment:
  image: quay.io/go-skynet/local-ai:latest
  env:
    threads: 14
    contextSize: 512
    modelsPath: "/models"
    rebuild: true
# Optionally create a PVC, mount the PV to the LocalAI Deployment,
# and download a model to prepopulate the models directory
modelsVolume:
  enabled: true
  url: "https://gpt4all.io/models/ggml-gpt4all-j.bin"
  pvc:
    size: 6Gi
    accessModes:
    - ReadWriteOnce
    # Optional
    # storageClassName: ""
  auth:
    # Optional value for HTTP basic access authentication header
    basic: "" # 'username:password' base64 encoded
service:
  type: ClusterIP
  annotations: {}
  # If using an AWS load balancer, you'll need to override the default 60s load balancer idle timeout
  # service.beta.kubernetes.io/aws-load-balancer-connection-idle-timeout: "1200"
```
Install the LocalAI chart:
```bash
helm install local-ai go-skynet/local-ai -f values.yaml
```
