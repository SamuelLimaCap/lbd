-- lbd: colunas de uma tabela (Postgres ou Oracle, conforme a conexão ativa) + dica Java/Hibernate.
--   <leader>dc / :BancoColunas [tabela] -> escolhe a tabela (busca por nome) e abre a janela
--   Na janela: buffer normal (/ busca, v / V / <C-v> + y copiam), s ordena A→Z / Z→A / original,
--   yA copia tudo, yj copia o campo Java da linha, yJ copia todos os campos, t troca a tabela,
--   d mostra o CREATE da tabela e gt as triggers dela (lbd/fonte.lua).
local sql = require("lbd.sql")

local M = {}

local ns = vim.api.nvim_create_namespace("lbd_colunas")
local ORDENS = { "original", "asc", "desc" }
local NOME_ORDEM = { original = "ordem original", asc = "nome A→Z", desc = "nome Z→A" }

-- Estado da janela aberta
local J = { buf = nil, win = nil, tabela = nil, conn = nil, colunas = {}, ordem = "original", java_por_linha = {} }

local function esc(s)
  return (s:gsub("'", "''"))
end

local function conexao()
  local ok, conn = pcall(function()
    return require("dbee.api").core.get_current_connection()
  end)
  if not ok or not conn then
    vim.notify("Nenhuma conexão ativa! Abra o Dbee (<leader>D) e escolha uma.", vim.log.levels.WARN)
    return nil
  end
  if conn.type ~= "postgres" and conn.type ~= "oracle" then
    vim.notify("Colunas: conexão do tipo " .. conn.type .. " não suportada (só Postgres/Oracle).", vim.log.levels.WARN)
    return nil
  end
  return conn
end

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------
local function sql_tabelas(tipo)
  if tipo == "oracle" then
    return [[select table_name from all_tables where owner = sys_context('USERENV','CURRENT_SCHEMA')
union all
select view_name from all_views where owner = sys_context('USERENV','CURRENT_SCHEMA')
order by 1]]
  end
  return "select table_name from information_schema.tables where table_schema = current_schema() order by 1"
end

-- Colunas devolvidas (mesma ordem nos dois bancos):
-- 1 nome, 2 tipo, 3 tamanho (chars), 4 precisão, 5 escala, 6 nulo (S/N), 7 default, 8 pk (S/N), 9 comentário
local function sql_colunas(tipo, tabela, exato)
  if tipo == "oracle" then
    local filtro = exato and ("c.table_name = '%s'"):format(esc(tabela)) or ("c.table_name = upper('%s')"):format(esc(tabela))
    return ([[select c.column_name, c.data_type,
  case when c.char_length > 0 then c.char_length end,
  c.data_precision, c.data_scale,
  case c.nullable when 'Y' then 'S' else 'N' end,
  c.data_default,
  case when exists (select 1 from all_constraints k join all_cons_columns kc
                      on kc.owner = k.owner and kc.constraint_name = k.constraint_name
                     where k.constraint_type = 'P' and k.owner = c.owner and k.table_name = c.table_name
                       and kc.column_name = c.column_name) then 'S' else 'N' end,
  m.comments
from all_tab_columns c
left join all_col_comments m on m.owner = c.owner and m.table_name = c.table_name and m.column_name = c.column_name
where c.owner = sys_context('USERENV','CURRENT_SCHEMA') and %s
order by c.column_id]]):format(filtro)
  end
  local filtro = exato and ("c.table_name = '%s'"):format(esc(tabela)) or ("lower(c.table_name) = lower('%s')"):format(esc(tabela))
  return ([[select c.column_name,
  case when c.data_type in ('USER-DEFINED', 'ARRAY') then c.udt_name else c.data_type end,
  c.character_maximum_length, c.numeric_precision, c.numeric_scale,
  case c.is_nullable when 'YES' then 'S' else 'N' end,
  c.column_default,
  case when exists (select 1 from information_schema.table_constraints tc
                      join information_schema.key_column_usage k
                        on k.constraint_schema = tc.constraint_schema and k.constraint_name = tc.constraint_name
                     where tc.constraint_type = 'PRIMARY KEY' and tc.table_schema = c.table_schema
                       and tc.table_name = c.table_name and k.column_name = c.column_name) then 'S' else 'N' end,
  (select col_description(a.attrelid, a.attnum) from pg_attribute a
    where a.attrelid = (quote_ident(c.table_schema) || '.' || quote_ident(c.table_name))::regclass
      and a.attname = c.column_name)
from information_schema.columns c
where c.table_schema = current_schema() and %s
order by c.ordinal_position]]):format(filtro)
end

---------------------------------------------------------------------------
-- Tipo SQL legível e dica Java/Hibernate
---------------------------------------------------------------------------
local function num(v)
  return v and v ~= "" and tonumber(v) or nil
