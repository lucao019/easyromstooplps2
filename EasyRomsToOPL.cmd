@echo off
rem ---------------------------------------------------------------------------
rem  EasyRomsToOPL - abre a interface grafica (sem janela de console)
rem ---------------------------------------------------------------------------
setlocal
set "GUI=%~dp0gui\EasyRomsToOPL.GUI.ps1"

if not exist "%GUI%" (
    echo Nao encontrei gui\EasyRomsToOPL.GUI.ps1
    echo Rode este arquivo de dentro da pasta do projeto.
    pause
    exit /b 1
)

start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%GUI%"
exit /b 0
