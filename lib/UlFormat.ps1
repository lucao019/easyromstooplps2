<#
    UlFormat.ps1 — funções do formato de jogos USB do OPL (Open PS2 Loader).

    Uso:
        . .\lib\UlFormat.ps1

    Referências do formato (código-fonte do OPL):
        include/supportbase.h  -> USBExtreme_game_entry_t (64 bytes)
        src/supportbase.c      -> sbCreatePath_name() ("ul.%08X.%s.%02x")
        src/system.c           -> USBA_crc32()
#>

# Tamanho de cada pedaço do formato ul.* (1 GiB, não 1 GB)
$script:UlPartSize = 1GB

# Mídia conforme o tipo de disco do PS2
$script:UlMediaCD  = 0x12
$script:UlMediaDVD = 0x14

function Get-UsbaCrc32 {
    <#
        Reimplementação fiel de USBA_crc32() do OPL (src/system.c).

        Não é o CRC32 comum: a tabela é gerada de trás pra frente, o valor
        inicial é o último elemento da tabela e o byte NUL final entra no
        cálculo. Por isso o resultado diverge de qualquer CRC32 padrão.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $mask = [uint64]4294967295          # 0xFFFFFFFF
    $tab = New-Object 'uint32[]' 256
    $crc = [uint64]0

    for ($table = 0; $table -lt 256; $table++) {
        $crc = ([uint64]$table -shl 24) -band $mask
        for ($count = 8; $count -gt 0; $count--) {
            if (($crc -band [uint64]2147483648) -ne 0) {      # MSB ligado
                $crc = ($crc -shl 1) -band $mask
            } else {
                $crc = (($crc -shl 1) -bxor [uint64]79764919) -band $mask   # 0x04C11DB7
            }
        }
        $tab[255 - $table] = [uint32]$crc
    }

    $crc = [uint64]$tab[0]              # valor com que o laço termina no original
    $count = 0
    do {
        $byte = if ($count -lt $Text.Length) { [int][char]$Text[$count] } else { 0 }
        $count++
        $idx = ($byte -bxor [int](($crc -shr 24) -band 0xFF)) -band 0xFF
        $crc = ([uint64]$tab[$idx] -bxor (($crc -shl 8) -band $mask)) -band $mask
    } while (($byte -ne 0) -and ($count -le 32))

    return [uint32]$crc
}

function ConvertTo-AsciiName {
    <# Normaliza o nome exibido no OPL: sem acento, ASCII, no máximo 32 caracteres. #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [int]$Max = 32
    )

    $t = $Text.Normalize([Text.NormalizationForm]::FormD)
    $t = $t -replace '\p{Mn}', ''            # remove acentos
    $t = $t -replace '[^\x20-\x7E]', ' '     # só ASCII imprimível
    $t = ($t -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max).Trim() }
    return $t
}

function New-UlEntry {
    <#
        Monta a entrada de 64 bytes do ul.cfg.

        Layout (include/supportbase.h):
            0x00  char name[32]      nome exibido no OPL
            0x20  char magic[3]      "ul."
            0x23  char startup[12]   serial, ex. "SLUS_209.46"
            0x2F  u8   parts         quantidade de pedaços
            0x30  u8   media         0x14 = DVD, 0x12 = CD
            0x31  u8   unknown[4]    zeros
            0x35  u8   Byte08        sempre 0x08
            0x36  u8   unknown2[10]  zeros
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][ValidateRange(1, 255)][int]$Parts,
        [Parameter(Mandatory)][byte]$Media
    )

    $entry = New-Object byte[] 64
    $nameBytes = [Text.Encoding]::ASCII.GetBytes($Name)
    [Array]::Copy($nameBytes, 0, $entry, 0, [Math]::Min(32, $nameBytes.Length))
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('ul.'), 0, $entry, 32, 3)
    $serBytes = [Text.Encoding]::ASCII.GetBytes($Serial)
    [Array]::Copy($serBytes, 0, $entry, 35, [Math]::Min(12, $serBytes.Length))
    $entry[47] = [byte]$Parts
    $entry[48] = [byte]$Media
    $entry[53] = 0x08

    return , $entry
}

function Get-UlPartName {
    <# Nome do pedaço: ul.<CRC32 do nome>.<serial>.<NN>  (ex.: ul.7C39E2C0.SLUS_209.46.00) #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][int]$Part
    )
    return ('ul.{0:X8}.{1}.{2:x2}' -f (Get-UsbaCrc32 $Name), $Serial, $Part)
}

