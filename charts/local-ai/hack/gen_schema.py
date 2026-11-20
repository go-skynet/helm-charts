"""Generates values.schema.json for the local-ai chart.

Edit this script, never the JSON. From the repository root:

    python3 -I charts/local-ai/hack/gen_schema.py charts/local-ai/values.schema.json

CI regenerates the schema and fails when the committed file differs. Every object rejects keys it
doesn't list (additionalProperties: false), so a typo in a values file fails at install time: a new
value needs an entry here as well as in values.yaml and the templates.
"""
import json
import sys


# ------------------------------------------------------------------------------- basic types

def string(**constraints):
    return {"type": "string", **constraints}


def integer(**constraints):
    return {"type": "integer", **constraints}


BOOLEAN = {"type": "boolean"}
INT_OR_STRING = {"type": ["integer", "string"]}
NULLABLE_INT = {"type": ["integer", "null"]}
ANY_OBJECT = {"type": "object"}
ANY_ARRAY = {"type": "array"}
STRING_LIST = {"type": "array", "items": string()}
# Environment variables: the templates quote every value.
ENV_MAP = {"type": "object", "additionalProperties": {"type": ["string", "number", "boolean"]}}
# Labels and annotations must be strings in Kubernetes: quote "true" / numbers in values.
STRING_MAP = {"type": "object", "additionalProperties": {"type": "string"}}
# Probes are passed through as written (a set probe replaces the chart's default).
PROBE = {"type": "object"}

