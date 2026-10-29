<#
.SYNOPSIS
    Gera os sons da interface em gui\sounds (WAV 16-bit mono, 22 kHz).

.DESCRIPTION
    Tudo é sintetizado aqui, com senoides e ruído filtrado: nenhum áudio de
    console ou de terceiros é usado. Os tons seguem o espírito do PS2 (um
    acorde grave que abre, bipes curtos e secos), mas são composições próprias.

    Rodar de novo só quando quiser mudar o timbre: os .wav vão versionados.

.EXAMPLE
    .\tools\New-Sounds.ps1
#>
[CmdletBinding()]
param(
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $repo 'gui\sounds' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$Rate = 22050

function New-Buffer {
    param([double]$Seconds)
    return , (New-Object double[] ([int]($Seconds * $Rate)))
}

function Add-Tone {
    param(
        [double[]]$Buf,
        [double]$Freq,
        [double]$Start,
        [double]$Dur,
        [double]$Amp = 0.2,
        [double]$Attack = 0.005,
        [double]$Release = 0.05,
        [double]$Vibrato = 0,
        [double]$VibratoHz = 5
    )

    $i0 = [int]($Start * $Rate)
    $n = [int]($Dur * $Rate)
    for ($i = 0; $i -lt $n; $i++) {
        $idx = $i0 + $i
        if ($idx -ge $Buf.Length) { break }
        $t = $i / $Rate
        $env = 1.0
        if ($Attack -gt 0 -and $t -lt $Attack) { $env = $t / $Attack }
        $left = $Dur - $t
        if ($Release -gt 0 -and $left -lt $Release) { $env = [Math]::Min($env, $left / $Release) }
        $f = $Freq
        if ($Vibrato -gt 0) { $f *= (1 + $Vibrato * [Math]::Sin(2 * [Math]::PI * $VibratoHz * $t)) }
        $Buf[$idx] += $Amp * $env * [Math]::Sin(2 * [Math]::PI * $f * $t)
    }
}

function Add-Sweep {
    param(
        [double[]]$Buf,
        [double]$F0,
        [double]$F1,
        [double]$Start,
        [double]$Dur,
        [double]$Amp = 0.2,
        [double]$Attack = 0.004,
        [double]$Release = 0.03
    )

    $i0 = [int]($Start * $Rate)
    $n = [int]($Dur * $Rate)
    $phase = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        $idx = $i0 + $i
        if ($idx -ge $Buf.Length) { break }
        $t = $i / $Rate
        $p = $i / [double]$n
        $f = $F0 + ($F1 - $F0) * $p
        $phase += 2 * [Math]::PI * $f / $Rate
        $env = 1.0
        if ($Attack -gt 0 -and $t -lt $Attack) { $env = $t / $Attack }
        $left = $Dur - $t
        if ($Release -gt 0 -and $left -lt $Release) { $env = [Math]::Min($env, $left / $Release) }
        $Buf[$idx] += $Amp * $env * [Math]::Sin($phase)
    }
}

function Add-Noise {
    param(
        [double[]]$Buf,
        [double]$Start,
        [double]$Dur,
        [double]$Amp = 0.02,
        [double]$Attack = 0.2,
        [double]$Release = 0.3,
        [int]$Seed = 12345
    )

    $rnd = New-Object System.Random($Seed)
    $i0 = [int]($Start * $Rate)
    $n = [int]($Dur * $Rate)
    $lp = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        $idx = $i0 + $i
        if ($idx -ge $Buf.Length) { break }
        $t = $i / $Rate
        $env = 1.0
        if ($Attack -gt 0 -and $t -lt $Attack) { $env = $t / $Attack }
        $left = $Dur - $t
        if ($Release -gt 0 -and $left -lt $Release) { $env = [Math]::Min($env, $left / $Release) }
        $lp = $lp * 0.92 + ($rnd.NextDouble() * 2 - 1) * 0.08
        $Buf[$idx] += $Amp * $env * $lp
    }
}

