# Estudo de caso: um pendrive de 64 GB do OPL, byte a byte

> Análise feita em 28/10/2026 em um pendrive SanDisk 64 GB (rótulo `64 GB`, letra `F:`),
> usado em um PS2 fat com FreeMcBoot. Este documento registra o diagnóstico que originou
> a ferramenta [EasyRomsToOPL](../README.md).

---

## 1. O que estava ali (e o que não estava)

O pendrive **não** é um emulador. É o **OPL — Open PS2 Loader**, um loader: o jogo roda no
hardware real do PS2, com o mesmo Emotion Engine e a mesma GPU. O OPL engana o console,
fazendo-o acreditar que o disco de DVD está inserido, quando os dados vêm do pendrive
pela porta USB. Compatibilidade e velocidade são as do console real; o único limite novo é
a banda do USB.

Quem inicia o OPL **não é o pendrive** — não havia nenhum `OPL.elf` na raiz. O boot vem do
**memory card com FreeMcBoot (FMCB)**, que carrega o OPL, e este lê o pendrive. Se o PS2
parar de abrir o menu do OPL, o problema é o memory card, não o pendrive.

## 2. Mapa do pendrive

```
F:\
├── ul.cfg                          <- índice dos jogos "ul" (64 bytes por jogo)
├── ul.7C39E2C0.SLUS_209.46.00..04  <- GTA San Andreas, 5 pedaços de 1 GiB (4,21 GB)
├── ul.75CC3FAF.SLUS_215.97.00..01  <- Medalha de Honra, 2 pedaços (1,16 GB)
├── DVD\
│   ├── ULTIMO BOMBA.iso            <- ISO inteiro, 2,56 GB (lido direto)
│   └── games.bin                   <- cache que o próprio OPL cria da pasta DVD
├── CD\        (vazio — ISOs de jogos em CD)
├── ART\       (capas)   THM\ (temas)   VMC\ (memory cards virtuais)
├── CHT\       (cheats)  CFG\ (config por jogo)   APPS\ (programas .elf)
```