# Values that end up in shell scripts, SQL or URLs are restricted to safe characters.
ABSOLUTE_PATH = string(pattern="^/[A-Za-z0-9._/-]*$")
DNS_NAME = string(pattern="^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$")
DNS_LABEL = string(pattern="^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
IMAGE_DIGEST = string(pattern="^$|^[a-z0-9]+:[a-f0-9]{32,}$")


def url_safe_token(min_length):
    """A credential that goes into a URL: empty (generated), or at least min_length safe characters."""
    return string(pattern="^$|^[A-Za-z0-9._~-]{%d,}$" % min_length)


def strict_object(properties, additional=False, **extra):
    """An object that only accepts the listed keys."""
    return {"type": "object", "properties": properties, "additionalProperties": additional, **extra}


def secret_ref(default_key):
    """{existingSecret, secretKey}: a key of a Secret the user creates."""
    return strict_object({"existingSecret": string(), "secretKey": string(default=default_key)})


# Chart 3.x keys: accepted only so the templates can fail with a pointer to the upgrade notes.
LEGACY = {"description": "chart 3.x value, replaced in 4.0: see \"Upgrading from 3.x\" in the chart README"}

# ------------------------------------------------------------------------------- images and volumes

LOCALAI_IMAGE = strict_object({"repository": string(), "tag": string(), "variant": string(), "digest": IMAGE_DIGEST,
                               "pullPolicy": string(enum=["Always", "IfNotPresent", "Never"])})
PLAIN_IMAGE = strict_object({"repository": string(), "tag": string(), "digest": IMAGE_DIGEST, "pullPolicy": string()})

FRONTEND_VOLUME = strict_object({"enabled": BOOLEAN, "mountPath": ABSOLUTE_PATH, "size": string(),
                                 "accessModes": STRING_LIST, "storageClass": string(), "existingClaim": string(),
                                 "annotations": STRING_MAP, "retain": BOOLEAN, "globalMount": LEGACY})
WORKER_VOLUMES = strict_object({
    name: strict_object({"enabled": BOOLEAN, "mountPath": ABSOLUTE_PATH, "size": string(),
                         "accessModes": STRING_LIST, "storageClass": string()})
    for name in ("models", "backends", "data")})
SIMPLE_VOLUME = strict_object({"enabled": BOOLEAN, "size": string(), "accessModes": ANY_ARRAY, "storageClass": string()})

# ------------------------------------------------------------------------------- LocalAI components

# Pod keys every LocalAI component accepts (values.yaml "Pod settings"; podCommon, podMetadata,
# env.user, probes and the extra containers/volumes in each workload template).
POD_KEYS = {"image": LOCALAI_IMAGE, "env": ENV_MAP, "extraEnv": ANY_ARRAY, "envFrom": ANY_ARRAY,
            "resources": ANY_OBJECT, "nodeSelector": ANY_OBJECT, "tolerations": ANY_ARRAY, "affinity": ANY_OBJECT,
            "podAnnotations": STRING_MAP, "podLabels": STRING_MAP, "securityContext": ANY_OBJECT,
            "topologySpreadConstraints": ANY_ARRAY, "priorityClassName": string(), "runtimeClassName": string(),
            "terminationGracePeriodSeconds": integer(minimum=0), "hostNetwork": BOOLEAN,
            "shareProcessNamespace": BOOLEAN, "startupProbe": PROBE, "readinessProbe": PROBE,
            "livenessProbe": PROBE, "initContainers": ANY_ARRAY, "sidecars": ANY_ARRAY,
            "extraVolumes": ANY_ARRAY, "extraVolumeMounts": ANY_ARRAY}


def component(**own_keys):
    """A LocalAI component: the pod keys plus its own."""
    return strict_object({**POD_KEYS, **own_keys})


WORKER_POOL_KEYS = {
    "name": DNS_LABEL,
    "type": string(enum=["generic", "llama-cpp-rpc", "p2p-llama-cpp-rpc", "vllm", "ds4-distributed"]),
    "replicaCount": integer(minimum=0),
    "grpcPort": integer(minimum=2, maximum=65535),
    "grpcMaxPort": integer(minimum=0, maximum=65535),
    "rpcPort": integer(minimum=1, maximum=65535),
    "args": STRING_LIST,
    "persistence": WORKER_VOLUMES,
}
WORKER_POOL = component(**WORKER_POOL_KEYS)
WORKER_POOL["required"] = ["name"]
# workerDefaults: everything a pool accepts except its identity.
WORKER_DEFAULTS = component(**{k: v for k, v in WORKER_POOL_KEYS.items() if k not in ("name", "type")})

P2P_SERVICE = strict_object({"type": string(enum=["ClusterIP", "NodePort", "LoadBalancer"]), "port": integer(),
                             "annotations": STRING_MAP})


def builtin_dependency(**own_keys):
    """The built-in PostgreSQL / NATS."""
    return strict_object({"enabled": BOOLEAN, "image": PLAIN_IMAGE, "existingSecret": string(), "secretKey": string(),
                          "resources": ANY_OBJECT, "nodeSelector": ANY_OBJECT, "tolerations": ANY_ARRAY,
                          "affinity": ANY_OBJECT, **own_keys})


# ------------------------------------------------------------------------------- values.yaml

VALUES = strict_object({
    "mode": string(enum=["standalone", "distributed", "p2p"]),
    "nameOverride": string(), "fullnameOverride": string(), "clusterDomain": DNS_NAME,
    "commonLabels": STRING_MAP, "commonAnnotations": STRING_MAP,
    "image": LOCALAI_IMAGE, "imagePullSecrets": ANY_ARRAY,
    "serviceAccount": strict_object({"create": BOOLEAN, "name": string(), "annotations": STRING_MAP,
                                     "automountServiceAccountToken": BOOLEAN}),
    "env": ENV_MAP, "extraEnv": ANY_ARRAY, "envFrom": ANY_ARRAY,
    "apiKey": secret_ref("api-key"), "allowUnauthenticated": BOOLEAN,
    "auth": strict_object({
        "enabled": BOOLEAN,
        "database": strict_object({"url": string(), "existingSecret": string(), "secretKey": string()}),
        "registrationMode": string(enum=["", "open", "approval", "invite"]), "adminEmail": string(),
        "disableLocalAuth": BOOLEAN, "baseUrl": string(),
        "oidc": strict_object({"issuer": string(), "clientId": string(), "existingSecret": string(),
                               "clientSecretKey": string()}),
        "github": strict_object({"clientId": string(), "existingSecret": string(), "clientSecretKey": string()}),
        "hmacSecret": secret_ref("hmac-secret")}),
    "collections": strict_object({
        "vectorEngine": string(enum=["", "chromem", "postgres"]),
        "database": strict_object({"url": string(), "existingSecret": string(), "secretKey": string()})}),
    "credentialsFile": secret_ref("credentials.yaml"), "hfToken": secret_ref("token"),
    "addonHostPolicy": strict_object({"content": string()}),
    "modelsConfigs": {"type": "object", "additionalProperties": string()},
    "promptTemplates": {"type": "object", "additionalProperties": string()},
    "frontend": component(replicaCount=integer(minimum=0), models=STRING_LIST, args=STRING_LIST,
                               strategy=strict_object({"type": string(enum=["Recreate", "RollingUpdate"]),
                                                       "rollingUpdate": ANY_OBJECT}),
                               pdb=strict_object({"enabled": BOOLEAN, "minAvailable": INT_OR_STRING})),
    "persistence": strict_object({**{name: FRONTEND_VOLUME
                                     for name in ("models", "backends", "data", "configuration", "generated")},
                                  "output": LEGACY}),
    "podSecurityContext": ANY_OBJECT, "securityContext": ANY_OBJECT,
    "service": strict_object({
        "type": string(enum=["ClusterIP", "NodePort", "LoadBalancer"]), "port": integer(), "nodePort": NULLABLE_INT,
        "annotations": STRING_MAP, "externalTrafficPolicy": string(enum=["", "Cluster", "Local"]),
        "loadBalancerIP": string(), "loadBalancerClass": string(),
        "sessionAffinity": string(enum=["", "None", "ClientIP"])}),
    "ingress": strict_object({"enabled": BOOLEAN, "className": string(), "annotations": STRING_MAP,
                              "hosts": ANY_ARRAY, "tls": ANY_ARRAY}),
    "distributed": strict_object({
        "nats": strict_object({"url": string(), "existingSecret": string(), "secretKey": string(),
                               "auth": strict_object({"existingSecret": string()}),
                               "requireAuth": {"type": ["boolean", "null"]},
                               "tls": strict_object({"existingSecret": string(), "clientAuth": BOOLEAN})}),
        "registrationToken": strict_object({"value": url_safe_token(32), "existingSecret": string(),
                                            "secretKey": string()}),
        "autoApproveNodes": BOOLEAN, "sharedModels": BOOLEAN,
        "storage": strict_object({"url": string(), "bucket": string(), "region": string(), "existingSecret": string(),
                                  "accessKeyKey": string(), "secretKeyKey": string()})}),
    "workers": {"type": "array", "items": WORKER_POOL},
    "workerDefaults": WORKER_DEFAULTS,
    "chatWorker": component(enabled=BOOLEAN, replicaCount=integer(minimum=0)),
    "agentWorker": component(enabled=BOOLEAN, replicaCount=integer(minimum=0)),
    "addonOwner": component(
        enabled=BOOLEAN,
        carrierKeys=strict_object({"ownerSecret": string(), "frontendSecret": string()}),
        persistence=strict_object({"size": string(), "accessModes": ANY_ARRAY, "storageClass": string(),
                                   "mountPath": ABSOLUTE_PATH})),
    "p2p": strict_object({"token": strict_object({"value": string(), "existingSecret": string(), "secretKey": string()}),
                          "federated": BOOLEAN}),
    "federatedServer": component(enabled=BOOLEAN, replicaCount=integer(minimum=0), service=P2P_SERVICE),
    "explorer": component(enabled=BOOLEAN, sync=BOOLEAN, service=P2P_SERVICE, persistence=SIMPLE_VOLUME),
    "postgresql": builtin_dependency(persistence=SIMPLE_VOLUME),
    "nats": builtin_dependency(),
    "serviceMonitor": strict_object({"enabled": BOOLEAN, "interval": string(), "labels": STRING_MAP,
                                     "bearerTokenSecret": ANY_OBJECT}),
    "networkPolicy": strict_object({"enabled": BOOLEAN, "backplane": BOOLEAN, "frontendIngressFrom": ANY_ARRAY}),
    # Helm passes `global` to every chart used as a dependency (even an empty one): without it a
    # parent chart can't render this one.
    "global": ANY_OBJECT,
    **{key: LEGACY for key in ("replicaCount", "deployment", "resources", "initContainers", "sidecarContainers",
                               "nodeSelector", "tolerations", "affinity")},
})

SCHEMA = {
    "$schema": "https://json-schema.org/draft-07/schema#",
    "title": "LocalAI Helm chart values",
    **VALUES,
}


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with open(sys.argv[1], "w") as out:
        json.dump(SCHEMA, out, indent=2)
        out.write("\n")


if __name__ == "__main__":
    main()
