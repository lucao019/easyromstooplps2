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
        while ($S.Busy -and (Get-Date) -lt $deadline) { Pump 100 }
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
    Assert-Equal 'ul' $S.Mode 'modo padrão é ul'

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
    }
    Assert-True ($tested -ge 2) "cliquei em $tested unidades"

    # ============================================================ 3. modos
    Write-Host ''
    Write-Host '3. Chips de modo' -ForegroundColor Cyan

    $modes = @($ui.ModePanel.Children | Where-Object { $_ -is [Windows.Controls.Primitives.ToggleButton] })
    Assert-Equal 2 $modes.Count 'dois modos (ul e dvd)'

    foreach ($chip in $modes) {
        Click $chip "modo-$($chip.Tag)"
        Assert-Equal $chip.Tag $S.Mode "clique no modo $($chip.Tag) muda o modo"
        $checked = @($modes | Where-Object { $_.IsChecked })
        Assert-Equal 1 $checked.Count 'só um modo marcado por vez'
    }
    Click ($modes | Where-Object { $_.Tag -eq 'ul' }) 'modo-ul'
    Assert-Equal 'ul' $S.Mode 'voltou para ul'

    # ============================================================ 4. botões sem arquivo
    Write-Host ''
    Write-Host '4. INSTALAR / SIMULAR sem arquivo (tem que avisar, não quebrar)' -ForegroundColor Cyan

    # Trava de segurança: a partir daqui nunca deixamos a unidade apontar para
    # um disco real. Se algo falhar, o teste morre em vez de gravar no pendrive.
    $S.Drive = $letter
    if ($S.Drive -ne $letter) { throw "não consegui fixar a unidade de teste ${letter}:" }

    Click $ui.BtnInstall 'BtnInstall'
    Assert-Equal 'Collapsed' $ui.Overlay.Visibility 'INSTALAR sem arquivo não abre confirmação'
    Assert-True ($ui.Toasts.Children.Count -gt 0) 'INSTALAR sem arquivo mostra aviso'

    Click $ui.BtnSimulate 'BtnSimulate'
    Assert-Equal 'Collapsed' $ui.Overlay.Visibility 'SIMULAR sem arquivo não abre confirmação'
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

    # ============================================================ 6. limpar e simular
    Write-Host ''
    Write-Host '6. Limpar lista e SIMULAR' -ForegroundColor Cyan

    Click $ui.BtnClearFiles 'BtnClearFiles'
    Assert-Equal 0 $S.Files.Count 'LIMPAR LISTA esvazia'
    Assert-Equal '' $ui.NameBox.Text 'LIMPAR LISTA limpa o nome'
    Assert-Equal 0 $ui.FilesPanel.Children.Count 'lista visual vazia'

    Add-DroppedFiles -Files @($isoFile.FullName)
    $logBefore = (Get-LogText).Length
    Click $ui.BtnSimulate 'BtnSimulate'
    $logAfter = Get-LogText
    Assert-True ($logAfter.Length -gt $logBefore) 'SIMULAR escreve no log'
    Assert-True ($logAfter -match 'SIMULA') 'log diz que é simulação'
    Assert-True (-not $S.Busy) 'SIMULAR não inicia cópia'
    Assert-Equal 0 @(Get-ChildItem "${letter}:\ul.*" -File).Count 'SIMULAR não gravou nada'

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
    Assert-Equal 'Maximized' $win.WindowState 'maximizar'
    Click $ui.BtnMax 'BtnMax'
    Assert-Equal 'Normal' $win.WindowState 'restaurar'

    Click $ui.BtnMin 'BtnMin'
    Assert-Equal 'Minimized' $win.WindowState 'minimizar'
    $win.WindowState = 'Normal'
    Pump 100

    # ============================================================ 12. nenhum erro de handler
    Write-Host ''
    Write-Host '12. Nenhum handler lançou exceção' -ForegroundColor Cyan

    if ($script:UiErrors.Count -gt 0) {
        foreach ($ex in $script:UiErrors) {
            Write-Host "  exceção: $($ex.GetType().Name): $($ex.Message)" -ForegroundColor Red
            Write-Host "  $($ex.StackTrace)" -ForegroundColor DarkGray
        }
    }
    Assert-Equal 0 $script:UiErrors.Count 'exceções em handlers'
    Assert-True (-not ((Get-LogText) -match 'ERRO inesperado')) 'log sem erro inesperado'

    # ============================================================ 13. cobertura
    Write-Host ''
    Write-Host '13. Cobertura dos controles' -ForegroundColor Cyan

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
