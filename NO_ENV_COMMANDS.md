# Dual-Stack OKE GVA Commands Without Environment Variables

This version avoids exported environment variables. Replace every `<...>` placeholder with the target OCI, subnet, image, gateway, namespace, and node values before running a command.

The commands create an enhanced IPv4/IPv6 OKE cluster, create a GVA node pool with three secondary VNICs per worker, install Multus, create NADs, deploy two routed test pods, and verify pod-to-pod IPv4/IPv6 connectivity.

## 1 Create Cluster Input Files

```sh
mkdir -p generated/dualstack-gva

cat > generated/dualstack-gva/cluster-pod-network-options.json <<'EOF'
[
  {
    "cniType": "OCI_VCN_IP_NATIVE"
  }
]
EOF

cat > generated/dualstack-gva/ip-families.json <<'EOF'
[
  "IPv4",
  "IPv6"
]
EOF

cat > generated/dualstack-gva/service-lb-subnet-ids.json <<'EOF'
[
  "<service_lb_subnet_1_ocid>",
  "<service_lb_subnet_2_ocid>"
]
EOF

jq empty generated/dualstack-gva/cluster-pod-network-options.json
jq empty generated/dualstack-gva/ip-families.json
jq empty generated/dualstack-gva/service-lb-subnet-ids.json
```

## 2 Create The Dual-Stack OKE Cluster

```sh
oci ce cluster create \
  --region "<oci_region>" \
  --compartment-id "<compartment_ocid>" \
  --name "<cluster_name>" \
  --vcn-id "<vcn_ocid>" \
  --kubernetes-version "<oke_kubernetes_version>" \
  --type ENHANCED_CLUSTER \
  --cluster-pod-network-options "file://$(pwd)/generated/dualstack-gva/cluster-pod-network-options.json" \
  --ip-families "file://$(pwd)/generated/dualstack-gva/ip-families.json" \
  --endpoint-subnet-id "<api_endpoint_subnet_ocid>" \
  --endpoint-public-ip-enabled "<true_or_false>" \
  --service-lb-subnet-ids "file://$(pwd)/generated/dualstack-gva/service-lb-subnet-ids.json" \
  --output json
```

Confirm the cluster create work request and cluster settings:

```sh
oci ce work-request get \
  --region "<oci_region>" \
  --work-request-id "<cluster_create_work_request_ocid>" \
  --output json \
  | jq '.data | {status, resources, errors}'

oci ce cluster get \
  --region "<oci_region>" \
  --cluster-id "<cluster_ocid>" \
  --output json \
  | jq '.data | {
      name,
      lifecycleState: ."lifecycle-state",
      type,
      clusterPodNetworkOptions: ."cluster-pod-network-options",
      ipFamilies: ."ip-families"
    }'
```

## 3 Configure Kubectl

```sh
oci ce cluster create-kubeconfig \
  --cluster-id "<cluster_ocid>" \
  --file "$HOME/.kube/config" \
  --region "<oci_region>" \
  --token-version 2.0.0 \
  --kube-endpoint "<PUBLIC_ENDPOINT_or_PRIVATE_ENDPOINT>"

kubectl config use-context "<kubectl_context_name>"
kubectl cluster-info
```

## 4 Create The Secondary VNIC Payload

```sh
cat > generated/dualstack-gva/secondary-vnics.json <<'EOF'
[
  {
    "displayName": "vnicattachment-gva-if1",
    "createVnicDetails": {
      "displayName": "vnic-gva-if1",
      "subnetId": "<secondary_subnet_1_ocid>",
      "assignPublicIp": false,
      "assignIpv6Ip": true,
      "skipSourceDestCheck": false,
      "ipCount": 16
    }
  },
  {
    "displayName": "vnicattachment-gva-if2",
    "createVnicDetails": {
      "displayName": "vnic-gva-if2",
      "subnetId": "<secondary_subnet_2_ocid>",
      "assignPublicIp": false,
      "assignIpv6Ip": true,
      "skipSourceDestCheck": false,
      "ipCount": 16
    }
  },
  {
    "displayName": "vnicattachment-gva-if3",
    "createVnicDetails": {
      "displayName": "vnic-gva-if3",
      "subnetId": "<secondary_subnet_3_ocid>",
      "assignPublicIp": false,
      "assignIpv6Ip": true,
      "skipSourceDestCheck": false,
      "ipCount": 16
    }
  }
]
EOF

jq empty generated/dualstack-gva/secondary-vnics.json
```

