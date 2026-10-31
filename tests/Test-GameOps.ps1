<#
.SYNOPSIS
    Testes das operações de jogos: renomear, copiar e mover (ul.* e DVD).

.DESCRIPTION
    Monta pendrives falsos em pastas temporárias (pedaços ul.<CRC>.<SERIAL>.<NN>
    + entrada no ul.cfg) e valida que renomear/copiar/mover mexem nos arquivos e
    no ul.cfg como o OPL espera.

.EXAMPLE
    .\tests\Test-GameOps.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

. (Join-Path $PSScriptRoot '..\lib\UlFormat.ps1')

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
    param([bool]$Condition, [string]$Label)
    if ($Condition) {
        $script:Passed++
        Write-Host "  [PASS] $Label" -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host "  [FAIL] $Label" -ForegroundColor Red
    }
}

$root = Join-Path $env:TEMP ('gameops_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null

# Cria um "drive" com um jogo ul.* sintético (2 pedaços pequenos).
function New-FakeDrive {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Serial,
        [byte]$Media = 0x14,
        [int]$Parts = 2
    )
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $crc = '{0:X8}' -f (Get-UsbaCrc32 $Name)
    for ($i = 0; $i -lt $Parts; $i++) {
        # conteúdo determinístico por pedaço para conferir a cópia byte a byte
        $bytes = New-Object byte[] (1024 * ($i + 1))
        for ($b = 0; $b -lt $bytes.Length; $b++) { $bytes[$b] = [byte](($i * 37 + $b) -band 0xFF) }
        [IO.File]::WriteAllBytes((Join-Path $Path ("ul.$crc.$Serial.{0:D2}" -f $i)), $bytes)
    }
    Update-UlCfg -Root $Path -Name $Name -Serial $Serial -Parts $Parts -Media $Media | Out-Null
    return $crc
}

function Get-PartBytes {
    param([string]$Dir, [string]$Serial)
    $out = @{}
    Get-ChildItem $Dir -Filter "ul.*.$Serial.*" -File | ForEach-Object {
        $idx = [int]($_.Name.Substring($_.Name.Length - 2))
        $out[$idx] = [IO.File]::ReadAllBytes($_.FullName)
    }
    return $out
}

Write-Host ""
Write-Host "Renomear (ul.*)" -ForegroundColor Cyan

$srcA = Join-Path $root 'srcA'
$null = New-FakeDrive -Path $srcA -Name 'Nome Antigo' -Serial 'SLUS_209.46' -Media 0x14 -Parts 2
$before = Get-PartBytes $srcA 'SLUS_209.46'

$r = Rename-UlGame -Root $srcA -Serial 'SLUS_209.46' -NewName 'Ação Épica'
Assert-Equal 'Nome Antigo' $r.Antigo 'guardou o nome antigo'
Assert-Equal 'Acao Epica' $r.Novo 'normalizou o nome novo (ASCII)'

$entry = @(Read-UlEntries $srcA)[0]
Assert-Equal 'Acao Epica' $entry.Nome 'ul.cfg tem o nome novo'
Assert-Equal 2 $entry.Partes 'número de pedaços preservado'
Assert-Equal 'SLUS_209.46' $entry.Serial 'serial preservado'

$after = Get-PartBytes $srcA 'SLUS_209.46'
Assert-Equal 2 $after.Count 'continuam 2 pedaços'
Assert-True ([Linq.Enumerable]::SequenceEqual([byte[]]$before[0], [byte[]]$after[0])) 'conteúdo do pedaço 0 intacto'
Assert-True ([Linq.Enumerable]::SequenceEqual([byte[]]$before[1], [byte[]]$after[1])) 'conteúdo do pedaço 1 intacto'
$newCrc = '{0:X8}' -f (Get-UsbaCrc32 'Acao Epica')
Assert-Equal 0 @(Get-ChildItem $srcA -File | Where-Object { $_.Name -like "ul.*.$('SLUS_209.46').*" -and $_.Name -notlike "ul.$newCrc.*" }).Count 'CRC antigo não sobrou'

try {
    Rename-UlGame -Root $srcA -Serial 'SLUS_209.46' -NewName 'Acao Epica'
    Assert-True $false 'renomear para o mesmo nome deve falhar'
} catch { Assert-True $true 'renomear para o mesmo nome dá erro' }

try {
    Rename-UlGame -Root $srcA -Serial 'SLUS_999.99' -NewName 'X'
    Assert-True $false 'serial inexistente deve falhar'
} catch { Assert-True $true 'serial inexistente dá erro' }

Write-Host ""
Write-Host "Copiar (ul.*)" -ForegroundColor Cyan

