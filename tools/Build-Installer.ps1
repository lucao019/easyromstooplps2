<#
.SYNOPSIS
    Gera dist\Instalar-EasyRomsToOPL.cmd — instalador de arquivo único.

.DESCRIPTION
    Empacota o programa em um zip, converte para base64 e escreve um .cmd que se
    auto-extrai em %TEMP% e chama o Instalar-EasyRomsToOPL.ps1 de dentro do pacote.

    O .cmd gerado é ASCII puro e não precisa de nada além do PowerShell que já
    existe no Windows: dá para copiar um único arquivo para qualquer PC.

.EXAMPLE
    .\tools\Build-Installer.ps1
#>
[CmdletBinding()]
param(
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repo = Split-Path -Parent $PSScriptRoot
if (-not $OutFile) { $OutFile = Join-Path $repo 'dist\Instalar-EasyRomsToOPL.cmd' }

$version = '1.2.0'
$changelog = Join-Path $repo 'CHANGELOG.md'
if (Test-Path -LiteralPath $changelog) {
    $m = [regex]::Match((Get-Content -LiteralPath $changelog -Raw -Encoding UTF8), '##\s*\[(\d+\.\d+\.\d+)\]')
    if ($m.Success) { $version = $m.Groups[1].Value }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('er2opl-build-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$stage = Join-Path $work 'app'
New-Item -ItemType Directory -Force -Path $stage | Out-Null

try {
    $items = @(
        'EasyRomsToOPL.ps1'
        'EasyRomsToOPL.cmd'
        'Instalar-EasyRomsToOPL.ps1'
        'lib'
        'gui'
        'docs'
        'README.md'
        'CHANGELOG.md'
        'LICENSE'
    )

    $copied = 0
    foreach ($item in $items) {
        $from = Join-Path $repo $item
        if (-not (Test-Path -LiteralPath $from)) { throw "falta $item no repositório" }
        Copy-Item -LiteralPath $from -Destination $stage -Recurse -Force
        $copied++
    }

    $zip = Join-Path $work 'app.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)

    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zip))
    $lines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $b64.Length; $i += 76) {
        $lines.Add('::B64:' + $b64.Substring($i, [Math]::Min(76, $b64.Length - $i)))
    }

    $header = @"
@echo off
rem ===========================================================================
rem  EasyRomsToOPL $version - instalador de arquivo unico
rem  Gerado por tools\Build-Installer.ps1 - nao edite a mao.
rem
rem  Instala em %LOCALAPPDATA%\EasyRomsToOPL e cria os atalhos.
rem  Nao pede administrador. Para desinstalar: Menu Iniciar > EasyRomsToOPL.
rem ===========================================================================
setlocal EnableExtensions
chcp 65001 >nul
title EasyRomsToOPL - instalador

echo.
echo   EASYROMS::OPL $version
echo   ----------------------------------------------------------
echo   Extraindo os arquivos...
echo.

set "WORK=%TEMP%\er2opl-setup-%RANDOM%%RANDOM%"
mkdir "%WORK%" 2>nul

powershell -NoProfile -ExecutionPolicy Bypass -Command "`$ErrorActionPreference='Stop'; `$me='%~f0'; `$zip=Join-Path '%WORK%' 'app.zip'; `$b64=(Get-Content -LiteralPath `$me | Where-Object { `$_.StartsWith('::B64:') } | ForEach-Object { `$_.Substring(6) }) -join ''; [IO.File]::WriteAllBytes(`$zip,[Convert]::FromBase64String(`$b64)); Expand-Archive -LiteralPath `$zip -DestinationPath (Join-Path '%WORK%' 'app') -Force"
if errorlevel 1 goto :erro

powershell -NoProfile -ExecutionPolicy Bypass -File "%WORK%\app\Instalar-EasyRomsToOPL.ps1" -Source "%WORK%\app" %*
set "RC=%ERRORLEVEL%"

rd /s /q "%WORK%" 2>nul

if not "%RC%"=="0" goto :erro
if "%~1"=="" pause
exit /b 0

:erro
echo.
echo   A instalacao falhou. Nada foi alterado.
echo.
if "%~1"=="" pause
exit /b 1

"@

    # CRLF em tudo: o cmd.exe depende disso, inclusive quando o arquivo é baixado
    $out = (($header + ($lines -join "`n")) -split "`r?`n") -join "`r`n"
    $out = $out.TrimEnd() + "`r`n"
    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    # ASCII puro: o cmd não tem codepage garantida
    [IO.File]::WriteAllText($OutFile, $out, [Text.Encoding]::ASCII)

    Write-Host ''
    Write-Host ("instalador: {0}" -f $OutFile) -ForegroundColor Green
    Write-Host ("versao    : {0}" -f $version) -ForegroundColor DarkGray
    Write-Host ("tamanho   : {0} KB ({1} arquivos, zip {2} KB)" -f
        [math]::Round((Get-Item $OutFile).Length / 1KB), $copied,
        [math]::Round((Get-Item $zip).Length / 1KB)) -ForegroundColor DarkGray
    Write-Host ''
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
