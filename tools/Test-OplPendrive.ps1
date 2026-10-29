<#
.SYNOPSIS
    Verifica se um pendrive está no formato que o OPL espera.

.DESCRIPTION
    Simula no Windows o que o OPL faz ao abrir a unidade USB:

      - lê o ul.cfg registro por registro (64 bytes cada);
      - recalcula o CRC do nome (USBA_crc32) e monta o nome de cada pedaço;
      - confere quantidade, numeração e tamanho dos pedaços (1 GiB, o último menor);
      - abre cada ISO da pasta DVD e valida ISO9660, SYSTEM.CNF, tamanho e o
        executável apontado pelo BOOT2.

    Não emula o console: valida o que o PS2 vai ler. O que sobra de risco é
    hardware (porta USB) e versão do OPL instalada no console.

.PARAMETER Drive
    Letra da unidade, com ou sem dois-pontos. Ex.: F ou F:

.EXAMPLE
    .\tools\Test-OplPendrive.ps1 -Drive F

.EXAMPLE
    .\tools\Test-OplPendrive.ps1 -Drive G
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Drive
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib\UlFormat.ps1')

# ---------------------------------------------------------------- estado

$script:OkCount = 0
$script:WarnCount = 0
$script:FailCount = 0
$script:GameCount = 0
$script:Listing = New-Object System.Collections.ArrayList

function Write-Check {
    param(
        [ValidateSet('OK', 'WARN', 'FAIL')][string]$Kind,
        [string]$Text
    )

    switch ($Kind) {
        'OK' { $script:OkCount++; $tag = 'PASS'; $color = 'Green' }
        'WARN' { $script:WarnCount++; $tag = 'WARN'; $color = 'Yellow' }
        'FAIL' { $script:FailCount++; $tag = 'FAIL'; $color = 'Red' }
    }
    Write-Host ('  [{0}] {1}' -f $tag, $Text) -ForegroundColor $color
}

# ---------------------------------------------------------------- ISO9660

function Read-IsoDir {
    <# Lê um diretório ISO9660 e devolve as entradas (nome, LBA, tamanho, flags). #>
    param(
        [Parameter(Mandatory = $true)][IO.FileStream]$Fs,
        [Parameter(Mandatory = $true)][uint32]$Lba,
        [Parameter(Mandatory = $true)][uint32]$Size
    )

    $len = [int]$Size
    if ($len -le 0 -or $len -gt 4MB) { return @() }

    $buf = New-Object byte[] $len
    $Fs.Position = [int64]$Lba * 2048
    $read = 0
    while ($read -lt $len) {
        $n = $Fs.Read($buf, $read, $len - $read)
        if ($n -le 0) { break }
        $read += $n
    }

    $out = New-Object System.Collections.ArrayList
    $i = 0
    while ($i -lt $read) {
        $recLen = $buf[$i]
        if ($recLen -eq 0) {
            $i = ([int]([math]::Floor($i / 2048)) + 1) * 2048
            continue
        }

        $nameLen = [int]$buf[$i + 32]
        [void]$out.Add([pscustomobject]@{
            Name  = [Text.Encoding]::ASCII.GetString($buf, $i + 33, $nameLen)
            Lba   = [BitConverter]::ToUInt32($buf, $i + 2)
            Size  = [BitConverter]::ToUInt32($buf, $i + 10)
            Flags = $buf[$i + 25]
        })
        $i += $recLen
    }
    return @($out)
}