function Read-UlEntries {
    <# Lê o ul.cfg e devolve uma entrada por jogo. #>
    param([Parameter(Mandatory)][string]$Root)

    $cfg = Join-Path $Root 'ul.cfg'
    $list = @()
    if (-not (Test-Path -LiteralPath $cfg)) { return $list }

    $bytes = [IO.File]::ReadAllBytes($cfg)
    if ($bytes.Length % 64 -ne 0) {
        Write-Warning "ul.cfg tem $($bytes.Length) bytes (não é múltiplo de 64). O OPL pode ignorar parte do arquivo."
    }

    for ($o = 0; $o + 64 -le $bytes.Length; $o += 64) {
        $name = [Text.Encoding]::ASCII.GetString($bytes, $o, 32).TrimEnd([char]0, ' ')
        $ser = [Text.Encoding]::ASCII.GetString($bytes, $o + 35, 12).TrimEnd([char]0, ' ')
        $media = $bytes[$o + 48]
        $list += [pscustomobject]@{
            Nome   = $name
            Serial = $ser
            Partes = $bytes[$o + 47]
            Media  = if ($media -eq 0x14) { 'DVD' } elseif ($media -eq 0x12) { 'CD' } else { ('0x{0:X2}' -f $media) }
            Crc    = ('{0:X8}' -f (Get-UsbaCrc32 $name))
            Offset = $o
        }
    }
    return $list
}

