#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  generate_nads_from_node.sh --node NODE --namespace NAMESPACE [options]

Discovers secondary host interfaces on a GVA worker node and generates Multus
NetworkAttachmentDefinitions that use ipvlan + oci-ipam.

Options:
  --node NODE                 Kubernetes node name to inspect.
  --namespace NAMESPACE       Namespace for workload NADs.
  --default-name NAME         kube-system NAD name for pod eth0.
                              Default: gva-default-network
  --nad-prefix PREFIX         Prefix for workload NAD names.
                              Default: if
  --interface-regex REGEX     Host interface allow-list regex.
                              Default: ^enp[1-9][0-9]*s[0-9]+$
  --count N                   Optional number of secondary interfaces to use.
                              Default: use all discovered matching interfaces.
  --output FILE               Write YAML to FILE instead of stdout.
  -h, --help                  Show this help.

Example:
  ./generate_nads_from_node.sh \
    --node <node_name> \
    --namespace gva-dualstack-test \
    --default-name gva-ipv6-if1-default \
    --nad-prefix if \
    --output nads.yaml

Resulting mapping for 3 discovered interfaces:
  eth0 -> kube-system/<default-name> -> first host interface
  net1 -> <namespace>/<prefix>2-oci-ipam -> second host interface
  net2 -> <namespace>/<prefix>3-oci-ipam -> third host interface

For more interfaces, the script continues the same pattern:
  net3 -> <namespace>/<prefix>4-oci-ipam -> fourth host interface
  net4 -> <namespace>/<prefix>5-oci-ipam -> fifth host interface
EOF
}

node=""
namespace=""
default_name="gva-default-network"
nad_prefix="if"
interface_regex='^enp[1-9][0-9]*s[0-9]+$'
count=""
output=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --node)
      node="${2:-}"
      shift 2
      ;;
    --namespace)
      namespace="${2:-}"
      shift 2
      ;;
    --default-name)
      default_name="${2:-}"
      shift 2
      ;;
    --nad-prefix)
      nad_prefix="${2:-}"
      shift 2
      ;;
    --interface-regex)
      interface_regex="${2:-}"
      shift 2
      ;;
    --count)
      count="${2:-}"
      shift 2
      ;;
    --output)
      output="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$node" ] || [ -z "$namespace" ]; then
  echo "--node and --namespace are required" >&2
  usage >&2
  exit 2
fi

if [ -n "$count" ]; then
  if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -lt 1 ]; then
    echo "--count must be a positive integer" >&2
    exit 2
  fi
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

debug_ns="default"
debug_pod="gva-nad-discovery-$(date +%s)"

cat > "$tmp/discovery-pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${debug_pod}
  namespace: ${debug_ns}
spec:
  restartPolicy: Never
  nodeName: ${node}
  hostPID: true
  tolerations:
    - operator: Exists
  containers:
    - name: inspect
      image: docker.io/nicolaka/netshoot:v0.13
      securityContext:
        privileged: true
      command:
        - /bin/sh
        - -lc
        - chroot /host ip -j addr
      volumeMounts:
        - name: host-root
          mountPath: /host
          readOnly: true
  volumes:
    - name: host-root
      hostPath:
        path: /
        type: Directory
EOF

kubectl apply --validate=false -f "$tmp/discovery-pod.yaml" >/dev/null

for _ in $(seq 1 30); do
  phase="$(kubectl -n "$debug_ns" get pod "$debug_pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ] && break
  sleep 1
done

kubectl -n "$debug_ns" logs "$debug_pod" > "$tmp/ip-addr.json"
kubectl -n "$debug_ns" delete pod "$debug_pod" --ignore-not-found >/dev/null 2>&1 || true

if [ -n "$count" ]; then
  mapfile -t interfaces < <(
    jq -r --arg re "$interface_regex" '
    .[]
    | select(.ifname | test($re))
    | select((.addr_info // []) | any(.family == "inet" or .family == "inet6"))
    | .ifname
    ' "$tmp/ip-addr.json" | sort -V | head -n "$count"
  )
else
  mapfile -t interfaces < <(
    jq -r --arg re "$interface_regex" '
    .[]
    | select(.ifname | test($re))
    | select((.addr_info // []) | any(.family == "inet" or .family == "inet6"))
    | .ifname
    ' "$tmp/ip-addr.json" | sort -V
  )
fi

if [ -n "$count" ] && [ "${#interfaces[@]}" -ne "$count" ]; then
  echo "expected ${count} interfaces matching ${interface_regex}, found ${#interfaces[@]}" >&2
  printf 'found: %s\n' "${interfaces[@]}" >&2
  exit 1
fi

if [ "${#interfaces[@]}" -lt 1 ]; then
  echo "no interfaces matching ${interface_regex} were found" >&2
  exit 1
fi

emit() {
  cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${namespace}
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${default_name}
  namespace: kube-system
spec:
  config: |
    {
      "name": "${default_name}",
      "cniVersion": "0.3.1",
      "plugins": [
        {
          "cniVersion": "0.3.1",
          "type": "oci-ipvlan",
          "mode": "l2",
          "ipam": {
            "type": "oci-ipam",
            "deviceSelector": {
              "interfaceName": "${interfaces[0]}"
            }
          }
        },
        {
          "cniVersion": "0.3.1",
          "type": "oci-ptp",
          "containerInterface": "ptp-veth0",
          "mtu": 9000
        }
      ]
    }
EOF

  for i in $(seq 1 $((${#interfaces[@]} - 1))); do
    nad_num=$((i + 1))
    iface="${interfaces[$i]}"
    cat <<EOF
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${nad_prefix}${nad_num}-oci-ipam
  namespace: ${namespace}
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "ipvlan",
      "mode": "l2",
      "master": "${iface}",
      "ipam": {
        "type": "oci-ipam",
        "deviceSelector": {
          "interfaceName": "${iface}"
        }
      }
    }
EOF
  done
}

if [ -n "$output" ]; then
  emit > "$output"
  echo "wrote $output" >&2
else
  emit
fi

echo "discovered mapping:" >&2
echo "  eth0 -> kube-system/${default_name} -> host ${interfaces[0]}" >&2
for i in $(seq 1 $((${#interfaces[@]} - 1))); do
  nad_num=$((i + 1))
  echo "  net${i} -> ${namespace}/${nad_prefix}${nad_num}-oci-ipam -> host ${interfaces[$i]}" >&2
done
