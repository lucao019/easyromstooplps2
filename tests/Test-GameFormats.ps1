<#
.SYNOPSIS
    Testes de identificação de formatos (assinatura/magic bytes) da biblioteca.

.DESCRIPTION
    Garante que só arquivos com o cabeçalho correto entram na biblioteca, e que
    um CHD é classificado como PS1 (CD) ou PS2 (DVD) pelo tamanho lógico.

.EXAMPLE
    .\tests\Test-GameFormats.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

. (Join-Path $PSScriptRoot '..\lib\GameLibrary.ps1')

$script:Passed = 0
$script:Failed = 0

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

$tmp = Join-Path $env:TEMP ('gamefmttest_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

function New-RawFile {
    param([string]$Name, [byte[]]$Bytes)
    $p = Join-Path $tmp $Name
    [IO.File]::WriteAllBytes($p, $Bytes)
    return $p
}

# Bloco de bytes preenchido, com o cabeçalho copiado no início.
function New-Padded {
    param([byte[]]$Head, [int]$Total = 200000)
    $b = New-Object byte[] $Total
    [Array]::Copy($Head, 0, $b, 0, $Head.Length)
    return , $b
}

function New-ChdBytes {
    param([int64]$Logical, [int]$Version)
    $b = New-Object byte[] 4096
    [byte[]]$magic = 0x4D, 0x43, 0x6F, 0x6D, 0x70, 0x72, 0x48, 0x44   # "MComprHD"
    [Array]::Copy($magic, 0, $b, 0, 8)
    $b[0x0C] = [byte](($Version -shr 24) -band 0xFF)
    $b[0x0D] = [byte](($Version -shr 16) -band 0xFF)
    $b[0x0E] = [byte](($Version -shr 8) -band 0xFF)
    $b[0x0F] = [byte]($Version -band 0xFF)
    $off = if ($Version -ge 5) { 0x18 } else { 0x1C }
    for ($i = 0; $i -lt 8; $i++) {
        $b[$off + $i] = [byte](($Logical -shr (8 * (7 - $i))) -band 0xFF)
    }
    return , $b
}

Write-Host ""
Write-Host "Assinatura de ROM (magic bytes)" -ForegroundColor Cyan

$p = New-RawFile 'ok.nes' (New-Padded ([byte[]](0x4E, 0x45, 0x53, 0x1A, 0, 0, 0, 0)))
Assert-True (Test-GameSignature ([IO.FileInfo]$p) '.nes') 'NES válido passa'

$p = New-RawFile 'bad.nes' (New-Padded ([byte[]](0x4D, 0x5A, 0, 0)))
Assert-True (-not (Test-GameSignature ([IO.FileInfo]$p) '.nes')) 'NES com cabeçalho MZ é reprovado'

$gba = New-Object byte[] 200000
[byte[]]$logo = 0x24, 0xFF, 0xAE, 0x51, 0x69, 0x9A, 0xA2, 0x21
[Array]::Copy($logo, 0, $gba, 4, 8)
$p = New-RawFile 'ok.gba' $gba
Assert-True (Test-GameSignature ([IO.FileInfo]$p) '.gba') 'GBA válido passa'

$p = New-RawFile 'bad.gba' (New-Padded ([byte[]](1, 2, 3, 4, 5, 6, 7, 8, 9, 10)))
Assert-True (-not (Test-GameSignature ([IO.FileInfo]$p) '.gba')) 'GBA sem logo é reprovado'

$p = New-RawFile 'ok.pbp' (New-Padded ([byte[]](0x00, 0x50, 0x42, 0x50)))
Assert-True (Test-GameSignature ([IO.FileInfo]$p) '.pbp') 'PBP válido passa'

$p = New-RawFile 'free.sfc' (New-Padded ([byte[]](9, 9, 9, 9)))
Assert-True (Test-GameSignature ([IO.FileInfo]$p) '.sfc') 'SFC (sem assinatura) passa direto'

Write-Host ""
Write-Host "CHD: assinatura e plataforma" -ForegroundColor Cyan

$p = New-RawFile 'cd.chd' (New-ChdBytes 734003200 5)      # ~700 MB
Assert-True (Test-GameSignature ([IO.FileInfo]$p) '.chd') 'CHD com magic MComprHD passa'
Assert-True ((Get-ChdPlatform $p) -eq 'PS1') 'CHD de CD (700 MB) vira PS1'

$p = New-RawFile 'dvd.chd' (New-ChdBytes 4700000000 5)   # ~4,7 GB
Assert-True ((Get-ChdPlatform $p) -eq 'PS2') 'CHD de DVD (4,7 GB) vira PS2'

$p = New-RawFile 'v3.chd' (New-ChdBytes 4700000000 3)
Assert-True ((Get-ChdPlatform $p) -eq 'PS2') 'CHD v3 de DVD vira PS2'

$p = New-RawFile 'junk.chd' (New-Padded ([byte[]](1, 2, 3, 4, 5, 6, 7, 8)))
Assert-True (-not (Test-GameSignature ([IO.FileInfo]$p) '.chd')) 'Arquivo qualquer com .chd é reprovado'

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Write-Host ""
Write-Host ("Resultado: {0} passaram, {1} falharam" -f $script:Passed, $script:Failed) `
    -ForegroundColor ($(if ($script:Failed) { 'Red' } else { 'Green' }))
if ($script:Failed) { exit 1 }
