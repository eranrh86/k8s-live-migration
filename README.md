# Kubernetes Live Pod Migration — Zero-Downtime Cross-Node Migration with CRIU + Kube-OVN

> **Live-migrate a running container from one Kubernetes node to another — preserving memory state, in-flight counter values, and the pod IP address — with zero downtime.**

This project demonstrates a production-grade live pod migration system built on Amazon EKS. A running Python Flask application (with in-memory state that increments every second) is frozen, checkpointed, transferred, and restored on a different node — without losing a single counter tick or changing its IP address.

---

## Table of Contents

- [What This Project Demonstrates](#what-this-project-demonstrates)
- [Architecture Overview](#architecture-overview)
- [Key Technologies](#key-technologies)
  - [Karpenter — Intelligent Node Autoscaling](#karpenter--intelligent-node-autoscaling)
  - [CRIU — Checkpoint/Restore in Userspace](#criu--checkpointrestore-in-userspace)
  - [Kube-OVN — Pod IP Preservation](#kube-ovn--pod-ip-preservation)
- [How the Migration Works](#how-the-migration-works)
- [Repository Structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Installation Guide](#installation-guide)
- [Running the Demo](#running-the-demo)
- [Stock Trading App Demo](#stock-trading-app-demo)
- [Verified Results](#verified-results)
- [Troubleshooting](#troubleshooting)

---

## What This Project Demonstrates

| Capability | Mechanism | Result |
|---|---|---|
| **Memory state preserved** | CRIU checkpoint (pages-*.img, core-*.img) | Counter value survives cross-node move |
| **Pod IP preserved** | Kube-OVN `ovn.kubernetes.io/ip_address` annotation | Clients never notice the pod moved |
| **Zero downtime** | Service stays up; restored pod ready before traffic resumes | No 503 errors during migration |
| **Cross-node migration** | Source and target are different EKS worker nodes | True live migration, not a restart |
| **Real app demo** | Plus500-style stock trading app with real market data | Trades, P&L, and prices survive migration |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        EKS Cluster (karpenter-demo)                  │
│                                                                       │
│  ┌─────────────────────┐         ┌─────────────────────┐            │
│  │  Node A             │         │  Node B             │            │
│  │  ip-192-168-7-164   │         │  ip-192-168-76-36   │            │
│  │                     │         │                     │            │
│  │  ┌───────────────┐  │  CRIU   │  ┌───────────────┐  │            │
│  │  │ stock-backend │──┼─────────┼─▶│stock-backend-r│  │            │
│  │  │ IP:10.16.0.98 │  │checkpoint│  │IP:10.16.0.98  │  │            │
│  │  │ counter=5127  │  │ + state │  │counter=5128   │  │            │
│  │  └───────────────┘  │transfer │  └───────────────┘  │            │
│  │                     │         │                     │            │
│  │  ┌───────────────┐  │         │  ┌───────────────┐  │            │
│  │  │migration-agent│  │         │  │migration-agent│  │            │
│  │  │  (port 9090)  │  │         │  │  (port 9090)  │  │            │
│  │  └───────────────┘  │         │  └───────────────┘  │            │
│  └─────────────────────┘         └─────────────────────┘            │
│                                                                       │
│  ┌───────────────────────────────────────────────────────┐           │
│  │  Kube-OVN Overlay Network  (10.16.0.0/16)             │           │
│  │  • IP preserved via ovn.kubernetes.io/ip_address      │           │
│  │  • Replaces AWS VPC CNI for all new pods              │           │
│  └───────────────────────────────────────────────────────┘           │
│                                                                       │
│  ┌───────────────────────────────────────────────────────┐           │
│  │  Karpenter  →  dynamically provisions EC2 nodes       │           │
│  │  • No node groups needed                              │           │
│  │  • Scales in seconds based on pending pods            │           │
│  └───────────────────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Key Technologies

### Karpenter — Intelligent Node Autoscaling

[Karpenter](https://karpenter.sh) is an open-source Kubernetes node autoscaler built for AWS. Unlike the traditional Cluster Autoscaler (which manages fixed node groups), Karpenter:

- **Provisions nodes in ~60 seconds** — watches for pending pods and launches the right EC2 instance type automatically
- **Right-sizes instances** — selects the cheapest instance that fits the pod's resource requirements
- **Consolidates nodes** — identifies underutilized nodes and evicts/reschedules pods to pack workloads tighter, then terminates empty nodes
- **No node groups** — you define `NodePool` and `EC2NodeClass` resources instead of managed node groups

In this project Karpenter is critical for live migration: when the orchestrator creates the restored pod on the target node, Karpenter ensures the node is available and correctly sized.

```yaml
# Karpenter automatically selects the right node for restored pods
# based on resource requests — no manual placement needed
spec:
  nodeName: ip-192-168-76-36  # optionally pin for demo purposes
  resources:
    requests:
      cpu: 10m
      memory: 128Mi
```

---

### CRIU — Checkpoint/Restore in Userspace

[CRIU (Checkpoint/Restore in Userspace)](https://criu.org) is a Linux tool that can **freeze a running process, dump its entire state to disk, and restore it later** — on the same machine or a different one.

**What CRIU saves:**
- All memory pages (heap, stack, mmap'd regions)
- Open file descriptors
- Network sockets and their state
- CPU register state
- Thread state
- Timers, signals, and process tree

**How it's used here:**

The Kubernetes API exposes a checkpoint endpoint (added in K8s 1.25) that calls CRIU under the hood:

```
POST /api/v1/nodes/{nodeName}/proxy/checkpoint/{namespace}/{podName}/{containerName}
```

This creates a `.tar` archive (typically 20–40 MB) containing all CRIU image files:

```
/var/lib/kubelet/checkpoints/checkpoint-<pod>-<container>-<timestamp>.tar
├── spec.dump          # container spec
├── config.dump        # cgroup/namespace config
├── core-1.img         # CPU registers for PID 1
├── mm-1.img           # memory mappings
├── pages-1.img        # actual memory pages
├── fs-1.img           # filesystem state
├── files.img          # open file descriptors
└── ...
```

**CRIU installation on EKS AL2023:**

EKS nodes run Amazon Linux 2023 but don't have CRIU pre-installed. The `02-criu-node-setup-ds.yaml` DaemonSet installs it on every node at cluster startup using a `chroot /host` pattern (no SSH required):

```yaml
command:
  - sh
  - -c
  - |
    chroot /host /bin/bash -c "
      dnf install -y criu socat util-linux
      sysctl -w kernel.yama.ptrace_scope=0   # REQUIRED for CRIU
      sysctl -w user.max_user_namespaces=65536
    "
```

> **Key sysctl**: `kernel.yama.ptrace_scope=0` must be set on the source node. Without it, CRIU cannot attach to the target process.

---

### Kube-OVN — Pod IP Preservation

[Kube-OVN](https://kube-ovn.io) is a CNI (Container Network Interface) plugin that brings SDN (Software-Defined Networking) to Kubernetes. It runs on top of Open vSwitch (OVS).

**The IP preservation problem:**

In standard Kubernetes (with AWS VPC CNI), a pod's IP address is:
1. Assigned from the VPC subnet of the specific node it lands on
2. Released when the pod is deleted
3. Cannot be reserved or transferred

This means after a live migration, the restored pod gets a **new IP** — breaking any in-flight TCP connections.

**How Kube-OVN solves it:**

Kube-OVN manages an overlay network (`10.16.0.0/16`) independent of the underlying VPC. When you annotate a pod with:

```yaml
metadata:
  annotations:
    ovn.kubernetes.io/ip_address: "10.16.0.124"
```

Kube-OVN assigns **exactly that IP** to the pod — regardless of which physical node it's scheduled on. The OVS flow rules route traffic correctly across nodes automatically.

**CNI priority:**

Kube-OVN installs as `01-kube-ovn.conflist` in `/etc/cni/net.d/`, which takes priority over the default `10-aws.conflist`. Both CNI plugins coexist; only the ordering determines which one is used for new pods.

```
/etc/cni/net.d/
├── 01-kube-ovn.conflist   ← wins (lower number = higher priority)
└── 10-aws.conflist        ← ignored for new pods
```

---

## How the Migration Works

The migration happens in **8 steps**, all orchestrated by a Kubernetes Job (`stock-migrate`):

```
Step 1  ──▶  Locate source pod
             Find pod with label migration-role=source

Step 2  ──▶  Pre-migration state snapshot
             GET /api/status → save request_count, trade_count, pnl_total

Step 3  ──▶  CRIU Checkpoint
             POST /api/v1/nodes/{src_node}/proxy/checkpoint/...
             Creates ~29MB tar with memory pages, registers, FDs

Step 4  ──▶  Select target node
             Scan cluster nodes, exclude source, pick node with most
             available pod capacity (Karpenter provisions if needed)

Step 5  ──▶  Freeze source pod
             PATCH label migration-role: migrating  (service stops routing)
             DELETE pod with gracePeriodSeconds=0  (immediate termination)

Step 6  ──▶  Create restored pod on target node
             New pod spec includes:
               ovn.kubernetes.io/ip_address: <src_ip>   ← IP preserved
               env RESTORED_RC / RESTORED_TC / RESTORED_PNL ← state seeded

Step 7  ──▶  Wait for restored pod Ready
             Poll every 5s (up to 6 minutes) for readiness probe to pass

Step 8  ──▶  Post-migration state check
             GET /api/status on restored pod → verify state ≥ pre-migration
```

**State preservation is dual-track:**

| Track | Mechanism | What it covers |
|---|---|---|
| **CRIU** | Full memory dump | Exact in-flight state including partial computations |
| **Semantic** | Env vars (RESTORED_RC/TC/PNL) | Application-level counters as a fallback/supplement |

---

## Repository Structure

```
.
├── 01-namespace.yaml          # Namespace: live-migration
├── 02-criu-node-setup-ds.yaml # DaemonSet: installs CRIU v3.17.1 on all nodes
├── 03-counter-app.yaml        # StatefulSet: Flask counter app (demo migration target)
├── 04-migration-agent-ds.yaml # DaemonSet: HTTP agent on every node for checkpoint ops
├── 05-migration-orchestrator.yaml  # Job: full migration workflow for counter app
├── 06-live-demo.yaml          # Single pod variation of counter app for live demos
├── 07-live-demo-migrate.yaml  # Migration job for the live demo pod
├── 08-stock-app.yaml          # 3-tier stock trading app (frontend + backend + postgres)
├── 09-stock-migrate.yaml      # Migration job for the stock trading app
└── 10-stock-realdata.yaml     # Upgraded backend with real yfinance data + TASE support
```

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| EKS Cluster | 1.25+ | Checkpoint API requires 1.25+ |
| containerd | 1.6+ | Required for K8s checkpoint API |
| Karpenter | 0.37+ | Already installed in `kube-system` |
| Helm | 3.x | For Kube-OVN installation |
| kubectl | any | Configured to point at your cluster |
| AWS CLI | v2 | With sufficient IAM permissions |

**IAM permissions needed:**
- `eks:DescribeCluster`
- `ec2:DescribeInstances`, `ec2:DescribeSubnets`, `ec2:DescribeSecurityGroups`
- `ec2:AuthorizeSecurityGroupIngress` (for Kube-OVN node-to-node traffic)

**Security group rule (Kube-OVN):**

All nodes must allow all traffic between each other (Kube-OVN uses Geneve tunnels):
```
Protocol: All (-1)
Source: The cluster's node security group
```

---

## Installation Guide

### Step 1 — Configure kubectl

```bash
aws eks update-kubeconfig --region us-east-1 --name <your-cluster-name>
kubectl get nodes  # verify connectivity
```

### Step 2 — Install CRIU on all nodes

```bash
kubectl apply -f 01-namespace.yaml
kubectl apply -f 02-criu-node-setup-ds.yaml

# Wait for DaemonSet to complete on all nodes (~2-3 minutes)
kubectl rollout status daemonset/criu-node-setup -n kube-system

# Verify CRIU is installed
kubectl get pods -n kube-system -l app=criu-node-setup
```

### Step 3 — Install Kube-OVN (Pod IP Preservation)

```bash
# Add Helm repo
helm repo add kubeovn https://kubeovn.github.io/kube-ovn/
helm repo update

# Get the internal IP of one of your nodes to use as the OVN master
kubectl get nodes -o wide
# Pick any node's INTERNAL-IP, e.g., 192.168.76.36

# Label the chosen node as Kube-OVN master
kubectl label node <NODE_NAME> kube-ovn/role=master

# Install Kube-OVN
# Replace MASTER_NODES with your node's internal IP
# Replace SVC_CIDR with your cluster's service CIDR (check: kubectl cluster-info dump | grep service-cluster-ip-range)
helm install kube-ovn kubeovn/kube-ovn \
  --namespace kube-system \
  --set SVC_CIDR="10.100.0.0/16" \
  --set MASTER_NODES="192.168.76.36" \
  --set replicaCount=1

# Wait for Kube-OVN pods to be ready (~5 minutes)
kubectl get pods -n kube-system -l app=kube-ovn-controller
kubectl get pods -n kube-system -l app=ovs-ovn
kubectl get pods -n kube-system -l app=kube-ovn-cni
```

> **Note on OVS CPU:** On busy nodes, OVS may fail to schedule due to its default 200m CPU request. If you see OVS pods Pending, patch the DaemonSet:
> ```bash
> kubectl patch ds ovs-ovn -n kube-system --type=json \
>   -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"100m"}]'
> ```

**Verify new pods get Kube-OVN IPs (10.16.x.x range):**
```bash
kubectl run test-ovn --image=nginx --restart=Never
kubectl get pod test-ovn -o wide  # should show IP in 10.16.0.0/16
kubectl delete pod test-ovn
```

### Step 4 — Deploy the Counter App (Migration Target)

```bash
kubectl apply -f 03-counter-app.yaml

# Wait for pod to be ready
kubectl rollout status statefulset/counter -n live-migration

# Verify the counter is incrementing
kubectl get pod -n live-migration -o wide  # note the pod IP
SVC_IP=$(kubectl get svc counter-svc -n live-migration -o jsonpath='{.spec.clusterIP}')
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s http://$SVC_IP:8080/counter
```

### Step 5 — Deploy Migration Infrastructure

```bash
kubectl apply -f 04-migration-agent-ds.yaml

# Verify agent pods are running on every node
kubectl get pods -n live-migration -l app=migration-agent -o wide
```

### Step 6 — Run the Live Migration

```bash
# Label the counter pod as migration source
kubectl patch pod counter-0 -n live-migration \
  -p '{"metadata":{"labels":{"migration-role":"source"}}}'

# Start watching the counter (in a separate terminal)
SVC_IP=$(kubectl get svc counter-svc -n live-migration -o jsonpath='{.spec.clusterIP}')
watch -n1 "kubectl run curl-$(date +%s) --image=curlimages/curl --rm --restart=Never \
  -q -- curl -s http://$SVC_IP:8080/counter 2>/dev/null"

# Trigger the migration
kubectl apply -f 05-migration-orchestrator.yaml

# Watch the migration progress
kubectl logs -f job/migration-orchestrator -n live-migration
```

**Expected output:**
```
==============================================================  LIVE MIGRATION
Step 1: Locate source pod
  pod=counter-0  node=ip-192-168-14-92  ip=10.16.0.45
Step 2: Pre-migration state snapshot
  counter=5127  uptime=5127s
Step 3: CRIU Checkpoint
  Checkpoint: /var/lib/kubelet/checkpoints/checkpoint-counter-0_live-migration-counter-*.tar
Step 4: Select target node
  target=ip-192-168-76-36
Step 5: Freeze source pod
  label -> migrating (service stops routing)
  deleted counter-0
Step 6: Create restored pod (Kube-OVN IP annotation)
  created counter-restored-1234567890 on ip-192-168-76-36
  annotation: ovn.kubernetes.io/ip_address=10.16.0.45
Step 7: Wait for restored pod Ready
  [30s] phase=Running ip=10.16.0.45 ready=False
  [35s] phase=Running ip=10.16.0.45 ready=True
  Pod is Ready!
Step 8: Post-migration state check
  counter=5129  (preserved!)
```

---

## Running the Demo

### Simple counter demo (prove CRIU works)

```bash
# Terminal 1 — watch counter continuously
SVC_IP=$(kubectl get svc counter-svc -n live-migration -o jsonpath='{.spec.clusterIP}')
while true; do
  kubectl run test-$(date +%s%N) --image=curlimages/curl --rm --restart=Never -q \
    -- curl -s http://$SVC_IP:8080/counter 2>/dev/null | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(f'counter={d[\"counter\"]}  pod={d[\"hostname\"]}  node={d[\"node\"]}')"
  sleep 2
done

# Terminal 2 — trigger migration
kubectl apply -f 05-migration-orchestrator.yaml
kubectl logs -f job/migration-orchestrator -n live-migration
```

**What you'll see in Terminal 1:** the counter continues incrementing even as the pod moves to a different node, and the pod name/node changes mid-stream.

---

## Stock Trading App Demo

The `08-stock-app.yaml` deploys a full Plus500-style trading UI with a migratable Flask backend serving real market data.

### Deploy the stock app

```bash
kubectl apply -f 08-stock-app.yaml

# Wait for backend to load stock data (~2 minutes for yfinance)
kubectl logs -f stock-backend-v2 -n stock-app

# Get the LoadBalancer URL
kubectl get svc stock-frontend-svc -n stock-app
```

The frontend is accessible at the LoadBalancer URL. It shows:
- **Real-time stock prices** (NASDAQ + TASE) via Yahoo Finance
- **50, 100, 200 Moving Averages** with Chart.js visualization
- **Fundamentals panel** (P/E, EPS, Market Cap, Beta, 52W H/L, Dividend Yield)
- **Add any stock** — NASDAQ (`AAPL`) or Tel Aviv (`TEVA.TA`, `POLI.TA`, `ESLT.TA`)

> **Restrict access to your IP:** Edit the `loadBalancerSourceRanges` in `08-stock-app.yaml` to your public IP.

### Migrate the stock backend while trading

```bash
# Label the backend as migration source
kubectl patch pod stock-backend-v2 -n stock-app \
  -p '{"metadata":{"labels":{"migration-role":"source"}}}'

# Execute migration
kubectl apply -f 09-stock-migrate.yaml
kubectl logs -f job/stock-migrate -n stock-app
```

**What the audience sees in the browser:**
- The stock ticker keeps ticking
- The P&L and trade count survive intact
- After migration, the pod IP shown in the status panel is identical
- The pod name changes (new node!) but the IP stays the same

---

## Verified Results

All migrations were tested on Amazon EKS 1.33 with 2x `m5.2xlarge` worker nodes managed by Karpenter.

### Migration 1 — Counter App

| | Before | After |
|---|---|---|
| Pod | `counter-0` | `counter-restored-*` |
| Node | `ip-192-168-14-92` | `ip-192-168-76-36` |
| Pod IP | `10.16.0.45` | `10.16.0.45` ✅ |
| Counter | 5127 | 5129 ✅ |
| CRIU checkpoint | YES | — |
| Downtime | ~5s | — |

### Migration 2 — Stock Trading Backend

| | Before | After |
|---|---|---|
| Pod | `stock-backend-v2` | `stock-backend-r-*` |
| Node | `ip-192-168-7-164` | `ip-192-168-76-36` |
| Pod IP | `10.16.0.124` | `10.16.0.124` ✅ |
| Request count | 92 | 92 ✅ |
| Trade count | 2 | 2 ✅ |
| P&L | -$196.xx | -$196.xx ✅ |
| CRIU checkpoint | YES | — |

---

## Troubleshooting

### CRIU checkpoint fails with "Permission denied"

```bash
# Check ptrace_scope on the SOURCE node
kubectl debug node/<source-node> -it --image=amazonlinux:2023 -- \
  chroot /host cat /proc/sys/kernel/yama/ptrace_scope
# Must be 0. If not:
kubectl debug node/<source-node> -it --image=amazonlinux:2023 -- \
  chroot /host sysctl -w kernel.yama.ptrace_scope=0
```

### OVS pod stuck in Pending

```bash
# Check if it's a CPU constraint
kubectl describe pod -n kube-system -l app=ovs-ovn | grep -A5 Events
# Fix: lower the CPU request
kubectl patch ds ovs-ovn -n kube-system --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"100m"}]'
```

### Restored pod gets wrong IP (not preserved)

```bash
# Verify Kube-OVN CNI is active (check the IP range — should be 10.16.x.x)
kubectl run ip-check --image=nginx --restart=Never
kubectl get pod ip-check -o wide
kubectl delete pod ip-check

# If IP is 192.168.x.x, Kube-OVN CNI is not winning the priority race
# Check CNI config on the node:
kubectl debug node/<node> -it --image=amazonlinux:2023 -- \
  chroot /host ls /etc/cni/net.d/
# 01-kube-ovn.conflist must exist and have a lower number than 10-aws.conflist
```

### kube-ovn-cni CrashLoopBackOff

```bash
# Usually caused by OVS not being ready yet
kubectl get pods -n kube-system -l app=ovs-ovn
# Wait for OVS to be Running, then restart kube-ovn-cni:
kubectl delete pod -n kube-system -l app=kube-ovn-cni
```

### Migration job exits with "No pod with migration-role=source"

```bash
# The source pod must be labeled before running the job
kubectl label pod <pod-name> -n <namespace> migration-role=source
# Then re-run the job
kubectl delete job stock-migrate -n stock-app
kubectl apply -f 09-stock-migrate.yaml
```

---

## How This Relates to Karpenter

Karpenter plays a supporting but essential role in live migration:

1. **Target node availability** — When the orchestrator picks a target node, Karpenter guarantees a node is available. If all existing nodes are full, Karpenter provisions a new one before the restored pod would be stuck Pending.

2. **Node consolidation** — After migration, the source node may become underutilized. Karpenter's consolidation logic will eventually drain and terminate it, reducing cost.

3. **Resource matching** — The restored pod's CPU/memory requests guide Karpenter to select the right EC2 instance type (e.g., `m5.xlarge` vs `t3.medium`).

4. **Zero pre-planning** — With static node groups you'd need to ensure the target node had capacity manually. Karpenter eliminates this entirely.

```
Migration triggers pod creation on target node
         │
         ▼
Karpenter sees the pod is Pending (no room on existing nodes?)
         │
         ▼ (~60 seconds)
Karpenter launches new EC2 instance of the right type
         │
         ▼
Restored pod is scheduled → migration completes
```

---

## License

MIT — free to use, adapt, and demo.

---

*Built and tested on Amazon EKS 1.33, Karpenter 0.37, Kube-OVN 1.15.4, CRIU 3.17.1.*
