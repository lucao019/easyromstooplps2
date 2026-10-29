<#
.SYNOPSIS
    Testa a interface clicando em TODOS os controles.

.DESCRIPTION
    Abre a janela de verdade (WPF), clica em cada chip de unidade, cada modo,
    cada botão, cada ✕, abre e fecha as confirmações, instala e remove em uma
    unidade virtual (subst), e falha se qualquer handler lançar exceção.

    É o teste que pega o tipo de bug que não aparece em teste de unidade:
    handler com variável errada, controle nulo, propriedade inexistente.

    A janela não fica aberta: o teste fecha no final.

.PARAMETER IsoPath
    ISO de PS2 real. Padrão: procura em E:\emulador PS2\games.

.PARAMETER SkipDrives
    Letras de unidade que o teste não clica (discos com erro de I/O conhecido).
    Padrão: D

.EXAMPLE
    .\tests\Test-GuiUi.ps1

.EXAMPLE
    .\tests\Test-GuiUi.ps1 -IsoPath "E:\jogos\Okami.iso" -SkipDrives "D,E"
#>
[CmdletBinding()]
param(
    [string]$IsoPath,
    [string]$SkipDrives = 'D'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# WPF exige STA; se não estiver, reinicia o script em STA.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $PSCommandPath)
    if ($IsoPath) { $argv += @('-IsoPath', $IsoPath) }
    if ($SkipDrives) { $argv += @('-SkipDrives', $SkipDrives) }
    & powershell.exe @argv
    exit $LASTEXITCODE
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib\UlFormat.ps1')

# ---------------------------------------------------------------- ISO de teste

if (-not $IsoPath) {
    $candidates = @(
        'E:\emulador PS2\games\Medalha de Honra (SLUS_215.97).iso',
        'E:\emulador PS2\games\Crash Twinsanity (USA).iso'
    )
    $IsoPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $IsoPath -or -not (Test-Path -LiteralPath $IsoPath)) {
    Write-Host 'Nenhum ISO de teste encontrado. Use -IsoPath.' -ForegroundColor Yellow
    exit 2
}
$isoFile = Get-Item -LiteralPath $IsoPath
$isoInfo = Get-IsoInfo $isoFile.FullName

# ---------------------------------------------------------------- unidade virtual

function Get-FreeLetter {
    $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1) })
    foreach ($l in 'X', 'Y', 'Z', 'W', 'V', 'U') {
        if ($used -notcontains $l) { return $l }
    }
    throw 'Nenhuma letra livre para a unidade de teste.'
}

