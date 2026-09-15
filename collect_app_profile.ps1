#!/usr/bin/env pwsh
<#
.SYNOPSIS
Collects a read-only VMware vSphere application VM performance profile.

.DESCRIPTION
PowerShell/PowerCLI port of collect_app_profile.py. It accepts the same logical
parameters and writes the same schema-version 1.0 JSON structure for use by
whatif_app_stack.py and the vSphere Scalability Analyst.

The script makes read-only vSphere API calls. Several disk counters have no
aggregate (instance="") VM series, so per-device instances are discovered and
combined at each timestamp: IOPS and aborted commands are summed across devices,
while per-command read/write latency is averaged. Latency prefers the VM-scoped
virtualDisk.* counters (collected at statistics level 1) over the host-scoped
disk.totalReadLatency/totalWriteLatency counters, which are never populated on a
VM entity.

.EXAMPLE
./collect_app_profile.ps1 -Host vcenter.example.com -User admin@vsphere.local `
  -VMs "web01,web02,app01" -Interval 336 -JsonOut app_profile.json

.EXAMPLE
./collect_app_profile.ps1 -Host vcenter.example.com -User admin@vsphere.local `
  -VmFile vms.txt -AppName "CRM-v2" -JsonOut crm_profile.json
#>

#requires -Version 5.1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword',
    '',
    Justification = 'Preserves the Python collector CLI; secure prompt is the default and -Password is discouraged.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingConvertToSecureStringWithPlainText',
    '',
    Justification = 'Required only for the compatible -Password argument and VSPHERE_PASSWORD environment variable.'
)]
[CmdletBinding()]
param(
    # $Host is a read-only PowerShell automatic variable, so the implementation
    # name differs while the public alias remains -Host/--host.
    [Parameter(Mandatory = $true)]
    [Alias('host')]
    [string]$VCenterHost,

    [ValidateRange(1, 65535)]
    [int]$Port = 443,

    [Parameter(Mandatory = $true)]
    [string]$User,

    [string]$Password,

    [Alias('no-ssl-verify')]
    [switch]$NoSslVerify,

    [string]$VMs,

    [Alias('vm-file')]
    [string]$VmFile,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$Interval = 336,

    [Alias('app-name')]
    [string]$AppName = '',

    [Parameter(Mandatory = $true)]
    [Alias('json-out')]
    [string]$JsonOut
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$VmPerfCounters = @(
    'cpu.usage.average',
    'cpu.usagemhz.average',
    'cpu.ready.summation',
    'cpu.costop.summation',
    'cpu.latency.average',
    'cpu.demand.average',
    'mem.usage.average',
    'mem.active.average',
    'mem.consumed.average',
    'mem.vmmemctl.average',
    'mem.swapped.average',
    'mem.overhead.average',
    'disk.numberReadAveraged.average',
    'disk.numberWriteAveraged.average',
    'disk.read.average',
    'disk.write.average',
    'disk.totalReadLatency.average',
    'disk.totalWriteLatency.average',
    'disk.commandsAborted.summation',
    'net.transmitted.average',
    'net.received.average',
    'net.droppedTx.summation',
    'net.droppedRx.summation'
)

$WhatIfVmCounters = @(
    'cpu.demand.average',
    'mem.consumed.average',
    'disk.numberReadAveraged.average',
    'disk.numberWriteAveraged.average',
    'disk.read.average',
    'disk.write.average'
)

# Disk counters with no aggregate (instance="") VM series. For each output key
# the collector discovers available device instances (virtual disks scsiX:Y,
# else datastore devices naa.*) and combines them per timestamp:
#   'sum'  - total across devices (IOPS, aborted commands)
#   'mean' - average across devices (per-command latency, an absolute value that
#            must NOT be summed)
# Candidates are tried in order; the first counter with available instances wins.
$PerDeviceCounterSources = [ordered]@{
    'disk.numberReadAveraged.average'  = [pscustomobject]@{
        Candidates = @('virtualDisk.numberReadAveraged.average', 'disk.numberReadAveraged.average')
        Combine    = 'sum'
    }
    'disk.numberWriteAveraged.average' = [pscustomobject]@{
        Candidates = @('virtualDisk.numberWriteAveraged.average', 'disk.numberWriteAveraged.average')
        Combine    = 'sum'
    }
    'disk.totalReadLatency.average'    = [pscustomobject]@{
        Candidates = @('virtualDisk.totalReadLatency.average', 'disk.totalReadLatency.average')
        Combine    = 'mean'
    }
    'disk.totalWriteLatency.average'   = [pscustomobject]@{
        Candidates = @('virtualDisk.totalWriteLatency.average', 'disk.totalWriteLatency.average')
        Combine    = 'mean'
    }
    'disk.commandsAborted.summation'   = [pscustomobject]@{
        Candidates = @('disk.commandsAborted.summation')
        Combine    = 'sum'
    }
}

# Per-output-key combination mode ('sum' | 'mean'). Keys not listed here are
# requested with the aggregate instance="" and yield a single series, for which
# sum and mean are identical.
$PerDeviceCombineMode = @{}
foreach ($perDeviceKey in $PerDeviceCounterSources.Keys) {
    $PerDeviceCombineMode[$perDeviceKey] = $PerDeviceCounterSources[$perDeviceKey].Combine
}

function Get-RollupIntervalCandidates {
    param([int]$IntervalHours)

    if ($IntervalHours -le 24) { return @(300, 1800, 7200, 86400) }
    if ($IntervalHours -le (7 * 24)) { return @(1800, 7200, 86400) }
    if ($IntervalHours -le (30 * 24)) { return @(7200, 86400) }
    return @(86400)
}

function Get-Percentile {
    param(
        [AllowEmptyCollection()]
        [double[]]$Values,
        [double]$Percent
    )

    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    [double[]]$orderedValues = @($Values | Sort-Object)
    $index = ($orderedValues.Count - 1) * ($Percent / 100.0)
    $lower = [int][Math]::Floor($index)
    $upper = [Math]::Min($lower + 1, $orderedValues.Count - 1)
    $weight = $index - $lower
    return $orderedValues[$lower] * (1.0 - $weight) + $orderedValues[$upper] * $weight
}

function Format-IsoTimestamp {
    param([DateTime]$Timestamp)

    if ($Timestamp.Kind -eq [DateTimeKind]::Unspecified) {
        $Timestamp = [DateTime]::SpecifyKind($Timestamp, [DateTimeKind]::Utc)
    }
    return $Timestamp.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:sszzz')
}

function Get-InferredSampleInterval {
    param(
        [AllowEmptyCollection()]
        [object[]]$Timestamps,
        [int]$Fallback
    )

    $clean = @($Timestamps | Where-Object { $null -ne $_ })
    $deltas = @()
    for ($index = 1; $index -lt $clean.Count; $index++) {
        $delta = [int](New-TimeSpan -Start $clean[$index - 1] -End $clean[$index]).TotalSeconds
        if ($delta -gt 0) { $deltas += $delta }
    }
    if ($deltas.Count -eq 0) { return $Fallback }
    return [int](Get-Percentile -Values $deltas -Percent 50)
}

function New-ValueSummary {
    param(
        [AllowEmptyCollection()]
        [double[]]$Values,
        [AllowEmptyCollection()]
        [object[]]$Timestamps = @()
    )

    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }

    $maximum = ($Values | Measure-Object -Maximum).Maximum
    $minimum = ($Values | Measure-Object -Minimum).Minimum
    $average = ($Values | Measure-Object -Average).Average
    $maximumIndex = [Array]::IndexOf($Values, [double]$maximum)

    $summary = [ordered]@{
        avg     = [Math]::Round([double]$average, 3)
        p50     = [Math]::Round((Get-Percentile -Values $Values -Percent 50), 3)
        p95     = [Math]::Round((Get-Percentile -Values $Values -Percent 95), 3)
        p99     = [Math]::Round((Get-Percentile -Values $Values -Percent 99), 3)
        peak    = [double]$maximum
        max     = [double]$maximum
        min     = [double]$minimum
        samples = $Values.Count
    }
    if ($Timestamps.Count -gt $maximumIndex -and $maximumIndex -ge 0 -and
        $null -ne $Timestamps[$maximumIndex]) {
        $summary.max_timestamp = Format-IsoTimestamp $Timestamps[$maximumIndex]
    }
    return $summary
}

function Get-HourOfWeek {
    param([DateTime]$Timestamp)

    # .NET Sunday=0; Python datetime.weekday() Monday=0.
    $mondayBasedDay = (([int]$Timestamp.DayOfWeek + 6) % 7)
    return $mondayBasedDay * 24 + $Timestamp.Hour
}

function Get-HourOfMonth {
    param([DateTime]$Timestamp)
    return ($Timestamp.Day - 1) * 24 + $Timestamp.Hour
}

function New-TimeBucketStats {
    param(
        [AllowEmptyCollection()]
        [object[]]$Samples,
        [ValidateSet('week', 'month')]
        [string]$Mode
    )

    $buckets = @{}
    foreach ($sample in $Samples) {
        if ($null -eq $sample.Timestamp) { continue }
        $bucket = if ($Mode -eq 'week') {
            Get-HourOfWeek $sample.Timestamp
        }
        else {
            Get-HourOfMonth $sample.Timestamp
        }
        if (-not $buckets.ContainsKey($bucket)) {
            $buckets[$bucket] = [System.Collections.Generic.List[double]]::new()
        }
        $buckets[$bucket].Add([double]$sample.Value)
    }

    $result = @()
    foreach ($bucket in @($buckets.Keys | Sort-Object)) {
        $statistics = New-ValueSummary -Values @($buckets[$bucket])
        $row = [ordered]@{}
        if ($Mode -eq 'week') { $row.hour_of_week = [int]$bucket }
        else { $row.hour_of_month = [int]$bucket }
        $row.samples = $statistics.samples
        $row.avg = $statistics.avg
        $row.p95 = $statistics.p95
        $row.p99 = $statistics.p99
        $row.max = $statistics.max
        $result += [pscustomobject]$row
    }
    return @($result)
}

