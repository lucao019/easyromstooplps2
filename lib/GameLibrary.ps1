# ===========================================================================
#  GameLibrary — catálogo de jogos encontrados em uma unidade
#
#  Varre a unidade com profundidade limitada e devolve os arquivos que
#  parecem jogos, com a plataforma identificada pelo formato:
#
#    PS2     .iso com SYSTEM.CNF (ou pasta/ISO com serial de PS2)
#    PS1     .bin/.cue/.chd/.pbp/.img/.mdf/.ccd (e .iso de PS1)
#    SNES    .sfc .smc          N64   .n64 .z64 .v64      GBA  .gba
#    GB      .gb .gbc           NDS   .nds                GC   .gcm .rvz .wbfs
#    MEGA    .md .gen .smd      MASTER .sms .gg           NES  .nes .fds
#    PSP     .cso               DC    .gdi .cdi
#
#  É só leitura: nada é gravado na unidade. A varredura roda em segundo
#  plano (runspace) para não travar a janela.
# ===========================================================================

if (-not (Get-Command Get-IsoInfo -ErrorAction SilentlyContinue)) {
    $ul = Join-Path $PSScriptRoot 'UlFormat.ps1'
    if (Test-Path -LiteralPath $ul) { . $ul }
}

$script:GameExt = @{
    '.iso' = 'ISO'
    '.bin' = 'PS1'; '.cue' = 'PS1'; '.chd' = 'PS1'; '.pbp' = 'PS1'
    '.img' = 'PS1'; '.mdf' = 'PS1'; '.mds' = 'PS1'; '.ccd' = 'PS1'
    '.sfc' = 'SNES'; '.smc' = 'SNES'
    '.n64' = 'N64'; '.z64' = 'N64'; '.v64' = 'N64'
    '.gba' = 'GBA'
    '.gb' = 'GB'; '.gbc' = 'GB'
    '.nds' = 'NDS'
    '.gcm' = 'GC'; '.rvz' = 'GC'; '.wbfs' = 'GC'
    '.md' = 'MEGA'; '.gen' = 'MEGA'; '.smd' = 'MEGA'
    '.sms' = 'MASTER'; '.gg' = 'MASTER'
    '.nes' = 'NES'; '.fds' = 'NES'
    '.cso' = 'PSP'
    '.gdi' = 'DC'; '.cdi' = 'DC'
}

# Pastas que nunca têm jogo (lixo do Windows ou estrutura do próprio OPL).
$script:GameSkipDirs = @(
    '$RECYCLE.BIN', 'SYSTEM VOLUME INFORMATION', '.GIT', 'NODE_MODULES',
    'ART', 'CFG', 'CHT', 'LNG', 'THM', 'VMC', 'PATINFO'
)

function Get-GamePlatformLabel {
    param([string]$Platform)

    switch ($Platform) {
        'PS2'    { return 'PS2' }
        'PS1'    { return 'PS1' }
        'SNES'   { return 'SNES' }
        'N64'    { return 'N64' }
        'GBA'    { return 'GBA' }
        'GB'     { return 'GB/GBC' }
        'NDS'    { return 'NDS' }
        'GC'     { return 'GC/WII' }
        'MEGA'   { return 'MEGA' }
        'MASTER' { return 'MASTER' }
        'NES'    { return 'NES' }
        'PSP'    { return 'PSP' }
        'DC'     { return 'DC' }
        default  { return 'ISO' }
    }
}

function Get-GamePlatformRank {
    param([string]$Platform)

    switch ($Platform) {
        'PS2'    { return 0 }
        'PS1'    { return 1 }
        'SNES'   { return 2 }
        'N64'    { return 3 }
        'GBA'    { return 4 }
        'GB'     { return 5 }
        'NDS'    { return 6 }
        'GC'     { return 7 }
        'MEGA'   { return 8 }
        'MASTER' { return 9 }
        'NES'    { return 10 }
        'PSP'    { return 11 }
        'DC'     { return 12 }
        default  { return 13 }
    }
}

function Get-GameSerialFromName {
    <#
        Extrai o serial do nome do arquivo, no formato que os dumps usam:
        "Jogo (SLUS_215.97).iso" ou "Jogo (SLUS-21597).iso".
    #>
    param([string]$Name)

    $m = [regex]::Match($Name, '\(\s*([A-Z]{4})[_-]?(\d{3})[.\-]?(\d{2})\s*\)', 'IgnoreCase')
    if ($m.Success) {
        return ('{0}_{1}.{2}' -f $m.Groups[1].Value.ToUpperInvariant(), $m.Groups[2].Value, $m.Groups[3].Value)
    }
    return $null
}

