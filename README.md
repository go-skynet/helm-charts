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
  main:
    enabled: true
    replicaCount: 1
    #args:
    #  - --p2p # enable p2p mode
    env:
      P2P_TOKEN: ""
  worker:
    enabled: false
    replicaCount: 2
    # args:  # enable p2p worker mode
    #   - worker
    #   - p2p-llama-cpp-rpc
    #   - --llama-cpp-args=-m4096
    env:
      P2P_TOKEN: ""

  runtimeClassName: ""
  image:
    repository: quay.io/go-skynet/local-ai
    tag: latest
  pullPolicy: IfNotPresent
  modelsPath: "/models"
  imagePullSecrets: []
  prompt_templates:
    image: busybox

modelsConfigs: {}
# Example:
#   phi-2: |
#     name: phi-2
#     context_size: 2048
#     f16: true
#     mmap: true
#     trimsuffix:
#     - "\n"
#     parameters:
#       model: phi-2.Q8_0.gguf
#       temperature: 0.2
#       top_k: 40
#       top_p: 0.95
#       seed: -1
#     template:
#       chat: &template |-
#         Instruct: {{.Input}}
#         Output:
#       completion: *template

promptTemplates: {}
# Example:
#   ggml-gpt4all-j.tmpl: |
#     The prompt below is a question to answer, a task to complete, or a conversation to respond to; decide which and write an appropriate response.
#     ### Prompt:
#     {{.Input}}
#     ### Response:

resources:
  {}
  # We usually recommend not to specify default resources and to leave this as a conscious
  # choice for the user. This also increases chances charts run on environments with little
  # resources, such as Minikube. If you do want to specify resources, uncomment the following
  # lines, adjust them as necessary, and remove the curly braces after 'resources:'.
  # Example:
  #   limits:
  #     cpu: 100m
  #     memory: 128Mi
  #   requests:
  #     cpu: 100m
  #     memory: 128Mi

persistence:
  main:
    models:
      enabled: true
      annotations: {}
      storageClass: ""
      accessModes:
        - ReadWriteOnce
      size: 10Gi
      globalMount: /models
    output:
      enabled: true
      annotations: {}
      storageClass: ""
      accessModes:
        - ReadWriteOnce
      size: 5Gi
      globalMount: /tmp/generated
  worker:
    models:
      enabled: true
      annotations: {}
      storageClass: ""
      accessModes:
        - ReadWriteMany
      size: 10Gi
      globalMount: /models
    output:
      enabled: true
      annotations: {}
      storageClass: ""
      accessModes:
        - ReadWriteMany
      size: 5Gi
      globalMount: /tmp/generated

service:
  type: ClusterIP
  port: 80
  annotations: {}
  # If using an AWS load balancer, you'll need to override the default 60s load balancer idle timeout
  # service.beta.kubernetes.io/aws-load-balancer-connection-idle-timeout: "1200"

ingress:
  enabled: false
  className: ""
  annotations: {}
    # nginx.ingress.kubernetes.io/proxy-body-size: "25m" # This value determines the maxmimum uploadable file size
    # kubernetes.io/ingress.class: nginx
    # kubernetes.io/tls-acme: "true"
  hosts:
    - host: chart-example.local
      paths:
        - path: /
          pathType: ImplementationSpecific
  tls: []
  #  - secretName: chart-example-tls
  #    hosts:
  #      - chart-example.local

nodeSelector: {}
# Using Node Feature Discovery and the correct operator (e.g. nvidia-operator or intel-gpu-plugin), you can schedule nodes
#   nvidia.com/gpu.present: 'true'

tolerations: []

affinity: {}
# Example affinity that ensures no pods are scheduled on the same node:
#   podAntiAffinity:
#     requiredDuringSchedulingIgnoredDuringExecution:
#       - labelSelector:
#           matchExpressions:
#             - key: app.kubernetes.io/name
#               operator: In
#               values:
#                 - localai
#         topologyKey: kubernetes.io/hostname
EOF
```
Install the LocalAI chart:
```bash
helm install local-ai go-skynet/local-ai -f values.yaml
```

### Distributed Inference

LocalAI supports distributed inference with the `worker` deployment. This functionality enables LocalAI to distribute inference requests across multiple worker nodes, improving efficiency and performance. Nodes are automatically discovered and connect via P2P using a shared token, ensuring secure and private communication between the nodes in the network.

LocalAI supports two modes of distributed inference via P2P:

- **Federated Mode**: Requests are shared between the cluster and routed to a single worker node in the network based on the load balancer's decision.
- **Worker Mode** (aka "model sharding" or "splitting weights"): Requests are processed by all the workers, which contribute to the final inference result by sharing the model weights.

To enable distributed inference, set `deployment.worker.enabled` to `true` and specify the desired number of worker replicas in `deployment.worker.replicaCount`. Additionally, provide the same `P2P_TOKEN` in both the `deployment.main.env` and `deployment.worker.env` sections.

For more details on configuring and using distributed inference, refer to the [Distributed Inference documentation](https://localai.io/features/distribute/).