function New-CollectionQuality {
    param(
        [int]$SampleCount,
        [int]$IntervalHours,
        [int]$SampleIntervalSeconds
    )

    $expected = [int](($IntervalHours * 3600) / $SampleIntervalSeconds)
    $coverage = if ($expected -gt 0) {
        [Math]::Round($SampleCount / $expected * 100.0, 2)
    }
    else { $null }

    $confidence = if ($null -eq $coverage) { 'UNKNOWN' }
    elseif ($coverage -ge 95) { 'HIGH' }
    elseif ($coverage -ge 80) { 'MEDIUM' }
    else { 'LOW' }

    return [ordered]@{
        expected_samples    = $expected
        actual_samples      = $SampleCount
        coverage_pct        = $coverage
        confidence          = $confidence
        sample_interval_sec = $SampleIntervalSeconds
    }
}

function New-PerfMetricId {
    param(
        [int]$CounterId,
        [AllowEmptyString()]
        [string]$Instance
    )

    $metric = New-Object -TypeName VMware.Vim.PerfMetricId
    $metric.CounterId = $CounterId
    $metric.Instance = $Instance
    return $metric
}

function Get-PerfMetricSelection {
    param(
        $PerformanceManager,
        $VmView,
        [hashtable]$CounterMap,
        [DateTime]$StartTime,
        [DateTime]$EndTime,
        [int]$IntervalSeconds
    )

    $metricIds = [System.Collections.Generic.List[object]]::new()
    $sourceKeys = @{}
    $sourceMetadata = @{}

    foreach ($key in $VmPerfCounters) {
        if ($PerDeviceCounterSources.Contains($key)) { continue }
        if ($CounterMap.ContainsKey($key)) {
            $counterId = [int]$CounterMap[$key]
            $metricIds.Add((New-PerfMetricId -CounterId $counterId -Instance ''))
            $sourceKeys[$counterId] = $key
        }
    }

    try {
        $available = @($PerformanceManager.QueryAvailablePerfMetric(
                $VmView.MoRef, $StartTime, $EndTime, $IntervalSeconds
            ))
    }
    catch {
        Write-Warning "Could not discover per-instance perf metrics for $($VmView.Name) at ${IntervalSeconds}s: $($_.Exception.Message)"
        return [pscustomobject]@{
            MetricIds      = @($metricIds)
            SourceKeys     = $sourceKeys
            SourceMetadata = $sourceMetadata
        }
    }

    $instancesByCounter = @{}
    foreach ($metric in $available) {
        $counterId = [int]$metric.CounterId
        if (-not $instancesByCounter.ContainsKey($counterId)) {
            $instancesByCounter[$counterId] = [System.Collections.Generic.HashSet[string]]::new()
        }
        [void]$instancesByCounter[$counterId].Add([string]$metric.Instance)
    }

    foreach ($outputKey in $PerDeviceCounterSources.Keys) {
        $spec = $PerDeviceCounterSources[$outputKey]
        foreach ($sourceKey in $spec.Candidates) {
            if (-not $CounterMap.ContainsKey($sourceKey)) { continue }
            $counterId = [int]$CounterMap[$sourceKey]
            if (-not $instancesByCounter.ContainsKey($counterId) -or
                $instancesByCounter[$counterId].Count -eq 0) { continue }

            $instances = $instancesByCounter[$counterId]
            if ($instances.Contains('')) {
                $selectedInstances = @('')
            }
            else {
                $selectedInstances = @($instances | Where-Object { $_ } | Sort-Object)
            }
            if ($selectedInstances.Count -eq 0) { continue }

            foreach ($instance in $selectedInstances) {
                $metricIds.Add((New-PerfMetricId -CounterId $counterId -Instance $instance))
            }
            $sourceKeys[$counterId] = $outputKey
            $sourceMetadata[$outputKey] = [ordered]@{
                source_counter   = $sourceKey
                source_instances = @($selectedInstances)
                combine          = $spec.Combine
            }
            break
        }
    }

    return [pscustomobject]@{
        MetricIds      = @($metricIds)
        SourceKeys     = $sourceKeys
        SourceMetadata = $sourceMetadata
    }
}

function Get-VmPerformance {
    param(
        $PerformanceManager,
        $VmView,
        [hashtable]$CounterMap,
        [int]$IntervalHours,
        [int]$RequestedSampleIntervalSeconds
    )

    $endTime = [DateTime]::UtcNow
    $startTime = $endTime.AddHours(-$IntervalHours)
    $results = @()
    $selectedInterval = $RequestedSampleIntervalSeconds
    $selectedSourceKeys = @{}
    $selectedSourceMetadata = @{}

    foreach ($candidate in (Get-RollupIntervalCandidates $IntervalHours)) {
        $selection = Get-PerfMetricSelection `
            -PerformanceManager $PerformanceManager `
            -VmView $VmView `
            -CounterMap $CounterMap `
            -StartTime $startTime `
            -EndTime $endTime `
            -IntervalSeconds $candidate
        if ($selection.MetricIds.Count -eq 0) { continue }

        $query = New-Object -TypeName VMware.Vim.PerfQuerySpec
        $query.Entity = $VmView.MoRef
        $query.MetricId = @($selection.MetricIds)
        $query.StartTime = $startTime
        $query.EndTime = $endTime
        $query.IntervalId = [int]$candidate
        $query.Format = 'normal'

        try {
            $results = @($PerformanceManager.QueryPerf(@($query)))
        }
        catch {
            Write-Warning "Could not retrieve ${candidate}s perf data for $($VmView.Name): $($_.Exception.Message)"
            continue
        }

        $hasValues = $false
        foreach ($result in $results) {
            foreach ($series in @($result.Value)) {
                if ($null -ne $series.Value -and $series.Value.Count -gt 0) {
                    $hasValues = $true
                    break
                }
            }
            if ($hasValues) { break }
        }
        if ($hasValues) {
            $selectedInterval = [int]$candidate
            $selectedSourceKeys = $selection.SourceKeys
            $selectedSourceMetadata = $selection.SourceMetadata
            break
        }
    }

    if ($results.Count -eq 0 -or $selectedSourceKeys.Count -eq 0) { return @{} }

    $samplesByKey = @{}
    $countsByKey = @{}
    $timestampsByKey = @{}
    foreach ($result in $results) {
        $sampleTimes = @($result.SampleInfo | ForEach-Object { $_.Timestamp })
        foreach ($series in @($result.Value)) {
            $counterId = [int]$series.Id.CounterId
            if (-not $selectedSourceKeys.ContainsKey($counterId)) { continue }
            $key = $selectedSourceKeys[$counterId]
            if (-not $samplesByKey.ContainsKey($key)) {
                $samplesByKey[$key] = @{}
                $countsByKey[$key] = @{}
                $timestampsByKey[$key] = @{}
            }
            for ($index = 0; $index -lt $series.Value.Count; $index++) {
                $value = [double]$series.Value[$index]
                if ($value -lt 0) { continue }
                $timestamp = if ($index -lt $sampleTimes.Count) { $sampleTimes[$index] } else { $null }
                if ($null -ne $timestamp) {
                    $timestamp = $timestamp.ToUniversalTime()
                    $bucket = 't:' + (Format-IsoTimestamp $timestamp)
                }
                else { $bucket = "i:$index" }
                if (-not $samplesByKey[$key].ContainsKey($bucket)) {
                    $samplesByKey[$key][$bucket] = 0.0
                    $countsByKey[$key][$bucket] = 0
                    $timestampsByKey[$key][$bucket] = $timestamp
                }
                $samplesByKey[$key][$bucket] += $value
                $countsByKey[$key][$bucket] += 1
            }
        }
    }

    $statistics = @{}
    foreach ($key in $samplesByKey.Keys) {
        $combine = if ($PerDeviceCombineMode.ContainsKey($key)) { $PerDeviceCombineMode[$key] } else { 'sum' }
        $orderedBuckets = @($samplesByKey[$key].Keys | Sort-Object {
                $timestamp = $timestampsByKey[$key][$_]
                if ($null -ne $timestamp) { $timestamp.Ticks } else { [long]::MaxValue }
            })
        [double[]]$values = @($orderedBuckets | ForEach-Object {
                if ($combine -eq 'mean' -and $countsByKey[$key][$_] -gt 0) {
                    [double]$samplesByKey[$key][$_] / $countsByKey[$key][$_]
                }
                else {
                    [double]$samplesByKey[$key][$_]
                }
            })
        [object[]]$timestamps = @($orderedBuckets | ForEach-Object { $timestampsByKey[$key][$_] })
        $summary = New-ValueSummary -Values $values -Timestamps $timestamps
        $actualInterval = Get-InferredSampleInterval -Timestamps $timestamps -Fallback $selectedInterval
        $summary.requested_sample_interval_sec = $RequestedSampleIntervalSeconds
        $summary.selected_sample_interval_sec = $selectedInterval
        $summary.actual_sample_interval_sec = $actualInterval
        if ($selectedSourceMetadata.ContainsKey($key)) {
            $summary.source_counter = $selectedSourceMetadata[$key].source_counter
            $summary.source_instances = @($selectedSourceMetadata[$key].source_instances)
        }

        if ($WhatIfVmCounters -contains $key) {
            $timestamped = @()
            for ($index = 0; $index -lt $values.Count; $index++) {
                if ($null -ne $timestamps[$index]) {
                    $timestamped += [pscustomobject]@{
                        Timestamp = $timestamps[$index]
                        Value     = $values[$index]
                    }
                }
            }
            if ($timestamped.Count -gt 0) {
                $summary.series = @($timestamped | ForEach-Object {
                        [ordered]@{
                            timestamp = Format-IsoTimestamp $_.Timestamp
                            value     = $_.Value
                        }
                    })
                $summary.hour_of_week = @(New-TimeBucketStats -Samples $timestamped -Mode week)
                $summary.hour_of_month = @(New-TimeBucketStats -Samples $timestamped -Mode month)
            }
        }
        $statistics[$key] = $summary
    }
    return $statistics
}