The payload intentionally omits `applicationResources`.

## 5 Create The GVA Node Pool

```sh
oci ce node-pool create \
  --region "<oci_region>" \
  --compartment-id "<compartment_ocid>" \
  --cluster-id "<cluster_ocid>" \
  --name "<gva_node_pool_name>" \
  --kubernetes-version "<oke_kubernetes_version>" \
  --node-shape "<worker_shape>" \
  --node-shape-config '{"ocpus":<ocpus_for_flex_shape>,"memoryInGBs":<memory_gb_for_flex_shape>}' \
  --size 2 \
  --cni-type OCI_VCN_IP_NATIVE \
  --placement-configs '[{"availabilityDomain":"<availability_domain_name>","subnetId":"<worker_primary_subnet_ocid>"}]' \
  --node-source-details '{"sourceType":"IMAGE","imageId":"<oke_worker_image_ocid>"}' \
  --initial-node-labels '[{"key":"network","value":"<gva_nodepool_label>"},{"key":"gva.oraclecloud.com/secondary-vnics","value":"3"}]' \
  --ssh-public-key "<ssh_public_key>" \
  --secondary-vnics "file://$(pwd)/generated/dualstack-gva/secondary-vnics.json" \
  --output json
```

Confirm the node pool and workers:

```sh
oci ce work-request get \
  --region "<oci_region>" \
  --work-request-id "<node_pool_create_work_request_ocid>" \
  --output json \
  | jq '.data | {status, resources, errors}'

oci ce node-pool get \
  --region "<oci_region>" \
  --node-pool-id "<node_pool_ocid>" \
  --output json \
  | jq '.data | {
      name,
      lifecycleState: ."lifecycle-state",
      clusterId: ."cluster-id",
      size,
      kubernetesVersion: ."kubernetes-version",
      nodeShape: ."node-shape"
    }'

kubectl get nodes -l "network=<gva_nodepool_label>" -o wide
```

## 6 Install Multus

```sh
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml
kubectl -n kube-system rollout status ds/kube-multus-ds --timeout=180s
kubectl get crd network-attachment-definitions.k8s.cni.cncf.io
```

## 7 Create NADs

Preferred generated path:

```sh
bash scripts/generate_nads_from_node.sh \
  --node "<gva_worker_node_name>" \
  --namespace "<test_namespace>" \
  --default-name gva-if1-default \
  --nad-prefix if \
  --count 3 \
  --output generated/dualstack-gva/nads.yaml

kubectl create namespace "<test_namespace>" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --dry-run=server -f generated/dualstack-gva/nads.yaml
kubectl apply -f generated/dualstack-gva/nads.yaml
kubectl -n kube-system get network-attachment-definitions gva-if1-default
kubectl -n "<test_namespace>" get network-attachment-definitions
```

Manual fallback when host interface names are already known:

```sh
cat > generated/dualstack-gva/nads.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: <test_namespace>
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: gva-if1-default
  namespace: kube-system
spec:
  config: |
    {
      "name": "gva-if1-default",
      "cniVersion": "0.3.1",
      "plugins": [
        {
          "cniVersion": "0.3.1",
          "type": "oci-ipvlan",
          "mode": "l2",
          "ipam": {
            "type": "oci-ipam",
            "deviceSelector": {
              "interfaceName": "<host_if1>"
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
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: if2-oci-ipam
  namespace: <test_namespace>
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "ipvlan",
      "mode": "l2",
      "master": "<host_if2>",
      "ipam": {
        "type": "oci-ipam",
        "deviceSelector": {
          "interfaceName": "<host_if2>"
        }
      }
    }
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: if3-oci-ipam
  namespace: <test_namespace>
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "ipvlan",
      "mode": "l2",
      "master": "<host_if3>",
      "ipam": {
        "type": "oci-ipam",
        "deviceSelector": {
          "interfaceName": "<host_if3>"
        }
      }
    }
EOF
```

## 8 Create Routed Test Pods

Replace all placeholders in this manifest before applying it.

