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
    'BtnYesConfirm', 'BtnMin', 'BtnMax', 'BtnClose'
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
    $S.Toasts.Add($border)

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(6)
    $timer.Add_Tick({
        param($s, $e)
        $s.Stop()
        if ($border.Parent) { [void]$ui.Toasts.Children.Remove($border) }
    })
    $timer.Tag = $border
    $close.Add_MouseLeftButtonUp({
        param($s, $e)
        if ($border.Parent) { [void]$ui.Toasts.Children.Remove($border) }
    })
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

    if (-not $S.Drive -or -not ($S.Drives | Where-Object { $_.Letter -eq $S.Drive })) {
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
            param($s, $e)
            $S.Drive = $s.Tag
            Update-DriveChips
            Update-Space
            Load-Games
        })
        [void]$ui.DrivesPanel.Children.Add($chip)
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
            param($s, $e)
            $S.Files.Remove($s.Tag) | Out-Null
            Render-Files
        })
        [Windows.Controls.Grid]::SetColumn($del, 2)
        [void]$grid.Children.Add($del)

        $border.Child = $grid
        [void]$ui.FilesPanel.Children.Add($border)
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
            $b.Add_Click({ param($s, $e) Start-Export $s.Tag })
            [void]$actions.Children.Add($b)
        }

        $d = New-Object Windows.Controls.Button
        $d.Style = $win.FindResource('BtnTiny')
        $d.Content = '✕'
        $d.Foreground = Br '#FF5555'
        $d.BorderBrush = Br '#663333'
        $d.ToolTip = 'Remover do pendrive'
        $d.Tag = $g
        $d.Add_Click({ param($s, $e) Confirm-Remove $s.Tag })
        [void]$actions.Children.Add($d)

        $border.Child = $grid
        $border.Add_MouseEnter({ param($s, $e) $s.Background = Br '#0D0D0D' })
        $border.Add_MouseLeave({ param($s, $e) $s.Background = Br '#000000' })
        [void]$ui.GamesPanel.Children.Add($border)
    }

    Update-Space
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
            -OnYes { Start-Worker -Jobs $jobs }
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

    $dest = Join-Path $dlg.SelectedPath ($Game.Nome + '.iso')
    if (Test-Path -LiteralPath $dest) {
        Show-Confirm -Title 'Sobrescrever arquivo?' -Text ("Já existe:`n$dest") -YesLabel 'SOBRESCREVER' `
            -OnYes { Start-Worker -Jobs @([pscustomobject]@{
                        Op = 'export'; Root = "$($S.Drive):\"; Serial = $Game.Serial; Name = $Game.Nome; Dest = $dest
                    }) }
        return
    }

    Start-Worker -Jobs @([pscustomobject]@{
        Op = 'export'; Root = "$($S.Drive):\"; Serial = $Game.Serial; Name = $Game.Nome; Dest = $dest
    })
}

function Confirm-Remove {
    param($Game)

    if ($S.Busy) { return }

    $label = if ($Game.Tipo -eq 'dvd') { "Apagar o arquivo $($Game.Nome).iso da pasta DVD?" } else { "Apagar '$($Game.Nome)' ($($Game.Partes) pedaço(s)) e remover do ul.cfg?" }

    Show-Confirm -Title 'Remover do pendrive' -Text ($label + "`n`nEssa ação não pode ser desfeita.") -YesLabel 'APAGAR' -OnYes {
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
    }
}

# ---------------------------------------------------------------- eventos

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
    if ($action) { & $action }
})

$ui.BtnCopyLog.Add_MouseLeftButtonUp({
    try {
        $text = (New-Object Windows.Documents.TextRange($ui.LogBox.Document.ContentStart, $ui.LogBox.Document.ContentEnd)).Text
        [Windows.Clipboard]::SetText($text)
        Show-Toast 'Log copiado' 'Conteúdo na área de transferência.' 'info'
    } catch { }
})

$ui.DropZone.Add_MouseLeftButtonUp({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Escolha as imagens de PS2'
    $dlg.Filter = 'Imagens de PS2 (*.iso)|*.iso|Todos os arquivos (*.*)|*.*'
    $dlg.Multiselect = $true
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        foreach ($f in $dlg.FileNames) { Add-IsoFile $f }
    }
})

$win.Add_DragOver({
    param($s, $e)
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
    param($s, $e)
    $ui.DropZone.BorderBrush = Br '#333333'
    $ui.DropTitle.Text = 'ARRASTE OS .ISO AQUI'
    $files = $e.Data.GetData([Windows.DataFormats]::FileDrop)
    foreach ($f in $files) { Add-IsoFile $f }
    $e.Handled = $true
})

$win.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Escape' -and $ui.Overlay.Visibility -eq 'Visible') { Hide-Confirm }
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
            param($s, $e)
            $S.Mode = $s.Tag
            foreach ($c in $ui.ModePanel.Children) { $c.IsChecked = ($c.Tag -eq $S.Mode) }
        })
        [void]$ui.ModePanel.Children.Add($chip)
    }
}

Add-Log 'EASYROMS::OPL — motor ul.* carregado' 'ok'
Add-Log ('CRC de referência: {0} (GTA) · {1} (Medalha)' -f ('{0:X8}' -f (Get-UsbaCrc32 'GTA - San Andreas')), ('{0:X8}' -f (Get-UsbaCrc32 'Medalha de Honra'))) 'dim'

Initialize-Modes

if ($Drive) {
    $S.Drive = $Drive.TrimEnd(':', '\').ToUpper()
}

Update-DriveChips
Load-Games
Render-Files

foreach ($p in @($Iso)) {
    if ($p) { Add-IsoFile $p }
}

if (-not $S.Drive) {
    Show-Toast 'Nenhum pendrive' 'Conecte um pendrive FAT32 para começar.' 'warn'
} else {
    Set-Status ("PRONTO · {0}:" -f $S.Drive) '#50FA7B'
}

# Modo de captura: usado para gerar o screenshot da documentação.
if ($env:EASYROMS_SNAPSHOT) {
    $win.Show()
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
