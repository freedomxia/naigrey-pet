$ErrorActionPreference = 'Stop'
$native = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../native'))
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (-not (Test-Path $compiler)) { throw 'Windows .NET Framework 4.x x64 C# compiler is required.' }
$output = Join-Path $native 'Naigrey.Senses.exe'
& $compiler /nologo /target:exe /platform:x64 /optimize+ /warnaserror+ /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll "/out:$output" (Join-Path $native 'Naigrey.Senses.cs')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $output)) { throw 'Native helper compilation failed.' }
Write-Output "Built $output"