$srcB = Join-Path $root 'srcB'
$dstB = Join-Path $root 'dstB'
$null = New-FakeDrive -Path $srcB -Name 'Jogo Copiavel' -Serial 'SCES_123.45' -Media 0x12 -Parts 2
New-Item -ItemType Directory -Path $dstB | Out-Null
$origin = Get-PartBytes $srcB 'SCES_123.45'

$c = Copy-UlGame -SourceRoot $srcB -DestRoot $dstB -Serial 'SCES_123.45'
Assert-Equal 2 $c.Arquivos.Count 'copiou 2 arquivos'
$copied = Get-PartBytes $dstB 'SCES_123.45'
Assert-True ([Linq.Enumerable]::SequenceEqual([byte[]]$origin[0], [byte[]]$copied[0])) 'pedaço 0 idêntico no destino'
Assert-True ([Linq.Enumerable]::SequenceEqual([byte[]]$origin[1], [byte[]]$copied[1])) 'pedaço 1 idêntico no destino'
Assert-Equal 1 @(Read-UlEntries $srcB).Count 'origem ainda tem o jogo'
$destEntry = @(Read-UlEntries $dstB)[0]
Assert-Equal 'Jogo Copiavel' $destEntry.Nome 'ul.cfg do destino tem o nome'
Assert-Equal 'CD' $destEntry.Media 'mídia CD preservada na cópia'

try {
    Copy-UlGame -SourceRoot $srcB -DestRoot $dstB -Serial 'SCES_123.45'
    Assert-True $false 'copiar serial já existente no destino deve falhar'
} catch { Assert-True $true 'destino com o mesmo serial dá erro' }

Write-Host ""
Write-Host "Mover (ul.*)" -ForegroundColor Cyan

$srcC = Join-Path $root 'srcC'
$dstC = Join-Path $root 'dstC'
$null = New-FakeDrive -Path $srcC -Name 'Jogo Movel' -Serial 'SLPM_654.32' -Media 0x14 -Parts 2
New-Item -ItemType Directory -Path $dstC | Out-Null
$originC = Get-PartBytes $srcC 'SLPM_654.32'

$m = Move-UlGame -SourceRoot $srcC -DestRoot $dstC -Serial 'SLPM_654.32'
Assert-Equal 'Jogo Movel' $m.Nome 'objeto devolvido tem o nome'
Assert-Equal 0 @(Read-UlEntries $srcC).Count 'origem ficou vazia'
Assert-Equal 0 @(Get-ChildItem $srcC -File | Where-Object { $_.Name -like 'ul.*.*' }).Count 'nenhum pedaço na origem'
$moved = Get-PartBytes $dstC 'SLPM_654.32'
Assert-True ([Linq.Enumerable]::SequenceEqual([byte[]]$originC[1], [byte[]]$moved[1])) 'pedaço movido idêntico'
Assert-Equal 1 @(Read-UlEntries $dstC).Count 'destino tem 1 jogo'

Write-Host ""
Write-Host "Copiar (ISO da pasta DVD)" -ForegroundColor Cyan

$isoSrc = Join-Path $root 'dvdSrc'
$isoDst = Join-Path $root 'dvdDst'
New-Item -ItemType Directory -Path (Join-Path $isoSrc 'DVD') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $isoDst 'DVD') -Force | Out-Null
$isoBytes = New-Object byte[] 5000
for ($b = 0; $b -lt $isoBytes.Length; $b++) { $isoBytes[$b] = [byte]($b -band 0xFF) }
$isoPath = Join-Path $isoSrc 'DVD\Meu Jogo.iso'
[IO.File]::WriteAllBytes($isoPath, $isoBytes)

$isoCopy = Copy-DvdGame -IsoPath $isoPath -DestRoot $isoDst
Assert-Equal 'Meu Jogo' $isoCopy.Nome 'nome do ISO devolvido'
Assert-True (Test-Path -LiteralPath (Join-Path $isoDst 'DVD\Meu Jogo.iso')) 'ISO apareceu no destino'
$back = [IO.File]::ReadAllBytes((Join-Path $isoDst 'DVD\Meu Jogo.iso'))
Assert-True ([Linq.Enumerable]::SequenceEqual($isoBytes, $back)) 'ISO copiado byte a byte'

try {
    Copy-DvdGame -IsoPath $isoPath -DestRoot $isoDst
    Assert-True $false 'copiar ISO já existente deve falhar'
} catch { Assert-True $true 'ISO duplicado no destino dá erro' }

Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

Write-Host ""
Write-Host ("Resultado: {0} passaram, {1} falharam" -f $script:Passed, $script:Failed) `
    -ForegroundColor $(if ($script:Failed) { 'Red' } else { 'Green' })
if ($script:Failed) { exit 1 }