function Test-TypeName {
    param($Value, [string]$TypeName)

    if ($null -eq $Value) { return $false }
    $type = $Value.GetType()
    while ($null -ne $type) {
        if ($type.Name -eq $TypeName) { return $true }
        $type = $type.BaseType
    }
    return $false
}

function Get-ViewName {
    param($Reference, [hashtable]$Cache, $Server)

    if ($null -eq $Reference) { return $null }
    $key = "$($Reference.Type):$($Reference.Value)"
    if (-not $Cache.ContainsKey($key)) {
        try { $Cache[$key] = (Get-View -Server $Server -Id $Reference -Property Name).Name }
        catch { $Cache[$key] = $null }
    }
    return $Cache[$key]
}

function Get-VmConfiguration {
    param($VmView, [hashtable]$NameCache, $Server)

    $configuration = $VmView.Config
    $runtime = $VmView.Summary.Runtime
    $guest = $VmView.Summary.Guest
    $disks = @()
    $nics = @()

    if ($null -ne $configuration -and $null -ne $configuration.Hardware) {
        foreach ($device in @($configuration.Hardware.Device)) {
            if (Test-TypeName $device 'VirtualDisk') {
                $datastoreName = $null
                if ($null -ne $device.Backing -and $null -ne $device.Backing.Datastore) {
                    $datastoreName = Get-ViewName $device.Backing.Datastore $NameCache $Server
                }
                $capacity = if ($null -ne $device.CapacityInKB) {
                    [Math]::Round([double]$device.CapacityInKB / (1024 * 1024), 2)
                }
                else { $null }
                $thin = if ($null -ne $device.Backing -and
                    $device.Backing.PSObject.Properties.Name -contains 'ThinProvisioned') {
                    $device.Backing.ThinProvisioned
                }
                else { $null }
                $disks += [ordered]@{
                    label            = if ($null -ne $device.DeviceInfo) { $device.DeviceInfo.Label } else { $null }
                    capacity_gb      = $capacity
                    thin_provisioned = $thin
                    datastore        = $datastoreName
                }
            }
            elseif (Test-TypeName $device 'VirtualEthernetCard') {
                $nics += [ordered]@{
                    label       = if ($null -ne $device.DeviceInfo) { $device.DeviceInfo.Label } else { $null }
                    mac_address = $device.MacAddress
                    connected   = if ($null -ne $device.Connectable) { $device.Connectable.Connected } else { $null }
                }
            }
        }
    }

    $hostName = $null
    $clusterName = $null
    if ($null -ne $runtime.Host) {
        try {
            $hostView = Get-View -Server $Server -Id $runtime.Host -Property Name, Parent
            $hostName = $hostView.Name
            if ($null -ne $hostView.Parent) {
                $parentView = Get-View -Server $Server -Id $hostView.Parent -Property Name
                if (Test-TypeName $parentView 'ClusterComputeResource') {
                    $clusterName = $parentView.Name
                }
            }
        }
        catch { Write-Warning "Could not resolve host placement for $($VmView.Name): $($_.Exception.Message)" }
    }

    $ramMb = if ($null -ne $configuration -and $null -ne $configuration.Hardware) {
        $configuration.Hardware.MemoryMB
    }
    else { $null }
    $diskTotal = @($disks | Where-Object { $null -ne $_.capacity_gb } |
            ForEach-Object { $_.capacity_gb } | Measure-Object -Sum).Sum
    if ($null -eq $diskTotal) { $diskTotal = 0 }

    return [ordered]@{
        name                      = $VmView.Name
        power_state               = if ($null -ne $runtime) { $runtime.PowerState.ToString() } else { $null }
        guest_os                  = if ($null -ne $configuration) { $configuration.GuestFullName } else { $null }
        guest_hostname            = if ($null -ne $guest) { $guest.HostName } else { $null }
        guest_ip                  = if ($null -ne $guest) { $guest.IpAddress } else { $null }
        vcpus                     = if ($null -ne $configuration -and $null -ne $configuration.Hardware) { $configuration.Hardware.NumCPU } else { $null }
        cores_per_socket          = if ($null -ne $configuration -and $null -ne $configuration.Hardware) { $configuration.Hardware.NumCoresPerSocket } else { $null }
        ram_mb                    = $ramMb
        ram_gb                    = if ($null -ne $ramMb) { [Math]::Round([double]$ramMb / 1024, 2) } else { $null }
        cpu_reservation_mhz       = if ($null -ne $configuration -and $null -ne $configuration.CpuAllocation) { $configuration.CpuAllocation.Reservation } else { $null }
        mem_reservation_mb        = if ($null -ne $configuration -and $null -ne $configuration.MemoryAllocation) { $configuration.MemoryAllocation.Reservation } else { $null }
        cpu_limit_mhz             = if ($null -ne $configuration -and $null -ne $configuration.CpuAllocation) { $configuration.CpuAllocation.Limit } else { $null }
        mem_limit_mb              = if ($null -ne $configuration -and $null -ne $configuration.MemoryAllocation) { $configuration.MemoryAllocation.Limit } else { $null }
        tools_status              = if ($null -ne $guest -and $null -ne $guest.ToolsStatus) { $guest.ToolsStatus.ToString() } else { $null }
        tools_version             = if ($null -ne $guest) { $guest.ToolsVersionStatus2 } else { $null }
        disks                     = @($disks)
        total_provisioned_disk_gb = [Math]::Round([double]$diskTotal, 2)
        nics                      = @($nics)
        host                      = $hostName
        cluster                   = $clusterName
        vmx_path                  = if ($null -ne $configuration -and $null -ne $configuration.Files) { $configuration.Files.VmPathName } else { $null }
    }
}

function Get-RoundedValue {
    param($Value, [int]$Digits = 2)
    if ($null -eq $Value) { return $null }
    return [Math]::Round([double]$Value, $Digits)
}

function Get-Stat {
    param([hashtable]$Raw, [string]$Key)
    if ($Raw.ContainsKey($Key)) { return $Raw[$Key] }
    return $null
}

function Get-StatValue {
    param($Stat, [string]$Name)
    if ($null -eq $Stat -or -not $Stat.Contains($Name)) { return $null }
    return $Stat[$Name]
}

