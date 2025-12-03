# Kubernetes Scripts

A grab-bag repo for small Kubernetes utilities and helper scripts. The goal is fast, copy-paste-friendly commands for day-to-day cluster triage, backed by small PowerShell wrappers when it makes sense.

## Current scripts

* `Get-KubeTopPodLimitUsage.ps1`

  * Joins `kubectl top pod --containers` usage with configured resource limits from workloads, then calculates how close each container is to its limits.

## Repo layout

* Scripts live in the repo root (for now).
* Each script is designed to be dot-sourced and used as a command.
* Common pattern: a function plus a short alias.

## Requirements

* PowerShell 7+ (`pwsh`) on Windows, Linux, or macOS
* `kubectl` installed and available on `PATH`
* Kubernetes Metrics API available (metrics-server) for scripts that rely on `kubectl top`
* Appropriate RBAC permissions for the namespaces you query

## Quick start

Dot-source a script to make its functions available in your current session.

If you are running from inside the repo folder:

```powershell
. (Join-Path $PSScriptRoot "Get-KubeTopPodLimitUsage.ps1")
```

Verify it loaded:

```powershell
Get-Command ktoph
```

## Load scripts automatically via $PROFILE

If you keep scripts in the same folder as your PowerShell profile file, dot-source them like this:

```powershell
. (Join-Path -Path (Split-Path -Parent $PROFILE) -ChildPath "Get-KubeTopPodLimitUsage.ps1")
```

Reload your profile:

```powershell
. $PROFILE
```

## Script: Get-KubeTopPodLimitUsage.ps1

### What it does

It combines three sources of information:

1. **Usage** from `kubectl top pod --containers`
2. **Limits** from workload specs in the namespace:

   * Deployments
   * StatefulSets
   * DaemonSets
3. **Ownership** from pod metadata (ownerReferences), so results can show which workload a pod belongs to

It outputs a table per pod container containing:

* `CpuM`, `MemMi` from `kubectl top`
* `CpuLimitM`, `MemLimitMi` from workload specs
* `CpuPct`, `MemPct` computed as usage divided by limit
* `OwnerKind` and `Owner` (best-effort) to indicate which workload a pod belongs to

Notes:

* If a container has **no CPU or memory limit**, the related limit and percent columns are blank.
* For Deployment-managed pods, the owner is derived from pod ownerReferences (ReplicaSet) and the typical ReplicaSet naming pattern.

### Output columns

| Column     | Meaning                                                            |
| ---------- | ------------------------------------------------------------------ |
| Namespace  | Namespace queried                                                  |
| OwnerKind  | Workload type (Deployment, StatefulSet, DaemonSet) when resolvable |
| Owner      | Workload name when resolvable                                      |
| Pod        | Pod name                                                           |
| Container  | Container name                                                     |
| CpuM       | CPU usage in millicores                                            |
| CpuLimitM  | CPU limit in millicores (blank if none set)                        |
| CpuPct     | CPU usage / CPU limit * 100 (blank if no limit)                    |
| MemMi      | Memory usage in Mi                                                 |
| MemLimitMi | Memory limit in Mi (blank if none set)                             |
| MemPct     | Memory usage / memory limit * 100 (blank if no limit)              |

### Caching behavior

* **Pods** are read fresh every run (pods change frequently).
* **Workload limits** are cached in memory for the PowerShell session, by namespace.

  * Controlled by `-LimitsCacheMinutes` (default: 60).

### Usage

After dot-sourcing, use the alias `ktoph`.

Basic scan for memory pressure:

```powershell
ktoph -Namespace "default" -SortBy MemPct -Descending
```

Filter by container name (supports wildcards):

```powershell
ktoph -Namespace "default" -Container @("api","worker*") -SortBy MemPct -Descending
```

Filter on any output column:

```powershell
ktoph -Namespace "default" -Where { ($_.MemPct -ge 80) -or ($_.CpuPct -ge 90) } -SortBy MemPct -Descending
```

Example (structure):

```powershell
ktoph -Namespace "my-namespace" -Where { ($_.CpuM -ge 150) -or ($_.MemPct -ge 30) } -IncludeTotals -SortBy MemPct -Descending
```

Include totals:

* Adds a final `TOTAL` row summing CPU and memory usage.
* Also computes overall % for CPU and memory where limits exist.

```powershell
ktoph -Namespace "default" -IncludeTotals -SortBy MemPct -Descending
```

Debug mode:

* `-DebugKubectl` prints raw kubectl output if parsing fails.

```powershell
ktoph -Namespace "default" -DebugKubectl
```

### Notes on interpretation

* **Memory** close to limit is the risky one. Sustained high `MemPct` is usually how you end up with OOMKills when the process spikes.
* **CPU** behaves differently. CPU limits can cause throttling rather than killing the process. High `CpuPct` may be fine or may be a performance issue depending on latency and throttling.

### Troubleshooting

Validate metrics are available:

```powershell
kubectl top pod -n "default"
kubectl top node
```

If `kubectl top` fails, common causes:

* Metrics server is not installed or not healthy
* RBAC does not allow reading the metrics API
* You are pointed at the wrong cluster or context

Useful checks:

```powershell
kubectl config current-context
kubectl get apiservices | Select-String -Pattern "metrics" -SimpleMatch
kubectl auth can-i get pods -n "default"
kubectl auth can-i get pods.metrics.k8s.io -n "default"
```