function Format-Size {
    param([Parameter(Mandatory)][double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

function Get-IsoInfo {
    <#
        Lê o ISO9660 e o SYSTEM.CNF de dentro do ISO (sem montar a imagem).

        Devolve Serial, Boot, Ver, SystemId e quantidade de entradas na raiz.
        É assim que descobrimos o serial de verdade, em vez de "adivinhar"
        pelo nome do arquivo.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -lt 0x9000) { throw "Arquivo pequeno demais para ser um ISO de PS2." }

        $fs.Position = 0x8000
        $pvd = New-Object byte[] 2048
        [void]$fs.Read($pvd, 0, 2048)

        $type = $pvd[0]
        $id = [Text.Encoding]::ASCII.GetString($pvd, 1, 5)
        $sysId = [Text.Encoding]::ASCII.GetString($pvd, 8, 32).Trim()

        if ($id -ne 'CD001' -or $type -ne 1) {
            throw "Não é uma imagem ISO9660 válida (PVD '$id')."
        }

        # Registro do diretório raiz dentro do PVD (offset 156)
        $rootLba = [BitConverter]::ToUInt32($pvd, 158)
        $rootLen = [BitConverter]::ToUInt32($pvd, 166)

        $fs.Position = [int64]$rootLba * 2048
        $dir = New-Object byte[] $rootLen
        [void]$fs.Read($dir, 0, $rootLen)

        $files = @()
        $i = 0
        while ($i -lt $dir.Length) {
            $len = $dir[$i]
            if ($len -eq 0) {
                # fim do setor: pula pro próximo
                $i = [int]([math]::Floor($i / 2048) + 1) * 2048
                continue
            }
            $nameLen = $dir[$i + 32]
            $files += [pscustomobject]@{
                Name = [Text.Encoding]::ASCII.GetString($dir, $i + 33, $nameLen)
                Lba  = [BitConverter]::ToUInt32($dir, $i + 2)
                Size = [BitConverter]::ToUInt32($dir, $i + 10)
            }
            $i += $len
        }

        $serial = $null
        $ver = $null
        $scnf = $files | Where-Object { $_.Name -like 'SYSTEM.CNF*' } | Select-Object -First 1
        if ($scnf) {
            $fs.Position = [int64]$scnf.Lba * 2048
            $buf = New-Object byte[] ([Math]::Min(4096, [int]$scnf.Size))
            [void]$fs.Read($buf, 0, $buf.Length)
            $txt = [Text.Encoding]::ASCII.GetString($buf)

            $m = [regex]::Match($txt, 'BOOT2\s*=\s*cdrom0:\\?([^\r\n;]+)', 'IgnoreCase')
            if ($m.Success) { $serial = $m.Groups[1].Value.Trim().ToUpper() }

            $m = [regex]::Match($txt, 'VER\s*=\s*([^\r\n]+)', 'IgnoreCase')
            if ($m.Success) { $ver = $m.Groups[1].Value.Trim() }
        }

        return [pscustomobject]@{
            Path        = $Path
            Pvd         = $id
            SystemId    = $sysId
            RootEntries = $files.Count
            SystemCnf   = [bool]$scnf
            Serial      = $serial
            Ver         = $ver
            IsPs2       = ($sysId -eq 'PLAYSTATION' -and $serial)
            Size        = $fs.Length
        }
    } finally {
        $fs.Dispose()
    }
}

# ===========================================================================
#  Motor de instalação — usado pela CLI e pela GUI
#
#  Todas as funções abaixo aceitam:
#    -OnLog      { param($level, $message) }   level: info | ok | warn | error
#    -OnProgress { param($percent, $done, $total) }
#    -State      [hashtable] opcional, com a chave Cancel = $true para abortar
# ===========================================================================

function Write-UlLog {
    param([scriptblock]$OnLog, [string]$Level, [string]$Message)
    if ($OnLog) { & $OnLog $Level $Message }
}

function Test-UlCancel {
    param([hashtable]$State)
    if ($State -and $State.Cancel) { throw 'Operação cancelada pelo usuário.' }
}

function Update-UlCfg {
    <#
        Remove a entrada do serial (se existir) e anexa a nova.
        Devolve quantas entradas existiam antes.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][int]$Parts,
        [Parameter(Mandatory)][byte]$Media
    )

    $cfgPath = Join-Path $Root 'ul.cfg'
    $old = if (Test-Path -LiteralPath $cfgPath) { [IO.File]::ReadAllBytes($cfgPath) } else { New-Object byte[] 0 }
    $before = [int]($old.Length / 64)

    $keep = New-Object 'System.Collections.Generic.List[byte]'
    for ($o = 0; $o + 64 -le $old.Length; $o += 64) {
        $s = [Text.Encoding]::ASCII.GetString($old, $o + 35, 12).TrimEnd([char]0, ' ')
        if ($s -ne $Serial) {
            $keep.AddRange([byte[]]$old[$o..($o + 63)])
        } else {
            $oldName = [Text.Encoding]::ASCII.GetString($old, $o, 32).TrimEnd([char]0, ' ')
            if ($oldName -and $oldName -ne $Name) {
                # nome mudou -> o CRC muda -> os pedaços antigos ficam órfãos
                $oldCrc = '{0:X8}' -f (Get-UsbaCrc32 $oldName)
                Get-ChildItem $Root -Filter "ul.$oldCrc.$Serial.*" -File -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $entry = New-UlEntry -Name $Name -Serial $Serial -Parts $Parts -Media $Media
    $stream = [IO.File]::Open($cfgPath, 'Create', 'Write', 'None')
    try {
        if ($keep.Count -gt 0) { $stream.Write($keep.ToArray(), 0, $keep.Count) }
        $stream.Write($entry, 0, 64)
    } finally { $stream.Dispose() }

    return $before
}

function Install-UlGame {
    <#
        Instala um ISO no formato ul.* (pedaços de 1 GiB + entrada no ul.cfg).
        Devolve um objeto com o resultado. Em caso de erro, apaga o que gravou.
    #>
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][byte]$Media,
        [switch]$Force,
        [scriptblock]$OnLog,
        [scriptblock]$OnProgress,
        [hashtable]$State
    )

    $iso = Get-Item -LiteralPath $IsoPath
    $partSize = $script:UlPartSize
    $parts = [int][Math]::Ceiling($iso.Length / $partSize)
    if ($parts -lt 1) { throw 'ISO vazio.' }
    if ($parts -gt 255) { throw 'ISO grande demais para o formato ul.* (máximo 255 pedaços).' }

    $existing = @(Read-UlEntries $Root)
    $dup = $existing | Where-Object { $_.Serial -eq $Serial } | Select-Object -First 1
    if ($dup -and -not $Force) {
        throw "Já existe um jogo com o serial $Serial no ul.cfg ('$($dup.Nome)'). Use -Force para substituir."
    }

    $written = New-Object 'System.Collections.Generic.List[string]'
    $total = [double]$iso.Length
    $done = [double]0

    try {
        $src = [IO.File]::OpenRead($iso.FullName)
        try {
            $buffer = New-Object byte[] (8MB)
            for ($i = 0; $i -lt $parts; $i++) {
                Test-UlCancel $State

                $partPath = Join-Path $Root (Get-UlPartName $Name $Serial $i)
                $written.Add($partPath)

                $remaining = [long]$iso.Length - ([long]$i * [long]$partSize)
                $toWrite = [long][Math]::Min([long]$partSize, $remaining)

                $dst = [IO.File]::Open($partPath, 'Create', 'Write', 'None')
                try {
                    $left = $toWrite
                    while ($left -gt 0) {
                        Test-UlCancel $State
                        $chunk = [int][Math]::Min($buffer.Length, $left)
                        $read = $src.Read($buffer, 0, $chunk)
                        if ($read -le 0) { throw 'Fim inesperado do ISO durante a cópia.' }
                        $dst.Write($buffer, 0, $read)
                        $left -= $read
                        $done += $read
                        if ($OnProgress) {
                            $pct = [int][Math]::Min(100, [Math]::Floor(100 * $done / $total))
                            & $OnProgress $pct $done $total
                        }
                    }
                } finally { $dst.Dispose() }

                Write-UlLog $OnLog 'info' ("parte {0}/{1} gravada ({2})" -f ($i + 1), $parts, (Format-Size $toWrite))
            }
        } finally { $src.Dispose() }

        $totalWritten = ($written | ForEach-Object { (Get-Item -LiteralPath $_).Length } | Measure-Object -Sum).Sum
        if ($totalWritten -ne $iso.Length) {
            throw "Tamanho gravado ($totalWritten) diferente do ISO ($($iso.Length))."
        }

        $before = Update-UlCfg -Root $Root -Name $Name -Serial $Serial -Parts $parts -Media $Media
        if ($before -eq 0) { Write-UlLog $OnLog 'info' 'ul.cfg criado.' }

        if ($OnProgress) { & $OnProgress 100 $total $total }

        return [pscustomobject]@{
            Nome     = $Name
            Serial   = $Serial
            Partes   = $parts
            Media    = $Media
            Crc      = ('{0:X8}' -f (Get-UsbaCrc32 $Name))
            Bytes    = $iso.Length
            Arquivos = $written.ToArray()
        }
    }
    catch {
        foreach ($f in $written) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Install-DvdFolderGame {
    <#
        Copia o ISO inteiro para <Root>\DVD (só abaixo de 4 GB, limite do FAT32).
    #>
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [scriptblock]$OnLog,
        [scriptblock]$OnProgress,
        [hashtable]$State
    )

    $iso = Get-Item -LiteralPath $IsoPath
    $limit = 4GB - 1MB
    if ($iso.Length -ge $limit) {
        throw ("Esse ISO tem {0} e não cabe na pasta DVD: FAT32 não aceita arquivo de 4 GB ou mais. Use o formato ul.*." -f (Format-Size $iso.Length))
    }

    $destFolder = Join-Path $Root 'DVD'
    if (-not (Test-Path -LiteralPath $destFolder)) { New-Item -ItemType Directory -Path $destFolder | Out-Null }
    $dest = Join-Path $destFolder ($Name + '.iso')

    $total = [double]$iso.Length
    $done = [double]0
    $src = [IO.File]::OpenRead($iso.FullName)
    try {
        $dst = [IO.File]::Open($dest, 'Create', 'Write', 'None')
        try {
            $buffer = New-Object byte[] (8MB)
            while ($true) {
                Test-UlCancel $State
                $read = $src.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                $dst.Write($buffer, 0, $read)
                $done += $read
                if ($OnProgress) {
                    $pct = [int][Math]::Min(100, [Math]::Floor(100 * $done / $total))
                    & $OnProgress $pct $done $total
                }
            }
        } finally { $dst.Dispose() }
    } catch {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        throw
    } finally { $src.Dispose() }

    if ((Get-Item -LiteralPath $dest).Length -ne $iso.Length) {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        throw 'Cópia incompleta: o arquivo de destino não tem o mesmo tamanho do ISO.'
    }

    Write-UlLog $OnLog 'ok' "ISO copiado para $dest"
    if ($OnProgress) { & $OnProgress 100 $total $total }

    return [pscustomobject]@{
        Nome   = $Name
        Serial = $null
        Bytes  = $iso.Length
        Destino = $dest
    }
}

function Remove-UlGame {
    <#
        Apaga os pedaços de um jogo e remove a entrada do ul.cfg.
        Devolve os arquivos removidos.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Serial
    )

    $cfgPath = Join-Path $Root 'ul.cfg'
    if (-not (Test-Path -LiteralPath $cfgPath)) { throw 'ul.cfg não encontrado.' }

    $old = [IO.File]::ReadAllBytes($cfgPath)
    $keep = New-Object 'System.Collections.Generic.List[byte]'
    $removed = New-Object 'System.Collections.Generic.List[string]'
    $found = $false

    for ($o = 0; $o + 64 -le $old.Length; $o += 64) {
        $s = [Text.Encoding]::ASCII.GetString($old, $o + 35, 12).TrimEnd([char]0, ' ')
        if ($s -ne $Serial) {
            $keep.AddRange([byte[]]$old[$o..($o + 63)])
            continue
        }
        $found = $true
        $name = [Text.Encoding]::ASCII.GetString($old, $o, 32).TrimEnd([char]0, ' ')
        $crc = '{0:X8}' -f (Get-UsbaCrc32 $name)
        Get-ChildItem $Root -Filter "ul.$crc.$Serial.*" -File -ErrorAction SilentlyContinue | ForEach-Object {
            $removed.Add($_.FullName)
            Remove-Item -LiteralPath $_.FullName -Force
        }
    }

    if (-not $found) { throw "Serial $Serial não encontrado no ul.cfg." }

    [IO.File]::WriteAllBytes($cfgPath, $keep.ToArray())
    return $removed.ToArray()
}

