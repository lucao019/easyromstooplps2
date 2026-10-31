<#
.SYNOPSIS
    Interface gráfica do EasyRomsToOPL.

.DESCRIPTION
    Front-end WPF para o mesmo motor da CLI (lib/UlFormat.ps1).
    Visual baseado nos tokens do terminal.css (JetBrains Mono, #050505, ciano #8BE9FD).

.EXAMPLE
    .\gui\EasyRomsToOPL.GUI.ps1
#>
[CmdletBinding()]
param(
    # ISOs para já abrir na lista (ex.: "Abrir com")
    [string[]]$Iso,

    # Letra do pendrive a selecionar, ex. 'F'
    [string]$Drive
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

trap {
    $log = Join-Path ([IO.Path]::GetTempPath()) 'EasyRomsToOPL-error.log'
    try {
        ("[{0}] {1}`r`n{2}`r`n" -f (Get-Date).ToString('s'), ($_ | Out-String), $_.ScriptStackTrace) |
            Add-Content -LiteralPath $log -Encoding UTF8
    } catch { }
    try {
        [Windows.MessageBox]::Show(
            ("Falha ao iniciar a interface:`r`n`r`n{0}`r`n`r`nDetalhes em:`r`n{1}" -f $_.Exception.Message, $log),
            'EasyRomsToOPL', 'OK', 'Error') | Out-Null
    } catch { }
    exit 1
}

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'lib\UlFormat.ps1')
. (Join-Path $repoRoot 'lib\GameLibrary.ps1')
. (Join-Path $repoRoot 'lib\GameInfo.ps1')

# ---------------------------------------------------------------- carregar XAML

$xamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$win = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))

$ui = @{}
@(
    'Root', 'DropZone', 'DropTitle', 'FileCount', 'BtnClearFiles', 'FilesPanel', 'DeviceName',
    'NameBox', 'BtnInstall', 'HintText', 'DrivesPanel', 'DriveCount', 'StatSpace',
    'StatGames', 'Bar', 'BarText', 'BarPct', 'BtnRefresh', 'GamesPanel', 'BtnCopyLog', 'LogBox',
    'LogHeader', 'LogBody', 'BtnLogToggle', 'BtnAuto', 'LibFilters',
    'StatusText', 'BusyDot', 'Toasts', 'Overlay', 'ConfirmTitle', 'ConfirmText', 'BtnCancelConfirm',
    'BtnYesConfirm', 'BtnMin', 'BtnMax', 'BtnClose', 'VersionText', 'LibWarn',
    'TabOpl', 'TabLibrary', 'LibraryInfo', 'OplView', 'LibraryView', 'LibraryPanel',
    'BtnInstallSelected',
    'BtnHelp', 'BtnHelpClose', 'BtnSound', 'HelpOverlay', 'HelpPanel',
    'InfoOverlay', 'InfoTitle', 'InfoStatus', 'InfoPanel', 'BtnInfoClose'
) | ForEach-Object { $ui[$_] = $win.FindName($_) }

# ---------------------------------------------------------------- estado

$S = @{
    Drive      = $null          # letra, ex. 'F'
    Drives     = @()
    Files      = New-Object System.Collections.ArrayList
    Mode       = 'ul'           # fixo: UL.* divide em pedaços de 1 GiB (serve para qualquer tamanho)
    Hw         = @{}            # letra -> tipo/modelo do disco (pendrive, SSD, HD...)
    Games      = @()
    Busy       = $false
    Force      = $false
    LogIndex   = 0
    Sync       = $null
    Timer      = $null
    PowerShell = $null
    Handle     = $null
    Confirm    = $null
    Toasts     = New-Object System.Collections.ArrayList
    DriveProbe = @()            # ultima lista de unidades vista (hot-plug)
    DriveTimer = $null
    Lib        = @()            # jogos encontrados na unidade (biblioteca)
    LibLetter  = $null          # unidade varrida por ultimo
    LibReport  = $null
    LibScan    = $null          # runspace da varredura em andamento
    LibTimer   = $null
    LibView    = 'opl'          # aba visivel: opl | library
    LibFilter  = 'all'          # filtro da biblioteca: all | installed | elsewhere | pending | other
    LibCounts  = $null          # { all, installed, elsewhere, pending, other } da última varredura
    InstalledMap = @{}          # serial -> letra da unidade onde o jogo já está instalado
    AutoInstall = $true         # soltar o jogo já inicia a instalação
    Extract    = $null          # extração de .zip/.rar/.7z em andamento
    Info       = $null          # busca da ficha do jogo (metadados) em andamento
    ExtractQueue = New-Object System.Collections.ArrayList
    TempRoots  = New-Object System.Collections.ArrayList
    ResultUntil = [datetime]::MinValue   # mantém o resultado da cópia na barra por alguns segundos
    Sound      = $true          # sons da interface (preferência do usuário)
    Muted      = $false         # silêncio forçado (testes / EASYROMS_MUTE)
    Snd        = @{}            # nome -> SoundPlayer
    HoverKey   = $null          # último elemento que recebeu hover (evita som repetido)
    HoverAt    = [datetime]::MinValue
    Selected   = @{}            # serial (ou nome do ISO) -> $true nos cards marcados
    LastPick   = $null          # chave do último card clicado (âncora do Shift+clique)
    CardChecks = @{}            # chave do jogo -> CheckBox do card
    CardBorders = @{}           # chave do jogo -> Border (realce) do card
    LibSel     = @{}            # chave de linha da biblioteca -> $true (instalação em lote)
}

$BRUSH = @{}
function Br([string]$hex) {
    if (-not $BRUSH.ContainsKey($hex)) {
        $BRUSH[$hex] = [Windows.Media.BrushConverter]::new().ConvertFromString($hex)
    }
    return $BRUSH[$hex]
}

# ---------------------------------------------------------------- sons
# Sons próprios, sintetizados por tools\New-Sounds.ps1. Nada de áudio da Sony:
# são tons curtos no espírito do console, livres de direitos.

$soundDir = Join-Path $PSScriptRoot 'sounds'
$settingsPath = $(if ($env:EASYROMS_SETTINGS) {
        $env:EASYROMS_SETTINGS
    } else {
        Join-Path (Join-Path $env:LOCALAPPDATA 'EasyRomsToOPL') 'settings.json'
    })

function Initialize-Sounds {
    $mute = [bool]$env:EASYROMS_MUTE
    if (-not (Test-Path -LiteralPath $soundDir)) { $S.Sound = $false; return }

    foreach ($n in @('hover', 'click', 'boot', 'success', 'error', 'connect', 'disconnect')) {
        $p = Join-Path $soundDir ($n + '.wav')
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $pl = New-Object System.Media.SoundPlayer $p
            $pl.Load()
            $S.Snd[$n] = $pl
        } catch { }
    }
    if ($S.Snd.Count -eq 0) { $S.Sound = $false }
    if ($mute) { $S.Muted = $true; $S.Sound = $false }
}

function Play-Sound {
    param([string]$Name)

    if (-not $S.Sound -or $S.Muted) { return }
    $p = $S.Snd[$Name]
    if ($p) { try { $p.Play() } catch { } }
}

function Load-UiSettings {
    try {
        if (Test-Path -LiteralPath $settingsPath) {
            $cfg = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $cfg.sound) { $S.Sound = [bool]$cfg.sound }
        }
    } catch { }
}

function Save-UiSettings {
    try {
        $dir = Split-Path -Parent $settingsPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        @{ sound = [bool]$S.Sound } | ConvertTo-Json -Compress | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    } catch { }
}

function Get-HoverTarget {
    <# Sobe do elemento sob o mouse até achar algo clicável (botão, chip, linha, link). #>
    param($Node)

    $n = $Node
    for ($i = 0; $i -lt 8 -and $null -ne $n; $i++) {
        if ($n -is [Windows.Controls.Primitives.ButtonBase]) { return $n }
        if ($n -is [Windows.FrameworkElement] -and $n.Cursor -and $n.Cursor.ToString() -eq 'Hand') { return $n }
        if ($n -is [Windows.FrameworkContentElement]) { $n = $n.Parent; continue }
        if ($n -is [Windows.Media.Visual]) { $n = [Windows.Media.VisualTreeHelper]::GetParent($n); continue }
        break
    }
    return $null
}

Load-UiSettings
Initialize-Sounds

$ui.BtnSound.IsChecked = [bool]$S.Sound
$ui.BtnSound.Content = $(if ($S.Sound) { 'SOM: ON' } else { 'SOM: OFF' })

# Um handler só para a janela inteira: hover e clique valem para os controles
# fixos e para os que são criados a cada varredura (chips, linhas, botões).
[void]$win.AddHandler([Windows.UIElement]::MouseEnterEvent, [Windows.Input.MouseEventHandler]{
        param($sender, $e)

        if (-not $S.Sound) { return }
        $t = Get-HoverTarget $e.OriginalSource
        if ($null -eq $t) { return }

        $now = Get-Date
        if ($t -eq $S.HoverKey -and ($now - $S.HoverAt).TotalMilliseconds -lt 150) { return }
        $S.HoverKey = $t
        $S.HoverAt = $now
        Play-Sound 'hover'
    }, $true)

[void]$win.AddHandler([Windows.UIElement]::MouseLeftButtonUpEvent, [Windows.Input.MouseButtonEventHandler]{
        param($sender, $e)

        if (-not $S.Sound) { return }
        if (Get-HoverTarget $e.OriginalSource) { Play-Sound 'click' }
    }, $true)

# ---------------------------------------------------------------- glossário

function Add-HelpSection {
    param($Panel, [string]$Title)

    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Title
    $t.Foreground = Br '#50FA7B'
    $t.FontSize = 10
    $t.FontWeight = 'Bold'
    $t.Margin = New-Object Windows.Thickness(0, 14, 0, 8)
    [void]$Panel.Children.Add($t)
}

function Add-HelpRow {
    param($Panel, [string]$Term, [string]$Text, [string]$Color = '#8BE9FD')

    $tb = New-Object Windows.Controls.TextBlock
    $tb.TextWrapping = 'Wrap'
    $tb.Margin = New-Object Windows.Thickness(0, 0, 0, 7)
    $tb.LineHeight = 18

    $r1 = New-Object Windows.Documents.Run($Term)
    $r1.Foreground = Br $Color
    $r1.FontWeight = 'Bold'
    $r2 = New-Object Windows.Documents.Run('  ' + $Text)
    $r2.Foreground = Br '#AAAAAA'

    [void]$tb.Inlines.Add($r1)
    [void]$tb.Inlines.Add($r2)
    [void]$Panel.Children.Add($tb)
}

function Render-Help {
    $p = $ui.HelpPanel
    $p.Children.Clear()

    Add-HelpSection $p 'FORMATOS DE JOGO'
    Add-HelpRow $p 'ISO' 'imagem do disco do jogo (PS1, PS2, GameCube…). É o arquivo que você arrasta para a janela.'
    Add-HelpRow $p 'ul.*' 'formato do OPL USB: o ISO é cortado em pedaços de 1 GiB (ul.CRC.SERIAL.00, .01, .02…). O FAT32 não aceita arquivo maior que 4 GB, então o console lê em partes. É o que o INSTALAR grava.'
    Add-HelpRow $p 'ul.cfg' 'índice do OPL: 64 bytes por jogo (nome, serial, número de pedaços, mídia e CRC). Sem ele o jogo não aparece no menu do console.'
    Add-HelpRow $p 'DVD\' 'pasta com o ISO inteiro, sem dividir. O OPL lê direto — prático para jogos pequenos; não precisa de ul.cfg.'
    Add-HelpRow $p 'ZIP / RAR / 7Z' 'jogo compactado. O app lê só o índice para listar e extrai na hora de instalar — nada é descompactado só para mostrar a lista.'
    Add-HelpRow $p 'CUE + BIN' 'par de um jogo de PS1 (o .cue é a capa que aponta para os dados). O mesmo vale para CCD+IMG e MDS+MDF. O app mostra uma linha só, sem duplicar.'
    Add-HelpRow $p 'CHD' 'imagem comprimida (Compressed Hunks of Data), criada para o MAME e usada por emuladores para encolher ISOs de DVD/CD. Não é formato do OPL: para rodar no PS2 precisa virar ISO antes.'
    Add-HelpRow $p 'ELF' 'executável nativo do PS2 (homebrew). Não é imagem de jogo; roda a partir do memory card, HD ou rede — não é instalado pelo app.'

    Add-HelpSection $p 'COLUNAS DA LISTA'
    Add-HelpRow $p 'MODO' 'mídia original do jogo, gravada no ul.cfg: DVD (jogo em DVD) ou CD (jogo em CD). O OPL usa isso para montar a imagem. Em DVD\ a coluna mostra ISO.'
    Add-HelpRow $p 'PARTES' 'em quantos pedaços de 1 GiB o jogo foi dividido.'
    Add-HelpRow $p 'CRC' 'assinatura que o OPL calcula a partir do nome. Se não bater, o jogo aparece no menu e não abre.'
    Add-HelpRow $p 'SERIAL' 'código do jogo (ex.: SLUS_215.97), lido do SYSTEM.CNF dentro do ISO.'
    Add-HelpRow $p 'TAMANHO' 'tamanho do arquivo na unidade.'

    Add-HelpSection $p 'STATUS DA BIBLIOTECA'
    Add-HelpRow $p 'INSTALADO' 'já está nesta unidade no formato que o OPL lê (ul.* ou DVD\).' '#50FA7B'
    Add-HelpRow $p 'JÁ NO OPL' 'este arquivo é uma cópia de um jogo que já está em ul.* (mesmo serial). Não precisa instalar de novo.' '#50FA7B'
    Add-HelpRow $p 'JÁ NO PENDRIVE' 'o jogo já está instalado em OUTRA unidade (ex.: F:). Também não precisa instalar de novo.' '#F1FA8C'
    Add-HelpRow $p 'INSTALAR' 'jogo de PS2 que ainda não está em lugar nenhum. O clique manda para a fila de instalação.' '#8BE9FD'
    Add-HelpRow $p 'OUTROS' 'PS1, SNES, N64… o OPL executa só PS2; ficam na lista para consulta.' '#666666'

    Add-HelpSection $p 'O QUE O APP IGNORA'
    Add-HelpRow $p 'ARQUIVOS QUE NÃO SÃO JOGO' 'README.md, .txt, .nfo, saves pequenos e qualquer arquivo com extensão de jogo mas conteúdo de texto ficam de fora. O app confere tamanho e conteúdo, não só o nome.' '#FFB86C'
    Add-HelpRow $p 'COMPACTADO SEM JOGO' 'um .zip/.rar/.7z que não tem jogo dentro — ou que o app não consegue abrir (senha, corrompido, driver, programa) — não entra na lista. Só aparece compactado que dá para conferir que é jogo.' '#FFB86C'
    Add-HelpRow $p 'PASTAS DO SISTEMA' '$RECYCLE.BIN, System Volume Information, .git, node_modules, ART, CFG, CHT, LNG, THM, VMC.' '#FFB86C'

    Add-HelpSection $p 'PLATAFORMAS'
    Add-HelpRow $p 'OPL' 'Open PS2 Loader: o programa que roda no PS2 e lê os jogos do pendrive. Ele executa apenas jogos de PlayStation 2.'
    Add-HelpRow $p 'PS1, SNES, N64, GBA, NDS, GC/WII, MEGA, MASTER, NES, PSP, DC' 'aparecem na biblioteca para você saber o que tem na unidade; o OPL não executa esses formatos.'

    Add-HelpSection $p 'SONS'
    Add-HelpRow $p 'SOM: ON / OFF' 'liga e desliga os sons de hover, clique, conexão e fim de instalação. São tons sintetizados pelo próprio app — nenhum áudio da Sony é usado. A escolha fica salva para a próxima vez.'
}

function Show-Help {
    if ($ui.HelpPanel.Children.Count -eq 0) { Render-Help }
    $ui.HelpOverlay.Visibility = [Windows.Visibility]::Visible
}

function Hide-Help {
    $ui.HelpOverlay.Visibility = [Windows.Visibility]::Collapsed
}

# ---------------------------------------------------------------- helpers de UI

function Set-Status {
    param([string]$Text, [string]$Color = '#666666')
    $ui.StatusText.Text = $Text.ToUpper()
    $ui.BusyDot.Fill = Br $Color
}

function Add-Log {
    param([string]$Message, [string]$Level = 'info')

    $colors = @{ info = '#CCCCCC'; ok = '#50FA7B'; warn = '#F1FA8C'; error = '#FF5555'; dim = '#666666' }
    $marks = @{ info = '»'; ok = '✓'; warn = '!'; error = '✕'; dim = '·' }
    $color = $colors[$Level]; if (-not $color) { $color = '#CCCCCC' }
    $mark = $marks[$Level]; if (-not $mark) { $mark = '»' }

    $para = New-Object Windows.Documents.Paragraph
    $para.Margin = New-Object Windows.Thickness(0, 0, 0, 2)

    $time = New-Object Windows.Documents.Run(('[{0}] ' -f (Get-Date).ToString('HH:mm:ss')))
    $time.Foreground = Br '#3A3A3A'
    [void]$para.Inlines.Add($time)

    $tag = New-Object Windows.Documents.Run(($mark + ' '))
    $tag.Foreground = Br $color
    $tag.FontWeight = 'Bold'
    [void]$para.Inlines.Add($tag)

    $body = New-Object Windows.Documents.Run($Message)
    $body.Foreground = Br $color
    [void]$para.Inlines.Add($body)

    [void]$ui.LogBox.Document.Blocks.Add($para)
    $ui.LogBox.ScrollToEnd()
}

