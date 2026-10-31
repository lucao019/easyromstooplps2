# Ficha do jogo — o que é, quando saiu, gênero, estúdio...

Toda vez que você clica no **ℹ️** de um jogo (na Biblioteca ou na aba OPL), o app mostra
uma ficha com o que sabe sobre ele. A busca é **híbrida** e funciona em três camadas:

1. **Catálogo local** — `data/games.json`, indexado por serial. Instantâneo, offline.
2. **Cache** — `data/games.cache.json`, o que já foi buscado online antes.
3. **Online (IGDB)** — só se você configurar as credenciais. O resultado vira cache.

Sem internet e sem catálogo, a ficha mostra só o que o app já descobre sozinho no
pendrive: nome, serial, mídia (DVD/CD), número de partes, CRC e tipo de origem.
Nada quebra — só fica mais pobre.

---

## 1. O que a ficha mostra

| Campo | De onde vem |
|---|---|
| Nome, Serial, Mídia, Partes, CRC | do próprio arquivo no pendrive (sempre) |
| Lançamento, Gênero, Desenvolvedora, Publicadora, Nota, Sinopse, Plataformas | catálogo local ou IGDB |
| Fonte | `catálogo` ou `IGDB` — diz de onde veio o resto |

---

## 2. Catálogo local (offline, recomendado para jogos específicos)

Edite `data/games.json` e adicione uma chave por **serial** (exatamente como o app
mostra na lista de jogos — maiúsculas e com ponto, tipo `SLUS_209.46`):

```json
{
  "SLUS_209.46": {
    "Titulo": "Grand Theft Auto: San Andreas",
    "Lancamento": "26/10/2004",
    "Genero": "Ação, Mundo aberto",
    "Desenvolvedora": "Rockstar North",
    "Publicadora": "Rockstar Games",
    "Nota": "9.5/10",
    "Sinopse": "CJ volta a Los Santos...",
    "Origem": "catálogo"
  }
}
```

Todos os campos são opcionais — o que você preencher aparece, o resto some.
O catálogo local tem prioridade sobre o cache e sobre a internet.

> O arquivo começa vazio (`{}`). O serial do jogo você vê na própria Biblioteca,
> logo abaixo do nome, ou na aba OPL.

---

## 3. Busca online (IGDB)

A [IGDB](https://api.igdb.com) é mantida pelo Twitch e tem fichas boas de jogos de
PS2. Precisa de um app registrado (grátis) para obter um **Client ID** e um
**Client Secret**.

### 3.1. Criar o app no Twitch

1. Acesse <https://dev.twitch.tv/console/apps> e faça login.
2. **Register Your Application**.
   - *Name*: qualquer coisa (ex.: `EasyRomsToOPL`).
   - *OAuth Redirect URLs*: `http://localhost` (não é usado, mas é obrigatório).
   - *Category*: `Application Integration`.
3. **Create**. Copie o **Client ID** e clique em **New Secret** para gerar o
   **Client Secret**.

### 3.2. Dizer ao app as credenciais

Escolha **uma** das duas formas:

**Arquivo** — copie `data/igdb.example.json` para `data/igdb.json` e preencha:

```json
{
  "client_id": "SEU_CLIENT_ID_AQUI",
  "client_secret": "SEU_CLIENT_SECRET_AQUI"
}
```

**Variáveis de ambiente** (útil para não deixar segredo em arquivo):

```powershell
$env:IGDB_CLIENT_ID     = 'seu_client_id'
$env:IGDB_CLIENT_SECRET = 'seu_client_secret'
```

O token de acesso é só de leitura, fica em memória e expira sozinho — o app
renova quando precisa. `data/igdb.json` e `data/games.cache.json` estão no
`.gitignore` e **nunca** são versionados.

### 3.3. Como a busca funciona

1. Tenta achar o jogo pelo **serial** (ex.: `SLUS_209.46`).
2. Se não achar, tenta pelo **nome**, limpando tags de região/versão
   (`(USA)`, `[v2]`, etc.).
3. O primeiro acerto bom (nome batendo) vira a ficha, e é guardado em
   `data/games.cache.json` para não buscar de novo.

Se a busca não achar nada, a ficha mostra o que é local e marca `SEM FICHA`.

---

## 4. Onde isso vive no código

| Arquivo | Papel |
|---|---|
| `lib/GameInfo.ps1` | módulo: catálogo, cache, IGDB, formatação |
| `gui/MainWindow.xaml` | overlay `InfoOverlay` (título, corpo, fechar) |
| `gui/EasyRomsToOPL.GUI.ps1` | `Show-GameInfo` (local + busca em segundo plano) |
| `data/games.json` | catálogo local (versionado, começa vazio) |
| `data/games.cache.json` | cache de buscas online (local, fora do git) |
| `data/igdb.json` | credenciais IGDB (local, fora do git) |

A busca online roda em **segundo plano** (runspace separado): a janela não
congela. Enquanto busca, o cabeçalho da ficha mostra `BUSCANDO...`; ao terminar,
vira `PRONTO` (achou) ou `SEM FICHA` (não achou).
