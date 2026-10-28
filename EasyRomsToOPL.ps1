<#
.SYNOPSIS
    Adiciona jogos de PS2 a um pendrive do OPL (Open PS2 Loader) no formato "ul.*".

.DESCRIPTION
    O OPL grava jogos de USB em pedaços de 1 GiB chamados  ul.<CRC32>.<SERIAL>.<NN>
    e mantém um índice binário de 64 bytes por jogo no arquivo ul.cfg.

    Este script:
      1. lê o serial real de dentro do ISO (SYSTEM.CNF / ISO9660);
      2. divide a imagem em pedaços de 1 GiB;
      3. grava a entrada correta no ul.cfg;
      4. confere o tamanho final.

    O cálculo de CRC foi validado contra jogos reais instalados por ferramentas
    oficiais (ver tests/Test-UlFormat.ps1).

.PARAMETER Iso
    Caminho do ISO de PS2.

.PARAMETER Drive
    Letra do pendrive. Padrão: F.

.PARAMETER Nome
    Nome exibido no menu do OPL (máx. 32 caracteres). Padrão: nome do arquivo.

.PARAMETER Serial
    Força o serial (normalmente é lido do próprio ISO).

.PARAMETER DvdFolder
    Copia como .iso solto na pasta DVD (só para arquivos abaixo de 4 GB).

.PARAMETER DryRun
    Mostra o que faria, sem gravar nada.

.PARAMETER Listar
    Lista os jogos instalados e sai.

.PARAMETER Force
    Substitui um jogo com o mesmo serial.

.EXAMPLE
    .\EasyRomsToOPL.ps1 -Listar

.EXAMPLE
    .\EasyRomsToOPL.ps1 -Iso "E:\jogos\Shadow of the Colossus.iso" -DryRun

.EXAMPLE
    .\EasyRomsToOPL.ps1 -Iso "E:\jogos\Shadow of the Colossus.iso" -Nome "Shadow of the Colossus"

.EXAMPLE
    .\EasyRomsToOPL.ps1 -Iso "E:\jogos\jogo-pequeno.iso" -DvdFolder
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Iso,

    [string]$Drive = 'F',

    [string]$Nome,

    [string]$Serial,

    [switch]$DvdFolder,

    [switch]$DryRun,

    [switch]$Listar,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

. (Join-Path $PSScriptRoot 'lib\UlFormat.ps1')

$PartSize = $script:UlPartSize
$Root = "$($Drive.TrimEnd(':')):\"

if (-not (Test-Path -LiteralPath $Root)) {
    throw "Unidade $Root não encontrada. Confira a letra do pendrive (-Drive)."
}

# ------------------------------------------------------------------ listar

if ($Listar) {
    Write-Host ""
    Write-Host "Pendrive: $Root" -ForegroundColor Cyan
    try {
        $di = New-Object IO.DriveInfo($Root)
        Write-Host ("Livre: {0} de {1}" -f (Format-Size $di.AvailableFreeSpace), (Format-Size $di.TotalSize)) -ForegroundColor DarkGray
    } catch { }
    Write-Host ""

    $entries = @(Read-UlEntries $Root)
    if ($entries.Count -eq 0) {
        Write-Host "Nenhum jogo no formato ul.* (ul.cfg vazio ou inexistente)." -ForegroundColor Yellow
    } else {
        Write-Host "Jogos em ul.cfg:" -ForegroundColor Green
        $entries | Format-Table Nome, Serial, Media, Partes, Crc -AutoSize
    }

    foreach ($folder in 'DVD', 'CD') {
        $p = Join-Path $Root $folder
        if (Test-Path -LiteralPath $p) {
            $isos = @(Get-ChildItem $p -File -Filter *.iso -ErrorAction SilentlyContinue)
            if ($isos.Count -gt 0) {
                Write-Host "ISOs soltos na pasta $folder (lidos direto pelo OPL):" -ForegroundColor Green
                $isos | Select-Object Name, @{n = 'Tamanho'; e = { Format-Size $_.Length } } | Format-Table -AutoSize
            }
        }
    }
    return
}

if (-not $Iso) {
    throw "Informe o caminho do ISO. Exemplo: .\EasyRomsToOPL.ps1 -Iso 'E:\jogos\jogo.iso'"
}
if (-not (Test-Path -LiteralPath $Iso)) { throw "ISO não encontrado: $Iso" }

$isoItem = Get-Item -LiteralPath $Iso
if ($isoItem.Length -lt 1MB) { throw "Arquivo muito pequeno para ser um ISO de PS2: $Iso" }

# ------------------------------------------------------------------ validação

$info = Get-IsoInfo $isoItem.FullName
if (-not $info.IsPs2) {
    throw ("O arquivo não parece um jogo de PS2.{0}  PVD={1}  SystemId={2}  SYSTEM.CNF={3}" -f
        [Environment]::NewLine, $info.Pvd, $info.SystemId, $info.SystemCnf)
}

$gameSerial = if ($Serial) { $Serial.ToUpper() } else { $info.Serial }
if ($gameSerial.Length -gt 12) { throw "Serial inválido: $gameSerial (máximo 12 caracteres)." }