function Write-Wav {
    param([string]$Path, [double[]]$Data)

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    try {
        $dataBytes = $Data.Length * 2
        $bw.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
        $bw.Write([int](36 + $dataBytes))
        $bw.Write([Text.Encoding]::ASCII.GetBytes('WAVE'))
        $bw.Write([Text.Encoding]::ASCII.GetBytes('fmt '))
        $bw.Write([int]16)
        $bw.Write([int16]1)          # PCM
        $bw.Write([int16]1)          # mono
        $bw.Write([int]$Rate)
        $bw.Write([int]($Rate * 2))  # bytes/s
        $bw.Write([int16]2)          # block align
        $bw.Write([int16]16)         # bits
        $bw.Write([Text.Encoding]::ASCII.GetBytes('data'))
        $bw.Write([int]$dataBytes)

        foreach ($s in $Data) {
            $v = [double]$s
            if ($v -gt 1.0) { $v = 1.0 }
            if ($v -lt -1.0) { $v = -1.0 }
            $bw.Write([int16][Math]::Round($v * 32767))
        }
        $bw.Flush()
        [IO.File]::WriteAllBytes($Path, $ms.ToArray())
    } finally {
        $bw.Dispose()
        $ms.Dispose()
    }
}

# ---------------------------------------------------------------- hover
# Um tique curtíssimo e discreto: passar o mouse em cima de uma opção.
$b = New-Buffer 0.045
Add-Tone $b 1800 0 0.045 0.055 0.002 0.03
Add-Tone $b 2700 0 0.035 0.025 0.002 0.02
Write-Wav (Join-Path $OutDir 'hover.wav') $b

# ---------------------------------------------------------------- click
$b = New-Buffer 0.085
Add-Sweep $b 980 1320 0 0.06 0.16 0.002 0.05
Add-Tone $b 1960 0.005 0.04 0.04 0.002 0.03
Write-Wav (Join-Path $OutDir 'click.wav') $b

# ---------------------------------------------------------------- boot
# Abertura: acorde grave que sobe com um brilho por cima (2,6 s).
$b = New-Buffer 2.6
Add-Noise $b 0 2.6 0.085 0.55 0.9
Add-Tone $b 110.00 0.00 2.60 0.150 0.55 1.00
Add-Tone $b 164.81 0.05 2.55 0.110 0.50 1.00
Add-Tone $b 220.00 0.10 2.50 0.095 0.45 0.95
Add-Tone $b 329.63 0.25 2.30 0.060 0.35 0.90 0.004 5
Add-Tone $b 659.25 0.95 1.55 0.035 0.25 0.80 0.006 6
Add-Tone $b 987.77 1.15 1.30 0.022 0.20 0.70 0.008 7
Write-Wav (Join-Path $OutDir 'boot.wav') $b

# ---------------------------------------------------------------- success
# Instalação concluída: três notas rápidas subindo.
$b = New-Buffer 0.65
Add-Tone $b 659.25 0.00 0.16 0.14 0.004 0.10
Add-Tone $b 783.99 0.12 0.16 0.14 0.004 0.10
Add-Tone $b 1046.50 0.24 0.38 0.16 0.004 0.22
Add-Tone $b 2093.00 0.24 0.30 0.03 0.004 0.20
Write-Wav (Join-Path $OutDir 'success.wav') $b

# ---------------------------------------------------------------- error
# Algo falhou: duas notas graves, curtas e secas.
$b = New-Buffer 0.42
Add-Tone $b 220.00 0.00 0.20 0.16 0.003 0.10
Add-Tone $b 440.00 0.00 0.20 0.05 0.003 0.10
Add-Tone $b 146.83 0.20 0.22 0.16 0.003 0.12
Add-Tone $b 293.66 0.20 0.22 0.05 0.003 0.12
Write-Wav (Join-Path $OutDir 'error.wav') $b

# ---------------------------------------------------------------- conectado
$b = New-Buffer 0.22
Add-Sweep $b 520 980 0 0.20 0.14 0.004 0.08
Add-Tone $b 1560 0.10 0.10 0.035 0.004 0.06
Write-Wav (Join-Path $OutDir 'connect.wav') $b

# ---------------------------------------------------------------- removido
$b = New-Buffer 0.22
Add-Sweep $b 980 520 0 0.20 0.14 0.004 0.08
Add-Tone $b 520 0.10 0.10 0.035 0.004 0.06
Write-Wav (Join-Path $OutDir 'disconnect.wav') $b

Write-Host ''
foreach ($f in Get-ChildItem $OutDir -Filter *.wav | Sort-Object Name) {
    Write-Host ('  {0,-16} {1,6} KB' -f $f.Name, [math]::Round($f.Length / 1KB, 1)) -ForegroundColor DarkGray
}
Write-Host ('sons gerados em {0}' -f $OutDir) -ForegroundColor Green
Write-Host ''
