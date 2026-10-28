# Changelog

Todas as mudanças relevantes deste projeto são registradas aqui.
O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/)
e o projeto adere ao [Versionamento Semântico](https://semver.org/lang/pt-BR/).

## [1.0.0] — 2026-10-28

Primeira versão pública. Nasceu de um diagnóstico real de um pendrive de 64 GB usado em
um PS2 com FreeMcBoot/OPL — ver [docs/CASE-STUDY.md](docs/CASE-STUDY.md).

### Adicionado

- `EasyRomsToOPL.ps1`: CLI para instalar jogos de PS2 em pendrive do OPL.
  - Leitura do serial real via ISO9660 + `SYSTEM.CNF` (sem montar a imagem).
  - Instalação no formato `ul.*`, com pedaços de 1 GiB e entrada de 64 bytes no `ul.cfg`.
  - Modo `-DvdFolder` para ISOs abaixo de 4 GB.
  - `-Listar`, `-DryRun`, `-Force`, `-Drive`, `-Nome`, `-Serial`.
  - Verificação do total gravado e limpeza automática em caso de falha.
- `lib/UlFormat.ps1`: biblioteca do formato.
  - `Get-UsbaCrc32` — reimplementação fiel de `USBA_crc32()`.
  - `New-UlEntry`, `Get-UlPartName`, `Read-UlEntries`.
  - `Get-IsoInfo` — leitor de ISO9660 sem dependências.
  - `ConvertTo-AsciiName`, `Format-Size`.
- `tests/Test-UlFormat.ps1`: 17 asserções, incluindo vetores de CRC extraídos de um
  pendrive real (`7C39E2C0`, `75CC3FAF`) e teste de integração com ISO real.
- `docs/UL-FORMAT.md`: especificação completa do formato `ul.*`/`ul.cfg`.
- `docs/TUTORIAL.md`: passo a passo do pendrive cru ao jogo rodando no PS2.
- `docs/CASE-STUDY.md`: análise do pendrive que originou o projeto.
- README com quickstart, referência de parâmetros, limitações e troubleshooting.

### Corrigido

- Checagem de serial duplicado não interrompe mais o `-DryRun`: o plano é exibido com
  aviso, e o erro só ocorre na gravação real.
- Substituição de volume via `Get-Volume` trocada por `System.IO.DriveInfo`, que não
  travava em discos com problema de I/O.

### Notas

- Validado em um pendrive SanDisk 64 GB, FAT32/MBR, com 5 jogos (GTA San Andreas,
  Medalha de Honra, ULTIMO BOMBA, God of War e Crash Twinsanity).
- God of War (DVD9, 7,94 GB) instalado em 8 pedaços; soma conferida byte a byte.

[1.0.0]: https://github.com/lucao019/easyromstooplps2/releases/tag/v1.0.0