```sh
cat > generated/dualstack-gva/pods.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: gva-dualstack-a
  namespace: <test_namespace>
  labels:
    app: gva-dualstack-test
  annotations:
    v1.multus-cni.io/default-network: kube-system/gva-if1-default
    k8s.v1.cni.cncf.io/networks: |
      [
        {"name":"if2-oci-ipam","namespace":"<test_namespace>","interface":"net1"},
        {"name":"if3-oci-ipam","namespace":"<test_namespace>","interface":"net2"}
      ]
spec:
  restartPolicy: Always
  nodeSelector:
    network: <gva_nodepool_label>
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app: gva-dualstack-test
          topologyKey: kubernetes.io/hostname
  containers:
    - name: netshoot
      image: docker.io/nicolaka/netshoot:v0.13
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          add:
            - NET_ADMIN
      command:
        - /bin/sh
        - -lc
        - |
          configure_iface() {
            iface="$1"
            table4="$2"
            prio4="$3"
            subnet4="$4"
            gw4="$5"
            table6="$6"
            prio6="$7"
            subnet6="$8"

            ip4="$(ip -4 -o addr show dev "${iface}" | awk '{split($4,a,"/"); print a[1]; exit}')"
            if [ -n "${ip4}" ]; then
              ip route replace default via "${gw4}" dev "${iface}" table "${table4}" || true
              ip route replace "${subnet4}" dev "${iface}" src "${ip4}" table "${table4}" || true
              ip rule add from "${ip4}/32" table "${table4}" priority "${prio4}" 2>/dev/null || true
            fi

            ip6="$(ip -6 -o addr show dev "${iface}" scope global | awk '{split($4,a,"/"); print a[1]; exit}')"
            if [ -n "${ip6}" ]; then
              ip -6 route replace "${subnet6}" dev "${iface}" src "${ip6}" table "${table6}" || true
              gw6="$(ip -6 route show default dev "${iface}" | awk '/ via / {print $3; exit}')"
              if [ -n "${gw6}" ]; then
                ip -6 route replace default via "${gw6}" dev "${iface}" table "${table6}" || true
              fi
              ip -6 rule add from "${ip6}/128" table "${table6}" priority "${prio6}" 2>/dev/null || true
            fi
          }

          configure_iface eth0 101 101 "<secondary_subnet_1_ipv4_cidr>" "<secondary_subnet_1_ipv4_gateway>" 201 201 "<secondary_subnet_1_ipv6_cidr>"
          configure_iface net1 102 102 "<secondary_subnet_2_ipv4_cidr>" "<secondary_subnet_2_ipv4_gateway>" 202 202 "<secondary_subnet_2_ipv6_cidr>"
          configure_iface net2 103 103 "<secondary_subnet_3_ipv4_cidr>" "<secondary_subnet_3_ipv4_gateway>" 203 203 "<secondary_subnet_3_ipv6_cidr>"

          ip -br addr
          ip rule
          ip -6 rule
          sleep infinity
---
apiVersion: v1
kind: Pod
metadata:
  name: gva-dualstack-b
  namespace: <test_namespace>
  labels:
    app: gva-dualstack-test
  annotations:
    v1.multus-cni.io/default-network: kube-system/gva-if1-default
    k8s.v1.cni.cncf.io/networks: |
      [
        {"name":"if2-oci-ipam","namespace":"<test_namespace>","interface":"net1"},
        {"name":"if3-oci-ipam","namespace":"<test_namespace>","interface":"net2"}
      ]
spec:
  restartPolicy: Always
  nodeSelector:
    network: <gva_nodepool_label>
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app: gva-dualstack-test
          topologyKey: kubernetes.io/hostname
  containers:
    - name: netshoot
      image: docker.io/nicolaka/netshoot:v0.13
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          add:
            - NET_ADMIN
      command:
        - /bin/sh
        - -lc
        - |
          configure_iface() {
            iface="$1"
            table4="$2"
            prio4="$3"
            subnet4="$4"
            gw4="$5"
            table6="$6"
            prio6="$7"
            subnet6="$8"

            ip4="$(ip -4 -o addr show dev "${iface}" | awk '{split($4,a,"/"); print a[1]; exit}')"
            if [ -n "${ip4}" ]; then
              ip route replace default via "${gw4}" dev "${iface}" table "${table4}" || true
              ip route replace "${subnet4}" dev "${iface}" src "${ip4}" table "${table4}" || true
              ip rule add from "${ip4}/32" table "${table4}" priority "${prio4}" 2>/dev/null || true
            fi

            ip6="$(ip -6 -o addr show dev "${iface}" scope global | awk '{split($4,a,"/"); print a[1]; exit}')"
            if [ -n "${ip6}" ]; then
              ip -6 route replace "${subnet6}" dev "${iface}" src "${ip6}" table "${table6}" || true
              gw6="$(ip -6 route show default dev "${iface}" | awk '/ via / {print $3; exit}')"
              if [ -n "${gw6}" ]; then
                ip -6 route replace default via "${gw6}" dev "${iface}" table "${table6}" || true
              fi
              ip -6 rule add from "${ip6}/128" table "${table6}" priority "${prio6}" 2>/dev/null || true
            fi
          }

          configure_iface eth0 101 101 "<secondary_subnet_1_ipv4_cidr>" "<secondary_subnet_1_ipv4_gateway>" 201 201 "<secondary_subnet_1_ipv6_cidr>"
          configure_iface net1 102 102 "<secondary_subnet_2_ipv4_cidr>" "<secondary_subnet_2_ipv4_gateway>" 202 202 "<secondary_subnet_2_ipv6_cidr>"
          configure_iface net2 103 103 "<secondary_subnet_3_ipv4_cidr>" "<secondary_subnet_3_ipv4_gateway>" 203 203 "<secondary_subnet_3_ipv6_cidr>"

          ip -br addr
          ip rule
          ip -6 rule
          sleep infinity
EOF

kubectl apply --dry-run=server -f generated/dualstack-gva/pods.yaml
kubectl apply -f generated/dualstack-gva/pods.yaml
kubectl -n "<test_namespace>" wait --for=condition=Ready pod/gva-dualstack-a pod/gva-dualstack-b --timeout=180s
```

