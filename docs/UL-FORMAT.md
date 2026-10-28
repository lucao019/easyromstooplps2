# O formato `ul.*` / `ul.cfg` do OPL

Especificação do formato que o Open PS2 Loader usa para jogos em USB, com o que este
projeto implementa e como foi validado. Serve tanto para entender o script quanto para
escrever sua própria ferramenta.

Referências no código-fonte do OPL:

| Item | Arquivo |
|---|---|
| Struct da entrada (64 bytes) | `include/supportbase.h` → `USBExtreme_game_entry_t` |
| Nome dos pedaços | `src/supportbase.c` → `sbCreatePath_name()` |
| CRC | `src/system.c` → `USBA_crc32()` |

---

## 1. Por que esse formato existe

O OPL lê pendrives em **FAT32**, que não aceita arquivo de 4 GB ou mais. Um DVD de PS2
"cheio" tem 4,38 GiB, então quase nenhum jogo cabe como `.iso` solto.

A solução (herdada do USBExtreme/USBAdvance) é cortar a imagem em pedaços de exatamente
**1 GiB** e manter um índice binário dizendo quantos pedaços cada jogo tem. O OPL abre o
jogo como se fosse um disco, lendo os pedaços em sequência.

## 2. Nomes dos arquivos

```
ul.<CRC32>.<SERIAL>.<NN>
```

| Campo | Exemplo | Regra |
|---|---|---|
| prefixo | `ul.` | literal |
| CRC32 | `7C39E2C0` | `USBA_crc32(nome)`, **8 hex maiúsculo** |
| serial | `SLUS_209.46` | do `SYSTEM.CNF`, até 12 caracteres |
| índice | `00` | **2 hex minúsculo**, de `00` a `FE` |

Exemplo real (GTA San Andreas, 5 pedaços):

```
ul.7C39E2C0.SLUS_209.46.00
ul.7C39E2C0.SLUS_209.46.01
ul.7C39E2C0.SLUS_209.46.02
ul.7C39E2C0.SLUS_209.46.03
ul.7C39E2C0.SLUS_209.46.04
```

Regras que quebram tudo se ignoradas:

- O CRC é calculado sobre o **nome exibido** (o campo `name` do `ul.cfg`), não sobre o
  serial nem sobre o nome do arquivo ISO.
- Trocar uma letra do nome muda o CRC e, portanto, **todos** os nomes de pedaço.
- Todos os pedaços menos o último têm exatamente `1 GiB` = `1.073.741.824` bytes.
- A soma dos pedaços é **exatamente** o tamanho do ISO original.

## 3. Entrada do `ul.cfg`

Arquivo binário, **64 bytes por jogo**, sem cabeçalho. Offset relativo ao início da
entrada:

| Offset | Tam | Campo | Conteúdo |
|---|---|---|---|
| `0x00` | 32 | `name` | nome exibido no OPL, ASCII, terminado em `\0` |
| `0x20` | 3 | `magic` | `"ul."` |
| `0x23` | 12 | `startup` | serial, ex. `SLUS_209.46` |
| `0x2F` | 1 | `parts` | número de pedaços (`1`–`255`) |
| `0x30` | 1 | `media` | `0x14` = DVD, `0x12` = CD |
| `0x31` | 4 | — | zeros |
| `0x35` | 1 | `Byte08` | sempre `0x08` (compatibilidade) |
| `0x36` | 10 | — | zeros |

Hexdump de uma entrada real (`God of War` / `SCUS_973.99`, 8 pedaços, DVD):

```
0000  47 6F 64 20 6F 66 20 57 61 72 00 00 00 00 00 00  God of War......
0010  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  ................
0020  75 6C 2E 53 43 55 53 5F 39 37 33 2E 39 39 00 08  ul.SCUS_973.99..
0030  14 00 00 00 00 08 00 00 00 00 00 00 00 00 00 00  ................
```

Repare em `0x2E`: o serial tem 11 caracteres e sobra **um NUL** de padding. É `0x2F` que
carrega `08` (oito pedaços), e `0x30` carrega `14` (DVD).

O tamanho do arquivo deve ser múltiplo de 64. Um `ul.cfg` de 192 bytes contém 3 jogos.

> **Importante:** não basta copiar os pedaços. Sem a entrada no `ul.cfg` o OPL não lista
> o jogo; com a entrada mas CRC errado, ele lista e falha ao abrir.

## 4. O CRC do OPL (a parte que ninguém acerta)

`USBA_crc32()` **não** é o CRC32 padrão (zlib/PNG/Ethernet). Três diferenças:

