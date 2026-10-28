<#
.SYNOPSIS
    Gera gui/EasyRomsToOPL.ico (ícone do atalho), nos tamanhos que o Windows usa.

.DESCRIPTION
    Desenha o ícone com as cores do terminal.css e monta um .ico multi-resolução.
    Rodar só quando quiser mudar o desenho; o .ico gerado fica versionado no repo.

.EXAMPLE
    .\tools\New-Icon.ps1
#>
[CmdletBinding()]
param(
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not $OutFile) {
    $OutFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'gui\EasyRomsToOPL.ico'
}

$sizes = @(16, 32, 48, 64, 128)

function New-Frame {
    param([int]$Size)

    $bmp = New-Object Drawing.Bitmap($Size, $Size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'AntiAliasGridFit'
        $g.Clear([Drawing.ColorTranslator]::FromHtml('#050505'))

        # borda ciano
        $pad = [Math]::Max(1, [int]($Size * 0.055))
        $pen = New-Object Drawing.Pen([Drawing.ColorTranslator]::FromHtml('#8BE9FD'), [Math]::Max(1, [single]($Size * 0.045)))
        $g.DrawRectangle($pen, $pad, $pad, $Size - 1 - (2 * $pad), $Size - 1 - (2 * $pad))
        $pen.Dispose()

        # "E" ciano + barra verde embaixo
        $fontSize = [single]($Size * 0.52)
        $font = New-Object Drawing.Font('Consolas', $fontSize, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
        $fmt = New-Object Drawing.StringFormat
        $fmt.Alignment = 'Center'
        $fmt.LineAlignment = 'Center'
        $rect = New-Object Drawing.RectangleF(0, [single](-$Size * 0.04), $Size, $Size)
        $brush = New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml('#8BE9FD'))
        $g.DrawString('E', $font, $brush, $rect, $fmt)

        $barH = [Math]::Max(1, [int]($Size * 0.055))
        $barW = [int]($Size * 0.42)
        $green = New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml('#50FA7B'))
        $g.FillRectangle($green, [int](($Size - $barW) / 2), [int]($Size * 0.74), $barW, $barH)

        $green.Dispose()
        $brush.Dispose()
        $font.Dispose()
        $fmt.Dispose()
    } finally {
        $g.Dispose()
    }
    return $bmp
}

function ConvertTo-IconDib {
    <#
        Frame de ícone no formato clássico (BITMAPINFOHEADER + BGRA + máscara AND).
        É o que o Windows desenha em qualquer versão; PNG só é aceito de fato no 256.
    #>
    param([Drawing.Bitmap]$Bitmap)

    $size = $Bitmap.Width
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($ms)

    $bw.Write([uint32]40)                 # biSize
    $bw.Write([int32]$size)               # biWidth
    $bw.Write([int32]($size * 2))         # biHeight (XOR + AND)
    $bw.Write([uint16]1)                  # biPlanes
    $bw.Write([uint16]32)                 # biBitCount
    $bw.Write([uint32]0)                  # biCompression (BI_RGB)
    $bw.Write([uint32]($size * $size * 4))
    $bw.Write([int32]0); $bw.Write([int32]0)
    $bw.Write([uint32]0); $bw.Write([uint32]0)

    for ($y = $size - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $size; $x++) {
            $c = $Bitmap.GetPixel($x, $y)
            $bw.Write([byte]$c.B); $bw.Write([byte]$c.G); $bw.Write([byte]$c.R); $bw.Write([byte]$c.A)
        }
    }

    # máscara AND: 1 bit por pixel, linhas alinhadas em 4 bytes (tudo 0 = opaco)
    $maskRow = [int][Math]::Ceiling($size / 32.0) * 4
    $zero = New-Object byte[] $maskRow
    for ($y = 0; $y -lt $size; $y++) { $bw.Write($zero) }

    $bw.Flush()
    $bytes = $ms.ToArray()
    $bw.Dispose(); $ms.Dispose()
    return $bytes
}

$frames = @()
foreach ($s in $sizes) {
    $bmp = New-Frame -Size $s
    $frames += [pscustomobject]@{ Size = $s; Bytes = [byte[]](ConvertTo-IconDib $bmp) }
    $bmp.Dispose()
}

# 256 em PNG: é o formato que o Explorer espera para ícones grandes
$big = New-Frame -Size 256
$ms = New-Object IO.MemoryStream
$big.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
$frames += [pscustomobject]@{ Size = 256; Bytes = [byte[]]$ms.ToArray() }
$ms.Dispose()
$big.Dispose()

$out = New-Object IO.MemoryStream
$bw = New-Object IO.BinaryWriter($out)

$bw.Write([uint16]0)            # reservado
$bw.Write([uint16]1)            # tipo: ícone
$bw.Write([uint16]$frames.Count)

$offset = 6 + (16 * $frames.Count)
foreach ($f in $frames) {
    $bw.Write([byte]$(if ($f.Size -ge 256) { 0 } else { $f.Size }))
    $bw.Write([byte]$(if ($f.Size -ge 256) { 0 } else { $f.Size }))
    $bw.Write([byte]0)          # cores da paleta
    $bw.Write([byte]0)          # reservado
    $bw.Write([uint16]1)        # planos
    $bw.Write([uint16]32)       # bits por pixel
    $bw.Write([uint32]$f.Bytes.Length)
    $bw.Write([uint32]$offset)
    $offset += $f.Bytes.Length
}
foreach ($f in $frames) { $bw.Write([byte[]]$f.Bytes) }

$bw.Flush()
[IO.File]::WriteAllBytes($OutFile, $out.ToArray())
$bw.Dispose()
$out.Dispose()

$check = New-Object Drawing.Icon($OutFile)
Write-Host ("ícone gravado: {0} ({1} bytes) — carregado como {2}x{3}" -f $OutFile, (Get-Item $OutFile).Length, $check.Width, $check.Height) -ForegroundColor Green
$check.Dispose()