function Show-Toast {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Level = 'info'
    )

    $colors = @{ info = '#8BE9FD'; ok = '#50FA7B'; warn = '#F1FA8C'; error = '#FF5555' }
    $icons = @{ info = '›'; ok = '✓'; warn = '!'; error = '✕' }
    $color = $colors[$Level]; if (-not $color) { $color = '#8BE9FD' }

    $border = New-Object Windows.Controls.Border
    $border.Background = Br '#0A0A0A'
    $border.BorderBrush = Br $color
    $border.BorderThickness = New-Object Windows.Thickness(1, 1, 1, 1)
    $border.Padding = New-Object Windows.Thickness(10)
    $border.Margin = New-Object Windows.Thickness(0, 0, 0, 8)

    $grid = New-Object Windows.Controls.Grid
    $c1 = New-Object Windows.Controls.ColumnDefinition
    $c1.Width = New-Object Windows.GridLength(4)
    $c2 = New-Object Windows.Controls.ColumnDefinition
    $c2.Width = New-Object Windows.GridLength(1, 'Star')
    $c3 = New-Object Windows.Controls.ColumnDefinition
    $c3.Width = New-Object Windows.GridLength(20)
    [void]$grid.ColumnDefinitions.Add($c1)
    [void]$grid.ColumnDefinitions.Add($c2)
    [void]$grid.ColumnDefinitions.Add($c3)

    $bar = New-Object Windows.Controls.Border
    $bar.Background = Br $color
    $bar.Margin = New-Object Windows.Thickness(0, 0, 8, 0)
    [Windows.Controls.Grid]::SetColumn($bar, 0)
    [void]$grid.Children.Add($bar)

    $stack = New-Object Windows.Controls.StackPanel
    [Windows.Controls.Grid]::SetColumn($stack, 1)
    $t1 = New-Object Windows.Controls.TextBlock
    $t1.Text = ($icons[$Level] + ' ' + $Title).ToUpper()
    $t1.Foreground = Br $color
    $t1.FontWeight = 'Bold'
    $t1.FontSize = 10
    [void]$stack.Children.Add($t1)
    if ($Message) {
        $t2 = New-Object Windows.Controls.TextBlock
        $t2.Text = $Message
        $t2.Foreground = Br '#999999'
        $t2.FontSize = 11
        $t2.TextWrapping = 'Wrap'
        $t2.Margin = New-Object Windows.Thickness(0, 4, 0, 0)
        [void]$stack.Children.Add($t2)
    }
    [void]$grid.Children.Add($stack)

    $close = New-Object Windows.Controls.TextBlock
    $close.Text = '✕'
    $close.Foreground = Br '#666666'
    $close.Cursor = 'Hand'
    $close.HorizontalAlignment = 'Right'
    $close.VerticalAlignment = 'Top'
    [Windows.Controls.Grid]::SetColumn($close, 2)
    [void]$grid.Children.Add($close)

    $border.Child = $grid
    [void]$ui.Toasts.Children.Add($border)
    [void]$S.Toasts.Add($border)

    # GetNewClosure: o handler roda depois que esta função terminou; sem isso
    # $border seria $null e o aviso nunca sairia da tela.
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(6)
    $timer.Add_Tick({
        param($sender, $e)
        $sender.Stop()
        if ($border.Parent) { [void]$ui.Toasts.Children.Remove($border) }
        [void]$S.Toasts.Remove($border)
    }.GetNewClosure())
    $close.Add_MouseLeftButtonUp({
        param($sender, $e)
        if ($border.Parent) { [void]$ui.Toasts.Children.Remove($border) }
        [void]$S.Toasts.Remove($border)
    }.GetNewClosure())
    $timer.Start()
}

function Show-Confirm {
    param(
        [string]$Title,
        [string]$Text,
        [string]$YesLabel = 'CONFIRMAR',
        [scriptblock]$OnYes
    )
    $ui.ConfirmTitle.Text = $Title.ToUpper()
    $ui.ConfirmText.Text = $Text
    $ui.BtnYesConfirm.Content = $YesLabel
    $S.Confirm = $OnYes
    $ui.Overlay.Visibility = 'Visible'
}

function Hide-Confirm {
    $ui.Overlay.Visibility = 'Collapsed'
    $S.Confirm = $null
}

# ---------------------------------------------------------------- ficha do jogo

function New-InfoLine {
    param(
        [string]$Icon,
        [string]$Text,
        [string]$Color = '#E8E8E8',
        [bool]$Strong = $false,
        [double]$Size = 12
    )
    $row = New-Object Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.Margin = New-Object Windows.Thickness(0, 0, 0, 6)

    $ic = New-Object Windows.Controls.TextBlock
    $ic.Text = $Icon
    $ic.Width = 26
    $ic.VerticalAlignment = 'Top'
    $ic.TextWrapping = 'NoWrap'
    [void]$row.Children.Add($ic)

    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.TextWrapping = 'Wrap'
    $tb.Foreground = Br $Color
    $tb.FontSize = $Size
    if ($Strong) { $tb.FontWeight = 'Bold' }
    [void]$row.Children.Add($tb)

    return $row
}

function Clear-GameInfo {
    $ui.InfoPanel.Children.Clear()
}

function Add-GameInfoLocal {
    <#  O que o app já sabe, sem internet: serial, mídia, partes, formato.  #>
    param($Game)

    $title = if ($Game.Nome) { $Game.Nome } else { 'Jogo' }
    $ui.InfoTitle.Text = ('FICHA — ' + $title.ToUpper())
    [void]$ui.InfoPanel.Children.Add((New-InfoLine '🎮' $title '#8BE9FD' $true 15))

    if ($Game.Serial) { [void]$ui.InfoPanel.Children.Add((New-InfoLine '🔢' ('Serial: ' + $Game.Serial) '#C8C8C8')) }
    if ($Game.Modo) { [void]$ui.InfoPanel.Children.Add((New-InfoLine '📀' ('Mídia: ' + $Game.Modo) '#C8C8C8')) }
    if ($Game.Partes) { [void]$ui.InfoPanel.Children.Add((New-InfoLine '🔗' ('Partes: ' + $Game.Partes) '#C8C8C8')) }
    if ($Game.Crc) { [void]$ui.InfoPanel.Children.Add((New-InfoLine '🔐' ('CRC: ' + $Game.Crc) '#C8C8C8')) }
    if ($Game.Tipo) { [void]$ui.InfoPanel.Children.Add((New-InfoLine '📁' ('Formato: ' + $Game.Tipo) '#C8C8C8')) }
}

function Show-GameInfo {
    <#
        Abre a ficha do jogo. Mostra o que é local na hora e, se houver
        credenciais do IGDB, busca o resto em segundo plano (não trava a janela).
    #>
    param($Game)

    Clear-GameInfo
    Add-GameInfoLocal -Game $Game

    $hasOnline = $false
    try { $hasOnline = Test-GameInfoOnline } catch { $hasOnline = $false }

    if (-not $hasOnline) {
        if (-not (Test-Path -LiteralPath (Join-Path (Get-GameInfoDataDir) 'games.json'))) {
            [void]$ui.InfoPanel.Children.Add((New-InfoLine '💡' 'Sem ficha extra. Para puxar sinopse e data de lançamento, configure o IGDB (veja docs) ou preencha data\games.json.' '#F1FA8C' $false 11))
        }
        $ui.InfoStatus.Text = 'LOCAL'
        $ui.InfoOverlay.Visibility = 'Visible'
        return
    }

    # 1) tenta local/cache primeiro — se veio, nem vai na internet
    $local = $null
    try { $local = Get-GameInfo -Serial $Game.Serial -Nome $Game.Nome -Offline } catch { }
    if ($local) {
        Render-GameInfoExtra $local
        $ui.InfoStatus.Text = 'PRONTO'
        $ui.InfoOverlay.Visibility = 'Visible'
        return
    }

    # 2) busca online em segundo plano
    $ui.InfoStatus.Text = 'BUSCANDO...'
    $ui.InfoOverlay.Visibility = 'Visible'

    $sync = [hashtable]::Synchronized(@{
            Serial = [string]$Game.Serial
            Nome   = [string]$Game.Nome
            Info   = $null
            Done   = $false
        })

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
            param($Sync, $InfoPath)
            . $InfoPath
            try {
                $Sync.Info = Get-GameInfo -Serial $Sync.Serial -Nome $Sync.Nome
            } catch { $Sync.Info = $null }
            $Sync.Done = $true
        })
    [void]$ps.AddParameter('Sync', $sync)
    [void]$ps.AddParameter('InfoPath', (Join-Path $repoRoot 'lib\GameInfo.ps1'))

    $S.Info = [pscustomobject]@{
        Sync       = $sync
        PowerShell = $ps
        Handle     = $ps.BeginInvoke()
        Timer      = $null
    }

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
            $i = $S.Info
            if (-not $i -or -not $i.Sync.Done) { return }
            $i.Timer.Stop()
            try { $i.PowerShell.Dispose() } catch { }
            $S.Info = $null
            if ($i.Sync.Info) {
                Render-GameInfoExtra $i.Sync.Info
                $ui.InfoStatus.Text = 'PRONTO'
            } else {
                $ui.InfoStatus.Text = 'SEM FICHA'
                [void]$ui.InfoPanel.Children.Add((New-InfoLine '🔎' 'Não achei essa ficha online. Confira o serial ou tente de novo.' '#F1FA8C' $false 11))
            }
        })
    $S.Info.Timer = $timer
    $timer.Start()
}

function Render-GameInfoExtra {
    param($Info)
    if (-not $Info) { return }

    if ($Info.Titulo -and $ui.InfoTitle) {
        $ui.InfoTitle.Text = ('FICHA — ' + ([string]$Info.Titulo).ToUpper())
    }

    if ($Info.Lancamento) { [void]$ui.InfoPanel.Children.Add((New-InfoLine '📅' ('Lançamento: ' + $Info.Lancamento) '#E8E8E8')) }
    if ($Info.Genero) { [void]$ui.InfoPanel.Children.Add((New-InfoLine '🏷️' ('Gênero: ' + $Info.Genero) '#E8E8E8')) }
    if ($Info.Desenvolvedora) { [void]$ui.InfoPanel.Children.Add((New-InfoLine '🏢' ('Desenvolvedora: ' + $Info.Desenvolvedora) '#E8E8E8')) }
    if ($Info.Publicadora) { [void]$ui.InfoPanel.Children.Add((New-InfoLine '📢' ('Publicadora: ' + $Info.Publicadora) '#E8E8E8')) }
    if ($Info.Nota) { [void]$ui.InfoPanel.Children.Add((New-InfoLine '⭐' ('Nota: ' + $Info.Nota) '#E8E8E8')) }
    if ($Info.Sinopse) {
        [void]$ui.InfoPanel.Children.Add((New-InfoLine '📝' '' '#C8C8C8'))
        $s = New-Object Windows.Controls.TextBlock
        $s.Text = [string]$Info.Sinopse
        $s.TextWrapping = 'Wrap'
        $s.Foreground = Br '#C8C8C8'
        $s.Margin = New-Object Windows.Thickness(26, 0, 0, 8)
        [void]$ui.InfoPanel.Children.Add($s)
    }
    if ($Info.Origem) { [void]$ui.InfoPanel.Children.Add((New-InfoLine '🌐' ('Fonte: ' + $Info.Origem) '#6272A4' $false 10)) }
}

# ---------------------------------------------------------------- drives

