# Changelog

Todas as mudanças relevantes deste projeto são registradas aqui.
O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/)
e o projeto adere ao [Versionamento Semântico](https://semver.org/lang/pt-BR/).

## [1.3.0] — 2026-10-28

### Adicionado

- **Pendrive em tempo real (hot-plug).** Com o programa aberto, conecte ou remova
  o pendrive: a unidade aparece/some sozinha em até 1 segundo, sem clicar em
  RECARREGAR. Se a unidade selecionada sair, o app avisa (aviso + log + barra de
  status) e escolhe outra automaticamente; se não sobrar nenhuma, mostra
  `NENHUM PENDRIVE DETECTADO`.
  - A checagem é barata: compara só a lista de letras das unidades a cada segundo
    (sem ler rótulo/espaço, que podem travar em pendrive com defeito). A leitura
    completa só acontece quando algo realmente muda.
  - Durante uma cópia a lista não é mexida (o worker continua mandando no progresso).
- Teste novo no `Test-GuiUi.ps1`: simula um pendrive entrando e saindo com o app
  aberto (`subst`) e confere chip, log, seleção e aviso (100 asserções no total).

### Corrigido

- Uma leitura momentaneamente falha da unidade não troca mais a unidade
  selecionada: a seleção só muda se a letra realmente desaparecer do sistema.

## [1.2.1] — 2026-10-28

### Corrigido

- **Clicar em uma aba/unidade fechava o programa.** Os handlers usavam
  `param($s, $e)` e, como o PowerShell não diferencia maiúsculas de minúsculas,
  `$s` sobrescrevia `$S` (o estado do aplicativo). O próximo acesso a `$S.Mode`
  estourava e a janela morria. Todos os 12 handlers agora usam `$sender`.
- **O ✕ de um jogo não removia nada.** A ação da confirmação era um scriptblock
  criado dentro de `Confirm-Remove`; ao ser chamado depois, `$Game` já não existia
  (virava `$null`) e a remoção falhava com "Serial vazio". O mesmo valia para
  "substituir jogos existentes" (INSTALAR) e "sobrescrever arquivo" (ISO).
  Agora os três usam `GetNewClosure()`.
- **Avisos (toasts) nunca sumiam sozinhos.** O timer de 6 s também perdia `$border`
  ao rodar fora da função; o aviso ficava na tela para sempre. Agora ele fecha
  sozinho e o ✕ funciona.
- **Erro dentro de um handler não fecha mais a janela**: uma rede de segurança
  (`Dispatcher.UnhandledException`) registra em `%TEMP%\EasyRomsToOPL-error.log`,
  mostra um aviso e mantém o programa aberto.
- Clique em CONFIRMAR agora trata falha da ação (loga e avisa) em vez de deixar
  a exceção subir.

### Adicionado

- **`tests\Test-GuiUi.ps1`** — 92 asserções que abrem a janela de verdade e clicam
  em cada controle: chips de unidade, modos, INSTALAR, SIMULAR, LIMPAR LISTA,
  RECARREGAR, COPIAR, ✕ dos arquivos, ✕ dos jogos (cancelar / ESC / confirmar),
  ISO, minimizar/maximizar/fechar, mais uma varredura que clica no que sobrou.
  Usa uma unidade virtual (`subst`) para nunca gravar em disco real e falha se
  qualquer handler lançar exceção.
- `Show-AddFilesDialog`, `Add-DroppedFiles` e `Start-ExportTo`: partes sem diálogo
  nativo, para o teste conseguir exercitar o mesmo código.

## [1.2.0] — 2026-10-28

### Adicionado

- **Instalador** (`Instalar-EasyRomsToOPL.cmd`): copia o programa para
  `%LOCALAPPDATA%\EasyRomsToOPL`, cria atalho na Área de Trabalho e no Menu Iniciar
  (com o desinstalador ao lado). Não pede administrador e não escreve no registro.
- **Instalador de arquivo único** (`dist\Instalar-EasyRomsToOPL.cmd`, ~170 KB):
  auto-extrai em `%TEMP%` e chama o instalador. Serve para levar em um pendrive ou
  instalar em outro PC sem baixar o repositório.
- `gui\EasyRomsToOPL.ico`: ícone próprio do atalho (borda ciano, "E", barra verde).
- `tools\New-Icon.ps1`: gera o `.ico` nos tamanhos 16/32/48/64/128/256.
- `tools\Build-Installer.ps1`: gera o instalador de arquivo único a partir do repo.
- Opções do instalador: `-Uninstall`, `-DesktopPath`, `-NoDesktop`, `-NoStartMenu`,
  `-Quiet`, `-Target`.
- `Desinstalar.cmd` gerado dentro da pasta instalada.

## [1.1.0] — 2026-10-28

### Adicionado

- **Interface gráfica (WPF)** — `gui/EasyRomsToOPL.GUI.ps1`, aberta por
  `EasyRomsToOPL.cmd`. Sem dependências além do .NET que já vem no Windows.
  - Arrastar e soltar vários `.iso` de uma vez.
  - Validação imediata: mostra serial lido do `SYSTEM.CNF` antes de gravar.
  - Modo `ul.*` ou pasta `DVD`, com bloqueio de ISO ≥ 4 GB no modo DVD.
  - Progresso real em bytes/porcentagem e log com timestamp.
  - Tabela dos jogos já instalados, com CRC e número de pedaços.
  - Remontagem de um jogo `ul.*` em `.iso` único, direto pela interface.
  - Remoção de jogo (pedaços + entrada do `ul.cfg`) com confirmação.
  - Aviso de duplicados com opção de substituir.
  - Visual baseado nos tokens do `terminal.css` (JetBrains Mono, `#050505`, ciano `#8BE9FD`).
- `gui/Worker.ps1`: execução em runspace separado, com progresso, log e cancelamento.
- `tests/Test-GuiWorker.ps1`: 20 asserções cobrindo instalação, remontagem e cancelamento.
- Parâmetros `-Drive` e `-Iso` na GUI (atalhos / "Abrir com").

### Alterado

- O motor de instalação saiu da CLI e foi para `lib/UlFormat.ps1`:
  `Install-UlGame`, `Install-DvdFolderGame`, `Remove-UlGame`, `Export-UlToIso`,
  `Update-UlCfg`. CLI e GUI agora compartilham a mesma implementação.
- CLI usa o motor compartilhado; comportamento e mensagens preservados.

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

[1.3.0]: https://github.com/lucao019/easyromstooplps2/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/lucao019/easyromstooplps2/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/lucao019/easyromstooplps2/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/lucao019/easyromstooplps2/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/lucao019/easyromstooplps2/tree/v1.0.0
