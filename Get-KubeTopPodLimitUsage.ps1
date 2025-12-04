<#
.SYNOPSIS
  Shows per-pod, per-container CPU and memory usage alongside configured resource limits and percentage-to-limit.

.DESCRIPTION
  Defines Get-KubeTopPodLimitUsage (alias: ktoph).

  It combines:
    1) Usage from: kubectl top pod --containers
    2) Limits from workload specs in the namespace:
       - Deployments
       - StatefulSets
       - DaemonSets
    3) Pod ownership from ownerReferences so output can include OwnerKind and Owner.
    4) Pod/container status data from kubectl get pod -o json:
       - Pod age
       - Container age
       - Container restarts

  Default output is colorized (Write-Host) with row-level severity:
    - Red:     Any restarts > 0, or high memory/CPU relative to thresholds
    - Yellow:  Approaching thresholds
    - Green:   Normal
    - Magenta: TOTAL row (if included)

.NOTES
  - CpuM is millicores (m). Example: 150m = 0.15 cores.
  - MemMi is mebibytes (Mi). Example: 1024Mi = 1Gi.
  - If a container has no CPU or memory limit set, the related *Limit* and *Pct* columns are blank.
  - Deployment owner is inferred from ReplicaSet naming: <deploymentName>-<hash>.
  - Pods are read fresh every run (pods change frequently).
  - Workload limits are cached in memory per namespace for the current PowerShell session (controlled by -LimitsCacheMinutes).
  - Restarts are per-container via .status.containerStatuses[].restartCount. Any restarts > 0 is an instant red row.

.PREREQUISITES
  - PowerShell 7+ (pwsh)
  - kubectl installed and available on PATH
  - metrics-server (or compatible metrics API) so `kubectl top` works
  - RBAC permissions to read pods + workloads in the namespace

