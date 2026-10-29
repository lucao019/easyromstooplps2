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

# ---------------------------------------------------------------- carregar XAML

$xamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$win = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))

$ui = @{}
@(
    'Root', 'DropZone', 'DropTitle', 'FileCount', 'BtnClearFiles', 'FilesPanel', 'ModePanel',
    'NameBox', 'BtnSimulate', 'BtnInstall', 'HintText', 'DrivesPanel', 'DriveCount', 'StatSpace',
    'StatGames', 'Bar', 'BarText', 'BarPct', 'BtnRefresh', 'GamesPanel', 'BtnCopyLog', 'LogBox',
    'StatusText', 'BusyDot', 'Toasts', 'Overlay', 'ConfirmTitle', 'ConfirmText', 'BtnCancelConfirm',
    'BtnYesConfirm', 'BtnMin', 'BtnMax', 'BtnClose', 'VersionText',
    'TabOpl', 'TabLibrary', 'LibraryInfo', 'OplView', 'LibraryView', 'LibraryPanel'
) | ForEach-Object { $ui[$_] = $win.FindName($_) }

# ---------------------------------------------------------------- estado

$S = @{
    Drive      = $null          # letra, ex. 'F'
    Drives     = @()
    Files      = New-Object System.Collections.ArrayList
    Mode       = 'ul'
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
}