function Export-UlToIso {
    <#
        Remonta os pedaços de um jogo em um .iso único (para PCSX2 ou backup).
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][string]$Destination,
        [scriptblock]$OnLog,
        [scriptblock]$OnProgress,
        [hashtable]$State
    )

    $entry = @(Read-UlEntries $Root) | Where-Object { $_.Serial -eq $Serial } | Select-Object -First 1
    if (-not $entry) { throw "Serial $Serial não encontrado no ul.cfg." }

    $base = Join-Path $Root ("ul.{0}.{1}" -f $entry.Crc, $Serial)
    $partFiles = @(0..([int]$entry.Partes - 1) | ForEach-Object { '{0}.{1:x2}' -f $base, $_ })
    $missing = @($partFiles | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing.Count -gt 0) {
        throw ("Faltam {0} pedaço(s): {1}" -f $missing.Count, (($missing | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))
    }

    $total = [double](($partFiles | ForEach-Object { (Get-Item -LiteralPath $_).Length } | Measure-Object -Sum).Sum)
    $done = [double]0

    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }

    $out = [IO.File]::Create($Destination)
    try {
        $buffer = New-Object byte[] (8MB)
        foreach ($part in $partFiles) {
            Test-UlCancel $State
            Write-UlLog $OnLog 'info' ("juntando {0}" -f (Split-Path $part -Leaf))
            $in = [IO.File]::OpenRead($part)
            try {
                while ($true) {
                    Test-UlCancel $State
                    $read = $in.Read($buffer, 0, $buffer.Length)
                    if ($read -le 0) { break }
                    $out.Write($buffer, 0, $read)
                    $done += $read
                    if ($OnProgress) {
                        $pct = [int][Math]::Min(100, [Math]::Floor(100 * $done / $total))
                        & $OnProgress $pct $done $total
                    }
                }
            } finally { $in.Dispose() }
        }
    } catch {
        $out.Dispose()
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw
    } finally { $out.Dispose() }

    if ((Get-Item -LiteralPath $Destination).Length -ne $total) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw 'ISO remontado com tamanho diferente da soma dos pedaços.'
    }

    if ($OnProgress) { & $OnProgress 100 $total $total }
    return [pscustomobject]@{ Nome = $entry.Nome; Destino = $Destination; Bytes = $total }
}

