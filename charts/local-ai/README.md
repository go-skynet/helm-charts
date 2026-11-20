# LocalAI Helm chart

Deploys [LocalAI](https://localai.io) to Kubernetes, in any of its topologies:

| `mode` | What runs |
|---|---|
| `standalone` (default) | One LocalAI server (API + web UI) with persistent models, backends and data. |
| `distributed` | Stateless frontends routing to pools of workers, coordinated through PostgreSQL and NATS ([docs](https://localai.io/administration/distributed-mode/)). Optional chat workers, agent worker and a dedicated add-on owner. |
| `p2p` | Peer-to-peer / federated inference over a shared token ([docs](https://localai.io/administration/p2p-federated-inference/)), with llama.cpp P2P workers, a federated load balancer and the network explorer. |

Chart version 4.x deploys LocalAI v5 and needs Kubernetes 1.27 or later. See
[Upgrading from 3.x](#upgrading-from-3x).

## Install

```bash
helm repo add go-skynet https://go-skynet.github.io/helm-charts/
helm repo update
helm install local-ai go-skynet/local-ai            # add -f my-values.yaml for the examples below
kubectl port-forward svc/local-ai 8080:8080
curl http://localhost:8080/readyz
```

Resource names start with the release's full name, written `<fullname>` below: the release name
when it contains `local-ai` (as above), otherwise `<release>-local-ai`.

LocalAI starts with authentication off: anyone who reaches the service, including any pod in the
cluster, is an administrator, and administrators can run code in the pod (by installing backends).
Before exposing it, set API keys or user accounts. With an API key:

```bash
kubectl create secret generic local-ai-api-key --from-literal=api-key="$(openssl rand -hex 32)"
helm upgrade local-ai go-skynet/local-ai --reuse-values --set apiKey.existingSecret=local-ai-api-key
KEY=$(kubectl get secret local-ai-api-key -o jsonpath='{.data.api-key}' | base64 -d)
curl -H "Authorization: Bearer $KEY" http://localhost:8080/v1/models
```

With user accounts (`auth.enabled: true`, always on in distributed mode), the first account that
signs up becomes an administrator, in every `auth.registrationMode` (`invite` too). Create it
through the port-forward before you expose the service. `auth.adminEmail` makes whoever signs up
with that email an administrator, and local sign-up doesn't verify emails: use it only with
`auth.disableLocalAuth: true` (OIDC/GitHub sign-in only).

The first start can take a while. LocalAI writes its configuration, then downloads any models listed
in `frontend.models`. Backends (inference engines) are downloaded the first time a model needs them,
so the pod needs egress to `quay.io`, unless you preinstall them.

## Examples

Put an example in a file and pass it with `helm install local-ai go-skynet/local-ai -f my-values.yaml`.

### Standalone with an NVIDIA GPU

```yaml
image:
  variant: gpu-nvidia-cuda-12     # gpu-nvidia-cuda-13, gpu-hipblas, gpu-intel, gpu-vulkan, nvidia-l4t-arm64, ...
frontend:
  models: [qwen3-4b]              # gallery names, URLs, huggingface:// oci:// ollama:// references
  runtimeClassName: nvidia        # if your cluster uses one
  shareProcessNamespace: true     # a process reaper, which nvidia-smi needs (LocalAI runs as PID 1)
  resources:
    limits:
      nvidia.com/gpu: 1
apiKey:
  existingSecret: local-ai-api-key
```

AMD: `variant: gpu-hipblas` with `amd.com/gpu: 1` (AMD device plugin). Intel: `variant: gpu-intel`
with `gpu.intel.com/i915: 1`, and set `mmap: false` in model configs (SYCL).

### Distributed

```yaml
mode: distributed
postgresql: {enabled: true}       # or auth.database.existingSecret + collections.database.existingSecret
nats: {enabled: true}             # or distributed.nats.url / existingSecret
frontend:
  replicaCount: 2
  strategy:                       # safe with ReadWriteMany volumes and several frontends (or addonOwner)
    type: RollingUpdate
    rollingUpdate: {maxSurge: 25%, maxUnavailable: 25%}
persistence:                      # frontends share their volumes: use ReadWriteMany storage
  models: {accessModes: [ReadWriteMany], storageClass: nfs}
  backends: {accessModes: [ReadWriteMany], storageClass: nfs}
  data: {accessModes: [ReadWriteMany], storageClass: nfs}
workers:
  - name: cpu
    replicaCount: 2
    env:
      LOCALAI_NODE_LABELS: tier=cpu   # LocalAI scheduling labels for model rules, not Kubernetes node labels
  - name: gpu
    image: {variant: gpu-nvidia-cuda-12}
    resources: {limits: {nvidia.com/gpu: 1}}
    env:
      LOCALAI_NODE_LABELS: tier=gpu
      LOCALAI_VRAM_BUDGET: "90%"
chatWorker: {enabled: true}       # unattended chat turns (triggers, agent jobs, connectors)
agentWorker: {enabled: true}      # MCP tool calls over NATS
addonOwner: {enabled: true}       # one owner installs and runs add-ons for every frontend
```

- Accounts are always on in distributed mode (see [Install](#install) for the first administrator).
  Every server shares one session/API-key signing secret (`auth.hmacSecret`), which the chart
  generates and keeps.
- Workers are StatefulSets behind headless Services. Each worker advertises its stable pod DNS name
  and registers with the frontend using a registration token the chart generates. Registration goes
  through `<fullname>-nodes`, a Service that also reaches frontends that are not ready yet. With
  `distributed.autoApproveNodes` (the default), every node that presents the token is approved
  without an admin click. See [Security](#security) for what the token allows.
- A distributed frontend reports ready (`/readyz`, and so the Service and ingress) only once a backend
  worker is healthy, or after 5 minutes without one.
- A worker gives each loaded model its own gRPC port, from `grpcPort` (default 50051) to `grpcMaxPort`.
  Its file-transfer and health server listens on `grpcPort - 1`.
- Model files are copied from the frontend to each worker. With `distributed.sharedModels` and a
  ReadWriteMany models volume, generic workers mount the frontends' models volume instead.
- The built-in PostgreSQL (pgvector) and NATS are single instances for trying things out. LocalAI
  signs in to them with generated credentials (a non-superuser PostgreSQL role, a NATS token),
  and they only accept this release's pods (`networkPolicy.backplane`). In production, point the
  chart at managed services:
  - PostgreSQL: use separate databases for the accounts and for the collections. Several servers
    (frontends, chat workers) need the postgres collections engine; the chart enforces it.
  - NATS: whoever can publish on it can run code on the agent worker and on generic workers. Use
    JWT auth (`distributed.nats.auth`, a Secret with all three of `account-seed`, `service-jwt` and
    `service-seed`), which gives each node its own scoped credentials, and TLS
    (`distributed.nats.tls`, then use a `tls://` URL). Both are for external servers: the built-in
    NATS has a shared token and no TLS.
- With several frontends, chat Files need S3 (`distributed.storage`) or a ReadWriteMany data volume.
  Without S3, chat workers and the add-on owner mount the frontends' data volume, so it must be
  reachable from their nodes too. Chat workers and the owner also mount `configuration` (runtime
  settings from the web UI) when it is enabled.
- Add-ons: without `addonOwner`, a deployment with several frontends turns add-ons off, and chat
  workers have no add-on tools. With it, a pre-install/pre-upgrade Job generates the owner/frontend
  carrier keys into two Secrets (kept on uninstall), or bring your own with `addonOwner.carrierKeys`.
  To rotate generated keys, delete both Secrets, run `helm upgrade` (the Job creates new ones), then
  restart the owner, frontends and chat workers (`kubectl rollout restart`).
- Rollouts: `frontend.strategy` defaults to `Recreate`. `RollingUpdate` (as in the example) is safe
  once the frontends can run side by side: every enabled volume ReadWriteMany, and an add-on owner or
  several replicas. A single frontend without an owner holds the add-on lock, so don't autoscale it
  beyond one replica. Set the `rollingUpdate` parameters explicitly, so a later switch back to
  `Recreate` also drops them under server-side apply (Helm 4).
- On a fresh database the servers start one at a time (frontend, then add-on owner, then chat
  workers): LocalAI v5.0.0 servers that set up an empty database together can deadlock in it.
- Upgrading LocalAI: the docs ask for the add-on owner first, then the frontends, then the workers.
  `helm upgrade` changes all at once, and the image tag defaults to the chart's appVersion. To follow
  the order, pin `image.tag` to the running version first, then upgrade with the new tag on
  `addonOwner.image.tag` only, then on `image.tag`.

#### Other worker types

| `type` | Runs | Notes |
|---|---|---|
| `generic` | `local-ai worker` | Default. Runs any backend; the frontend installs backends on it on demand. |
| `llama-cpp-rpc` | `local-ai p2p-worker llama-cpp-rpc` | llama.cpp `rpc-server` (`args` are passed to it). The frontend (standalone, p2p) or generic workers (distributed) get `LLAMACPP_GRPC_SERVERS` pointing at every replica. Works in every mode, but not together with `p2p-llama-cpp-rpc` pools. |
| `p2p-llama-cpp-rpc` | `local-ai p2p-worker p2p-llama-cpp-rpc` | Joins the P2P network with the shared token (`mode: p2p`). `args` are passed to `rpc-server`. |
| `vllm` | `local-ai p2p-worker vllm` | vLLM data-parallel follower: the model in `args`, `VLLM_*` settings in `env`, one pool (`replicaCount: 1`) per rank. Gets `hfToken`; the HF cache is on its models volume. |
| `ds4-distributed` | `local-ai p2p-worker ds4-distributed` | ds4 layer-split worker: ds4-worker arguments in `args` (passed as `--ds4-args`). |

RPC-type pools only get a backends volume; vllm and ds4 pools also get a models volume for their
model files. With LocalAI v5.0.0 a `llama-cpp-rpc` pod restarts once on its first start, while it
installs the llama.cpp backend.

### P2P / federated

```yaml
mode: p2p
p2p:
  federated: true                 # this instance shares requests with other federated nodes
auth: {enabled: true}             # federated mode needs user accounts or an API key (see below)
frontend:
  models: [qwen3-4b]              # a llama.cpp (GGUF) model, sharded over the P2P workers
workers:
  - name: p2p
    type: p2p-llama-cpp-rpc
    replicaCount: 3
federatedServer: {enabled: true}  # local-ai federated: load balancer over the federated nodes
explorer: {enabled: true}         # local-ai explorer
```

- Clients that should use every federated node send requests to `svc/<fullname>-federated`; the
  frontend's own Service only reaches this release's frontend.
- `p2p.federated` publishes the frontend's API to every holder of the token, wherever they are, so
  the chart requires an API key or user accounts with it (`allowUnauthenticated: true` overrides).
- Sharding over P2P workers works for llama.cpp (GGUF) models, one model at a time, and the workers
  must be online before the model's first request. A `p2p-llama-cpp-rpc` worker downloads the
  llama.cpp backend on start (gallery egress, or a pre-filled backends volume): if that fails it
  still joins the network and model loads fail on the frontend.
- The chart generates the network token (or use `p2p.token.existingSecret`), kept on uninstall;
  machines outside the cluster join with it.
- Peers find each other through the public DHT (internet egress) unless `LOCALAI_P2P_DISABLE_DHT: "true"`
  is set in `env` (it reaches every P2P process, like `LOCALAI_P2P_NETWORK_ID`); mDNS alone needs
  multicast between pods (e.g. `hostNetwork`).
- libp2p listens on random ports that no Service exposes. For peers outside the cluster, give the P2P
  pods `hostNetwork` (each such pod also binds port 8080 on its node: one per node).
  `LOCALAI_P2P_LISTEN_MADDRS` / `LOCALAI_P2P_DHT_ANNOUNCE_MADDRS` only help with an address per pod
  (a component's `extraEnv`, e.g. from `status.hostIP`) and a route to it; without internet also set
  `LOCALAI_P2P_BOOTSTRAP_PEERS_MADDRS`. `networkPolicy.enabled` blocks inbound connections from peers
  outside the release.
- P2P discovery replaces a static `LLAMACPP_GRPC_SERVERS` list, so `llama-cpp-rpc` pools can't be
  mixed with P2P workers.
- The explorer lists the networks users submit tokens for, and only those with online workers.
- The federated server's TCP probes are forwarded to a federated node like any connection.

## Configuration notes

- `env` / `extraEnv` / `envFrom` apply to every LocalAI process. Each component also has its own.
  A variable set in `env` or `extraEnv` replaces the chart's value of the same name, and `env` values
  can reference `extraEnv` variables as `$(NAME)`. `envFrom` never overrides a variable the chart
  sets (Kubernetes gives `env` priority). The full list of settings is in `local-ai run --help` and
  on [localai.io](https://localai.io/reference/cli-reference/). Settings the chart doesn't wire up
  itself have no value of their own: e.g. `LOCALAI_COLLECTIONS_EMBEDDING_MODEL` in `env`,
  `LOCALAI_CHAT_WORKER_MAX_TURNS` in `chatWorker.env`, `LOCALAI_RANDOM_WORKER` in `federatedServer.env`.
- Pod settings: every component (`frontend`, each `workers` entry and `workerDefaults`, `chatWorker`,
  `agentWorker`, `addonOwner`, `federatedServer`, `explorer`) takes the same keys: `replicaCount`
  (where it scales), `image`, `env`/`extraEnv`/`envFrom`, `resources`, `nodeSelector`, `tolerations`,
  `affinity`, `topologySpreadConstraints`, `priorityClassName`, `runtimeClassName`, `podAnnotations`,
  `podLabels`, `securityContext`, `terminationGracePeriodSeconds`, `hostNetwork`,
  `shareProcessNamespace`, the three probes, `initContainers`, `sidecars`, `extraVolumes` and
  `extraVolumeMounts` (see "Pod settings" in `values.yaml`). `workerDefaults` is merged into every
  pool: maps merge, lists replace.
- Images: each component (and worker pool) takes `repository`, `tag` and `variant` from the global
  `image` unless it sets them itself, each one separately; the global `digest` applies only to
  components whose `image` sets nothing but `pullPolicy`. With a GPU `image.variant`, give the
  components that need no GPU `image: {variant: ""}` (the CPU image): `addonOwner`,
  `federatedServer`, `explorer`, `agentWorker`. The add-on carrier-keys install hook runs the
  `addonOwner` image and the `helm test` pod the `frontend` image, so a GPU image there is pulled
  within Helm's `--timeout` on a node that doesn't have it yet.
- Probes: an empty probe uses the chart's default; a probe you set replaces it entirely.
- Storage: `persistence.{models,backends,data,configuration,generated}`. Any volume that is
  disabled becomes an emptyDir. Settings changed in the web UI live in `configuration`, which is
  off by default, so they are lost on restart unless you enable it. The image runs as uid 10001;
  `podSecurityContext.fsGroup: 10001` keeps every volume writable (except on storage that ignores
  fsGroup, such as NFS: there the volume must already be writable by uid 10001).
- `modelsConfigs` and `promptTemplates` are written into the models directory at startup.
- Behind an ingress, set `LOCALAI_TRUSTED_PROXIES` in `frontend.env` to the controller's address
  range and `auth.baseUrl` to the external URL (OAuth/OIDC callbacks). Streaming (SSE, WebSockets)
  needs long proxy timeouts and no buffering; see the `ingress.annotations` example in `values.yaml`.
- Private registries / Hugging Face: `credentialsFile.existingSecret`, `hfToken.existingSecret`.
- Add-on host policy: `addonHostPolicy.content` replaces the image's policy file; changing it restarts
  the servers.
- Sandbox add-on: runs on the add-on owner (or the standalone frontend). It needs `/dev/kvm` through a
  device plugin, or gVisor, which needs user namespaces: see `addonOwner.securityContext` for the
  trade-offs, and prefer a node pool dedicated to the owner.
- Monitoring: `serviceMonitor.enabled` scrapes `/metrics`. With auth on, LocalAI serves it to
  administrators only, so the bearer token Secret must hold an admin API key.
- `networkPolicy.enabled` limits workers, the add-on carrier and the built-in databases to traffic
  from the release's own pods (inbound only). Pods with `hostNetwork` send from node addresses,
  which these policies may then block, depending on the CNI.
- StatefulSet `volumeClaimTemplates` can't change after creation: worker and add-on owner volumes,
  `distributed.sharedModels` (it removes the workers' models template) and the built-in PostgreSQL's
  `persistence.enabled`. To change them, delete the StatefulSet with `--cascade=orphan`
  and upgrade. Existing claims keep their size: to grow one, edit its storage request (the storage
  class must allow volume expansion).
- On uninstall, worker claims are kept. Delete them with
  `kubectl delete pvc -l app.kubernetes.io/instance=<release>`, which also matches the data volumes
  you chose to retain.
- `helm test <release>` checks `/readyz` through the Service (for up to 10 minutes in distributed
  mode).

### Security

- Containers: LocalAI's image starts as root, hands its volumes to uid 10001 and drops to it. The
  default `securityContext` keeps only the capabilities that needs (and no privilege escalation,
  seccomp `RuntimeDefault`), which meets Pod Security "baseline". For "restricted", run as 10001
  (`runAsUser`/`runAsGroup: 10001`, `runAsNonRoot: true`, `capabilities: {drop: [ALL], add: []}`)
  with volumes already writable by that user, and leave `modelsConfigs`/`promptTemplates` empty
  (copying them needs a root init container). Each component's `securityContext` is merged over
  the global one.
- Backends run as child processes with the pod's whole environment, so a model that runs code
  (pickle files, `trust_remote_code`) can read every secret of its pod: on workers the
  registration token, the S3 keys (every user's chat Files) and the Hugging Face token; in
  standalone and p2p mode the frontend's own secrets. Only install models you trust. The
  NetworkPolicies are inbound-only; add your own egress policy to block e.g. cloud metadata
  addresses. `LOCALAI_REQUIRE_BACKEND_INTEGRITY=true` rejects backends without a signature
  policy or checksum (check that your galleries provide them first).
- The registration token (distributed mode) lets its holder register a node, take over an existing
  node's name (LocalAI v5.0.0) and read or write every worker's files; turning off
  `autoApproveNodes` doesn't change that. The node endpoints (`/api/node/`) are served on the API
  port: if no workers outside the cluster register, don't route that path through your ingress.
- `llama-cpp-rpc`, `vllm` and `ds4-distributed` pools speak unauthenticated protocols, and the
  built-in NATS and PostgreSQL hold the cluster's state: they only accept this release's pods
  (`networkPolicy.backplane`, on by default and independent of `networkPolicy.enabled`).
- The explorer has no authentication and shows every submitted token to every visitor.
- Credentials in `*.database.url` or `distributed.nats.url` are plain text in the pod spec and the
  Helm release: use the `existingSecret` fields. For GitOps, prefer existing Secrets (sealed or
  external secrets) over the `value` fields.
- Images: pin them with `digest` (`image`, every component image, and the built-in
  PostgreSQL's and NATS's images). The global digest only applies to components without an `image`
  of their own.

### GitOps / `helm template`

The chart generates the registration token, the P2P token, the auth HMAC secret, the built-in
PostgreSQL password and the built-in NATS token, and keeps them across upgrades by reading them
back from the cluster. Tools that render without cluster access (`helm template`, Argo CD) get new
values on every render, which breaks logins, the P2P network and the database and NATS
credentials. Set them explicitly there: `distributed.registrationToken.existingSecret`,
`p2p.token.existingSecret`, `auth.hmacSecret.existingSecret`, `postgresql.existingSecret`,
`nats.existingSecret` (or `distributed.registrationToken.value`, `p2p.token.value`). Generated
add-on carrier keys are created by a Job, not rendered: they carry annotations that keep Argo CD
from pruning them.

The HMAC secret and the P2P token are kept on uninstall. The built-in PostgreSQL keeps its data and
password on uninstall only with `persistence.data.retain: true` (which also keeps the data volume);
otherwise both go.

In distributed mode, LocalAI checks at startup that the Files blob folder (`<data>/chats/blobs`) is
the one the account database knows. With an external database and no S3, keep the data volume
with the database (`persistence.data.retain: true` or an `existingClaim`), or a reinstall stops with
"the blob folder is not the one the database expects".

Every value is documented in [values.yaml](values.yaml) and checked by `values.schema.json`, which
is generated: edit `hack/gen_schema.py` and run
`python3 -I charts/local-ai/hack/gen_schema.py charts/local-ai/values.schema.json` (CI checks that
the two match).

## Upgrading from 3.x

Chart 4.0 is a rewrite for LocalAI v5 and is not values-compatible with 3.x. Start from the 4.x
values: with 3.x keys, `helm upgrade` stops with a list of the keys to translate.

| 3.x | 4.x |
|---|---|
| `replicaCount` | `frontend.replicaCount` (above 1 needs `mode: distributed`) |
| `deployment.image.{repository,tag}` | `image.{repository,tag,variant}`. The tag defaults to the chart's appVersion (3.x: `latest`); the variant picks the GPU image. |
| `deployment.env` (keys upper-cased) | `env` with the real variable names (e.g. `LOCALAI_THREADS`). 3.x set `threads: 4` and `context_size: 512` by default; 4.x leaves both to LocalAI. |
| `deployment.secretEnv` | `extraEnv` |
| `deployment.modelsPath` | `persistence.models.mountPath` |
| `modelsConfigs`, `promptTemplates` | same names; written into the models directory by an init container in the LocalAI image |
| `deployment.prompt_templates.image` | removed: the init step that copies `promptTemplates` (and `modelsConfigs`) runs in the LocalAI image |
| `deployment.pullPolicy`, `deployment.imagePullSecrets` | `image.pullPolicy`, `imagePullSecrets` |
| `deployment.runtimeClassName`, `deployment.strategy` | `frontend.runtimeClassName`, `frontend.strategy` |
| `persistence.models` / `persistence.output` (`globalMount`) | `persistence.{models,backends,data,configuration,generated}` (`mountPath`). `labels` is gone. A disabled volume is now an emptyDir. |
| `resources`, `nodeSelector`, `tolerations`, `affinity`, `initContainers`, `sidecarContainers` | the same under `frontend.` (`sidecarContainers` → `frontend.sidecars`). 3.x mounted the persistence volumes into them automatically; 4.x doesn't: add `volumeMounts` (volume names `models`, `backends`, `data`, `configuration`, `generated`). |
| `service.*`, `ingress.*` | same names. Service port 80 → 8080; the ingress `pathType` default is `Prefix`. |

Steps:

1. Translate your values with the table above into a new file.
2. Models claim (`<fullname>-models`): access modes can't change and the size can only grow, so set
   `persistence.models.accessModes` and `persistence.models.size` to the existing claim's (3.x:
   `[ReadWriteMany]`, `10Gi`). To use it as an `existingClaim` instead, first protect it, since the
   upgrade would otherwise delete it: `kubectl annotate pvc <fullname>-models helm.sh/resource-policy=keep`.
3. 3.x's `output` claim is deleted by the upgrade (it is now `generated`). Copy what you need first,
   or keep it: `kubectl annotate pvc <fullname>-output helm.sh/resource-policy=keep`.
4. The Deployment's selector changed, which Kubernetes can't update in place. Delete it (the pods
   stop; the claims stay): `kubectl delete deployment <fullname>`.
5. `helm upgrade <release> go-skynet/local-ai -f new-values.yaml --reset-values` (not
   `--reuse-values`, which would carry the 3.x values over). If clients or an external ingress use
   port 80, set `service.port: 80`.

The image now runs as uid 10001. Existing volumes are handed over to that user on the first start
(this can take a while on a large models volume). On NFS with `root_squash` (3.x's ReadWriteMany
default often is), root can't do that: give the export to uid/gid 10001 first, or set
`LOCALAI_RUN_AS_ROOT=true` in `env`.
