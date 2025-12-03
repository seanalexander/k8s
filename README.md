# Kubernetes Troubleshooting Scripts (pwsh)

A small collection of Kubernetes helper scripts focused on day-to-day troubleshooting and fast visibility into what is happening in a cluster.

This repo is designed to work anywhere `pwsh` and `kubectl` work, including Windows, Linux, and macOS.

## Contents

### `Get-KubeTopPodLimitUsage.ps1`
Defines the function `Get-KubeTopPodLimitUsage` (alias: `ktoph`).

It combines:
- `kubectl top pod --containers` (current CPU and memory usage)
- Workload resource **limits** (Deployments, StatefulSets, DaemonSets)
- Pod ownership (so you can see which workload a pod belongs to)

It also exposes pod lifecycle signals from `kubectl get pods -o json`:
- **Restarts** (per container)
- **PodAge**
- **ContainerAge**

## Key features

- **Per container view**: Pod + container, not just pod totals.
- **Owner mapping**: Shows which Deployment (or other controller) a pod belongs to.
- **Limits awareness**: Adds CpuLimitM / MemLimitMi and calculates CpuPct / MemPct when limits exist.
- **Age and restarts**:
  - `Restarts` is taken from `.status.containerStatuses[].restartCount`
  - `PodAge` from `.status.startTime`
  - `ContainerAge` from container started timestamps (best effort)
  - Any container with **Restarts > 0 is highlighted red**.
- **Color output** (default):
  - Green: normal
  - Yellow: warning thresholds met
  - Red: critical thresholds met, or Restarts > 0
  - Magenta: totals row (only if you opt in)
- **Filtering and sorting**:
  - `-Container @("service-a","worker*")`
  - `-Where { ... }` against any property
  - `-SortBy MemPct -Descending`
- **Session caching**:
  - Workload limits are cached per namespace for the current PowerShell session (`-LimitsCacheMinutes`).
  - Pods are always read fresh each run so churn is handled correctly.
- **Output modes**:
  - Default: colored console output
  - `-NoColor`: plain table output
  - `-PassThru`: emit objects for piping/exporting
- Optional absolute memory thresholds:
  - `-MemMiWarn` / `-MemMiCrit` let you color based on absolute Mi usage in addition to percent-based thresholds.

## Requirements

- PowerShell 7+ (`pwsh`)
- `kubectl` on PATH
- A working Metrics API in the cluster (metrics-server or equivalent) so `kubectl top` works
- RBAC permissions to read:
  - pods in the namespace
  - deployments/statefulsets/daemonsets in the namespace

## Install / import into your profile

Place the script next to your `$PROFILE` file, then dot-source it from your profile:

```powershell
. (Join-Path -Path (Split-Path -Parent $($PROFILE)) -ChildPath "Get-KubeTopPodLimitUsage.ps1")
````

Reload your profile:

```powershell
. $($PROFILE)
```

Confirm the alias exists:

```powershell
Get-Command ktoph
```

## Notes on units

* `CpuM` is millicores: `150m = 0.15 cores`
* `MemMi` is Mi: `1024Mi = 1Gi`
* If CPU or memory **limits are not set**, the related Limit and Pct columns will be blank.
* `-Where` controls what rows are returned.
* Threshold parameters like `-MemPctCrit` control coloring, not filtering.

## Basic examples

### 1) Simple scan

```powershell
ktoph -Namespace "default" -SortBy MemPct -Descending
```

### 2) Filter on any output column

```powershell
ktoph -Namespace "default" `
  -Where { ($_.MemPct -ge 80) -or ($_.CpuPct -ge 90) -or ($_.Restarts -gt 0) } `
  -SortBy MemPct -Descending
```

### 3) Filter by containers (supports wildcards)

```powershell
ktoph -Namespace "default" -Container @("service-a","worker*") -SortBy MemPct -Descending
```

### 4) Disable color output

```powershell
ktoph -Namespace "default" -NoColor -SortBy MemPct -Descending
```

### 5) Emit objects for piping/exporting

```powershell
ktoph -Namespace "default" -PassThru |
  Export-Csv -NoTypeInformation -Path "./kube-top.csv"
```

### 6) Show anything that restarted (instant red rows)

```powershell
ktoph -Namespace "default" -Where { $_.Restarts -gt 0 } -SortBy Restarts -Descending
```

## Threshold tuning examples

### Function style: CPU critical at 900m, Memory critical at 50%

```powershell
ktoph -Namespace "default" `
  -Where { ($_.CpuM -ge 900) -or ($_.MemPct -ge 40) } `
  -SortBy MemPct -Descending `
  -CpuMWarn 500 -CpuMCrit 900 `
  -MemPctWarn 40 -MemPctCrit 50
```

### Absolute Mi coloring (useful when you care about raw memory usage)

```powershell
ktoph -Namespace "default" `
  -Where { ($_.MemMi -ge 5000) -or ($_.Restarts -gt 0) } `
  -SortBy MemMi -Descending `
  -MemMiWarn 5000 -MemMiCrit 5000
```

## Combined “two views” example (run back-to-back)

```powershell
clear

Write-Host "=== Service A + Service B (CpuM >= 1000 OR MemMi >= 5000 OR Restarts > 0) ===" -ForegroundColor Cyan
ktoph -Namespace "my-namespace" `
  -Container @("service-a","service-b") `
  -Where { ($_.CpuM -ge 1000) -or ($_.MemMi -ge 5000) -or ($_.Restarts -gt 0) } `
  -SortBy MemMi -Descending `
  -CpuMWarn 1000 -CpuMCrit 1000 `
  -MemMiWarn 5000 -MemMiCrit 5000

Write-Host "`n=== Worker (CpuM >= 2000 OR MemPct >= 50 OR Restarts > 0) ===" -ForegroundColor Cyan
ktoph -Namespace "my-namespace" `
  -Container @("worker") `
  -Where { ($_.CpuM -ge 2000) -or ($_.MemPct -ge 50) -or ($_.Restarts -gt 0) } `
  -SortBy MemPct -Descending `
  -CpuMWarn 2000 -CpuMCrit 2000 `
  -MemPctWarn 50 -MemPctCrit 50
```

## Troubleshooting

### `kubectl top` returns nothing

* Metrics API is not available or not healthy. Validate with:

  * `kubectl top nodes`
  * `kubectl get apiservices | Select-String metrics`

### Script returns “No rows matched the current filters.”

* Your `-Where { ... }` filter excluded everything. Remove `-Where` to confirm baseline output.

### Debugging parsing or kubectl output

Use `-DebugKubectl` to print raw lines/output when parsing fails:

```powershell
ktoph -Namespace "default" -DebugKubectl
```

## Tips

* Totals are opt-in only. If you do not pass `-IncludeTotals`, no totals row is calculated or printed.
* For repeatable triage, prefer filters based on `MemPct` when limits exist, and `MemMi` when you care about absolute memory.
