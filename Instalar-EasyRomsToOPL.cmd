@echo off
rem ---------------------------------------------------------------------------
rem  EasyRomsToOPL - instalador (duplo clique)
rem  Instala em %LOCALAPPDATA%\EasyRomsToOPL e cria os atalhos.
rem  Argumentos extras sao repassados, ex.: /? ou -Uninstall
rem ---------------------------------------------------------------------------
setlocal
chcp 65001 >nul
title EasyRomsToOPL - instalador

if not exist "%~dp0Instalar-EasyRomsToOPL.ps1" (
    echo.
    echo  Nao encontrei Instalar-EasyRomsToOPL.ps1 nesta pasta.
    echo  Rode este arquivo de dentro da pasta do projeto.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar-EasyRomsToOPL.ps1" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo  A instalacao falhou ^(codigo %RC%^).
    echo.
    pause
)

exit /b %RC%