$BRUSH = @{}
function Br([string]$hex) {
    if (-not $BRUSH.ContainsKey($hex)) {
        $BRUSH[$hex] = [Windows.Media.BrushConverter]::new().ConvertFromString($hex)
    }
    return $BRUSH[$hex]
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

# ---------------------------------------------------------------- drives

function Get-DriveList {
    $list = New-Object System.Collections.ArrayList
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady) { continue }
        if ($d.DriveType -ne 'Removable' -and $d.DriveType -ne 'Fixed') { continue }
        $letter = $d.Name.Substring(0, 1)
        if ($letter -eq $env:SystemDrive.Substring(0, 1)) { continue }
        [void]$list.Add([pscustomobject]@{
            Letter = $letter
            Root   = $d.Name
            Label  = $d.VolumeLabel
            Format = $d.DriveFormat
            Free   = [double]$d.AvailableFreeSpace
            Total  = [double]$d.TotalSize
            Type   = [string]$d.DriveType
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
        $chip.Content = ('{0}{1}: {2} GB' -f $(if ($d.Type -eq 'Removable') { '' } else { 'HD ' }), $d.Letter, [math]::Round($d.Free / 1GB, 0))
        $chip.ToolTip = ('{0} · {1} · {2} livre de {3}{4}' -f $d.Label, $d.Format, (Format-Size $d.Free), (Format-Size $d.Total), $(if ($d.Type -eq 'Removable') { '' } else { ' · unidade fixa' }))
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
    if (($now -join ';') -eq (@($S.DriveProbe) -join ';')) { return }
    $S.DriveProbe = $now

    $before = @($S.Drives | ForEach-Object { $_.Letter })
    $selected = $S.Drive

    Update-DriveChips
    Load-Games
    Update-Space
    Refresh-Library

    $after = @($S.Drives | ForEach-Object { $_.Letter })
    $added = @($after | Where-Object { $before -notcontains $_ })
    $removed = @($before | Where-Object { $after -notcontains $_ })

    foreach ($l in $added) { Add-Log ("Unidade conectada: {0}:" -f $l) 'ok' }
    foreach ($l in $removed) { Add-Log ("Unidade removida: {0}:" -f $l) 'warn' }

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
    }
}
function Update-Space {
    $ui.StatGames.Text = ('{0} JOGO(S)' -f $S.Games.Count).ToUpper()
    if (-not $S.Drive) {
        $ui.StatSpace.Text = '—'
        return
    }
    try {
        $di = New-Object IO.DriveInfo("$($S.Drive):\")
        $ui.StatSpace.Text = ('{0} LIVRES DE {1}' -f (Format-Size $di.AvailableFreeSpace), (Format-Size $di.TotalSize))

        if (-not $S.Busy) {
            $used = 0
            if ($di.TotalSize -gt 0) { $used = [int](100 * ($di.TotalSize - $di.AvailableFreeSpace) / $di.TotalSize) }
            $ui.Bar.Value = $used
            $ui.BarPct.Text = ('{0}%' -f $used)
            $ui.BarText.Text = 'USO DO PENDRIVE'
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

function Render-Files {
    $ui.FilesPanel.Children.Clear()

    if ($S.Files.Count -eq 0) {
        $ui.FileCount.Text = 'NENHUM ARQUIVO'
        $ui.NameBox.IsEnabled = $true
        $ui.HintText.Text = 'A instalação grava pedaços de 1 GiB e atualiza o ul.cfg. Nada é apagado sem confirmação.'
        return
    }

    $ui.FileCount.Text = ('{0} ARQUIVO(S) · {1}' -f $S.Files.Count, (Format-Size (($S.Files | Measure-Object Size -Sum).Sum)))
    $ui.NameBox.IsEnabled = ($S.Files.Count -eq 1)

    if ($S.Files.Count -eq 1) {
        $ui.HintText.Text = 'O nome acima vai para o menu do OPL. Com vários arquivos, cada um usa o próprio nome.'
    } else {
        $ui.HintText.Text = 'Vários arquivos: cada ISO usa o próprio nome de arquivo como nome no menu.'
    }

    foreach ($f in $S.Files) {
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
            $meta.Foreground = Br '#666666'
        } else {
            $meta.Text = ('INVÁLIDO · ' + $f.Error)
            $meta.Foreground = Br '#FF5555'
        }
        $meta.TextTrimming = 'CharacterEllipsis'
        [void]$stack.Children.Add($meta)
        [void]$grid.Children.Add($stack)

        $tag = New-Object Windows.Controls.TextBlock
        $tag.Text = if ($f.Valid) { 'OK' } else { 'ERR' }
        $tag.Foreground = if ($f.Valid) { Br '#50FA7B' } else { Br '#FF5555' }
        $tag.FontSize = 9
        $tag.FontWeight = 'Bold'
        $tag.VerticalAlignment = 'Center'
        $tag.HorizontalAlignment = 'Right'
        $tag.Margin = New-Object Windows.Thickness(0, 0, 8, 0)
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
        [void]$ui.FilesPanel.Children.Add($border)
    }
}

function Add-DroppedFiles {
    <#
        Chamado pelo evento de drop (e pelo teste). Aceita qualquer coisa que
        venha do DataObject: caminhos, um caminho só, ou nada.
    #>
    param($Files)

    foreach ($f in @($Files)) {
        if (-not $f) { continue }
        Add-IsoFile ([string]$f)
    }
}

function Show-AddFilesDialog {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Escolha as imagens de PS2'
    $dlg.Filter = 'Imagens de PS2 (*.iso)|*.iso|Todos os arquivos (*.*)|*.*'
    $dlg.Multiselect = $true
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Add-DroppedFiles -Files $dlg.FileNames
    }
}

# ---------------------------------------------------------------- jogos

function Load-Games {
    $ui.GamesPanel.Children.Clear()
    $S.Games = @()

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
        return
    }

    foreach ($g in $S.Games) {
        $border = New-Object Windows.Controls.Border
        $border.BorderBrush = Br '#161616'
        $border.BorderThickness = New-Object Windows.Thickness(0, 0, 0, 1)
        $border.Padding = New-Object Windows.Thickness(0, 6, 0, 6)

        $grid = New-Object Windows.Controls.Grid
        $widths = @('2.4*', '1.5*', '0.7*', '0.6*', '1.1*', 'Auto')
        foreach ($w in $widths) {
            $c = New-Object Windows.Controls.ColumnDefinition
            if ($w.EndsWith('*')) {
                $c.Width = New-Object Windows.GridLength([double]$w.TrimEnd('*'), 'Star')
            }
            [void]$grid.ColumnDefinitions.Add($c)
        }

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
            [Windows.Controls.Grid]::SetColumn($t, $i)
            [void]$grid.Children.Add($t)
        }

        $actions = New-Object Windows.Controls.StackPanel
        $actions.Orientation = 'Horizontal'
        $actions.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($actions, 5)
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
        $border.Add_MouseEnter({ param($sender, $e) $sender.Background = Br '#0D0D0D' })
        $border.Add_MouseLeave({ param($sender, $e) $sender.Background = Br '#000000' })
        [void]$ui.GamesPanel.Children.Add($border)
    }

    Update-Space
}

# ---------------------------------------------------------------- biblioteca
# Varre a unidade em segundo plano e lista os jogos de todas as plataformas
# (PS2, PS1, SNES, N64, GBA...). O OPL executa só PS2: o resto é consulta.

function Set-GamesView {
    param([string]$View)

    $S.LibView = $View
    $ui.OplView.Visibility = $(if ($View -eq 'opl') { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed })
    $ui.LibraryView.Visibility = $(if ($View -eq 'library') { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed })
    $ui.TabOpl.IsChecked = ($View -eq 'opl')
    $ui.TabLibrary.IsChecked = ($View -eq 'library')
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
    $ui.LibraryInfo.Text = 'VARRENDO...'
    Show-LibraryMessage ('PROCURANDO JOGOS EM {0}:...' -f $letter) '#8BE9FD'

    $ulPath = Join-Path $repoRoot 'lib\UlFormat.ps1'
    $libPath = Join-Path $repoRoot 'lib\GameLibrary.ps1'

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($UlPath, $LibPath, $Root, $MaxDepth, $Limit, $MaxIso)
        . $UlPath
        . $LibPath
        Get-GameLibrary -Root $Root -MaxDepth $MaxDepth -Limit $Limit -MaxIsoChecks $MaxIso -Report
    })
    [void]$ps.AddArgument($ulPath)
    [void]$ps.AddArgument($libPath)
    [void]$ps.AddArgument("${letter}:\")
    [void]$ps.AddArgument(4)
    [void]$ps.AddArgument(800)
    [void]$ps.AddArgument(60)

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
    Add-Log ("Biblioteca: {0} jogo(s) em {1}:" -f $report.Count, $scan.Letter) 'dim'
    Render-Library
}

