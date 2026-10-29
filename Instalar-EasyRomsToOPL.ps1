<#
.SYNOPSIS
    Instala o EasyRomsToOPL na pasta do usuário e cria os atalhos.

.DESCRIPTION
    Copia o programa para %LOCALAPPDATA%\EasyRomsToOPL e cria:
      - atalho na Área de Trabalho
      - atalho no Menu Iniciar (com o desinstalador ao lado)

    Não pede administrador, não escreve no registro e não instala nada além
    disso. Para remover: -Uninstall (ou o atalho "Desinstalar").

.PARAMETER Source
    Pasta com os arquivos do programa. Padrão: a pasta deste script.

.PARAMETER Target
    Onde instalar. Padrão: %LOCALAPPDATA%\EasyRomsToOPL

.PARAMETER DesktopPath
    Área de Trabalho onde criar o atalho. Padrão: a do usuário.
    Útil quando o Desktop é redirecionado (OneDrive) e você quer o atalho na
    pasta local.

.PARAMETER NoDesktop
    Não cria atalho na Área de Trabalho.

.PARAMETER NoStartMenu
    Não cria atalho no Menu Iniciar.

.PARAMETER Uninstall
    Remove o programa e os atalhos.

.PARAMETER Quiet
    Só imprime erros.

.EXAMPLE
    .\Instalar-EasyRomsToOPL.ps1

.EXAMPLE
    .\Instalar-EasyRomsToOPL.ps1 -DesktopPath "C:\Users\eu\Desktop"

.EXAMPLE
    .\Instalar-EasyRomsToOPL.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$Target,
    [string]$DesktopPath,
    [switch]$NoDesktop,
    [switch]$NoStartMenu,
    [switch]$Uninstall,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$AppName = 'EasyRomsToOPL'
if (-not $Target) { $Target = Join-Path $env:LOCALAPPDATA $AppName }

function Say {
    param([string]$Text, [string]$Color = 'Gray')
    if (-not $Quiet) { Write-Host $Text -ForegroundColor $Color }
}

function Get-ShortcutPaths {
    $desktop = if ($DesktopPath) { $DesktopPath } else { [Environment]::GetFolderPath('Desktop') }
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'

    $paths = New-Object System.Collections.ArrayList
    if (-not $NoDesktop -and $desktop) {
        [void]$paths.Add((Join-Path $desktop "$AppName.lnk"))
    }
    if (-not $NoStartMenu) {
        [void]$paths.Add((Join-Path $startMenu "$AppName\$AppName.lnk"))
        [void]$paths.Add((Join-Path $startMenu "$AppName\Desinstalar.lnk"))
    }
    return $paths
}

