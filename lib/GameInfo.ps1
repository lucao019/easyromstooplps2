# ===========================================================================
#  GameInfo — ficha do jogo (o que é, quando saiu, gênero, estúdio...)
#
#  Estratégia híbrida:
#    1) procura no catálogo local  (data/games.json, por serial ou nome)
#    2) se não achar, busca online (IGDB) — só se houver credenciais
#    3) guarda o que voltou em cache local (data/games.cache.json)
#
#  Nada aqui é obrigatório: sem internet e sem catálogo, a ficha volta vazia
#  e o app segue mostrando o que já sabe (serial, mídia, partes, CRC).
#
#  IGDB (https://api.igdb.com) exige um app registrado no Twitch:
#    https://dev.twitch.tv/console/apps  ->  Client ID + Client Secret
#  Guarde em data/igdb.json ou nas variáveis de ambiente IGDB_CLIENT_ID e
#  IGDB_CLIENT_SECRET. O token é só de leitura e fica em memória.
# ===========================================================================

$script:GameInfoCache = $null
$script:IgdbToken = $null
$script:IgdbTokenExpires = [datetime]::MinValue

function Get-GameInfoDataDir {
    $root = Split-Path -Parent $PSScriptRoot
    $dir = Join-Path $root 'data'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    return $dir
}

function Get-GameInfoCatalog {
    <#  Catálogo local: data/games.json  { "SLUS_209.46": { ... } }  #>
    if ($script:GameInfoCache) { return $script:GameInfoCache }

    $path = Join-Path (Get-GameInfoDataDir) 'games.json'
    $catalog = @{}
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $raw.PSObject.Properties) {
                $catalog[$prop.Name.ToUpperInvariant()] = $prop.Value
            }
        } catch { }
    }
    $script:GameInfoCache = $catalog
    return $catalog
}

function Get-CachedGameInfo {
    <#  O que já foi buscado online antes: data/games.cache.json  #>
    $path = Join-Path (Get-GameInfoDataDir) 'games.cache.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $out = @{}
        foreach ($prop in $raw.PSObject.Properties) { $out[$prop.Name.ToUpperInvariant()] = $prop.Value }
        return $out
    } catch { return @{} }
}

function Save-CachedGameInfo {
    param([hashtable]$Cache)
    try {
        $path = Join-Path (Get-GameInfoDataDir) 'games.cache.json'
        ($Cache | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8
    } catch { }
}

function Get-IgdbCredentials {
    $id = $env:IGDB_CLIENT_ID
    $secret = $env:IGDB_CLIENT_SECRET
    if (-not $id -or -not $secret) {
        $path = Join-Path (Get-GameInfoDataDir) 'igdb.json'
        if (Test-Path -LiteralPath $path) {
            try {
                $cfg = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not $id) { $id = $cfg.client_id }
                if (-not $secret) { $secret = $cfg.client_secret }
            } catch { }
        }
    }
    if (-not $id -or -not $secret) { return $null }
    return @{ Id = $id; Secret = $secret }
}

function Test-GameInfoOnline {
    <#  Há como buscar online? (credenciais presentes)  #>
    return [bool](Get-IgdbCredentials)
}

