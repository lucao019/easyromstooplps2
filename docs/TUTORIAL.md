# Tutorial: do pendrive cru ao jogo rodando no PS2

Este é o caminho completo, na ordem em que as coisas precisam acontecer. Se você só quer
instalar mais um jogo num pendrive que **já funciona**, pule para o
[passo 5](#5-adicionar-um-jogo).

> **Antes de começar:** você precisa de um PS2 com **FreeMcBoot** e do **OPL** já
> instalados. O pendrive não dá boot no console — quem carrega o OPL é o memory card.
> Se o seu PS2 não abre o menu do OPL, resolva isso primeiro; nenhum script daqui vai
> ajudar nessa parte.

---

## Índice

1. [Entenda o que é o OPL](#1-entenda-o-que-é-o-opl)
2. [Prepare o pendrive](#2-prepare-o-pendrive)
3. [Crie a estrutura de pastas](#3-crie-a-estrutura-de-pastas)
4. [Confirme que o PS2 enxerga o pendrive](#4-confirme-que-o-ps2-enxerga-o-pendrive)
5. [Adicionar um jogo](#5-adicionar-um-jogo)
6. [Verificar antes de desconectar](#6-verificar-antes-de-desconectar)
7. [Testar no console](#7-testar-no-console)
8. [Ajustar desempenho por jogo](#8-ajustar-desempenho-por-jogo)
9. [Levar os jogos de volta para o PC](#9-levar-os-jogos-de-volta-para-o-pc)
10. [Checklist final](#10-checklist-final)

---

## 1. Entenda o que é o OPL

O **OPL (Open PS2 Loader)** não é emulador. Ele roda no hardware real do PS2 e faz o
console acreditar que o disco está inserido — só que os dados vêm do pendrive pela porta
USB. Compatibilidade e gráficos são os do console de verdade; o único limite novo é a
**banda do USB**.

```
Memory card (FMCB)  ->  carrega OPL.elf  ->  OPL lê o pendrive  ->  PS2 roda o jogo
```

Três consequências práticas:

- O pendrive **não precisa** de `OPL.elf` na raiz (embora possa ter, em `APPS\`).
- O USB do PS2 é **1.1**, cerca de **1 MB/s**. É o gargalo de tudo.
- O sistema de arquivos tem que ser **FAT32**. O OPL não lê NTFS nem exFAT.

## 2. Prepare o pendrive

Use um pendrive de 8 GB ou mais. 32 GB já cabem ~6 jogos médios; 64 GB cabem ~12.

1. Abra o **Gerenciamento de Disco** do Windows (`diskmgmt.msc`).
2. Confirme que o pendrive está em **MBR** (não GPT) e tem uma única partição.
3. Formate em **FAT32**, alocação padrão.

> **Por que FAT32 e não exFAT?** O OPL só implementa FAT. Um pendrive exFAT simplesmente
> não aparece na lista de dispositivos do console.
>
> **Limite do FAT32:** nenhum arquivo pode ter 4 GB ou mais. É exatamente por isso que o
> formato `ul.*` divide o jogo em pedaços de 1 GiB.

Se o Windows se recusar a formatar em FAT32 por causa do tamanho, use
[`fat32format`](https://github.com/antoinersx/fat32format) (GUI) ou o `format` do próprio
Windows em um pendrive de até 32 GB.

## 3. Crie a estrutura de pastas

O OPL cria o que falta, mas deixar pronto evita susto. Na raiz do pendrive:

```
F:\
├── DVD\      ISOs inteiros (abaixo de 4 GB) — lidos direto
├── CD\       ISOs de jogos em CD
├── ART\      capas dos jogos
├── THM\      temas do OPL
├── VMC\      memory cards virtuais
├── CFG\      configuração por jogo
├── CHT\      cheats
└── APPS\     programas .elf
```

Você pode criar todas de uma vez:

```powershell
$root = 'F:\'
'DVD','CD','ART','THM','VMC','CFG','CHT','APPS' |
    ForEach-Object { New-Item -ItemType Directory -Force (Join-Path $root $_) | Out-Null }
```

Os jogos em `ul.*` ficam na **raiz**, não em subpasta. É o `ul.cfg` da raiz que o OPL lê.

## 4. Confirme que o PS2 enxerga o pendrive

Antes de copiar 8 GB, faça o teste de 30 segundos:

1. Ejete o pendrive com segurança, coloque no PS2, ligue com o memory card do FMCB.
2. Abra o **OPL**.
3. Vá em **USB** (ou `Settings → USB device start mode` se a lista estiver vazia).

Se aparecer a lista (mesmo vazia), o pendrive está OK. Se der "no device", o problema é
formatação/porta — não é o jogo.

> Dica: use a porta USB **de cima** (a mais próxima da saída de vídeo) em modelos
> fat/slim antigos; algumas portas frontais são mais instáveis.

## 5. Adicionar um jogo

### 5.0 Caminho rápido: interface gráfica

Se você não quer terminal:

1. Duplo clique em **`EasyRomsToOPL.cmd`**.
2. Confira o chip do pendrive em **PENDRIVE** (o removível é escolhido sozinho).
3. **Arraste os `.iso`** para a área pontilhada.
4. Veja o serial que apareceu — se estiver vazio ou vermelho, o ISO não serve.
5. Escolha o modo (**UL.\* (1 GiB)** quase sempre) e o nome no menu.
6. Clique em **SIMULAR** para ver o plano; depois **INSTALAR NO PENDRIVE**.

O log mostra cada pedaço gravado. Ao terminar, a lista **JOGOS NA UNIDADE** já aparece
atualizada — se o jogo está ali, o PS2 vai enxergar. O resto deste passo é o caminho CLI,
útil para automação e para entender o que a interface faz por baixo.

**Não sabe o que já tem no pendrive?** Clique na unidade e abra a aba **BIBLIOTECA**: o
app varre a unidade e lista todos os jogos encontrados, separados por plataforma (PS2,
PS1, SNES, N64, GBA, NDS, GC/Wii, Mega Drive, Master System, NES, PSP, Dreamcast), com
pasta e tamanho. Jogos já instalados aparecem marcados `OPL`; em um ISO de PS2, o botão
**+** coloca o jogo na lista de instalação. PS1 e Nintendo são **só consulta** — o OPL
executa apenas jogos de PS2. A varredura roda em segundo plano e se refaz sozinha quando
o pendrive entra ou sai.

### 5.1 Clone a ferramenta

```powershell
git clone https://github.com/lucao019/easyromstooplps2.git
cd easyromstooplps2
```

Se você só quer a interface instalada no PC, sem clonar nada: baixe
`dist/Instalar-EasyRomsToOPL.cmd` e dê duplo clique. Ele instala em
`%LOCALAPPDATA%\EasyRomsToOPL` e cria o atalho na Área de Trabalho e no Menu Iniciar —
sem administrador e sem tocar no registro. O desinstalador fica no Menu Iniciar.

### 5.2 Veja o estado atual

```powershell
.\EasyRomsToOPL.ps1 -Listar
```

```
Pendrive: F:\
Livre: 39,44 GB de 57,27 GB

Jogos em ul.cfg:

Nome              Serial      Media Partes Crc
----              ------      ----- ------ ---
GTA - San Andreas SLUS_209.46 DVD        5 7C39E2C0
Medalha de Honra  SLUS_215.97 DVD        2 75CC3FAF
God of War        SCUS_973.99 DVD        8 574F9590

ISOs soltos na pasta DVD (lidos direto pelo OPL):
Name                       Tamanho
----                       -------
ULTIMO BOMBA.iso           2,56 GB
```

### 5.3 Simule primeiro

```powershell
.\EasyRomsToOPL.ps1 -Iso "E:\jogos\Shadow of the Colossus.iso" -DryRun
```

O `-DryRun` mostra nome, serial lido do ISO, mídia, número de pedaços e os nomes dos
arquivos. **Nada é gravado.** Se o serial estiver errado ou vazio, o problema é o ISO —
não tente instalar.

### 5.4 Instale

```powershell
.\EasyRomsToOPL.ps1 -Iso "E:\jogos\Shadow of the Colossus.iso" -Nome "Shadow of the Colossus"
```

O nome exibido no menu tem no máximo 32 caracteres e é convertido para ASCII (sem acento).
Escolha bem: o nome entra no cálculo do CRC dos arquivos — renomear depois exige
reinstalar.

### 5.5 Alternativa: jogo pequeno como ISO solto

Se o jogo tem menos de 4 GB, você pode deixá-lo inteiro na pasta `DVD\`:

```powershell
.\EasyRomsToOPL.ps1 -Iso "E:\jogos\Katamari Damacy.iso" -DvdFolder
```

O OPL lê ISOs de `DVD\` diretamente. Vantagem: um arquivo só, fácil de copiar de volta.
Desvantagem: não serve para jogos acima de 4 GB (o FAT32 recusa).

> **Quando usar cada modo?**
> `ul.*` para tudo acima de 4 GB e para o padrão "de fábrica" do OPL.
> `DVD\` para jogos pequenos, quando você quer simplicidade.

## 6. Verificar antes de desconectar

```powershell
.\EasyRomsToOPL.ps1 -Listar
```

Confira:

- O jogo novo aparece em `ul.cfg` com o serial certo e a contagem de partes correta.
- O espaço livre caiu aproximadamente pelo tamanho do ISO.
- Deixe **pelo menos 1 GB livre** — o OPL grava `ul.cfg`, configurações e memory cards
  virtuais no pendrive.

Conferência manual dos pedaços (opcional, mas útil em jogo grande):

```powershell
$iso  = 'E:\jogos\God of War (USA).iso'
$base = 'F:\ul.574F9590.SCUS_973.99'
$sum  = (Get-ChildItem "$base.*" | Measure-Object Length -Sum).Sum
"partes: $sum | iso: $((Get-Item $iso).Length) | igual: $($sum -eq (Get-Item $iso).Length)"
```

Se der `igual: True`, a soma dos pedaços é exatamente o ISO original.

**Ejete com segurança.** Arrancar o pendrive com escrita pendente corrompe o FAT32 e você
perde o índice inteiro.

## 7. Testar no console

1. Pendrive no PS2, OPL aberto, entre em **USB**.
2. O jogo novo deve aparecer. Se a lista estiver em cache, saia e volte.
3. Rode o jogo e deixe passar do primeiro carregamento — é onde erro de instalação
   aparece.
4. Se voltar ao menu do OPL: nome de arquivo/CRC não bateu. Reinstale com o script.

## 8. Ajustar desempenho por jogo

No OPL, selecione o jogo e pressione **Select** para abrir os **modes** de compatibilidade.
Os mais usados:

| Mode | Quando ativar |
|---|---|
| **1** | Jogo trava em vídeo ou tela de loading (mais comum no USB) |
| **3** | Jogo trava ao salvar/carregar |
| **6** | Jogos de DVD9 (dupla camada) que não passam da primeira área |
| **2** | Alguns jogos de CD antigos |

Ative **um por vez** e teste. As configurações ficam em `CFG\`, por jogo.

Expectativa realista com USB 1.1 (~1 MB/s):

- **Rodam bem:** luta, RPG por turnos, esportes, 2D, arcade, jogos de 1 disco com poucos vídeos.
- **Engasgam:** GTA, God of War, jogos de corrida, qualquer coisa com streaming pesado.
- Não é defeito da instalação — é o barramento do console.

## 9. Levar os jogos de volta para o PC

Na interface, cada jogo `ul.*` tem um botão **ISO** que remonta os pedaços em um `.iso`
único na pasta que você escolher. Abaixo, o equivalente em linha de comando.

O PCSX2 **não lê** os pedaços `ul.*`. Para rodar no PC, remonte o ISO único: basta
concatenar os pedaços na ordem `00`, `01`, `02`…

```powershell
$dst  = 'E:\emulador PS2\games'
$base = 'F:\ul.574F9590.SCUS_973.99'   # ajuste para o jogo desejado
$parts = 8

$out = [IO.File]::Create((Join-Path $dst 'God of War (USA).iso'))
try {
    $buf = New-Object byte[] (8MB)
    for ($i = 0; $i -lt $parts; $i++) {
        $in = [IO.File]::OpenRead(('{0}.{1:x2}' -f $base, $i))
        try { while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $n) } }
        finally { $in.Dispose() }
    }
} finally { $out.Dispose() }
```

Confira o resultado abrindo o `SYSTEM.CNF` de dentro do ISO (o script já tem a função):

```powershell
. .\lib\UlFormat.ps1
Get-IsoInfo 'E:\emulador PS2\games\God of War (USA).iso' | Format-List
```

```
Pvd       : CD001
SystemId  : PLAYSTATION
SystemCnf : True
Serial    : SCUS_973.99
IsPs2     : True
```

No PCSX2: `Settings → Game List → Add Folder` e aponte para a pasta dos ISOs. Se você
mudou o emulador de disco, a pasta antiga continua configurada e a lista fica vazia — é
só adicionar a nova.

## 10. Checklist final

- [ ] Pendrive em **FAT32/MBR**, ejetado com segurança sempre.
- [ ] `-Listar` mostra todos os jogos, com serial e número de partes corretos.
- [ ] A soma dos pedaços de cada jogo bate com o ISO original.
- [ ] Pelo menos ~1 GB livre no pendrive.
- [ ] Cada jogo novo foi aberto no PS2 até o primeiro carregamento.
- [ ] Modes de compatibilidade anotados (se algum precisou).
- [ ] PS2 do destino boota o OPL pelo memory card (FMCB) — não pelo pendrive.

---

## Problemas comuns

**"Unidade F:\ não encontrada"**
A letra mudou. Rode `Get-PSDrive -PSProvider FileSystem` e use `-Drive` com a letra certa.

**"O arquivo não parece um jogo de PS2"**
O ISO não tem `SYSTEM.CNF`/`PLAYSTATION` no volume. Pode ser ISO de PS1, imagem de áudio
ou arquivo corrompido. Teste abrir no PCSX2.

**"Já existe um jogo com o serial ..."**
Já há uma entrada com aquele serial no `ul.cfg`. Use `-Force` para substituir (o script
apaga os pedaços antigos quando o nome muda) ou remova o jogo antigo antes.

**Jogo instalado, mas o OPL não lista**
Saia e volte na tela USB; o OPL cacheia a pasta `DVD\` em `games.bin`. Se persistir, o
`ul.cfg` pode estar truncado — confira se o tamanho é múltiplo de 64 bytes.

**Jogo lista e volta ao menu**
Quase sempre CRC/nome divergente. Reinstale com este script em vez de renomear arquivos.

**Tela preta em jogo DVD9**
Ative **Mode 6**. Se continuar, o ISO provavelmente foi cortado errado na origem.

**Pendrive "some" no meio da cópia**
Cabo/porta ruim ou pendrive falsificado. Teste com `h2testw` antes de confiar.