.BASIC EXAMPLES
  # Basic scan for memory pressure (descending)
  ktoph -Namespace "default" -SortBy MemPct -Descending

  # Filter on any output column
  ktoph -Namespace "default" -Where { ($_.MemPct -ge 80) -or ($_.CpuPct -ge 90) } -IncludeTotals -SortBy MemPct -Descending

  # Container filter supports wildcards
  ktoph -Namespace "default" -Container @("api","worker*") -SortBy MemPct -Descending

  # Example matching common triage style
  clear;ktoph -Namespace "default" -Where { ($_.CpuM -ge 500) -or ($_.MemPct -ge 30) } -SortBy MemPct -Descending

  # Turn off colors (plain Format-Table)
  ktoph -Namespace "default" -NoColor

  # Emit objects for piping/exporting
  ktoph -Namespace "default" -PassThru | Export-Csv -NoTypeInformation -Path "./kube-top.csv"
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
    [ValidateSet("Container","CpuM","CpuPct","MemMi","MemPct","Pod","OwnerKind","Owner","Namespace","Restarts","PodAge","ContainerAge")]
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
    [int]$LimitsCacheMinutes = 60,

    # Output behavior
    [Parameter(Mandatory = $false)]
    [switch]$NoColor,

    [Parameter(Mandatory = $false)]
    [switch]$PassThru,

    # Percent-based thresholds (only apply when limits exist)
    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 100)]
    [double]$MemPctWarn = 50,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 100)]
    [double]$MemPctCrit = 80,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 100)]
    [double]$CpuPctWarn = 85,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 100)]
    [double]$CpuPctCrit = 95,

    # Absolute thresholds for CPU when CPU limits are not set (CpuPct is null)
    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 100000)]
    [int]$CpuMWarn = 500,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 100000)]
    [int]$CpuMCrit = 1000,

    # Optional absolute thresholds for memory usage (Mi). Disabled when 0.
    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 10000000)]
    [int]$MemMiWarn = 0,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 10000000)]
    [int]$MemMiCrit = 0
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

  function Format-Age {
    param([TimeSpan]$Span)
    if ($null -eq $Span) { return "" }
    if ($Span.TotalSeconds -lt 0) { return "" }

    $d = [int]$Span.TotalDays
    $h = $Span.Hours
    $m = $Span.Minutes

    if ($d -gt 0) { return "$($d)d$($h)h" }
    if ($Span.TotalHours -ge 1) { return "$($h)h$($m)m" }
    return "$([int]$Span.TotalMinutes)m"
  }

  function Get-RowSeverity {
    param($Row)

    # 0=Green, 1=Yellow, 2=Red
    $sev = 0

    # Any restarts are instantly critical
    if ($null -ne $Row.Restarts -and [int]$Row.Restarts -gt 0) {
      return 2
    }

    # Optional absolute mem thresholds (Mi)
    if ($MemMiCrit -gt 0 -and $null -ne $Row.MemMi -and [int]$Row.MemMi -ge $MemMiCrit) { $sev = [Math]::Max($sev, 2) }
    elseif ($MemMiWarn -gt 0 -and $null -ne $Row.MemMi -and [int]$Row.MemMi -ge $MemMiWarn) { $sev = [Math]::Max($sev, 1) }

    # Percent-based memory thresholds (only when limit exists)
    if ($null -ne $Row.MemPct) {
      if ([double]$Row.MemPct -ge $MemPctCrit) { $sev = [Math]::Max($sev, 2) }
      elseif ([double]$Row.MemPct -ge $MemPctWarn) { $sev = [Math]::Max($sev, 1) }
    }

    # CPU percent thresholds (only when limit exists)
    if ($null -ne $Row.CpuPct) {
      if ([double]$Row.CpuPct -ge $CpuPctCrit) { $sev = [Math]::Max($sev, 2) }
      elseif ([double]$Row.CpuPct -ge $CpuPctWarn) { $sev = [Math]::Max($sev, 1) }
    } else {
      # CPU millicore thresholds (when no CPU limit exists)
      if ($null -ne $Row.CpuM) {
        if ([int]$Row.CpuM -ge $CpuMCrit) { $sev = [Math]::Max($sev, 2) }
        elseif ([int]$Row.CpuM -ge $CpuMWarn) { $sev = [Math]::Max($sev, 1) }
      }
    }

    return $sev
  }

  function Write-ColorTable {
    param(
      [Parameter(Mandatory = $true)]
      [object[]]$Rows
    )

    $cols = @(
      "Namespace","OwnerKind","Owner","Pod","Container",
      "Restarts","PodAge","ContainerAge",
      "CpuM","CpuLimitM","CpuPct","MemMi","MemLimitMi","MemPct"
    )

    $stringRows = foreach ($r in $Rows) {
      $h = [ordered]@{}
      foreach ($c in $cols) {
        $v = $r.$c
        if ($null -eq $v) { $h[$c] = "" }
        else {
          if ($c -in @("CpuPct","MemPct")) {
            $h[$c] = if ($v -is [double] -or $v -is [float] -or $v -is [decimal]) { "{0:N1}" -f $v } else { "$($v)" }
          } else {
            $h[$c] = "$($v)"
          }
        }
      }
      [pscustomobject]$h
    }

    $widths = @{}
    foreach ($c in $cols) { $widths[$c] = $c.Length }

    foreach ($r in $stringRows) {
      foreach ($c in $cols) {
        $len = ($r.$c).ToString().Length
        if ($len -gt $widths[$c]) { $widths[$c] = $len }
      }
    }

    $header = ($cols | ForEach-Object { $_.PadRight($widths[$_]) }) -join "  "
    Write-Host $header -ForegroundColor Cyan

    $divider = ($cols | ForEach-Object { ("-" * $widths[$_]) }) -join "  "
    Write-Host $divider -ForegroundColor DarkGray

    for ($i = 0; $i -lt $Rows.Count; $i++) {
      $raw = $Rows[$i]
      $sr  = $stringRows[$i]

      $isTotal = ($raw.OwnerKind -eq "TOTAL")
      $sev = if ($isTotal) { 0 } else { Get-RowSeverity -Row $raw }

      $color =
        if ($isTotal) { "Magenta" }
        elseif ($sev -eq 2) { "Red" }
        elseif ($sev -eq 1) { "Yellow" }
        else { "Green" }

      $line = ($cols | ForEach-Object { ($sr.$_).PadRight($widths[$_]) }) -join "  "
      Write-Host $line -ForegroundColor $color
    }
  }

  if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Error "kubectl was not found on PATH."
    return
  }

  $nowDto = [DateTimeOffset]::UtcNow

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

  # Pods are read fresh every run so pod churn never breaks owner mapping
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

  $podOwnerMap = @{}                # podName -> { OwnerKind, OwnerName }
  $podStartMap = @{}                # podName -> DateTimeOffset?
  $podContainerStatusMap = @{}      # "pod|container" -> { Restarts, ContainerStartedAt }

  foreach ($p in ($podObj.items | Where-Object { $_ -ne $null })) {
    $pName = $p.metadata.name
    if (-not $pName) { continue }

    # owner mapping
    $owner = $p.metadata.ownerReferences | Select-Object -First 1
    $ownerKind = $owner.kind
    $ownerName = $owner.name

    if ($ownerKind -eq "ReplicaSet" -and $ownerName) {
      $deployName = ($ownerName -replace "-[^-]+$","")
      $podOwnerMap[$pName] = [pscustomobject]@{ OwnerKind = "Deployment"; OwnerName = $deployName }
    } elseif ($ownerKind -and $ownerName) {
      $podOwnerMap[$pName] = [pscustomobject]@{ OwnerKind = $ownerKind; OwnerName = $ownerName }
    } else {
      $podOwnerMap[$pName] = [pscustomobject]@{ OwnerKind = ""; OwnerName = "" }
    }

    # pod start time
    if ($p.status.startTime) {
      try { $podStartMap[$pName] = [DateTimeOffset]::Parse($p.status.startTime) } catch { }
    }

    # per-container restarts and startedAt
    foreach ($cs in @($p.status.containerStatuses)) {
      if (-not $cs -or -not $cs.name) { continue }

      $restarts = 0
      if ($null -ne $cs.restartCount) { $restarts = [int]$cs.restartCount }

      $startedAt = $null
      $startedAtStr = $null

      if ($cs.state -and $cs.state.running -and $cs.state.running.startedAt) {
        $startedAtStr = $cs.state.running.startedAt
      } elseif ($cs.lastState -and $cs.lastState.terminated -and $cs.lastState.terminated.startedAt) {
        $startedAtStr = $cs.lastState.terminated.startedAt
      } elseif ($cs.state -and $cs.state.terminated -and $cs.state.terminated.startedAt) {
        $startedAtStr = $cs.state.terminated.startedAt
      }

      if ($startedAtStr) {
        try { $startedAt = [DateTimeOffset]::Parse($startedAtStr) } catch { $startedAt = $null }
      }

      $podContainerStatusMap["$($pName)|$($cs.name)"] = [pscustomobject]@{
        Restarts         = $restarts
        ContainerStarted = $startedAt
      }
    }
  }

  # Workload limits are cached as they usually change rarely
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

  # Usage metrics per container
  $topRaw = & kubectl top pod -n $($Namespace) --containers --no-headers 2>&1
  if (-not $topRaw -or $topRaw.Count -eq 0) {
    if ($DebugKubectl) { $topRaw | ForEach-Object { Write-Host $_ } }
    Write-Error "No output from: kubectl top pod -n $($Namespace) --containers --no-headers"
    return
  }

  # Force array output so IncludeTotals always works even with 1 row
  $rows = @(
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

        $podAge = ""
        if ($podStartMap.ContainsKey($podName)) {
          $podAge = Format-Age -Span ($nowDto - $podStartMap[$podName])
        }

        $restarts = 0
        $containerAge = ""
        $key = "$($podName)|$($containerName)"
        if ($podContainerStatusMap.ContainsKey($key)) {
          $restarts = [int]$podContainerStatusMap[$key].Restarts
          if ($podContainerStatusMap[$key].ContainerStarted) {
            $containerAge = Format-Age -Span ($nowDto - $podContainerStatusMap[$key].ContainerStarted)
          }
        }

        [pscustomobject]@{
          Namespace     = $Namespace
          OwnerKind     = $ownerKind
          Owner         = $ownerName
          Pod           = $podName
          Container     = $containerName
          Restarts      = $restarts
          PodAge        = $podAge
          ContainerAge  = $containerAge
          CpuM          = $cpuM
          CpuLimitM     = $cpuLimitM
          CpuPct        = $cpuPct
          MemMi         = $memMi
          MemLimitMi    = $memLimitMi
          MemPct        = $memPct
        }
      } elseif ($DebugKubectl) {
        Write-Host $line
      }
    } |
    Where-Object { $_ -ne $null }
  )

  if (-not $rows -or $rows.Count -eq 0) {
    if ($DebugKubectl) {
      Write-Host "kubectl returned (stdout/stderr combined):"
      $topRaw | ForEach-Object { Write-Host $_ }
    }
    Write-Error "No parsable rows from kubectl top output."
    return
  }

  if ($Where) {
    $rows = @($rows | Where-Object $Where)
  }

  $sortExpr = @{ Expression = $SortBy; Descending = [bool]$Descending }

  # Force array output so output and "+=" behave reliably
  $sorted = @($rows | Sort-Object Container, $sortExpr, Pod)

  if ($IncludeTotals) {
    $cpuTotalM = [double](($sorted | Measure-Object CpuM -Sum).Sum)
    $memTotalMi = [double](($sorted | Measure-Object MemMi -Sum).Sum)
    $cpuLimitTotalM = [double](($sorted | Where-Object { $_.CpuLimitM } | Measure-Object CpuLimitM -Sum).Sum)
    $memLimitTotalMi = [double](($sorted | Where-Object { $_.MemLimitMi } | Measure-Object MemLimitMi -Sum).Sum)

    $sorted += [pscustomobject]@{
      Namespace     = $Namespace
      OwnerKind     = "TOTAL"
      Owner         = ""
      Pod           = ""
      Container     = ""
      Restarts      = ""
      PodAge        = ""
      ContainerAge  = ""
      CpuM          = [int]$cpuTotalM
      CpuLimitM     = if ($cpuLimitTotalM -gt 0) { [int]$cpuLimitTotalM } else { $null }
      CpuPct        = if ($cpuLimitTotalM -gt 0) { [Math]::Round(($cpuTotalM / $cpuLimitTotalM) * 100, 1) } else { $null }
      MemMi         = [int]$memTotalMi
      MemLimitMi    = if ($memLimitTotalMi -gt 0) { [int]$memLimitTotalMi } else { $null }
      MemPct        = if ($memLimitTotalMi -gt 0) { [Math]::Round(($memTotalMi / $memLimitTotalMi) * 100, 1) } else { $null }
    }
  }

  if (-not $sorted -or $sorted.Count -eq 0) {
    Write-Host "No rows matched the current filters." -ForegroundColor DarkYellow
    return
  }

  if ($PassThru) { return $sorted }

  if ($NoColor) {
    $sorted | Format-Table Namespace, OwnerKind, Owner, Pod, Container, Restarts, PodAge, ContainerAge, CpuM, CpuLimitM, CpuPct, MemMi, MemLimitMi, MemPct -AutoSize
    return
  }

  Write-ColorTable -Rows $sorted
}

Set-Alias ktoph Get-KubeTopPodLimitUsage
