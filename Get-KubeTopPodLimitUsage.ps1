<#
.SYNOPSIS
  Shows per-pod, per-container CPU and memory usage alongside configured resource limits and percentage-to-limit.

.DESCRIPTION
  This script defines:
    - Get-KubeTopPodLimitUsage: A function that joins:
        1) "kubectl top pod --containers" usage
        2) Workload container limits from Deployments/StatefulSets/DaemonSets
        3) Pod ownership metadata so results can include owner kind/name

  It outputs a table with:
    Namespace, OwnerKind, Owner, Pod, Container,
    CpuM, CpuLimitM, CpuPct, MemMi, MemLimitMi, MemPct

  Notes:
    - CpuM is millicores (m). Example: 150m = 0.15 cores.
    - MemMi is mebibytes (Mi). Example: 1024Mi = 1Gi.
    - If a container has no limit set, limit and percent columns are blank.
    - Owner for Deployment pods is inferred from ReplicaSet naming as "<deploymentName>-<hash>".

.PREREQUISITES
  - kubectl installed and available on PATH
  - Metrics API available (metrics-server) for `kubectl top` to work
  - Permissions to read pods and relevant workloads in the namespace

.USAGE
  1) Dot-source this file in your PowerShell profile:
       . "C:\path\to\Get-KubeTopPodLimitUsage.ps1"

     Or paste the function into your $PROFILE directly.

  2) Use the alias:
       ktoph -Namespace <namespace>

#>

