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

# Tamanho mínimo de um jogo de verdade. Um README.md de 3 KB não é Mega Drive;
# um save .bin de 2 KB não é imagem de PS1. Isso corta 90% dos falsos positivos.
$script:GameMinSize = @{
    '.iso' = 32768; '.bin' = 4096; '.cue' = 0; '.chd' = 32768; '.pbp' = 32768
    '.img' = 4096; '.mdf' = 4096; '.mds' = 0; '.ccd' = 0
    '.sfc' = 8192; '.smc' = 8192
    '.n64' = 65536; '.z64' = 65536; '.v64' = 65536
    '.gba' = 16384
    '.gb' = 4096; '.gbc' = 4096
    '.nds' = 65536
    '.gcm' = 262144; '.rvz' = 262144; '.wbfs' = 262144
    '.md' = 8192; '.gen' = 8192; '.smd' = 8192
    '.sms' = 4096; '.gg' = 4096
    '.nes' = 8192; '.fds' = 16384
    '.cso' = 65536
    '.gdi' = 0; '.cdi' = 262144
}

# O "capa" de cada par de disco: .bin só é jogo se existir o .cue ao lado.
$script:CoverExt = @{ '.bin' = '.cue'; '.img' = '.ccd'; '.mdf' = '.mds' }

# Extensões que são arquivos de texto por natureza (não dá para checar conteúdo).
$script:TextExt = @('.cue', '.ccd', '.mds', '.gdi')

# Arquivos compactados: o jogo pode estar dentro deles (é como os dumps vêm).
$script:ArchiveExt = @('.zip', '.rar', '.7z')

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
        'ARQ'    { return 'ARQUIVO' }
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