end

local function tipo_sql(c)
  local t = c.tipo
  if c.tamanho then
    return ("%s(%d)"):format(t, c.tamanho)
  end
  local tl = t:lower()
  if (tl == "number" or tl == "numeric") and c.precisao then
    return c.escala and c.escala > 0 and ("%s(%d,%d)"):format(t, c.precisao, c.escala) or ("%s(%d)"):format(t, c.precisao)
  end
  return t
end

local function maximo(c)
  local tl = c.tipo:lower()
  if c.tamanho then
    return c.tamanho .. " caracteres"
  end
  if tl == "number" or tl == "numeric" then
    if not c.precisao then
      return "sem limite"
    end
    local inteiros = c.precisao - (c.escala or 0)
    return ("%d dígitos (%d inteiros, %d decimais)"):format(c.precisao, inteiros, c.escala or 0)
  end
  local fixos = {
    smallint = "±32.767", integer = "±2.147.483.647", bigint = "±9,2 quintilhões",
    int2 = "±32.767", int4 = "±2.147.483.647", int8 = "±9,2 quintilhões",
    text = "sem limite (1 GB)", clob = "4 GB", nclob = "4 GB", blob = "4 GB", bytea = "1 GB",
    boolean = "true/false",
  }
  return fixos[tl] or ""
end

local function camel(nome)
  local s = nome:lower():gsub("_(%w)", function(c)
    return c:upper()
  end)
  return s
end

-- Retorna tipo Java, atributos extras do @Column, anotações extras
local function mapear_java(c, tipo_banco)
  local tl = c.tipo:lower()
  local p, s = c.precisao, c.escala or 0

  if tl:match("char") or tl == "text" or tl == "character varying" or tl == "bpchar" or tl == "citext" then
    return "String", c.tamanho and { "length = " .. c.tamanho } or {}, {}
  end
  if tl == "clob" or tl == "nclob" or tl == "long" then
    return "String", {}, { "@Lob" }
  end
  if tl == "blob" or tl:match("raw") then
    return "byte[]", {}, tl == "blob" and { "@Lob" } or {}
  end
  if tl == "bytea" then
    return "byte[]", {}, {}
  end
  if tl == "smallint" or tl == "int2" then
    return "Short", {}, {}
  end
  if tl == "integer" or tl == "int4" or tl == "int" then
    return "Integer", {}, {}
  end
  if tl == "bigint" or tl == "int8" then
    return "Long", {}, {}
  end
  if tl == "number" or tl == "numeric" or tl == "decimal" then
    if p and s == 0 then
      if p <= 9 then
        return "Integer", { "precision = " .. p }, {}
      elseif p <= 18 then
        return "Long", { "precision = " .. p }, {}
      end
      return "BigInteger", { "precision = " .. p }, {}
    end
    if p then
      return "BigDecimal", { "precision = " .. p, "scale = " .. s }, {}
    end
    return "BigDecimal", {}, {}
  end
  if tl == "real" or tl == "float4" or tl == "binary_float" then
    return "Float", {}, {}
  end
  if tl == "double precision" or tl == "float8" or tl == "float" or tl == "binary_double" then
    return "Double", {}, {}
  end
  if tl == "boolean" or tl == "bool" then
    return "Boolean", {}, {}
  end
  -- Datas: sempre java.util.Date
  if tl == "date" then
    -- DATE do Oracle guarda hora também; o do Postgres é só a data
    return "Date", {}, { tipo_banco == "oracle" and "@Temporal(TemporalType.TIMESTAMP)" or "@Temporal(TemporalType.DATE)" }
  end
  if tl:match("^timestamp") then
    return "Date", {}, { "@Temporal(TemporalType.TIMESTAMP)" }
  end
  if tl:match("^time") then
    return "Date", {}, { "@Temporal(TemporalType.TIME)" }
  end
  if tl == "uuid" then
    return "UUID", {}, {}
  end
  return "String", {}, { "// tipo " .. c.tipo .. ": confira o mapeamento" }
end

local function java_campo(c, tipo_banco)
  local tipo_java, attrs, anots = mapear_java(c, tipo_banco)
  local linhas = {}
  if c.comentario then
    table.insert(linhas, "/** " .. c.comentario:gsub("\r?\n", " ") .. " */")
  end
  if c.pk then
    table.insert(linhas, "@Id")
  end
  vim.list_extend(linhas, anots)
  local col = { ('name = "%s"'):format(c.nome) }
  vim.list_extend(col, attrs)
  if not c.nulo then
    table.insert(col, "nullable = false")
  end
  table.insert(linhas, "@Column(" .. table.concat(col, ", ") .. ")")
  local decl = ("private %s %s;"):format(tipo_java, camel(c.nome))
  if c.default then
    decl = decl .. " // default no banco: " .. c.default
  end
  table.insert(linhas, decl)
  return linhas, tipo_java
