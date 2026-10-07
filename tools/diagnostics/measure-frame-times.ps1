param(
    [Parameter(Mandatory=$true)][string]$PresentMonPath,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [int]$TargetProcessId=0,
    [ValidateRange(5,60)][int]$Seconds=20
)
$ErrorActionPreference='Stop'
if(-not $TargetProcessId) {
    $target=Get-Process shadPS4 -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending | Select-Object -First 1
    if(-not $target) { throw 'Start shadPS4 and load gameplay before measuring frame times' }
    $TargetProcessId=$target.Id
}
$target=Get-Process -Id $TargetProcessId
if($target.ProcessName -ne 'shadPS4') { throw 'Target must be shadPS4' }
$root=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $root | Out-Null
$csv=Join-Path $root 'latest-frames.csv'
$summaryPath=Join-Path $root 'latest-summary.json'
# Clear stale evidence so a failed capture cannot be reported as a fresh measurement.
[IO.File]::WriteAllText($csv,'')
[IO.File]::WriteAllText($summaryPath,'{"state":"recording"}')
$started=[DateTime]::UtcNow
$session='CodexUnchartedFrames-'+[guid]::NewGuid().ToString('N')
& $PresentMonPath --process_id $TargetProcessId --session_name $session --delay 3 --timed $Seconds --terminate_after_timed --terminate_on_proc_exit --no_track_gpu --no_track_input --no_track_display --no_console_stats --output_file $csv --v1_metrics
$captureExit=$LASTEXITCODE
if($captureExit -ne 0) {
    @{state='failed';exit_code=$captureExit;utc=$started.ToString('o')} | ConvertTo-Json | Set-Content $summaryPath
    throw "PresentMon capture failed with exit code $captureExit"
}
$rows=@(Import-Csv -LiteralPath $csv | Where-Object { $_.ProcessID -eq [string]$TargetProcessId })
if(-not $rows.Count) {
    '{"state":"no_frames","reason":"No target frame rows were recorded"}' | Set-Content $summaryPath
    throw 'No frame rows recorded; verify gameplay is visible and presenting frames'
}
$dominant=$rows | Group-Object SwapChainAddress | Sort-Object Count -Descending | Select-Object -First 1
$times=[Collections.Generic.List[double]]::new()
foreach($row in $dominant.Group) {
    $value=0.0
    if([double]::TryParse($row.MsBetweenPresents,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$value) -and $value -gt 0 -and -not [double]::IsInfinity($value) -and -not [double]::IsNaN($value)) {
        $times.Add($value)
    }
}
if($times.Count -lt 2) { throw 'Not enough valid present intervals to calculate statistics' }
$sorted=@($times | Sort-Object)
$count=$sorted.Count
$mean=($sorted | Measure-Object -Average).Average
function Percentile([double]$percent) { $sorted[[Math]::Max(0,[int][Math]::Ceiling($count*$percent)-1)] }
$slowCount=[Math]::Max(1,[int][Math]::Ceiling($count*0.01))
$slowMean=($sorted[($count-$slowCount)..($count-1)] | Measure-Object -Average).Average
$summary=@{state='complete';utc=$started.ToString('o');process_id=$TargetProcessId;
    requested_seconds=$Seconds;swapchain=$dominant.Name;interval_count=$count;
    average_fps=[Math]::Round(1000/$mean,2);
    one_percent_low_fps=[Math]::Round(1000/$slowMean,2);
    median_ms=[Math]::Round((Percentile 0.5),3);
    p95_ms=[Math]::Round((Percentile 0.95),3);p99_ms=[Math]::Round((Percentile 0.99),3);
    longest_ms=[Math]::Round($sorted[-1],3);
    intervals_over_33ms=@($times | Where-Object { $_ -gt (1000/30) }).Count;
    intervals_over_50ms=@($times | Where-Object { $_ -gt 50 }).Count;
    intervals_over_100ms=@($times | Where-Object { $_ -gt 100 }).Count;
    method='Present intervals of the swapchain with most rows; 1% low is 1000 divided by mean slowest 1% intervals';
    limits='No GPU duration or display completion tracking; Vulkan instrumentation may be limited. Recording itself can affect performance. Compare with capture off.'}
$summary | ConvertTo-Json -Depth 5 | Set-Content $summaryPath
$summary | ConvertTo-Json -Depth 5