function Get-DiskHardware {
    <#
        Descobre o que é cada letra: pendrive, cartão SD, SSD, HD ou disco
        externo — com modelo e barramento.

        Fonte: Win32_DiskDrive (rápido, ~160 ms) + MSFT_PhysicalDisk, que é
        quem diz se a mídia é SSD ou HD. Roda sem administrador e é só leitura.
        Devolve uma tabela letra -> objeto.
    #>
    $map = @{}

    try {
        $disks = @{}
        foreach ($d in @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop)) {
            $disks[[int]$d.Index] = $d
        }

        # disco -> partição -> letra (o DeviceID é o que liga as duas tabelas)
        $partDisk = @{}
        foreach ($a in @(Get-CimInstance -ClassName Win32_DiskDriveToDiskPartition -ErrorAction SilentlyContinue)) {
            $m = [regex]::Match([string]$a.Antecedent.DeviceID, 'PHYSICALDRIVE(\d+)$')
            if ($m.Success) { $partDisk[[string]$a.Dependent.DeviceID] = [int]$m.Groups[1].Value }
        }

        $media = @{}
        try {
            foreach ($p in @(Get-CimInstance -Namespace 'root\Microsoft\Windows\Storage' `
                    -ClassName MSFT_PhysicalDisk -ErrorAction Stop)) {
                $media[[int]$p.DeviceId] = $p
            }
        } catch { }

        foreach ($a in @(Get-CimInstance -ClassName Win32_LogicalDiskToPartition -ErrorAction SilentlyContinue)) {
            $letter = ([string]$a.Dependent.DeviceID).TrimEnd(':').ToUpperInvariant()
            if ($letter.Length -ne 1) { continue }

            $index = $partDisk[[string]$a.Antecedent.DeviceID]
            if ($null -eq $index) { continue }

            $d = $disks[$index]
            $phys = $media[$index]

            $model = ''
            $busUsb = $false
            $removable = $false
            if ($d) {
                $model = ([string]$d.Model).Trim()
                $model = $model -replace '^USB\s+', '' -replace '\s+SCSI Disk Device$', ''
                $removable = ([string]$d.MediaType -match 'Removable')
                $busUsb = ([string]$d.InterfaceType -match 'USB')
            }

            $mediaType = 0
            $busType = 0
            if ($phys) {
                $mediaType = [int]$phys.MediaType
                $busType = [int]$phys.BusType
                if (-not $model) { $model = ([string]$phys.FriendlyName).Trim() }
            }

            $kind = 'UNIDADE'
            if ($removable) {
                $kind = $(if ($busType -in 12, 13) { 'CARTÃO SD' } else { 'PENDRIVE' })
            } elseif ($busType -eq 7 -or $busUsb) {
                $kind = switch ($mediaType) { 4 { 'SSD EXTERNO' } 3 { 'HD EXTERNO' } default { 'HD/SSD USB' } }
            } else {
                $kind = switch ($mediaType) { 4 { 'SSD' } 3 { 'HD' } default { 'DISCO FIXO' } }
            }

            $map[$letter] = [pscustomobject]@{
                Kind  = $kind
                Model = $model
                Bus   = $(switch ($busType) { 7 { 'USB' } 11 { 'SATA' } 17 { 'NVMe' } 12 { 'SD' } 13 { 'MMC' } default { '' } })
                Media = $(switch ($mediaType) { 3 { 'HD' } 4 { 'SSD' } 5 { 'SCM' } default { '' } })
            }
        }
    } catch { }

    return $map
}

function Update-Hardware {
    <# Reconsulta o hardware só quando a lista de letras mudou (hot-plug). #>
    try { $S.Hw = Get-DiskHardware } catch { $S.Hw = @{} }
}

function Get-DriveList {
    $list = New-Object System.Collections.ArrayList
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady) { continue }
        if ($d.DriveType -ne 'Removable' -and $d.DriveType -ne 'Fixed') { continue }
        $letter = $d.Name.Substring(0, 1)
        if ($letter -eq $env:SystemDrive.Substring(0, 1)) { continue }

        $hw = $S.Hw[$letter]
        if (-not $hw) { $hw = [pscustomobject]@{ Kind = $(if ($d.DriveType -eq 'Removable') { 'PENDRIVE' } else { 'DISCO FIXO' }); Model = ''; Bus = ''; Media = '' } }

        [void]$list.Add([pscustomobject]@{
            Letter = $letter
            Root   = $d.Name
            Label  = $d.VolumeLabel
            Format = $d.DriveFormat
            Free   = [double]$d.AvailableFreeSpace
            Total  = [double]$d.TotalSize
            Type   = [string]$d.DriveType
            Kind   = $hw.Kind
            Model  = $hw.Model
            Bus    = $hw.Bus
        })
    }
    return @($list | Sort-Object @{ e = { $_.Type -ne 'Removable' } }, Letter)
}

function Update-DriveChips {
    $ui.DrivesPanel.Children.Clear()
    $S.Drives = Get-DriveList
    $ui.DriveCount.Text = ('{0} UNIDADE(S)' -f $S.Drives.Count).ToUpper()

    if ($S.Drives.Count -eq 0) {
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = 'NENHUM PENDRIVE DETECTADO'
        $t.Foreground = Br '#FF5555'
        $t.FontSize = 10
        [void]$ui.DrivesPanel.Children.Add($t)
        $S.Drive = $null
        return
    }

    # A letra ainda existe no sistema? (não exige estar "pronta": um pendrive
    # ocupado pode falhar na leitura por um instante e não deve perder a seleção)
    $stillThere = $false
    if ($S.Drive) {
        try {
            foreach ($d in [IO.DriveInfo]::GetDrives()) {
                if ($d.Name.Substring(0, 1) -eq $S.Drive) { $stillThere = $true; break }
            }
        } catch { }
    }

    if (-not $S.Drive -or -not $stillThere) {
        $preferred = $S.Drives | Where-Object { $_.Type -eq 'Removable' -and $_.Format -eq 'FAT32' } | Select-Object -First 1
        if (-not $preferred) { $preferred = $S.Drives | Where-Object { $_.Type -eq 'Removable' } | Select-Object -First 1 }
        if (-not $preferred) { $preferred = $S.Drives[0] }
        $S.Drive = $preferred.Letter
    }

    foreach ($d in $S.Drives) {
        $chip = New-Object Windows.Controls.Primitives.ToggleButton
        $chip.Style = $win.FindResource('Chip')
        $chip.Tag = $d.Letter
        $chip.IsChecked = ($d.Letter -eq $S.Drive)
        $chip.Content = ('{0}: {1}' -f $d.Letter, $d.Kind)
        $chip.ToolTip = ('{0}: {1}`n{2}{3}`n{4} livres de {5}' -f
            $d.Letter, $d.Kind,
            $(if ($d.Format) { $d.Format + ' · ' } else { '' }), $d.Label,
            (Format-Size $d.Free), (Format-Size $d.Total))
        $chip.Add_Click({
            param($sender, $e)
            $S.Drive = $sender.Tag
            Update-DriveChips
            Update-Space
            Load-Games
            # Clicou na unidade: mostra direto os jogos que existem nela.
            Set-GamesView 'library'
            Refresh-Library
        })
        [void]$ui.DrivesPanel.Children.Add($chip)
    }
}

function Get-DriveProbe {
    <#
        Lista "letra|tipo" de cada unidade, SEM tocar no disco: IsReady/VolumeLabel
        podem travar em pendrive com defeito. Serve só para saber se mudou algo.
    #>
    $probe = New-Object System.Collections.ArrayList
    try {
        foreach ($d in [IO.DriveInfo]::GetDrives()) {
            try {
                if ($d.DriveType -ne 'Removable' -and $d.DriveType -ne 'Fixed') { continue }
                $letter = $d.Name.Substring(0, 1)
                if ($letter -eq $env:SystemDrive.Substring(0, 1)) { continue }
                [void]$probe.Add(('{0}|{1}' -f $letter, $d.DriveType))
            } catch { }
        }
    } catch { }
    return @($probe | Sort-Object)
}

function Sync-Drives {
    <#
        Chamado a cada segundo pelo timer. Compara só a lista de unidades:
        se nada entrou/saiu, não faz nada (barato). Quando muda, reconstrói os
        chips e recarrega os jogos — é isso que faz o pendrive aparecer/sumir
        em tempo real com o app aberto.
    #>
    if (-not $win.IsVisible) { return }
    if ($S.Busy) { return }   # não mexe na lista no meio de uma cópia

    $now = @(Get-DriveProbe)
    if (($now -join ';') -eq (@($S.DriveProbe) -join ';')) {
        # Nada entrou/saiu: só atualiza o espaço (usado/livre) em tempo real.
        if (-not $S.Busy) { Update-Space }
        return
    }
    $S.DriveProbe = $now

    $before = @($S.Drives | ForEach-Object { $_.Letter })
    $selected = $S.Drive

    Update-Hardware
    Update-DriveChips
    Load-Games
    Update-Space
    Refresh-Library

    $after = @($S.Drives | ForEach-Object { $_.Letter })
    $added = @($after | Where-Object { $before -notcontains $_ })
    $removed = @($before | Where-Object { $after -notcontains $_ })

    foreach ($l in $added) { Add-Log ("Unidade conectada: {0}:" -f $l) 'ok' }
    foreach ($l in $removed) { Add-Log ("Unidade removida: {0}:" -f $l) 'warn' }
    if ($added.Count -gt 0) { Play-Sound 'connect' }
    if ($removed.Count -gt 0) { Play-Sound 'disconnect' }

    if ($removed -contains $selected) {
        if ($S.Drive) {
            Show-Toast 'Pendrive removido' ("{0}: saiu. Selecionado agora: {1}:" -f $selected, $S.Drive) 'warn'
            Set-Status ("PENDRIVE TROCADO · {0}:" -f $S.Drive) '#F1FA8C'
        } else {
            Show-Toast 'Pendrive removido' ("{0}: não está mais conectado." -f $selected) 'error'
            Set-Status 'SEM PENDRIVE' '#FF5555'
        }
    } elseif ($added.Count -gt 0) {
        $first = $S.Drives | Where-Object { $_.Letter -eq $added[0] } | Select-Object -First 1
        $label = if ($first -and $first.Label) { ' — ' + $first.Label } else { '' }
        Show-Toast 'Pendrive conectado' ("{0}:{1}" -f $added[0], $label) 'ok'
        if ($S.Drive) { Set-Status ("PRONTO · {0}:" -f $S.Drive) '#50FA7B' }

        # Soltou o jogo antes de plugar? Instala agora que a unidade apareceu.
        if ($S.Files.Count -gt 0) { Invoke-AutoInstall }
    }
}
function Update-Space {
    <#
        Nome do dispositivo (pendrive, SSD, HD...), espaço usado e livre.
        Chamado a cada segundo pelo timer: os números acompanham a cópia.
    #>
    $ui.StatGames.Text = ('{0} JOGO(S)' -f $S.Games.Count).ToUpper()

    if (-not $S.Drive) {
        $ui.DeviceName.Text = 'NENHUM DISPOSITIVO SELECIONADO'
        $ui.DeviceName.Foreground = Br '#666666'
        $ui.StatSpace.Text = '—'
        $ui.Bar.Value = 0
        $ui.BarPct.Text = ''
        return
    }

    $d = $S.Drives | Where-Object { $_.Letter -eq $S.Drive } | Select-Object -First 1
    $kind = if ($d) { $d.Kind } else { 'UNIDADE' }
    $fmt = if ($d) { $d.Format } else { '' }
    $label = if ($d) { $d.Label } else { '' }

    $parts = @("$($S.Drive): $kind")
    if ($fmt) { $parts += $fmt }
    if ($label) { $parts += $label }
    $ui.DeviceName.Text = ($parts -join ' · ')
    $ui.DeviceName.Foreground = Br '#8BE9FD'

    try {
        $di = New-Object IO.DriveInfo("$($S.Drive):\")
        $total = [double]$di.TotalSize
        $free = [double]$di.AvailableFreeSpace
        $used = [Math]::Max([double]0, ($total - $free))

        $ui.StatSpace.Text = ('USADO {0} DE {1} · LIVRE {2}' -f
            (Format-Size $used), (Format-Size $total), (Format-Size $free))

        if (-not $S.Busy -and (Get-Date) -ge $S.ResultUntil) {
            $pct = 0
            if ($total -gt 0) { $pct = [int][Math]::Round(100 * $used / $total) }
            $ui.Bar.Value = $pct
            $ui.BarPct.Text = ('{0}%' -f $pct)
            $ui.BarText.Text = 'USO DO DISPOSITIVO'
        }
    } catch {
        $ui.StatSpace.Text = 'ERRO AO LER A UNIDADE'
    }
}

# ---------------------------------------------------------------- arquivos

function Get-CleanGameName {
    <#
        Tira do nome do arquivo o que não deve aparecer no menu do OPL:
        o serial entre parênteses/colchetes e sufixos comuns de dump.
        "Medalha de Honra (SLUS_215.97)" -> "Medalha de Honra"
    #>
    param([string]$BaseName)

    $clean = $BaseName
    $clean = [regex]::Replace($clean, '\s*[\(\[]\s*[A-Z]{4}[_-]?\d{3}[\._]\d{2}\s*[\)\]]', '')
    $clean = [regex]::Replace($clean, '\s*[\(\[]\s*(USA|Europe|Japan|Brazil|NTSC|PAL|Korea|Asia|World)\b[^\)\]]*[\)\]]', '', 'IgnoreCase')
    $clean = [regex]::Replace($clean, '\s+', ' ').Trim(' ', '-', '_', '.')
    if (-not $clean) { $clean = $BaseName }
    return $clean
}

function Add-IsoFile {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path
        if ($item.Extension -notin '.iso', '.ISO') {
            Show-Toast 'Arquivo ignorado' (Split-Path $Path -Leaf) 'warn'
            return
        }
    } else {
        Show-Toast 'Arquivo não encontrado' $Path 'error'
        return
    }

    if ($S.Files | Where-Object { $_.Path -eq $item.FullName }) { return }

    $entry = [pscustomobject]@{
        Path   = $item.FullName
        Name   = $item.BaseName
        Clean  = Get-CleanGameName $item.BaseName
        Size   = [double]$item.Length
        Serial = $null
        Ver    = $null
        Valid  = $false
        Error  = $null
    }

    try {
        $info = Get-IsoInfo $item.FullName
        if (-not $info.IsPs2) {
            $entry.Error = 'não é um ISO de PS2 (sem SYSTEM.CNF / PLAYSTATION)'
        } else {
            $entry.Serial = $info.Serial
            $entry.Ver = $info.Ver
            $entry.Valid = $true
        }
    } catch {
        $entry.Error = $_.Exception.Message
    }

    [void]$S.Files.Add($entry)

    if ($entry.Valid) {
        Add-Log ("{0} · {1} · {2}" -f $entry.Clean, $entry.Serial, (Format-Size $entry.Size)) 'dim'
    }

    if ($S.Files.Count -eq 1) {
        $ui.NameBox.Text = ConvertTo-AsciiName $entry.Clean
    }
    if (-not $entry.Valid) {
        Show-Toast 'ISO inválido' ("{0}: {1}" -f $item.Name, $entry.Error) 'error'
    }
    Render-Files
}

function Get-FormatTooltip {
    param([string]$Extension)
    
    $ext = $Extension.ToLower()
    
    switch -Regex ($ext) {
        '^\.iso$' { return '📀 ISO - Imagem de disco de PlayStation 2 (raramente PS1). Cópia fiel do DVD/CD do jogo. É o formato que o app instala no pendrive: divide em ul.* e registra no ul.cfg.' }
        '^\.zip$' { return '🗜 ZIP - Arquivo compactado. O app abre e extrai o ISO (ou ul.*) de dentro dele para instalar. Suporta ZIP padrão e ZIP multipart (.z01, .z02...).' }
        '^\.rar$' { return '🗜 RAR - Arquivo compactado (WinRAR). O app abre e extrai o ISO de dentro dele para instalar.' }
        '^\.7z$' { return '🗜 7Z - Arquivo compactado (7-Zip). O app abre e extrai o ISO de dentro dele para instalar.' }
        '^\.ul\..*$' { return '🔗 UL.* - Formato do OPL USB. É o próprio ISO já dividido em pedaços de 1 GiB (limite do FAT32) e indexado no ul.cfg. Já está pronto para o console: não precisa reinstalar.' }
        '^\.bin$|^\.cue$|^\.img$|^\.ccd$|^\.mds$|^\.mdf$' { return '📼 BIN/CUE/IMG - Imagem de CD (PS1, Saturno, Mega-CD). O .bin guarda os dados do disco e o .cue/.ccd/.mds descreve as faixas. Fora do escopo do OPL USB, que usa ISO de PS2.' }
        '^\.chd$' { return '🗜 CHD - Compressed Hunks of Data. Formato de imagem comprimida criado para o MAME e usado por emuladores para encolher ISOs de DVD/CD. NÃO é uma imagem de CD avulsa nem um formato do OPL: para jogar no PS2 ele precisa ser reconvertido para ISO.' }
        '^\.elf$' { return '⚙️ ELF - Executável nativo do PlayStation 2 (também usado para homebrew/OPL). Não é uma imagem de jogo; roda a partir do MC, HD ou rede no console.' }
        '^\.gcm$|^\.gcz$' { return '🎮 GCM/GCZ - Imagem de disco de GameCube (.gcz é a versão comprimida). Não é do PS2 nem do OPL; roda em emuladores como o Dolphin.' }
        '^\.pbp$' { return '🎮 PBP - PlayStation Portable (PSP). Imagem compactada específica para PSP.' }
        '^\.nds$' { return '🎮 NDS - Nintendo DS. Jogo de DS que funciona em emuladores como DeSmuME.' }
        '^\.gba$' { return '🎮 GBA - Game Boy Advance. Jogo portátil da Nintendo.' }
        '^\.sfc$|^\.smc$' { return '🎮 SFC/SMC - Super Nintendo (SNES). Jogo clássico de 16-bit.' }
        '^\.n64$|^\.v64$|^\.z64$' { return '🎮 N64/V64/Z64 - Nintendo 64. Jogo de 64-bit da Nintendo.' }
        '^\.md$|^\.gen$' { return '🎮 MD/GEN - Sega Genesis/Mega Drive. Jogo clássico da Sega de 16-bit.' }
        '^\.nes$|^\.fds$' { return '🎮 NES/FDS - Nintendo Entertainment System. Jogo clássico de 8-bit.' }
        default { return "📄 $Extension - Tipo de arquivo não reconhecido automaticamente como jogo." }
    }
}

function Get-StatusTooltip {
    param([string]$Status)
    
    switch ($Status) {
        'OK' { return '✅ Arquivo válido - Pronto para instalar no OPL USB' }
        'JÁ' { return '📋 Jogo já está instalado - Este jogo já aparece no menu do OPL. Instalar novamente substituirá a cópia existente.' }
        'ERR' { return '❌ Arquivo inválido - ISO corrompido, formato não suportado ou ausência do SYSTEM.CNF necessário para identificar o jogo PS2.' }
        'INSTALADO' { return '✅ Já no OPL - Já aparece no menu do console e está pronto para jogar.' }
        'JÁ NO OPL' { return '📋 Cópia detectada - Este arquivo é uma cópia do mesmo jogo já instalado em ul.*.' }
        'JÁ NO PENDRIVE' { return '📋 Disponível em outra unidade - Já está instalado em outro pendrive, não precisa instalar novamente.' }
        'INSTALAR' { return '⬇️ Disponível para instalação - Clique para adicionar à fila de instalação no pendrive selecionado.' }
        default { return '📊 Status do jogo na biblioteca.' }
    }
}

function Get-PlatformTooltip {
    param([string]$Platform)
    
    switch ($Platform.ToUpper()) {
        'PS2' { return '🎮 PlayStation 2 - Executa no OPL. Jogos de PS2 podem ser instalados no pendrive.' }
        'PS1' { return '🎮 PlayStation 1 - Não executa no OPL. Apenas para consulta na biblioteca.' }
        'SNES' { return '🎮 Super Nintendo - Não executa no OPL. Apenas para consulta na biblioteca.' }
        'N64' { return '🎮 Nintendo 64 - Não executa no OPL. Apenas para consulta na biblioteca.' }
        'GBA' { return '🎮 Game Boy Advance - Não executa no OPL. Apenas para consulta na biblioteca.' }
        'NDS' { return '🎮 Nintendo DS - Não executa no OPL. Apenas para consulta na biblioteca.' }
        'GC' { return '🎮 GameCube - Não executa no OPL. Apenas para consulta na biblioteca.' }
        'MEGA' { return '🎮 Sega Mega Drive/Genesis - Não executa no OPL. Apenas para consulta na biblioteca.' }
        'MASTER' { return '🎮 Sega Master System - Não executa no OPL. Apenas para consulta na biblioteca.' }
        'NES' { return '🎮 Nintendo Entertainment System - Não executa no OPL. Apenas para consulta na biblioteca.' }
        'PSP' { return '🎮 PlayStation Portable - Não executa no OPL. Apenas para consulta na biblioteca.' }
        'DC' { return '🎮 Sega Dreamcast - Não executa no OPL. Apenas para consulta na biblioteca.' }
        default { return "🎮 $Platform - Plataforma de jogo na biblioteca." }
    }
}

function Render-Files {
    $ui.FilesPanel.Children.Clear()

    if ($S.Files.Count -eq 0) {
        $ui.FileCount.Text = 'NENHUM ARQUIVO'
        $ui.NameBox.IsEnabled = $true
        $ui.HintText.Text = 'Solte um jogo: o app grava no pendrive e atualiza o ul.cfg sozinho.'
        return
    }

    $installed = Get-InstalledSerials

    $ui.FileCount.Text = ('{0} ARQUIVO(S) · {1}' -f $S.Files.Count, (Format-Size (($S.Files | Measure-Object Size -Sum).Sum)))
    $ui.NameBox.IsEnabled = ($S.Files.Count -eq 1)

    $allThere = @($S.Files | Where-Object { -not ($_.Valid -and $_.Serial -and $installed.ContainsKey([string]$_.Serial)) }).Count -eq 0
    if ($allThere) {
        $ui.HintText.Text = 'Já está tudo no OPL — INSTALAR pergunta antes de substituir.'
    } elseif ($S.Files.Count -eq 1) {
        $ui.HintText.Text = 'O nome acima vai para o menu do OPL.'
    } else {
        $ui.HintText.Text = 'Vários jogos: cada um usa o próprio nome de arquivo no menu.'
    }

    foreach ($f in $S.Files) {
        $already = [bool]($f.Valid -and $f.Serial -and $installed.ContainsKey([string]$f.Serial))

        $border = New-Object Windows.Controls.Border
        $border.BorderBrush = Br '#1E1E1E'
        $border.BorderThickness = New-Object Windows.Thickness(0, 0, 0, 1)
        $border.Padding = New-Object Windows.Thickness(8, 7, 8, 7)
        $border.Background = Br '#000000'

        $grid = New-Object Windows.Controls.Grid
        foreach ($w in @('1', 'Auto')) {
            $c = New-Object Windows.Controls.ColumnDefinition
            if ($w -eq '1') { $c.Width = New-Object Windows.GridLength(1, 'Star') }
            [void]$grid.ColumnDefinitions.Add($c)
        }
        $c3 = New-Object Windows.Controls.ColumnDefinition
        $c3.Width = New-Object Windows.GridLength(22)
        [void]$grid.ColumnDefinitions.Add($c3)

        $stack = New-Object Windows.Controls.StackPanel
        $name = New-Object Windows.Controls.TextBlock
        $name.Text = $f.Name
        $name.Foreground = Br '#CCCCCC'
        $name.FontSize = 11
        $name.TextTrimming = 'CharacterEllipsis'
        [void]$stack.Children.Add($name)

        $meta = New-Object Windows.Controls.TextBlock
        $meta.FontSize = 10
        if ($f.Valid) {
            $meta.Text = ('{0} · {1} · {2}' -f $f.Serial, (Format-Size $f.Size), $f.Ver)
            if ($already) { $meta.Text += ' · JÁ NO OPL' }
            $meta.Foreground = Br '#666666'
        } else {
            $meta.Text = ('INVÁLIDO · ' + $f.Error)
            $meta.Foreground = Br '#FF5555'
        }
        $meta.TextTrimming = 'CharacterEllipsis'
        [void]$stack.Children.Add($meta)
        
        # Tooltip explicativo do formato do arquivo
        $formatTip = Get-FormatTooltip ([System.IO.Path]::GetExtension($f.Name))
        if ($formatTip) {
            $stack.ToolTip = $formatTip
        }
        
        [void]$grid.Children.Add($stack)

        $tag = New-Object Windows.Controls.TextBlock
        if (-not $f.Valid) {
            $tag.Text = 'ERR'
            $tag.Foreground = Br '#FF5555'
        } elseif ($already) {
            $tag.Text = 'JÁ'
            $tag.Foreground = Br '#F1FA8C'
        } else {
            $tag.Text = 'OK'
            $tag.Foreground = Br '#50FA7B'
        }
        $tag.FontSize = 9
        $tag.FontWeight = 'Bold'
        $tag.VerticalAlignment = 'Center'
        $tag.HorizontalAlignment = 'Right'
        $tag.Margin = New-Object Windows.Thickness(0, 0, 8, 0)
        $tag.ToolTip = Get-StatusTooltip $tag.Text
        [Windows.Controls.Grid]::SetColumn($tag, 1)
        [void]$grid.Children.Add($tag)

        $del = New-Object Windows.Controls.TextBlock
        $del.Text = '✕'
        $del.Foreground = Br '#666666'
        $del.Cursor = 'Hand'
        $del.VerticalAlignment = 'Center'
        $del.HorizontalAlignment = 'Right'
        $del.Tag = $f
        $del.Add_MouseLeftButtonUp({
            param($sender, $e)
            $S.Files.Remove($sender.Tag) | Out-Null
            Render-Files
        })
        [Windows.Controls.Grid]::SetColumn($del, 2)
        [void]$grid.Children.Add($del)

        $border.Child = $grid
        
        # Menu de contexto (clique direito)
        $border.Tag = $f
        $contextMenu = New-Object Windows.Controls.ContextMenu
        
        $itemInstall = New-Object Windows.Controls.MenuItem
        $itemInstall.Header = 'Instalar'
        $itemInstall.Tag = $f
        $itemInstall.Add_Click({
            param($sender, $e)
            $file = $sender.Tag
            if ($file.Valid -and $S.Drive) {
                Start-Install
            } elseif (-not $S.Drive) {
                Show-Toast 'Sem pendrive' 'Conecte o pendrive para instalar.' 'warn'
            }
        })
        [void]$contextMenu.Items.Add($itemInstall)
        
        $itemRemove = New-Object Windows.Controls.MenuItem
        $itemRemove.Header = 'Remover da lista'
        $itemRemove.Tag = $f
        $itemRemove.Add_Click({
            param($sender, $e)
            $S.Files.Remove($sender.Tag) | Out-Null
            Render-Files
        })
        [void]$contextMenu.Items.Add($itemRemove)
        
        $border.ContextMenu = $contextMenu
        
        # Duplo clique para instalar. Border não expõe MouseDoubleClick (é um
        # Decorator, não um Control), então escutamos o MouseLeftButtonDown
        # roteado e checamos ClickCount = 2.
        $border.AddHandler([Windows.Controls.Border]::MouseLeftButtonDownEvent, [Windows.Input.MouseButtonEventHandler]{
            param($sender, $e)
            if ($e.ClickCount -ne 2) { return }
            $file = $sender.Tag
            if ($file.Valid -and $S.Drive) {
                Start-Install
            }
        })

        [void]$ui.FilesPanel.Children.Add($border)
    }
}

# ---------------------------------------------------------------- arquivos compactados

$script:ExtractScript = @'
param($Sync)

$ErrorActionPreference = 'Stop'
try {
    New-Item -ItemType Directory -Force -Path $Sync.Dest | Out-Null

    switch ($Sync.Kind) {
        'zip' {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory($Sync.Archive, $Sync.Dest)
        }
        'unrar' {
            $argv = @('x', '-y', '-o+', $Sync.Archive, ($Sync.Dest + '\'))
            & $Sync.Exe @argv | Out-Null
            if ($LASTEXITCODE -ne 0) { throw ('UnRAR saiu com código {0}' -f $LASTEXITCODE) }
        }
        '7z' {
            $argv = @('x', '-y', ('-o' + $Sync.Dest), $Sync.Archive)
            & $Sync.Exe @argv | Out-Null
            if ($LASTEXITCODE -ne 0) { throw ('7-Zip saiu com código {0}' -f $LASTEXITCODE) }
        }
        'tar' {
            $argv = @('-xf', $Sync.Archive, '-C', $Sync.Dest)
            & $Sync.Exe @argv | Out-Null
            if ($LASTEXITCODE -ne 0) { throw ('tar saiu com código {0}' -f $LASTEXITCODE) }
        }
        default { throw ('Extrator desconhecido: ' + $Sync.Kind) }
    }

    $Sync.Isos = @(Get-ChildItem -LiteralPath $Sync.Dest -Recurse -File -Filter '*.iso' -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending | ForEach-Object { $_.FullName })
    $Sync.Ok = $true
} catch {
    $Sync.Error = $_.Exception.Message
} finally {
    $Sync.Done = $true
}
'@

function Get-FirstPath {
    param([string[]]$Candidates)
    foreach ($c in $Candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Get-Extractor {
    <#
        Escolhe quem extrai o arquivo. ZIP é nativo (.NET); RAR usa o UnRAR
        do WinRAR; 7Z usa o 7-Zip; e o tar do Windows (libarchive) é a reserva.
    #>
    param([string]$Path)

    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -eq '.zip') { return [pscustomobject]@{ Kind = 'zip'; Exe = $null } }

    $programFilesX86 = ${env:ProgramFiles(x86)}

    if ($ext -eq '.rar') {
        $unrar = Get-FirstPath @(
            (Join-Path $env:ProgramFiles 'WinRAR\UnRAR.exe'),
            $(if ($programFilesX86) { Join-Path $programFilesX86 'WinRAR\UnRAR.exe' })
        )
        if ($unrar) { return [pscustomobject]@{ Kind = 'unrar'; Exe = $unrar } }
    }

    $seven = Get-FirstPath @(
        (Join-Path $env:ProgramFiles '7-Zip\7z.exe'),
        $(if ($programFilesX86) { Join-Path $programFilesX86 '7-Zip\7z.exe' })
    )
    if ($seven) { return [pscustomobject]@{ Kind = '7z'; Exe = $seven } }

    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($tar) { return [pscustomobject]@{ Kind = 'tar'; Exe = $tar.Source } }

    return $null
}

function Remove-TempRoot {
    param([string]$Path)
    if (-not $Path) { return }
    try {
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    [void]$S.TempRoots.Remove($Path)
}

function Start-Extract {
    param([string]$Archive)

    $tool = Get-Extractor $Archive
    if (-not $tool) {
        Show-Toast 'Sem extrator' 'Instale o 7-Zip ou o WinRAR, ou extraia o .iso você mesmo.' 'error'
        Add-Log ("Não sei extrair {0}: instale 7-Zip/WinRAR ou extraia o ISO." -f (Split-Path $Archive -Leaf)) 'error'
        return
    }

    [void]$S.ExtractQueue.Add([pscustomobject]@{ Archive = $Archive; Tool = $tool })
    if (-not $S.Extract) { Start-NextExtract }
}

function Start-NextExtract {
    if ($S.Extract -or $S.ExtractQueue.Count -eq 0) { return }

    $job = $S.ExtractQueue[0]
    $S.ExtractQueue.RemoveAt(0)

    $tempBase = Join-Path ([IO.Path]::GetTempPath()) 'EasyRomsToOPL'
    $dest = Join-Path $tempBase ([guid]::NewGuid().ToString('N'))

    $sync = [hashtable]::Synchronized(@{
        Archive = $job.Archive
        Dest    = $dest
        Kind    = $job.Tool.Kind
        Exe     = $job.Tool.Exe
        Isos    = @()
        Ok      = $false
        Error   = ''
        Done    = $false
    })

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:ExtractScript)
    [void]$ps.AddParameter('Sync', $sync)

    $S.Extract = [pscustomobject]@{
        Sync       = $sync
        PowerShell = $ps
        Handle     = $ps.BeginInvoke()
        Timer      = $null
        Dest       = $dest
        Archive    = $job.Archive
    }
    [void]$S.TempRoots.Add($dest)

    $ui.Bar.Value = 0
    $ui.BarPct.Text = ''
    $ui.BarText.Text = 'EXTRAINDO...'
    $ui.Bar.IsIndeterminate = $true
    Set-Status 'EXTRAINDO...' '#F1FA8C'
    Add-Log ("Extraindo {0}..." -f (Split-Path $job.Archive -Leaf)) 'info'

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Add_Tick({ Update-Extract })
    $S.Extract.Timer = $timer
    $timer.Start()
}

function Update-Extract {
    $x = $S.Extract
    if (-not $x) { return }
    if (-not $x.Sync.Done) { return }

    $x.Timer.Stop()
    try { $x.PowerShell.Dispose() } catch { }
    $S.Extract = $null
    $ui.Bar.IsIndeterminate = $false

    if ($x.Sync.Ok) {
        $isos = @($x.Sync.Isos)
        if ($isos.Count -eq 0) {
            Add-Log 'O arquivo não tem nenhum .iso dentro.' 'error'
            Show-Toast 'Nenhum ISO' ('{0} não tem .iso dentro.' -f (Split-Path $x.Archive -Leaf)) 'error'
            Remove-TempRoot $x.Dest
        } else {
            Add-Log ('{0} ISO(s) encontrado(s) dentro do arquivo.' -f $isos.Count) 'ok'
            foreach ($iso in $isos) { Add-IsoFile $iso }
        }
    } else {
        Add-Log ("Falha ao extrair: {0}" -f $x.Sync.Error) 'error'
        Show-Toast 'Falha ao extrair' $x.Sync.Error 'error'
        Remove-TempRoot $x.Dest
    }

    $ui.BarText.Text = 'OCIOSO'
    if ($S.Drive) { Set-Status ("PRONTO · {0}:" -f $S.Drive) '#50FA7B' }

    if ($S.ExtractQueue.Count -gt 0) { Start-NextExtract; return }
    Invoke-AutoInstall
}

function Remove-InstalledTempFiles {
    <#
        Depois de instalar, apaga o que veio de .zip/.rar/.7z: o jogo já está
        no pendrive e o temporário só ocuparia espaço.
    #>
    if ($S.TempRoots.Count -eq 0) { return }

    $gone = @()
    foreach ($f in @($S.Files)) {
        foreach ($root in @($S.TempRoots)) {
            if ($f.Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $gone += $f; break }
        }
    }
    if ($gone.Count -eq 0) { return }

    foreach ($f in $gone) { [void]$S.Files.Remove($f) }
    foreach ($root in @($S.TempRoots)) { Remove-TempRoot $root }
    $ui.NameBox.Text = ''
    Render-Files
}

# ---------------------------------------------------------------- arquivos

function Add-OneDropped {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Show-Toast 'Arquivo não encontrado' $Path 'error'
        return 0
    }

    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -eq '.iso') {
        $before = $S.Files.Count
        Add-IsoFile $Path
        return ($S.Files.Count - $before)
    }

    if ($ext -in '.zip', '.rar', '.7z') {
        Start-Extract $Path
        return 0
    }

    Show-Toast 'Arquivo ignorado' (Split-Path $Path -Leaf) 'warn'
    return 0
}

function Add-DroppedFiles {
    <#
        Chamado pelo evento de drop (e pelo teste). Aceita qualquer coisa que
        venha do DataObject: ISO, ZIP/RAR/7Z, pastas, caminhos ou nada.
        Com -Auto, começa a instalar assim que o(s) arquivo(s) estiverem prontos.
    #>
    param($Files, [switch]$Auto)

    foreach ($f in @($Files)) {
        if (-not $f) { continue }
        $path = [string]$f

        if (Test-Path -LiteralPath $path -PathType Container) {
            $found = @(Get-ChildItem -LiteralPath $path -Recurse -Depth 2 -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.iso', '.zip', '.rar', '.7z' })
            if ($found.Count -eq 0) {
                Show-Toast 'Pasta sem jogos' ('Nenhum .iso/.zip/.rar/.7z em ' + (Split-Path $path -Leaf)) 'warn'
                continue
            }
            foreach ($g in $found) { [void](Add-OneDropped $g.FullName) }
            continue
        }

        [void](Add-OneDropped $path)
    }

    if ($Auto) { Invoke-AutoInstall }
}

function Invoke-AutoInstall {
    <#
        O "arrastou, instalou": só dispara com tudo pronto (nada extraindo,
        todos os ISOs válidos e um pendrive selecionado). Sem pendrive, o
        arquivo fica na lista e a instalação começa quando ele aparecer.
    #>
    if (-not $S.AutoInstall) { return }
    if ($S.Busy -or $S.Extract -or $S.ExtractQueue.Count -gt 0) { return }
    if ($S.Files.Count -eq 0) { return }
    if (@($S.Files | Where-Object { -not $_.Valid }).Count -gt 0) { return }

    if (-not $S.Drive) {
        Show-Toast 'Conecte o pendrive' 'O jogo fica na lista; instalo assim que a unidade aparecer.' 'warn'
        Set-Status 'SEM PENDRIVE' '#FF5555'
        return
    }

    Start-Install
}

function Show-AddFilesDialog {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Escolha o jogo (ISO, ZIP, RAR ou 7Z)'
    $dlg.Filter = 'Jogos (*.iso;*.zip;*.rar;*.7z)|*.iso;*.zip;*.rar;*.7z|Todos os arquivos (*.*)|*.*'
    $dlg.Multiselect = $true
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Add-DroppedFiles -Files $dlg.FileNames -Auto
    }
}

# ---------------------------------------------------------------- jogos

function Get-GameKey {
    <# Chave estável de um card: serial quando existe, senão o nome do arquivo. #>
    param($Game)
    if ($null -eq $Game) { return $null }
    if ($Game.Serial -and $Game.Serial -ne '—') { return "ul:$($Game.Serial)" }
    return "dvd:$($Game.Nome)"
}

function Get-GameCheck {
    <# Checkbox do card (guardado em $S.CardChecks) para manter a marcação em sincronia. #>
    param($Game)
    $k = Get-GameKey $Game
    if ($S.CardChecks.ContainsKey($k)) { return $S.CardChecks[$k] }
    return $null
}

function Test-GameSelected {
    param($Game)
    return [bool]$S.Selected[(Get-GameKey $Game)]
}

function Set-GameSelected {
    <# Marca/desmarca um card e sincroniza o checkbox e o realce visual. #>
    param($Game, [bool]$On, $Border)

    $key = Get-GameKey $Game
    if (-not $key) { return }
    if ($On) { $S.Selected[$key] = $true } else { $S.Selected.Remove($key) }

    $check = Get-GameCheck $Game
    if ($check) { $check.IsChecked = $On }

    $b = $Border
    if (-not $b -and $S.CardBorders.ContainsKey($key)) { $b = $S.CardBorders[$key] }
    if ($b) {
        $b.Background = Br $(if ($On) { '#1A1030' } else { '#000000' })
        $b.BorderBrush = Br $(if ($On) { '#8A2BE2' } else { '#161616' })
    }
    Update-GamesSelectionInfo
}

function Clear-GameSelection {
    $S.Selected = @{}
    $S.LastPick = $null
    foreach ($chk in @($S.CardChecks.Values)) { if ($chk) { $chk.IsChecked = $false } }
    foreach ($b in @($S.CardBorders.Values)) {
        if ($b) {
            $b.Background = Br '#000000'
            $b.BorderBrush = Br '#161616'
        }
    }
    Update-GamesSelectionInfo
}

function Get-SelectedGames {
    return @($S.Games | Where-Object { Test-GameSelected $_ })
}

# ------------------------------------------------- seleção em lote (biblioteca)

function Get-LibraryKey {
    <# Chave estável de uma linha da biblioteca: caminho relativo quando é um
       arquivo solto; senão serial/nome da entrada instalada. #>
    param($Row)
    if ($null -eq $Row) { return $null }
    if ($Row.File) { return "file:$($Row.Rel)" }
    return "lib:$($Row.Label)$($Row.Name)"
}

function Get-SelectableLibraryRows {
    <# Linhas que aceitam instalação: PS2, ainda não instaladas e com arquivo. #>
    return @(Get-LibraryRows | Where-Object {
        $_.Status -eq 'pending' -and $_.Platform -eq 'PS2' -and $_.File
    })
}

function Test-LibrarySelected {
    param($Row)
    return [bool]$S.LibSel[(Get-LibraryKey $Row)]
}

function Set-LibrarySelected {
    param($Row, [bool]$On)
    $key = Get-LibraryKey $Row
    if (-not $key) { return }
    if ($On) { $S.LibSel[$key] = $true } else { $S.LibSel.Remove($key) }
    Update-LibrarySelectionInfo
}

function Clear-LibrarySelection {
    $S.LibSel = @{}
    Update-LibrarySelectionInfo
}

function Get-SelectedLibraryRows {
    return @(Get-SelectableLibraryRows | Where-Object { Test-LibrarySelected $_ })
}

function Update-LibrarySelectionInfo {
    $n = $S.LibSel.Count
    if ($n -le 0) {
        $ui.BtnInstallSelected.Visibility = [Windows.Visibility]::Collapsed
        $ui.LibraryInfo.Text = Get-LibraryInfoText
        return
    }
    $bytes = [double]0
    foreach ($r in (Get-SelectedLibraryRows)) { $bytes += [double]$r.Size }
    $ui.BtnInstallSelected.Content = ("INSTALAR {0} SELECIONADO(S) · {1}" -f $n, (Format-Size $bytes))
    $ui.BtnInstallSelected.Visibility = [Windows.Visibility]::Visible
    $base = Get-LibraryInfoText
    $ui.LibraryInfo.Text = if ($base) { ("{0} · {1} SELECIONADO(S)" -f $base, $n) } else { ("{0} SELECIONADO(S)" -f $n) }
}

function Install-SelectedLibraryGames {
    <# Instala em lote o que estiver marcado na biblioteca. #>
    if ($S.Busy) { Show-Toast 'Ocupado' 'Já existe uma instalação em andamento.' 'warn'; return }
    if (-not $S.Drive) { Show-Toast 'Sem pendrive' 'Selecione uma unidade acima.' 'error'; return }

    $rows = @(Get-SelectedLibraryRows)
    if ($rows.Count -eq 0) { Show-Toast 'Nada selecionado' 'Marque os jogos que quer instalar.' 'warn'; return }

    $S.Files.Clear()
    $added = 0
    foreach ($r in $rows) {
        $before = $S.Files.Count
        if ($r.Container) {
            Add-DroppedFiles -Files @($r.File) -Auto
        } else {
            Add-IsoFile $r.File
        }
        if ($S.Files.Count -gt $before) { $added += ($S.Files.Count - $before) }
    }

    if ($added -eq 0) { Show-Toast 'Nada para instalar' 'Os jogos selecionados não geraram arquivos válidos.' 'error'; return }

    Set-Status ('INSTALANDO {0} JOGO(S)...' -f $added) '#8BE9FD'
    Start-Install
}

function Get-ActionGames {
    <# Jogos sobre os quais uma ação de menu deve incidir: a seleção inteira
       quando o alvo faz parte dela; caso contrário, só o alvo. #>
    param($Target)
    if (Test-GameSelected $Target) {
        $sel = Get-SelectedGames
        if ($sel.Count -gt 0) { return $sel }
    }
    return @($Target)
}

function Update-GamesSelectionInfo {
    $n = $S.Selected.Count
    if ($n -le 0) {
        # Sem seleção: restaura o status ocioso em vez de deixar o texto antigo.
        if ($S.Drive) { Set-Status 'PRONTO' '#50FA7B' } else { Set-Status 'NENHUM DISPOSITIVO SELECIONADO' '#666666' }
        return
    }
    Set-Status ("{0} JOGO(S) SELECIONADO(S)" -f $n) '#BD93F9'
}

function Get-OtherDrives {
    <# Unidades removíveis diferentes da atual, para Mover/Copiar. #>
    $out = @()
    foreach ($d in @(Get-DriveList)) {
        if ($d.Letter -and ($d.Letter -ne $S.Drive)) { $out += $d }
    }
    return $out
}

function Invoke-AskText {
    <# Caixa simples de entrada de texto (usada pelo Renomear). Devolve $null se cancelar. #>
    param([string]$Title, [string]$Prompt, [string]$Default = '')

    $dlg = New-Object Windows.Window
    $dlg.Title = $Title
    $dlg.Width = 420
    $dlg.Height = 190
    $dlg.WindowStartupLocation = 'CenterOwner'
    $dlg.Owner = $win
    $dlg.Background = Br '#0A0A0A'
    $dlg.WindowStyle = 'ToolWindow'
    $dlg.ResizeMode = 'NoResize'

    $outer = New-Object Windows.Controls.StackPanel
    $outer.Margin = New-Object Windows.Thickness(18)

    $lbl = New-Object Windows.Controls.TextBlock
    $lbl.Text = $Prompt
    $lbl.Foreground = Br '#CCCCCC'
    $lbl.FontSize = 11
    $lbl.TextWrapping = 'Wrap'
    $lbl.Margin = New-Object Windows.Thickness(0, 0, 0, 10)
    [void]$outer.Children.Add($lbl)

    $box = New-Object Windows.Controls.TextBox
    $box.Text = $Default
    $box.Padding = New-Object Windows.Thickness(4)
    $box.FontSize = 11
    $box.Background = Br '#111111'
    $box.Foreground = Br '#EEEEEE'
    $box.CaretBrush = Br '#BD93F9'
    $box.BorderBrush = Br '#333333'
    [void]$outer.Children.Add($box)

    $row = New-Object Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.HorizontalAlignment = 'Right'
    $row.Margin = New-Object Windows.Thickness(0, 14, 0, 0)

    $ok = New-Object Windows.Controls.Button
    $ok.Style = $win.FindResource('BtnPrimary')
    $ok.Content = 'OK'
    $ok.MinWidth = 90
    $ok.Margin = New-Object Windows.Thickness(0, 0, 8, 0)
    $ok.IsDefault = $true

    $cancel = New-Object Windows.Controls.Button
    $cancel.Style = $win.FindResource('BtnTiny')
    $cancel.Content = 'Cancelar'
    $cancel.MinWidth = 90
    $cancel.IsCancel = $true

    $script:askResult = $null
    $ok.Add_Click({ param($s, $e) $script:askResult = $box.Text; $dlg.DialogResult = $true })
    $cancel.Add_Click({ param($s, $e) $dlg.DialogResult = $false })

    $dlg.Add_ContentRendered({ $box.Focus() | Out-Null; $box.SelectAll() })

    [void]$row.Children.Add($ok)
    [void]$row.Children.Add($cancel)
    [void]$outer.Children.Add($row)
    $dlg.Content = $outer

    [void]$dlg.ShowDialog()
    return $script:askResult
}

function Start-GameTransfer {
    <#
        Copia/move um ou mais jogos para outra unidade, rodando no worker
        (mesma barra de progresso do instalar/exportar).
    #>
    param([string]$Op, $Games)

    $Games = @($Games)
    if ($Games.Count -eq 0) { Show-Toast 'Seleção' 'Nenhum jogo selecionado.' 'info'; return }
    if (-not $S.Drive) { Show-Toast 'Pendrive' 'Escolha uma unidade de origem.' 'error'; return }

    $others = Get-OtherDrives
    if ($others.Count -eq 0) {
        Show-Toast 'Unidades' 'Não há outra unidade removível disponível para receber os jogos.' 'error'
        return
    }

    # Escolha do destino. Com uma única unidade, serve direto; com várias, pergunta.
    $dest = $null
    if ($others.Count -eq 1) {
        $dest = $others[0]
    } else {
        $opts = @($others | ForEach-Object { "$($_.Letter): $($_.Label)" })
        $prompt = ("Para onde {0} {1}?" -f $(if ($Op -eq 'move') { 'mover' } else { 'copiar' }), (($Games | ForEach-Object { $_.Nome }) -join ', '))
        $pick = Show-Choice 'Escolha o destino' $prompt $opts
        if (-not $pick) { return }
        $idx = [array]::IndexOf($opts, $pick)
        if ($idx -ge 0) { $dest = $others[$idx] }
    }
    if (-not $dest) { return }

    $verb = if ($Op -eq 'move') { 'Mover' } else { 'Copiar' }
    Show-Confirm ("$($verb.ToUpper()) JOGO(S)") ("$verb {0} jogo(s) para a unidade {1}:?`n`n{2}" -f $Games.Count, $dest.Letter, (($Games | ForEach-Object { '• ' + $_.Nome }) -join "`n")) -OnYes {
        $jobs = New-Object System.Collections.ArrayList
        foreach ($g in $Games) {
            if ($g.Tipo -eq 'ul') {
                $opName = if ($Op -eq 'move') { 'move-ul' } else { 'copy-ul' }
                [void]$jobs.Add([pscustomobject]@{
                    Op = $opName; Name = $g.Nome; Serial = $g.Serial
                    SourceRoot = "$($S.Drive):\"; DestRoot = "$($dest.Letter):\"; DestLetter = $dest.Letter
                })
            } else {
                $opName = if ($Op -eq 'move') { 'move-dvd' } else { 'copy-dvd' }
                [void]$jobs.Add([pscustomobject]@{
                    Op = $opName; Name = $g.Nome; Iso = $g.Path
                    DestRoot = "$($dest.Letter):\"; DestLetter = $dest.Letter
                })
            }
        }
        Start-Worker $jobs
    }
}

function Confirm-DeleteGame {
    <# Apaga os arquivos de verdade (ul.* + entrada no ul.cfg, ou o ISO). #>
    param($Games)

    $Games = @($Games)
    if ($Games.Count -eq 0) { return }
    $names = ($Games | ForEach-Object { '• ' + $_.Nome }) -join "`n"

    Show-Confirm 'APAGAR PERMANENTEMENTE' ("Apagar TODOS os arquivos de {0} jogo(s)?`n`n{1}`n`nIsto remove os arquivos UL.* e a entrada no ul.cfg (ou o .iso). Não tem volta." -f $Games.Count, $names) -OnYes {
        $removed = 0
        $errors = @()
        foreach ($g in $Games) {
            try {
                if ($g.Tipo -eq 'ul') {
                    $r = Remove-UlGame -Root "$($S.Drive):\" -Serial $g.Serial
                    $removed += 1 + @($r).Count
                    Add-Log ("Apagado: {0} ({1} arquivo(s))" -f $g.Nome, (1 + @($r).Count)) 'warn'
                } elseif ($g.Tipo -eq 'dvd' -and $g.Path -and (Test-Path -LiteralPath $g.Path)) {
                    Remove-Item -LiteralPath $g.Path -Force
                    $removed += 1
                    Add-Log "Apagado: $($g.Nome).iso" 'warn'
                }
            } catch {
                $errors += "$($g.Nome): $($_.Exception.Message)"
                Add-Log "Falha ao apagar $($g.Nome): $($_.Exception.Message)" 'error'
            }
        }
        Clear-GameSelection
        Load-Games
        if ($errors.Count) {
            Show-Toast 'Apagar' ("Não deu para apagar:`n" + ($errors -join "`n")) 'error'
        } else {
            Show-Toast 'Apagar' ("{0} jogo(s) apagado(s)." -f $Games.Count) 'ok'
        }
    }
}

function Start-RenameGame {
    param($Game)

    if ($Game.Tipo -ne 'ul') {
        Show-Toast 'Renomear' 'Só jogos UL.* podem ser renomeados por aqui (o nome do ISO é o próprio arquivo).' 'info'
        return
    }
    $new = Invoke-AskText 'Renomear jogo' ("Novo nome para:`n{0}" -f $Game.Nome) $Game.Nome
    if (-not $new) { return }
    $new = $new.Trim()
    if ($new -eq $Game.Nome) { return }

    try {
        $r = Rename-UlGame -Root "$($S.Drive):\" -Serial $Game.Serial -NewName $new
        Add-Log ("Renomeado: {0} -> {1}" -f $r.Antigo, $r.Novo) 'ok'
        Show-Toast 'Renomear' ("Agora é:`n{0}" -f $r.Novo) 'ok'
        Clear-GameSelection
        Load-Games
    } catch {
        Show-Toast 'Renomear' $_.Exception.Message 'error'
    }
}

function Show-Choice {
    <# Lista de escolha simples (usada para eleger a unidade de destino). Devolve $null se cancelar. #>
    param([string]$Title, [string]$Prompt, [array]$Options)

    if (-not $Options -or $Options.Count -eq 0) { return $null }

    $dlg = New-Object Windows.Window
    $dlg.Title = $Title
    $dlg.Width = 440
    $dlg.SizeToContent = 'Height'
    $dlg.WindowStartupLocation = 'CenterOwner'
    $dlg.Owner = $win
    $dlg.Background = Br '#0A0A0A'
    $dlg.WindowStyle = 'ToolWindow'
    $dlg.ResizeMode = 'NoResize'
    $dlg.ShowInTaskbar = $false

    $outer = New-Object Windows.Controls.StackPanel
    $outer.Margin = New-Object Windows.Thickness(18)

    $lbl = New-Object Windows.Controls.TextBlock
    $lbl.Text = $Prompt
    $lbl.Foreground = Br '#CCCCCC'
    $lbl.FontSize = 11
    $lbl.TextWrapping = 'Wrap'
    $lbl.Margin = New-Object Windows.Thickness(0, 0, 0, 12)
    [void]$outer.Children.Add($lbl)

    $script:choiceResult = $null
    foreach ($opt in $Options) {
        $btn = New-Object Windows.Controls.Button
        $btn.Style = $win.FindResource('BtnPrimary')
        $btn.Content = $opt
        $btn.HorizontalAlignment = 'Stretch'
        $btn.Margin = New-Object Windows.Thickness(0, 0, 0, 6)
        $btn.Tag = $opt
        $btn.Add_Click({ param($s, $e) $script:choiceResult = $s.Tag; $dlg.DialogResult = $true })
        [void]$outer.Children.Add($btn)
    }

    $cancel = New-Object Windows.Controls.Button
    $cancel.Style = $win.FindResource('BtnTiny')
    $cancel.Content = 'Cancelar'
    $cancel.HorizontalAlignment = 'Right'
    $cancel.Margin = New-Object Windows.Thickness(0, 6, 0, 0)
    $cancel.IsCancel = $true
    [void]$outer.Children.Add($cancel)

    $dlg.Content = $outer
    [void]$dlg.ShowDialog()
    return $script:choiceResult
}

function Load-Games {
    $ui.GamesPanel.Children.Clear()
    $S.Games = @()
    # A lista pode encolher (remover/apagar jogo): o âncora do Shift+clique não
    # pode apontar para um índice que deixou de existir.
    $S.LastPick = $null

    if (-not $S.Drive) {
        Update-Space
        return
    }

    $root = "$($S.Drive):\"
    $games = New-Object System.Collections.ArrayList

    try {
        foreach ($e in @(Read-UlEntries $root)) {
            [void]$games.Add([pscustomobject]@{
                Nome = $e.Nome; Serial = $e.Serial; Modo = $e.Media
                Partes = [string]$e.Partes; Crc = $e.Crc; Tipo = 'ul'
            })
        }
    } catch {
        Add-Log "Falha ao ler ul.cfg: $($_.Exception.Message)" 'error'
    }

    $dvd = Join-Path $root 'DVD'
    if (Test-Path -LiteralPath $dvd) {
        foreach ($iso in @(Get-ChildItem $dvd -File -Filter *.iso -ErrorAction SilentlyContinue)) {
            $serial = '—'
            try {
                $info = Get-IsoInfo $iso.FullName
                if ($info.Serial) { $serial = $info.Serial }
            } catch { }

            [void]$games.Add([pscustomobject]@{
                Nome = $iso.BaseName; Serial = $serial; Modo = 'ISO'
                Partes = '—'; Crc = (Format-Size $iso.Length); Tipo = 'dvd'; Path = $iso.FullName
            })
        }
    }

    $S.Games = @($games)

    if ($S.Games.Count -eq 0) {
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = 'NENHUM JOGO INSTALADO NESTE PENDRIVE'
        $t.Foreground = Br '#666666'
        $t.FontSize = 10
        $t.Margin = New-Object Windows.Thickness(0, 8, 0, 0)
        [void]$ui.GamesPanel.Children.Add($t)
        Update-Space
        Update-OplInfo
        return
    }

    foreach ($g in $S.Games) {
        $key = Get-GameKey $g

        $border = New-Object Windows.Controls.Border
        $border.BorderThickness = New-Object Windows.Thickness(0, 0, 0, 1)
        $border.Padding = New-Object Windows.Thickness(0, 6, 0, 6)
        $border.Tag = $g
        # Fundo/borda guardados para a seleção restaurar o visual ao limpar
        $border.Background = Br '#000000'
        $border.BorderBrush = Br '#161616'
        $S.CardBorders[$key] = $border

        $grid = New-Object Windows.Controls.Grid
        $widths = @('Auto', '2.4*', '1.5*', '0.7*', '0.6*', '1.1*', 'Auto')
        foreach ($w in $widths) {
            $c = New-Object Windows.Controls.ColumnDefinition
            if ($w.EndsWith('*')) {
                $c.Width = New-Object Windows.GridLength([double]$w.TrimEnd('*'), 'Star')
            }
            [void]$grid.ColumnDefinitions.Add($c)
        }

        # Coluna 0: caixa de seleção (marca o jogo para ações em lote)
        $chk = New-Object Windows.Controls.CheckBox
        $chk.VerticalAlignment = 'Center'
        $chk.Margin = New-Object Windows.Thickness(2, 0, 10, 0)
        $chk.Tag = $g
        $chk.IsChecked = [bool](Test-GameSelected $g)
        $chk.ToolTip = 'Marcar para ações em lote'
        $chk.Add_Click({ param($sender, $e) Set-GameSelected $sender.Tag ([bool]$sender.IsChecked) })
        [Windows.Controls.Grid]::SetColumn($chk, 0)
        [void]$grid.Children.Add($chk)
        $S.CardChecks[$key] = $chk

        $cells = @(
            @{ Text = $g.Nome;   Color = '#CCCCCC'; Bold = $true },
            @{ Text = $g.Serial; Color = '#666666' },
            @{ Text = $g.Modo;   Color = $(if ($g.Modo -eq 'DVD') { '#8BE9FD' } elseif ($g.Modo -eq 'CD') { '#FF79C6' } else { '#BD93F9' }) },
            @{ Text = $g.Partes; Color = '#666666' },
            @{ Text = $g.Crc;    Color = '#666666' }
        )

        for ($i = 0; $i -lt $cells.Count; $i++) {
            $t = New-Object Windows.Controls.TextBlock
            $t.Text = $cells[$i].Text
            $t.Foreground = Br $cells[$i].Color
            $t.FontSize = 10
            $t.TextTrimming = 'CharacterEllipsis'
            $t.VerticalAlignment = 'Center'
            $t.Margin = New-Object Windows.Thickness(0, 0, 6, 0)
            if ($cells[$i].Bold) { $t.FontWeight = 'Bold' }
            [Windows.Controls.Grid]::SetColumn($t, $i + 1)
            [void]$grid.Children.Add($t)
        }

        $actions = New-Object Windows.Controls.StackPanel
        $actions.Orientation = 'Horizontal'
        $actions.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($actions, 6)
        [void]$grid.Children.Add($actions)

        if ($g.Tipo -eq 'ul') {
            $b = New-Object Windows.Controls.Button
            $b.Style = $win.FindResource('BtnTiny')
            $b.Content = 'ISO'
            $b.ToolTip = 'Remontar os pedaços em um .iso único (PCSX2 / backup)'
            $b.Margin = New-Object Windows.Thickness(0, 0, 4, 0)
            $b.Tag = $g
            $b.Add_Click({ param($sender, $e) Start-Export $sender.Tag })
            [void]$actions.Children.Add($b)
        }

        $d = New-Object Windows.Controls.Button
        $d.Style = $win.FindResource('BtnTiny')
        $d.Content = '✕'
        $d.Foreground = Br '#FF5555'
        $d.BorderBrush = Br '#663333'
        $d.ToolTip = 'Remover do pendrive'
        $d.Tag = $g
        $d.Add_Click({ param($sender, $e) Confirm-Remove $sender.Tag })
        [void]$actions.Children.Add($d)

        $border.Child = $grid

        # Menu de contexto (clique direito). As ações que mexem em vários jogos
        # operam sobre a seleção quando o jogo clicado faz parte dela.
        $contextMenu = New-Object Windows.Controls.ContextMenu

        $itemInfo = New-Object Windows.Controls.MenuItem
        $itemInfo.Header = 'ℹ️ Informações'
        $itemInfo.Tag = $g
        $itemInfo.Add_Click({ param($sender, $e) Show-GameInfo $sender.Tag })
        [void]$contextMenu.Items.Add($itemInfo)

        if ($g.Tipo -eq 'ul') {
            $itemExport = New-Object Windows.Controls.MenuItem
            $itemExport.Header = '📀 Exportar ISO'
            $itemExport.Tag = $g
            $itemExport.Add_Click({ param($sender, $e) Start-Export $sender.Tag })
            [void]$contextMenu.Items.Add($itemExport)

            $itemRename = New-Object Windows.Controls.MenuItem
            $itemRename.Header = '✏️ Renomear'
            $itemRename.Tag = $g
            $itemRename.Add_Click({ param($sender, $e) Start-RenameGame $sender.Tag })
            [void]$contextMenu.Items.Add($itemRename)
        }

        $contextMenu.Items.Add((New-Object Windows.Controls.Separator))

        $itemMove = New-Object Windows.Controls.MenuItem
        $itemMove.Header = '➡️ Mover para…'
        $itemMove.Tag = $g
        $itemMove.Add_Click({ param($sender, $e) Start-GameTransfer -Op 'move' -Games (Get-ActionGames $sender.Tag) })
        [void]$contextMenu.Items.Add($itemMove)

        $itemCopy = New-Object Windows.Controls.MenuItem
        $itemCopy.Header = '📋 Copiar para…'
        $itemCopy.Tag = $g
        $itemCopy.Add_Click({ param($sender, $e) Start-GameTransfer -Op 'copy' -Games (Get-ActionGames $sender.Tag) })
        [void]$contextMenu.Items.Add($itemCopy)

        $contextMenu.Items.Add((New-Object Windows.Controls.Separator))

        $itemRemove = New-Object Windows.Controls.MenuItem
        $itemRemove.Header = '🗑️ Remover do pendrive'
        $itemRemove.Tag = $g
        $itemRemove.Add_Click({ param($sender, $e) Confirm-Remove $sender.Tag })
        [void]$contextMenu.Items.Add($itemRemove)

        $itemDelete = New-Object Windows.Controls.MenuItem
        $itemDelete.Header = '💥 Apagar permanentemente'
        $itemDelete.Tag = $g
        $itemDelete.Add_Click({ param($sender, $e) Confirm-DeleteGame (Get-ActionGames $sender.Tag) })
        [void]$contextMenu.Items.Add($itemDelete)

        $border.ContextMenu = $contextMenu

        # Clique esquerdo = seleção. Ctrl alterna, Shift pega o intervalo; sem
        # modificador, seleciona só este (igual explorador de arquivos).
        $border.Add_MouseLeftButtonUp({
            param($sender, $e)
            $game = $sender.Tag
            $mods = [Windows.Input.Keyboard]::Modifiers
            $ctrl = [bool]($mods -band [Windows.Input.ModifierKeys]::Control)
            $shift = [bool]($mods -band [Windows.Input.ModifierKeys]::Shift)
            $k = Get-GameKey $game

            $idx = $S.Games.IndexOf($game)
            if ($shift -and $null -ne $S.LastPick -and $S.LastPick -lt $S.Games.Count) {
                $lo = [Math]::Max(0, [Math]::Min($S.LastPick, $idx))
                $hi = [Math]::Min($S.Games.Count - 1, [Math]::Max($S.LastPick, $idx))
                Clear-GameSelection
                for ($n = $lo; $n -le $hi; $n++) {
                    if ($null -ne $S.Games[$n]) { Set-GameSelected $S.Games[$n] $true }
                }
                $S.LastPick = $idx
            } elseif ($ctrl) {
                Set-GameSelected $game (-not (Test-GameSelected $game))
                $S.LastPick = $idx
            } else {
                Clear-GameSelection
                Set-GameSelected $game $true
                $S.LastPick = $idx
            }
            Update-GamesSelectionInfo
            $e.Handled = $true
        })
        $border.Add_MouseRightButtonUp({
            param($sender, $e)
            # Clique direito sobre um item não selecionado: seleciona só ele,
            # para o menu agir no alvo intuitivo.
            $game = $sender.Tag
            if (-not (Test-GameSelected $game)) {
                Clear-GameSelection
                Set-GameSelected $game $true
                $S.LastPick = $S.Games.IndexOf($game)
                Update-GamesSelectionInfo
            }
        })
        $border.Add_MouseEnter({ param($sender, $e) if (-not (Test-GameSelected $sender.Tag)) { $sender.Background = Br '#0D0D0D' } })
        $border.Add_MouseLeave({ param($sender, $e) if (-not (Test-GameSelected $sender.Tag)) { $sender.Background = Br '#000000' } })
        [void]$ui.GamesPanel.Children.Add($border)
    }

    Update-GamesSelectionInfo
    Update-Space
    Update-OplInfo
}

# ---------------------------------------------------------------- biblioteca
# Varre a unidade em segundo plano e lista os jogos de todas as plataformas
# (PS2, PS1, SNES, N64, GBA...). O OPL executa só PS2: o resto é consulta.

function Update-OplInfo {
    <# Quantos jogos já estão no pendrive e em que formato (ul.* ou DVD\). #>
    if ($S.LibView -ne 'opl') { return }
    if (-not $S.Drive) { $ui.LibraryInfo.Text = ''; return }

    $ul = @($S.Games | Where-Object { $_.Tipo -eq 'ul' }).Count
    $dvd = @($S.Games | Where-Object { $_.Tipo -eq 'dvd' }).Count
    $ui.LibraryInfo.Text = ('{0} JOGO(S) · {1} NO OPL (UL.*) · {2} EM DVD\' -f ($ul + $dvd), $ul, $dvd)
}

function Set-GamesView {
    param([string]$View)

    $S.LibView = $View
    $ui.OplView.Visibility = $(if ($View -eq 'opl') { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed })
    $ui.LibraryView.Visibility = $(if ($View -eq 'library') { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed })
    $ui.TabOpl.IsChecked = ($View -eq 'opl')
    $ui.TabLibrary.IsChecked = ($View -eq 'library')

    if ($View -eq 'opl') { Update-OplInfo } else { Render-Library }
}

function Get-PlatformColor {
    param([string]$Platform)

    switch ($Platform) {
        'PS2'    { return '#8BE9FD' }
        'PS1'    { return '#FF79C6' }
        'SNES'   { return '#F1FA8C' }
        'N64'    { return '#BD93F9' }
        'GBA'    { return '#50FA7B' }
        'GB'     { return '#FF79C6' }
        'NDS'    { return '#8BE9FD' }
        'GC'     { return '#BD93F9' }
        'MEGA'   { return '#F1FA8C' }
        'MASTER' { return '#F1FA8C' }
        'NES'    { return '#FF5555' }
        'PSP'    { return '#8BE9FD' }
        'DC'     { return '#FFB86C' }
        default  { return '#666666' }
    }
}

function Show-LibraryMessage {
    param([string]$Text, [string]$Color = '#666666')

    $ui.LibraryPanel.Children.Clear()
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text
    $t.Foreground = Br $Color
    $t.FontSize = 10
    $t.TextWrapping = 'Wrap'
    $t.LineHeight = 16
    $t.Margin = New-Object Windows.Thickness(0, 8, 0, 0)
    [void]$ui.LibraryPanel.Children.Add($t)
}

function Stop-LibraryScan {
    if ($S.LibTimer) {
        try { $S.LibTimer.Stop() } catch { }
        $S.LibTimer = $null
    }
    if ($S.LibScan) {
        try { $S.LibScan.PowerShell.Stop() } catch { }
        try { $S.LibScan.PowerShell.Dispose() } catch { }
        try { $S.LibScan.Runspace.Dispose() } catch { }
        $S.LibScan = $null
    }
}

function Start-LibraryScan {
    if (-not $S.Drive) {
        $S.LibLetter = $null
        $S.Lib = @()
        $S.LibReport = $null
        $ui.LibraryInfo.Text = ''
        Show-LibraryMessage 'SELECIONE UMA UNIDADE'
        return
    }
    if ($S.Busy) { return }

    Stop-LibraryScan

    $letter = $S.Drive
    $S.LibLetter = $letter
    $S.Lib = @()
    $S.LibReport = $null
    Clear-LibrarySelection
    if ($S.LibView -eq 'library') { $ui.LibraryInfo.Text = 'VARRENDO...' }
    Show-LibraryMessage ('PROCURANDO JOGOS EM {0}:...' -f $letter) '#8BE9FD'

    $ulPath = Join-Path $repoRoot 'lib\UlFormat.ps1'
    $libPath = Join-Path $repoRoot 'lib\GameLibrary.ps1'

    # Outras unidades: usadas para avisar "já está no pendrive F:" quando o
    # jogo existe na unidade aberta e também está instalado em outra.
    $otherRoots = @()
    foreach ($d in @($S.Drives)) {
        if ($d.Letter -and $d.Letter -ne $letter) { $otherRoots += $d.Root }
    }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($UlPath, $LibPath, $Root, $MaxDepth, $Limit, $MaxIso, $OtherRoots)
        . $UlPath
        . $LibPath

        $report = Get-GameLibrary -Root $Root -MaxDepth $MaxDepth -Limit $Limit -MaxIsoChecks $MaxIso -Report

        # Jogos já instalados nas outras unidades (ul.cfg + DVD\*.iso).
        $map = @{}
        foreach ($r in @($OtherRoots)) {
            if (-not $r) { continue }
            $let = ([string]$r).Substring(0, 1).ToUpperInvariant()
            try {
                foreach ($e in @(Read-UlEntries $r)) {
                    if ($e.Serial) { $map[[string]$e.Serial] = $let }
                }
            } catch { }
            $dvd = Join-Path $r 'DVD'
            if (Test-Path -LiteralPath $dvd) {
                foreach ($iso in @(Get-ChildItem $dvd -File -Filter *.iso -ErrorAction SilentlyContinue)) {
                    try {
                        $info = Get-IsoInfo $iso.FullName
                        if ($info.Serial) { $map[[string]$info.Serial] = $let }
                    } catch { }
                }
            }
        }

        Add-Member -InputObject $report -NotePropertyName InstalledElsewhere -NotePropertyValue $map -Force
        $report
    })
    [void]$ps.AddArgument($ulPath)
    [void]$ps.AddArgument($libPath)
    [void]$ps.AddArgument("${letter}:\")
    [void]$ps.AddArgument(4)
    [void]$ps.AddArgument(800)
    [void]$ps.AddArgument(60)
    [void]$ps.AddArgument($otherRoots)

    $handle = $ps.BeginInvoke()
    $S.LibScan = [pscustomobject]@{
        PowerShell = $ps
        Runspace   = $rs
        Handle     = $handle
        Letter     = $letter
    }

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({ Update-LibraryScan })
    $S.LibTimer = $timer
    $timer.Start()
}

function Update-LibraryScan {
    if (-not $S.LibScan) { return }

    $scan = $S.LibScan
    if (-not $scan.Handle.IsCompleted) { return }

    $report = $null
    try {
        $out = @($scan.PowerShell.EndInvoke($scan.Handle))
        $report = $out | Where-Object { $_ -and $_.PSObject.Properties['Items'] } | Select-Object -First 1
    } catch {
        Add-Log ("Falha ao varrer a unidade: {0}" -f $_.Exception.Message) 'error'
    } finally {
        if ($S.LibTimer) {
            try { $S.LibTimer.Stop() } catch { }
            $S.LibTimer = $null
        }
        try { $scan.PowerShell.Dispose() } catch { }
        try { $scan.Runspace.Dispose() } catch { }
        $S.LibScan = $null
    }

    if ($S.Drive -ne $scan.Letter) { return }   # trocou de unidade no meio

    if (-not $report) {
        $ui.LibraryInfo.Text = ''
        Show-LibraryMessage 'NAO CONSEGUI LER A UNIDADE' '#FF5555'
        return
    }

    $S.Lib = @($report.Items)
    $S.LibReport = $report
    $S.InstalledMap = $(if ($report.InstalledElsewhere) { $report.InstalledElsewhere } else { @{} })
    Add-Log ("Biblioteca: {0} jogo(s) em {1}:" -f $report.Count, $scan.Letter) 'dim'
    Render-Library
}

function Get-InstalledSerials {
    <#
        Seriais que já estão no pendrive: os do ul.cfg (ul.*) e os dos ISOs de
        DVD\. Serve para reconhecer o mesmo jogo mesmo quando ele está em outro
        arquivo (uma cópia em ROMs\PS2, por exemplo) — aí a linha já nasce
        INSTALADA em vez de oferecer instalar de novo.
    #>
    $set = @{}
    foreach ($g in @($S.Games)) {
        if ($g.Serial -and $g.Serial -ne '—') { $set[[string]$g.Serial] = $true }
    }
    return $set
}

function Get-LibraryRows {
    $rows = New-Object System.Collections.ArrayList
    $serials = Get-InstalledSerials

    # Jogos já instalados no formato do OPL (ul.*)
    foreach ($g in @($S.Games)) {
        if ($g.Tipo -eq 'ul') {
            [void]$rows.Add([pscustomobject]@{
                Platform = 'PS2'; Label = 'PS2'; Name = $g.Nome
                Rel = 'INSTALADO NO OPL (UL.*)'; Size = [double]0; SizeText = '—'
                Instalado = $true; Status = 'installed'; Where = 'OPL (UL.*)'
                File = $null; Serial = $g.Serial
            })
        }
    }

    # Jogos soltos encontrados na unidade (inclui os do modo DVD e os compactados)
    $dvd = @($S.Games | Where-Object { $_.Tipo -eq 'dvd' } | ForEach-Object { $_.Path })
    foreach ($it in @($S.Lib)) {
        $status = 'other'
        $where = ''
        if ($dvd -contains $it.File) {
            $status = 'installed'; $where = 'DVD\'
        } elseif ($it.Platform -eq 'PS2') {
            if ($it.Serial -and $serials.ContainsKey([string]$it.Serial)) {
                # o arquivo é o mesmo jogo que já está em ul.*: nada a instalar
                $status = 'installed'; $where = 'COPIA'
            } elseif ($it.Serial -and $S.InstalledMap.ContainsKey([string]$it.Serial)) {
                # está instalado em OUTRA unidade (ex.: o pendrive F:)
                $status = 'elsewhere'; $where = [string]$S.InstalledMap[[string]$it.Serial]
            } else {
                $status = 'pending'
            }
        }

        [void]$rows.Add([pscustomobject]@{
            Platform = $it.Platform; Label = $it.PlatformLabel; Name = $it.Name
            Rel = $it.Rel; Size = $it.Size
            SizeText = $(if ($it.Size -lt 1024) { '—' } else { Format-Size $it.Size })
            Instalado = ($status -in 'installed', 'elsewhere'); Status = $status; Where = $where
            File = $it.File; Serial = $it.Serial
            Container = ($it.Kind -eq 'archive'); Inner = $it.Inner; InnerCount = $it.InnerCount
        })
    }

    return @($rows | Sort-Object @{ e = { Get-GamePlatformRank $_.Platform } }, @{ e = { $_.Status -eq 'pending' } }, Name)
}

function Update-LibFilters {
    <#
        Chips de filtro com a contagem de cada grupo. O usuário vê de cara
        quantos jogos já estão no pendrive e quantos ainda pode instalar.
    #>
    param($Counts)

    $defs = @(
        @{ Id = 'all';       Label = 'TUDO';          Tip = 'Tudo que existe na unidade' },
        @{ Id = 'installed'; Label = 'INSTALADOS';    Tip = 'Já aparecem no menu do OPL (ul.*) ou estão em DVD\ desta unidade' },
        @{ Id = 'elsewhere'; Label = 'NO PENDRIVE';   Tip = 'Já estão instalados em OUTRA unidade — não precisa instalar de novo' },
        @{ Id = 'pending';   Label = 'PARA INSTALAR'; Tip = 'Jogos de PS2 que ainda não estão instalados em lugar nenhum' },
        @{ Id = 'other';     Label = 'OUTROS';        Tip = 'PS1 e Nintendo: só consulta, o OPL executa apenas PS2' }
    )

    $ui.LibFilters.Children.Clear()
    foreach ($d in $defs) {
        $n = [int]$Counts[$d.Id]
        $chip = New-Object Windows.Controls.Primitives.ToggleButton
        $chip.Style = $win.FindResource('Chip')
        $chip.Tag = $d.Id
        $chip.Content = ('{0} ({1})' -f $d.Label, $n)
        $chip.ToolTip = $d.Tip
        $chip.IsChecked = ($S.LibFilter -eq $d.Id)
        $chip.Add_Click({
            param($sender, $e)
            $S.LibFilter = [string]$sender.Tag
            Render-Library
        })
        [void]$ui.LibFilters.Children.Add($chip)
    }
}

function Get-LibraryInfoText {
    <# Resumo do cabeçalho da aba Jogos. #>
    if ($S.LibView -ne 'library') { return '' }
    $c = $S.LibCounts
    if (-not $c) { return '' }

    $info = ('{0} JOGO(S) · {1} INSTALADO(S)' -f $c.all, $c.installed)
    if ($c.elsewhere -gt 0) { $info += (' · {0} NO PENDRIVE' -f $c.elsewhere) }
    $info += (' · {0} PARA INSTALAR' -f $c.pending)
    if ($c.other -gt 0) { $info += (' · {0} OUTRO(S)' -f $c.other) }
    if ($S.LibReport -and $S.LibReport.Truncated) { $info = 'MOSTRANDO ' + $info }
    return $info
}

function Render-Library {
    $ui.LibraryPanel.Children.Clear()

    $all = @(Get-LibraryRows)

    $counts = @{
        all       = $all.Count
        installed = @($all | Where-Object { $_.Status -eq 'installed' }).Count
        elsewhere = @($all | Where-Object { $_.Status -eq 'elsewhere' }).Count
        pending   = @($all | Where-Object { $_.Status -eq 'pending' }).Count
        other     = @($all | Where-Object { $_.Status -eq 'other' }).Count
    }
    $S.LibCounts = $counts
    Update-LibFilters $counts

    # Aviso em amarelo: estes jogos já estão instalados em outra unidade.
    if ($counts.elsewhere -gt 0) {
        $lets = @($all | Where-Object { $_.Status -eq 'elsewhere' } | ForEach-Object { $_.Where } |
            Select-Object -Unique | Sort-Object)
        $ui.LibWarn.Text = ('{0} JOGO(S) DESTA UNIDADE JÁ ESTÃO NO PENDRIVE {1}: — NÃO PRECISA INSTALAR DE NOVO' -f
            $counts.elsewhere, ($lets -join ', '))
        $ui.LibWarn.Visibility = [Windows.Visibility]::Visible
    } else {
        $ui.LibWarn.Text = ''
        $ui.LibWarn.Visibility = [Windows.Visibility]::Collapsed
    }

    if ($all.Count -eq 0) {
        if ($S.LibView -eq 'library') { $ui.LibraryInfo.Text = '0 JOGO(S)' }
        if (-not $S.Drive) {
            Show-LibraryMessage 'SELECIONE UMA UNIDADE'
        } else {
            Show-LibraryMessage ("NENHUM JOGO ENCONTRADO EM {0}:`n`nO app só lista arquivos que são jogos de verdade (tamanho e conteúdo conferidos).`nFormatos: PS2 .iso · PS1 .bin/.cue · SNES .sfc · N64 .n64`nGBA .gba · NDS .nds · GC .gcm · Mega .md — e .zip/.rar/.7z" -f $S.Drive)
        }
        return
    }

    if ($S.LibView -eq 'library') {
        $ui.LibraryInfo.Text = Get-LibraryInfoText
    }

    $rows = switch ($S.LibFilter) {
        'installed' { @($all | Where-Object { $_.Status -eq 'installed' }) }
        'elsewhere' { @($all | Where-Object { $_.Status -eq 'elsewhere' }) }
        'pending'   { @($all | Where-Object { $_.Status -eq 'pending' }) }
        'other'     { @($all | Where-Object { $_.Status -eq 'other' }) }
        default     { $all }
    }

    if ($rows.Count -eq 0) {
        $msg = switch ($S.LibFilter) {
            'installed' { 'NADA INSTALADO NESTA UNIDADE`n`nSolte um jogo ou veja PARA INSTALAR.' }
            'elsewhere' { 'NENHUM JOGO DESTA UNIDADE ESTÁ INSTALADO EM OUTRA' }
            'pending'   { 'NADA PARA INSTALAR`n`nTodo jogo de PS2 desta unidade já está instalado.' }
            'other'     { 'NENHUM JOGO DE OUTRA PLATAFORMA NESTA UNIDADE' }
            default     { 'NENHUM JOGO' }
        }
        Show-LibraryMessage $msg
        return
    }

    foreach ($r in $rows) {
        $border = New-Object Windows.Controls.Border
        $border.BorderBrush = Br '#161616'
        $border.BorderThickness = New-Object Windows.Thickness(0, 0, 0, 1)
        $border.Padding = New-Object Windows.Thickness(0, 6, 0, 6)
        $border.Tag = $r

        if ($r.File) {
            $formatTip = Get-FormatTooltip ([System.IO.Path]::GetExtension($r.File))
            if ($formatTip) {
                $border.ToolTip = ('{0} · {1}`n{2}`n{3}`n`n{4}' -f $r.Label, $r.Name, $r.Rel, $r.File, $formatTip)
            } else {
                $border.ToolTip = ('{0} · {1}`n{2}`n{3}' -f $r.Label, $r.Name, $r.Rel, $r.File)
            }
        } else {
            $border.ToolTip = ('{0} · {1}`n{2}' -f $r.Label, $r.Name, $r.Rel)
        }

        $grid = New-Object Windows.Controls.Grid

        $c0 = New-Object Windows.Controls.ColumnDefinition
        $c0.Width = New-Object Windows.GridLength(72)
        [void]$grid.ColumnDefinitions.Add($c0)

        $c1 = New-Object Windows.Controls.ColumnDefinition
        $c1.Width = New-Object Windows.GridLength(1, 'Star')
        [void]$grid.ColumnDefinitions.Add($c1)

        $c2 = New-Object Windows.Controls.ColumnDefinition
        $c2.Width = [Windows.GridLength]::Auto
        [void]$grid.ColumnDefinitions.Add($c2)

        $c3 = New-Object Windows.Controls.ColumnDefinition
        $c3.Width = [Windows.GridLength]::Auto
        [void]$grid.ColumnDefinitions.Add($c3)

        # caixa de seleção (só para jogos que podem ser instalados)
        $selectable = ($r.Status -eq 'pending' -and $r.Platform -eq 'PS2' -and $r.File)
        if ($selectable) {
            $cChk = New-Object Windows.Controls.ColumnDefinition
            $cChk.Width = [Windows.GridLength]::Auto
            [void]$grid.ColumnDefinitions.Insert(0, $cChk)

            $chk = New-Object Windows.Controls.CheckBox
            $chk.VerticalAlignment = 'Center'
            $chk.Margin = New-Object Windows.Thickness(0, 0, 8, 0)
            $chk.IsChecked = (Test-LibrarySelected $r)
            $chk.Tag = $r
            $chk.ToolTip = 'Marque para instalar em lote'
            $chk.add_Click({
                $row = $this.Tag
                Set-LibrarySelected $row ([bool]$this.IsChecked)
                $b = $this.Parent
                while ($b -and -not ($b -is [Windows.Controls.Border])) { $b = $b.Parent }
                if ($b) {
                    $b.BorderBrush = Br $(if ($this.IsChecked) { '#2A1A44' } else { '#161616' })
                }
            })
            [Windows.Controls.Grid]::SetColumn($chk, 0)
            [void]$grid.Children.Add($chk)
        } else {
            $cPad = New-Object Windows.Controls.ColumnDefinition
            $cPad.Width = [Windows.GridLength]::Auto
            [void]$grid.ColumnDefinitions.Insert(0, $cPad)
            $pad = New-Object Windows.Controls.Border
            $pad.Width = 14
            $pad.Margin = New-Object Windows.Thickness(0, 0, 8, 0)
            [Windows.Controls.Grid]::SetColumn($pad, 0)
            [void]$grid.Children.Add($pad)
        }

        # plataforma (deslocada para a coluna 1)
        $badge = New-Object Windows.Controls.Border
        $badge.BorderBrush = Br (Get-PlatformColor $r.Platform)
        $badge.BorderThickness = New-Object Windows.Thickness(1)
        $badge.Padding = New-Object Windows.Thickness(4, 1, 4, 1)
        $badge.HorizontalAlignment = 'Left'
        $badge.VerticalAlignment = 'Center'
        $badge.ToolTip = Get-PlatformTooltip $r.Platform
        $bt = New-Object Windows.Controls.TextBlock
        $bt.Text = $r.Label
        $bt.Foreground = Br (Get-PlatformColor $r.Platform)
        $bt.FontSize = 9
        $bt.FontWeight = 'Bold'
        $badge.Child = $bt
        [Windows.Controls.Grid]::SetColumn($badge, 1)
        [void]$grid.Children.Add($badge)

        # nome + caminho
        $stack = New-Object Windows.Controls.StackPanel
        $stack.Margin = New-Object Windows.Thickness(6, 0, 6, 0)
        $stack.VerticalAlignment = 'Center'

        $nm = New-Object Windows.Controls.TextBlock
        $nm.Text = $r.Name
        $nm.Foreground = Br '#CCCCCC'
        $nm.FontSize = 10
        $nm.FontWeight = 'Bold'
        $nm.TextTrimming = 'CharacterEllipsis'
        [void]$stack.Children.Add($nm)

        $rel = New-Object Windows.Controls.TextBlock
        $rel.Text = $r.Rel
        $rel.Foreground = Br '#555555'
        $rel.FontSize = 9
        $rel.TextTrimming = 'CharacterEllipsis'
        [void]$stack.Children.Add($rel)

        [Windows.Controls.Grid]::SetColumn($stack, 2)
        [void]$grid.Children.Add($stack)

        # tamanho
        $sz = New-Object Windows.Controls.TextBlock
        $sz.Text = $r.SizeText
        $sz.Foreground = Br '#666666'
        $sz.FontSize = 9
        $sz.VerticalAlignment = 'Center'
        $sz.HorizontalAlignment = 'Right'
        $sz.Margin = New-Object Windows.Thickness(0, 0, 10, 0)
        [Windows.Controls.Grid]::SetColumn($sz, 3)
        [void]$grid.Children.Add($sz)

        # status / ação: INSTALADO (já no OPL), JÁ NO OPL (cópia),
        # JÁ NO PENDRIVE (outra unidade) ou INSTALAR
        if ($r.Status -eq 'installed') {
            $act = New-Object Windows.Controls.TextBlock
            $act.Text = $(if ($r.Where -eq 'COPIA') { 'JÁ NO OPL' } else { 'INSTALADO' })
            $act.Foreground = Br '#50FA7B'
            $act.FontSize = 9
            $act.FontWeight = 'Bold'
            $act.VerticalAlignment = 'Center'
            $act.ToolTip = $(switch ($r.Where) {
                'COPIA'     { 'Este arquivo é o mesmo jogo que já está instalado em ul.*' }
                'DVD\'      { 'Está em DVD\ — o OPL lê esse ISO direto, sem instalar' }
                default     { 'Já aparece no menu do OPL' }
            })
        } elseif ($r.Status -eq 'elsewhere') {
            $act = New-Object Windows.Controls.TextBlock
            $act.Text = ('JÁ NO PENDRIVE {0}:' -f $r.Where)
            $act.Foreground = Br '#F1FA8C'
            $act.FontSize = 9
            $act.FontWeight = 'Bold'
            $act.VerticalAlignment = 'Center'
            $act.ToolTip = ('Este jogo já está instalado no pendrive {0}: — não precisa instalar de novo.' -f $r.Where)
        } elseif ($r.Status -eq 'pending' -and $r.File) {
            $act = New-Object Windows.Controls.Button
            $act.Style = $win.FindResource('BtnTiny')
            $act.Content = 'INSTALAR'
            $act.Foreground = Br '#8BE9FD'
            $act.BorderBrush = Br '#2B5F6B'
            $act.Tag = $r
            $act.ToolTip = $(if ($r.Container) { 'Extrair o arquivo e instalar no OPL' } else { 'Adicionar à lista de instalação' })
            $act.Add_Click({ param($sender, $e) Add-LibraryGame $sender.Tag })
        } else {
            $act = New-Object Windows.Controls.TextBlock
            $act.Text = '—'
            $act.Foreground = Br '#333333'
            $act.FontSize = 9
            $act.VerticalAlignment = 'Center'
        }
        $act.Margin = New-Object Windows.Thickness(0, 0, 10, 0)
        [Windows.Controls.Grid]::SetColumn($act, 4)
        [void]$grid.Children.Add($act)

        $border.Child = $grid
        
        # Menu de contexto (clique direito) expandido
        $contextMenu = New-Object Windows.Controls.ContextMenu
        
        if ($r.Status -eq 'pending' -and $r.File) {
            $itemInstall = New-Object Windows.Controls.MenuItem
            $itemInstall.Header = '▶ Instalar'
            $itemInstall.Tag = $r
            $itemInstall.Add_Click({ param($sender, $e) Add-LibraryGame $sender.Tag })
            [void]$contextMenu.Items.Add($itemInstall)
            
            $contextMenu.Items.Add((New-Object Windows.Controls.Separator))
        }
        
        if ($r.File -and (Test-Path -LiteralPath $r.File -ErrorAction SilentlyContinue)) {
            $itemOpen = New-Object Windows.Controls.MenuItem
            $itemOpen.Header = '📂 Abrir local'
            $itemOpen.Tag = $r
            $itemOpen.Add_Click({
                param($sender, $e)
                $item = $sender.Tag
                if ($item.File) {
                    $parent = Split-Path -Parent $item.File
                    if (Test-Path -LiteralPath $parent) {
                        Start-Process 'explorer.exe' -ArgumentList $parent
                    }
                }
            })
            [void]$contextMenu.Items.Add($itemOpen)
            
            $itemCopy = New-Object Windows.Controls.MenuItem
            $itemCopy.Header = '📋 Copiar'
            $itemCopy.Tag = $r
            $itemCopy.Add_Click({
                param($sender, $e)
                $item = $sender.Tag
                if ($item.File) {
                    try {
                        Set-Clipboard -Value $item.File
                        Show-Toast 'Copiado' 'Caminho copiado para a área de transferência' 'ok'
                    } catch { }
                }
            })
            [void]$contextMenu.Items.Add($itemCopy)
            
            $itemMove = New-Object Windows.Controls.MenuItem
            $itemMove.Header = '➡ Mover'
            $itemMove.Tag = $r
            $itemMove.Add_Click({
                param($sender, $e)
                $item = $sender.Tag
                Show-Toast 'Funcionalidade' 'Ação de mover será implementada em breve' 'info'
            })
            [void]$contextMenu.Items.Add($itemMove)
            
            $itemDelete = New-Object Windows.Controls.MenuItem
            $itemDelete.Header = '🗑 Apagar'
            $itemDelete.Tag = $r
            $itemDelete.Add_Click({
                param($sender, $e)
                $item = $sender.Tag
                Show-Confirm 'APAGAR ARQUIVO' ("Tem certeza que deseja apagar:`n`n{0}`n`nEsta ação não pode ser desfeita." -f $item.File) -OnYes {
                    try {
                        if (Test-Path -LiteralPath $item.File) {
                            Remove-Item -LiteralPath $item.File -Force
                            Show-Toast 'Arquivo apagado' $item.Name 'ok'
                            Refresh-Library
                        }
                    } catch {
                        Show-Toast 'Erro ao apagar' $_.Exception.Message 'error'
                    }
                }
            })
            [void]$contextMenu.Items.Add($itemDelete)
            
            $itemCut = New-Object Windows.Controls.MenuItem
            $itemCut.Header = '✂ Recortar'
            $itemCut.Tag = $r
            $itemCut.Add_Click({
                param($sender, $e)
                $item = $sender.Tag
                Show-Toast 'Funcionalidade' 'Ação de recortar será implementada em breve' 'info'
            })
            [void]$contextMenu.Items.Add($itemCut)
            
            $contextMenu.Items.Add((New-Object Windows.Controls.Separator))
        }
        
        $itemProps = New-Object Windows.Controls.MenuItem
        $itemProps.Header = '⚙ Propriedades'
        $itemProps.Tag = $r
        $itemProps.Add_Click({
            param($sender, $e)
            $item = $sender.Tag
            $details = '📱 {0} · {1}' -f $item.Label, $item.Name
            if ($item.Serial) { $details += "`n🔢 Serial: " + $item.Serial }
            if ($item.SizeText) { $details += "`n📊 Tamanho: " + $item.SizeText }
            if ($item.File) { $details += "`n📁 Arquivo: " + $item.File }
            if ($item.Rel) { $details += "`n📂 Caminho: " + $item.Rel }
            if ($item.Status) { $details += "`n📈 Status: " + $item.Status }
            if ($item.Platform) { $details += "`n🎮 Plataforma: " + $item.Platform }
            Show-Toast 'Propriedades' $details 'ok'
        })
        [void]$contextMenu.Items.Add($itemProps)
        
        $border.ContextMenu = $contextMenu
        
        # Duplo clique para instalar (se pending). Border é Decorator: sem
        # MouseDoubleClick, então usamos o evento roteado + ClickCount.
        $border.AddHandler([Windows.Controls.Border]::MouseLeftButtonDownEvent, [Windows.Input.MouseButtonEventHandler]{
            param($sender, $e)
            if ($e.ClickCount -ne 2) { return }
            $item = $sender.Tag
            if ($item.Status -eq 'pending' -and $item.File) {
                Add-LibraryGame $item
            }
        })

        $border.Add_MouseEnter({ param($sender, $e) $sender.Background = Br '#0D0D0D' })
        $border.Add_MouseLeave({ param($sender, $e) $sender.Background = Br '#000000' })
        [void]$ui.LibraryPanel.Children.Add($border)
    }
}

function Add-LibraryGame {
    param($Item)

    if (-not $Item) { return }

    if ($Item.Platform -ne 'PS2') {
        Show-Toast 'Plataforma não suportada' ("{0}: o OPL executa apenas jogos de PS2." -f $Item.Label) 'warn'
        return
    }
    if ($Item.Instalado) {
        if ($Item.Where -eq 'COPIA') {
            Show-Toast 'Já está no OPL' ('{0} é o mesmo jogo que já está instalado em ul.*' -f $Item.Name) 'warn'
        } elseif ($Item.Status -eq 'elsewhere') {
            Show-Toast 'Já está no pendrive' ('{0} já está instalado em {1}: — não precisa instalar de novo.' -f $Item.Name, $Item.Where) 'warn'
        } else {
            Show-Toast 'Já está no pendrive' ('{0} já aparece no menu do OPL.' -f $Item.Name) 'warn'
        }
        return
    }
    if (-not $Item.File) { return }

    if ($Item.Container) {
        # Compactado: extrai em segundo plano e instala (se o auto-instalar estiver ligado).
        $before = $S.Files.Count
        Add-DroppedFiles -Files @($Item.File) -Auto
        if ($S.Extract -or $S.Files.Count -gt $before) {
            Show-Toast 'Extraindo e instalando' $Item.Name 'ok'
            Set-Status 'EXTRAINDO...' '#F1FA8C'
        }
        return
    }

    $before = $S.Files.Count
    Add-IsoFile $Item.File
    if ($S.Files.Count -gt $before) {
        Show-Toast 'Adicionado à instalação' $Item.Name 'ok'
        Set-Status 'PRONTO PARA INSTALAR' '#8BE9FD'
    }
}

function Refresh-Library {
    if ($env:EASYROMS_SNAPSHOT) { return }

    if (-not $S.Drive) {
        Stop-LibraryScan
        $S.LibLetter = $null
        $S.Lib = @()
        $S.LibReport = $null
        $ui.LibraryInfo.Text = ''
        Show-LibraryMessage 'SELECIONE UMA UNIDADE'
        return
    }

    if ($S.Busy) { return }
    Start-LibraryScan
}

function Initialize-GamesTabs {
    $ui.TabOpl.Add_Click({
        param($sender, $e)
        Set-GamesView 'opl'
    })
    $ui.TabLibrary.Add_Click({
        param($sender, $e)
        Set-GamesView 'library'
        if ($S.LibLetter -ne $S.Drive) { Refresh-Library }
    })
    Set-GamesView 'opl'
}

# ---------------------------------------------------------------- motor assíncrono

. (Join-Path $PSScriptRoot 'Worker.ps1')

function Start-Worker {
    param([array]$Jobs)

    $sync = [hashtable]::Synchronized(@{
        Jobs     = $Jobs
        Log      = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        Percent  = 0
        Done     = [double]0
        Total    = [double]0
        PartPct  = 0
        Current  = ''
        Cancel   = $false
        Finished = $false
        Failed   = 0
        LibPath  = (Join-Path $repoRoot 'lib\UlFormat.ps1')
    })

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($WorkerScript)
    [void]$ps.AddParameter('Sync', $sync)

    $S.Sync = $sync
    $S.PowerShell = $ps
    $S.Handle = $ps.BeginInvoke()
    $S.LogIndex = 0

    $S.Busy = $true
    Set-Busy $true

    $ui.Bar.Value = 0
    $ui.BarPct.Text = '0%'
    $ui.BarText.Text = 'INICIANDO...'
    $ui.Bar.IsIndeterminate = $true

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $timer.Add_Tick({ Update-Worker })
    $S.Timer = $timer
    $timer.Start()
}

function Set-Busy {
    param([bool]$Busy)
    $ui.BtnInstall.IsEnabled = -not $Busy
    $ui.BtnRefresh.IsEnabled = -not $Busy
    $ui.BtnClearFiles.IsEnabled = -not $Busy
    $ui.DropZone.IsEnabled = -not $Busy
    $ui.BtnAuto.IsEnabled = -not $Busy
    $ui.NameBox.IsEnabled = (-not $Busy) -and ($S.Files.Count -le 1)
    if ($Busy) {
        Set-Status 'TRABALHANDO...' '#F1FA8C'
    }
}

function Update-Worker {
    $sync = $S.Sync
    if (-not $sync) { return }

    while ($S.LogIndex -lt $sync.Log.Count) {
        $raw = [string]$sync.Log[$S.LogIndex]
        $S.LogIndex++
        $level, $msg = $raw -split '\|', 2
        Add-Log $msg $level
    }

    $ui.Bar.Value = [double]$sync.Percent
    $ui.BarPct.Text = ('{0}%' -f [int]$sync.Percent)

    if ($sync.Total -gt 0) {
        $ui.BarText.Text = ('{0} · {1} / {2}' -f
            $sync.Current.ToUpper(), (Format-Size $sync.Done), (Format-Size $sync.Total))
    }

    if ($sync.Finished) {
        $S.Timer.Stop()
        $S.Timer = $null
        $ui.Bar.IsIndeterminate = $false

        try { if ($S.PowerShell) { $S.PowerShell.Dispose() } } catch { }
        $S.PowerShell = $null
        $S.Handle = $null
        $S.Sync = $null
        $S.Busy = $false
        $S.Force = $false

        Set-Busy $false

        if ($sync.Cancel) {
            $ui.BarText.Text = 'CANCELADO'
            Set-Status 'CANCELADO' '#F1FA8C'
        } elseif ($sync.Failed -gt 0) {
            $ui.BarText.Text = 'CONCLUÍDO COM ERROS'
            Set-Status 'CONCLUÍDO COM ERROS' '#FF5555'
            Show-Toast 'Falha na operação' ('{0} item(ns) falharam. Veja o log.' -f $sync.Failed) 'error'
            Play-Sound 'error'
        } else {
            $ui.BarText.Text = 'CONCLUÍDO'
            Set-Status 'PRONTO' '#50FA7B'
            Show-Toast 'Concluído' 'Pendrive pronto para usar no PS2.' 'ok'
            Play-Sound 'success'
        }

        Load-Games
        Update-DriveChips
        Refresh-Library
        if (-not $sync.Cancel -and $sync.Failed -eq 0) {
            Remove-InstalledTempFiles

            # O jogo já está no pendrive: sai da fila, senão ele continuaria
            # ali como se ainda faltasse instalar (e um INSTALAR sem querer
            # copiaria tudo de novo).
            $done = Get-InstalledSerials
            $left = 0
            foreach ($f in @($S.Files)) {
                if ($f.Serial -and $done.ContainsKey([string]$f.Serial)) {
                    [void]$S.Files.Remove($f)
                    $left++
                }
            }
            if ($left -gt 0) { Render-Files }
        }

        # Load-Games recalcula o uso do disco; restaura o resultado da operação.
        if ($sync.Cancel) {
            $ui.BarText.Text = 'CANCELADO'
        } elseif ($sync.Failed -gt 0) {
            $ui.BarText.Text = 'CONCLUÍDO COM ERROS'
        } else {
            $ui.Bar.Value = 100
            $ui.BarPct.Text = '100%'
            $ui.BarText.Text = 'CONCLUÍDO'
        }

        # Mantém o resultado na barra por alguns segundos antes de voltar a
        # mostrar o uso do disco (o timer de 1 s não apaga o "CONCLUÍDO").
        $S.ResultUntil = (Get-Date).AddSeconds(6)
    }
}

# ---------------------------------------------------------------- instalar

function Start-Install {
    if ($S.Busy) { return }
    if ($S.Extract) { return }
    if (-not $S.Drive) { Show-Toast 'Sem pendrive' 'Selecione uma unidade acima.' 'error'; return }
    if ($S.Files.Count -eq 0) { Show-Toast 'Nada para instalar' 'Arraste um .iso para a área pontilhada.' 'error'; return }

    $invalid = @($S.Files | Where-Object { -not $_.Valid })
    if ($invalid.Count -gt 0) {
        Show-Toast 'ISO inválido na lista' ('{0} arquivo(s) não são de PS2.' -f $invalid.Count) 'error'
        return
    }

    $root = "$($S.Drive):\"
    $jobs = New-Object System.Collections.ArrayList
    $totalBytes = [double]0

    foreach ($f in $S.Files) {
        $name = if ($S.Files.Count -eq 1 -and $ui.NameBox.Text.Trim()) {
            ConvertTo-AsciiName $ui.NameBox.Text
        } else {
            ConvertTo-AsciiName $f.Clean
        }

        if ([string]::IsNullOrWhiteSpace($name)) {
            Show-Toast 'Nome vazio' 'Digite um nome para o jogo.' 'error'
            return
        }

        $mode = 'ul'   # sempre UL.*: divide em 1 GiB e aceita ISO de qualquer tamanho
        $media = if ($f.Size -gt 700MB) { 0x14 } else { 0x12 }

        [void]$jobs.Add([pscustomobject]@{
            Op     = 'install'
            Iso    = $f.Path
            Root   = $root
            Name   = $name
            Serial = $f.Serial
            Media  = [byte]$media
            Mode   = $mode
            Force  = $true
        })
        $totalBytes += $f.Size
    }

    $di = New-Object IO.DriveInfo($root)
    if ($di.AvailableFreeSpace -lt ($totalBytes + 4096)) {
        Show-Toast 'Espaço insuficiente' ('Precisa de {0}, livre {1}.' -f (Format-Size $totalBytes), (Format-Size $di.AvailableFreeSpace)) 'error'
        return
    }

    # duplicados? (mesmo serial já instalado no OPL, ou o mesmo jogo já em DVD\)
    $dups = @()
    $existing = @(Read-UlEntries $root)
    foreach ($j in $jobs) {
        $hit = $existing | Where-Object { $_.Serial -eq $j.Serial } | Select-Object -First 1
        if ($hit) {
            $dups += ('{0} (já instalado como "{1}")' -f $j.Name, $hit.Nome)
            continue
        }
        $dvd = $S.Games | Where-Object { $_.Tipo -eq 'dvd' -and $_.Serial -eq $j.Serial } | Select-Object -First 1
        if ($dvd) { $dups += ('{0} (já existe em DVD\{1}.iso)' -f $j.Name, $dvd.Nome) }
    }

    if ($dups.Count -gt 0) {
        Show-Confirm -Title 'Substituir jogos existentes?' `
            -Text ("Estes jogos já estão no pendrive e serão regravados:`n`n{0}" -f ($dups -join "`n")) `
            -YesLabel 'SUBSTITUIR' `
            -OnYes ({ Start-Worker -Jobs $jobs }).GetNewClosure()
        return
    }

    Add-Log ('Instalando {0} jogo(s) em {1}:...' -f $jobs.Count, $root) 'info'
    Start-Worker -Jobs $jobs
}

# ---------------------------------------------------------------- exportar / remover

function Start-Export {
    param($Game)

    if ($S.Busy) { return }

    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pasta de destino do .iso remontado'
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    Start-ExportTo -Game $Game -Dest (Join-Path $dlg.SelectedPath ($Game.Nome + '.iso'))
}

function Start-ExportTo {
    <#
        Parte sem diálogo do Start-Export: recebe o destino pronto.
        É o que o teste automatizado usa (não dá para clicar em diálogo nativo).
    #>
    param($Game, [string]$Dest)

    if ($S.Busy) { return }
    if (-not $Dest) { return }

    $job = [pscustomobject]@{
        Op = 'export'; Root = "$($S.Drive):\"; Serial = $Game.Serial; Name = $Game.Nome; Dest = $Dest
    }

    if (Test-Path -LiteralPath $Dest) {
        Show-Confirm -Title 'Sobrescrever arquivo?' -Text ("Já existe:`n$Dest") -YesLabel 'SOBRESCREVER' `
            -OnYes ({ Start-Worker -Jobs @($job) }).GetNewClosure()
        return
    }

    Start-Worker -Jobs @($job)
}

function Confirm-Remove {
    param($Game)

    if ($S.Busy) { return }

    $label = if ($Game.Tipo -eq 'dvd') { "Apagar o arquivo $($Game.Nome).iso da pasta DVD?" } else { "Apagar '$($Game.Nome)' ($($Game.Partes) pedaço(s)) e remover do ul.cfg?" }

    $onYes = {
        try {
            if ($Game.Tipo -eq 'dvd') {
                Remove-Item -LiteralPath $Game.Path -Force
                Add-Log "Removido: $($Game.Nome).iso" 'warn'
            } else {
                $removed = Remove-UlGame -Root "$($S.Drive):\" -Serial $Game.Serial
                Add-Log ("Removido: {0} ({1} arquivo(s))" -f $Game.Nome, $removed.Count) 'warn'
            }
            Show-Toast 'Removido' $Game.Nome 'warn'
            Load-Games
            Update-Space
        } catch {
            Add-Log "Erro ao remover: $($_.Exception.Message)" 'error'
            Show-Toast 'Erro ao remover' $_.Exception.Message 'error'
        }
    }.GetNewClosure()

    Show-Confirm -Title 'Remover do pendrive' -Text ($label + "`n`nEssa ação não pode ser desfeita.") -YesLabel 'APAGAR' -OnYes $onYes
}

# ---------------------------------------------------------------- eventos

# Rede de segurança: um erro dentro de um handler não pode fechar a janela.
# (foi assim que um bug de variável virou "cliquei e o app sumiu")
$win.Dispatcher.Add_UnhandledException({
    param($sender, $e)

    $e.Handled = $true
    $msg = $e.Exception.GetBaseException().Message

    try { Add-Log ("ERRO inesperado: {0}" -f $msg) 'error' } catch { }
    try { Set-Status 'ERRO' '#FF5555' } catch { }
    try { Show-Toast 'Erro inesperado' $msg 'error' } catch { }

    try {
        $log = Join-Path ([IO.Path]::GetTempPath()) 'EasyRomsToOPL-error.log'
        ("[{0}] {1}`r`n{2}`r`n" -f (Get-Date).ToString('s'), $e.Exception, $e.Exception.StackTrace) |
            Add-Content -LiteralPath $log -Encoding UTF8
    } catch { }
})

$ui.BtnClose.Add_Click({ $win.Close() })
$ui.BtnMin.Add_Click({ $win.WindowState = 'Minimized' })
$ui.BtnMax.Add_Click({
    $win.WindowState = if ($win.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
})

# glossário e som
$ui.BtnHelp.Add_Click({ Show-Help })
$ui.BtnHelpClose.Add_Click({ Hide-Help })
$ui.BtnInfoClose.Add_Click({ $ui.InfoOverlay.Visibility = 'Collapsed' })
$ui.BtnSound.Add_Click({
    $S.Sound = [bool]$ui.BtnSound.IsChecked
    $ui.BtnSound.Content = $(if ($S.Sound) { 'SOM: ON' } else { 'SOM: OFF' })
    Save-UiSettings
    Play-Sound 'click'
    Add-Log ('Sons da interface: {0}' -f $(if ($S.Sound) { 'LIGADOS' } else { 'DESLIGADOS' })) 'dim'
})

$ui.BtnInstall.Add_Click({ Start-Install })

$ui.BtnInstallSelected.Add_Click({ Install-SelectedLibraryGames })

$ui.BtnRefresh.Add_MouseLeftButtonUp({
    Update-DriveChips
    Load-Games
    Add-Log 'Lista recarregada.' 'dim'
    Refresh-Library
})

$ui.BtnClearFiles.Add_MouseLeftButtonUp({
    $S.Files.Clear()
    Render-Files
    $ui.NameBox.Text = ''
})

$ui.BtnAuto.Add_Click({
    $S.AutoInstall = [bool]$ui.BtnAuto.IsChecked
    Add-Log ('Instalar ao soltar: {0}' -f $(if ($S.AutoInstall) { 'LIGADO' } else { 'DESLIGADO' })) 'dim'
})

function Toggle-Log {
    $open = ($ui.LogBody.Visibility -ne 'Visible')
    $ui.LogBody.Visibility = if ($open) { 'Visible' } else { 'Collapsed' }
    $ui.BtnLogToggle.Text = if ($open) { 'FECHAR ▴' } else { 'ABRIR ▾' }
}

$ui.BtnLogToggle.Add_MouseLeftButtonUp({
    param($sender, $e)
    Toggle-Log
    $e.Handled = $true
})

$ui.LogHeader.Add_MouseLeftButtonUp({
    param($sender, $e)
    Toggle-Log
    $e.Handled = $true
})

$ui.BtnCancelConfirm.Add_Click({ Hide-Confirm })
$ui.BtnYesConfirm.Add_Click({
    $action = $S.Confirm
    Hide-Confirm
    if (-not $action) { return }
    try {
        & $action
    } catch {
        Add-Log ("Erro ao executar a ação: {0}" -f $_.Exception.Message) 'error'
        Show-Toast 'Ação falhou' $_.Exception.Message 'error'
    }
})

$ui.BtnCopyLog.Add_MouseLeftButtonUp({
    param($sender, $e)
    try {
        $text = (New-Object Windows.Documents.TextRange($ui.LogBox.Document.ContentStart, $ui.LogBox.Document.ContentEnd)).Text
        [Windows.Clipboard]::SetText($text)
        Show-Toast 'Log copiado' 'Conteúdo na área de transferência.' 'info'
    } catch { }
    $e.Handled = $true
})

$ui.DropZone.Add_MouseLeftButtonUp({ Show-AddFilesDialog })

$win.Add_DragOver({
    param($sender, $e)
    if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) {
        $e.Effects = 'Copy'
        $ui.DropZone.BorderBrush = Br '#8BE9FD'
        $ui.DropTitle.Text = $(if ($S.AutoInstall) { 'SOLTE PARA INSTALAR' } else { 'SOLTE PARA ADICIONAR' })
    } else {
        $e.Effects = 'None'
    }
    $e.Handled = $true
})

$win.Add_DragLeave({
    $ui.DropZone.BorderBrush = Br '#333333'
    $ui.DropTitle.Text = 'ARRASTE O JOGO AQUI'
})

$win.Add_Drop({
    param($sender, $e)
    $ui.DropZone.BorderBrush = Br '#333333'
    $ui.DropTitle.Text = 'ARRASTE O JOGO AQUI'
    Add-DroppedFiles -Files $e.Data.GetData([Windows.DataFormats]::FileDrop) -Auto
    $e.Handled = $true
})

function Hide-ConfirmIfOpen {
    if ($ui.Overlay.Visibility -eq 'Visible') { Hide-Confirm }
}

$win.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Escape') {
        if ($ui.InfoOverlay.Visibility -eq 'Visible') {
            $ui.InfoOverlay.Visibility = 'Collapsed'
            $e.Handled = $true
            return
        }
        if ($ui.HelpOverlay.Visibility -eq 'Visible') {
            Hide-Help
            $e.Handled = $true
            return
        }
        Hide-ConfirmIfOpen
    }
})

