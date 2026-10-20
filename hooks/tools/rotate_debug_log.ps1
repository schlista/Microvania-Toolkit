param([Parameter(Mandatory=$true)][string]$ProjectRoot,[long]$MaxBytes)
$ErrorActionPreference='Stop'
$rootPath=[IO.Path]::GetFullPath($ProjectRoot)
$logPath=[IO.Path]::Combine($rootPath,'debug_output.txt')
$backupPath=[IO.Path]::Combine($rootPath,'debug_output.txt.1')
if ($MaxBytes -gt 0 -and [IO.File]::Exists($logPath) -and (Get-Item -LiteralPath $logPath).Length -gt $MaxBytes) {
    if ([IO.File]::Exists($backupPath)) { Remove-Item -LiteralPath $backupPath -Force }
    Move-Item -LiteralPath $logPath -Destination $backupPath
}