function Get-LibraryRows {
    $rows = New-Object System.Collections.ArrayList

    # Jogos já instalados no formato do OPL (ul.*)
    foreach ($g in @($S.Games)) {
        if ($g.Tipo -eq 'ul') {
            [void]$rows.Add([pscustomobject]@{
                Platform = 'PS2'; Label = 'PS2'; Name = $g.Nome
                Rel = 'INSTALADO NO OPL (UL.*)'; Size = [double]0; SizeText = '—'
                Instalado = $true; File = $null; Serial = $g.Serial
            })
        }
    }

    # Jogos soltos encontrados na unidade (inclui os do modo DVD)
    $dvd = @($S.Games | Where-Object { $_.Tipo -eq 'dvd' } | ForEach-Object { $_.Path })
    foreach ($it in @($S.Lib)) {
        [void]$rows.Add([pscustomobject]@{
            Platform = $it.Platform; Label = $it.PlatformLabel; Name = $it.Name
            Rel = $it.Rel; Size = $it.Size; SizeText = (Format-Size $it.Size)
            Instalado = ($dvd -contains $it.File); File = $it.File; Serial = $it.Serial
        })
    }

    return @($rows | Sort-Object @{ e = { Get-GamePlatformRank $_.Platform } }, Name)
}

function Render-Library {
    $ui.LibraryPanel.Children.Clear()

    $rows = @(Get-LibraryRows)

    if ($rows.Count -eq 0) {
        $ui.LibraryInfo.Text = '0 JOGOS'
        if (-not $S.Drive) {
            Show-LibraryMessage 'SELECIONE UMA UNIDADE'
        } else {
            Show-LibraryMessage ("NENHUM JOGO ENCONTRADO EM {0}:`n`nFormatos reconhecidos: PS2 .iso · PS1 .bin/.cue/.chd`nSNES .sfc · N64 .n64 · GBA .gba · NDS .nds · GC .gcm" -f $S.Drive)
        }
        return
    }

    $platforms = @($rows | ForEach-Object { $_.Platform } | Select-Object -Unique).Count
    if ($S.LibReport -and $S.LibReport.Truncated) {
        $ui.LibraryInfo.Text = ('MOSTRANDO {0} (LIMITE)' -f $rows.Count)
    } else {
        $ui.LibraryInfo.Text = ('{0} JOGO(S) · {1} PLATAFORMA(S)' -f $rows.Count, $platforms)
    }

    foreach ($r in $rows) {
        $border = New-Object Windows.Controls.Border
        $border.BorderBrush = Br '#161616'
        $border.BorderThickness = New-Object Windows.Thickness(0, 0, 0, 1)
        $border.Padding = New-Object Windows.Thickness(0, 6, 0, 6)
        $border.Tag = $r

        if ($r.File) {
            $border.ToolTip = ('{0} · {1}`n{2}`n{3}' -f $r.Label, $r.Name, $r.Rel, $r.File)
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

        # plataforma
        $badge = New-Object Windows.Controls.Border
        $badge.BorderBrush = Br (Get-PlatformColor $r.Platform)
        $badge.BorderThickness = New-Object Windows.Thickness(1)
        $badge.Padding = New-Object Windows.Thickness(4, 1, 4, 1)
        $badge.HorizontalAlignment = 'Left'
        $badge.VerticalAlignment = 'Center'
        $bt = New-Object Windows.Controls.TextBlock
        $bt.Text = $r.Label
        $bt.Foreground = Br (Get-PlatformColor $r.Platform)
        $bt.FontSize = 9
        $bt.FontWeight = 'Bold'
        $badge.Child = $bt
        [Windows.Controls.Grid]::SetColumn($badge, 0)
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

        [Windows.Controls.Grid]::SetColumn($stack, 1)
        [void]$grid.Children.Add($stack)

        # tamanho
        $sz = New-Object Windows.Controls.TextBlock
        $sz.Text = $r.SizeText
        $sz.Foreground = Br '#666666'
        $sz.FontSize = 9
        $sz.VerticalAlignment = 'Center'
        $sz.HorizontalAlignment = 'Right'
        $sz.Margin = New-Object Windows.Thickness(0, 0, 10, 0)
        [Windows.Controls.Grid]::SetColumn($sz, 2)
        [void]$grid.Children.Add($sz)

        # ação
        if ($r.Instalado) {
            $act = New-Object Windows.Controls.TextBlock
            $act.Text = 'OPL'
            $act.Foreground = Br '#50FA7B'
            $act.FontSize = 9
            $act.FontWeight = 'Bold'
            $act.VerticalAlignment = 'Center'
        } elseif ($r.Platform -eq 'PS2' -and $r.File) {
            $act = New-Object Windows.Controls.Button
            $act.Style = $win.FindResource('BtnTiny')
            $act.Content = '+'
            $act.Tag = $r
            $act.ToolTip = 'Adicionar à lista de instalação'
            $act.Add_Click({ param($sender, $e) Add-LibraryGame $sender.Tag })
        } else {
            $act = New-Object Windows.Controls.TextBlock
            $act.Text = '—'
            $act.Foreground = Br '#333333'
            $act.FontSize = 9
            $act.VerticalAlignment = 'Center'
        }
        [Windows.Controls.Grid]::SetColumn($act, 3)
        [void]$grid.Children.Add($act)

        $border.Child = $grid
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
        Show-Toast 'Já está no pendrive' $Item.Name 'warn'
        return
    }
    if (-not $Item.File) { return }

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

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $timer.Add_Tick({ Update-Worker })
    $S.Timer = $timer
    $timer.Start()
}

function Set-Busy {
    param([bool]$Busy)
    $ui.BtnInstall.IsEnabled = -not $Busy
    $ui.BtnSimulate.IsEnabled = -not $Busy
    $ui.BtnRefresh.IsEnabled = -not $Busy
    $ui.BtnClearFiles.IsEnabled = -not $Busy
    $ui.DropZone.IsEnabled = -not $Busy
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
        } else {
            $ui.BarText.Text = 'CONCLUÍDO'
            Set-Status 'PRONTO' '#50FA7B'
            Show-Toast 'Concluído' 'Pendrive pronto para usar no PS2.' 'ok'
        }

        Load-Games
        Update-DriveChips
        Refresh-Library

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
    }
}