function Get-IgdbToken {
    if ($script:IgdbToken -and (Get-Date) -lt $script:IgdbTokenExpires) {
        return $script:IgdbToken
    }
    $cred = Get-IgdbCredentials
    if (-not $cred) { return $null }

    try {
        $url = 'https://id.twitch.tv/oauth2/token?client_id={0}&client_secret={1}&grant_type=client_credentials' -f `
            [uri]::EscapeDataString($cred.Id), [uri]::EscapeDataString($cred.Secret)
        $resp = Invoke-RestMethod -Method Post -Uri $url -TimeoutSec 12
        if (-not $resp.access_token) { return $null }
        $script:IgdbToken = $resp.access_token
        $ttl = if ($resp.expires_in) { [int]$resp.expires_in } else { 3600 }
        $script:IgdbTokenExpires = (Get-Date).AddSeconds([Math]::Max(60, $ttl - 60))
        return $script:IgdbToken
    } catch {
        return $null
    }
}

function Invoke-IgdbQuery {
    param([string]$Endpoint, [string]$Body)
    $token = Get-IgdbToken
    if (-not $token) { return $null }
    $cred = Get-IgdbCredentials
    try {
        return Invoke-RestMethod -Method Post -Uri "https://api.igdb.com/v4/$Endpoint" `
            -Headers @{ 'Client-ID' = $cred.Id; 'Authorization' = "Bearer $token" } `
            -ContentType 'text/plain' -Body $Body -TimeoutSec 12
    } catch {
        return $null
    }
}

function Format-IgdbGame {
    param($Row)
    if (-not $Row) { return $null }

    $info = [ordered]@{}
    if ($Row.name) { $info.Titulo = [string]$Row.name }
    if ($Row.summary) { $info.Sinopse = [string]$Row.summary }

    if ($Row.first_release_date) {
        try {
            $d = [datetimeoffset]::FromUnixTimeSeconds([long]$Row.first_release_date).LocalDateTime
            $info.Lancamento = $d.ToString('dd/MM/yyyy')
        } catch { }
    }

    if ($Row.genres) {
        $names = @($Row.genres | ForEach-Object { $_.name } | Where-Object { $_ })
        if ($names.Count) { $info.Genero = ($names -join ', ') }
    }

    foreach ($pair in @(
            @{ Key = 'developers'; Field = 'Desenvolvedora' }
            @{ Key = 'publishers'; Field = 'Publicadora' }
        )) {
        $col = $Row.($pair.Key)
        if ($col) {
            $names = @($col | ForEach-Object { $_.name } | Where-Object { $_ })
            if ($names.Count) { $info[$pair.Field] = ($names -join ', ') }
        }
    }

    if ($Row.rating) {
        # A IGDB devolve `rating` na escala 0-100. A ficha (e o catálogo local)
        # usam 0-10, então normalizamos para não exibir "9.5/100" ao usuário.
        try {
            $nota = [double]$Row.rating
            if ($nota -gt 10) { $nota = $nota / 10 }
            $info.Nota = ('{0:N1}/10' -f $nota)
        } catch { }
    }

    if ($Row.platforms) {
        $names = @($Row.platforms | ForEach-Object { $_.name } | Where-Object { $_ })
        if ($names.Count) { $info.Plataformas = ($names -join ', ') }
    }

    $info.Origem = 'IGDB'
    return [pscustomobject]$info
}

function Get-GameInfoOnline {
    <#  Busca por serial (PS2) e, se não achar, cai no nome.  #>
    param([string]$Serial, [string]$Nome)

    if (-not (Test-GameInfoOnline)) { return $null }

    $fields = 'name,summary,first_release_date,genres.name,developers.name,publishers.name,rating,platforms.name'

    if ($Serial) {
        # O IGDB guarda o serial PS2 em alternative_names ou no próprio nome às
        # vezes; a busca textual por serial costuma acertar.
        $esc = $Serial -replace '"', ''
        $rows = Invoke-IgdbQuery -Endpoint 'games' -Body "search `"$esc`"; fields $fields; limit 3;"
        $hit = @($rows) | Where-Object { $_.name } | Select-Object -First 1
        if ($hit) { return Format-IgdbGame $hit }
    }

    if ($Nome) {
        # limpa tags de região/versão do nome antes de buscar
        $clean = $Nome -replace '\(.*?\)', '' -replace '\[.*?\]', ''
        $clean = ($clean -replace '\s+', ' ').Trim()
        if ($clean) {
            $esc = $clean -replace '"', ''
            $rows = Invoke-IgdbQuery -Endpoint 'games' -Body "search `"$esc`"; fields $fields; limit 3;"
            $hit = @($rows) | Where-Object { $_.name } | Select-Object -First 1
            if ($hit) { return Format-IgdbGame $hit }
        }
    }

    return $null
}

function Get-GameInfo {
    <#
        Ficha do jogo — híbrido:
          1) catálogo local por serial, depois por nome
          2) cache de buscas anteriores
          3) online (IGDB), que alimenta o cache
        Devolve $null se não houver nada; o chamador decide o que mostrar.
    #>
    param(
        [string]$Serial,
        [string]$Nome,
        [switch]$Offline   # só local/cache, não vai na internet
    )

    $key = if ($Serial) { $Serial.ToUpperInvariant() } else { ($Nome -replace '\W', '').ToUpperInvariant() }
    if (-not $key) { return $null }

    # 1) catálogo local
    $catalog = Get-GameInfoCatalog
    if ($Serial -and $catalog.ContainsKey($Serial.ToUpperInvariant())) {
        return $catalog[$Serial.ToUpperInvariant()]
    }

    # 2) cache de buscas
    $cache = Get-CachedGameInfo
    if ($cache.ContainsKey($key)) {
        $cached = $cache[$key]
        if ($cached) { return $cached }
    }

    # 3) online
    if ($Offline) { return $null }
    $online = Get-GameInfoOnline -Serial $Serial -Nome $Nome
    if ($online) {
        $cache[$key] = $online
        Save-CachedGameInfo $cache
        return $online
    }

    return $null
}

function Format-GameInfoLines {
    <#  Transforma a ficha em linhas prontas para exibir (texto + cor).  #>
    param($Info)
    $lines = New-Object System.Collections.ArrayList
    if (-not $Info) { return $lines }

    function Add-Line([string]$Label, [string]$Value) {
        if ($Value) { [void]$lines.Add(@{ Label = $Label; Value = $Value }) }
    }

    Add-Line '🎮' $Info.Titulo
    Add-Line '📅' $(if ($Info.Lancamento) { 'Lançamento: ' + $Info.Lancamento })
    Add-Line '🏷️' $(if ($Info.Genero) { 'Gênero: ' + $Info.Genero })
    Add-Line '🏢' $(if ($Info.Desenvolvedora) { 'Desenvolvedora: ' + $Info.Desenvolvedora })
    Add-Line '📢' $(if ($Info.Publicadora) { 'Publicadora: ' + $Info.Publicadora })
    Add-Line '⭐' $(if ($Info.Nota) { 'Nota: ' + $Info.Nota })
    Add-Line '🖥️' $(if ($Info.Plataformas) { 'Plataformas: ' + $Info.Plataformas })
    Add-Line '📝' $Info.Sinopse
    Add-Line '🌐' $(if ($Info.Origem) { 'Fonte: ' + $Info.Origem })
    return $lines
}