end

---------------------------------------------------------------------------
-- Janela
---------------------------------------------------------------------------
local function fechar()
  if J.win and vim.api.nvim_win_is_valid(J.win) then
    vim.api.nvim_win_close(J.win, true)
  end
  J.win = nil
end

local function ordenadas()
  local lista = vim.list_slice(J.colunas, 1, #J.colunas)
  if J.ordem ~= "original" then
    table.sort(lista, function(a, b)
      if J.ordem == "asc" then
        return a.nome:lower() < b.nome:lower()
      end
      return a.nome:lower() > b.nome:lower()
    end)
  end
  return lista
end

local function alinhar(linhas)
  local larg = {}
  for _, l in ipairs(linhas) do
    for i, v in ipairs(l) do
      larg[i] = math.max(larg[i] or 0, vim.fn.strdisplaywidth(v))
    end
  end
  local saida = {}
  for _, l in ipairs(linhas) do
    local partes = {}
    for i, v in ipairs(l) do
      partes[i] = i < #l and (v .. string.rep(" ", larg[i] - vim.fn.strdisplaywidth(v))) or v
    end
    table.insert(saida, (table.concat(partes, " │ "):gsub("%s+$", "")))
  end
  return saida
end

local function desenhar()
  local tipo_banco = J.conn.type
  local cab = { "Coluna", "Tipo", "Máximo", "Nulo", "Default", "PK", "Java", "Comentário" }
  local linhas = { cab }
  local java_todos = {}
  J.java_por_linha = {}
  for _, c in ipairs(ordenadas()) do
    local campo, tipo_java = java_campo(c, tipo_banco)
    table.insert(linhas, {
      c.nome,
      tipo_sql(c),
      maximo(c),
      c.nulo and "S" or "N",
      c.default and c.default:gsub("\r?\n", " ") or "",
      c.pk and "PK" or "",
      tipo_java,
      c.comentario and c.comentario:gsub("\r?\n", " ") or "",
    })
    table.insert(java_todos, campo)
  end

  local texto = alinhar(linhas)
  local separador = {}
  for _, ch in ipairs(vim.fn.split(texto[1], "\\zs")) do
    table.insert(separador, ch == "│" and "┼" or "─")
  end
  separador = table.concat(separador)
  table.insert(texto, 2, separador)
  -- linha do buffer -> campo Java
  for i, campo in ipairs(java_todos) do
    J.java_por_linha[i + 2] = campo
  end

  table.insert(texto, "")
  table.insert(texto, "── Java / Hibernate ──")
  local inicio_java = #texto
  for i, campo in ipairs(java_todos) do
    if i > 1 then
      table.insert(texto, "")
    end
    for _, l in ipairs(campo) do
      table.insert(texto, l)
      J.java_por_linha[#texto] = campo
    end
  end

  vim.bo[J.buf].modifiable = true
  vim.api.nvim_buf_set_lines(J.buf, 0, -1, false, texto)
  vim.bo[J.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(J.buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(J.buf, ns, 0, 0, { end_col = #texto[1], hl_group = "Title" })
  vim.api.nvim_buf_set_extmark(J.buf, ns, 1, 0, { end_col = #texto[2], hl_group = "Comment" })
  vim.api.nvim_buf_set_extmark(J.buf, ns, inicio_java - 1, 0, { end_col = #texto[inicio_java], hl_group = "Title" })
  for i = 3, 2 + #java_todos do
    local l = texto[i]
    local fim = l:find(" │", 1, true) or #l + 1
    vim.api.nvim_buf_set_extmark(J.buf, ns, i - 1, 0, { end_col = fim - 1, hl_group = "Identifier" })
  end

  local w = math.floor(vim.o.columns * 0.9)
  local h = math.floor(vim.o.lines * 0.8)
  local cfg = {
    relative = "editor",
    width = w,
    height = h,
    row = math.floor((vim.o.lines - h) / 2) - 1,
    col = math.floor((vim.o.columns - w) / 2),
    border = "rounded",
    title = (" %s · %d colunas · %s · %s "):format(J.tabela, #J.colunas, NOME_ORDEM[J.ordem], J.conn.name),
    title_pos = "center",
    footer = " / buscar · s ordenar · yA copiar tudo · yj/yJ Java · d CREATE · gt triggers · t trocar · q fechar · ? ajuda ",
    footer_pos = "center",
  }
  if J.win and vim.api.nvim_win_is_valid(J.win) then
    vim.api.nvim_win_set_config(J.win, cfg)
  else
    J.win = vim.api.nvim_open_win(J.buf, true, cfg)
    vim.wo[J.win].wrap = false
    vim.wo[J.win].cursorline = true
    vim.wo[J.win].number = false
    vim.wo[J.win].relativenumber = false
  end
end

local function copiar(texto, msg)
  vim.fn.setreg("+", texto)
  vim.fn.setreg('"', texto)
  vim.notify(msg)
end

local function criar_buffer()
  if J.buf and vim.api.nvim_buf_is_valid(J.buf) then
    return
  end
  J.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[J.buf].bufhidden = "hide"
  vim.bo[J.buf].filetype = "lbdcolunas"
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = J.buf, nowait = true, silent = true, desc = desc })
  end
  map("s", function()
    local i = 1
    for k, o in ipairs(ORDENS) do
      if o == J.ordem then
        i = k
      end
    end
    J.ordem = ORDENS[i % #ORDENS + 1]
    desenhar()
    vim.api.nvim_win_set_cursor(J.win, { 1, 0 })
  end, "Colunas: ordem original / A→Z / Z→A")
  map("yA", function()
    copiar(table.concat(vim.api.nvim_buf_get_lines(J.buf, 0, -1, false), "\n"), "Tudo copiado.")
  end, "Colunas: copiar tudo")
  map("yj", function()
    local campo = J.java_por_linha[vim.api.nvim_win_get_cursor(0)[1]]
    if not campo then
      return vim.notify("Cursor não está numa coluna.", vim.log.levels.WARN)
    end
    copiar(table.concat(campo, "\n"), "Campo Java copiado.")
  end, "Colunas: copiar o campo Java da linha")
  map("yJ", function()
    local blocos = {}
    for _, c in ipairs(ordenadas()) do
      table.insert(blocos, table.concat((java_campo(c, J.conn.type)), "\n"))
    end
    copiar(table.concat(blocos, "\n\n"), "Todos os campos Java copiados.")
  end, "Colunas: copiar todos os campos Java")
  map("d", function()
    local tabela = J.tabela
    fechar()
    require("lbd.fonte").tabela(tabela)
  end, "Colunas: CREATE da tabela")
  map("gt", function()
    require("lbd.fonte").listar("trigger", J.tabela)
  end, "Colunas: triggers da tabela")
  map("t", function()
    fechar()
    M.abrir()
  end, "Colunas: trocar de tabela")
  map("q", fechar, "Colunas: fechar")
  map("<Esc>", fechar, "Colunas: fechar")
  map("?", function() require("lbd.ajuda").mostrar({ "colunas" }) end, "Colunas: ajuda")
end

local function mostrar(conn, tabela, exato)
  vim.notify("Carregando colunas de " .. tabela .. "...")
  sql.executar_async(conn.id, sql_colunas(conn.type, tabela, exato), function(_, linhas, erro)
    if erro then
      return vim.notify("Colunas: " .. tostring(erro), vim.log.levels.ERROR)
    end
    if not linhas or #linhas == 0 then
      return vim.notify(("Tabela '%s' não encontrada no schema atual."):format(tabela), vim.log.levels.WARN)
    end
    local cols = {}
    for _, l in ipairs(linhas) do
      local default = l[7] and vim.trim(l[7]) or ""
      table.insert(cols, {
        nome = l[1],
        tipo = l[2] or "",
        tamanho = num(l[3]),
        precisao = num(l[4]),
        escala = num(l[5]),
        nulo = l[6] == "S",
        default = default ~= "" and default or nil,
        pk = l[8] == "S",
        comentario = l[9] ~= "" and l[9] or nil,
      })
    end
    criar_buffer()
    J.conn, J.tabela, J.colunas, J.ordem = conn, tabela, cols, "original"
    desenhar()
    vim.api.nvim_win_set_cursor(J.win, { 1, 0 })
  end)
end

---Abre a janela de colunas. Sem tabela: lista as do schema atual para buscar e escolher.
---@param tabela? string
function M.abrir(tabela)
  local conn = conexao()
  if not conn then
    return
  end
  if tabela and tabela ~= "" then
    return mostrar(conn, tabela, false)
  end
  sql.executar_async(conn.id, sql_tabelas(conn.type), function(_, linhas, erro)
    if erro then
      return vim.notify("Colunas: " .. tostring(erro), vim.log.levels.ERROR)
    end
    local nomes = {}
    for _, l in ipairs(linhas or {}) do
      table.insert(nomes, l[1])
    end
    if #nomes == 0 then
      return vim.notify("Nenhuma tabela no schema/database atual.", vim.log.levels.WARN)
    end
    vim.ui.select(nomes, { prompt = ("Tabela [%s]"):format(conn.name) }, function(escolhida)
      if escolhida then
        mostrar(conn, escolhida, true)
      end
    end)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("BancoColunas", function(opts)
    M.abrir(opts.args)
  end, { nargs = "?", desc = "Colunas da tabela (tipo, máximo, default, PK) + dica Java/Hibernate" })
end

return M
