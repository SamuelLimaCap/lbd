-- lbd: fonte de autocomplete (blink.cmp) baseada SÓ no schema/database atual da conexão ativa.
--   * tabelas/views do schema atual (Oracle: CURRENT_SCHEMA da sessão; Postgres: current_schema() do database)
--   * colunas das tabelas citadas no FROM/JOIN da query sob o cursor
--   * depois de "alias." ou "tabela." -> só as colunas daquela tabela
-- Tudo é carregado de forma assíncrona e guardado em cache por conexão + escopo (trocado pelo <leader>ds).
local sql = require("lbd.sql")

local M = {}

-- conn_id -> nome do schema/database escolhido no seletor ("padrao" = o da URL/login)
local escopos = {}
-- chave -> { pronto = bool, itens = {...}, esperando = { cb, ... } }
local cache = {}

local function escopo(conn_id)
  return escopos[conn_id] or "padrao"
end

function M.definir_escopo(conn_id, nome)
  escopos[conn_id] = nome
  M.precarregar()
end

-- Database (PG) / schema (Oracle) escolhido no seletor, ou nil se ainda não trocou
function M.escopo_atual(conn_id)
  return escopos[conn_id]
end

---Limpa o cache (todas as conexões, ou só uma)
function M.limpar(conn_id)
  for chave in pairs(cache) do
    if not conn_id or vim.startswith(chave, conn_id .. "|") then
      cache[chave] = nil
    end
  end
end

local function esc(s)
  return (s:gsub("'", "''"))
end

-- Oracle: owner explícito do schema escolhido no seletor. Não dá pra confiar no CURRENT_SCHEMA da sessão:
-- o dbee usa um pool de conexões e consultas em paralelo abrem sessões novas (sem o ALTER SESSION).
local function owner_oracle(conn_id)
  local nome = escopos[conn_id]
  return nome and ("'" .. esc(nome) .. "'") or "sys_context('USERENV','CURRENT_SCHEMA')"
end

local function sql_tabelas(tipo, conn_id)
  if tipo == "oracle" then
    local owner = owner_oracle(conn_id)
    return ([[select table_name, 'tabela' from all_tables where owner = %s
union all
select view_name, 'view' from all_views where owner = %s]]):format(owner, owner)
  end
  return [[select table_name, case table_type when 'VIEW' then 'view' else 'tabela' end
from information_schema.tables where table_schema = current_schema()]]
end

local function sql_colunas(tipo, conn_id, schema, tabela, citado)
  if tipo == "oracle" then
    local owner = schema and ("'" .. esc(schema:upper()) .. "'") or owner_oracle(conn_id)
    local nome = citado and tabela or tabela:upper()
    return ("select column_name, data_type from all_tab_columns where owner = %s and table_name = '%s' order by column_id")
      :format(owner, esc(nome))
  end
  local onde = schema and ("table_schema = '" .. esc(schema) .. "'") or "table_schema = current_schema()"
  local nome = citado and ("table_name = '" .. esc(tabela) .. "'") or ("lower(table_name) = lower('" .. esc(tabela) .. "')")
  return ("select column_name, data_type from information_schema.columns where %s and %s order by ordinal_position")
    :format(onde, nome)
end

-- Carrega (uma vez) e entrega via cb(itens). Chamadas concorrentes esperam a mesma carga.
local function carregar(chave, conn_id, query, montar, cb)
  local entrada = cache[chave]
  if entrada and entrada.pronto then
    return cb(entrada.itens)
  end
  if entrada then
    table.insert(entrada.esperando, cb)
    return
  end
  entrada = { pronto = false, itens = {}, esperando = { cb } }
  cache[chave] = entrada
  sql.executar_async(conn_id, query, function(_, linhas, erro)
    if erro then
      cache[chave] = nil -- tenta de novo na próxima vez
      vim.notify("lbd autocomplete: " .. tostring(erro), vim.log.levels.WARN)
    else
      entrada.itens = montar(linhas or {})
      entrada.pronto = true
    end
    for _, fn in ipairs(entrada.esperando) do
      fn(entrada.itens)
    end
    entrada.esperando = {}
  end)
end

local function kinds()
  return require("blink.cmp.types").CompletionItemKind
end

local function tabelas(conn, cb)
  local k = kinds()
  carregar(conn.id .. "|" .. escopo(conn.id) .. "|tabelas", conn.id, sql_tabelas(conn.type, conn.id), function(linhas)
    local itens = {}
    for _, l in ipairs(linhas) do
      table.insert(itens, {
        label = l[1],
        insertText = l[1],
        kind = l[2] == "view" and k.Interface or k.Struct,
        labelDetails = { description = l[2] .. " · " .. escopo(conn.id) },
      })
    end
    return itens
  end, cb)
end

local function colunas(conn, ref, cb)
  local k = kinds()
  local chave = ("%s|%s|col|%s.%s"):format(conn.id, escopo(conn.id), ref.schema or "", ref.tabela:lower())
  carregar(chave, conn.id, sql_colunas(conn.type, conn.id, ref.schema, ref.tabela, ref.citado), function(linhas)
    local itens = {}
    for _, l in ipairs(linhas) do
      table.insert(itens, {
        label = l[1],
        insertText = l[1],
        kind = k.Field,
        labelDetails = { description = (l[2] or ""):lower() .. " · " .. ref.tabela },
      })
    end
    return itens
  end, cb)
end

-- Texto da query sob o cursor (bloco entre linhas em branco, igual ao <CR> do editor do dbee)
function M.query_atual(bufnr, linha)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local ini, fim = linha, linha
  while ini > 1 and vim.trim(vim.api.nvim_buf_get_lines(bufnr, ini - 2, ini - 1, false)[1] or "") ~= "" do
    ini = ini - 1
  end
  while fim < total and vim.trim(vim.api.nvim_buf_get_lines(bufnr, fim, fim + 1, false)[1] or "") ~= "" do
    fim = fim + 1
  end
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, ini - 1, fim, false), "\n")
end