function Rename-UlGame {
    <#
        Renomeia um jogo no formato ul.*.

        O CRC faz parte do nome dos pedaços (ul.<CRC>.<SERIAL>.<NN>), então mudar o
        nome exige RENOMEAR cada pedaço e reescrever a entrada no ul.cfg. Fazemos os
        dois de forma atômica: qualquer falha no meio reverte os pedaços já renomeados.

        Devolve um objeto com o nome antigo, o novo e quantos pedaços mudaram.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][string]$NewName
    )

    $NewName = (ConvertTo-AsciiName $NewName).Trim()
    if (-not $NewName) { throw 'O nome não pode ficar vazio.' }
    if ($NewName.Length -gt 32) { $NewName = $NewName.Substring(0, 32) }

    $entry = @(Read-UlEntries $Root) | Where-Object { $_.Serial -eq $Serial } | Select-Object -First 1
    if (-not $entry) { throw "Serial $Serial não encontrado no ul.cfg." }
    if ($entry.Nome -eq $NewName) { throw 'O novo nome é igual ao atual.' }

    $oldCrc = $entry.Crc
    $newCrc = '{0:X8}' -f (Get-UsbaCrc32 $NewName)
    if ($oldCrc -eq $newCrc) { throw 'O novo nome gera o mesmo CRC; escolha outro nome.' }

    $media = if ($entry.Media -eq 'DVD') { [byte]0x14 } elseif ($entry.Media -eq 'CD') { [byte]0x12 } else { [byte]0x14 }
    $parts = [int]$entry.Partes

    $oldParts = @(Get-ChildItem $Root -Filter "ul.$oldCrc.$Serial.*" -File -ErrorAction SilentlyContinue |
        Sort-Object Name)
    if ($oldParts.Count -eq 0) { throw "Não encontrei os pedaços de $($entry.Nome) ($oldCrc)." }
    if ($oldParts.Count -ne $parts) {
        Write-Warning "ul.cfg diz $parts pedaço(s) mas existem $($oldParts.Count); usando o número real."
        $parts = $oldParts.Count
    }

    # Renomeia pedaço a pedaço guardando o mapa para poder reverter.
    $renamed = New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach ($f in $oldParts) {
            $suffix = $f.Name.Substring(("ul.$oldCrc.$Serial").Length)   # ".00", ".01"...
            $dest = Join-Path $Root ("ul.$newCrc.$Serial$suffix")
            if (Test-Path -LiteralPath $dest) { throw "Já existe $dest." }
            Move-Item -LiteralPath $f.FullName -Destination $dest
            $renamed.Add([pscustomobject]@{ From = $f.FullName; To = $dest })
        }
    } catch {
        foreach ($m in $renamed) {
            Move-Item -LiteralPath $m.To -Destination $m.From -ErrorAction SilentlyContinue
        }
        throw
    }

    # Reescreve o ul.cfg. Update-UlCfg apagaria os pedaços do CRC antigo (que já
    # renomeamos) — por isso ele é seguro aqui: não há mais nada com o CRC antigo.
    Update-UlCfg -Root $Root -Name $NewName -Serial $Serial -Parts $parts -Media $media | Out-Null

    return [pscustomobject]@{
        Antigo = $entry.Nome
        Novo   = $NewName
        Partes = $parts
        Crc    = $newCrc
    }
}