function Get-GameLibrary {
    <#
        .SYNOPSIS
            Lista os jogos (PS2, PS1, Nintendo e outros) encontrados na unidade.

        .PARAMETER Root
            Raiz da unidade, ex. "F:\".

        .PARAMETER MaxDepth
            Quantas pastas abaixo da raiz descer (padrão 4).

        .PARAMETER Limit
            Máximo de jogos devolvidos (padrão 800). Evita travar em unidade
            com milhares de arquivos.

        .PARAMETER MaxIsoChecks
            Quantos .iso podem ser abertos para confirmar se são de PS2
            (padrão 60). Os demais são classificados pelo nome/pasta.

        .PARAMETER NoIsoInspection
            Não abre nenhum .iso (só nome/pasta). Mais rápido, menos preciso.

        .PARAMETER Report
            Devolve um objeto com Items/Count/Truncated em vez do array puro.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [int]$MaxDepth = 4,
        [int]$Limit = 800,
        [int]$MaxIsoChecks = 60,
        [switch]$NoIsoInspection,
        [switch]$Report
    )

    $rootFull = [IO.Path]::GetFullPath($Root)
    if (-not $rootFull.EndsWith('\')) { $rootFull += '\' }

    $found = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([pscustomobject]@{ Path = $rootFull; Depth = 0 })

    $truncated = $false
    $folders = 0
    $isoChecks = 0
    $hasIsoInfo = [bool](Get-Command Get-IsoInfo -ErrorAction SilentlyContinue)

    while ($queue.Count -gt 0 -and -not $truncated) {
        $cur = $queue.Dequeue()
        $folders++

        $files = @()
        try {
            $files = [IO.Directory]::GetFiles($cur.Path)
            if ($cur.Depth -lt $MaxDepth) {
                foreach ($d in [IO.Directory]::GetDirectories($cur.Path)) {
                    $leaf = [IO.Path]::GetFileName($d).ToUpperInvariant()
                    if ($script:GameSkipDirs -contains $leaf) { continue }
                    $queue.Enqueue([pscustomobject]@{ Path = $d; Depth = $cur.Depth + 1 })
                }
            }
        } catch {
            continue   # pasta sem permissão / unidade removida no meio
        }

        foreach ($f in $files) {
            if ($found.Count -ge $Limit) { $truncated = $true; break }

            $ext = [IO.Path]::GetExtension($f).ToLowerInvariant()
            $platform = $script:GameExt[$ext]
            if (-not $platform) { continue }

            try { $fi = New-Object IO.FileInfo($f) } catch { continue }

            # .cue/.ccd/.mds são arquivos de texto minúsculos: valem mesmo assim.
            if ($fi.Length -lt 4096 -and $ext -notin '.cue', '.ccd', '.mds') { continue }

            $base = [IO.Path]::GetFileNameWithoutExtension($f)
            $serial = $null

            if ($ext -eq '.iso') {
                $serial = Get-GameSerialFromName $base

                if (-not $NoIsoInspection -and $hasIsoInfo -and $isoChecks -lt $MaxIsoChecks -and $fi.Length -ge 0x9000) {
                    $isoChecks++
                    try {
                        $info = Get-IsoInfo -Path $f
                        if ($info.IsPs2) {
                            $platform = 'PS2'
                            $serial = $info.Serial
                        } elseif ($info.SystemCnf) {
                            $platform = 'PS2'
                        } elseif ($serial) {
                            $platform = 'PS1'   # serial na capa, mas sem SYSTEM.CNF
                        }
                    } catch {
                        # não é ISO9660 legível: decide pelo nome/pasta abaixo
                    }
                }

                if ($platform -eq 'ISO') {
                    $folderName = [IO.Path]::GetFileName($cur.Path)
                    if ($folderName -match '(?i)ps2|playstation\s*2') { $platform = 'PS2' }
                    elseif ($folderName -match '(?i)ps1|psx|playstation\s*1') { $platform = 'PS1' }
                    elseif ($folderName -match '(?i)gamecube|wii') { $platform = 'GC' }
                    elseif ($serial) { $platform = 'PS1' }
                }
            }

            [void]$found.Add([pscustomobject]@{
                Name          = $base
                File          = $fi.FullName
                Rel           = $fi.FullName.Substring($rootFull.Length)
                Dir           = $fi.DirectoryName
                Ext           = $ext
                Size          = [double]$fi.Length
                Platform      = $platform
                PlatformLabel = (Get-GamePlatformLabel $platform)
                Serial        = $serial
                Kind          = $(if ($ext -eq '.iso') { 'iso' } else { 'rom' })
            })
        }
    }

    # .cue+.bin (e .ccd+.img, .mds+.mdf) são o mesmo jogo: fica só a "capa".
    $covers = @{}
    foreach ($it in $found) {
        if ($it.Ext -in '.cue', '.ccd', '.mds') {
            $covers[($it.Dir + '|' + $it.Name).ToLowerInvariant()] = $true
        }
    }
    $items = New-Object System.Collections.ArrayList
    foreach ($it in $found) {
        if ($it.Ext -in '.bin', '.img', '.mdf') {
            if ($covers.ContainsKey(($it.Dir + '|' + $it.Name).ToLowerInvariant())) { continue }
        }
        [void]$items.Add($it)
    }

    $sorted = @($items | Sort-Object @{ e = { Get-GamePlatformRank $_.Platform } }, Name)

    if ($Report) {
        return [pscustomobject]@{
            Root       = $rootFull
            Items      = $sorted
            Count      = $sorted.Count
            Folders    = $folders
            Truncated  = $truncated
            IsoChecked = $isoChecks
        }
    }

    return $sorted
}
