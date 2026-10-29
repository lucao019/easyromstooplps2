<#
.SYNOPSIS
    Testa o worker assíncrono da GUI de ponta a ponta.

.DESCRIPTION
    Usa o mesmo Worker.ps1 que a interface usa, com um diretório temporário no
    lugar do pendrive. Cobre: instalação ul.*, remontagem para .iso, cancelamento
    e limpeza.

.PARAMETER IsoPath
    ISO de PS2 real para o teste. Padrão: tenta achar um em E:\emulador PS2\games.

.EXAMPLE
    .\tests\Test-GuiWorker.ps1

.EXAMPLE
    .\tests\Test-GuiWorker.ps1 -IsoPath "E:\jogos\God of War (USA).iso"
#>
[CmdletBinding()]
param(
    [string]$IsoPath
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib\UlFormat.ps1')
. (Join-Path $repoRoot 'gui\Worker.ps1')
. (Join-Path $PSScriptRoot 'TestIso.ps1')

$libPath = Join-Path $repoRoot 'lib\UlFormat.ps1'

$explicitIso = [bool]$IsoPath
if (-not $IsoPath) {
    $candidates = @(
        'E:\emulador PS2\games\Medalha de Honra (SLUS_215.97).iso',
        'E:\emulador PS2\games\Crash Twinsanity (USA).iso'
    )
    $IsoPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if ($IsoPath -and -not (Test-Path -LiteralPath $IsoPath)) {
    Write-Host "ISO não encontrado: $IsoPath" -ForegroundColor Yellow
    exit 2
}
if (-not $IsoPath -and $explicitIso) {
    Write-Host 'ISO de teste inválido. Use -IsoPath.' -ForegroundColor Yellow
    exit 2
}

# O teste instala (cópia do ISO) e exporta (segunda cópia). Sem espaço para as
# duas, usa um ISO sintético de 38 KB em vez de falhar por disco cheio.
$synthetic = -not $IsoPath
if ($IsoPath -and -not $explicitIso) {
    $need = (Get-Item -LiteralPath $IsoPath).Length * 2.4
    try {
        $free = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot([IO.Path]::GetTempPath()))).AvailableFreeSpace
        if ($free -lt $need) { $synthetic = $true }
    } catch { $synthetic = $true }
}

$script:Passed = 0
$script:Failed = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Label)
    if ("$Expected" -eq "$Actual") {
        $script:Passed++
        Write-Host "  [PASS] $Label" -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host "  [FAIL] $Label" -ForegroundColor Red
        Write-Host "         esperado: $Expected" -ForegroundColor DarkGray
        Write-Host "         obtido  : $Actual" -ForegroundColor DarkGray
    }
}

function Assert-True {
    param($Condition, [string]$Label)
    Assert-Equal $true ([bool]$Condition) $Label
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('er2opl-worker-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $root | Out-Null

if ($synthetic) {
    $IsoPath = Join-Path $root 'Sintetico (SLUS_215.97).iso'
    New-TestPs2Iso -Path $IsoPath -Serial 'SLUS_215.97'
    Write-Host 'Pouco espaço livre: usando um ISO sintético de 38 KB.' -ForegroundColor Yellow
}

$iso = Get-Item -LiteralPath $IsoPath
$info = Get-IsoInfo $iso.FullName
$serial = $info.Serial

Write-Host ''
Write-Host "Worker da GUI — $($iso.Name) ($serial)" -ForegroundColor Cyan

try {
    # ---------------------------------------------------------------- instalar
    Write-Host ''
    Write-Host 'Instalação ul.*' -ForegroundColor Cyan

    $sync = New-WorkerState -LibPath $libPath -Jobs @([pscustomobject]@{
        Op = 'install'; Iso = $iso.FullName; Root = $root; Name = 'Jogo de Teste'
        Serial = $serial; Media = [byte]0x14; Mode = 'ul'; Force = $true
    })

    & $WorkerScript -Sync $sync

    Assert-True $sync.Finished 'worker terminou'
    Assert-Equal 0 $sync.Failed 'nenhuma falha'
    Assert-Equal 100 $sync.Percent 'progresso final 100%'

    $cfg = Join-Path $root 'ul.cfg'
    Assert-True (Test-Path -LiteralPath $cfg) 'ul.cfg criado'
    Assert-Equal 64 (Get-Item -LiteralPath $cfg).Length 'ul.cfg tem 64 bytes'

    $entries = @(Read-UlEntries $root)
    Assert-Equal 1 $entries.Count 'uma entrada no ul.cfg'
    Assert-Equal 'Jogo de Teste' $entries[0].Nome 'nome na entrada'
    Assert-Equal $serial $entries[0].Serial 'serial na entrada'
    Assert-Equal ('{0:X8}' -f (Get-UsbaCrc32 'Jogo de Teste')) $entries[0].Crc 'CRC confere'

    $parts = @(Get-ChildItem $root -Filter "ul.$($entries[0].Crc).$serial.*" -File)
    Assert-Equal $entries[0].Partes $parts.Count 'quantidade de pedaços'
    Assert-Equal $iso.Length (($parts | Measure-Object Length -Sum).Sum) 'soma dos pedaços = ISO'

    # ---------------------------------------------------------------- exportar
    Write-Host ''
    Write-Host 'Remontagem para .iso' -ForegroundColor Cyan

    $dest = Join-Path $root 'saida.iso'
    $sync2 = New-WorkerState -LibPath $libPath -Jobs @([pscustomobject]@{
        Op = 'export'; Root = $root; Serial = $serial; Name = 'Jogo de Teste'; Dest = $dest
    })
    & $WorkerScript -Sync $sync2

    Assert-True $sync2.Finished 'worker de export terminou'
    Assert-Equal 0 $sync2.Failed 'export sem falhas'
    Assert-True (Test-Path -LiteralPath $dest) 'iso gerado'
    Assert-Equal $iso.Length (Get-Item -LiteralPath $dest).Length 'iso remontado tem o mesmo tamanho'

    $back = Get-IsoInfo $dest
    Assert-Equal $serial $back.Serial 'serial do iso remontado'
    Assert-Equal 'PLAYSTATION' $back.SystemId 'SystemId do iso remontado'

    # ---------------------------------------------------------------- cancelar
    Write-Host ''
    Write-Host 'Cancelamento' -ForegroundColor Cyan

    $sync3 = New-WorkerState -LibPath $libPath -Jobs @([pscustomobject]@{
        Op = 'install'; Iso = $iso.FullName; Root = $root; Name = 'Cancelado'
        Serial = 'SLUS_999.99'; Media = [byte]0x14; Mode = 'ul'; Force = $true
    })
    $sync3.Cancel = $true
    & $WorkerScript -Sync $sync3

    Assert-True $sync3.Finished 'worker cancelado terminou'
    Assert-Equal 0 (@(Get-ChildItem $root -Filter 'ul.*SLUS_999.99*' -File).Count) 'nada gravado após cancelar'
    Assert-Equal 1 (@(Read-UlEntries $root)).Count 'ul.cfg preservado'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("Resultado: {0} passaram, {1} falharam" -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
