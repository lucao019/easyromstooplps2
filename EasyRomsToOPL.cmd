@echo off
rem ---------------------------------------------------------------------------
rem  EasyRomsToOPL - abre a interface grafica (sem janela de console)
rem ---------------------------------------------------------------------------
setlocal
set "LAUNCHER=%~dp0EasyRomsToOPL-Launcher.cmd"
set "GUI=%~dp0gui\EasyRomsToOPL.GUI.ps1"

rem Usar o launcher principal que escolhe o melhor método
if exist "%LAUNCHER%" (
    call "%LAUNCHER%" %*
    exit /b %ERRORLEVEL%
)

rem Método antigo (fallback)
if not exist "%GUI%" (
    echo Nao encontrei gui\EasyRomsToOPL.GUI.ps1
    echo Rode este arquivo de dentro da pasta do projeto.
    pause
    exit /b 1
)

start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%GUI%" %*
exit /b 0