function Copy-UlGame {
    <#
        Copia um jogo (ul.* ou DVD\*.iso) para outra unidade, preservando o formato.
        Espelha os bytes sem remontar o ISO. Devolve os arquivos criados no destino.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestRoot,
        [Parameter(Mandatory)][string]$Serial,
        [scriptblock]$OnLog,
        [scriptblock]$OnProgress,
        [hashtable]$State
    )

    $entry = @(Read-UlEntries $SourceRoot) | Where-Object { $_.Serial -eq $Serial } | Select-Object -First 1
    if (-not $entry) { throw "Serial $Serial não encontrado no ul.cfg de $SourceRoot." }

    $destCfg = Join-Path $DestRoot 'ul.cfg'
    if (Test-Path -LiteralPath $destCfg) {
        $dup = @(Read-UlEntries $DestRoot) | Where-Object { $_.Serial -eq $Serial } | Select-Object -First 1
        if ($dup) { throw "O destino já tem '$($dup.Nome)' ($Serial). Remova-o antes de copiar." }
    }

    $parts = @(Get-ChildItem $SourceRoot -Filter "ul.$($entry.Crc).$Serial.*" -File -ErrorAction SilentlyContinue |
        Sort-Object Name)
    if ($parts.Count -eq 0) { throw "Não encontrei os pedaços de $($entry.Nome)." }

    $total = [double](($parts | Measure-Object Length -Sum).Sum)
    $done = [double]0
    $created = New-Object 'System.Collections.Generic.List[string]'
    $buffer = New-Object byte[] (8MB)

    try {
        foreach ($p in $parts) {
            Test-UlCancel $State
            $dest = Join-Path $DestRoot $p.Name
            $created.Add($dest)
            $src = [IO.File]::OpenRead($p.FullName)
            try {
                $dst = [IO.File]::Open($dest, 'Create', 'Write', 'None')
                try {
                    while ($true) {
                        Test-UlCancel $State
                        $read = $src.Read($buffer, 0, $buffer.Length)
                        if ($read -le 0) { break }
                        $dst.Write($buffer, 0, $read)
                        $done += $read
                        if ($OnProgress) {
                            $pct = [int][Math]::Min(100, [Math]::Floor(100 * $done / $total))
                            & $OnProgress $pct $done $total
                        }
                    }
                } finally { $dst.Dispose() }
            } finally { $src.Dispose() }
            Write-UlLog $OnLog 'info' ("copiado {0}" -f $p.Name)
        }

        $media = if ($entry.Media -eq 'CD') { [byte]0x12 } else { [byte]0x14 }
        Update-UlCfg -Root $DestRoot -Name $entry.Nome -Serial $Serial -Parts $parts.Count -Media $media | Out-Null
        if ($OnProgress) { & $OnProgress 100 $total $total }

        return [pscustomobject]@{ Nome = $entry.Nome; Serial = $Serial; Arquivos = $created.ToArray(); Bytes = $total }
    } catch {
        foreach ($f in $created) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        throw
    } finally { $buffer = $null }
}

