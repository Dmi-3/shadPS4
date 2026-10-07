param(
    [ValidateSet('watch','mark','status','stop')][string]$Mode='watch',
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$LogPath,
    [int]$TargetProcessId=0,
    [string]$Label='visual defect',
    [ValidateRange(500,10000)][int]$PollMilliseconds=2000
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $root | Out-Null
$control=Join-Path $root 'requests'
New-Item -ItemType Directory -Force $control | Out-Null
$statusPath=Join-Path $root 'status.json'
function WriteJson($path,$value) {
    $temp=$path+'.tmp'
    [IO.File]::WriteAllText($temp,($value | ConvertTo-Json -Depth 9),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $path -Force
}
if($Mode -eq 'status') { Get-Content -LiteralPath $statusPath -Raw; exit 0 }
if($Mode -eq 'mark' -or $Mode -eq 'stop') {
    if($Label.Length -gt 120) { throw 'Label must be at most 120 characters' }
    $request=@{command=$Mode;label=$Label;utc=[DateTime]::UtcNow.ToString('o')}
    WriteJson (Join-Path $control ([guid]::NewGuid().ToString()+'.json')) $request
    exit 0
}
if(-not $LogPath) { throw 'LogPath is required for watch mode' }
$lockPath=Join-Path $root 'monitor.lock'
try { $lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
catch { throw 'A monitor is already running in this output directory' }
$samples=[Collections.Generic.Queue[object]]::new()
$tail=[Collections.Generic.Queue[string]]::new()
$offset=0L; $partial=''; $attachedId=0; $incidentIndex=0; $incidentCount=0
$previousCpu=0.0; $previousTime=[DateTime]::UtcNow; $lastIncident=[DateTime]::MinValue
$active=$false; $stop=$false; $tick=0; $lastError=$null; $lastMarker=$null
function Incident($reason,$label) {
    $utc=[DateTime]::UtcNow.ToString('o')
    $slot=$script:incidentIndex % 20
    $record=@{utc=$utc;reason=$reason;label=$label;process_id=$script:attachedId;
        samples=@($script:samples.ToArray());log_tail=@($script:tail.ToArray());
        limits=@{sample_interval_ms=$PollMilliseconds;sample_count_limit=90;log_lines_limit=200;
                 incident_slots=20;frame_times_available=$false}}
    WriteJson (Join-Path $root ('incident-{0:d2}.json' -f $slot)) $record
    $script:incidentIndex++; $script:incidentCount++; $script:lastIncident=[DateTime]::UtcNow
}
function ReadLog {
    if(-not (Test-Path -LiteralPath $LogPath)) { return @() }
    $stream=[IO.File]::Open($LogPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,
                          ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        if($stream.Length -lt $script:offset) { $script:offset=0; $script:partial='' }
        if($stream.Length-$script:offset -gt 65536) {
            $script:offset=$stream.Length-65536; $script:partial=''
        }
        [void]$stream.Seek($script:offset,[IO.SeekOrigin]::Begin)
        $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true,4096,$true)
        try { $text=$reader.ReadToEnd() } finally { $reader.Dispose() }
        $script:offset=$stream.Position
        $parts=($script:partial+$text) -split "`n"
        $script:partial=$parts[-1]
        if($script:partial.Length -gt 8192) { $script:partial=$script:partial.Substring(0,8192) }
        if($parts.Count -gt 1) { return @($parts[0..($parts.Count-2)] | ForEach-Object { $_.TrimEnd("`r") }) }
        return @()
    } finally { $stream.Dispose() }
}
try {
    while(-not $stop) {
        $now=[DateTime]::UtcNow
        try {
            $target=$null
            if($TargetProcessId) { $target=Get-Process -Id $TargetProcessId -ErrorAction SilentlyContinue }
            else { $target=Get-Process shadPS4 -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending | Select-Object -First 1 }
            if($target -and $target.ProcessName -ne 'shadPS4') { throw 'Target must be shadPS4' }
            if($target -and $target.Id -ne $attachedId) {
                $attachedId=$target.Id; $active=$true; $samples.Clear(); $tail.Clear(); $offset=0; $partial=''
                $previousCpu=$target.TotalProcessorTime.TotalSeconds; $previousTime=$now
                $lastError=$null
            }
            foreach($line in @(ReadLog)) {
                if($line.Length -gt 8192) { $line=$line.Substring(0,8192) }
                $tail.Enqueue($line); while($tail.Count -gt 200) { [void]$tail.Dequeue() }
                if($line -match 'Assertion failed|GPU hang|VK_ERROR_DEVICE_LOST|Unhandled exception|access violation|m_gfxEopTick') {
                    if(($now-$lastIncident).TotalSeconds -ge 10) { Incident 'runtime_error' $line }
                }
            }
            if($target) {
                $elapsed=($now-$previousTime).TotalSeconds
                $cpu=$target.TotalProcessorTime.TotalSeconds
                $cpuPercent=if($elapsed -gt 0) { [Math]::Round(100*($cpu-$previousCpu)/$elapsed/[Environment]::ProcessorCount,2) } else { 0 }
                $sample=@{utc=$now.ToString('o');process_id=$target.Id;cpu_percent=$cpuPercent;
                    working_set_mb=[Math]::Round($target.WorkingSet64/1MB,2);
                    private_memory_mb=[Math]::Round($target.PrivateMemorySize64/1MB,2);
                    threads=$target.Threads.Count;handles=$target.HandleCount}
                $samples.Enqueue($sample); while($samples.Count -gt 90) { [void]$samples.Dequeue() }
                $previousCpu=$cpu; $previousTime=$now
            } elseif($active) {
                Incident 'process_closed' 'Exit detected; manual close and crash are not distinguished automatically'
                $active=$false
                if($TargetProcessId) { $stop=$true }
            }
            foreach($file in @(Get-ChildItem -LiteralPath $control -Filter '*.json' | Sort-Object LastWriteTime | Select-Object -First 20)) {
                if($file.Length -gt 4096) { throw 'Oversized diagnostic request' }
                $request=Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
                if($request.command -eq 'mark') {
                    $mark=[string]$request.label
                    if($mark.Length -gt 120) { $mark=$mark.Substring(0,120) }
                    $lastMarker=$mark; Incident 'user_marker' $mark
                } elseif($request.command -eq 'stop') { $stop=$true }
                # Only remove a processed request within this monitor's exact control directory.
                if([IO.Path]::GetDirectoryName($file.FullName) -eq $control) { Remove-Item -LiteralPath $file.FullName }
            }
            $lastError=$null
        } catch { $lastError=$_.Exception.Message }
        WriteJson $statusPath @{utc=$now.ToString('o');monitor_pid=$PID;game_process_id=$attachedId;
            game_running=$active;incident_count=$incidentCount;last_marker=$lastMarker;last_error=$lastError;
            latest_sample=if($samples.Count) { $samples.ToArray()[-1] } else { $null };
            limitations='CPU/memory/log samples only; no frame times or GPU counters. Visual symptoms need a user marker and a separate capture.'}
        if(($tick++ % 5) -eq 0 -or $stop) { WriteJson (Join-Path $root 'recent-samples.json') @($samples.ToArray()) }
        if(-not $stop) { Start-Sleep -Milliseconds $PollMilliseconds }
    }
} finally {
    $lock.Dispose()
}
