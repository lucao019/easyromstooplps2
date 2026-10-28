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