$gameName = if ($Nome) { ConvertTo-AsciiName $Nome } else { ConvertTo-AsciiName $isoItem.BaseName }
if ([string]::IsNullOrWhiteSpace($gameName)) {
    throw "O nome do jogo ficou vazio. Use -Nome 'Nome do Jogo'."
}

Write-Verbose "ISO: $($info.Path)"
Write-Verbose "Serial lido do SYSTEM.CNF: $($info.Serial)"
Write-Verbose "VER: $($info.Ver)"

# ------------------------------------------------------------------ modo pasta DVD

if ($DvdFolder) {
    $limit = 4GB - 1MB
    if ($isoItem.Length -ge $limit) {
        throw ("Esse ISO tem {0} e não cabe na pasta DVD: FAT32 não aceita arquivo de 4 GB ou mais.{1}Use o modo padrão (dividido em ul.*), que aceita qualquer tamanho." -f
            (Format-Size $isoItem.Length), [Environment]::NewLine)
    }

    $destFolder = Join-Path $Root 'DVD'
    if (-not (Test-Path -LiteralPath $destFolder)) {
        New-Item -ItemType Directory -Path $destFolder | Out-Null
    }
    $dest = Join-Path $destFolder ($gameName + '.iso')

    Write-Host ""
    Write-Host "Modo: ISO direto na pasta DVD" -ForegroundColor Cyan
    Write-Host "  Nome    : $gameName"
    Write-Host "  Serial  : $gameSerial"
    Write-Host "  Tamanho : $(Format-Size $isoItem.Length)"
    Write-Host "  Destino : $dest"

    if ($DryRun) { Write-Host "`n[dry-run] nada foi gravado." -ForegroundColor Yellow; return }

    Install-DvdFolderGame -IsoPath $isoItem.FullName -Root $Root -Name $gameName -OnLog {
        param($level, $message)
        if ($level -eq 'ok') { Write-Host "  $message" -ForegroundColor DarkGray }
    } | Out-Null
    Write-Host "`nOK. O OPL lista o jogo ao abrir a lista de USB." -ForegroundColor Green
    return
}

# ------------------------------------------------------------------ modo ul.*

$parts = [int][Math]::Ceiling($isoItem.Length / $PartSize)
if ($parts -gt 255) { throw "ISO grande demais para o formato ul.* (máximo 255 pedaços)." }

$media = if ($isoItem.Length -gt 700MB) { $script:UlMediaDVD } else { $script:UlMediaCD }

$existing = @(Read-UlEntries $Root)
$dup = $existing | Where-Object { $_.Serial -eq $gameSerial }

$vol = $null
try { $vol = New-Object IO.DriveInfo($Root) } catch { }
if ($vol -and $vol.AvailableFreeSpace -lt ($isoItem.Length + 4096)) {
    throw ("Espaço insuficiente: precisa de {0}, livre {1}." -f
        (Format-Size ($isoItem.Length + 4096)), (Format-Size $vol.AvailableFreeSpace))
}

if ($dup -and -not $Force) {
    Write-Host ""
    Write-Host "AVISO: já existe '$($dup.Nome)' com o serial $gameSerial no ul.cfg." -ForegroundColor Yellow
    Write-Host "       Use -Force para substituir, ou apague o jogo antigo." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Modo: formato ul.* (padrão do OPL para USB)" -ForegroundColor Cyan
Write-Host "  Nome    : $gameName"
Write-Host "  Serial  : $gameSerial"
Write-Host "  Mídia   : $(if ($media -eq $script:UlMediaDVD) { 'DVD' } else { 'CD' })"
Write-Host "  Tamanho : $(Format-Size $isoItem.Length)"
Write-Host "  Partes  : $parts x 1 GiB"
Write-Host "  Arquivos: $(Get-UlPartName $gameName $gameSerial 0) .. $(Get-UlPartName $gameName $gameSerial ($parts - 1))"
Write-Host "  ul.cfg  : +1 entrada de 64 bytes"

if ($isoItem.Length -gt 4.7GB) {
    Write-Host "  Aviso   : imagem DVD9 (dupla camada) — funciona, mas sofre mais no USB 1.1." -ForegroundColor Yellow
}

if ($DryRun) { Write-Host "`n[dry-run] nada foi gravado." -ForegroundColor Yellow; return }

if ($dup -and -not $Force) {
    throw "Já existe um jogo com o serial $gameSerial no ul.cfg ('$($dup.Nome)'). Use -Force para substituir, ou apague o antigo."
}
Write-Host ""

$onLog = {
    param($level, $message)
    switch ($level) {
        'ok'    { Write-Host "  $message" -ForegroundColor Green }
        'warn'  { Write-Host "  $message" -ForegroundColor Yellow }
        'error' { Write-Host "  $message" -ForegroundColor Red }
        default { Write-Host "  $message" -ForegroundColor DarkGray }
    }
}

try {
    $result = Install-UlGame -IsoPath $isoItem.FullName -Root $Root -Name $gameName `
        -Serial $gameSerial -Media $media -Force:$Force -OnLog $onLog
}
catch {
    Write-Host "`nERRO: $_" -ForegroundColor Red
    throw
}

Write-Host ""
Write-Host "Pronto! '$gameName' ($gameSerial) adicionado." -ForegroundColor Green
Write-Host "No PS2: abra o OPL > USB > o jogo aparece na lista." -ForegroundColor Green