function Copy-DvdGame {
    <#
        Copia um ISO inteiro da pasta DVD\ para a pasta DVD\ de outra unidade.
    #>
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][string]$DestRoot,
        [scriptblock]$OnLog,
        [scriptblock]$OnProgress,
        [hashtable]$State
    )

    $iso = Get-Item -LiteralPath $IsoPath
    $destFolder = Join-Path $DestRoot 'DVD'
    if (-not (Test-Path -LiteralPath $destFolder)) { New-Item -ItemType Directory -Path $destFolder | Out-Null }
    $dest = Join-Path $destFolder $iso.Name
    if (Test-Path -LiteralPath $dest) { throw "O destino já tem $($iso.Name)." }

    $total = [double]$iso.Length
    $done = [double]0
    $buffer = New-Object byte[] (8MB)
    try {
        $src = [IO.File]::OpenRead($iso.FullName)
        try {
            $dst = [IO.File]::Open($dest, 'Create', 'Write', 'None')
            try {
                while ($true) {
                    Test-UlCancel $State
                    $read = $src.Read($buffer, 0, $buffer.Length)
                    if ($read -le 0) { break }
                    $dst.Write($buffer, 0, $read)
                    $done += $read
                    if ($OnProgress) {
                        $pct = [int][Math]::Min(100, [Math]::Floor(100 * $done / $total))
                        & $OnProgress $pct $done $total
                    }
                }
            } finally { $dst.Dispose() }
        } finally { $src.Dispose() }
    } catch {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        throw
    } finally { $buffer = $null }

    if ((Get-Item -LiteralPath $dest).Length -ne $iso.Length) {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        throw 'Cópia incompleta: o destino não tem o mesmo tamanho da origem.'
    }
    if ($OnProgress) { & $OnProgress 100 $total $total }
    Write-UlLog $OnLog 'ok' "ISO copiado para $dest"
    return [pscustomobject]@{ Nome = $iso.BaseName; Destino = $dest; Bytes = $iso.Length }
}

function Move-UlGame {
    <# Move = copiar para o destino e só então apagar a origem (seguro contra falha). #>
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestRoot,
        [Parameter(Mandatory)][string]$Serial,
        [scriptblock]$OnLog,
        [scriptblock]$OnProgress,
        [hashtable]$State
    )

    $copy = Copy-UlGame -SourceRoot $SourceRoot -DestRoot $DestRoot -Serial $Serial `
        -OnLog $OnLog -OnProgress $OnProgress -State $State
    Remove-UlGame -Root $SourceRoot -Serial $Serial | Out-Null
    Write-UlLog $OnLog 'ok' "Removido da origem após mover: $($copy.Nome)"
    return $copy
}
