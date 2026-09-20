$ErrorActionPreference = 'Stop'
$native = Join-Path $PSScriptRoot '../native/Naigrey.Senses.exe'
if (-not (Test-Path $native)) { throw 'Build native helper before its smoke test.' }
$json = & $native --self-test | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $json.selfTest -ne $true -or $json.processStartedAt -le 0) { throw 'Native process identity test failed.' }
# Headless Windows CI can lack an audio endpoint or an interactive desktop.
# Availability is reported, never replaced with simulated keyboard/audio input.
$json | ConvertTo-Json -Compress

# Exercise the persistent transport, not just the one-shot probe. No synthetic
# keystrokes are injected and no audio playback/recording is started.
$start = New-Object System.Diagnostics.ProcessStartInfo
$start.FileName = [IO.Path]::GetFullPath($native)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $start
try {
    if (-not $process.Start()) { throw 'Could not start native helper.' }
    $process.StandardInput.WriteLine('{"id":1,"pid":' + $process.Id + '}')
    $process.StandardInput.Flush()
    $identity = $false
    $sample = $false
    for ($i = 0; $i -lt 12 -and (-not $identity -or -not $sample); $i++) {
        $read = $process.StandardOutput.ReadLineAsync()
        if (-not $read.Wait(10000)) { throw 'Native helper transport timed out.' }
        if ($null -eq $read.Result) { throw 'Native helper exited before its response.' }
        $message = $read.Result | ConvertFrom-Json
        if ($message.id -eq 1) { $identity = $message.startedAt -gt 0 }
        if ($message.type -eq 'senses') {
            $sample = $true
            foreach ($property in $message.PSObject.Properties.Name) {
                if ($property -notin @('type','keyboardAvailable','keyAge','audioActive')) { throw 'Unexpected sensor field.' }
            }
            if ($null -ne $message.keyAge -and $message.keyAge -lt 0) { throw 'Invalid key age.' }
        }
    }
    if (-not $identity -or -not $sample) { throw 'Missing native sample or process identity.' }
    Write-Output 'NATIVE_TRANSPORT_OK'
} finally {
    if (-not $process.HasExited) {
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(3000)) { $process.Kill() }
    }
    $process.Dispose()
}