function New-MetricBlock {
    param(
        $Stat,
        [double]$Scale,
        [int]$IntervalHours,
        [int]$RequestedSampleIntervalSeconds
    )

    if ($null -eq $Stat) { return $null }
    $actualInterval = Get-StatValue $Stat 'actual_sample_interval_sec'
    if ($null -eq $actualInterval) { $actualInterval = $RequestedSampleIntervalSeconds }

    $block = [ordered]@{
        avg                           = Get-RoundedValue ((Get-StatValue $Stat 'avg') * $Scale)
        p50                           = if ($null -ne (Get-StatValue $Stat 'p50')) { Get-RoundedValue ((Get-StatValue $Stat 'p50') * $Scale) } else { $null }
        p95                           = if ($null -ne (Get-StatValue $Stat 'p95')) { Get-RoundedValue ((Get-StatValue $Stat 'p95') * $Scale) } else { $null }
        p99                           = if ($null -ne (Get-StatValue $Stat 'p99')) { Get-RoundedValue ((Get-StatValue $Stat 'p99') * $Scale) } else { $null }
        max                           = Get-RoundedValue ((Get-StatValue $Stat 'max') * $Scale)
        min                           = if ($null -ne (Get-StatValue $Stat 'min')) { Get-RoundedValue ((Get-StatValue $Stat 'min') * $Scale) } else { $null }
        max_timestamp                 = Get-StatValue $Stat 'max_timestamp'
        requested_sample_interval_sec = $RequestedSampleIntervalSeconds
        actual_sample_interval_sec    = $actualInterval
        collection_quality            = New-CollectionQuality `
            -SampleCount (Get-StatValue $Stat 'samples') `
            -IntervalHours $IntervalHours `
            -SampleIntervalSeconds $actualInterval
    }

    if ($Stat.Contains('hour_of_week')) {
        $block.hour_of_week = @($Stat.hour_of_week | ForEach-Object {
                [ordered]@{
                    hour_of_week = $_.hour_of_week
                    samples      = $_.samples
                    avg          = if ($null -ne $_.avg) { Get-RoundedValue ($_.avg * $Scale) } else { $null }
                    p95          = if ($null -ne $_.p95) { Get-RoundedValue ($_.p95 * $Scale) } else { $null }
                    p99          = if ($null -ne $_.p99) { Get-RoundedValue ($_.p99 * $Scale) } else { $null }
                    max          = if ($null -ne $_.max) { Get-RoundedValue ($_.max * $Scale) } else { $null }
                }
            })
    }
    if ($Stat.Contains('hour_of_month')) {
        $block.hour_of_month = @($Stat.hour_of_month | ForEach-Object {
                [ordered]@{
                    hour_of_month = $_.hour_of_month
                    samples       = $_.samples
                    avg           = if ($null -ne $_.avg) { Get-RoundedValue ($_.avg * $Scale) } else { $null }
                    p95           = if ($null -ne $_.p95) { Get-RoundedValue ($_.p95 * $Scale) } else { $null }
                    p99           = if ($null -ne $_.p99) { Get-RoundedValue ($_.p99 * $Scale) } else { $null }
                    max           = if ($null -ne $_.max) { Get-RoundedValue ($_.max * $Scale) } else { $null }
                }
            })
    }
    if ($Stat.Contains('series')) {
        $block.series = @($Stat.series | ForEach-Object {
                [ordered]@{
                    timestamp = $_.timestamp
                    value     = Get-RoundedValue ($_.value * $Scale)
                }
            })
    }
    return $block
}

function New-PerformanceSummary {
    param(
        [hashtable]$Raw,
        [int]$VCpuCount,
        [int]$IntervalHours,
        [int]$RequestedSampleIntervalSeconds
    )

    $cpuUsage = Get-Stat $Raw 'cpu.usage.average'
    $cpuMhz = Get-Stat $Raw 'cpu.usagemhz.average'
    $cpuDemand = Get-Stat $Raw 'cpu.demand.average'
    $cpuReady = Get-Stat $Raw 'cpu.ready.summation'
    $cpuCostop = Get-Stat $Raw 'cpu.costop.summation'
    $cpuLatency = Get-Stat $Raw 'cpu.latency.average'
    $memUsage = Get-Stat $Raw 'mem.usage.average'
    $memActive = Get-Stat $Raw 'mem.active.average'
    $memConsumed = Get-Stat $Raw 'mem.consumed.average'
    $memBalloon = Get-Stat $Raw 'mem.vmmemctl.average'
    $memSwapped = Get-Stat $Raw 'mem.swapped.average'
    $memOverhead = Get-Stat $Raw 'mem.overhead.average'
    $diskReadIops = Get-Stat $Raw 'disk.numberReadAveraged.average'
    $diskWriteIops = Get-Stat $Raw 'disk.numberWriteAveraged.average'
    $diskReadKbps = Get-Stat $Raw 'disk.read.average'
    $diskWriteKbps = Get-Stat $Raw 'disk.write.average'
    $diskReadLatency = Get-Stat $Raw 'disk.totalReadLatency.average'
    $diskWriteLatency = Get-Stat $Raw 'disk.totalWriteLatency.average'
    $diskAborts = Get-Stat $Raw 'disk.commandsAborted.summation'
    $netTransmit = Get-Stat $Raw 'net.transmitted.average'
    $netReceive = Get-Stat $Raw 'net.received.average'
    $netDropTx = Get-Stat $Raw 'net.droppedTx.summation'
    $netDropRx = Get-Stat $Raw 'net.droppedRx.summation'

    $vcpusSafe = if ($VCpuCount -gt 0) { $VCpuCount } else { 1 }
    $readyActual = Get-StatValue $cpuReady 'actual_sample_interval_sec'
    $costopActual = Get-StatValue $cpuCostop 'actual_sample_interval_sec'
    if ($null -eq $readyActual -and $null -ne $cpuReady) { $readyActual = $RequestedSampleIntervalSeconds }
    if ($null -eq $costopActual -and $null -ne $cpuCostop) { $costopActual = $RequestedSampleIntervalSeconds }
    $readyIntervalMs = if ($null -ne $readyActual) { $readyActual * 1000.0 } else { $null }
    $costopIntervalMs = if ($null -ne $costopActual) { $costopActual * 1000.0 } else { $null }
    $readyAverage = if ($null -ne $cpuReady) { Get-RoundedValue ((Get-StatValue $cpuReady 'avg') / $readyIntervalMs * 100 / $vcpusSafe) } else { $null }
    $readyPeak = if ($null -ne $cpuReady) { Get-RoundedValue ((Get-StatValue $cpuReady 'peak') / $readyIntervalMs * 100 / $vcpusSafe) } else { $null }
    $costopAverage = if ($null -ne $cpuCostop) { Get-RoundedValue ((Get-StatValue $cpuCostop 'avg') / $costopIntervalMs * 100 / $vcpusSafe) } else { $null }

    $actualIntervals = @($Raw.Values | ForEach-Object { Get-StatValue $_ 'actual_sample_interval_sec' } | Where-Object { $null -ne $_ })
    $selectedIntervals = @($Raw.Values | ForEach-Object { Get-StatValue $_ 'selected_sample_interval_sec' } | Where-Object { $null -ne $_ })
    $actualInterval = if ($actualIntervals.Count) { [int](Get-Percentile $actualIntervals 50) } else { $RequestedSampleIntervalSeconds }
    $selectedInterval = if ($selectedIntervals.Count) { [int](Get-Percentile $selectedIntervals 50) } else { $RequestedSampleIntervalSeconds }

    $balloonAverage = Get-StatValue $memBalloon 'avg'
    $swappedAverage = Get-StatValue $memSwapped 'avg'
    $overcommitKnown = $null -ne $memBalloon -or $null -ne $memSwapped
    $overcommitActive = if ($overcommitKnown) {
        (($null -ne $balloonAverage -and $balloonAverage -gt 0) -or
            ($null -ne $swappedAverage -and $swappedAverage -gt 0))
    }
    else { $null }

    return [ordered]@{
        collection_window_hours        = $IntervalHours
        requested_sample_interval_sec  = $RequestedSampleIntervalSeconds
        selected_sample_interval_sec   = $selectedInterval
        actual_sample_interval_sec     = $actualInterval
        cpu = [ordered]@{
            usage_avg_pct    = if ($null -ne $cpuUsage) { Get-RoundedValue ((Get-StatValue $cpuUsage 'avg') / 100) } else { $null }
            usage_p95_pct    = if ($null -ne $cpuUsage) { Get-RoundedValue ((Get-StatValue $cpuUsage 'p95') / 100) } else { $null }
            usage_p99_pct    = if ($null -ne $cpuUsage) { Get-RoundedValue ((Get-StatValue $cpuUsage 'p99') / 100) } else { $null }
            usage_peak_pct   = if ($null -ne $cpuUsage) { Get-RoundedValue ((Get-StatValue $cpuUsage 'peak') / 100) } else { $null }
            usage_avg_mhz    = if ($null -ne $cpuMhz) { Get-RoundedValue (Get-StatValue $cpuMhz 'avg') } else { $null }
            usage_p95_mhz    = if ($null -ne $cpuMhz) { Get-RoundedValue (Get-StatValue $cpuMhz 'p95') } else { $null }
            usage_p99_mhz    = if ($null -ne $cpuMhz) { Get-RoundedValue (Get-StatValue $cpuMhz 'p99') } else { $null }
            usage_peak_mhz   = if ($null -ne $cpuMhz) { Get-RoundedValue (Get-StatValue $cpuMhz 'peak') } else { $null }
            demand_avg_mhz   = if ($null -ne $cpuDemand) { Get-RoundedValue (Get-StatValue $cpuDemand 'avg') } else { $null }
            demand_p95_mhz   = if ($null -ne $cpuDemand) { Get-RoundedValue (Get-StatValue $cpuDemand 'p95') } else { $null }
            demand_p99_mhz   = if ($null -ne $cpuDemand) { Get-RoundedValue (Get-StatValue $cpuDemand 'p99') } else { $null }
            demand_peak_mhz  = if ($null -ne $cpuDemand) { Get-RoundedValue (Get-StatValue $cpuDemand 'peak') } else { $null }
            demand_mhz       = New-MetricBlock $cpuDemand 1 $IntervalHours $RequestedSampleIntervalSeconds
            ready_avg_pct    = $readyAverage
            ready_peak_pct   = $readyPeak
            costop_avg_pct   = $costopAverage
            latency_avg_pct  = if ($null -ne $cpuLatency) { Get-RoundedValue ((Get-StatValue $cpuLatency 'avg') / 100) } else { $null }
            latency_peak_pct = if ($null -ne $cpuLatency) { Get-RoundedValue ((Get-StatValue $cpuLatency 'peak') / 100) } else { $null }
            notes            = @($(if ($null -ne $readyAverage -and $readyAverage -gt 5) { 'cpu.ready elevated — scheduling contention on source cluster' }))
        }
        memory = [ordered]@{
            usage_avg_pct     = if ($null -ne $memUsage) { Get-RoundedValue ((Get-StatValue $memUsage 'avg') / 100) } else { $null }
            usage_peak_pct    = if ($null -ne $memUsage) { Get-RoundedValue ((Get-StatValue $memUsage 'peak') / 100) } else { $null }
            active_avg_mb     = if ($null -ne $memActive) { Get-RoundedValue ((Get-StatValue $memActive 'avg') / 1024) } else { $null }
            active_peak_mb    = if ($null -ne $memActive) { Get-RoundedValue ((Get-StatValue $memActive 'peak') / 1024) } else { $null }
            consumed_avg_mb   = if ($null -ne $memConsumed) { Get-RoundedValue ((Get-StatValue $memConsumed 'avg') / 1024) } else { $null }
            consumed_p95_mb   = if ($null -ne $memConsumed) { Get-RoundedValue ((Get-StatValue $memConsumed 'p95') / 1024) } else { $null }
            consumed_p99_mb   = if ($null -ne $memConsumed) { Get-RoundedValue ((Get-StatValue $memConsumed 'p99') / 1024) } else { $null }
            consumed_peak_mb  = if ($null -ne $memConsumed) { Get-RoundedValue ((Get-StatValue $memConsumed 'peak') / 1024) } else { $null }
            consumed_mb       = New-MetricBlock $memConsumed (1.0 / 1024) $IntervalHours $RequestedSampleIntervalSeconds
            overhead_avg_mb   = if ($null -ne $memOverhead) { Get-RoundedValue ((Get-StatValue $memOverhead 'avg') / 1024) } else { $null }
            balloon_avg_mb    = if ($null -ne $memBalloon) { Get-RoundedValue ((Get-StatValue $memBalloon 'avg') / 1024) } else { $null }
            balloon_peak_mb   = if ($null -ne $memBalloon) { Get-RoundedValue ((Get-StatValue $memBalloon 'peak') / 1024) } else { $null }
            swapped_avg_mb    = if ($null -ne $memSwapped) { Get-RoundedValue ((Get-StatValue $memSwapped 'avg') / 1024) } else { $null }
            swapped_peak_mb   = if ($null -ne $memSwapped) { Get-RoundedValue ((Get-StatValue $memSwapped 'peak') / 1024) } else { $null }
            overcommit_active = $overcommitActive
            notes             = @($(if ($overcommitActive) { 'mem.balloon/swap active — source host is memory-overcommitted' }))
        }
        disk = [ordered]@{
            read_iops_avg         = if ($null -ne $diskReadIops) { Get-RoundedValue (Get-StatValue $diskReadIops 'avg') } else { $null }
            read_iops_peak        = if ($null -ne $diskReadIops) { Get-RoundedValue (Get-StatValue $diskReadIops 'peak') } else { $null }
            write_iops_avg        = if ($null -ne $diskWriteIops) { Get-RoundedValue (Get-StatValue $diskWriteIops 'avg') } else { $null }
            write_iops_peak       = if ($null -ne $diskWriteIops) { Get-RoundedValue (Get-StatValue $diskWriteIops 'peak') } else { $null }
            read_kbps_avg         = if ($null -ne $diskReadKbps) { Get-RoundedValue (Get-StatValue $diskReadKbps 'avg') } else { $null }
            read_kbps_peak        = if ($null -ne $diskReadKbps) { Get-RoundedValue (Get-StatValue $diskReadKbps 'peak') } else { $null }
            write_kbps_avg        = if ($null -ne $diskWriteKbps) { Get-RoundedValue (Get-StatValue $diskWriteKbps 'avg') } else { $null }
            write_kbps_peak       = if ($null -ne $diskWriteKbps) { Get-RoundedValue (Get-StatValue $diskWriteKbps 'peak') } else { $null }
            read_latency_avg_ms   = if ($null -ne $diskReadLatency) { Get-RoundedValue (Get-StatValue $diskReadLatency 'avg') } else { $null }
            read_latency_peak_ms  = if ($null -ne $diskReadLatency) { Get-RoundedValue (Get-StatValue $diskReadLatency 'peak') } else { $null }
            write_latency_avg_ms  = if ($null -ne $diskWriteLatency) { Get-RoundedValue (Get-StatValue $diskWriteLatency 'avg') } else { $null }
            write_latency_peak_ms = if ($null -ne $diskWriteLatency) { Get-RoundedValue (Get-StatValue $diskWriteLatency 'peak') } else { $null }
            commands_aborted_avg  = if ($null -ne $diskAborts) { Get-RoundedValue (Get-StatValue $diskAborts 'avg') } else { $null }
            read_iops              = New-MetricBlock $diskReadIops 1 $IntervalHours $RequestedSampleIntervalSeconds
            write_iops             = New-MetricBlock $diskWriteIops 1 $IntervalHours $RequestedSampleIntervalSeconds
            read_kbps              = New-MetricBlock $diskReadKbps 1 $IntervalHours $RequestedSampleIntervalSeconds
            write_kbps             = New-MetricBlock $diskWriteKbps 1 $IntervalHours $RequestedSampleIntervalSeconds
            notes                  = @($(if ($null -ne $diskAborts -and (Get-StatValue $diskAborts 'avg')) { 'disk.commandsAborted non-zero — storage path issues on source' }))
        }
        network = [ordered]@{
            transmit_avg_kbps  = if ($null -ne $netTransmit) { Get-RoundedValue (Get-StatValue $netTransmit 'avg') } else { $null }
            transmit_peak_kbps = if ($null -ne $netTransmit) { Get-RoundedValue (Get-StatValue $netTransmit 'peak') } else { $null }
            receive_avg_kbps   = if ($null -ne $netReceive) { Get-RoundedValue (Get-StatValue $netReceive 'avg') } else { $null }
            receive_peak_kbps  = if ($null -ne $netReceive) { Get-RoundedValue (Get-StatValue $netReceive 'peak') } else { $null }
            dropped_tx_avg     = if ($null -ne $netDropTx) { Get-RoundedValue (Get-StatValue $netDropTx 'avg') } else { $null }
            dropped_rx_avg     = if ($null -ne $netDropRx) { Get-RoundedValue (Get-StatValue $netDropRx 'avg') } else { $null }
            notes              = @($(if (($null -ne $netDropTx -and (Get-StatValue $netDropTx 'avg') -gt 0) -or ($null -ne $netDropRx -and (Get-StatValue $netDropRx 'avg') -gt 0)) { 'network drops detected — uplink saturation on source host' }))
        }
    }
}

function Get-PathValue {
    param($Root, [string[]]$Path)
    $value = $Root
    foreach ($part in $Path) {
        if ($null -eq $value) { return $null }
        if ($value -is [System.Collections.IDictionary]) {
            if (-not $value.Contains($part)) { return $null }
            $value = $value[$part]
        }
        else {
            $property = $value.PSObject.Properties[$part]
            if ($null -eq $property) { return $null }
            $value = $property.Value
        }
    }
    return $value
}

function Get-SummedPath {
    param([object[]]$VmProfileList, [string[]]$Path)
    $values = @($VmProfileList | ForEach-Object { Get-PathValue $_ $Path } | Where-Object { $null -ne $_ })
    if ($values.Count -eq 0) { return $null }
    return [Math]::Round([double](($values | Measure-Object -Sum).Sum), 2)
}

function Get-MaximumPath {
    param([object[]]$VmProfileList, [string[]]$Path)
    $values = @($VmProfileList | ForEach-Object { Get-PathValue $_ $Path } | Where-Object { $null -ne $_ })
    if ($values.Count -eq 0) { return $null }
    return [Math]::Round([double](($values | Measure-Object -Maximum).Maximum), 2)
}

function Get-WeightedAveragePath {
    param(
        [object[]]$VmProfileList,
        [string[]]$ValuePath,
        [string[]]$WeightPath
    )
    $weightedTotal = 0.0
    $totalWeight = 0.0
    foreach ($vmEntry in $VmProfileList) {
        $value = Get-PathValue $vmEntry $ValuePath
        $weight = Get-PathValue $vmEntry $WeightPath
        if ($null -ne $value -and $null -ne $weight -and [double]$weight -gt 0) {
            $weightedTotal += [double]$value * [double]$weight
            $totalWeight += [double]$weight
        }
    }
    if ($totalWeight -le 0) { return $null }
    return [Math]::Round($weightedTotal / $totalWeight, 2)
}

function Get-AggregatedVmMetricSeries {
    param(
        [object[]]$VmProfileList,
        [object[]]$MetricPaths,
        [int]$ExpectedVmCount
    )

    $buckets = @{}
    for ($vmIndex = 0; $vmIndex -lt $VmProfileList.Count; $vmIndex++) {
        $vmEntry = $VmProfileList[$vmIndex]
        $seriesMaps = @()
        foreach ($metricPath in $MetricPaths) {
            $seriesMap = @{}
            $series = Get-PathValue $vmEntry @(
                'performance', $metricPath.Section, $metricPath.Metric, 'series'
            )
            foreach ($point in @($series)) {
                if ($null -eq $point -or $null -eq $point.value) { continue }
                try { $timestamp = [DateTimeOffset]::Parse($point.timestamp).UtcDateTime }
                catch { continue }
                $key = Format-IsoTimestamp $timestamp
                $seriesMap[$key] = [pscustomobject]@{
                    Timestamp = $timestamp
                    Value     = [double]$point.value * [double]$metricPath.Scale
                }
            }
            $seriesMaps += ,$seriesMap
        }

        if ($seriesMaps.Count -eq 0) { continue }
        foreach ($key in @($seriesMaps[0].Keys)) {
            $presentInAll = $true
            foreach ($seriesMap in $seriesMaps) {
                if (-not $seriesMap.ContainsKey($key)) {
                    $presentInAll = $false
                    break
                }
            }
            if (-not $presentInAll) { continue }
            if (-not $buckets.ContainsKey($key)) {
                $buckets[$key] = [pscustomobject]@{
                    Timestamp = $seriesMaps[0][$key].Timestamp
                    Values    = @{}
                }
            }
            $value = 0.0
            foreach ($seriesMap in $seriesMaps) {
                $value += [double]$seriesMap[$key].Value
            }
            $buckets[$key].Values[$vmIndex] = $value
        }
    }

    $points = @()
    foreach ($bucket in @($buckets.Values | Sort-Object Timestamp)) {
        $contributingCount = $bucket.Values.Count
        $complete = $ExpectedVmCount -gt 0 -and $contributingCount -eq $ExpectedVmCount
        $points += [pscustomobject]@{
            Timestamp            = $bucket.Timestamp
            Value                = [double](($bucket.Values.Values | Measure-Object -Sum).Sum)
            ExpectedVmCount      = $ExpectedVmCount
            ContributingVmCount  = $contributingCount
            VmCompletenessPct    = if ($ExpectedVmCount -gt 0) {
                $contributingCount / $ExpectedVmCount * 100.0
            } else { $null }
            Complete             = $complete
            Accepted             = $complete
        }
    }

    $completeCount = @($points | Where-Object { $_.Complete }).Count
    $incompleteCount = $points.Count - $completeCount
    $expectedSlots = $points.Count * $ExpectedVmCount
    $contributingSlots = [double](($points | Measure-Object -Property ContributingVmCount -Sum).Sum)
    return [pscustomobject]@{
        Points         = @($points)
        AcceptedSeries = @($points | Where-Object { $_.Accepted })
        FallbackSeries = @($points)
        VmParticipation = [ordered]@{
            expected_vm_count                  = $ExpectedVmCount
            observed_timestamp_count           = $points.Count
            complete_timestamp_count           = $completeCount
            incomplete_timestamp_count         = $incompleteCount
            accepted_timestamp_count           = $completeCount
            excluded_incomplete_timestamp_count = $incompleteCount
            vm_sample_completeness_pct         = if ($expectedSlots -gt 0) {
                $contributingSlots / $expectedSlots * 100.0
            } else { $null }
            complete_timestamp_pct             = if ($points.Count -gt 0) {
                $completeCount / $points.Count * 100.0
            } else { $null }
            incomplete_timestamp_policy        = 'exclude_from_statistics_and_planning; use_partial_timestamp_fallback_only_when_no_complete_timestamps_exist'
        }
    }
}

function New-ApplicationMetric {
    param(
        $Aggregation,
        [int]$IntervalHours,
        [int]$RequestedSampleIntervalSeconds,
        [int]$FallbackActualIntervalSeconds
    )

    if ($null -eq $Aggregation) { return $null }
    [object[]]$completeSamples = @($Aggregation.AcceptedSeries)
    if ($completeSamples.Count -gt 0) {
        [object[]]$cleanSamples = @($completeSamples)
        $aggregationMethod = 'complete_case_timestamp_sum'
    }
    else {
        [object[]]$cleanSamples = @($Aggregation.FallbackSeries)
        $aggregationMethod = 'partial_timestamp_sum_low_confidence_fallback'
    }
    if ($cleanSamples.Count -eq 0) { return $null }
    [double[]]$values = @($cleanSamples | ForEach-Object { [double]$_.Value })
    [object[]]$timestamps = @($cleanSamples | ForEach-Object { $_.Timestamp })
    $summary = New-ValueSummary $values $timestamps
    $actualInterval = Get-InferredSampleInterval $timestamps $FallbackActualIntervalSeconds
    $pointByTimestamp = @{}
    foreach ($point in @($Aggregation.Points)) {
        $pointByTimestamp[(Format-IsoTimestamp $point.Timestamp)] = $point
    }
    return [ordered]@{
        avg                           = Get-RoundedValue $summary.avg
        p50                           = Get-RoundedValue $summary.p50
        p95                           = Get-RoundedValue $summary.p95
        p99                           = Get-RoundedValue $summary.p99
        max                           = Get-RoundedValue $summary.max
        min                           = Get-RoundedValue $summary.min
        max_timestamp                 = $summary.max_timestamp
        requested_sample_interval_sec = $RequestedSampleIntervalSeconds
        actual_sample_interval_sec    = $actualInterval
        collection_quality            = New-CollectionQuality $values.Count $IntervalHours $actualInterval
        aggregation_method            = $aggregationMethod
        vm_participation              = $Aggregation.VmParticipation
        hour_of_week                  = @(New-TimeBucketStats $cleanSamples week)
        hour_of_month                 = @(New-TimeBucketStats $cleanSamples month)
        series                        = @($cleanSamples | ForEach-Object {
                $point = $pointByTimestamp[(Format-IsoTimestamp $_.Timestamp)]
                [ordered]@{
                    timestamp            = Format-IsoTimestamp $_.Timestamp
                    value                = Get-RoundedValue $_.Value
                    expected_vm_count    = $point.ExpectedVmCount
                    contributing_vm_count = $point.ContributingVmCount
                    vm_completeness_pct  = Get-RoundedValue $point.VmCompletenessPct
                }
            })
        excluded_incomplete_timestamps = @($Aggregation.Points | Where-Object { -not $_.Accepted } | ForEach-Object {
                [ordered]@{
                    timestamp             = Format-IsoTimestamp $_.Timestamp
                    expected_vm_count     = $_.ExpectedVmCount
                    contributing_vm_count = $_.ContributingVmCount
                    vm_completeness_pct   = Get-RoundedValue $_.VmCompletenessPct
                }
            })
    }
}

function New-ApplicationSummary {
    param(
        [object[]]$VmProfiles,
        [int]$ExpectedVmCount = -1
    )

    if ($ExpectedVmCount -lt 0) { $ExpectedVmCount = $VmProfiles.Count }

    $intervalHours = if ($VmProfiles.Count) { [int](Get-PathValue $VmProfiles[0] @('performance', 'collection_window_hours')) } else { 0 }
    $requestedInterval = if ($VmProfiles.Count) { [int](Get-PathValue $VmProfiles[0] @('performance', 'requested_sample_interval_sec')) } else { 300 }
    $fallbackInterval = if ($VmProfiles.Count) { [int](Get-PathValue $VmProfiles[0] @('performance', 'actual_sample_interval_sec')) } else { 300 }

    $cpuAggregation = Get-AggregatedVmMetricSeries $VmProfiles @(
        [pscustomobject]@{ Section = 'cpu'; Metric = 'demand_mhz'; Scale = 1.0 }
    ) $ExpectedVmCount
    $memoryAggregation = Get-AggregatedVmMetricSeries $VmProfiles @(
        [pscustomobject]@{ Section = 'memory'; Metric = 'consumed_mb'; Scale = 1.0 }
    ) $ExpectedVmCount
    $readIopsAggregation = Get-AggregatedVmMetricSeries $VmProfiles @(
        [pscustomobject]@{ Section = 'disk'; Metric = 'read_iops'; Scale = 1.0 }
    ) $ExpectedVmCount
    $writeIopsAggregation = Get-AggregatedVmMetricSeries $VmProfiles @(
        [pscustomobject]@{ Section = 'disk'; Metric = 'write_iops'; Scale = 1.0 }
    ) $ExpectedVmCount
    $totalIopsAggregation = Get-AggregatedVmMetricSeries $VmProfiles @(
        [pscustomobject]@{ Section = 'disk'; Metric = 'read_iops'; Scale = 1.0 },
        [pscustomobject]@{ Section = 'disk'; Metric = 'write_iops'; Scale = 1.0 }
    ) $ExpectedVmCount
    $readKbpsAggregation = Get-AggregatedVmMetricSeries $VmProfiles @(
        [pscustomobject]@{ Section = 'disk'; Metric = 'read_kbps'; Scale = 1.0 }
    ) $ExpectedVmCount
    $writeKbpsAggregation = Get-AggregatedVmMetricSeries $VmProfiles @(
        [pscustomobject]@{ Section = 'disk'; Metric = 'write_kbps'; Scale = 1.0 }
    ) $ExpectedVmCount
    $totalKbpsAggregation = Get-AggregatedVmMetricSeries $VmProfiles @(
        [pscustomobject]@{ Section = 'disk'; Metric = 'read_kbps'; Scale = 1.0 },
        [pscustomobject]@{ Section = 'disk'; Metric = 'write_kbps'; Scale = 1.0 }
    ) $ExpectedVmCount

    $cpuProfile = New-ApplicationMetric $cpuAggregation $intervalHours $requestedInterval $fallbackInterval
    $memoryProfile = New-ApplicationMetric $memoryAggregation $intervalHours $requestedInterval $fallbackInterval
    $readIopsProfile = New-ApplicationMetric $readIopsAggregation $intervalHours $requestedInterval $fallbackInterval
    $writeIopsProfile = New-ApplicationMetric $writeIopsAggregation $intervalHours $requestedInterval $fallbackInterval
    $totalIopsProfile = New-ApplicationMetric $totalIopsAggregation $intervalHours $requestedInterval $fallbackInterval
    $readKbpsProfile = New-ApplicationMetric $readKbpsAggregation $intervalHours $requestedInterval $fallbackInterval
    $writeKbpsProfile = New-ApplicationMetric $writeKbpsAggregation $intervalHours $requestedInterval $fallbackInterval
    $totalKbpsProfile = New-ApplicationMetric $totalKbpsAggregation $intervalHours $requestedInterval $fallbackInterval

    $clusters = @($VmProfiles | ForEach-Object { Get-PathValue $_ @('config', 'cluster') } | Where-Object { $_ } | Sort-Object -Unique)
    $poweredOn = @($VmProfiles | Where-Object { (Get-PathValue $_ @('config', 'power_state')) -eq 'poweredOn' }).Count
    $overcommit = @($VmProfiles | ForEach-Object { Get-PathValue $_ @('performance', 'memory', 'overcommit_active') } | Where-Object { $null -ne $_ }) -contains $true

    return [ordered]@{
        total_vms                     = $VmProfiles.Count
        powered_on_vms                = $poweredOn
        total_vcpus                   = Get-SummedPath $VmProfiles @('config', 'vcpus')
        total_ram_gb                  = Get-SummedPath $VmProfiles @('config', 'ram_gb')
        total_provisioned_disk_gb     = Get-SummedPath $VmProfiles @('config', 'total_provisioned_disk_gb')
        peak_cpu_demand_mhz           = Get-SummedPath $VmProfiles @('performance', 'cpu', 'demand_peak_mhz')
        avg_cpu_demand_mhz            = Get-SummedPath $VmProfiles @('performance', 'cpu', 'demand_avg_mhz')
        p95_cpu_demand_mhz            = if ($null -ne $cpuProfile) { $cpuProfile.p95 } else { $null }
        p99_cpu_demand_mhz            = if ($null -ne $cpuProfile) { $cpuProfile.p99 } else { $null }
        peak_cpu_usage_pct            = Get-MaximumPath $VmProfiles @('performance', 'cpu', 'usage_peak_pct')
        avg_cpu_usage_pct             = Get-WeightedAveragePath $VmProfiles @('performance', 'cpu', 'usage_avg_pct') @('config', 'vcpus')
        max_vm_avg_cpu_usage_pct      = Get-MaximumPath $VmProfiles @('performance', 'cpu', 'usage_avg_pct')
        peak_mem_consumed_mb          = Get-SummedPath $VmProfiles @('performance', 'memory', 'consumed_peak_mb')
        avg_mem_consumed_mb           = Get-SummedPath $VmProfiles @('performance', 'memory', 'consumed_avg_mb')
        p95_mem_consumed_mb           = if ($null -ne $memoryProfile) { $memoryProfile.p95 } else { $null }
        p99_mem_consumed_mb           = if ($null -ne $memoryProfile) { $memoryProfile.p99 } else { $null }
        total_read_iops_avg           = Get-SummedPath $VmProfiles @('performance', 'disk', 'read_iops_avg')
        total_write_iops_avg          = Get-SummedPath $VmProfiles @('performance', 'disk', 'write_iops_avg')
        total_read_iops_peak          = Get-SummedPath $VmProfiles @('performance', 'disk', 'read_iops_peak')
        total_write_iops_peak         = Get-SummedPath $VmProfiles @('performance', 'disk', 'write_iops_peak')
        p95_total_iops                = if ($null -ne $totalIopsProfile) { $totalIopsProfile.p95 } else { $null }
        p95_read_iops                 = if ($null -ne $readIopsProfile) { $readIopsProfile.p95 } else { $null }
        p95_write_iops                = if ($null -ne $writeIopsProfile) { $writeIopsProfile.p95 } else { $null }
        p95_total_throughput_kbps     = if ($null -ne $totalKbpsProfile) { $totalKbpsProfile.p95 } else { $null }
        p95_read_throughput_kbps      = if ($null -ne $readKbpsProfile) { $readKbpsProfile.p95 } else { $null }
        p95_write_throughput_kbps     = if ($null -ne $writeKbpsProfile) { $writeKbpsProfile.p95 } else { $null }
        total_net_transmit_avg_kbps   = Get-SummedPath $VmProfiles @('performance', 'network', 'transmit_avg_kbps')
        total_net_receive_avg_kbps    = Get-SummedPath $VmProfiles @('performance', 'network', 'receive_avg_kbps')
        any_balloon_swap_active       = $overcommit
        source_clusters               = @($clusters)
        what_if_profiles = [ordered]@{
            methodology = 'Timestamped samples at the selected vCenter historical rollup interval and hour-of-week buckets for application CPU demand, memory consumed, and aggregated read/write/total disk I/O (IOPS and throughput). Complete-case timestamps are used for statistics and planning. If none exist, partial sums remain available only as an explicit low-confidence fallback. Observed zero is valid; absent samples are missing.'
            historical_series_coverage = [ordered]@{
                cpu_demand_mhz          = $cpuAggregation.VmParticipation
                memory_consumed_mb      = $memoryAggregation.VmParticipation
                read_iops               = $readIopsAggregation.VmParticipation
                write_iops              = $writeIopsAggregation.VmParticipation
                total_iops              = $totalIopsAggregation.VmParticipation
                read_throughput_kbps    = $readKbpsAggregation.VmParticipation
                write_throughput_kbps   = $writeKbpsAggregation.VmParticipation
                total_throughput_kbps   = $totalKbpsAggregation.VmParticipation
            }
            cpu_demand_mhz          = $cpuProfile
            memory_consumed_mb      = $memoryProfile
            read_iops               = $readIopsProfile
            write_iops              = $writeIopsProfile
            total_iops              = $totalIopsProfile
            read_throughput_kbps    = $readKbpsProfile
            write_throughput_kbps   = $writeKbpsProfile
            total_throughput_kbps   = $totalKbpsProfile
        }
    }
}

function New-ApplicationProfileQuality {
    param(
        [string[]]$RequestedVms,
        [object[]]$VmProfiles,
        [string[]]$NotFoundVms,
        $ApplicationSummary
    )

    $poweredOffVms = @($VmProfiles | Where-Object {
            (Get-PathValue $_ @('config', 'power_state')) -ne 'poweredOn'
        } | ForEach-Object {
            Get-PathValue $_ @('config', 'name')
        })
    $reasons = @()
    $warnings = @()
    if ($VmProfiles.Count -eq 0) {
        $reasons += 'No requested VMs were collected'
    }
    elseif ($NotFoundVms.Count -gt 0) {
        $reasons += "$($NotFoundVms.Count) of $($RequestedVms.Count) requested VMs were not found"
    }

    foreach ($profileName in @('cpu_demand_mhz', 'memory_consumed_mb')) {
        $metricData = Get-PathValue $ApplicationSummary @('what_if_profiles', $profileName)
        if ($null -eq $metricData) {
            $reasons += "$profileName is unavailable"
            continue
        }
        $method = Get-PathValue $metricData @('aggregation_method')
        $incompleteCount = Get-PathValue $metricData @('vm_participation', 'incomplete_timestamp_count')
        if ($method -eq 'partial_timestamp_sum_low_confidence_fallback') {
            $reasons += "$profileName has no complete timestamps and uses partial sums as a low-confidence fallback"
        }
        elseif ($null -ne $incompleteCount -and [int]$incompleteCount -gt 0) {
            $reasons += "$profileName excluded $incompleteCount incomplete timestamps"
        }
    }

    if ($poweredOffVms.Count -gt 0) {
        $warnings += 'VMs currently powered off were not assumed to have zero historical demand; only observed samples were used'
    }
    $status = if ($VmProfiles.Count -eq 0) { 'UNUSABLE' }
    elseif ($reasons.Count -gt 0) { 'INCOMPLETE' }
    else { 'COMPLETE' }

    return [ordered]@{
        status               = $status
        is_complete          = $status -eq 'COMPLETE'
        confidence           = if ($status -eq 'COMPLETE') { 'HIGH' } else { 'LOW' }
        requested_vm_count   = $RequestedVms.Count
        collected_vm_count   = $VmProfiles.Count
        not_found_vm_count   = $NotFoundVms.Count
        powered_off_vm_count = $poweredOffVms.Count
        not_found_vms        = @($NotFoundVms)
        powered_off_vms      = @($poweredOffVms)
        reasons              = @($reasons)
        warnings             = @($warnings)
        assessment_policy    = 'Always perform the assessment with available evidence. Reflect incompleteness in the summary, reduce confidence, and report affected results as UNKNOWN when no usable value exists.'
    }
}

# Validate mutually exclusive VM selectors before loading PowerCLI.
if ([string]::IsNullOrWhiteSpace($VMs) -eq [string]::IsNullOrWhiteSpace($VmFile)) {
    throw 'Exactly one of -VMs (--vms) or -VmFile (--vm-file) is required.'
}

if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) {
    throw 'VMware PowerCLI is required. Install it with: Install-Module VMware.PowerCLI -Scope CurrentUser'
}
Import-Module VMware.VimAutomation.Core -ErrorAction Stop

if (-not [string]::IsNullOrWhiteSpace($VMs)) {
    $vmNames = @($VMs.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
else {
    if (-not (Test-Path -LiteralPath $VmFile -PathType Leaf)) {
        throw "Cannot read VM list file: $VmFile"
    }
    $vmNames = @(Get-Content -LiteralPath $VmFile | ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') })
}
if ($vmNames.Count -eq 0) { throw 'No VM names provided.' }

if (-not [string]::IsNullOrEmpty($Password)) {
    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    Write-Host 'Password supplied via --password argument.'
}
elseif (-not [string]::IsNullOrEmpty($env:VSPHERE_PASSWORD)) {
    $securePassword = ConvertTo-SecureString $env:VSPHERE_PASSWORD -AsPlainText -Force
    Write-Host 'Password taken from VSPHERE_PASSWORD environment variable.'
}
else {
    $securePassword = Read-Host -AsSecureString -Prompt "Password for ${User}@${VCenterHost}"
    Write-Host 'Password received — connecting …'
}
$credential = New-Object System.Management.Automation.PSCredential($User, $securePassword)

if ($NoSslVerify) {
    Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
}

$scriptStopwatch = [Diagnostics.Stopwatch]::StartNew()
Write-Host "`n============================================================"
Write-Host '  VMware vSphere Application VM Profiler'
Write-Host '============================================================'
Write-Host "  vCenter  : ${VCenterHost}:${Port}"
Write-Host "  User     : $User"
Write-Host "  VMs      : $($vmNames.Count)  ($($vmNames -join ', '))"
Write-Host "  Window   : last $Interval h"
if ($AppName) { Write-Host "  App      : $AppName" }
Write-Host "  Output   : $JsonOut"
Write-Host "============================================================`n"

$connection = $null
try {
    Write-Host "[1/4] Connecting to vCenter ${VCenterHost}:${Port} as $User …"
    $step = [Diagnostics.Stopwatch]::StartNew()
    $connection = Connect-VIServer -Server $VCenterHost -Port $Port -Credential $credential -WarningAction SilentlyContinue
    Write-Host ("      Connected  ({0:N1}s)`n" -f $step.Elapsed.TotalSeconds)

    Write-Host '[2/4] Loading inventory and performance counter map …'
    $step.Restart()
    $serviceInstance = Get-View -Server $connection -Id ServiceInstance
    $performanceManager = Get-View -Server $connection -Id $serviceInstance.Content.PerfManager
    $counterMap = @{}
    foreach ($counter in @($performanceManager.PerfCounter)) {
        $key = '{0}.{1}.{2}' -f $counter.GroupInfo.Key, $counter.NameInfo.Key, $counter.RollupType
        $counterMap[$key] = [int]$counter.Key
    }
    $inventory = @(Get-View -Server $connection -ViewType VirtualMachine -Property Name, Config, Summary)
    $exactInventory = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $foldedInventory = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($vm in $inventory) {
        $exactInventory[$vm.Name] = $vm
        $foldedInventory[$vm.Name] = $vm
    }
    Write-Host ("      {0} VMs in inventory, {1} perf counters available  ({2:N1}s)`n" -f $inventory.Count, $counterMap.Count, $step.Elapsed.TotalSeconds)

    $vmProfiles = @()
    $notFound = @()
    $nameCache = @{}
    $requestedSampleInterval = (Get-RollupIntervalCandidates $Interval)[0]
    Write-Host "[3/4] Profiling $($vmNames.Count) VM(s) …"

    for ($index = 0; $index -lt $vmNames.Count; $index++) {
        $name = $vmNames[$index]
        $vmView = $null
        if (-not $exactInventory.TryGetValue($name, [ref]$vmView)) {
            [void]$foldedInventory.TryGetValue($name, [ref]$vmView)
        }
        if ($null -eq $vmView) {
            Write-Warning "[$($index + 1)/$($vmNames.Count)] NOT FOUND: '$name'"
            $notFound += $name
            continue
        }

        Write-Host "  [$($index + 1)/$($vmNames.Count)] $($vmView.Name)"
        $step.Restart()
        Write-Host '          collecting configuration …' -NoNewline
        $configuration = Get-VmConfiguration $vmView $nameCache $connection
        Write-Host (" done ({0:N1}s)  {1} vCPU  {2} GB RAM  {3} GB disk" -f $step.Elapsed.TotalSeconds, $configuration.vcpus, $configuration.ram_gb, $configuration.total_provisioned_disk_gb)

        $step.Restart()
        Write-Host "          collecting ${Interval}h performance data (rollup ${requestedSampleInterval}s) …" -NoNewline
        $rawPerformance = Get-VmPerformance $performanceManager $vmView $counterMap $Interval $requestedSampleInterval
        $performance = New-PerformanceSummary $rawPerformance $configuration.vcpus $Interval $requestedSampleInterval
        $sampleCounts = @($rawPerformance.Values | ForEach-Object { Get-StatValue $_ 'samples' } | Where-Object { $null -ne $_ })
        $samples = if ($sampleCounts.Count) { ($sampleCounts | Measure-Object -Maximum).Maximum } else { 0 }
        Write-Host (" done ({0:N1}s)  {1} samples" -f $step.Elapsed.TotalSeconds, $samples)
        Write-Host ("          CPU avg {0}%  |  MEM avg {1}%  |  Disk R {2} / W {3} IOPS" -f $performance.cpu.usage_avg_pct, $performance.memory.usage_avg_pct, $performance.disk.read_iops_avg, $performance.disk.write_iops_avg)

        $vmProfiles += [ordered]@{
            config      = $configuration
            performance = $performance
        }
    }

    Write-Host "`n[4/4] Writing JSON output …" -NoNewline
    $step.Restart()
    $applicationSummary = New-ApplicationSummary $vmProfiles $vmNames.Count
    $profileQuality = New-ApplicationProfileQuality $vmNames $vmProfiles $notFound $applicationSummary
    $applicationSummary['profile_quality'] = $profileQuality
    $actualSampleInterval = $requestedSampleInterval
    foreach ($profileName in @('cpu_demand_mhz', 'memory_consumed_mb')) {
        $applicationProfile = $applicationSummary.what_if_profiles[$profileName]
        if ($null -ne $applicationProfile -and $null -ne $applicationProfile.actual_sample_interval_sec) {
            $actualSampleInterval = $applicationProfile.actual_sample_interval_sec
            break
        }
    }

    $output = [ordered]@{
        _metadata = [ordered]@{
            schema_version                     = '1.1'
            collection_tool                    = 'collect_app_profile.ps1'
            collected_at                       = [DateTime]::Now.ToString('yyyy-MM-ddTHH:mm:ss')
            vcenter                            = $VCenterHost
            app_name                           = if ($AppName) { $AppName } else { $null }
            requested_vms                      = @($vmNames)
            collected_vms                      = @($vmProfiles | ForEach-Object { $_.config.name })
            not_found_vms                      = @($notFound)
            powered_off_vms                    = @($profileQuality.powered_off_vms)
            requested_vm_count                 = $profileQuality.requested_vm_count
            collected_vm_count                 = $profileQuality.collected_vm_count
            not_found_vm_count                 = $profileQuality.not_found_vm_count
            powered_off_vm_count               = $profileQuality.powered_off_vm_count
            profile_quality                    = $profileQuality
            history_window_hours               = $Interval
            requested_sample_interval_sec      = $requestedSampleInterval
            rollup_interval_candidates_sec     = @(Get-RollupIntervalCandidates $Interval)
            actual_sample_interval_sec         = $actualSampleInterval
        }
        application_summary = $applicationSummary
        virtual_machines    = @($vmProfiles)
    }

    $outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($JsonOut)
    $outputDirectory = Split-Path -Parent $outputPath
    if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        throw "Output directory does not exist: $outputDirectory"
    }
    $json = ConvertTo-Json -InputObject $output -Depth 100
    [IO.File]::WriteAllText($outputPath, $json, [Text.UTF8Encoding]::new($false))
    Write-Host (" done ({0:N1}s)`n" -f $step.Elapsed.TotalSeconds)

    Write-Host '============================================================'
    Write-Host ("  COLLECTION COMPLETE  ({0:N1}s total)" -f $scriptStopwatch.Elapsed.TotalSeconds)
    Write-Host '============================================================'
    Write-Host "  Output file  : $JsonOut"
    Write-Host "  VMs profiled : $($vmProfiles.Count)"
    if ($notFound.Count) { Write-Host "  VMs missing  : $($notFound -join ', ')" }
    if ($profileQuality.status -ne 'COMPLETE') {
        Write-Warning "PROFILE $($profileQuality.status) — assessment remains available at $($profileQuality.confidence) confidence"
        foreach ($reason in $profileQuality.reasons) {
            Write-Host "      - $reason"
        }
    }
    if ($vmProfiles.Count) {
        Write-Host "`n  Application totals:"
        Write-Host "    vCPUs       : $($applicationSummary.total_vcpus)"
        Write-Host "    RAM         : $($applicationSummary.total_ram_gb) GB"
        Write-Host "    Disk        : $($applicationSummary.total_provisioned_disk_gb) GB"
        Write-Host "    CPU demand  : avg $($applicationSummary.avg_cpu_demand_mhz) MHz  p95 $($applicationSummary.p95_cpu_demand_mhz) MHz  p99 $($applicationSummary.p99_cpu_demand_mhz) MHz  peak $($applicationSummary.peak_cpu_demand_mhz) MHz"
        Write-Host "    Mem consumed: avg $($applicationSummary.avg_mem_consumed_mb) MB  p95 $($applicationSummary.p95_mem_consumed_mb) MB  p99 $($applicationSummary.p99_mem_consumed_mb) MB  peak $($applicationSummary.peak_mem_consumed_mb) MB"
        Write-Host "    IOPS R/W    : $($applicationSummary.total_read_iops_avg) / $($applicationSummary.total_write_iops_avg) avg"
        Write-Host "    IOPS total  : p95 $($applicationSummary.p95_total_iops) (read p95 $($applicationSummary.p95_read_iops) / write p95 $($applicationSummary.p95_write_iops))"
        Write-Host "    Throughput  : p95 $($applicationSummary.p95_total_throughput_kbps) KBps (read p95 $($applicationSummary.p95_read_throughput_kbps) / write p95 $($applicationSummary.p95_write_throughput_kbps))"
        if ($applicationSummary.any_balloon_swap_active) {
            Write-Warning 'Memory overcommit active on source — balloon/swap detected on at least one VM'
        }
    }
    Write-Host "============================================================`n"
}
finally {
    if ($null -ne $connection) {
        Disconnect-VIServer -Server $connection -Confirm:$false | Out-Null
    }
}