function Get-KubeTopPodLimitUsage {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $false)]
    [string]$Namespace = "default",

    # Filter by container name (exact matches or wildcards like "api*")
    [Parameter(Mandatory = $false)]
    [string[]]$Container,

    # Filter on any output column, e.g. { $_.MemPct -ge 80 -or $_.CpuPct -ge 90 }
    [Parameter(Mandatory = $false)]
    [scriptblock]$Where,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Container","CpuM","CpuPct","MemMi","MemPct","Pod","OwnerKind","Owner","Namespace")]
    [string]$SortBy = "MemPct",

    [Parameter(Mandatory = $false)]
    [switch]$Descending,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeTotals,

    # If parsing fails, prints raw kubectl output to help troubleshoot
    [Parameter(Mandatory = $false)]
    [switch]$DebugKubectl,

    # Cache workload limits for this many minutes (pods are read fresh every run)
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 1440)]
    [int]$LimitsCacheMinutes = 60
  )

  function Convert-K8sCpuToMillicores {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    if ($v -match "m$") { return [int]($v -replace "m$","") }
    [int]([double]$v * 1000)
  }

  function Convert-K8sMemToMi {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()

    if ($v -match "^(?<num>\d+(\.\d+)?)(?<unit>Ki|Mi|Gi|Ti|Pi|Ei|K|M|G|T|P|E)?$") {
      $n = [double]$Matches["num"]
      $u = $Matches["unit"]
      switch ($u) {
        "Ki" { return [int]($n / 1024) }
        "Mi" { return [int]$n }
        "Gi" { return [int]($n * 1024) }
        "Ti" { return [int]($n * 1024 * 1024) }
        "Pi" { return [int]($n * 1024 * 1024 * 1024) }
        "Ei" { return [int]($n * 1024 * 1024 * 1024 * 1024) }

        # Decimal SI (best-effort), converted to Mi
        "K"  { return [int](($n * 1000) / 1024 / 1024) }
        "M"  { return [int](($n * 1000 * 1000) / 1024 / 1024) }
        "G"  { return [int](($n * 1000 * 1000 * 1000) / 1024 / 1024) }
        "T"  { return [int](($n * 1000 * 1000 * 1000 * 1000) / 1024 / 1024) }
        "P"  { return [int](($n * 1000 * 1000 * 1000 * 1000 * 1000) / 1024 / 1024) }
        "E"  { return [int](($n * 1000 * 1000 * 1000 * 1000 * 1000 * 1000) / 1024 / 1024) }

        default { return [int]($n / 1024 / 1024) }
      }
    }

    return $null
  }

  function Match-AnyPattern {
    param(
      [string]$Value,
      [string[]]$Patterns
    )
    if (-not $Patterns -or $Patterns.Count -eq 0) { return $true }
    foreach ($p in $Patterns) {
      if ([string]::IsNullOrWhiteSpace($p)) { continue }
      if ($Value -like $p) { return $true }
    }
    return $false
  }

  if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Error "kubectl was not found on PATH."
    return
  }

  # Cache limits per namespace for the current PowerShell session
  if (-not $script:KubeTopLimitCache) { $script:KubeTopLimitCache = @{} }
  $cacheKey = "ns:$($Namespace)"
  $now = Get-Date

  if (-not $script:KubeTopLimitCache.ContainsKey($cacheKey)) {
    $script:KubeTopLimitCache[$cacheKey] = [pscustomobject]@{
      LimitsBuiltAt  = [datetime]::MinValue
      WorkloadLimits = $null
    }
  }

  $cache = $script:KubeTopLimitCache[$cacheKey]

  # 1) Pods are read fresh every run so pod churn never breaks owner mapping
  $podJsonRaw = & kubectl get pod -n $($Namespace) -o json 2>&1
  if (-not $podJsonRaw) {
    if ($DebugKubectl) { $podJsonRaw | ForEach-Object { Write-Host $_ } }
    Write-Error "No output from: kubectl get pod -n $($Namespace) -o json"
    return
  }

  try { $podObj = $podJsonRaw | ConvertFrom-Json }
  catch {
    if ($DebugKubectl) { $podJsonRaw | ForEach-Object { Write-Host $_ } }
    Write-Error "Failed to parse pod JSON."
    return
  }

  $podOwnerMap = @{} # podName -> { OwnerKind, OwnerName }
  foreach ($p in ($podObj.items | Where-Object { $_ -ne $null })) {
    $pName = $p.metadata.name
    if (-not $pName) { continue }

    $owner = $p.metadata.ownerReferences | Select-Object -First 1
    $ownerKind = $owner.kind
    $ownerName = $owner.name

    if ($ownerKind -eq "ReplicaSet" -and $ownerName) {
      # ReplicaSet name is usually "<deploymentName>-<hash>"
      $deployName = ($ownerName -replace "-[^-]+$","")
      $podOwnerMap[$pName] = [pscustomobject]@{ OwnerKind = "Deployment"; OwnerName = $deployName }
    } elseif ($ownerKind -and $ownerName) {
      $podOwnerMap[$pName] = [pscustomobject]@{ OwnerKind = $ownerKind; OwnerName = $ownerName }
    } else {
      $podOwnerMap[$pName] = [pscustomobject]@{ OwnerKind = ""; OwnerName = "" }
    }
  }

  # 2) Workload limits are cached as they usually change rarely
  $limitsExpired = ($cache.LimitsBuiltAt.AddMinutes($LimitsCacheMinutes) -lt $now)
  if (-not $cache.WorkloadLimits -or $limitsExpired) {
    $workloadLimits = @{
      Deployment  = @{}
      StatefulSet = @{}
      DaemonSet   = @{}
    }

    foreach ($kind in @("deploy","statefulset","daemonset")) {
      $jsonRaw = & kubectl get $kind -n $($Namespace) -o json 2>&1
      if (-not $jsonRaw) { continue }

      try { $obj = $jsonRaw | ConvertFrom-Json }
      catch {
        if ($DebugKubectl) { $jsonRaw | ForEach-Object { Write-Host $_ } }
        Write-Error "Failed to parse JSON for: kubectl get $($kind) -n $($Namespace) -o json"
        return
      }

      foreach ($item in ($obj.items | Where-Object { $_ -ne $null })) {
        $wName = $item.metadata.name
        if (-not $wName) { continue }

        $containerMap = @{}
        foreach ($c in ($item.spec.template.spec.containers | Where-Object { $_ -ne $null })) {
          $cName = $c.name
          if (-not $cName) { continue }

          $containerMap[$cName] = [pscustomobject]@{
            CpuLimitM  = Convert-K8sCpuToMillicores $c.resources.limits.cpu
            MemLimitMi = Convert-K8sMemToMi $c.resources.limits.memory
          }
        }

        switch ($kind) {
          "deploy"      { $workloadLimits["Deployment"][$wName]  = $containerMap }
          "statefulset" { $workloadLimits["StatefulSet"][$wName] = $containerMap }
          "daemonset"   { $workloadLimits["DaemonSet"][$wName]   = $containerMap }
        }
      }
    }

    $cache.WorkloadLimits = $workloadLimits
    $cache.LimitsBuiltAt  = $now
  }

  # 3) Usage metrics per container
  $topRaw = & kubectl top pod -n $($Namespace) --containers --no-headers 2>&1
  if (-not $topRaw -or $topRaw.Count -eq 0) {
    if ($DebugKubectl) { $topRaw | ForEach-Object { Write-Host $_ } }
    Write-Error "No output from: kubectl top pod -n $($Namespace) --containers --no-headers"
    return
  }

  $rows =
    $topRaw |
    ForEach-Object {
      $line = $_.ToString().Trim()
      if ([string]::IsNullOrWhiteSpace($line)) { return }

      if ($line -match "^(?<Pod>\S+)\s+(?<Container>\S+)\s+(?<Cpu>\S+)\s+(?<Mem>\S+)$") {
        $podName = $Matches["Pod"]
        $containerName = $Matches["Container"]

        if (-not (Match-AnyPattern -Value $containerName -Patterns $Container)) { return }

        $cpuM  = Convert-K8sCpuToMillicores $Matches["Cpu"]
        $memMi = Convert-K8sMemToMi $Matches["Mem"]

        $owner = $podOwnerMap[$podName]
        $ownerKind = $owner.OwnerKind
        $ownerName = $owner.OwnerName

        $cpuLimitM = $null
        $memLimitMi = $null

        if ($ownerKind -and $ownerName -and $cache.WorkloadLimits.ContainsKey($ownerKind)) {
          $kindMap = $cache.WorkloadLimits[$ownerKind]
          if ($kindMap -and $kindMap.ContainsKey($ownerName)) {
            $cMap = $kindMap[$ownerName]
            if ($cMap -and $cMap.ContainsKey($containerName)) {
              $cpuLimitM  = $cMap[$containerName].CpuLimitM
              $memLimitMi = $cMap[$containerName].MemLimitMi
            }
          }
        }

        $cpuPct = if ($cpuLimitM) { [Math]::Round(($cpuM / $cpuLimitM) * 100, 1) } else { $null }
        $memPct = if ($memLimitMi) { [Math]::Round(($memMi / $memLimitMi) * 100, 1) } else { $null }

        [pscustomobject]@{
          Namespace  = $Namespace
          OwnerKind  = $ownerKind
          Owner      = $ownerName
          Pod        = $podName
          Container  = $containerName
          CpuM       = $cpuM
          CpuLimitM  = $cpuLimitM
          CpuPct     = $cpuPct
          MemMi      = $memMi
          MemLimitMi = $memLimitMi
          MemPct     = $memPct
        }
      } elseif ($DebugKubectl) {
        Write-Host $line
      }
    } |
    Where-Object { $_ -ne $null }

  if (-not $rows -or $rows.Count -eq 0) {
    if ($DebugKubectl) {
      Write-Host "kubectl returned (stdout/stderr combined):"
      $topRaw | ForEach-Object { Write-Host $_ }
    }
    Write-Error "No parsable rows from kubectl top output."
    return
  }

  # Optional filter on any output column
  if ($Where) {
    $rows = $rows | Where-Object $Where
  }

  $sortExpr = @{ Expression = $SortBy; Descending = [bool]$Descending }

  # Always group by container first so multiple workloads are easier to scan
  $sorted = $rows | Sort-Object Container, $sortExpr, Pod

  if ($IncludeTotals) {
    $cpuTotalM = ($sorted | Measure-Object CpuM -Sum).Sum
    $memTotalMi = ($sorted | Measure-Object MemMi -Sum).Sum
    $cpuLimitTotalM = ($sorted | Where-Object { $_.CpuLimitM } | Measure-Object CpuLimitM -Sum).Sum
    $memLimitTotalMi = ($sorted | Where-Object { $_.MemLimitMi } | Measure-Object MemLimitMi -Sum).Sum

    $sorted += [pscustomobject]@{
      Namespace  = $Namespace
      OwnerKind  = "TOTAL"
      Owner      = ""
      Pod        = ""
      Container  = ""
      CpuM       = [int]$cpuTotalM
      CpuLimitM  = if ($cpuLimitTotalM) { [int]$cpuLimitTotalM } else { $null }
      CpuPct     = if ($cpuLimitTotalM) { [Math]::Round(($cpuTotalM / $cpuLimitTotalM) * 100, 1) } else { $null }
      MemMi      = [int]$memTotalMi
      MemLimitMi = if ($memLimitTotalMi) { [int]$memLimitTotalMi } else { $null }
      MemPct     = if ($memLimitTotalMi) { [Math]::Round(($memTotalMi / $memLimitTotalMi) * 100, 1) } else { $null }
    }
  }

  $sorted | Format-Table Namespace, OwnerKind, Owner, Pod, Container, CpuM, CpuLimitM, CpuPct, MemMi, MemLimitMi, MemPct -AutoSize
}

# Convenience alias
Set-Alias ktoph Get-KubeTopPodLimitUsage

<#
BASIC EXAMPLES

  # Show everything in a namespace, sorted by MemPct descending
  ktoph -Namespace authentisign -SortBy MemPct -Descending

  # Only show a specific container name (supports wildcards)
  ktoph -Namespace authentisign -Container @("api") -SortBy MemPct -Descending

  # Filter by any output column
  ktoph -Namespace authentisign -Where { $_.MemPct -ge 80 -or $_.CpuPct -ge 90 } -IncludeTotals -SortBy MemPct -Descending

  # Example requested
  ktoph -Namespace authentisign -Where { ($_.CpuM -ge 150) -or ($_.MemPct -ge 30) } -IncludeTotals -SortBy MemPct -Descending

PROFILE SETUP

  Add this line to your PowerShell profile to load it automatically:
    . "C:\path\to\Get-KubeTopPodLimitUsage.ps1"

  Open your profile:
    notepad $PROFILE

#>