| Jogo | Serial | Formato | Tamanho |
|---|---|---|---|
| GTA - San Andreas | `SLUS_209.46` | `ul.*` (5 partes) | 4,21 GB |
| Medalha de Honra (*Medal of Honor: Vanguard*) | `SLUS_215.97` | `ul.*` (2 partes) | 1,16 GB |
| ULTIMO BOMBA (patch brasileiro, serial japonês) | `SLPM_663.74` | `.iso` em `DVD\` | 2,56 GB |
| God of War | `SCUS_973.99` | `ul.*` (8 partes) | 7,94 GB |
| Crash Twinsanity | `SLUS_209.09` | `.iso` em `DVD\` | 1,96 GB |

**Ocupação final:** ~18 GB usados, **~39 GB livres** — cabem mais ~10 jogos médios.

## 3. As regras que mandam em tudo

1. **FAT32** → nenhum arquivo pode ter **4 GB ou mais**. Um DVD de PS2 "cheio" tem
   4,38 GiB, então quase todo jogo **não cabe** como `.iso` solto.
2. Por isso o padrão do OPL no USB é o formato **`ul.*`**: o ISO é cortado em pedaços de
   exatamente **1 GiB** (`00`, `01`, `02`…) e o índice `ul.cfg` diz quantos pedaços cada
   jogo tem.
3. **`ul.cfg` é binário, 64 bytes por jogo:**
   `nome[32] + "ul." + serial[12] + partes(1) + mídia(1) + 4 zeros + 0x08 + 10 zeros`
   (mídia `0x14` = DVD, `0x12` = CD). O nome do arquivo é
   `ul.<CRC32 do nome>.<serial>.<NN>` — e esse CRC é específico do OPL (inclui o byte
   nulo final), não é o CRC32 comum.
4. **Só copiar os pedaços não funciona**: sem a entrada no `ul.cfg` o OPL não lista o
   jogo. E se nome/CRC não baterem, o OPL lista mas não acha os arquivos.
5. **Pasta `DVD\`** aceita `.iso` inteiro — mas só abaixo de 4 GB. O OPL revarre a pasta
   sozinha e atualiza o `games.bin`.
6. **DVD9** (7–8 GB, dupla camada) funciona, mas vira 8 pedaços e sofre mais no USB.

## 4. O que foi validado na prática

### 4.1 CRC contra dados reais

O maior risco de qualquer implementação caseira é o CRC. Ele foi reconstruído a partir de
`USBA_crc32()` e comparado com os nomes dos arquivos que já existiam no pendrive:

| Nome | CRC calculado | Arquivo no pendrive | Resultado |
|---|---|---|---|
| `GTA - San Andreas` | `7C39E2C0` | `ul.7C39E2C0.SLUS_209.46.00` | ✅ |
| `Medalha de Honra` | `75CC3FAF` | `ul.75CC3FAF.SLUS_215.97.00` | ✅ |

Bater os dois significa que o algoritmo é bit a bit o do OPL.

### 4.2 Instalação de um DVD9

`God of War (USA)`, 8.522.792.960 bytes:

```
ul.574F9590.SCUS_973.99.00 .. 07    (7 x 1 GiB + 960 MB)
ul.cfg: 128 -> 192 bytes            (+1 entrada de 64 bytes)
soma das partes: 8.522.792.960       (= tamanho do ISO) ✅
```

Hexdump da entrada nova, já no pendrive:

```
0000  47 6F 64 20 6F 66 20 57 61 72 00 00 00 00 00 00  God of War......
0020  75 6C 2E 53 43 55 53 5F 39 37 33 2E 39 39 00 08  ul.SCUS_973.99..
0030  14 00 00 00 00 08 00 00 00 00 00 00 00 00 00 00  ................
```

`parts = 0x08`, `media = 0x14`, `Byte08 = 0x08`. Exatamente o layout esperado.

### 4.3 ISO pequeno na pasta DVD

`Crash Twinsanity (USA)`, 2.108.096.512 bytes — abaixo do limite de 4 GB, então foi
copiado inteiro para `DVD\`. Verificação sem montar a imagem:

```
PVD       = CD001
SystemId  = PLAYSTATION
BOOT2     = cdrom0:\SLUS_209.09;1
```

### 4.4 Remontagem para o PC (PCSX2)

O PCSX2 não lê `ul.*`. Concatenando os pedaços na ordem, os cinco jogos voltaram a ISOs
únicos e foram validados por ISO9660 + `SYSTEM.CNF`:

| Arquivo | Serial | Bytes |
|---|---|---|
| `GTA - San Andreas (USA).iso` | `SLUS_209.46` | 4.517.314.560 |
| `Medalha de Honra (SLUS_215.97).iso` | `SLUS_215.97` | 1.240.416.256 |
| `ULTIMO BOMBA.iso` | `SLPM_663.74` | 2.745.991.168 |
| `God of War (USA).iso` | `SCUS_973.99` | 8.522.792.960 |
| `Crash Twinsanity (USA).iso` | `SLUS_209.09` | 2.108.096.512 |

Os tamanhos batem byte a byte com a soma dos pedaços originais, e todos abrem com
`SYSTEM.CNF` presente. Nada foi perdido na ida e volta.

## 5. Desempenho observado

O USB do PS2 é **1.1** (12 Mbit/s) → na prática **~1 MB/s**. Isso é ~5x mais lento que o
DVD do console. Consequências:

- Jogos com vídeos/carregamento pesado (GTA, God of War, corrida) **engasgam**.
- Luta, RPG por turnos, esportes, 2D e arcade rodam bem.
- Fragmentação piora a leitura: instale com o pendrive o mais vazio possível.
- Travou numa cena? No OPL, **Select → Mode 1** ou **Mode 3**.

## 6. Notas de campo

- **Pendrive não é o gargalo.** Cópia sustentada de 84 MB/s no PC; o limite é sempre o
  USB 1.1 do console.
- **`Get-Volume` travava** em um dos discos do ambiente de teste. A ferramenta passou a
  usar `System.IO.DriveInfo`, que responde na hora — e é por isso que o script não depende
  de cmdlets de armazenamento.
- **Um HD do conjunto de teste estava falhando** (Event 153 / `storahci` 129: reset de
  porta). Nada no pendrive foi afetado, mas o diagnóstico inicial chegou a parecer
  "pendrive lento" quando era o disco de origem. Antes de culpar a cópia, confira a saúde
  do disco de origem com CrystalDiskInfo.
- **Sempre ejete com segurança.** FAT32 corrompe fácil, e o `ul.cfg` é o ponto único de
  falha de todos os jogos.

## 7. Checklist antes de devolver o pendrive

- [ ] Ejetar com segurança no Windows.
- [ ] Confirmar que o PS2 de destino boota o OPL pelo memory card (FMCB).
- [ ] Testar 1 jogo novo antes de encher o pendrive.
- [ ] Deixar pelo menos ~1 GB livre (o OPL grava `ul.cfg`, configs e VMC).