$letter = Get-FreeLetter
$work = Join-Path ([IO.Path]::GetTempPath()) ('er2opl-ui-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
& cmd /c subst "${letter}:" "$work" | Out-Null
if (-not (Test-Path "${letter}:\")) { throw "subst ${letter}: falhou" }

# ---------------------------------------------------------------- placar

$script:Passed = 0
$script:Failed = 0
$script:UiErrors = New-Object System.Collections.ArrayList
$script:Covered = @{}

function Assert-Equal {
    param($Expected, $Actual, [string]$Label)
    if ("$Expected" -eq "$Actual") {
        $script:Passed++
        Write-Host "  [PASS] $Label" -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host "  [FAIL] $Label" -ForegroundColor Red
        Write-Host "         esperado: $Expected" -ForegroundColor DarkGray
        Write-Host "         obtido  : $Actual" -ForegroundColor DarkGray
    }
}

function Assert-True {
    param($Condition, [string]$Label)
    Assert-Equal $true ([bool]$Condition) $Label
}

# ---------------------------------------------------------------- carregar a GUI

$gui = Join-Path $repoRoot 'gui\EasyRomsToOPL.GUI.ps1'
$code = [IO.File]::ReadAllText($gui, [Text.Encoding]::UTF8)

# sem o bloco param (não vale dentro de Invoke-Expression) e sem o ShowDialog final
$code = [regex]::Replace($code, '(?s)\[CmdletBinding\(\)\]\s*param\(.*?\[string\]\$Drive\s*\)\s*', '')
$code = $code.Replace('[void]$win.ShowDialog()', '')
$code = $code.Replace('$PSScriptRoot', "'" + (Join-Path $repoRoot 'gui') + "'")

$env:EASYROMS_SNAPSHOT = ''

try {
    Invoke-Expression $code

    # qualquer exceção de handler cai aqui
    $win.Dispatcher.Add_UnhandledException({
        param($sender, $e)
        [void]$script:UiErrors.Add($e.Exception.GetBaseException())
    })

    $win.Show()

    function Pump {
        param([int]$Ms = 60)
        $frame = New-Object Windows.Threading.DispatcherFrame
        $timer = New-Object Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds($Ms)
        $timer.Add_Tick({ $timer.Stop(); $frame.Continue = $false })
        $timer.Start()
        [Windows.Threading.Dispatcher]::PushFrame($frame)
    }

    function Click {
        param($Element, [string]$Label)

        if (-not $Element) { throw "elemento nulo ao clicar em '$Label'" }

        if ($Element -is [Windows.Controls.Primitives.ButtonBase]) {
            $Element.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        } else {
            $m = New-Object Windows.Input.MouseButtonEventArgs([Windows.Input.Mouse]::PrimaryDevice, 0, [Windows.Input.MouseButton]::Left)
            $m.RoutedEvent = [Windows.UIElement]::MouseLeftButtonUpEvent
            $Element.RaiseEvent($m)
        }

        $script:Covered[$Label] = $true
        Pump 90
    }

    function Wait-Idle {
        $deadline = (Get-Date).AddMinutes(6)
        while (($S.Busy -or $S.Extract -or $S.ExtractQueue.Count -gt 0) -and (Get-Date) -lt $deadline) { Pump 100 }
    }

    function Get-LogText {
        (New-Object Windows.Documents.TextRange($ui.LogBox.Document.ContentStart, $ui.LogBox.Document.ContentEnd)).Text
    }

    Pump 200

    # ============================================================ 1. boot
    Write-Host ''
    Write-Host '1. Estado inicial' -ForegroundColor Cyan

    Assert-True ($null -ne $win) 'janela carregou'
    Assert-True ($S.Drives.Count -gt 0) "unidades detectadas ($($S.Drives.Count))"
    Assert-Equal $S.Drives.Count $ui.DrivesPanel.Children.Count 'um chip por unidade'
    Assert-True ($S.Drive -eq 'F' -or $S.Drive -eq $letter -or $S.Drive) "unidade selecionada ($($S.Drive):)"
    Assert-Equal 0 $S.Files.Count 'nenhum arquivo no início'
    Assert-True ([string]$ui.DeviceName.Text -match ('^{0}: ' -f $S.Drive)) "painel nomeia o dispositivo ($($ui.DeviceName.Text))"
    Assert-True ([string]$ui.DeviceName.Text -match 'PENDRIVE|CARTÃO|SSD|HD|DISCO|UNIDADE') 'painel diz o tipo (pendrive, SSD, HD...)'
    Assert-True ([string]$ui.StatSpace.Text -match '^USADO .+ DE .+ · LIVRE .+$') "painel mostra usado/livre ($($ui.StatSpace.Text))"
    Assert-True ($ui.BarPct.Text -match '^\d+%$') 'painel mostra a porcentagem usada'
    Assert-True ([bool]$ui.BtnAuto.IsChecked) 'auto-instalar ligado por padrão'
    Assert-True $S.AutoInstall 'estado do auto-instalar acompanha o botão'
    Assert-Equal 'Collapsed' ([string]$ui.LogBody.Visibility) 'log começa fechado'
    Assert-Equal 'ABRIR ▾' $ui.BtnLogToggle.Text 'log começa com ABRIR'

    # ============================================================ 2. chips de unidade
    Write-Host ''
    Write-Host '2. Chips de unidade (o clique que fechava o app)' -ForegroundColor Cyan

    $chips = @($ui.DrivesPanel.Children | Where-Object { $_ -is [Windows.Controls.Primitives.ToggleButton] })
    Assert-True ($chips.Count -gt 0) 'há chips clicáveis'

    $skip = @($SkipDrives.Split(',') | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })
    $tested = 0
    foreach ($chip in $chips) {
        $tag = [string]$chip.Tag
        if ($skip -contains $tag) {
            Write-Host "  [SKIP] unidade $tag (disco com erro de I/O — evita travar o teste)" -ForegroundColor DarkYellow
            continue
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Click $chip "chip-$tag"
        $sw.Stop()
        $tested++
        Assert-Equal $tag $S.Drive "clique no chip $tag seleciona $tag ($([int]$sw.Elapsed.TotalMilliseconds) ms)"
        Assert-True ($chip.IsChecked -or ($S.Drive -eq $tag)) "chip $tag ficou marcado"
        Assert-True ([string]$ui.DeviceName.Text -match ('^{0}: ' -f $tag)) "painel acompanha o chip $tag"
    }
    Assert-True ($tested -ge 2) "cliquei em $tested unidades"
    Assert-Equal 'library' $S.LibView 'clique na unidade abre a biblioteca'

    # ============================================================ 3. painel do dispositivo
    Write-Host ''
    Write-Host '3. Painel do dispositivo (tipo, usado, livre) em tempo real' -ForegroundColor Cyan

    $S.Drive = $letter
    Update-DriveChips
    Update-Space
    Assert-True ([string]$ui.DeviceName.Text -match ('^{0}: ' -f $letter)) "painel nomeia ${letter}: ($($ui.DeviceName.Text))"
    Assert-True ([string]$ui.StatSpace.Text -match '^USADO ') 'painel mostra o espaço usado'

    # espaço muda sem clicar em nada: o timer de 1 s relê a unidade
    $spaceBefore = [string]$ui.StatSpace.Text
    [IO.File]::WriteAllBytes("${letter}:\espaco-teste.bin", (New-Object byte[] (16MB)))
    $deadline = (Get-Date).AddSeconds(10)
    while ([string]$ui.StatSpace.Text -eq $spaceBefore -and (Get-Date) -lt $deadline) { Pump 250 }
    Assert-True ([string]$ui.StatSpace.Text -ne $spaceBefore) 'usado/livre mudou sozinho (tempo real)'
    Remove-Item -LiteralPath "${letter}:\espaco-teste.bin" -Force
    Pump 1300

    # auto-instalar e log: dois controles novos, um clique em cada.
    # O clique do teste levanta o evento direto, sem passar pelo ToggleButton,
    # então o IsChecked é alternado à mão antes do clique (como o WPF faria).
    $ui.BtnAuto.IsChecked = $false
    Click $ui.BtnAuto 'BtnAuto (desliga)'
    Assert-True (-not $S.AutoInstall) 'auto-instalar desliga'
    $ui.BtnAuto.IsChecked = $true
    Click $ui.BtnAuto 'BtnAuto (liga)'
    Assert-True $S.AutoInstall 'auto-instalar liga'

    Click $ui.BtnLogToggle 'BtnLogToggle (abre)'
    Assert-Equal 'Visible' ([string]$ui.LogBody.Visibility) 'log abre'
    Assert-Equal 'FECHAR ▴' $ui.BtnLogToggle.Text 'texto muda para FECHAR'
    Click $ui.BtnLogToggle 'BtnLogToggle (fecha)'
    Assert-Equal 'Collapsed' ([string]$ui.LogBody.Visibility) 'log fecha'

    # ============================================================ 4. botões sem arquivo
    Write-Host ''
    Write-Host '4. INSTALAR sem arquivo (tem que avisar, não quebrar)' -ForegroundColor Cyan

    # Trava de segurança: a partir daqui nunca deixamos a unidade apontar para
    # um disco real. Se algo falhar, o teste morre em vez de gravar no pendrive.
    $S.Drive = $letter
    if ($S.Drive -ne $letter) { throw "não consegui fixar a unidade de teste ${letter}:" }

    # Fluxo manual daqui até a seção 13: desliga o auto-instalar para o hot-plug
    # da seção 12 não começar a copiar sozinho em outra unidade.
    $ui.BtnAuto.IsChecked = $false
    $S.AutoInstall = $false

    Click $ui.BtnInstall 'BtnInstall'
    Assert-Equal 'Collapsed' $ui.Overlay.Visibility 'INSTALAR sem arquivo não abre confirmação'
    Assert-True ($ui.Toasts.Children.Count -gt 0) 'INSTALAR sem arquivo mostra aviso'
    Assert-True (-not $S.Busy) 'nada ficou travado como ocupado'

    # o ✕ do aviso fecha só aquele aviso
    $toastCount = $ui.Toasts.Children.Count
    Assert-True ($toastCount -gt 0) 'há avisos na tela'
    $lastToast = $ui.Toasts.Children[$toastCount - 1]
    $toastX = $lastToast.Child.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] -and $_.Text -eq '✕' } | Select-Object -First 1
    Assert-True ($null -ne $toastX) 'o aviso tem ✕'
    Click $toastX 'toast-remove'
    Assert-Equal ($toastCount - 1) $ui.Toasts.Children.Count '✕ fecha o aviso'

    # ============================================================ 5. entrada de arquivos
    Write-Host ''
    Write-Host '5. Entrada de arquivos (drop, duplicado, inválido, inexistente)' -ForegroundColor Cyan

    Add-DroppedFiles -Files @($isoFile.FullName)
    Assert-Equal 1 $S.Files.Count 'drop adiciona o ISO'
    Assert-True $S.Files[0].Valid 'ISO reconhecido como PS2'
    Assert-Equal $isoInfo.Serial $S.Files[0].Serial 'serial lido'
    Assert-Equal 'Medalha de Honra' $ui.NameBox.Text 'nome no menu sem o serial'
    Assert-Equal 1 $ui.FilesPanel.Children.Count 'linha na lista de arquivos'

    Add-DroppedFiles -Files @($isoFile.FullName)
    Assert-Equal 1 $S.Files.Count 'mesmo ISO não duplica'

    $txt = Join-Path $work 'leiame.txt'
    'nao sou um iso' | Set-Content -LiteralPath $txt -Encoding ASCII
    Add-DroppedFiles -Files @($txt)
    Assert-Equal 1 $S.Files.Count 'arquivo que não é .iso é ignorado'

    Add-DroppedFiles -Files @((Join-Path $work 'nao-existe.iso'))
    Assert-Equal 1 $S.Files.Count 'caminho inexistente não entra na lista'

    Add-DroppedFiles -Files @($null, '', $isoFile.FullName)
    Assert-Equal 1 $S.Files.Count 'entradas nulas/vazias não quebram'

    # ============================================================ 6. limpar lista
    Write-Host ''
    Write-Host '6. Limpar lista' -ForegroundColor Cyan

    Click $ui.BtnClearFiles 'BtnClearFiles'
    Assert-Equal 0 $S.Files.Count 'LIMPAR LISTA esvazia'
    Assert-Equal '' $ui.NameBox.Text 'LIMPAR LISTA limpa o nome'
    Assert-Equal 0 $ui.FilesPanel.Children.Count 'lista visual vazia'

    Add-DroppedFiles -Files @($isoFile.FullName)
    Assert-Equal 1 $S.Files.Count 'volta a aceitar o ISO'
    Assert-True ((Get-LogText) -match 'Medalha') 'log registra o ISO lido'
    Assert-Equal 0 @(Get-ChildItem "${letter}:\ul.*" -File).Count 'nada foi gravado ainda'

    # ============================================================ 7. instalar de verdade
    Write-Host ''
    Write-Host '7. Instalar na unidade virtual' -ForegroundColor Cyan

    $virtualChip = $ui.DrivesPanel.Children | Where-Object { $_ -is [Windows.Controls.Primitives.ToggleButton] -and [string]$_.Tag -eq $letter }
    Assert-True ($null -ne $virtualChip) "existe chip para ${letter}:"
    Click $virtualChip "chip-$letter"
    Assert-Equal $letter $S.Drive "unidade de teste selecionada"
    if ($S.Drive -ne $letter) { throw "ABORTADO: a unidade não é a virtual (${letter}:) — não vou gravar em disco real" }

    $ui.NameBox.Text = 'Jogo de Teste'
    Click $ui.BtnInstall 'BtnInstall'
    Assert-True $S.Busy 'INSTALAR começou (busy)'
    Assert-True ($ui.Overlay.Visibility -eq 'Collapsed') 'sem duplicado, não pergunta nada'

    # clicar de novo durante a cópia não pode abrir um segundo worker
    $handle = $S.Handle
    Click $ui.BtnInstall 'BtnInstall'
    Assert-Equal $handle $S.Handle 'clicar INSTALAR durante a cópia é ignorado'

    Wait-Idle
    Pump 300

    Assert-True (-not $S.Busy) 'instalação terminou'
    Assert-Equal 1 $S.Games.Count 'jogo aparece na lista'
    Assert-Equal 'Jogo de Teste' $S.Games[0].Nome 'nome na lista'
    $expectedParts = [int][Math]::Ceiling($isoFile.Length / 1GB)
    $parts = @(Get-ChildItem "${letter}:\ul.*" -File | Where-Object { $_.Name -ne 'ul.cfg' })
    Assert-Equal $expectedParts $parts.Count "pedaços gravados ($expectedParts esperado(s))"
    Assert-Equal 0 @($parts | Where-Object { $_.Length -le 0 }).Count 'nenhum pedaço vazio'
    Assert-Equal 64 (Get-Item "${letter}:\ul.cfg").Length 'ul.cfg com uma entrada'
    Assert-Equal 'CONCLUÍDO' $ui.BarText.Text 'barra diz CONCLUÍDO'
    Assert-Equal 100 $ui.Bar.Value 'barra em 100%'

    # ============================================================ 8. remover arquivo da lista
    Write-Host ''
    Write-Host '8. ✕ na lista de arquivos' -ForegroundColor Cyan

    $fileX = $ui.FilesPanel.Children[0].Child.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] -and $_.Text -eq '✕' }
    Assert-True ($null -ne $fileX) 'o ✕ do arquivo existe'
    Click $fileX 'file-remove'
    Assert-Equal 0 $S.Files.Count '✕ remove o arquivo da lista'
    Assert-Equal 0 $ui.FilesPanel.Children.Count 'linha sumiu da tela'

    # ============================================================ 9. remover jogo (cancelar / esc / confirmar)
    Write-Host ''
    Write-Host '9. ✕ no jogo: cancelar, ESC e confirmar' -ForegroundColor Cyan

    function Get-GameButton {
        param([string]$Content)
        foreach ($row in $ui.GamesPanel.Children) {
            if ($row.Child -isnot [Windows.Controls.Grid]) { continue }
            foreach ($child in $row.Child.Children) {
                if ($child -is [Windows.Controls.StackPanel]) {
                    $btn = $child.Children | Where-Object { $_ -is [Windows.Controls.Button] -and "$($_.Content)" -eq $Content } | Select-Object -First 1
                    if ($btn) { return $btn }
                }
            }
        }
        return $null
    }

    $xBtn = Get-GameButton '✕'
    Assert-True ($null -ne $xBtn) 'botão ✕ do jogo existe'
    Assert-True ($xBtn.Tag.Nome -eq 'Jogo de Teste') 'botão ✕ está ligado ao jogo certo'

    Click $xBtn 'game-remove'
    Assert-Equal 'Visible' $ui.Overlay.Visibility 'pede confirmação'

    Click $ui.BtnCancelConfirm 'BtnCancelConfirm'
    Assert-Equal 'Collapsed' $ui.Overlay.Visibility 'CANCELAR fecha'
    Assert-Equal 1 $S.Games.Count 'CANCELAR não apaga'

    Click $xBtn 'game-remove'
    Hide-ConfirmIfOpen
    Pump 50
    Assert-Equal 'Collapsed' $ui.Overlay.Visibility 'ESC fecha a confirmação'
    Assert-Equal 1 $S.Games.Count 'ESC não apaga'

    Click $xBtn 'game-remove'
    Click $ui.BtnYesConfirm 'BtnYesConfirm'
    Pump 300
    Assert-Equal 0 $S.Games.Count 'confirmar apaga o jogo'
    Assert-Equal 0 (Get-Item "${letter}:\ul.cfg").Length 'ul.cfg ficou vazio'
    Assert-Equal 0 @(Get-ChildItem "${letter}:\ul.*" -File | Where-Object { $_.Name -ne 'ul.cfg' }).Count 'pedaços apagados'

    # ============================================================ 10. exportar ISO
    Write-Host ''
    Write-Host '10. Botão ISO (exportar)' -ForegroundColor Cyan

    Add-DroppedFiles -Files @($isoFile.FullName)
    $ui.NameBox.Text = 'Jogo de Teste'
    Click $ui.BtnInstall 'BtnInstall'
    Wait-Idle
    Pump 300
    Assert-Equal 1 $S.Games.Count 'jogo reinstalado para o teste de export'

    $isoBtn = Get-GameButton 'ISO'
    Assert-True ($null -ne $isoBtn) 'botão ISO existe'
    Assert-Equal 'Jogo de Teste' $isoBtn.Tag.Nome 'botão ISO ligado ao jogo certo'

    # o botão abre diálogo nativo; o teste usa o caminho sem diálogo
    $dest = Join-Path $work 'export.iso'
    Start-ExportTo -Game $isoBtn.Tag -Dest $dest
    Assert-True $S.Busy 'export começou'
    Wait-Idle
    Pump 300
    Assert-True (Test-Path -LiteralPath $dest) 'iso remontado existe'
    Assert-Equal $isoFile.Length (Get-Item -LiteralPath $dest).Length 'iso remontado tem o mesmo tamanho'
    Assert-Equal $isoInfo.Serial (Get-IsoInfo $dest).Serial 'serial do iso remontado'

    # sobrescrever pede confirmação
    Start-ExportTo -Game $isoBtn.Tag -Dest $dest
    Assert-Equal 'Visible' $ui.Overlay.Visibility 'exportar sobre arquivo existente pede confirmação'
    Click $ui.BtnCancelConfirm 'BtnCancelConfirm'
    Assert-True (-not $S.Busy) 'cancelar não inicia export'

    # ============================================================ 11. recarregar / copiar log / janela
    Write-Host ''
    Write-Host '11. RECARREGAR, COPIAR e botões da janela' -ForegroundColor Cyan

    Assert-Equal $letter $S.Drive 'a unidade escolhida não muda sozinha'
    Click $ui.BtnRefresh 'BtnRefresh'
    Assert-Equal 1 $S.Games.Count 'RECARREGAR mantém a lista'
    Assert-True ((Get-LogText) -match 'recarregada') 'RECARREGAR registra no log'

    Click $ui.BtnCopyLog 'BtnCopyLog'
    try {
        $clip = [Windows.Clipboard]::GetText()
        Assert-True ($clip.Length -gt 0) 'COPIAR coloca o log na área de transferência'
    } catch {
        Write-Host '  [SKIP] área de transferência ocupada por outro processo' -ForegroundColor DarkYellow
    }

    Click $ui.BtnMax 'BtnMax'
    $deadline = (Get-Date).AddSeconds(3)
    while ($win.WindowState -ne 'Maximized' -and (Get-Date) -lt $deadline) { Pump 100 }
    Assert-Equal 'Maximized' $win.WindowState 'maximizar'
    Click $ui.BtnMax 'BtnMax'
    $deadline = (Get-Date).AddSeconds(3)
    while ($win.WindowState -ne 'Normal' -and (Get-Date) -lt $deadline) { Pump 100 }
    Assert-Equal 'Normal' $win.WindowState 'restaurar'

    Click $ui.BtnMin 'BtnMin'
    $deadline = (Get-Date).AddSeconds(3)
    while ($win.WindowState -ne 'Minimized' -and (Get-Date) -lt $deadline) { Pump 100 }
    Assert-Equal 'Minimized' $win.WindowState 'minimizar'
    $win.WindowState = 'Normal'
    Pump 100

    # ============================================================ 12. hot-plug
    Write-Host ''
    Write-Host '12. Pendrive conectado/removido com o app aberto' -ForegroundColor Cyan

    $plugLetter = if (Test-Path 'Y:\') { 'Z' } else { 'Y' }
    $plugDir = Join-Path ([IO.Path]::GetTempPath()) ('er2opl-plug-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $plugDir | Out-Null

    & cmd /c subst "${plugLetter}:" "$plugDir" | Out-Null
    Pump 1800
    $plugChip = $ui.DrivesPanel.Children | Where-Object { $_ -is [Windows.Controls.Primitives.ToggleButton] -and [string]$_.Tag -eq $plugLetter }
    Assert-True ($null -ne $plugChip) "unidade ${plugLetter}: apareceu sozinha"
    Assert-True ((Get-LogText) -match "conectada: $plugLetter") 'log registrou a conexão'

    Click $plugChip "chip-$plugLetter"
    Assert-Equal $plugLetter $S.Drive "unidade ${plugLetter}: selecionada"

    & cmd /c subst "${plugLetter}:" /d | Out-Null
    Pump 1800
    $plugChip = $ui.DrivesPanel.Children | Where-Object { $_ -is [Windows.Controls.Primitives.ToggleButton] -and [string]$_.Tag -eq $plugLetter }
    Assert-True ($null -eq $plugChip) "unidade ${plugLetter}: sumiu sozinha"
    Assert-True ($S.Drive -ne $plugLetter) 'seleção mudou ao remover a unidade'
    Assert-True ((Get-LogText) -match "removida: $plugLetter") 'log registrou a remoção'
    Assert-True ($ui.Toasts.Children.Count -gt 0) 'avisou que o pendrive saiu'
    Remove-Item $plugDir -Recurse -Force -ErrorAction SilentlyContinue

        # ============================================================ 13. biblioteca
    Write-Host ''
    Write-Host '13. Biblioteca: jogos de todas as plataformas na unidade' -ForegroundColor Cyan

    function New-TestPs2Iso {
        # ISO9660 mínimo com SYSTEM.CNF: serve para testar a leitura de verdade.
        param([string]$Path, [string]$Serial = 'SLUS_215.97')

        $total = 19
        $bytes = New-Object byte[] ($total * 2048)

        $pvd = 16 * 2048
        $bytes[$pvd] = 1
        [Text.Encoding]::ASCII.GetBytes('CD001').CopyTo($bytes, $pvd + 1)
        $bytes[$pvd + 6] = 1
        [Text.Encoding]::ASCII.GetBytes('PLAYSTATION').CopyTo($bytes, $pvd + 8)
        [BitConverter]::GetBytes([uint32]$total).CopyTo($bytes, $pvd + 80)
        [BitConverter]::GetBytes([uint32]2048).CopyTo($bytes, $pvd + 128)

        $rec = 156
        $bytes[$pvd + $rec] = 34
        [BitConverter]::GetBytes([uint32]17).CopyTo($bytes, $pvd + $rec + 2)
        [BitConverter]::GetBytes([uint32]2048).CopyTo($bytes, $pvd + $rec + 10)
        $bytes[$pvd + $rec + 25] = 2
        $bytes[$pvd + $rec + 28] = 1
        $bytes[$pvd + $rec + 31] = 1

        $dir = 17 * 2048
        $off = 0
        foreach ($n in @(@{ N = '.'; F = 2; E = 17; S = 2048 }, @{ N = '..'; F = 2; E = 17; S = 2048 }, @{ N = 'SYSTEM.CNF;1'; F = 0; E = 18; S = 64 })) {
            $nb = [Text.Encoding]::ASCII.GetBytes($n.N)
            $len = 33 + $nb.Length
            if ($len % 2) { $len++ }
            $bytes[$dir + $off] = [byte]$len
            [BitConverter]::GetBytes([uint32]$n.E).CopyTo($bytes, $dir + $off + 2)
            [BitConverter]::GetBytes([uint32]$n.S).CopyTo($bytes, $dir + $off + 10)
            $bytes[$dir + $off + 25] = [byte]$n.F
            $bytes[$dir + $off + 28] = 1
            $bytes[$dir + $off + 32] = [byte]$nb.Length
            $nb.CopyTo($bytes, $dir + $off + 33)
            $off += $len
        }

        $cnf = [Text.Encoding]::ASCII.GetBytes("BOOT2 = cdrom0:\$Serial;1`r`nVER = 1.00`r`nVMODE = NTSC`r`n")
        $cnf.CopyTo($bytes, 18 * 2048)
        [IO.File]::WriteAllBytes($Path, $bytes)
    }

    $roms = "${letter}:\ROMs"
    foreach ($d in 'PS2', 'PS1', 'SNES', 'N64', 'GBA', 'NDS', 'GC') {
        New-Item -ItemType Directory -Force (Join-Path $roms $d) | Out-Null
    }

    $ps2Iso = Join-Path $roms 'PS2\Jogo Teste (SLUS_215.97).iso'
    New-TestPs2Iso -Path $ps2Iso
    [IO.File]::WriteAllBytes((Join-Path $roms 'PS1\Crash (SLUS_005.94).bin'), (New-Object byte[] 8192))
    [IO.File]::WriteAllBytes((Join-Path $roms 'PS1\Crash (SLUS_005.94).cue'), [Text.Encoding]::ASCII.GetBytes('FILE "Crash (SLUS_005.94).bin" BINARY'))
    [IO.File]::WriteAllBytes((Join-Path $roms 'SNES\Super Mario World.sfc'), (New-Object byte[] 8192))
    [IO.File]::WriteAllBytes((Join-Path $roms 'N64\Zelda.z64'), (New-Object byte[] 8192))
    [IO.File]::WriteAllBytes((Join-Path $roms 'GBA\Pokemon.gba'), (New-Object byte[] 8192))
    [IO.File]::WriteAllBytes((Join-Path $roms 'NDS\Kirby.nds'), (New-Object byte[] 8192))
    [IO.File]::WriteAllBytes((Join-Path $roms 'GC\Sunshine.gcm'), (New-Object byte[] 8192))
    [IO.File]::WriteAllBytes((Join-Path $roms 'lixo.txt'), (New-Object byte[] 8192))

    # A seção 12 removeu a unidade do teste de hot-plug e o app escolheu outra:
    # volta para a unidade virtual antes de conferir a biblioteca.
    $chip = $ui.DrivesPanel.Children | Where-Object {
        $_ -is [Windows.Controls.Primitives.ToggleButton] -and [string]$_.Tag -eq $letter
    } | Select-Object -First 1
    Assert-True ($null -ne $chip) "unidade ${letter}: de volta na lista"
    Click $chip "chip-$letter (biblioteca)"
    Assert-Equal $letter $S.Drive "unidade ${letter}: selecionada para a biblioteca"

    Click $ui.TabLibrary 'TabLibrary'
    Pump 250
    Assert-Equal 'Visible' ([string]$ui.LibraryView.Visibility) 'aba BIBLIOTECA aparece'
    Assert-Equal 'Collapsed' ([string]$ui.OplView.Visibility) 'aba OPL fica escondida'

    Click $ui.BtnRefresh 'BtnRefresh (varredura)'
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline -and $ui.LibraryInfo.Text -match 'VARRENDO') { Pump 200 }
    Assert-True ($ui.LibraryInfo.Text -notmatch 'VARRENDO') 'varredura terminou'

    $lib = @($S.Lib)
    $plats = @($lib | ForEach-Object { $_.Platform } | Select-Object -Unique)
    foreach ($plat in 'PS2', 'PS1', 'SNES', 'N64', 'GBA', 'NDS', 'GC') {
        Assert-True ($plats -contains $plat) "biblioteca encontrou $plat"
    }

    $ps2 = $lib | Where-Object { $_.Platform -eq 'PS2' -and $_.Ext -eq '.iso' } | Select-Object -First 1
    Assert-True ($null -ne $ps2) 'biblioteca encontrou o ISO de PS2'
    Assert-Equal 'SLUS_215.97' $ps2.Serial 'serial lido de dentro do ISO'
    Assert-True ($S.LibReport.IsoChecked -ge 1) 'o ISO de PS2 foi aberto e lido (não só o nome)'
    Assert-True (-not ($lib | Where-Object { $_.Ext -eq '.bin' })) '.bin escondido (fica só o .cue)'
    Assert-True ([bool]($lib | Where-Object { $_.Ext -eq '.cue' })) '.cue aparece na lista'
    Assert-True ($ui.LibraryPanel.Children.Count -ge 7) 'linhas desenhadas na biblioteca'

    $row = $ui.LibraryPanel.Children | Where-Object { $_.Tag -and $_.Tag.File -eq $ps2Iso } | Select-Object -First 1
    Assert-True ($null -ne $row) 'linha do ISO de PS2 na tela'
    $plus = $row.Child.Children | Where-Object { $_ -is [Windows.Controls.Button] } | Select-Object -First 1
    Assert-True ($null -ne $plus) 'botão + na linha do PS2'

    $before = $S.Files.Count
    Click $plus 'botão + do PS2'
    Assert-Equal ($before + 1) $S.Files.Count 'jogo entrou na lista de instalação'
    Assert-Equal $ps2Iso $S.Files[$S.Files.Count - 1].Path 'é o ISO certo'
    $S.Files.Clear()
    Render-Files

    $snesRow = $ui.LibraryPanel.Children | Where-Object { $_.Tag -and $_.Tag.Platform -eq 'SNES' } | Select-Object -First 1
    $snesButtons = if ($snesRow) { @($snesRow.Child.Children | Where-Object { $_ -is [Windows.Controls.Button] }).Count } else { -1 }
    Assert-Equal 0 $snesButtons 'SNES não tem botão de instalar'

    Click $ui.TabOpl 'TabOpl'
    Pump 200
    Assert-Equal 'Visible' ([string]$ui.OplView.Visibility) 'voltou para a aba OPL'

    # ============================================================ 13b. arrastar compactado instala sozinho
    Write-Host ''
    Write-Host '13b. ZIP/RAR: arrastar instala sozinho' -ForegroundColor Cyan

    Assert-Equal $letter $S.Drive "unidade virtual ainda selecionada para o teste de ZIP"

    $ui.BtnAuto.IsChecked = $true
    $S.AutoInstall = $true
    Assert-True $S.AutoInstall 'auto-instalar religado para o teste de ZIP/RAR'

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $src = Join-Path $work 'compactado'
    New-Item -ItemType Directory -Force $src | Out-Null
    New-TestPs2Iso -Path (Join-Path $src 'Jogo Zip (SLUS_215.98).iso') -Serial 'SLUS_215.98'

    $zip = Join-Path $work 'Jogo Zip.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($src, $zip)

    $before = $S.Games.Count
    Add-DroppedFiles -Files @($zip) -Auto
    Assert-True ($S.Busy -or $S.Extract) 'ZIP começou a ser extraído'
    Wait-Idle
    Pump 400

    Assert-Equal ($before + 1) $S.Games.Count 'ZIP instalou sozinho'
    Assert-True ([bool]($S.Games | Where-Object { $_.Nome -eq 'Jogo Zip' })) 'nome do jogo veio do ZIP'
    Assert-Equal 0 $S.Files.Count 'lista limpa depois de instalar do ZIP'
    Assert-Equal 0 @($S.TempRoots).Count 'temporário do ZIP apagado'
    Assert-True ((Get-LogText) -match 'Extraindo') 'log registrou a extração'

    $rarExe = 'C:\Program Files\WinRAR\Rar.exe'
    if (Test-Path -LiteralPath $rarExe) {
        New-TestPs2Iso -Path (Join-Path $src 'Jogo Rar (SLUS_215.99).iso') -Serial 'SLUS_215.99'
        $rar = Join-Path $work 'Jogo Rar.rar'
        & $rarExe a -idq -ep1 $rar (Join-Path $src 'Jogo Rar (SLUS_215.99).iso')
        Assert-Equal 0 $LASTEXITCODE 'RAR de teste criado'

        $before = $S.Games.Count
        Add-DroppedFiles -Files @($rar) -Auto
        Wait-Idle
        Pump 400

        Assert-Equal ($before + 1) $S.Games.Count 'RAR instalou sozinho'
        Assert-True ([bool]($S.Games | Where-Object { $_.Nome -eq 'Jogo Rar' })) 'nome do jogo veio do RAR'
        Assert-Equal 0 $S.Files.Count 'lista limpa depois de instalar do RAR'
        Assert-Equal 0 @($S.TempRoots).Count 'temporário do RAR apagado'
    } else {
        Write-Host '  (WinRAR ausente: teste de RAR pulado)' -ForegroundColor DarkGray
    }
    # ============================================================ 13c. biblioteca lê compactados
    Write-Host ''
    Write-Host '13c. Biblioteca: ZIP/RAR/7Z mostram o jogo de dentro' -ForegroundColor Cyan

    $ui.BtnAuto.IsChecked = $false
    $S.AutoInstall = $false

    $bibSrc = Join-Path $work 'bib'
    New-Item -ItemType Directory -Force $bibSrc | Out-Null
    $bibIso = Join-Path $bibSrc 'Jogo Bib (SLUS_215.96).iso'
    New-TestPs2Iso -Path $bibIso -Serial 'SLUS_215.96'
    # bytes aleatórios: sem isso o ISO de teste comprime para poucos bytes e
    # o filtro de "arquivo pequeno demais" esconderia o compactado
    $rand = New-Object byte[] 300000
    (New-Object Random 7).NextBytes($rand)
    [IO.File]::WriteAllBytes($bibIso, [byte[]]([IO.File]::ReadAllBytes($bibIso) + $rand))

    $archDir = "${letter}:\Arquivos"
    New-Item -ItemType Directory -Force $archDir | Out-Null
    [IO.Compression.ZipFile]::CreateFromDirectory($bibSrc, (Join-Path $archDir 'Jogo Bib.zip'))

    $rarOnDrive = Join-Path $archDir 'Jogo Bib.rar'
    $rarExe = 'C:\Program Files\WinRAR\Rar.exe'
    $hasRar = Test-Path -LiteralPath $rarExe
    if ($hasRar) {
        & $rarExe a -idq -ep1 $rarOnDrive $bibIso
        $hasRar = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $rarOnDrive)
    }

    $sevenOnDrive = Join-Path $archDir 'Jogo Bib.7z'
    & tar.exe -cf $sevenOnDrive --format 7zip -C $bibSrc 'Jogo Bib (SLUS_215.96).iso' 2>$null
    $has7z = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $sevenOnDrive)

    Refresh-Library
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline -and $ui.LibraryInfo.Text -match 'VARRENDO') { Pump 250 }
    Pump 400

    $arch = @($S.Lib | Where-Object { $_.Kind -eq 'archive' })
    Assert-True ($arch.Count -ge 1) "biblioteca listou compactados ($($arch.Count))"
    Assert-True ($S.LibReport.ArchiveChecked -ge 1) 'o compactado foi aberto (só o índice)'

    $zipRow = $arch | Where-Object { $_.Ext -eq '.zip' } | Select-Object -First 1
    Assert-True ($null -ne $zipRow) 'ZIP aparece na biblioteca'
    Assert-Equal 'PS2' $zipRow.Platform 'ZIP com ISO de PS2 é classificado como PS2'
    Assert-Equal 'SLUS_215.96' $zipRow.Serial 'serial veio do nome do ISO dentro do ZIP'
    Assert-True ($zipRow.Rel -match 'dentro') 'a linha diz o que tem dentro do arquivo'

    if ($hasRar) {
        $rarRow = $arch | Where-Object { $_.Ext -eq '.rar' } | Select-Object -First 1
        Assert-True ($null -ne $rarRow) 'RAR aparece na biblioteca'
        Assert-Equal 'Jogo Bib (SLUS_215.96).iso' $rarRow.Inner 'RAR aponta o ISO de dentro'
    }
    if ($has7z) {
        $sevenRow = $arch | Where-Object { $_.Ext -eq '.7z' } | Select-Object -First 1
        Assert-True ($null -ne $sevenRow) '7Z aparece na biblioteca'
    }

    $zipPath = Join-Path $archDir 'Jogo Bib.zip'
    $zipLine = $ui.LibraryPanel.Children | Where-Object { $_.Tag -and $_.Tag.File -eq $zipPath } | Select-Object -First 1
    Assert-True ($null -ne $zipLine) 'linha do ZIP desenhada'
    $zipPlus = $zipLine.Child.Children | Where-Object { $_ -is [Windows.Controls.Button] } | Select-Object -First 1
    Assert-True ($null -ne $zipPlus) 'botão + no ZIP'

    Click $zipPlus 'botão + do ZIP da biblioteca'
    Wait-Idle
    Pump 300
    Assert-Equal 1 $S.Files.Count 'ZIP da biblioteca foi extraído para a lista'
    Assert-True ($S.TempRoots.Count -ge 1) 'temporário da extração existe enquanto o jogo não foi instalado'
    $S.Files.Clear()
    Render-Files
    foreach ($t in @($S.TempRoots)) { Remove-TempRoot $t }

    # ============================================================ 14. nenhum erro de handler
    Write-Host ''
    Write-Host '14. Nenhum handler lançou exceção' -ForegroundColor Cyan

    if ($script:UiErrors.Count -gt 0) {
        foreach ($ex in $script:UiErrors) {
            Write-Host "  exceção: $($ex.GetType().Name): $($ex.Message)" -ForegroundColor Red
            Write-Host "  $($ex.StackTrace)" -ForegroundColor DarkGray
        }
    }
    Assert-Equal 0 $script:UiErrors.Count 'exceções em handlers'
    Assert-True (-not ((Get-LogText) -match 'ERRO inesperado')) 'log sem erro inesperado'

    # ============================================================ 15. cobertura
    Write-Host ''
    Write-Host '15. Cobertura dos controles' -ForegroundColor Cyan

    $all = New-Object System.Collections.ArrayList
    function Walk {
        param($Node)
        if ($null -eq $Node) { return }
        if ($Node -is [Windows.Controls.Primitives.ButtonBase] -or
            ($Node -is [Windows.Controls.TextBlock] -and $Node.Cursor -eq [Windows.Input.Cursors]::Hand)) {
            [void]$all.Add($Node)
        }
        $children = @()
        if ($Node -is [Windows.Controls.Panel]) { $children = $Node.Children }
        elseif ($Node -is [Windows.Controls.Decorator]) { $children = @($Node.Child) }
        elseif ($Node -is [Windows.Controls.ContentControl]) { $children = @($Node.Content) }
        foreach ($c in $children) { Walk $c }
    }
    Walk $win.Content

    Write-Host ("  controles na tela: {0}" -f $all.Count) -ForegroundColor DarkGray
    Assert-True ($all.Count -gt 0) 'varredura da árvore encontrou controles'

    # Sweep: clica no que ainda não foi clicado. Sem arquivos na lista e com
    # qualquer confirmação cancelada, nada aqui pode gravar no pendrive.
    $S.Files.Clear()
    Render-Files

    $skip = @('BtnClose')
    $swept = 0
    $skipped = New-Object System.Collections.ArrayList

    for ($i = 0; $i -lt $all.Count; $i++) {
        $el = $all[$i]
        $name = if ($el.Name) { $el.Name } else { "#$i" }
        $content = if ($el.Content -is [string]) { $el.Content } elseif ($el.Text) { $el.Text } else { '' }

        if ($skip -contains $el.Name) { [void]$skipped.Add("$name (fecha a janela)"); continue }
        if ($content -eq 'ISO') { [void]$skipped.Add("$name (abre diálogo nativo)"); continue }
        if ($el.Name -and $script:Covered.ContainsKey($el.Name)) { continue }

        Click $el "sweep-$name"
        $swept++

        if ($ui.Overlay.Visibility -eq 'Visible') { Click $ui.BtnCancelConfirm 'BtnCancelConfirm' }
        if ($win.WindowState -ne 'Normal') { $win.WindowState = 'Normal'; Pump 80 }
        if ($S.Busy) { throw "ABORTADO: o clique em $name iniciou uma cópia" }
    }

    Write-Host ("  clicados agora: {0} | fora do sweep: {1}" -f $swept, ($skipped -join ', ')) -ForegroundColor DarkGray
    Assert-True ($swept -ge 5) "cliquei nos controles que faltavam ($swept)"
    Assert-Equal 0 $script:UiErrors.Count 'exceções durante o sweep'

    # fechar por último
    Click $ui.BtnClose 'BtnClose'
    Assert-True (-not $win.IsVisible) 'fechar a janela funciona'
}
finally {
    try { if ($win) { $win.Close() } } catch { }
    & cmd /c subst "${letter}:" /d | Out-Null
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("Resultado: {0} passaram, {1} falharam" -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