local PARADA = {}
for _, w in ipairs({
  "where", "group", "order", "having", "on", "using", "join", "inner", "left", "right", "full", "outer",
  "cross", "union", "limit", "fetch", "connect", "start", "select", "and", "or", "set", "values", "natural",
  "lateral", "minus", "intersect", "except", "offset", "for", "window", "returning",
}) do
  PARADA[w] = true
end

-- Tabelas citadas em FROM/JOIN/UPDATE/INTO: retorna { [alias_ou_nome_minúsculo] = { schema, tabela, citado } }
function M.referencias(texto)
  texto = texto:gsub("%-%-[^\n]*", " "):gsub("/%*.-%*/", " ")
  -- protege espaços dentro de "nomes citados" antes de quebrar em palavras
  texto = texto:gsub('"[^"]*"', function(q)
    return (q:gsub("%s", "\1"))
  end)
  texto = texto:gsub("[();]", " "):gsub(",", " , ")
  local tk = vim.split(vim.trim(texto), "%s+")
  local refs = {}
  local function registrar(nome, alias)
    local citado = nome:find('"', 1, true) ~= nil
    nome = nome:gsub('"', ""):gsub("\1", " ")
    local schema, tabela = nome:match("^([^%.]+)%.([^%.]+)$")
    local ref = { schema = schema, tabela = tabela or nome, citado = citado }
    refs[ref.tabela:lower()] = ref
    if alias then
      refs[alias:lower()] = ref
    end
  end
  local i = 1
  while i <= #tk do
    local w = tk[i]:lower()
    if w == "from" or w == "join" or w == "update" or w == "into" then
      local j = i + 1
      while j <= #tk and tk[j] ~= "," and not PARADA[tk[j]:lower()] do
        local nome, alias, k = tk[j], nil, j + 1
        if tk[k] and tk[k]:lower() == "as" then
          k = k + 1
        end
        if tk[k] and tk[k] ~= "," and not PARADA[tk[k]:lower()] then
          alias = tk[k]
          k = k + 1
        end
        if nome:match("^[%w_$#%.\"\1]+$") then
          registrar(nome, alias)
        end
        j = k
        if tk[j] == "," then
          j = j + 1
        else
          break
        end
      end
      i = math.max(j, i + 1)
    else
      i = i + 1
    end
  end
  return refs
end

---------------------------------------------------------------------------
-- Fonte do blink.cmp
---------------------------------------------------------------------------
local Fonte = {}

function M.new()
  return setmetatable({}, { __index = Fonte })
end

local function conexao_atual()
  if not package.loaded["dbee"] then
    return nil
  end
  local ok, conn = pcall(function()
    return require("dbee.api").core.get_current_connection()
  end)
  return ok and conn or nil
end

function Fonte:enabled()
  return conexao_atual() ~= nil
end

function Fonte:get_trigger_characters()
  return { "." }
end

function Fonte:get_completions(ctx, callback)
  local conn = conexao_atual()
  local vazio = { items = {}, is_incomplete_forward = false, is_incomplete_backward = false }
  if not conn then
    return callback(vazio)
  end

  local antes = ctx.line:sub(1, ctx.cursor[2])
  local qualificador = antes:match('([%w_$#"]+)%.[%w_$#]*$')
  local refs = M.referencias(M.query_atual(ctx.bufnr, ctx.cursor[1]))

  local function responder(itens)
    callback({ items = itens, is_incomplete_forward = false, is_incomplete_backward = false })
  end

  -- "alias." / "tabela." -> só as colunas daquela tabela
  if qualificador then
    local ref = refs[qualificador:gsub('"', ""):lower()] or { tabela = qualificador:gsub('"', ""), citado = qualificador:find('"') ~= nil }
    return colunas(conn, ref, responder)
  end

  -- Sem qualificador: tabelas do schema atual + colunas das tabelas citadas na query
  local unicas, vistos = {}, {}
  for _, ref in pairs(refs) do
    local id = (ref.schema or "") .. "." .. ref.tabela:lower()
    if not vistos[id] then
      vistos[id] = true
      table.insert(unicas, ref)
    end
  end

  local resultado, faltam = {}, #unicas + 1
  local function juntar(itens)
    vim.list_extend(resultado, itens)
    faltam = faltam - 1
    if faltam == 0 then
      responder(resultado)
    end
  end
  tabelas(conn, juntar)
  for _, ref in ipairs(unicas) do
    colunas(conn, ref, juntar)
  end
end

---------------------------------------------------------------------------
-- Integração: troca de database pela árvore do dbee também muda o escopo
---------------------------------------------------------------------------
-- Pré-carrega as tabelas do escopo atual em segundo plano (Oracle grande leva alguns segundos)
function M.precarregar()
  vim.schedule(function()
    local conn = conexao_atual()
    if conn then
      tabelas(conn, function() end)
    end
  end)
end

function M.setup()
  local core = require("dbee.api").core
  core.register_event_listener("database_selected", function(data)
    M.definir_escopo(data.conn_id, data.database_name)
  end)
  core.register_event_listener("current_connection_changed", function()
    M.precarregar()
  end)
  vim.api.nvim_create_user_command("BancoRecarregarAutocomplete", function()
    M.limpar()
    vim.notify("lbd: cache do autocomplete limpo (tabelas/colunas serão recarregadas)")
  end, { desc = "Limpa o cache de tabelas/colunas do autocomplete" })
end

return M