function Test-ShortcutPointsToTarget {
    <#
        Um atalho só deve ser apagado se apontar para a instalação que está
        sendo removida. Sem isso, desinstalar uma cópia de teste apagava o
        atalho (e o Menu Iniciar) da cópia real instalada em outro lugar.
    #>
    param([string]$Path, [string]$Root)

    if (-not $Root) { return $true }
    try {
        $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
        $probe = (@($lnk.TargetPath, $lnk.Arguments, $lnk.WorkingDirectory) | Where-Object { $_ }) -join ' '
        return $probe.IndexOf($Root.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -ge 0
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------- desinstalar

if ($Uninstall) {
    Set-Location $env:TEMP

    foreach ($lnk in (Get-ShortcutPaths)) {
        if (-not (Test-Path -LiteralPath $lnk)) { continue }

        if (Test-ShortcutPointsToTarget -Path $lnk -Root $Target) {
            Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
            Say "atalho removido: $lnk" 'DarkGray'
        } else {
            Say "atalho de outra instalação mantido: $lnk" 'DarkGray'
        }
    }

    $startFolder = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$AppName"
    if (Test-Path -LiteralPath $startFolder) {
        # Só apaga a pasta se ela ficou vazia (não mexe em atalhos de outra cópia).
        if (@(Get-ChildItem -LiteralPath $startFolder -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $startFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path -LiteralPath $Target) {
        Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $Target) {
        Say "Não consegui apagar tudo em $Target (arquivo em uso?). Feche o programa e tente de novo." 'Yellow'
        exit 1
    }

    Say ''
    Say '  EasyRomsToOPL desinstalado.' 'Green'
    Say ''
    exit 0
}

# ---------------------------------------------------------------- validar origem

if (-not $Source) { $Source = $PSScriptRoot }
if (-not $Source -or -not (Test-Path -LiteralPath $Source)) {
    Say "Pasta de origem não encontrada: $Source" 'Red'
    exit 1
}
$Source = (Resolve-Path -LiteralPath $Source).Path

foreach ($must in @('gui\EasyRomsToOPL.GUI.ps1', 'gui\MainWindow.xaml', 'lib\UlFormat.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Source $must))) {
        Say "Instalação incompleta: falta $must em $Source" 'Red'
        exit 1
    }
}

# ---------------------------------------------------------------- copiar

Say ''
Say '  EASYROMS::OPL  —  instalador' 'Cyan'
Say '  ----------------------------------------------------------' 'DarkGray'
Say "  origem : $Source" 'DarkGray'
Say "  destino: $Target" 'DarkGray'
Say ''

if (Test-Path -LiteralPath $Target) {
    Say '  Atualizando uma instalação existente...' 'Yellow'
    Set-Location $env:TEMP
    Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Force -Path $Target | Out-Null

$items = @('EasyRomsToOPL.ps1', 'EasyRomsToOPL.cmd', 'Instalar-EasyRomsToOPL.ps1', 'lib', 'gui', 'docs', 'README.md', 'CHANGELOG.md', 'LICENSE')
foreach ($item in $items) {
    $from = Join-Path $Source $item
    if (-not (Test-Path -LiteralPath $from)) { continue }
    Copy-Item -LiteralPath $from -Destination $Target -Recurse -Force
    Say "  + $item" 'DarkGray'
}

# desinstalador dentro da pasta instalada
$uninstallCmd = @'
@echo off
chcp 65001 >nul
title EasyRomsToOPL - desinstalar
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar-EasyRomsToOPL.ps1" -Uninstall
pause
'@
[IO.File]::WriteAllText((Join-Path $Target 'Desinstalar.cmd'), ($uninstallCmd -replace "`r?`n", "`r`n"), [Text.Encoding]::ASCII)

# ---------------------------------------------------------------- atalhos

$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$guiScript = Join-Path $Target 'gui\EasyRomsToOPL.GUI.ps1'
$iconPath = Join-Path $Target 'gui\EasyRomsToOPL.ico'
if (-not (Test-Path -LiteralPath $iconPath)) { $iconPath = "$powershellExe,0" }

$shell = New-Object -ComObject WScript.Shell

function New-AppShortcut {
    param([string]$Path, [string]$Label)

    $folder = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
    }

    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath = $powershellExe
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$guiScript`""
    $lnk.WorkingDirectory = $Target
    $lnk.IconLocation = $iconPath
    $lnk.Description = 'EasyRomsToOPL - jogos de PS2 no pendrive do OPL'
    $lnk.WindowStyle = 1
    $lnk.Save()
    Say "  atalho: $Label -> $Path" 'DarkGray'
}

if (-not $NoDesktop) {
    $desktop = if ($DesktopPath) { $DesktopPath } else { [Environment]::GetFolderPath('Desktop') }
    if ($desktop -and (Test-Path -LiteralPath $desktop)) {
        New-AppShortcut -Path (Join-Path $desktop "$AppName.lnk") -Label 'Área de Trabalho'
    } else {
        Say "  (área de trabalho não encontrada: $desktop)" 'Yellow'
    }
}

if (-not $NoStartMenu) {
    $startFolder = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$AppName"
    New-AppShortcut -Path (Join-Path $startFolder "$AppName.lnk") -Label 'Menu Iniciar'

    $un = $shell.CreateShortcut((Join-Path $startFolder 'Desinstalar.lnk'))
    $un.TargetPath = Join-Path $Target 'Desinstalar.cmd'
    $un.WorkingDirectory = $Target
    $un.IconLocation = $iconPath
    $un.Description = 'Remover o EasyRomsToOPL deste computador'
    $un.Save()
}

[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)

# ---------------------------------------------------------------- pronto

Say ''
Say '  Pronto. Abra pelo atalho "EasyRomsToOPL" ou por:' 'Green'
Say "    $Target\EasyRomsToOPL.cmd" 'DarkGray'
Say ''
Say '  Para remover depois: Menu Iniciar > EasyRomsToOPL > Desinstalar' 'DarkGray'
Say '  (nada foi instalado fora da pasta acima e dos atalhos)' 'DarkGray'
Say ''
exit 0