## 9 Verify

```sh
kubectl -n "<test_namespace>" get pods -o wide
kubectl -n "<test_namespace>" get pod gva-dualstack-a -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}{"\n"}'
kubectl -n "<test_namespace>" get pod gva-dualstack-b -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}{"\n"}'
kubectl -n "<test_namespace>" exec gva-dualstack-a -- ip -br addr
kubectl -n "<test_namespace>" exec gva-dualstack-a -- ip rule
kubectl -n "<test_namespace>" exec gva-dualstack-a -- ip -6 rule
kubectl -n "<test_namespace>" exec gva-dualstack-a -- ip route show table 101
kubectl -n "<test_namespace>" exec gva-dualstack-a -- ip route show table 102
kubectl -n "<test_namespace>" exec gva-dualstack-a -- ip route show table 103
kubectl -n "<test_namespace>" exec gva-dualstack-a -- ip -6 route show table 201
kubectl -n "<test_namespace>" exec gva-dualstack-a -- ip -6 route show table 202
kubectl -n "<test_namespace>" exec gva-dualstack-a -- ip -6 route show table 203
```

Record the IPv4 and IPv6 addresses from `network-status`, then run interface-bound pings:

```sh
kubectl -n "<test_namespace>" exec gva-dualstack-a -- ping -4 -I eth0 -c 2 -W 2 "<pod_b_eth0_ipv4>"
kubectl -n "<test_namespace>" exec gva-dualstack-a -- ping -4 -I net1 -c 2 -W 2 "<pod_b_net1_ipv4>"
kubectl -n "<test_namespace>" exec gva-dualstack-a -- ping -4 -I net2 -c 2 -W 2 "<pod_b_net2_ipv4>"
kubectl -n "<test_namespace>" exec gva-dualstack-a -- ping -6 -I eth0 -c 2 -W 2 "<pod_b_eth0_ipv6>"
kubectl -n "<test_namespace>" exec gva-dualstack-a -- ping -6 -I net1 -c 2 -W 2 "<pod_b_net1_ipv6>"
kubectl -n "<test_namespace>" exec gva-dualstack-a -- ping -6 -I net2 -c 2 -W 2 "<pod_b_net2_ipv6>"
```

## 10 Cleanup

```sh
kubectl delete -f generated/dualstack-gva/pods.yaml --ignore-not-found
kubectl delete -f generated/dualstack-gva/nads.yaml --ignore-not-found
kubectl delete -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml
```