# ---------------------------------------------------------------- boot

# Som de abertura no estilo do console (sintetizado pelo app; nada da Sony).
# Não toca no modo de captura de tela nem quando o som está desligado.
if (-not $env:EASYROMS_SNAPSHOT) {
    $win.Add_Loaded({ Play-Sound 'boot' })
}

# A versão vem do CHANGELOG (um lugar só para lembrar de atualizar).
try {
    $cl = Join-Path $repoRoot 'CHANGELOG.md'
    if (Test-Path -LiteralPath $cl) {
        $m = [regex]::Match((Get-Content -LiteralPath $cl -Raw -Encoding UTF8), '##\s*\[(\d+\.\d+\.\d+)\]')
        if ($m.Success) { $ui.VersionText.Text = ('EASYROMSTOOPL {0} · MIT' -f $m.Groups[1].Value) }
    }
} catch { }

# Limpa temporários de execuções anteriores (extrações antigas).
try {
    $tempBase = Join-Path ([IO.Path]::GetTempPath()) 'EasyRomsToOPL'
    if (Test-Path -LiteralPath $tempBase) {
        Get-ChildItem -LiteralPath $tempBase -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
} catch { }

Add-Log 'EASYROMS::OPL — motor ul.* carregado' 'ok'
Add-Log ('CRC de referência: {0} (GTA) · {1} (Medalha)' -f ('{0:X8}' -f (Get-UsbaCrc32 'GTA - San Andreas')), ('{0:X8}' -f (Get-UsbaCrc32 'Medalha de Honra'))) 'dim'

if ($Drive) {
    $S.Drive = $Drive.TrimEnd(':', '\').ToUpper()
}

Initialize-GamesTabs

Update-Hardware
Update-DriveChips
Load-Games
Render-Files
Refresh-Library

foreach ($p in @($Iso)) {
    if ($p) { Add-IsoFile $p }
}

if (-not $S.Drive) {
    Show-Toast 'Nenhum pendrive' 'Conecte um pendrive FAT32 para começar.' 'warn'
} else {
    Set-Status ("PRONTO · {0}:" -f $S.Drive) '#50FA7B'
}

# ---------------------------------------------------------------- hot-plug
# Um timer de 1 s compara só a lista de letras (barato). Se um pendrive
# entrar ou sair, os chips e a lista de jogos são atualizados na hora.
if (-not $env:EASYROMS_SNAPSHOT) {
    $S.DriveProbe = @(Get-DriveProbe)
    $S.DriveTimer = New-Object Windows.Threading.DispatcherTimer
    $S.DriveTimer.Interval = [TimeSpan]::FromSeconds(1)
    $S.DriveTimer.Add_Tick({ Sync-Drives })
    $S.DriveTimer.Start()
    $win.Add_Closed({
        if ($S.DriveTimer) { $S.DriveTimer.Stop(); $S.DriveTimer = $null }
        Stop-LibraryScan
        if ($S.Extract) {
            try { $S.Extract.Timer.Stop() } catch { }
            try { $S.Extract.PowerShell.Dispose() } catch { }
            $S.Extract = $null
        }
        foreach ($root in @($S.TempRoots)) { Remove-TempRoot $root }
    })
}

# Modo de captura: usado para gerar o screenshot da documentação.
if ($env:EASYROMS_SNAPSHOT) {
    $win.Show()
    $win.UpdateLayout()

    # Deixa o dispatcher rodar um pouco (a varredura da biblioteca usa timer).
    function Wait-Snapshot {
        param([int]$Ms = 250)
        $frame = New-Object Windows.Threading.DispatcherFrame
        $t = New-Object Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds($Ms)
        $t.Add_Tick({ $t.Stop(); $frame.Continue = $false })
        $t.Start()
        [Windows.Threading.Dispatcher]::PushFrame($frame)
    }

    if ($env:EASYROMS_SNAPSHOT_VIEW -eq 'help') {
        Show-Help
        Wait-Snapshot 400
    } elseif ($env:EASYROMS_SNAPSHOT_VIEW -eq 'library' -and $S.Drive) {
        Set-GamesView 'library'
        Start-LibraryScan
        $deadline = (Get-Date).AddSeconds(20)
        Wait-Snapshot 300
        while ((Get-Date) -lt $deadline -and $ui.LibraryInfo.Text -match 'VARRENDO') { Wait-Snapshot 250 }
        Wait-Snapshot 400
    }

    $win.UpdateLayout()
    [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
        [Windows.Threading.DispatcherPriority]::Render, [action] { })

    $w = [int]$win.ActualWidth
    $h = [int]$win.ActualHeight
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($win)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [IO.File]::Create($env:EASYROMS_SNAPSHOT)
    try { $enc.Save($fs) } finally { $fs.Dispose() }
    $win.Close()
    return
}

[void]$win.ShowDialog()