function Resolve-IsoPath {
    <# Resolve um caminho (ex.: SLUS_213.76 ou PASTA\ARQUIVO) dentro do ISO. #>
    param(
        [Parameter(Mandatory = $true)][IO.FileStream]$Fs,
        [Parameter(Mandatory = $true)][uint32]$RootLba,
        [Parameter(Mandatory = $true)][uint32]$RootSize,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $parts = @($Path.Trim('\') -split '\\' | Where-Object { $_ })
    if ($parts.Count -eq 0) { return $null }

    $lba = $RootLba
    $size = $RootSize
    $entry = $null

    for ($p = 0; $p -lt $parts.Count; $p++) {
        $wanted = $parts[$p] -replace ';\d+$', ''
        $entries = @(Read-IsoDir -Fs $Fs -Lba $lba -Size $size)
        $entry = $entries | Where-Object { ($_.Name -replace ';\d+$', '') -ieq $wanted } | Select-Object -First 1
        if (-not $entry) { return $null }

        $isLast = ($p -eq $parts.Count - 1)
        if (-not $isLast) {
            if (-not ($entry.Flags -band 2)) { return $null }
            $lba = $entry.Lba
            $size = $entry.Size
        }
    }

    if ($entry.Flags -band 2) { return $null }   # o boot tem que ser arquivo
    return $entry
}

# ---------------------------------------------------------------- ul.cfg

function Test-UlCfg {
    $cfg = Join-Path $rootPath 'ul.cfg'

    Write-Host ''
    Write-Host '  ul.cfg' -ForegroundColor White

    if (-not (Test-Path -LiteralPath $cfg)) {
        Write-Check WARN 'ul.cfg não existe (nenhum jogo no modo UL.*)'
        return
    }

    $len = (Get-Item -LiteralPath $cfg).Length
    if ($len % 64 -ne 0) {
        Write-Check FAIL ("ul.cfg tem {0} bytes (não é múltiplo de 64): o OPL ignora o resto" -f $len)
    } else {
        Write-Check OK ("{0} bytes = {1} registro(s)" -f $len, ($len / 64))
    }

    $entries = @(Read-UlEntries $rootPath)
    if ($entries.Count -eq 0) {
        Write-Check WARN 'ul.cfg está vazio'
        return
    }

    $seen = @{}
    foreach ($e in $entries) {
        $script:GameCount++
        Write-Host ''
        Write-Host ('  jogo: {0}  [{1}]' -f $e.Nome, $e.Media) -ForegroundColor White

        if (-not $e.Nome) {
            Write-Check FAIL 'entrada sem nome'
            continue
        }
        if ($seen.ContainsKey($e.Nome.ToUpperInvariant())) {
            Write-Check FAIL 'nome duplicado no ul.cfg'
        } else {
            $seen[$e.Nome.ToUpperInvariant()] = $true
        }
        if ($e.Nome -match '[^\x20-\x7E]') {
            Write-Check WARN 'nome com caractere fora de ASCII'
        }
        if ($e.Serial -notmatch '^[A-Z]{4}_\d{3}\.\d{2}$') {
            Write-Check WARN ('serial fora do padrão: [{0}]' -f $e.Serial)
        }
        if ($e.Media -notin 'CD', 'DVD') {
            Write-Check WARN ('media desconhecida: {0}' -f $e.Media)
        }

        $crc = '{0:X8}' -f (Get-UsbaCrc32 $e.Nome)
        if ($crc -ne $e.Crc) {
            Write-Check FAIL ('CRC calculado ({0}) difere do registrado ({1})' -f $crc, $e.Crc)
        }

        $parts = [int]$e.Partes
        if ($parts -le 0) {
            Write-Check FAIL 'registro diz 0 pedaços'
            continue
        }

        $total = [double]0
        $missing = 0
        for ($i = 0; $i -lt $parts; $i++) {
            $fn = 'ul.{0}.{1}.{2:x2}' -f $crc, $e.Serial, $i
            $fp = Join-Path $rootPath $fn
            if (-not (Test-Path -LiteralPath $fp)) {
                Write-Check FAIL ('falta o pedaço {0}' -f $fn)
                $missing++
                continue
            }

            $fl = [double](Get-Item -LiteralPath $fp).Length
            $total += $fl
            if ($i -lt ($parts - 1)) {
                if ($fl -ne 1GB) {
                    Write-Check FAIL ('pedaço {0} tem {1} (esperado 1 GiB)' -f $i, (Format-Size $fl))
                }
            } else {
                if ($fl -le 0 -or $fl -gt 1GB) {
                    Write-Check FAIL ('último pedaço com tamanho inválido: {0}' -f (Format-Size $fl))
                }
            }
        }

        if ($missing -eq 0) {
            Write-Check OK ('{0} pedaço(s), {1} no total' -f $parts, (Format-Size $total))
        }

        if ($total -gt 0) {
            $expected = [int][math]::Ceiling($total / 1GB)
            if ($expected -ne $parts) {
                Write-Check FAIL ('registro diz {0} pedaço(s), os arquivos somam {1}' -f $parts, $expected)
            }
        }

        $found = @(Get-ChildItem -LiteralPath $rootPath -File -Filter ("ul.{0}.{1}.*" -f $crc, $e.Serial) -ErrorAction SilentlyContinue)
        $extra = @($found | Where-Object {
            $leaf = $_.Name
            $idx = -1
            try { $idx = [Convert]::ToInt32($leaf.Substring($leaf.Length - 2), 16) } catch { }
            $idx -ge $parts
        })
        if ($extra.Count -gt 0) {
            Write-Check WARN ('{0} pedaço(s) sobrando (o OPL ignora): {1}' -f $extra.Count, (($extra | ForEach-Object { $_.Name }) -join ', '))
        }

        [void]$script:Listing.Add([pscustomobject]@{
            Media  = 'UL'
            Name   = $e.Nome
            Serial = $e.Serial
            Detail = ('{0} pedaço(s), {1}' -f $parts, (Format-Size $total))
        })
    }
}

# ---------------------------------------------------------------- DVD\*.iso

function Test-DvdIso {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [bool]$Fat32
    )

    $fi = Get-Item -LiteralPath $Path
    $script:GameCount++

    Write-Host ''
    Write-Host ('  ISO: {0}' -f $fi.Name) -ForegroundColor White

    if ($Fat32 -and $fi.Length -gt 4294967295) {
        Write-Check FAIL ('arquivo maior que 4 GiB em FAT32: {0}' -f (Format-Size $fi.Length))
    } else {
        Write-Check OK ('tamanho {0} ({1:N0} bytes)' -f (Format-Size $fi.Length), $fi.Length)
    }

    $info = $null
    try {
        $info = Get-IsoInfo $Path
    } catch {
        Write-Check FAIL ('ISO9660 inválido: {0}' -f $_.Exception.Message)
        return
    }

    if (-not $info.IsPs2) {
        Write-Check FAIL 'não é ISO de PS2 (sem SYSTEM.CNF / PLAYSTATION)'
        return
    }
    Write-Check OK ('PS2 {0} v{1}' -f $info.Serial, $info.Ver)

    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $fs.Position = 0x8000
        $pvd = New-Object byte[] 2048
        [void]$fs.Read($pvd, 0, 2048)

        $blocks = [BitConverter]::ToUInt32($pvd, 80)
        if (([int64]$blocks * 2048) -eq $fi.Length) {
            Write-Check OK ('tamanho bate com o PVD ({0} setores)' -f $blocks)
        } else {
            Write-Check FAIL ('PVD declara {0} bytes, arquivo tem {1}' -f ($blocks * 2048), $fi.Length)
        }

        $rootLba = [BitConverter]::ToUInt32($pvd, 158)
        $rootLen = [BitConverter]::ToUInt32($pvd, 166)
        $entries = @(Read-IsoDir -Fs $fs -Lba $rootLba -Size $rootLen)

        $cnf = $entries | Where-Object { $_.Name -like 'SYSTEM.CNF*' } | Select-Object -First 1
        if (-not $cnf) {
            Write-Check FAIL 'SYSTEM.CNF não encontrado na raiz'
            return
        }

        $fs.Position = [int64]$cnf.Lba * 2048
        $buf = New-Object byte[] ([Math]::Min(4096, [int]$cnf.Size))
        [void]$fs.Read($buf, 0, $buf.Length)
        $txt = [Text.Encoding]::ASCII.GetString($buf)

        $m = [regex]::Match($txt, 'BOOT2\s*=\s*cdrom0:\\([^\r\n]+)', 'IgnoreCase')
        if (-not $m.Success) {
            Write-Check FAIL 'SYSTEM.CNF sem BOOT2'
            return
        }

        $boot = ($m.Groups[1].Value -replace ';\d+\s*$', '').Trim()
        $be = Resolve-IsoPath -Fs $fs -RootLba $rootLba -RootSize $rootLen -Path $boot
        if ($be -and $be.Size -gt 0) {
            Write-Check OK ('executável do BOOT2 existe: {0} ({1:N0} bytes)' -f $boot, $be.Size)
        } elseif ($be) {
            Write-Check FAIL ('executável do BOOT2 tem 0 bytes: {0}' -f $boot)
        } else {
            Write-Check FAIL ('executável do BOOT2 não existe no ISO: {0}' -f $boot)
        }

        [void]$script:Listing.Add([pscustomobject]@{
            Media  = 'DVD'
            Name   = $fi.BaseName
            Serial = $info.Serial
            Detail = ('1 arquivo, {0}' -f (Format-Size $fi.Length))
        })
    } finally {
        $fs.Dispose()
    }
}

# ---------------------------------------------------------------- unidade

$letter = $Drive.Trim().TrimEnd(':', '\').ToUpperInvariant()
if ($letter -notmatch '^[A-Z]$') { throw "Letra de unidade inválida: $Drive" }

$rootPath = "${letter}:\"
if (-not (Test-Path -LiteralPath $rootPath)) { throw "Unidade ${letter}: não encontrada." }

$vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
$fsName = if ($vol) { $vol.FileSystem } else { (New-Object IO.DriveInfo($rootPath)).DriveFormat }
$label = if ($vol) { $vol.FileSystemLabel } else { (New-Object IO.DriveInfo($rootPath)).VolumeLabel }
$free = if ($vol) { $vol.SizeRemaining } else { (New-Object IO.DriveInfo($rootPath)).AvailableFreeSpace }
$total = if ($vol) { $vol.Size } else { (New-Object IO.DriveInfo($rootPath)).TotalSize }
$fat32 = ($fsName -eq 'FAT32')

Write-Host ''
Write-Host '  EASYROMS::OPL  -  verificador de pendrive' -ForegroundColor Cyan
Write-Host ('  unidade {0}:  {1}  {2}  -  {3} livres de {4}' -f $letter, $label, $fsName, (Format-Size $free), (Format-Size $total))

if (-not $fat32) {
    Write-Check WARN ('sistema de arquivos {0}: o OPL USB espera FAT32' -f $fsName)
} else {
    Write-Check OK 'FAT32 (limite de 4 GiB por arquivo)'
}

Test-UlCfg

$dvd = Join-Path $rootPath 'DVD'
$isos = @(Get-ChildItem -LiteralPath $dvd -File -Filter '*.iso' -ErrorAction SilentlyContinue | Sort-Object Name)
if ($isos.Count -eq 0) {
    Write-Host ''
    Write-Host '  DVD' -ForegroundColor White
    Write-Check WARN 'nenhum .iso na pasta DVD'
} else {
    foreach ($iso in $isos) {
        Test-DvdIso -Path $iso.FullName -Fat32 $fat32
    }
}

# ---------------------------------------------------------------- resumo

Write-Host ''
Write-Host '  OPL LISTARIA' -ForegroundColor Cyan
if ($script:Listing.Count -eq 0) {
    Write-Host '    (nada)' -ForegroundColor DarkGray
} else {
    foreach ($g in $script:Listing) {
        Write-Host ('    [{0}] {1,-30} {2,-13} {3}' -f $g.Media, $g.Name, $g.Serial, $g.Detail)
    }
}

Write-Host ''
$summary = 'Resultado: {0} jogo(s), {1} verificação(ões) OK, {2} aviso(s), {3} falha(s)' -f $script:GameCount, $script:OkCount, $script:WarnCount, $script:FailCount
if ($script:FailCount -gt 0) {
    Write-Host ('  ' + $summary) -ForegroundColor Red
    Write-Host '  O OPL provavelmente NÃO vai abrir o que falhou acima.' -ForegroundColor Red
    exit 1
}

Write-Host ('  ' + $summary) -ForegroundColor Green
Write-Host '  A estrutura está no formato que o OPL espera.' -ForegroundColor Green
exit 0
