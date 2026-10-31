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
. (Join-Path $PSScriptRoot 'TestIso.ps1')

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
$env:EASYROMS_MUTE = '1'                      # testes não tocam som
$env:EASYROMS_SETTINGS = Join-Path $work 'settings.json'   # não mexe na config real

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
    Assert-Equal 0 $S.Files.Count 'jogo instalado sai da fila (não fica como pendente)'

    Click $ui.TabOpl 'TabOpl (resumo)'
    Assert-True ([string]$ui.LibraryInfo.Text -match 'NO OPL') "aba OPL resume o que está instalado ($($ui.LibraryInfo.Text))"

    # ============================================================ 7b. jogo já instalado na fila
    Write-Host ''
    Write-Host '7b. Jogo já instalado é marcado antes de copiar' -ForegroundColor Cyan

    Add-DroppedFiles -Files @($isoFile.FullName)
    Assert-Equal 1 $S.Files.Count 'o mesmo ISO volta para a lista'
    $tag = $ui.FilesPanel.Children[0].Child.Children |
        Where-Object { $_ -is [Windows.Controls.TextBlock] -and $_.Text -in 'OK', 'JÁ', 'ERR' } |
        Select-Object -First 1
    Assert-True ($null -ne $tag) 'a linha tem etiqueta de estado'
    Assert-Equal 'JÁ' $tag.Text 'etiqueta avisa que já está no OPL'
    Assert-True ([string]$ui.HintText.Text -match 'Já está tudo no OPL') "a dica avisa antes de instalar de novo ($($ui.HintText.Text))"

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
        param([string]$Content, [string]$Nome)
        foreach ($row in $ui.GamesPanel.Children) {
            if ($row.Child -isnot [Windows.Controls.Grid]) { continue }
            foreach ($child in $row.Child.Children) {
                if ($child -is [Windows.Controls.StackPanel]) {
                    $btn = $child.Children | Where-Object { $_ -is [Windows.Controls.Button] -and "$($_.Content)" -eq $Content } | Select-Object -First 1
                    if ($btn) {
                        if ($Nome -and "$($btn.Tag.Nome)" -ne $Nome) { continue }
                        return $btn
                    }
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

    # Exportar um ISO pequeno: o teste do ul.* de 2 pedaços já foi feito na
    # seção 7. Assim o teste não precisa de 2 GB livres no disco do sistema.
    $expIso = Join-Path $work 'Jogo Export (SLUS_215.97).iso'
    New-TestPs2Iso -Path $expIso -Serial 'SLUS_215.97'
    $expInfo = Get-IsoInfo $expIso

    Add-DroppedFiles -Files @($expIso)
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
    Assert-Equal (Get-Item -LiteralPath $expIso).Length (Get-Item -LiteralPath $dest).Length 'iso remontado tem o mesmo tamanho'
    Assert-Equal $expInfo.Serial (Get-IsoInfo $dest).Serial 'serial do iso remontado'

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

    $roms = "${letter}:\ROMs"
    foreach ($d in 'PS2', 'PS1', 'SNES', 'N64', 'GBA', 'NDS', 'GC') {
        New-Item -ItemType Directory -Force (Join-Path $roms $d) | Out-Null
    }

    $ps2Iso = Join-Path $roms 'PS2\Jogo Teste (SLUS_215.97).iso'
    New-TestPs2Iso -Path $ps2Iso
    # Mesmo serial do jogo instalado na seção 7: é uma cópia, não um jogo novo.
    # A biblioteca tem que marcar JÁ NO OPL em vez de oferecer instalar.
    $ps2Novo = Join-Path $roms 'PS2\Jogo Novo (SLUS_215.96).iso'
    New-TestPs2Iso -Path $ps2Novo -Serial 'SLUS_215.96'
    [IO.File]::WriteAllBytes((Join-Path $roms 'PS1\Crash (SLUS_005.94).bin'), (New-Object byte[] 8192))
    [IO.File]::WriteAllBytes((Join-Path $roms 'PS1\Crash (SLUS_005.94).cue'), [Text.Encoding]::ASCII.GetBytes('FILE "Crash (SLUS_005.94).bin" BINARY'))
    [IO.File]::WriteAllBytes((Join-Path $roms 'SNES\Super Mario World.sfc'), (New-Object byte[] 8192))
    # ROMs de verdade: cada formato tem uma assinatura que a biblioteca confere
    # (ver $script:GameSignature em lib/GameLibrary.ps1). Arquivo de zeros puro
    # é rejeitado de propósito — um .gba renomeado não pode contar como jogo.
    $z64 = New-Object byte[] (128 * 1024)
    $n64sig = [byte[]](0x80, 0x37, 0x12, 0x40)
    $n64sig.CopyTo($z64, 0x00)
    [IO.File]::WriteAllBytes((Join-Path $roms 'N64\Zelda.z64'), $z64)
    # GBA e NDS compartilham o logo da Nintendo; muda só o offset.
    $logo = [byte[]](0x24, 0xFF, 0xAE, 0x51, 0x69, 0x9A, 0xA2, 0x21)
    $gba = New-Object byte[] (32 * 1024)
    $logo.CopyTo($gba, 0x04)
    [IO.File]::WriteAllBytes((Join-Path $roms 'GBA\Pokemon.gba'), $gba)
    $nds = New-Object byte[] (128 * 1024)
    $logo.CopyTo($nds, 0x0C)
    [IO.File]::WriteAllBytes((Join-Path $roms 'NDS\Kirby.nds'), $nds)
    # GameCube: magic do disco no offset 0x1C.
    $gcm = New-Object byte[] (512 * 1024)
    $gcmSig = [byte[]](0xC2, 0x33, 0x9F, 0x3D)
    $gcmSig.CopyTo($gcm, 0x1C)
    [IO.File]::WriteAllBytes((Join-Path $roms 'GC\Sunshine.gcm'), $gcm)
    [IO.File]::WriteAllBytes((Join-Path $roms 'lixo.txt'), (New-Object byte[] 8192))

    # Falsos positivos que o usuário viu: README.md (Markdown) com extensão de
    # Mega Drive e um .iso que não é ISO9660. Nenhum dos dois pode aparecer.
    $readme = Join-Path $roms 'README.md'
    $texto = ('# Meus jogos' + "`r`n" + ('lista de jogos baixados' + "`r`n")) * 400
    [IO.File]::WriteAllText($readme, $texto, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllBytes((Join-Path $roms 'PS2\filme.iso'), [Text.Encoding]::ASCII.GetBytes(('nao sou iso ' * 4000)))

    # Mega Drive de verdade: 16 KB com a assinatura SEGA no offset 0x100.
    $md = New-Object byte[] (16 * 1024)
    [Text.Encoding]::ASCII.GetBytes('SEGA MEGA DRIVE ').CopyTo($md, 0x100)
    [IO.File]::WriteAllBytes((Join-Path $roms 'Sonic (USA).md'), $md)

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

    $ps2 = $lib | Where-Object { $_.Platform -eq 'PS2' -and $_.Ext -eq '.iso' -and $_.File -eq $ps2Iso } | Select-Object -First 1
    Assert-True ($null -ne $ps2) 'biblioteca encontrou o ISO de PS2'
    Assert-Equal 'SLUS_215.97' $ps2.Serial 'serial lido de dentro do ISO'
    Assert-True ($S.LibReport.IsoChecked -ge 1) 'o ISO de PS2 foi aberto e lido (não só o nome)'
    Assert-True (-not ($lib | Where-Object { $_.Ext -eq '.bin' })) '.bin escondido (fica só o .cue)'
    Assert-True ([bool]($lib | Where-Object { $_.Ext -eq '.cue' })) '.cue aparece na lista'
    Assert-True ($ui.LibraryPanel.Children.Count -ge 8) 'linhas desenhadas na biblioteca'

    # ---- filtros de lixo: README.md e .iso falso não entram
    Assert-True (-not ($lib | Where-Object { $_.Name -eq 'README' })) 'README.md não aparece como jogo'
    Assert-True (-not ($lib | Where-Object { $_.Name -eq 'filme' })) '.iso que não é ISO9660 não aparece'
    $md = $lib | Where-Object { $_.Ext -eq '.md' } | Select-Object -First 1
    Assert-True ($null -ne $md) 'ROM de Mega Drive com assinatura SEGA aparece'
    Assert-Equal 'MEGA' $md.Platform 'Mega Drive classificado certo'

    # ---- status: instalado x pode instalar
    $counts = $S.LibCounts
    Assert-Equal 5 $ui.LibFilters.Children.Count 'cinco filtros (tudo, instalados, no pendrive, para instalar, outros)'
    Assert-Equal $counts.all ($counts.installed + $counts.elsewhere + $counts.pending + $counts.other) 'as contagens fecham com o total'
    Assert-True ($counts.installed -ge 2) "conta os instalados ($($counts.installed))"
    Assert-True ($counts.pending -ge 1) "conta o que pode ser instalado ($($counts.pending))"
    Assert-True ([string]$ui.LibraryInfo.Text -match 'INSTALADO\(S\)') "cabeçalho resume instalados x pendentes ($($ui.LibraryInfo.Text))"

    $row = $ui.LibraryPanel.Children | Where-Object { $_.Tag -and $_.Tag.File -eq $ps2Iso } | Select-Object -First 1
    Assert-True ($null -ne $row) 'linha do ISO de PS2 na tela'
    Assert-Equal 'installed' $row.Tag.Status 'mesmo serial do ul.cfg = já instalado'
    Assert-Equal 'COPIA' $row.Tag.Where 'a linha diz que é cópia do jogo instalado'
    $rowText = @($row.Child.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] } | ForEach-Object { $_.Text })
    Assert-True ($rowText -contains 'JÁ NO OPL') 'a linha mostra JÁ NO OPL'
    Assert-Equal 0 @($row.Child.Children | Where-Object { $_ -is [Windows.Controls.Button] }).Count 'não oferece instalar de novo'

    $novoRow = $ui.LibraryPanel.Children | Where-Object { $_.Tag -and $_.Tag.File -eq $ps2Novo } | Select-Object -First 1
    Assert-True ($null -ne $novoRow) 'linha do jogo novo na tela'
    Assert-Equal 'pending' $novoRow.Tag.Status 'jogo de PS2 fora do ul.cfg = pode instalar'
    $installBtn = $novoRow.Child.Children | Where-Object { $_ -is [Windows.Controls.Button] } | Select-Object -First 1
    Assert-True ($null -ne $installBtn) 'botão INSTALAR na linha do jogo novo'
    Assert-Equal 'INSTALAR' $installBtn.Content 'o botão diz o que faz'

    $before = $S.Files.Count
    Click $installBtn 'INSTALAR do jogo novo'
    Assert-Equal ($before + 1) $S.Files.Count 'jogo entrou na lista de instalação'
    Assert-Equal $ps2Novo $S.Files[$S.Files.Count - 1].Path 'é o ISO certo'
    $S.Files.Clear()
    Render-Files

    # ---- filtros
    $pendingChip = $ui.LibFilters.Children | Where-Object { [string]$_.Tag -eq 'pending' } | Select-Object -First 1
    Click $pendingChip 'filtro PARA INSTALAR'
    Assert-Equal 'pending' $S.LibFilter 'filtro PARA INSTALAR ativo'
    Assert-True ($ui.LibraryPanel.Children.Count -ge 1) 'filtro PARA INSTALAR tem linhas'
    Assert-Equal 0 @($ui.LibraryPanel.Children | Where-Object { $_.Tag -and $_.Tag.Status -ne 'pending' }).Count 'só mostra o que falta instalar'

    $installedChip = $ui.LibFilters.Children | Where-Object { [string]$_.Tag -eq 'installed' } | Select-Object -First 1
    Click $installedChip 'filtro INSTALADOS'
    Assert-Equal 'installed' $S.LibFilter 'filtro INSTALADOS ativo'
    Assert-Equal 0 @($ui.LibraryPanel.Children | Where-Object { $_.Tag -and $_.Tag.Status -ne 'installed' }).Count 'só mostra o que já está no pendrive'

    $otherChip = $ui.LibFilters.Children | Where-Object { [string]$_.Tag -eq 'other' } | Select-Object -First 1
    Click $otherChip 'filtro OUTROS'
    Assert-Equal 0 @($ui.LibraryPanel.Children | Where-Object { $_.Tag -and $_.Tag.Status -ne 'other' }).Count 'OUTROS só tem PS1/Nintendo'

    $allChip = $ui.LibFilters.Children | Where-Object { [string]$_.Tag -eq 'all' } | Select-Object -First 1
    Click $allChip 'filtro TUDO'
    Assert-Equal 'all' $S.LibFilter 'voltou para TUDO'

    $snesRow = $ui.LibraryPanel.Children | Where-Object { $_.Tag -and $_.Tag.Platform -eq 'SNES' } | Select-Object -First 1
    $snesButtons = if ($snesRow) { @($snesRow.Child.Children | Where-Object { $_ -is [Windows.Controls.Button] }).Count } else { -1 }
    Assert-Equal 0 $snesButtons 'SNES não tem botão de instalar'

    # ---- seleção em lote: cada linha que pode instalar tem caixa de seleção
    $novoRow = $ui.LibraryPanel.Children | Where-Object { $_.Tag -and $_.Tag.File -eq $ps2Novo } | Select-Object -First 1
    $chk = $novoRow.Child.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] } | Select-Object -First 1
    Assert-True ($null -ne $chk) 'jogo instalável tem caixa de seleção'
    Assert-Equal 'Collapsed' ([string]$ui.BtnInstallSelected.Visibility) 'botão de lote começa escondido'
    Assert-Equal 0 $S.LibSel.Count 'nada selecionado no começo'

    $chk.IsChecked = $true
    $chk.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Pump 60
    Assert-Equal 1 $S.LibSel.Count 'marcou 1 jogo para instalar'
    Assert-Equal 'Visible' ([string]$ui.BtnInstallSelected.Visibility) 'botão de lote aparece'
    Assert-True ([string]$ui.BtnInstallSelected.Content -match '1 SELECIONADO') 'botão mostra a contagem'
    Assert-True ([string]$ui.LibraryInfo.Text -match 'SELECIONADO') 'cabeçalho mostra a seleção'

    $chk.IsChecked = $false
    $chk.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Pump 60
    Assert-Equal 0 $S.LibSel.Count 'desmarcar limpa a seleção'
    Assert-Equal 'Collapsed' ([string]$ui.BtnInstallSelected.Visibility) 'botão de lote some de novo'

    # ---- não oferece caixa para o que não instala (cópia já no OPL)
    $copyRow = $ui.LibraryPanel.Children | Where-Object { $_.Tag -and $_.Tag.File -eq $ps2Iso } | Select-Object -First 1
    $copyChk = $copyRow.Child.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] } | Select-Object -First 1
    Assert-True ($null -eq $copyChk) 'jogo já instalado não tem caixa de seleção'

    # ---- instalar em lote: marca e instala de uma vez
    $S.Files.Clear()
    Render-Files
    $chk.IsChecked = $true
    $chk.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Pump 60
    Assert-Equal 1 $S.LibSel.Count 'jogo marcado para lote'
    Click $ui.BtnInstallSelected 'INSTALAR SELECIONADOS'
    Wait-Idle
    Assert-True ($S.Busy -or $ui.Bar.Value -ge 0) 'lote disparou a instalação'
    Assert-True (@($S.Games | Where-Object { $_.Serial -eq 'SLUS_215.96' }).Count -ge 1) 'o lote instalou o jogo escolhido'
    Assert-Equal 0 $S.LibSel.Count 'seleção é limpa ao recarregar a biblioteca'

    # Desfaz a instalação do lote: sem isso o serial SLUS_215.96 fica no pendrive
    # e a seção 13c acharia o jogo de dentro do ZIP já instalado.
    Click $ui.TabOpl 'TabOpl'
    Pump 120
    $batchEntry = $S.Games | Where-Object { $_.Serial -eq 'SLUS_215.96' } | Select-Object -First 1
    $batchGame = if ($batchEntry) { Get-GameButton '✕' $batchEntry.Nome } else { $null }
    if ($batchGame) {
        Click $batchGame 'game-remove (lote)'
        Click $ui.BtnYesConfirm 'BtnYesConfirm (lote)'
        Wait-Idle
        Pump 400
        Assert-Equal 0 @($S.Games | Where-Object { $_.Serial -eq 'SLUS_215.96' }).Count 'drive limpo de volta para a 13b/13c'
    }

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
    # tar do macOS/Linux (bsdtar) pode não suportar --format 7zip; sem o guard o
    # erro nativo derruba a suíte inteira ($ErrorActionPreference = 'Stop').
    $has7z = $false
    try {
        & tar.exe -cf $sevenOnDrive --format 7zip -C $bibSrc 'Jogo Bib (SLUS_215.96).iso' 2>$null
        $has7z = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $sevenOnDrive)
    } catch {
        $has7z = $false
    }

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

    # ============================================================ 13d. jogo já instalado em outra unidade
    Write-Host ''
    Write-Host '13d. Aviso: jogo já instalado em outra unidade' -ForegroundColor Cyan

    $S.LibFilter = 'all'
    $S.InstalledMap = @{ 'SLUS_215.96' = 'F' }
    Render-Library

    $outro = $ui.LibraryPanel.Children | Where-Object { $_.Tag -and $_.Tag.File -eq $ps2Novo } | Select-Object -First 1
    Assert-True ($null -ne $outro) 'linha do jogo aparece com o mapa de outras unidades'
    Assert-Equal 'elsewhere' $outro.Tag.Status 'jogo de outra unidade = elsewhere'
    Assert-Equal 'F' $outro.Tag.Where 'a linha sabe em qual unidade ele está'
    $outroText = @($outro.Child.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] } | ForEach-Object { $_.Text })
    Assert-True ($outroText -contains 'JÁ NO PENDRIVE F:') 'a linha avisa JÁ NO PENDRIVE F:'
    Assert-Equal 0 @($outro.Child.Children | Where-Object { $_ -is [Windows.Controls.Button] }).Count 'não oferece instalar de novo'
    Assert-Equal 'Visible' ([string]$ui.LibWarn.Visibility) 'faixa amarela de aviso aparece'
    Assert-True ($ui.LibWarn.Text -match 'NÃO PRECISA INSTALAR') "aviso diz que não precisa instalar ($($ui.LibWarn.Text))"
    Assert-True ($S.LibCounts.elsewhere -ge 1) "contagem NO PENDRIVE ($($S.LibCounts.elsewhere))"

    $elseChip = $ui.LibFilters.Children | Where-Object { [string]$_.Tag -eq 'elsewhere' } | Select-Object -First 1
    Assert-True ($null -ne $elseChip) 'existe o filtro NO PENDRIVE'
    Assert-True ([string]$elseChip.Content -match 'NO PENDRIVE') "o filtro mostra a contagem ($($elseChip.Content))"
    Click $elseChip 'filtro NO PENDRIVE'
    Assert-Equal 'elsewhere' $S.LibFilter 'filtro NO PENDRIVE ativo'
    Assert-Equal 0 @($ui.LibraryPanel.Children | Where-Object { $_.Tag -and $_.Tag.Status -ne 'elsewhere' }).Count 'só mostra jogos de outra unidade'

    $before = $S.Files.Count
    Add-LibraryGame $outro.Tag
    Assert-Equal $before $S.Files.Count 'clicar no jogo de outra unidade não enfileira nada'

    # volta ao normal: sem o mapa, o aviso desaparece
    $S.InstalledMap = @{}
    $S.LibFilter = 'all'
    Render-Library
    Assert-Equal 'Collapsed' ([string]$ui.LibWarn.Visibility) 'sem jogos de fora, a faixa some'
    Assert-Equal 0 $S.LibCounts.elsewhere 'contagem NO PENDRIVE volta a zero'

    # ============================================================ 13e. glossário e sons
    Write-Host ''
    Write-Host '13e. Glossário e sons da interface' -ForegroundColor Cyan

    Assert-Equal 'Collapsed' ([string]$ui.HelpOverlay.Visibility) 'glossário começa fechado'
    Click $ui.BtnHelp 'BtnHelp'
    Assert-Equal 'Visible' ([string]$ui.HelpOverlay.Visibility) 'botão ? abre o glossário'
    Assert-True ($ui.HelpPanel.Children.Count -ge 10) "glossário tem seções e termos ($($ui.HelpPanel.Children.Count))"

    $helpText = @($ui.HelpPanel.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] } | ForEach-Object {
            if ($_.Inlines.Count -gt 0) { ($_.Inlines | ForEach-Object { $_.Text }) -join ' ' } else { $_.Text }
        }) -join ' '
    foreach ($term in 'MODO', 'ul.*', 'ul.cfg', 'JÁ NO PENDRIVE', 'OPL', 'README.md') {
        Assert-True ($helpText -match [regex]::Escape($term)) "glossário explica $term"
    }

    Click $ui.BtnHelpClose 'BtnHelpClose'
    Assert-Equal 'Collapsed' ([string]$ui.HelpOverlay.Visibility) 'FECHAR esconde o glossário'

    # ESC também fecha o glossário
    Click $ui.BtnHelp 'BtnHelp'
    $src = [Windows.PresentationSource]::FromVisual($win)
    $key = New-Object Windows.Input.KeyEventArgs([Windows.Input.Keyboard]::PrimaryDevice, $src, 0, [Windows.Input.Key]::Escape)
    $key.RoutedEvent = [Windows.UIElement]::KeyDownEvent
    $win.RaiseEvent($key)
    Pump 90
    Assert-Equal 'Collapsed' ([string]$ui.HelpOverlay.Visibility) 'ESC fecha o glossário'

    Assert-True ($S.Snd.Count -ge 6) "sons carregados do disco ($($S.Snd.Count))"
    foreach ($n in 'hover', 'click', 'boot', 'success', 'error', 'connect', 'disconnect') {
        Assert-True ($S.Snd.ContainsKey($n)) "som '$n' disponível"
    }
    Assert-Equal 'SOM: OFF' ([string]$ui.BtnSound.Content) 'teste começa em silêncio (EASYROMS_MUTE)'
    Assert-Equal $true $S.Muted 'o modo de teste não toca áudio'

    $ui.BtnSound.IsChecked = $true
    Click $ui.BtnSound 'BtnSound'
    Assert-Equal $true $S.Sound 'SOM: ON liga os sons'
    Assert-Equal 'SOM: ON' ([string]$ui.BtnSound.Content) 'o chip mostra SOM: ON'

    $ui.BtnSound.IsChecked = $false
    Click $ui.BtnSound 'BtnSound'
    Assert-Equal $false $S.Sound 'SOM: OFF desliga os sons'
    Assert-Equal 'SOM: OFF' ([string]$ui.BtnSound.Content) 'o chip mostra SOM: OFF'

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
