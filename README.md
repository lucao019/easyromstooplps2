# EasyRomsToOPL

**Adicione jogos de PS2 a um pendrive do OPL (Open PS2 Loader) — arrastando o arquivo ou em um comando. Sem USBUtil, sem quebrar o `ul.cfg`.**

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6?logo=windows&logoColor=white)
![PS2](https://img.shields.io/badge/PlayStation%202-OPL%20USB-003791?logo=playstation&logoColor=white)
![GUI](https://img.shields.io/badge/interface-WPF%20nativa-8BE9FD)
![Testes](https://img.shields.io/badge/testes-268%20passando-brightgreen)
![Licença](https://img.shields.io/badge/licen%C3%A7a-MIT-green)

**Interface gráfica** (arrastar e soltar) e **CLI** — as duas usando o mesmo motor.

---

## Interface gráfica

![Interface do EasyRomsToOPL](docs/screenshot.png)

Abra com **duplo clique em `EasyRomsToOPL.cmd`** (ou rode `gui\EasyRomsToOPL.GUI.ps1`).
Sem instalação, sem Electron, sem runtime extra: é WPF nativo do Windows.

- **Arraste o jogo e pronto.** A área pontilhada aceita **`.iso`, `.zip`, `.rar`
  (até multi-volume) e `.7z`**, além de pastas. O compactado é extraído em segundo
  plano e o ISO entra na fila sozinho.
- Com **INSTALAR AO SOLTAR** ligado (padrão), a cópia começa assim que o ISO é
  reconhecido — um arrasto, nenhum clique. Soltou antes de plugar o pendrive? O
  jogo espera na lista e instala quando a unidade aparecer.
- O serial é **lido do `SYSTEM.CNF`** na hora e mostrado antes de gravar.
- **DISPOSITIVO** diz o que você selecionou e quanto cabe: `F: PENDRIVE · SanDisk
  3.2Gen1 · FAT32 · 64 GB`, com **usado / total / livre** e a barra de ocupação
  atualizados a cada segundo — os números andam junto com a cópia.
- Sem escolha de modo: o app sempre grava em **`ul.*`**, que divide o ISO em pedaços
  de 1 GiB e por isso aceita jogo de qualquer tamanho (o limite do FAT32 é 4 GB por
  arquivo). Não existe mais jeito de errar essa escolha.
- **INSTALAR** mostra progresso real (bytes, %), log com timestamp e aviso de duplicados.
- **JOGOS NA UNIDADE** lista o que já está lá, com CRC e número de pedaços.
- **BIBLIOTECA** — clique na unidade e a aba abre sozinha, com **todos os jogos**
  que existem nela: etiqueta de plataforma, pasta e tamanho. Cobre PS2, PS1, SNES,
  N64, GBA, GB/GBC, NDS, GC/Wii, Mega Drive, Master System, NES, PSP e Dreamcast.
  PS1 e Nintendo aparecem só para consulta — **o OPL executa apenas PS2**.
- **Instalado x para instalar, sem adivinhação.** A coluna **STATUS** e os filtros
  **TUDO / INSTALADOS / NO PENDRIVE / PARA INSTALAR / OUTROS**, todos com contagem,
  dizem o que já está no pendrive e o que ainda pode entrar. Cada linha mostra
  `INSTALADO`, `JÁ NO OPL` (o arquivo é uma cópia de um jogo que já está em `ul.*`,
  reconhecido pelo serial), `JÁ NO PENDRIVE F:` (instalado em outra unidade) ou o
  botão **INSTALAR**. O cabeçalho resume:
  `7 JOGO(S) · 6 INSTALADO(S) · 1 PARA INSTALAR`.
- **Jogo já instalado no SSD não pede instalação de novo.** Se você abre a pasta de
  ISOs do SSD e os mesmos jogos já estão no pendrive, a linha fica amarela
  (`JÁ NO PENDRIVE F:`) e uma faixa avisa: *"NÃO PRECISA INSTALAR DE NOVO"*. A
  comparação é pelo **serial de dentro do ISO**, não pelo nome do arquivo.
- **Só jogo de verdade.** `README.md`, `.txt`, `.nfo`, vídeo renomeado para `.iso`,
  save pequeno, faixa solta de `.bin` — nada disso entra na biblioteca. O app
  confere tamanho, conteúdo e, no caso do ISO, se ele abre mesmo como ISO9660.
  `.md` só aparece se tiver a assinatura `SEGA` de um Mega Drive de verdade.
- **Glossário embutido.** O botão **`?`** no topo explica cada formato (`ISO`,
  `ul.*`, `ul.cfg`, `DVD\`, CUE+BIN), cada coluna (**MODO**, PARTES, CRC, SERIAL) e
  cada status. A aba OPL também tem uma legenda fixa e tooltips nas colunas.
- **Sons discretos.** Tique ao passar o mouse, clique, conexão/remoção do pendrive,
  sucesso e erro — **sons próprios, sintetizados pelo projeto** (nada de áudio da
  Sony). O chip **SOM: ON / OFF** liga e desliga, e a escolha fica salva.
- **Compactados na biblioteca.** `.zip`, `.rar` (inclusive multi-volume) e `.7z`
  aparecem com o que têm dentro (`… · 1 jogo(s) dentro · God of War.iso`). O app lê
  só o índice do arquivo — nada é extraído só para listar — e o **INSTALAR** extrai
  e instala o jogo de dentro.
- **A fila avisa antes de copiar de novo.** Um ISO que já está no pendrive entra na
  lista com a etiqueta **JÁ** e a dica "Já está tudo no OPL — INSTALAR pergunta antes
  de substituir". Depois de instalar, o jogo sai da fila.
- Botão **ISO** remonta os pedaços de um jogo em `.iso` único (para PCSX2 ou backup).
- Botão **✕** remove um jogo (pedaços + entrada do `ul.cfg`), com confirmação.
- Os chips mostram o **tipo de cada unidade** (`F: PENDRIVE`, `E: SSD`, `H: HD`) —
  o padrão é sempre o pendrive removível.
- **Pendrive em tempo real:** conecte ou remova com o programa aberto — a unidade
  aparece/some sozinha em até 1 s, sem precisar clicar em RECARREGAR. Se o pendrive
  selecionado sair, o app avisa e escolhe outro automaticamente.

![Biblioteca de jogos: o que está instalado e o que pode ser instalado](docs/screenshot-biblioteca.png)

![Glossário: formatos, colunas e status explicados na própria janela](docs/screenshot-glossario.png)

O visual segue os tokens do `terminal.css` (a biblioteca de componentes usada como
referência): fundo `#050505`, ciano `#8BE9FD`, JetBrains Mono com fallback para
Cascadia/Consolas, bordas de 1px e nada de cantos arredondados.

## O problema

O OPL não lê `.iso` solto na raiz do pendrive. Ele espera o formato **`ul.*`**: a imagem
cortada em pedaços de exatamente **1 GiB** (`00`, `01`, `02`…) mais uma entrada binária
de 64 bytes no `ul.cfg`. E o nome dos pedaços depende de um **CRC32 não-padrão** que o
OPL calcula do nome do jogo — se errar um byte, o jogo aparece na lista e não abre.

Na prática, o caminho comum é abrir um programa de interface gráfica antigo, arrastar o
ISO, torcer, e depois descobrir que o jogo não aparece no console.

## A solução

Um script PowerShell que faz o trabalho **correto e verificável**:

```powershell
.\EasyRomsToOPL.ps1 -Iso "E:\jogos\God of War (USA).iso" -Nome "God of War"
```

Ele lê o serial de verdade de dentro do ISO, divide, grava os pedaços, escreve a entrada
no `ul.cfg` e confere o tamanho no final. O CRC foi **validado contra jogos instalados
por ferramentas oficiais** — os testes comparam com vetores reais (`7C39E2C0`, `75CC3FAF`).

| O que o script faz | Por que importa |
|---|---|
| Lê o `SYSTEM.CNF` do ISO | Descobre o serial real (`SLUS_209.46`), sem adivinhar pelo nome do arquivo |
| Calcula o `USBA_crc32` do OPL | O nome dos pedaços sai idêntico ao que o console espera |
| Divide em pedaços de 1 GiB | Contorna o limite de 4 GB do FAT32 |
| Escreve a entrada de 64 bytes | Sem isso o OPL lista o jogo, mas não acha os arquivos |
| Confere o total gravado | Falha alto em vez de deixar um jogo corrompido |
| `-DryRun` | Mostra o plano completo sem gravar um byte |

---

## Quickstart (CLI)

```powershell
# 1. clone
git clone https://github.com/lucao019/easyromstooplps2.git
cd easyromstooplps2

# 2. veja o que já está no pendrive (F: por padrão)
.\EasyRomsToOPL.ps1 -Listar

# 3. simule a instalação
.\EasyRomsToOPL.ps1 -Iso "E:\jogos\Shadow of the Colossus.iso" -DryRun

# 4. instale
.\EasyRomsToOPL.ps1 -Iso "E:\jogos\Shadow of the Colossus.iso" -Nome "Shadow of the Colossus"
```

No PS2: ligue o console → FMCB → **OPL → USB** → o jogo está na lista.

---

## Requisitos

- **Windows 10/11** com PowerShell 5.1 (já vem no sistema) ou PowerShell 7+.
- Pendrive formatado em **FAT32** (MBR). É o que o OPL entende.
- Um **ISO de PS2 íntegro** (`.iso`) — ou o `.zip`/`.rar`/`.7z` que você baixou.
  ZIP é extraído pelo próprio Windows; RAR usa o **UnRAR** (vem com o WinRAR) e
  7Z usa o **7-Zip** ou o `tar` do Windows.
- PS2 com **FreeMcBoot** no memory card e o **OPL** instalado — o pendrive não dá boot
  sozinho, quem carrega o OPL é o memory card.

## Instalação

Nada de dependências: nem Node, nem Electron, nem módulo PowerShell.

### Instalador (recomendado)

Baixe **`dist/Instalar-EasyRomsToOPL.cmd`** (um arquivo só, ~583 KB) e dê duplo clique.
Ele instala em `%LOCALAPPDATA%\EasyRomsToOPL` e cria os atalhos:

- **Área de Trabalho** → `EasyRomsToOPL`
- **Menu Iniciar** → `EasyRomsToOPL` (com o **Desinstalar** ao lado)

Não pede administrador e não escreve no registro. Para remover, use o atalho
*Desinstalar* do Menu Iniciar — sobram zero arquivos.

### A partir do repositório

```powershell
git clone https://github.com/lucao019/easyromstooplps2.git
cd easyromstooplps2
```

Depois, duplo clique em `Instalar-EasyRomsToOPL.cmd` — ou, se preferir não instalar nada,
use direto da pasta:

- **Interface:** `EasyRomsToOPL.cmd`
- **CLI:** `.\EasyRomsToOPL.ps1 -Listar`

Se o Windows bloquear a execução:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Ou rode direto, sem mexer na política do sistema:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\EasyRomsToOPL.ps1 -Listar
```

A GUI também aceita parâmetros, útil para criar um atalho ou usar "Abrir com":

```powershell
powershell -File .\gui\EasyRomsToOPL.GUI.ps1 -Drive F -Iso "E:\jogos\Okami.iso"
```

> O atalho aponta para o PowerShell com a janela escondida — por isso não existe `.exe`:
> o programa é 100% script, e um executável só existiria para embrulhar o mesmo comando.

## Uso (CLI)

```
.\EasyRomsToOPL.ps1 [-Iso <caminho>] [-Drive <letra>] [-Nome <nome>] [-Serial <serial>]
                    [-DvdFolder] [-DryRun] [-Listar] [-Force]
```

| Parâmetro | Descrição |
|---|---|
| `-Iso` | Caminho do ISO de PS2. Obrigatório, exceto com `-Listar`. |
| `-Drive` | Letra do pendrive. Padrão: `F`. |
| `-Nome` | Nome exibido no menu do OPL (máx. 32 caracteres, sem acento). Padrão: nome do arquivo. |
| `-Serial` | Força o serial. Normalmente é lido do próprio ISO. |
| `-DvdFolder` | Copia como `.iso` inteiro na pasta `DVD\` (só abaixo de 4 GB). |
| `-DryRun` | Mostra tudo o que faria, sem gravar nada. |
| `-Listar` | Lista os jogos `ul.*` e os ISOs soltos, e mostra o espaço livre. |
| `-Force` | Substitui um jogo que já exista com o mesmo serial. |

### Exemplos reais

```powershell
# listar o pendrive
.\EasyRomsToOPL.ps1 -Listar

# pendrive em outra letra
.\EasyRomsToOPL.ps1 -Iso "C:\isos\Okami.iso" -Drive G

# jogo pequeno, direto na pasta DVD (sem dividir)
.\EasyRomsToOPL.ps1 -Iso "C:\isos\Katamari.iso" -DvdFolder

# substituir um jogo já instalado
.\EasyRomsToOPL.ps1 -Iso "C:\isos\GTA.iso" -Nome "GTA - San Andreas" -Force
```

Saída típica:

```
Modo: formato ul.* (padrão do OPL para USB)
  Nome    : God of War
  Serial  : SCUS_973.99
  Mídia   : DVD
  Tamanho : 7,94 GB
  Partes  : 8 x 1 GiB
  Arquivos: ul.574F9590.SCUS_973.99.00 .. ul.574F9590.SCUS_973.99.07
  ul.cfg  : +1 entrada de 64 bytes

  parte 1/8 gravada (1,00 GB)
  ...
Pronto! 'God of War' (SCUS_973.99) adicionado.
```

---

## Como funciona

1. **Validação** — abre o ISO, lê o *Primary Volume Descriptor* em `0x8000`, confirma
   `CD001` + `PLAYSTATION` e extrai o serial do `SYSTEM.CNF` (`BOOT2 = cdrom0:\SLUS_209.46;1`).
   Se não for jogo de PS2, para antes de escrever qualquer coisa.
2. **Planejamento** — calcula quantos pedaços de 1 GiB são necessários, a mídia
   (`0x14` DVD / `0x12` CD) e o nome de cada pedaço:
   `ul.<CRC32 do nome>.<serial>.<NN>`.
3. **Gravação** — copia em blocos de 8 MB, um arquivo por pedaço, e soma os bytes no final.
4. **Índice** — anexa 64 bytes ao `ul.cfg`. Em caso de erro no meio do caminho, apaga os
   pedaços já gravados para não deixar lixo no FAT32.

O formato completo, com offsets e o detalhe do CRC, está em
[`docs/UL-FORMAT.md`](docs/UL-FORMAT.md).

CLI e GUI não têm código duplicado: as duas chamam as mesmas funções de
`lib/UlFormat.ps1` (`Install-UlGame`, `Install-DvdFolderGame`, `Remove-UlGame`,
`Export-UlToIso`). A GUI só acrescenta a camada visual e roda a cópia em um runspace
separado (`gui/Worker.ps1`) para não travar a janela.

## Limitações (leia antes de culpar o script)

- **USB 1.1 do PS2 ≈ 1 MB/s.** Isso é ~5x mais lento que o DVD do console. Jogos com
  muito streaming (GTA, God of War, corrida) engasgam em vídeos e trocas de área.
- **FAT32 não aceita arquivo ≥ 4 GB.** Por isso o formato `ul.*` existe. A pasta `DVD\`
  só serve para ISOs abaixo de 4 GB.
- **DVD9 (7–8 GB)** funciona, mas vira 8 pedaços e sofre mais no barramento lento.
- **Fragmentação** degrada a leitura. Instale com o pendrive o mais vazio possível.
- **Não converte formato.** O script instala `.iso`; se você tem `.zso`/`.chd`, converta
  antes (o OPL também aceita `zso` em versões recentes, mas este script não gera).
- **Não baixa jogos.** Ele só move arquivos que você já tem.

## Troubleshooting

| Sintoma | Causa provável | Solução |
|---|---|---|
| Jogo aparece na lista e volta ao menu | Nome do pedaço/CRC errado | Reinstale com este script; ele calcula o CRC do OPL |
| Jogo não aparece de jeito nenhum | Entrada ausente no `ul.cfg` | Rode `-Listar`; se não listar, reinstale |
| Travamento em cena específica | Velocidade do USB / jogo exigente | No OPL: **Select → Mode 1** ou **Mode 3** |
| Erro "Já existe um jogo com o serial" | Mesmo jogo já instalado | Use `-Force` para substituir |
| Erro de espaço | Pendrive cheio | Libere espaço; o script precisa do tamanho do ISO + 4 KB |
| "Unidade F:\ não encontrada" | Letra do pendrive mudou | Use `-Drive G` (ou a letra correta) |
| Pendrive não monta / arquivos somem | Remoção sem ejetar | **Sempre** use "Ejetar com segurança"; FAT32 corrompe fácil |

## Testes

```powershell
# 17 asserções do formato (CRC, entrada de 64 bytes, nomes, normalização)
.\tests\Test-UlFormat.ps1

# inclui a leitura de um ISO real
.\tests\Test-UlFormat.ps1 -IsoPath "E:\jogos\God of War (USA).iso"

# 20 asserções do worker da GUI: instala, exporta, cancela
.\tests\Test-GuiWorker.ps1

# 231 asserções da interface: clica em todo controle, instala, remove e varre a unidade
.\tests\Test-GuiUi.ps1
```

```
CRC do OPL (USBA_crc32)
  [PASS] GTA - San Andreas
  [PASS] Medalha de Honra
  ...
Resultado: 17 passaram, 0 falharam
```

Os vetores de CRC não foram inventados: saíram de um pendrive real, com jogos instalados
por ferramenta oficial. Se os testes passam, o CRC é bit a bit o do OPL.

O `Test-GuiWorker.ps1` roda o **mesmo** `gui/Worker.ps1` que a interface usa, num
diretório temporário: instala um ISO, remonta o `.iso`, confere serial e tamanho, e
valida o cancelamento. Se ele passa, a GUI não tem caminho de cópia divergente. Ele usa
um jogo real quando há espaço para as duas cópias (~2,4× o tamanho do ISO); com o disco
cheio, gera um ISO sintético de 38 KB — o caminho de cópia é o mesmo.

O `Test-GuiUi.ps1` abre a janela de verdade (WPF) e **clica em cada controle**: chips de
unidade, INSTALAR, LIMPAR LISTA, RECARREGAR, COPIAR, ✕ dos arquivos, ✕ dos jogos
(cancelar / ESC / confirmar), ISO (exportar), glossário **`?`**, **SOM: ON/OFF**,
minimizar / maximizar / fechar — e ainda faz uma varredura que clica no que sobrou.
Ele usa uma unidade virtual (`subst`) para nunca gravar em disco real, e falha se
qualquer handler lançar exceção. Foi esse teste que encontrou o bug do clique que
fechava o programa. Ele também simula um pendrive entrando e saindo (`subst`) e
confere que a unidade aparece/some sozinha.

O painel do dispositivo é testado de verdade: escreve 16 MB na unidade virtual **sem
clicar em nada** e espera o texto de usado/livre mudar sozinho — é assim que o teste
prova que o número é em tempo real e não uma foto do momento em que a tela abriu.

A seção da biblioteca monta uma árvore de ROMs (PS1, SNES, N64, GBA, NDS, GC, Mega
Drive) e dois ISOs de PS2 **sintéticos** (ISO9660 + `SYSTEM.CNF`, gerados na hora),
para conferir a classificação de cada plataforma, a leitura do serial de dentro da
imagem, o `.cue`/`.bin` sem duplicata, o **STATUS** de cada linha (um ISO com o serial
que já está no `ul.cfg` nasce `JÁ NO OPL`; um jogo novo nasce com o botão
**INSTALAR**), os **cinco filtros** com contagem e a fila sendo limpa depois de
instalar. Ela também planta os falsos positivos que o usuário viu — `README.md` e um
`.iso` que não é ISO9660 — e exige que **não** apareçam, além de um Mega Drive com a
assinatura `SEGA` que **precisa** aparecer.

O aviso de outra unidade é simulado com um mapa de serial → letra: a linha vira
`JÁ NO PENDRIVE F:`, não oferece botão, a faixa amarela aparece, o filtro **NO
PENDRIVE** isola os casos e o clique não enfileira nada. O glossário é aberto e
fechado (`?`, **FECHAR** e **ESC**) e o texto é conferido termo a termo (`MODO`,
`ul.*`, `ul.cfg`, `OPL`, `README.md`). O chip de som alterna **ON/OFF** e o teste
confere que os sete WAVs carregaram — em silêncio, via `EASYROMS_MUTE=1`.

A última seção cria um **ZIP**, um **RAR** e um **7Z** com ISOs sintéticos: solta o ZIP e
o RAR na janela (extração em segundo plano, instalação automática, nome correto e
temporário apagado) e abre os três na **biblioteca**, conferindo que o jogo de dentro é
listado, que o serial vem do nome do ISO interno e que o **INSTALAR** do ZIP extrai e
instala.

```powershell
# discos com erro de I/O conhecido podem ser pulados
.\tests\Test-GuiUi.ps1 -SkipDrives "D"
```

## Verificar o pendrive (sem o PS2)

O `tools/Test-OplPendrive.ps1` reproduz no Windows o que o OPL faz ao abrir a
unidade USB — sem emular o console:

```powershell
.\tools\Test-OplPendrive.ps1 -Drive F
```

Ele lê o `ul.cfg` registro por registro (64 bytes), recalcula o CRC do nome, monta
o nome de cada pedaço, confere tamanho/numeração/sobras e abre cada `.iso` de
`DVD\` (ISO9660, PVD, `SYSTEM.CNF`, `BOOT2` e o executável apontado por ele). Sai
com código 1 se encontrar algo que o OPL não abriria.

No pendrive de teste (64 GB, 6 jogos) passou com 17 verificações OK. Num pendrive
falso quebrado, reprovou pedaço faltando, tamanho errado, pedaço sobrando e ISO
inválido.

O que ele **não** cobre: a porta USB do console, a versão do OPL instalada nele e a
compatibilidade específica do jogo.

## Estrutura

```
easyromstooplps2/
├── EasyRomsToOPL.ps1          # CLI
├── EasyRomsToOPL.cmd          # abre a interface sem console (portátil)
├── Instalar-EasyRomsToOPL.ps1 # instalador: copia, cria atalhos, desinstala
├── Instalar-EasyRomsToOPL.cmd # instalador (duplo clique)
├── dist/
│   └── Instalar-EasyRomsToOPL.cmd  # instalador de arquivo único (~583 KB)
├── lib/
│   ├── UlFormat.ps1           # CRC, entrada de 64 bytes, ISO9660, motor de instalação
│   └── GameLibrary.ps1        # varredura da unidade: jogos por plataforma
├── gui/
│   ├── EasyRomsToOPL.GUI.ps1  # front-end WPF
│   ├── MainWindow.xaml        # layout e tema (tokens do terminal.css)
│   ├── Worker.ps1             # execução assíncrona (runspace + progresso)
│   ├── EasyRomsToOPL.ico      # ícone do atalho
│   └── sounds/                # hover, click, boot, success, error, connect, disconnect
├── tools/
│   ├── New-Icon.ps1           # gera o .ico (16…256)
│   ├── New-Sounds.ps1         # sintetiza os WAVs da interface (nada de áudio da Sony)
│   ├── Build-Installer.ps1    # gera dist/Instalar-EasyRomsToOPL.cmd
│   └── Test-OplPendrive.ps1   # valida a unidade no formato que o OPL espera
├── tests/
│   ├── Test-UlFormat.ps1      # 17 asserções do formato
│   ├── Test-GuiWorker.ps1     # 20 asserções do worker da GUI
│   └── Test-GuiUi.ps1         # 231 asserções clicando em todo controle
├── docs/
│   ├── TUTORIAL.md            # passo a passo do zero (pendrive + FMCB + OPL)
│   ├── UL-FORMAT.md           # especificação do formato ul.* / ul.cfg
│   ├── CASE-STUDY.md          # diagnóstico de um pendrive real de 64 GB
│   ├── screenshot.png         # captura da interface (aba OPL)
│   ├── screenshot-biblioteca.png  # captura da biblioteca (instalado x para instalar)
│   └── screenshot-glossario.png   # captura do glossário (formatos, colunas, status)
├── CHANGELOG.md
└── LICENSE
```

## Documentação

- **[Tutorial completo](docs/TUTORIAL.md)** — do pendrive cru ao jogo rodando no PS2.
- **[Formato `ul.*`](docs/UL-FORMAT.md)** — a especificação que o script implementa.
- **[Estudo de caso](docs/CASE-STUDY.md)** — um pendrive real analisado byte a byte.

## Aviso legal

Este projeto é uma **ferramenta de instalação**, não uma fonte de jogos. Ele não baixa,
distribui nem contém nenhuma imagem de jogo.

Os jogos usados para validar e testar esta ferramenta eram **cópias originais** de
propriedade do autor, feitas a partir dos discos que ele possui. Nenhuma ROM foi
baixada da internet.

PlayStation 2 é marca registrada da Sony Interactive Entertainment. Este projeto não é
afiliado à Sony, ao Open PS2 Loader nem a qualquer distribuidora de jogos. Use apenas com
mídias que você possui legalmente — a legalidade de backups varia por país.

## Licença

[MIT](LICENSE) © 2026 [lucao019](https://github.com/lucao019)
