# ===========================================================================
#  TestIso — gera um ISO9660 mínimo de PS2 para os testes.
#
#  O arquivo tem 19 setores, PVD em 0x8000 e um SYSTEM.CNF apontando para o
#  serial. Serve para exercitar Get-IsoInfo, a biblioteca e o worker sem
#  depender de um jogo real (e sem gastar gigabytes em disco).
#
#  Uso:  . "$PSScriptRoot\TestIso.ps1"
#        New-TestPs2Iso -Path "C:\temp\jogo.iso" -Serial 'SLUS_215.97'
# ===========================================================================

function New-TestPs2Iso {
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
    foreach ($n in @(
            @{ N = '.'; F = 2; E = 17; S = 2048 },
            @{ N = '..'; F = 2; E = 17; S = 2048 },
            @{ N = 'SYSTEM.CNF;1'; F = 0; E = 18; S = 64 })) {
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
