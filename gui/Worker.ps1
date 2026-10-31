<#
    Worker.ps1 — executor assíncrono usado pela GUI.

    Roda em um runspace separado para não travar a interface durante cópias
    de vários GB. A comunicação é feita por um hashtable sincronizado:

        Jobs      array de trabalhos (@{ Op; Iso; Root; Name; Serial; Media; Mode; Force; Dest })
        Log       ArrayList sincronizado, entradas "nivel|mensagem"
        Percent   0..100 do trabalho inteiro
        Done      bytes já processados
        Total     bytes do trabalho atual
        Current   nome do jogo em andamento
        Cancel    $true para abortar (checado entre blocos de 8 MB)
        Finished  $true quando o worker terminou
        Failed    quantidade de trabalhos que falharam

    Este arquivo é dot-sourced pela GUI e pelos testes.
#>

$script:WorkerScript = {
    param($Sync)

    $ErrorActionPreference = 'Stop'
    . $Sync.LibPath

    $jobs = @($Sync.Jobs)
    $count = [Math]::Max(1, $jobs.Count)
    $index = 0
    $failed = 0

    $onLog = {
        param($level, $message)
        [void]$Sync.Log.Add("$level|$message")
    }

    try {
        foreach ($job in $jobs) {
            if ($Sync.Cancel) { break }
            $index++
            $Sync.Current = $job.Name

            $onProgress = {
                param($percent, $done, $total)
                $Sync.Percent = [int](((($index - 1) * 100) + $percent) / $count)
                $Sync.Done = $done
                $Sync.Total = $total
                $Sync.PartPct = $percent
            }

            try {
                if ($job.Op -eq 'export') {
                    [void]$Sync.Log.Add("info|REMONTANDO: $($job.Name)")
                    $r = Export-UlToIso -Root $job.Root -Serial $job.Serial -Destination $job.Dest `
                        -OnLog $onLog -OnProgress $onProgress -State $Sync
                    [void]$Sync.Log.Add("ok|ISO gerado: $($r.Destino) ($([Math]::Round($r.Bytes / 1GB, 2)) GB)")
                }
                elseif ($job.Op -eq 'copy-ul') {
                    [void]$Sync.Log.Add("info|COPIANDO: $($job.Name) -> unidade $($job.DestLetter):")
                    $r = Copy-UlGame -SourceRoot $job.SourceRoot -DestRoot $job.DestRoot -Serial $job.Serial `
                        -OnLog $onLog -OnProgress $onProgress -State $Sync
                    [void]$Sync.Log.Add("ok|$($job.Name) copiado para $($job.DestLetter):")
                }
                elseif ($job.Op -eq 'move-ul') {
                    [void]$Sync.Log.Add("info|MOVENDO: $($job.Name) -> unidade $($job.DestLetter):")
                    $r = Move-UlGame -SourceRoot $job.SourceRoot -DestRoot $job.DestRoot -Serial $job.Serial `
                        -OnLog $onLog -OnProgress $onProgress -State $Sync
                    [void]$Sync.Log.Add("ok|$($job.Name) movido para $($job.DestLetter):")
                }
                elseif ($job.Op -eq 'copy-dvd') {
                    [void]$Sync.Log.Add("info|COPIANDO ISO: $($job.Name) -> unidade $($job.DestLetter):")
                    $r = Copy-DvdGame -IsoPath $job.Iso -DestRoot $job.DestRoot `
                        -OnLog $onLog -OnProgress $onProgress -State $Sync
                    [void]$Sync.Log.Add("ok|$($job.Name).iso copiado para $($job.DestLetter):")
                }
                elseif ($job.Op -eq 'move-dvd') {
                    [void]$Sync.Log.Add("info|MOVENDO ISO: $($job.Name) -> unidade $($job.DestLetter):")
                    $r = Copy-DvdGame -IsoPath $job.Iso -DestRoot $job.DestRoot `
                        -OnLog $onLog -OnProgress $onProgress -State $Sync
                    Remove-Item -LiteralPath $job.Iso -Force
                    [void]$Sync.Log.Add("ok|$($job.Name).iso movido para $($job.DestLetter):")
                }
                elseif ($job.Mode -eq 'dvd') {
                    [void]$Sync.Log.Add("info|COPIANDO PARA DVD\: $($job.Name)")
                    $r = Install-DvdFolderGame -IsoPath $job.Iso -Root $job.Root -Name $job.Name `
                        -OnLog $onLog -OnProgress $onProgress -State $Sync
                    [void]$Sync.Log.Add("ok|$($job.Name) copiado")
                }
                else {
                    [void]$Sync.Log.Add("info|INSTALANDO: $($job.Name) [$($job.Serial)]")
                    $r = Install-UlGame -IsoPath $job.Iso -Root $job.Root -Name $job.Name `
                        -Serial $job.Serial -Media $job.Media -Force:$job.Force `
                        -OnLog $onLog -OnProgress $onProgress -State $Sync
                    [void]$Sync.Log.Add("ok|$($job.Name) instalado — $($r.Partes) pedaço(s), CRC $($r.Crc)")
                }
            }
            catch {
                if ($Sync.Cancel) {
                    [void]$Sync.Log.Add("warn|Cancelado pelo usuário.")
                    break
                }
                $failed++
                [void]$Sync.Log.Add("error|$($job.Name): $($_.Exception.Message)")
            }
        }
    }
    catch {
        [void]$Sync.Log.Add("error|Falha inesperada: $($_.Exception.Message)")
        $failed++
    }
    finally {
        $Sync.Failed = $failed
        $Sync.Finished = $true
    }
}

function New-WorkerState {
    param([string]$LibPath, [array]$Jobs)

    return [hashtable]::Synchronized(@{
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
        LibPath  = $LibPath
    })
}
