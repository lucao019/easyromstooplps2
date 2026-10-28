<#
.SYNOPSIS
    Testes do formato ul.* / ul.cfg.

.DESCRIPTION
    Os vetores de CRC abaixo foram extraídos de um pendrive real, com jogos
    instalados por ferramentas oficiais (USBUtil). Se estes testes passam, o
    CRC calculado é idêntico ao do OPL.

.EXAMPLE
    .\tests\Test-UlFormat.ps1

.EXAMPLE
    .\tests\Test-UlFormat.ps1 -IsoPath "E:\jogos\God of War (USA).iso"
#>
[CmdletBinding()]
param(
    # Opcional: valida também a leitura de um ISO real
    [string]$IsoPath
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

. (Join-Path $PSScriptRoot '..\lib\UlFormat.ps1')

$script:Passed = 0
$script:Failed = 0

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

Write-Host ""
Write-Host "CRC do OPL (USBA_crc32)" -ForegroundColor Cyan
Assert-Equal '7C39E2C0' ('{0:X8}' -f (Get-UsbaCrc32 'GTA - San Andreas')) 'GTA - San Andreas'
Assert-Equal '75CC3FAF' ('{0:X8}' -f (Get-UsbaCrc32 'Medalha de Honra')) 'Medalha de Honra'
Assert-Equal '56D86CD8' ('{0:X8}' -f (Get-UsbaCrc32 'TESTE SCRIPT')) 'TESTE SCRIPT (sintético)'

Write-Host ""
Write-Host "Nome dos pedaços" -ForegroundColor Cyan
Assert-Equal 'ul.7C39E2C0.SLUS_209.46.00' (Get-UlPartName 'GTA - San Andreas' 'SLUS_209.46' 0) 'primeiro pedaço'
Assert-Equal 'ul.7C39E2C0.SLUS_209.46.04' (Get-UlPartName 'GTA - San Andreas' 'SLUS_209.46' 4) 'quinto pedaço'
Assert-Equal 'ul.75CC3FAF.SLUS_215.97.01' (Get-UlPartName 'Medalha de Honra' 'SLUS_215.97' 1) 'segundo pedaço'

Write-Host ""
Write-Host "Entrada de 64 bytes do ul.cfg" -ForegroundColor Cyan
$e = New-UlEntry -Name 'GTA - San Andreas' -Serial 'SLUS_209.46' -Parts 5 -Media 0x14
Assert-Equal 64 $e.Length 'tamanho'
Assert-Equal 'GTA - San Andreas' ([Text.Encoding]::ASCII.GetString($e, 0, 17)) 'campo name'
Assert-Equal 'ul.' ([Text.Encoding]::ASCII.GetString($e, 32, 3)) 'magic "ul."'
Assert-Equal 'SLUS_209.46' ([Text.Encoding]::ASCII.GetString($e, 35, 11)) 'campo startup'
Assert-Equal 5 $e[47] 'campo parts'
Assert-Equal 0x14 $e[48] 'campo media'
Assert-Equal 0x08 $e[53] 'Byte08 (compatibilidade)'
$zeros = @($e[49..52] + $e[54..63] | Where-Object { $_ -ne 0 })
Assert-Equal 0 $zeros.Count 'bytes reservados zerados'

Write-Host ""
Write-Host "Normalização de nome" -ForegroundColor Cyan
Assert-Equal 'Acao Epica' (ConvertTo-AsciiName 'Ação Épica') 'remove acentos'
Assert-Equal 32 (ConvertTo-AsciiName ('X' * 50)).Length 'trunca em 32'
Assert-Equal 'God of War' (ConvertTo-AsciiName '  God   of  War  ') 'colapsa espaços'

if ($IsoPath) {
    Write-Host ""
    Write-Host "Leitura de ISO real" -ForegroundColor Cyan
    $info = Get-IsoInfo $IsoPath
    Assert-Equal 'CD001' $info.Pvd 'PVD'
    Assert-Equal 'PLAYSTATION' $info.SystemId 'SystemId'
    Assert-Equal $true $info.SystemCnf 'SYSTEM.CNF encontrado'
    Assert-Equal $true $info.IsPs2 'é jogo de PS2'
    Write-Host "         serial lido: $($info.Serial) (VER $($info.Ver))" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host ("Resultado: {0} passaram, {1} falharam" -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) { exit 1 }