# ---------------------------------------------------------------- instalar

function Start-Install {
    param([switch]$Simulate)

    if ($S.Busy) { return }
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

        $mode = $S.Mode
        if ($mode -eq 'dvd' -and $f.Size -ge (4GB - 1MB)) {
            Show-Toast 'Não cabe na pasta DVD' ("{0} tem {1}. Use o modo UL.*." -f $f.Name, (Format-Size $f.Size)) 'error'
            return
        }

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

    if ($Simulate) {
        Add-Log ('SIMULAÇÃO — nada será gravado. Destino: {0}' -f $root) 'warn'
        foreach ($j in $jobs) {
            if ($j.Mode -eq 'dvd') {
                Add-Log ("{0} -> DVD\{0}.iso ({1})" -f $j.Name, (Format-Size ($S.Files | Where-Object { $_.Path -eq $j.Iso }).Size)) 'info'
            } else {
                $size = ($S.Files | Where-Object { $_.Path -eq $j.Iso }).Size
                $parts = [int][Math]::Ceiling($size / 1GB)
                Add-Log ("{0} [{1}] -> {2} pedaço(s) de 1 GiB" -f $j.Name, $j.Serial, $parts) 'info'
                Add-Log ("  {0}" -f (Get-UlPartName $j.Name $j.Serial 0)) 'dim'
            }
        }
        Add-Log ('Total: {0} em {1} arquivo(s).' -f (Format-Size $totalBytes), $jobs.Count) 'ok'
        Show-Toast 'Simulação concluída' 'Plano gerado no log. Nada foi gravado.' 'info'
        return
    }

    # duplicados?
    $dups = @()
    if ($S.Mode -eq 'ul') {
        $existing = @(Read-UlEntries $root)
        foreach ($j in $jobs) {
            $hit = $existing | Where-Object { $_.Serial -eq $j.Serial } | Select-Object -First 1
            if ($hit) { $dups += ('{0} (já instalado como "{1}")' -f $j.Name, $hit.Nome) }
        }
    }

    if ($dups.Count -gt 0) {
        Show-Confirm -Title 'Substituir jogos existentes?' `
            -Text ("Estes jogos já estão no pendrive e serão regravados:`n`n{0}" -f ($dups -join "`n")) `
            -YesLabel 'SUBSTITUIR' `
            -OnYes ({ Start-Worker -Jobs $jobs }).GetNewClosure()
        return
    }

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

$ui.BtnInstall.Add_Click({ Start-Install })
$ui.BtnSimulate.Add_Click({ Start-Install -Simulate })

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
    try {
        $text = (New-Object Windows.Documents.TextRange($ui.LogBox.Document.ContentStart, $ui.LogBox.Document.ContentEnd)).Text
        [Windows.Clipboard]::SetText($text)
        Show-Toast 'Log copiado' 'Conteúdo na área de transferência.' 'info'
    } catch { }
})

$ui.DropZone.Add_MouseLeftButtonUp({ Show-AddFilesDialog })

$win.Add_DragOver({
    param($sender, $e)
    if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) {
        $e.Effects = 'Copy'
        $ui.DropZone.BorderBrush = Br '#8BE9FD'
        $ui.DropTitle.Text = 'SOLTE PARA ADICIONAR'
    } else {
        $e.Effects = 'None'
    }
    $e.Handled = $true
})

$win.Add_DragLeave({
    $ui.DropZone.BorderBrush = Br '#333333'
    $ui.DropTitle.Text = 'ARRASTE OS .ISO AQUI'
})

$win.Add_Drop({
    param($sender, $e)
    $ui.DropZone.BorderBrush = Br '#333333'
    $ui.DropTitle.Text = 'ARRASTE OS .ISO AQUI'
    Add-DroppedFiles -Files $e.Data.GetData([Windows.DataFormats]::FileDrop)
    $e.Handled = $true
})

function Hide-ConfirmIfOpen {
    if ($ui.Overlay.Visibility -eq 'Visible') { Hide-Confirm }
}

$win.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Escape') { Hide-ConfirmIfOpen }
})

# ---------------------------------------------------------------- boot

function Initialize-Modes {
    $modes = @(
        @{ Id = 'ul';  Label = 'UL.* (1 GIB)'; Tip = 'Divide o ISO em pedaços de 1 GiB — aceita qualquer tamanho' },
        @{ Id = 'dvd'; Label = 'DVD (ISO < 4 GB)'; Tip = 'Copia o ISO inteiro para a pasta DVD — só abaixo de 4 GB' }
    )
    foreach ($m in $modes) {
        $chip = New-Object Windows.Controls.Primitives.ToggleButton
        $chip.Style = $win.FindResource('Chip')
        $chip.Content = $m.Label
        $chip.Tag = $m.Id
        $chip.ToolTip = $m.Tip
        $chip.IsChecked = ($m.Id -eq $S.Mode)
        $chip.Add_Click({
            param($sender, $e)
            $S.Mode = $sender.Tag
            foreach ($c in $ui.ModePanel.Children) { $c.IsChecked = ($c.Tag -eq $S.Mode) }
        })
        [void]$ui.ModePanel.Children.Add($chip)
    }
}

# A versão vem do CHANGELOG (um lugar só para lembrar de atualizar).
try {
    $cl = Join-Path $repoRoot 'CHANGELOG.md'
    if (Test-Path -LiteralPath $cl) {
        $m = [regex]::Match((Get-Content -LiteralPath $cl -Raw -Encoding UTF8), '##\s*\[(\d+\.\d+\.\d+)\]')
        if ($m.Success) { $ui.VersionText.Text = ('EASYROMSTOOPL {0} · MIT' -f $m.Groups[1].Value) }
    }
} catch { }

Add-Log 'EASYROMS::OPL — motor ul.* carregado' 'ok'
Add-Log ('CRC de referência: {0} (GTA) · {1} (Medalha)' -f ('{0:X8}' -f (Get-UsbaCrc32 'GTA - San Andreas')), ('{0:X8}' -f (Get-UsbaCrc32 'Medalha de Honra'))) 'dim'

Initialize-Modes

if ($Drive) {
    $S.Drive = $Drive.TrimEnd(':', '\').ToUpper()
}

Initialize-GamesTabs

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

    if ($env:EASYROMS_SNAPSHOT_VIEW -eq 'library' -and $S.Drive) {
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