1. A tabela de 256 posições é gerada **de trás para frente** (`tab[255 - i]`).
2. O valor inicial é `tab[0]`, e não `0xFFFFFFFF`.
3. O laço processa **até o byte NUL inclusive** (`while (byte != 0 && count <= 32)`),
   então o terminador entra no cálculo.

Resultado: `crc32("GTA - San Andreas")` em zlib dá `0x…`, mas o OPL espera `7C39E2C0`.

### Implementação de referência

```c
static uint32_t crc_table[256];

static void crc32_init(void) {
    uint32_t crc;
    for (int i = 0; i < 256; i++) {
        crc = (uint32_t)i << 24;
        for (int j = 0; j < 8; j++)
            crc = (crc & 0x80000000) ? (crc << 1) : ((crc << 1) ^ 0x04C11DB7);
        crc_table[255 - i] = crc;      /* tabela invertida */
    }
}

uint32_t USBA_crc32(const char *string) {
    uint32_t crc = crc_table[0];       /* não é 0xFFFFFFFF */
    uint32_t c, ind;
    int count = 0;
    do {
        c = (uint8_t)string[count++];
        ind = (c ^ (crc >> 24)) & 0xFF;
        crc = crc_table[ind] ^ (crc << 8);
    } while (c && count <= 32);        /* processa o NUL e para */
    return crc;
}
```

O equivalente em PowerShell está em
[`lib/UlFormat.ps1`](../lib/UlFormat.ps1) → `Get-UsbaCrc32`.

### Vetores verificados

Extraídos de um pendrive real, com jogos instalados por ferramenta oficial:

| Nome | CRC |
|---|---|
| `GTA - San Andreas` | `7C39E2C0` |
| `Medalha de Honra` | `75CC3FAF` |
| `God of War` | `574F9590` |
| `TESTE SCRIPT` (sintético) | `56D86CD8` |

Esses valores são asserções em [`tests/Test-UlFormat.ps1`](../tests/Test-UlFormat.ps1).

## 5. Como descobrir o serial

O serial não deve ser adivinhado pelo nome do arquivo. Ele está dentro do ISO, em
`SYSTEM.CNF`:

```
BOOT2 = cdrom0:\SLUS_209.46;1
VER   = 1.00
VMODE = NTSC
```

Para chegar lá sem montar a imagem:

1. Ler o setor 16 (offset `0x8000`), 2048 bytes → *Primary Volume Descriptor*.
2. Conferir `pvd[1..5] == "CD001"` e `pvd[0] == 1`.
3. `rootLba = u32(pvd, 158)`, `rootLen = u32(pvd, 166)`.
4. Ler o diretório raiz em `rootLba * 2048` e varrer os registros.
5. Achar `SYSTEM.CNF;1`, ler o arquivo no LBA indicado e aplicar
   `BOOT2\s*=\s*cdrom0:\\?([^\r\n;]+)`.

Também vale checar `SystemId` (`pvd[8..39]`) = `PLAYSTATION`. É o que separa um jogo de
PS2 de um ISO de PS1 ou de um arquivo qualquer.

## 6. Mídia: DVD ou CD

O campo `media` é `0x14` para DVD e `0x12` para CD. A heurística usada por este script é o
tamanho: acima de 700 MB → DVD. Jogos de CD de PS2 (raros, até ~700 MB) recebem `0x12`.

## 7. Pasta `DVD\`

Alternativa ao formato `ul.*`: o OPL também lê `.iso` inteiro na pasta `DVD\`. Vantagens
e limites:

- **Só abaixo de 4 GB** (limite do FAT32).
- Um arquivo só — fácil de copiar de volta para o PC.
- O OPL mantém um cache (`games.bin`) e revarre a pasta sozinho.

## 8. Verificação de integridade

Não existe checksum no formato. A verificação possível é comparar tamanhos:

```
soma(tamanho dos pedaços) == tamanho do ISO original
```

E, para garantir que a imagem é válida, abrir o `SYSTEM.CNF` de dentro dela (seção 5).
Um ISO truncado costuma falhar já no PVD.

## 9. Resumo para implementadores

```
para instalar o jogo:
  serial = ler SYSTEM.CNF do ISO
  nome   = ASCII(nome escolhido, máx 32, sem acento)
  crc    = USBA_crc32(nome)                    # inclui o NUL
  partes = ceil(tamanho_iso / 1 GiB)
  para i em 0..partes-1:
      gravar "ul.{crc:X8}.{serial}.{i:x2}" com o próximo bloco de 1 GiB
  anexar 64 bytes ao ul.cfg:
      name[32] "ul." serial[12] partes media 00*4 08 00*10
```