function Get-GameFileHead {
    param([string]$Path, [int]$Count = 512)

    $fs = $null
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $n = $Count
        if ($fs.Length -lt [int64]$Count) { $n = [int]$fs.Length }
        if ($n -le 0) { return , (New-Object byte[] 0) }
        $buf = New-Object byte[] $n
        [void]$fs.Read($buf, 0, $n)
        return , $buf
    } catch {
        return , (New-Object byte[] 0)
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

# .cue → nomes de arquivos que ele referencia. Cache por pasta: numa pasta com
# 30 faixas de .bin, o .cue é lido uma vez só.
$script:CueRefCache = @{}

function Get-CueFileRefs {
    param([string]$Dir)

    $key = $Dir.ToLowerInvariant()
    if ($script:CueRefCache.ContainsKey($key)) { return $script:CueRefCache[$key] }

    $set = @{}
    try {
        foreach ($cue in @([IO.Directory]::GetFiles($Dir, '*.cue'))) {
            try {
                $txt = [IO.File]::ReadAllText($cue)
                foreach ($m in [regex]::Matches($txt, '(?im)^\s*FILE\s+(?:"([^"]+)"|(\S+))')) {
                    $n = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
                    $set[[IO.Path]::GetFileName($n).ToLowerInvariant()] = $true
                }
            } catch { }
        }
    } catch { }

    $script:CueRefCache[$key] = $set
    return $set
}

function Test-GameTextFile {    <#
        Um README.md, uma lista.txt ou um .nfo têm extensão parecida com a de
        jogo, mas são texto. ROM de verdade tem byte zero e binário no começo.
    #>
    param([string]$Path)

    $b = Get-GameFileHead $Path 512
    if ($b.Length -eq 0) { return $true }

    $text = 0
    $bin = 0
    foreach ($x in $b) {
        if ($x -eq 0) { $bin++; continue }
        if ($x -lt 0x09) { $bin++; continue }
        if (($x -ge 0x20 -and $x -lt 0x7F) -or $x -eq 0x09 -or $x -eq 0x0A -or $x -eq 0x0D -or $x -ge 0xC2) { $text++ }
        else { $bin++ }
    }
    return ($bin -eq 0 -and $text -gt 0)
}

function Test-MegaDriveRom {
    <# ROM de Mega Drive tem "SEGA" no cabeçalho, no offset 0x100. #>
    param([string]$Path)

    $b = Get-GameFileHead $Path 0x120
    if ($b.Length -lt 0x104) { return $false }
    return ([Text.Encoding]::ASCII.GetString($b, 0x100, 4) -eq 'SEGA')
}

function Test-GameFile {
    <#
        Confere se o arquivo realmente pode ser um jogo, e não só um arquivo
        com a extensão certa. Devolve $true/$false; nunca lança.
    #>
    param([IO.FileInfo]$File, [string]$Ext)

    $min = 0
    if ($script:GameMinSize.ContainsKey($Ext)) { $min = [int64]$script:GameMinSize[$Ext] }
    if ($File.Length -lt $min) { return $false }

    if ($script:TextExt -contains $Ext) { return $true }

    # O ISO não passa por esse teste: o setor de sistema pode vir preenchido
    # com um byte repetido (0x6D, 0xED…) e parecer "texto". Para .iso quem
    # decide é a leitura do ISO9660, feita na varredura.
    if ($Ext -ne '.iso' -and (Test-GameTextFile $File.FullName)) { return $false }

    if ($Ext -in '.md', '.gen') {
        # .md também é Markdown: só aceita com a assinatura SEGA do console.
        return ((Test-MegaDriveRom $File.FullName) -or ($File.Length -ge 1048576))
    }

    if ($Ext -in '.bin', '.img', '.mdf') {
        # .bin/.img/.mdf solto é quase sempre pedaço de instalador, cache de
        # jogo de PC ou faixa solta: não é jogo. Só entra quando existe o
        # .cue/.ccd/.mds do disco — e a lista mostra só a "capa".
        $cover = [IO.Path]::ChangeExtension($File.FullName, $script:CoverExt[$Ext])
        return (Test-Path -LiteralPath $cover)
    }

    return $true
}

function Test-ArchiveJunkName {
    <# README.md, LICENSE.txt… dentro de um ZIP não são jogos, mesmo com extensão parecida. #>
    param([string]$Name)

    $leaf = [IO.Path]::GetFileName($Name)
    return ($leaf -match '(?i)^(readme|leiame|licen[cs]e|changelog|credits|cr[eé]ditos|notes|notas|todo|install|instalar|manual|instructions?|guia|guide)(\.[a-z0-9]+)?$')
}

function Get-GameSerialFromName {    <#
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

function Get-ArchiveExe {
    <#
        Programa que lista/extrai o compactado. ZIP é nativo; RAR precisa do
        UnRAR (vem com o WinRAR); 7Z usa o 7-Zip ou o tar do Windows.
    #>
    param([string]$Kind)

    $pf86 = ${env:ProgramFiles(x86)}

    if ($Kind -eq 'unrar') {
        foreach ($p in @(
                (Join-Path $env:ProgramFiles 'WinRAR\UnRAR.exe'),
                $(if ($pf86) { Join-Path $pf86 'WinRAR\UnRAR.exe' })
            )) {
            if ($p -and (Test-Path -LiteralPath $p)) { return $p }
        }
        return $null
    }

    if ($Kind -eq '7z') {
        foreach ($p in @(
                (Join-Path $env:ProgramFiles '7-Zip\7z.exe'),
                $(if ($pf86) { Join-Path $pf86 '7-Zip\7z.exe' })
            )) {
            if ($p -and (Test-Path -LiteralPath $p)) { return $p }
        }
    }

    if ($Kind -eq 'tar') {
        $t = Get-Command tar.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($t) { return $t.Source }
    }

    return $null
}

function Test-ArchiveContinuation {
    <#
        "Jogo.part2.rar" e "Jogo.r01" são pedaços do mesmo arquivo: só o
        primeiro volume é lido, senão o jogo apareceria várias vezes.
    #>
    param([string]$Path)

    $name = [IO.Path]::GetFileName($Path)
    if ($name -match '(?i)\.part(\d+)\.rar$' -and [int]$Matches[1] -gt 1) { return $true }
    return $false
}

function Get-ArchiveEntries {
    <#
        Lista os nomes dos arquivos dentro do compactado, sem extrair nada.
        Devolve Ok/Entries/Error. Nunca lança: um arquivo corrompido só
        devolve Ok = $false.
    #>
    param([string]$Path)

    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $names = New-Object System.Collections.ArrayList

    try {
        switch ($ext) {
            '.zip' {
                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
                $zip = [IO.Compression.ZipFile]::OpenRead($Path)
                try {
                    foreach ($e in $zip.Entries) {
                        if (-not $e.FullName.EndsWith('/')) { [void]$names.Add($e.FullName) }
                    }
                } finally { $zip.Dispose() }
            }
            '.rar' {
                $exe = Get-ArchiveExe 'unrar'
                if (-not $exe) { return [pscustomobject]@{ Ok = $false; Entries = @(); Error = 'UnRAR não encontrado' } }
                $out = & $exe 'lb' $Path 2>$null
                if ($LASTEXITCODE -ne 0) { throw ('UnRAR saiu com código {0}' -f $LASTEXITCODE) }
                foreach ($l in @($out)) {
                    $s = ([string]$l).Trim()
                    if ($s) { [void]$names.Add($s) }
                }
            }
            '.7z' {
                $tar = Get-ArchiveExe 'tar'
                $out = $null
                if ($tar) {
                    $out = & $tar '-tf' $Path 2>$null
                    if ($LASTEXITCODE -ne 0) { $out = $null }
                }
                if ($null -eq $out) {
                    $exe = Get-ArchiveExe '7z'
                    if (-not $exe) { return [pscustomobject]@{ Ok = $false; Entries = @(); Error = 'sem 7-Zip nem tar' } }
                    $raw = & $exe 'l' '-slt' $Path 2>$null
                    if ($LASTEXITCODE -ne 0) { throw ('7-Zip saiu com código {0}' -f $LASTEXITCODE) }
                    $out = @($raw | Where-Object { $_ -match '^Path = ' } | ForEach-Object { $_.Substring(7) } | Select-Object -Skip 1)
                }
                foreach ($l in @($out)) {
                    $s = ([string]$l).Trim()
                    if ($s) { [void]$names.Add($s) }
                }
            }
            default { return [pscustomobject]@{ Ok = $false; Entries = @(); Error = 'formato não suportado' } }
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Entries = @(); Error = $_.Exception.Message }
    }

    return [pscustomobject]@{ Ok = $true; Entries = @($names); Error = '' }
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

        .PARAMETER MaxArchiveChecks
            Quantos .zip/.rar/.7z podem ser abertos para ver o que têm dentro
            (padrão 40). Só o índice é lido: nada é extraído.

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
        [int]$MaxArchiveChecks = 40,
        [switch]$NoIsoInspection,
        [switch]$Report
    )

    $rootFull = [IO.Path]::GetFullPath($Root)
    if (-not $rootFull.EndsWith('\')) { $rootFull += '\' }
    $script:CueRefCache = @{}

    $found = New-Object System.Collections.ArrayList
    $archives = New-Object System.Collections.ArrayList
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

            if ($script:ArchiveExt -contains $ext) {
                # .zip/.rar/.7z: o jogo pode estar dentro. Lido depois da varredura.
                if (-not (Test-ArchiveContinuation $f)) {
                    try {
                        $afi = New-Object IO.FileInfo($f)
                        if ($afi.Length -ge 4096) { [void]$archives.Add($afi) }
                    } catch { }
                }
                continue
            }

            $platform = $script:GameExt[$ext]
            if (-not $platform) { continue }

            try { $fi = New-Object IO.FileInfo($f) } catch { continue }

            # Extensão certa não basta: README.md, lista.txt renomeado, save
            # pequeno… nada disso é jogo. O filtro olha tamanho e conteúdo.
            if (-not (Test-GameFile -File $fi -Ext $ext)) { continue }

            $base = [IO.Path]::GetFileNameWithoutExtension($f)
            $serial = $null
            $notAnIso = $false

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
                        # Não é ISO9660: não é jogo, é arquivo qualquer com .iso.
                        $notAnIso = $true
                    }
                }

                if ($notAnIso) { continue }

                # ISO que não foi aberto (limite da varredura): jogo de verdade
                # tem pelo menos 1 MB. Evita .iso de 40 KB que é só lixo.
                if (-not $NoIsoInspection -and $isoChecks -ge $MaxIsoChecks -and $fi.Length -lt 1048576) { continue }

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

    # Compactados: abre só o índice (nada é extraído) e vê se há jogo dentro.
    $archChecked = 0
    foreach ($afi in $archives) {
        if ($found.Count -ge $Limit) { $truncated = $true; break }
        if ($archChecked -ge $MaxArchiveChecks) { break }
        $archChecked++

        $list = Get-ArchiveEntries -Path $afi.FullName
        $inner = $null
        $innerPlatform = $null
        $innerCount = 0

        if ($list.Ok) {
            foreach ($e in @($list.Entries)) {
                if (Test-ArchiveJunkName $e) { continue }
                $iext = [IO.Path]::GetExtension($e).ToLowerInvariant()
                $ip = $script:GameExt[$iext]
                if (-not $ip) { continue }
                if ($iext -in '.bin', '.cue', '.ccd', '.mds', '.img', '.mdf') { continue }
                if ($ip -eq 'ISO') { $ip = 'PS2' }   # ISO dentro de arquivo: caso real é PS2
                $innerCount++
                if (-not $inner) {
                    $inner = [IO.Path]::GetFileName($e)
                    $innerPlatform = $ip
                }
            }
            if (-not $inner) { continue }   # compactado sem jogo: não polui a lista
        } else {
            $innerPlatform = 'ARQ'
        }

        $serial = $null
        if ($inner) { $serial = Get-GameSerialFromName ([IO.Path]::GetFileNameWithoutExtension($inner)) }
        if (-not $serial) { $serial = Get-GameSerialFromName $afi.BaseName }

        $rel = $afi.FullName.Substring($rootFull.Length)
        if ($list.Ok) {
            $rel = ('{0} · {1} jogo(s) dentro · {2}' -f $rel, $innerCount, $inner)
        } else {
            $rel = ('{0} · NÃO CONSEGUI LER O CONTEÚDO' -f $rel)
        }

        [void]$found.Add([pscustomobject]@{
            # "Jogo.part1" é só o primeiro pedaço: no menu vale "Jogo".
            Name          = ($afi.BaseName -replace '(?i)\.part\d+$', '')
            File          = $afi.FullName
            Rel           = $rel
            Dir           = $afi.DirectoryName
            Ext           = ([IO.Path]::GetExtension($afi.FullName)).ToLowerInvariant()
            Size          = [double]$afi.Length
            Platform      = $innerPlatform
            PlatformLabel = (Get-GamePlatformLabel $innerPlatform)
            Serial        = $serial
            Kind          = 'archive'
            Inner         = $inner
            InnerCount    = $innerCount
        })
    }

    # .cue+.bin (e .ccd+.img, .mds+.mdf) são o mesmo jogo: fica só a "capa".
    # Faixas de um jogo com vários .bin (Track 01, Track 02…) também somem: o
    # .cue já representa o disco inteiro e o app não deve listar 30 linhas.
    $covers = @{}
    $cueBases = @{}
    foreach ($it in $found) {
        if ($it.Ext -in '.cue', '.ccd', '.mds') {
            $covers[($it.Dir + '|' + $it.Name).ToLowerInvariant()] = $true
            if ($it.Ext -eq '.cue') { $cueBases[($it.Dir + '|' + $it.Name).ToLowerInvariant()] = $true }
        }
    }
    $items = New-Object System.Collections.ArrayList
    foreach ($it in $found) {
        if ($it.Ext -in '.bin', '.img', '.mdf') {
            $k = ($it.Dir + '|' + $it.Name).ToLowerInvariant()
            if ($covers.ContainsKey($k)) { continue }

            if ($it.Ext -eq '.bin') {
                # faixa citada dentro de algum .cue da pasta
                if ((Get-CueFileRefs $it.Dir).ContainsKey(($it.Name + $it.Ext).ToLowerInvariant())) { continue }

                # faixa que começa com o nome de um .cue da pasta
                $hit = $false
                foreach ($cb in @($cueBases.Keys)) {
                    if (-not $cb.StartsWith($it.Dir.ToLowerInvariant() + '|')) { continue }
                    $base = $cb.Substring($it.Dir.Length + 1)
                    if ($it.Name.ToLowerInvariant().StartsWith($base + ' (')) { $hit = $true; break }
                }
                if ($hit) { continue }
            }
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
            ArchiveChecked = $archChecked
        }
    }

    return $sorted
}
