-- lbd: código dos objetos do banco e CREATE de tabela, numa janela flutuante (Postgres e Oracle).
--   <leader>do / :BancoFonte [nome]      -> procedures, functions, packages, types e views (busca e abre)
--   <leader>dt / :BancoTriggers [tabela] -> triggers do schema/database atual (ou só as da tabela)
--   <leader>dO                           -> objeto sob o cursor (aceita SCHEMA.OBJ e PACOTE.PROC)
--   <leader>dd / :BancoCreate [tabela]   -> CREATE da tabela (constraints, índices e comentários)
--   Na janela: / busca, yA copia tudo, r recarrega, t troca, c clona (tabela, sem dados),
--   T tipos das colunas, gt triggers da tabela, q fecha, ? ajuda. Só lê o banco: nada é gravado.
-- Oracle: código de ALL_SOURCE (erros de compilação viram diagnósticos nas linhas), views e tabelas
--   por DBMS_METADATA sem as cláusulas de storage. Postgres: pg_get_functiondef/viewdef/triggerdef,
--   e o CREATE TABLE é montado pelo catálogo (o Postgres não tem função pronta para isso).
local sql = require("lbd.sql")

local M = {}

local ns = vim.api.nvim_create_namespace("lbd_fonte")

-- Janela aberta: conn, obj, modo (lista do "t"), atual (conteúdo mostrado), base (o original, p/ clonar)
local J = { buf = nil, win = nil }

local TIPOS = {
  codigo = {
    oracle = { "PROCEDURE", "FUNCTION", "PACKAGE", "TYPE", "VIEW", "MATERIALIZED VIEW" },
    postgres = { "FUNCTION", "PROCEDURE", "VIEW", "MATERIALIZED VIEW" },
  },
  trigger = { oracle = { "TRIGGER" }, postgres = { "TRIGGER" } },
  tabela = { oracle = { "TABLE" }, postgres = { "TABLE" } },
}

local NOME_MODO = { codigo = "Código", trigger = "Trigger", tabela = "Tabela (CREATE)" }
local VAZIO =
  { codigo = "Nenhuma procedure, function, package ou view", trigger = "Nenhuma trigger", tabela = "Nenhuma tabela" }

local TRANSFORMAR = [[begin
  dbms_metadata.set_transform_param(dbms_metadata.session_transform, 'SEGMENT_ATTRIBUTES', false);
  dbms_metadata.set_transform_param(dbms_metadata.session_transform, 'SQLTERMINATOR', true);
end;;]] -- o driver Oracle do dbee corta um ";" do fim; o bloco precisa do "end;"

-- Executa e lê o resultado; o dbee devolve NULL como o texto "<nil>": aqui vira ""
local function executar(conn, q, cb)
  sql.executar_async(conn.id, q, function(cab, linhas, erro)
    for _, l in ipairs(linhas or {}) do
      for i, v in ipairs(l) do
        if v == "<nil>" then
          l[i] = ""
        end
      end
    end
    cb(cab, linhas, erro)
  end)
end

local function esc(s)
  return (s:gsub("'", "''"))
end

local function lista_in(tipos)
  local t = {}
  for _, v in ipairs(tipos) do
    table.insert(t, "'" .. v .. "'")
  end
  return table.concat(t, ", ")
end

local function todos(banco)
  local t = {}
  for _, modo in ipairs({ "codigo", "trigger", "tabela" }) do
    vim.list_extend(t, TIPOS[modo][banco])
  end
  return t
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
    vim.notify("Conexão do tipo " .. conn.type .. " não suportada (só Postgres/Oracle).", vim.log.levels.WARN)
    return nil
  end
  return conn
end

-- Quebra um texto em linhas, sem espaços no fim nem linhas vazias nas pontas
local function linhas_de(texto)
  local t = vim.split(((texto or ""):gsub("\r\n", "\n")), "\n", { plain = true })
  for i, l in ipairs(t) do
    t[i] = l:gsub("%s+$", "")
  end
  while #t > 0 and t[1] == "" do
    table.remove(t, 1)
  end
  while #t > 0 and t[#t] == "" do
    table.remove(t)
  end
  return t
end

-- DBMS_METADATA: tira o recuo de 2 espaços dos comandos e junta o ";" que vem sozinho na linha
local function arrumar_ddl(linhas)
  local saida = {}
  for _, l in ipairs(linhas) do
    if l:match("^%s*;$") and #saida > 0 then
      saida[#saida] = saida[#saida]:gsub("%s+$", "") .. ";"
    elseif l:match("^%s+CREATE%s") or l:match("^%s+COMMENT%s") or l:match("^%s+ALTER%s") then
      table.insert(saida, (l:gsub("^%s+", "")))
    else
      table.insert(saida, l)
    end
  end
  return saida
end

local function com_ponto_virgula(texto)
  texto = vim.trim(texto or "")
  return texto:match(";$") and texto or (texto .. ";")
end

-- Substitui `velho` por `novo` sem interpretar padrões Lua (nomes têm $, #, %...)
local function trocar(s, velho, novo)
  local saida, ini, n = {}, 1, 0
  while true do
    local i, f = s:find(velho, ini, true)
    if not i then
      break
    end
    table.insert(saida, s:sub(ini, i - 1))
    table.insert(saida, novo)
    ini, n = f + 1, n + 1
  end
  table.insert(saida, s:sub(ini))
  return table.concat(saida), n
end

---------------------------------------------------------------------------
-- Lista de objetos (colunas: tipo, id, esquema, nome, extra, status)
---------------------------------------------------------------------------
---@param f { tipos: string[], schema?: string, nome?: string, tabela?: string }
local function sql_lista(banco, f)
  if banco == "oracle" then
    local w = { "o.object_type in (" .. lista_in(f.tipos) .. ")" }
    if f.schema then
      table.insert(w, ("(o.owner = '%s' or o.owner = upper('%s'))"):format(esc(f.schema), esc(f.schema)))
    else
      table.insert(w, "o.owner = sys_context('USERENV','CURRENT_SCHEMA')")
    end
    if f.nome then
      table.insert(w, ("(o.object_name = '%s' or o.object_name = upper('%s'))"):format(esc(f.nome), esc(f.nome)))
    end
    if f.tabela then
      table.insert(
        w,
        ([[exists (select 1 from all_triggers t where t.owner = o.owner and t.trigger_name = o.object_name
     and (t.table_name = '%s' or t.table_name = upper('%s')))]]):format(esc(f.tabela), esc(f.tabela))
      )
    end
    return ([[select o.object_type, o.owner || '.' || o.object_name, o.owner, o.object_name,
  case when o.object_type = 'TRIGGER' then
    (select '  on ' || t.table_name from all_triggers t where t.owner = o.owner and t.trigger_name = o.object_name)
  end,
  o.status
from all_objects o
where %s
order by 1, 4]]):format(table.concat(w, "\n  and "))
  end

  local w = { "o.tipo in (" .. lista_in(f.tipos) .. ")" }
  if f.schema then
    table.insert(w, ("(o.esquema = '%s' or o.esquema = lower('%s'))"):format(esc(f.schema), esc(f.schema)))
  else
    table.insert(w, "o.esquema = current_schema()")
  end
  if f.nome then
    table.insert(w, ("(o.nome = '%s' or o.nome = lower('%s'))"):format(esc(f.nome), esc(f.nome)))
  end
  if f.tabela then
    table.insert(w, ("(o.tabela = '%s' or o.tabela = lower('%s'))"):format(esc(f.tabela), esc(f.tabela)))
  end
  return ([[select tipo, id, esquema, nome, extra, '' from (
  select case p.prokind when 'p' then 'PROCEDURE' else 'FUNCTION' end as tipo, p.oid::text as id,
         n.nspname as esquema, p.proname as nome,
         '(' || pg_get_function_identity_arguments(p.oid) || ')' as extra, null::text as tabela
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where p.prokind in ('f', 'p')
    and not exists (select 1 from pg_depend d
                     where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
  union all
  select 'TRIGGER', t.oid::text, n.nspname, t.tgname, '  on ' || c.relname, c.relname
  from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
  where not t.tgisinternal
  union all
  select case c.relkind when 'v' then 'VIEW' when 'm' then 'MATERIALIZED VIEW' else 'TABLE' end,
         c.oid::text, n.nspname, c.relname, '', c.relname
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where c.relkind in ('r', 'p', 'v', 'm') and not c.relispartition
) o
where %s
order by 1, 4, 5]]):format(table.concat(w, "\n  and "))
end

local function buscar(conn, f, cb)
  executar(conn, sql_lista(conn.type, f), function(_, linhas, erro)
    if erro then
      return cb(erro)
    end
    local objs = {}
    for _, l in ipairs(linhas or {}) do
      table.insert(
        objs,
        { tipo = l[1], id = l[2], esquema = l[3], nome = l[4], extra = l[5] or "", status = l[6] or "" }
      )
    end
    cb(nil, objs)
  end)
end

local function rotulo(o)
  local s = ("%-17s %s%s"):format(o.tipo, o.nome, o.extra)
  if o.status == "INVALID" then
    s = s .. "  ⚠ INVALID"
  end
  return s
end

---------------------------------------------------------------------------
-- Execução em sequência (cada passo: { q, bloco = PL/SQL sem resultado, opcional = erro não aborta })
---------------------------------------------------------------------------
local function em_ordem(conn, passos, cb)
  local res = {}
  local function prox(i)
    if i > #passos then
      return cb(nil, res)
    end
    local p = passos[i]
    if p.bloco then
      return sql.chamar(conn.id, p.q, function(call)
        if call.state ~= "archived" and not p.opcional then
          return cb(call.error or call.state)
        end
        prox(i + 1)
      end)
    end
    executar(conn, p.q, function(_, linhas, erro)
      if erro and not p.opcional then
        return cb(erro)
      end
      res[i] = linhas or {}
      prox(i + 1)
    end)
  end
  prox(1)
end

---------------------------------------------------------------------------
-- Código (procedure, function, package, type, trigger, view)
-- Devolve { linhas, diags?, corpo? (1ª linha do BODY), erros? }
---------------------------------------------------------------------------
local PARTES_ORACLE = { PACKAGE = { "PACKAGE", "PACKAGE BODY" }, TYPE = { "TYPE", "TYPE BODY" } }
local DDL_ORACLE = { VIEW = "VIEW", ["MATERIALIZED VIEW"] = "MATERIALIZED_VIEW" }

local function codigo_oracle(conn, obj, cb)
  local dono, nome = esc(obj.esquema), esc(obj.nome)
  if DDL_ORACLE[obj.tipo] then
    return em_ordem(conn, {
      { q = TRANSFORMAR, bloco = true, opcional = true },
      { q = ("select dbms_metadata.get_ddl('%s', '%s', '%s') from dual"):format(DDL_ORACLE[obj.tipo], nome, dono) },
    }, function(erro, res)
      if erro then
        return cb(erro)
      end
      cb(nil, { linhas = arrumar_ddl(linhas_de(res[2][1] and res[2][1][1])) })
    end)
  end

  local partes = PARTES_ORACLE[obj.tipo] or { obj.tipo }
  em_ordem(conn, {
    {
      q = ([[select type, text from all_source where owner = '%s' and name = '%s' and type in (%s)
order by case when type like '%% BODY' then 2 else 1 end, line]]):format(dono, nome, lista_in(partes)),
    },
    {
      q = ([[select type, line, position, attribute, text from all_errors
where owner = '%s' and name = '%s' order by sequence]]):format(dono, nome),
      opcional = true,
    },
  }, function(erro, res)
    if erro then
      return cb(erro)
    end
    local linhas, inicio, ultimo = {}, {}, nil
    for _, r in ipairs(res[1]) do
      local tipo, texto = r[1], (r[2] or ""):gsub("\r?\n$", "")
      if tipo ~= ultimo then
        if ultimo then
          table.insert(linhas, "/")
          table.insert(linhas, "")
        end
        inicio[tipo] = #linhas -- 0-based: linha da tela onde a linha 1 do fonte cai
        texto = "CREATE OR REPLACE " .. texto
        ultimo = tipo
      end
      table.insert(linhas, (texto:gsub("%s+$", "")))
    end
    if #linhas == 0 then
      return cb(("Sem código-fonte visível para %s.%s (falta permissão?)"):format(obj.esquema, obj.nome))
    end
    table.insert(linhas, "/")

    local diags, erros = {}, 0
    for _, e in ipairs(res[2] or {}) do
      local base = inicio[e[1]]
      if base then
        local grave = e[4] ~= "WARNING"
        erros = erros + (grave and 1 or 0)
        table.insert(diags, {
          lnum = math.min(base + (tonumber(e[2]) or 1) - 1, #linhas - 1),
          col = math.max((tonumber(e[3]) or 1) - 1, 0),
          message = vim.trim(e[5] or ""),
          severity = grave and vim.diagnostic.severity.ERROR or vim.diagnostic.severity.WARN,
          source = "oracle",
        })
      end
    end
    local corpo = partes[2] and inicio[partes[2]]
    cb(nil, { linhas = linhas, diags = diags, erros = erros, corpo = corpo and (corpo + 1) })
  end)
end

local function codigo_postgres(conn, obj, cb)
  local id = tonumber(obj.id)
  local q
  if obj.tipo == "TRIGGER" then
    q = ("select pg_get_triggerdef(t.oid, true), pg_get_functiondef(t.tgfoid) from pg_trigger t where t.oid = %d"):format(
      id
    )
  elseif obj.tipo == "VIEW" or obj.tipo == "MATERIALIZED VIEW" then
    q = ([[select quote_ident(n.nspname) || '.' || quote_ident(c.relname), pg_get_viewdef(c.oid, true)
from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = %d]]):format(id)
  else
    q = ("select pg_get_functiondef(%d)"):format(id)
  end
  executar(conn, q, function(_, res, erro)
    if erro then
      return cb(erro)
    end
    local r = res and res[1]
    if not r then
      return cb(("%s %s não existe mais (r na lista recarrega)."):format(obj.tipo, obj.nome))
    end
    local linhas
    if obj.tipo == "TRIGGER" then
      linhas = linhas_de(com_ponto_virgula(r[1]))
      table.insert(linhas, "")
      table.insert(linhas, "-- função chamada pela trigger:")
      vim.list_extend(linhas, linhas_de(com_ponto_virgula(r[2])))
    elseif obj.tipo == "VIEW" or obj.tipo == "MATERIALIZED VIEW" then
      local cab = obj.tipo == "VIEW" and "CREATE OR REPLACE VIEW " or "CREATE MATERIALIZED VIEW "
      linhas = { cab .. r[1] .. " AS" }
      vim.list_extend(linhas, linhas_de(com_ponto_virgula(r[2])))
    else
      linhas = linhas_de(com_ponto_virgula(r[1]))
    end
    cb(nil, { linhas = linhas })
  end)
end

---------------------------------------------------------------------------
-- CREATE TABLE (+ clone com outro nome)
-- Devolve { linhas, clonar = function(novo) -> linhas }
---------------------------------------------------------------------------
local function triggers_comentario(nomes)
  if #nomes == 0 then
    return {}
  end
  return { "", "-- triggers desta tabela (não entram no clone; gt lista e abre): " .. table.concat(nomes, ", ") }
end

local function tabela_oracle(conn, obj, cb)
  local dono, nome = esc(obj.esquema), esc(obj.nome)
  em_ordem(conn, {
    { q = TRANSFORMAR, bloco = true, opcional = true },
    { q = ("select dbms_metadata.get_ddl('TABLE', '%s', '%s') from dual"):format(nome, dono) },
    -- índices que não são de PK/UNIQUE (esses já saem no CREATE TABLE)
    {
      q = ([[select dbms_metadata.get_ddl('INDEX', i.index_name, i.owner) from all_indexes i
where i.table_owner = '%s' and i.table_name = '%s' and i.index_type not like 'LOB%%'
  and not exists (select 1 from all_constraints c
                   where c.owner = i.table_owner and c.table_name = i.table_name and c.index_name = i.index_name)
order by i.index_name]]):format(dono, nome),
      opcional = true,
    },
    {
      q = ([[select dbms_metadata.get_dependent_ddl('COMMENT', '%s', '%s') from dual
where exists (select 1 from all_tab_comments where owner = '%s' and table_name = '%s' and comments is not null)
   or exists (select 1 from all_col_comments where owner = '%s' and table_name = '%s' and comments is not null)]]):format(
        nome,
        dono,
        dono,
        nome,
        dono,
        nome
      ),
      opcional = true,
    },
    {
      q = ("select trigger_name from all_triggers where table_owner = '%s' and table_name = '%s' order by 1"):format(
        dono,
        nome
      ),
      opcional = true,
    },
  }, function(erro, res)
    if erro then
      return cb(erro)
    end
    local blocos = { res[2][1] and res[2][1][1] or "" }
    for _, i in ipairs({ 3, 4 }) do
      for _, r in ipairs(res[i] or {}) do
        table.insert(blocos, r[1] or "")
      end
    end
    local texto = {}
    for _, b in ipairs(blocos) do
      local l = arrumar_ddl(linhas_de(b))
      if #l > 0 then
        if #texto > 0 then
          table.insert(texto, "")
        end
        vim.list_extend(texto, l)
      end
    end
    local trg = {}
    for _, r in ipairs(res[5] or {}) do
      table.insert(trg, r[1])
    end
    local ddl = table.concat(texto, "\n")
    local linhas = vim.list_extend(vim.list_slice(texto, 1, #texto), triggers_comentario(trg))

    local function clonar(novo)
      novo = novo:gsub('"', ""):upper()
      local q_velho, q_novo = ('"%s"."%s"'):format(obj.esquema, obj.nome), ('"%s"."%s"'):format(obj.esquema, novo)
      local s = trocar(ddl, q_velho, q_novo)
      local colide, longos = {}, {}
      local function renomear(n)
        local r, k = trocar(n, obj.nome, novo)
        if k == 0 then
          table.insert(colide, n)
        elseif #r > 30 then
          table.insert(longos, r)
        end
        return r
      end
      s = s:gsub('(CONSTRAINT%s+)"([^"]+)"', function(pre, n)
        return pre .. '"' .. renomear(n) .. '"'
      end)
      s = s:gsub('(INDEX%s+"[^"]+"%.)"([^"]+)"', function(pre, n)
        return pre .. '"' .. renomear(n) .. '"'
      end)
      local cab = {
        ("-- Clone de %s.%s → %s.%s: só a estrutura, sem dados."):format(obj.esquema, obj.nome, obj.esquema, novo),
        ("-- Forma curta (sem PK, índices nem defaults): CREATE TABLE %s AS SELECT * FROM %s WHERE 1 = 0;"):format(
          novo,
          obj.nome
        ),
      }
      if #colide > 0 then
        table.insert(
          cab,
          "-- ⚠ estes nomes não têm o nome da tabela e iam colidir com os da original; troque antes de rodar: "
            .. table.concat(colide, ", ")
        )
      end
      if #longos > 0 then
        table.insert(
          cab,
          "-- ⚠ nomes com mais de 30 caracteres (limite do Oracle 11): " .. table.concat(longos, ", ")
        )
      end
      table.insert(cab, "")
      return vim.list_extend(cab, vim.split(s, "\n", { plain = true }))
    end

    cb(nil, { linhas = linhas, clonar = clonar })
  end)
end

local function quote_pg(n)
  if n:match("^[%l_][%l%d_$]*$") then
    return n
  end
  return '"' .. n:gsub('"', '""') .. '"'
end

local function tabela_postgres(conn, obj, cb)
  local id = tonumber(obj.id)
  local q = ([[with t as (select c.oid, c.relkind, quote_ident(n.nspname) as esquema
            from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = %d)
select 'col' as parte, a.attnum as ordem, quote_ident(a.attname) as nome,
  format_type(a.atttypid, a.atttypmod)
  || case when a.attidentity <> '' then ' GENERATED ' || case a.attidentity when 'a' then 'ALWAYS' else 'BY DEFAULT' end || ' AS IDENTITY'
          when a.attgenerated = 's' then ' GENERATED ALWAYS AS (' || pg_get_expr(d.adbin, d.adrelid) || ') STORED'
          when d.adbin is not null then ' DEFAULT ' || pg_get_expr(d.adbin, d.adrelid) else '' end
  || case when a.attnotnull then ' NOT NULL' else '' end as def
from t join pg_attribute a on a.attrelid = t.oid
left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
where a.attnum > 0 and not a.attisdropped
union all
select 'con', case k.contype when 'p' then 1 when 'u' then 2 when 'c' then 3 when 'x' then 4 else 5 end,
  quote_ident(k.conname), k.contype::text || pg_get_constraintdef(k.oid)
from t join pg_constraint k on k.conrelid = t.oid where k.contype in ('p', 'u', 'c', 'f', 'x')
union all
select 'idx', 0, quote_ident(ic.relname), pg_get_indexdef(i.indexrelid)
from t join pg_index i on i.indrelid = t.oid join pg_class ic on ic.oid = i.indexrelid
where not exists (select 1 from pg_constraint k where k.conindid = i.indexrelid and k.conrelid = t.oid)
union all
select 'com', coalesce(a.attnum, 0), coalesce(quote_ident(a.attname), ''), quote_literal(ds.description)
from t join pg_description ds on ds.objoid = t.oid and ds.classoid = 'pg_class'::regclass
left join pg_attribute a on a.attrelid = t.oid and a.attnum = ds.objsubid and ds.objsubid > 0
union all
select 'part', 0, '', pg_get_partkeydef(t.oid) from t where t.relkind = 'p'
union all
select 'esq', 0, '', t.esquema from t
union all
select 'trg', 0, quote_ident(g.tgname), '' from t join pg_trigger g on g.tgrelid = t.oid where not g.tgisinternal
order by 1, 2, 3]]):format(id)

  executar(conn, q, function(_, res, erro)
    if erro then
      return cb(erro)
    end
    local p = { col = {}, con = {}, idx = {}, com = {}, trg = {} }
    for _, r in ipairs(res or {}) do
      local parte = r[1]
      if parte == "part" then
        p.part = r[4]
      elseif parte == "esq" then
        p.esquema = r[4]
      elseif p[parte] then
        table.insert(p[parte], { ordem = tonumber(r[2]), nome = r[3], def = r[4] })
      end
    end
    if not p.esquema then
      return cb(("Tabela %s não existe mais."):format(obj.nome))
    end

    local function montar(nome_tab, renomear)
      local q_tab = p.esquema .. "." .. nome_tab
      local itens = {}
      for _, c in ipairs(p.col) do
        table.insert(itens, "    " .. c.nome .. " " .. c.def)
      end
      for _, c in ipairs(p.con) do
        local tipo, def = c.def:sub(1, 1), c.def:sub(2)
        table.insert(itens, "    CONSTRAINT " .. renomear(c.nome, tipo ~= "c" and tipo ~= "f") .. " " .. def)
      end
      local linhas = { "CREATE TABLE " .. q_tab .. " (" }
      for i, l in ipairs(itens) do
        table.insert(linhas, l .. (i < #itens and "," or ""))
      end
      table.insert(linhas, ")" .. (p.part and (" PARTITION BY " .. p.part) or "") .. ";")
      if #p.idx > 0 then
        table.insert(linhas, "")
      end
      for _, ix in ipairs(p.idx) do
        local cria, using = ix.def:match("^(CREATE .-INDEX) .- ON (.+)$")
        local only, resto = (using or ""):match("^(ONLY )(.+)$")
        resto = (resto or using or ""):match("^%S+ (USING .+)$")
        if cria and resto then
          table.insert(linhas, ("%s %s ON %s%s %s;"):format(cria, renomear(ix.nome, true), only or "", q_tab, resto))
        else
          table.insert(linhas, ix.def .. ";")
        end
      end
      if #p.com > 0 then
        table.insert(linhas, "")
      end
      for _, c in ipairs(p.com) do
        if c.ordem == 0 then
          table.insert(linhas, ("COMMENT ON TABLE %s IS %s;"):format(q_tab, c.def))
        else
          table.insert(linhas, ("COMMENT ON COLUMN %s.%s IS %s;"):format(q_tab, c.nome, c.def))
        end
      end
      return linhas
    end

    local trg = {}
    for _, t in ipairs(p.trg) do
      table.insert(trg, t.nome)
    end
    local linhas = vim.list_extend(
      montar(quote_pg(obj.nome), function(n)
        return n
      end),
      triggers_comentario(trg)
    )

    local function clonar(novo)
      -- como no Postgres: sem aspas vira minúsculo; entre aspas fica como foi digitado
      local bruto = novo:match('^"(.+)"$') or novo:lower()
      local colide, seq = {}, {}
      local corpo = montar(quote_pg(bruto), function(n, unico)
        local cru = n:gsub('^"(.*)"$', "%1"):gsub('""', '"')
        local r, k = trocar(cru, obj.nome, bruto)
        if k == 0 and unico then
          table.insert(colide, n)
        end
        return k > 0 and quote_pg(r) or n
      end)
      for _, c in ipairs(p.col) do
        if c.def:match("nextval%(") then
          table.insert(seq, c.nome)
        end
      end
      local cab = {
        ("-- Clone de %s.%s → %s.%s: só a estrutura, sem dados."):format(
          p.esquema,
          quote_pg(obj.nome),
          p.esquema,
          quote_pg(bruto)
        ),
        "-- Forma curta (copia defaults, constraints, índices e comentários, com nomes automáticos):",
        ("--   CREATE TABLE %s.%s (LIKE %s.%s INCLUDING ALL);"):format(
          p.esquema,
          quote_pg(bruto),
          p.esquema,
          quote_pg(obj.nome)
        ),
      }
      if #colide > 0 then
        table.insert(
          cab,
          "-- ⚠ estes nomes não têm o nome da tabela e iam colidir com os da original; troque antes de rodar: "
            .. table.concat(colide, ", ")
        )
      end
      if #seq > 0 then
        table.insert(
          cab,
          "-- ⚠ "
            .. table.concat(seq, ", ")
            .. " usa(m) a sequence da original (nextval); se o clone precisar da própria, crie outra."
        )
      end
      table.insert(cab, "")
      return vim.list_extend(cab, corpo)
    end

    cb(nil, { linhas = linhas, clonar = clonar })
  end)
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

local function copiar(texto, msg)
  vim.fn.setreg("+", texto)
  vim.fn.setreg('"', texto)
  vim.notify(msg)
end

local function rodape()
  local partes = { "/ buscar", "yA copiar tudo", "r recarregar" }
  if J.obj.tipo == "TABLE" then
    vim.list_extend(partes, { "c clonar", "T tipos", "gt triggers" })
  end
  vim.list_extend(partes, { "t trocar", "q fechar", "? ajuda" })
  return " " .. table.concat(partes, " · ") .. " "
end

local function mostrar(c)
  J.atual = c
  vim.bo[J.buf].modifiable = true
  vim.api.nvim_buf_set_lines(J.buf, 0, -1, false, c.linhas)
  vim.bo[J.buf].modifiable = false
  vim.diagnostic.reset(ns, J.buf)
  if c.diags and #c.diags > 0 then
    vim.diagnostic.set(ns, J.buf, c.diags)
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
    title = c.titulo,
    title_pos = "center",
    footer = rodape(),
    footer_pos = "center",
  }
  if J.win and vim.api.nvim_win_is_valid(J.win) then
    vim.api.nvim_win_set_config(J.win, cfg)
    vim.api.nvim_set_current_win(J.win)
  else
    J.win = vim.api.nvim_open_win(J.buf, true, cfg)
    vim.wo[J.win].wrap = false
    vim.wo[J.win].cursorline = true
    vim.wo[J.win].number = true
    vim.wo[J.win].relativenumber = false
    vim.wo[J.win].signcolumn = "yes"
  end
  local linha = math.max(1, math.min(c.cursor or 1, #c.linhas))
  vim.api.nvim_win_set_cursor(J.win, { linha, 0 })
  if c.cursor then
    vim.cmd("normal! zt")
  end
end

local function titulo(conn, obj, c, extra)
  local s = (" %s %s.%s"):format(obj.tipo, obj.esquema, obj.nome)
  if obj.extra ~= "" and obj.tipo ~= "TABLE" then
    s = s .. (obj.tipo == "TRIGGER" and " ·" or "") .. obj.extra:gsub("^%s+", " ")
  end
  if c.erros and c.erros > 0 then
    s = s .. (" · INVALID (%d erro%s)"):format(c.erros, c.erros > 1 and "s" or "")
  elseif obj.status == "INVALID" then
    s = s .. " · INVALID"
  end
  if extra then
    s = s .. " · " .. extra
  end
  return s .. " · " .. conn.name .. " "
end

-- Linha (1-based) do PROCEDURE/FUNCTION `nome` no corpo do pacote
local function achar_rotina(linhas, nome, desde)
  local alvo = vim.pesc(nome:upper())
  for i = desde or 1, #linhas do
    local u = linhas[i]:upper()
    if u:match("^%s*PROCEDURE%s+" .. alvo .. "%f[^%w_$#]") or u:match("^%s*FUNCTION%s+" .. alvo .. "%f[^%w_$#]") then
      return i
    end
  end
end

local function criar_buffer()
  if J.buf and vim.api.nvim_buf_is_valid(J.buf) then
    return
  end
  J.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[J.buf].bufhidden = "hide"
  vim.bo[J.buf].filetype = "lbdfonte"
  vim.bo[J.buf].tabstop = 4
  -- destaque de SQL sem filetype=sql (não liga LSP, autocomplete nem os atalhos do editor do dbee)
  if not pcall(vim.treesitter.start, J.buf, "sql") then
    vim.bo[J.buf].syntax = "sql"
  end
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = J.buf, nowait = true, silent = true, desc = desc })
  end
  local function so_tabela(fn)
    return function()
      if J.obj.tipo ~= "TABLE" then
        return vim.notify("Só na janela do CREATE de tabela.", vim.log.levels.WARN)
      end
      fn()
    end
  end
  map("yA", function()
    copiar(table.concat(vim.api.nvim_buf_get_lines(J.buf, 0, -1, false), "\n"), "Código copiado.")
  end, "Fonte: copiar tudo")
  map("r", function()
    M.abrir(J.conn, J.obj, J.modo)
  end, "Fonte: recarregar do banco")
  map("t", function()
    fechar()
    M.listar(J.modo)
  end, "Fonte: trocar de objeto")
  map(
    "c",
    so_tabela(function()
      local sufixo = J.obj.nome:match("%l") and "_copia" or "_COPIA"
      vim.ui.input(
        { prompt = ("Nome do clone de %s: "):format(J.obj.nome), default = J.obj.nome .. sufixo },
        function(novo)
          if not novo or vim.trim(novo) == "" then
            return
          end
          local linhas = J.base.clonar(vim.trim(novo))
          mostrar({
            linhas = linhas,
            titulo = titulo(J.conn, J.obj, {}, "clone → " .. vim.trim(novo)),
          })
          vim.notify("Clone pronto (yA copia; r volta para a original).")
        end
      )
    end),
    "Fonte: clonar a tabela (CREATE com outro nome, sem dados)"
  )
  map(
    "T",
    so_tabela(function()
      local nome = J.obj.nome
      fechar()
      require("lbd.colunas").abrir(nome)
    end),
    "Fonte: tipos das colunas"
  )
  map(
    "gt",
    so_tabela(function()
      M.listar("trigger", J.obj.nome)
    end),
    "Fonte: triggers da tabela"
  )
  map("q", fechar, "Fonte: fechar")
  map("<Esc>", fechar, "Fonte: fechar")
  map("?", function()
    require("lbd.ajuda").mostrar({ "fonte" })
  end, "Fonte: ajuda")
end

---------------------------------------------------------------------------
-- API
---------------------------------------------------------------------------

---Abre o objeto na janela. `pular`: nome da procedure/function do pacote onde parar o cursor.
function M.abrir(conn, obj, modo, pular)
  vim.notify(("Carregando %s %s..."):format(obj.tipo:lower(), obj.nome))
  local fn
  if obj.tipo == "TABLE" then
    fn = conn.type == "oracle" and tabela_oracle or tabela_postgres
  else
    fn = conn.type == "oracle" and codigo_oracle or codigo_postgres
  end
  fn(conn, obj, function(erro, c)
    if erro then
      return vim.notify(("%s %s: %s"):format(obj.tipo, obj.nome, tostring(erro)), vim.log.levels.ERROR)
    end
    J.conn, J.obj, J.base = conn, obj, c
    J.modo = modo or (obj.tipo == "TABLE" and "tabela") or (obj.tipo == "TRIGGER" and "trigger") or "codigo"
    c.titulo = titulo(conn, obj, c)
    if pular then
      c.cursor = achar_rotina(c.linhas, pular, c.corpo)
      if not c.cursor then
        vim.notify(("%s não encontrada no corpo de %s."):format(pular, obj.nome), vim.log.levels.WARN)
      end
    end
    criar_buffer()
    mostrar(c)
  end)
end

local function escolher(conn, objs, prompt, modo, pular)
  if #objs == 1 then
    return M.abrir(conn, objs[1], modo, pular)
  end
  vim.ui.select(objs, { prompt = prompt, format_item = rotulo }, function(o)
    if o then
      M.abrir(conn, o, modo, pular)
    end
  end)
end

---Lista os objetos do modo ("codigo" | "trigger" | "tabela") para buscar e abrir.
---@param tabela? string só as triggers desta tabela (modo "trigger")
function M.listar(modo, tabela)
  local conn = conexao()
  if not conn then
    return
  end
  buscar(conn, { tipos = TIPOS[modo][conn.type], tabela = tabela }, function(erro, objs)
    if erro then
      return vim.notify(NOME_MODO[modo] .. ": " .. tostring(erro), vim.log.levels.ERROR)
    end
    if #objs == 0 then
      local onde = tabela and ("na tabela " .. tabela) or "no schema/database atual"
      return vim.notify(("%s %s."):format(VAZIO[modo], onde), vim.log.levels.WARN)
    end
    escolher(conn, objs, ("%s [%s]%s"):format(NOME_MODO[modo], conn.name, tabela and (" · " .. tabela) or ""), modo)
  end)
end

---Abre o objeto pelo nome: "OBJ", "SCHEMA.OBJ", "PACOTE.PROC" ou "SCHEMA.PACOTE.PROC".
---@param tipos? string[] restringe os tipos (padrão: todos)
function M.por_nome(palavra, tipos)
  local conn = conexao()
  if not conn then
    return
  end
  palavra = (palavra or ""):gsub('"', ""):gsub("^%.+", ""):gsub("%.+$", "")
  if palavra == "" then
    return vim.notify("Nenhum nome sob o cursor.", vim.log.levels.WARN)
  end
  local p = vim.split(palavra, ".", { plain = true })
  local tudo = tipos or todos(conn.type)
  local tentativas
  if #p == 1 then
    tentativas = { { f = { tipos = tudo, nome = p[1] } } }
  elseif #p == 2 then
    tentativas = {
      { f = { tipos = tudo, schema = p[1], nome = p[2] } },
      { f = { tipos = { "PACKAGE" }, nome = p[1] }, pular = p[2], so = "oracle" },
      { f = { tipos = tudo, nome = p[2] } }, -- alias.objeto
    }
  else
    tentativas =
      { { f = { tipos = { "PACKAGE" }, schema = p[#p - 2], nome = p[#p - 1] }, pular = p[#p], so = "oracle" } }
  end

  local function tentar(i)
    local t = tentativas[i]
    if not t then
      return vim.notify(
        ("'%s' não encontrado (procedure, function, package, trigger, view ou tabela)."):format(palavra),
        vim.log.levels.WARN
      )
    end
    if t.so and t.so ~= conn.type then
      return tentar(i + 1)
    end
    buscar(conn, t.f, function(erro, objs)
      if erro then
        return vim.notify("Fonte: " .. tostring(erro), vim.log.levels.ERROR)
      end
      if #objs == 0 then
        return tentar(i + 1)
      end
      escolher(conn, objs, ("'%s' [%s]"):format(palavra, conn.name), nil, t.pular)
    end)
  end
  tentar(1)
end

---Objeto sob o cursor (pega SCHEMA.PACOTE.PROC inteiro, com ou sem aspas)
function M.sob_cursor()
  local linha = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local chars = '[%w_$#%."]'
  if not linha:sub(col, col):match(chars) then
    return vim.notify("Nenhum nome sob o cursor.", vim.log.levels.WARN)
  end
  local s, e = col, col
  while s > 1 and linha:sub(s - 1, s - 1):match(chars) do
    s = s - 1
  end
  while e < #linha and linha:sub(e + 1, e + 1):match(chars) do
    e = e + 1
  end
  M.por_nome(linha:sub(s, e))
end

---CREATE da tabela pelo nome (sem nome: lista as tabelas)
function M.tabela(nome)
  if not nome or nome == "" then
    return M.listar("tabela")
  end
  M.por_nome(nome, { "TABLE" })
end

function M.setup()
  vim.api.nvim_create_user_command("BancoFonte", function(opts)
    if opts.args ~= "" then
      M.por_nome(opts.args)
    else
      M.listar("codigo")
    end
  end, { nargs = "?", desc = "Código de procedure/function/package/view (sem nome: lista)" })
  vim.api.nvim_create_user_command("BancoTriggers", function(opts)
    M.listar("trigger", opts.args ~= "" and opts.args or nil)
  end, { nargs = "?", desc = "Triggers do schema/database (ou só as da tabela)" })
  vim.api.nvim_create_user_command("BancoCreate", function(opts)
    M.tabela(opts.args)
  end, { nargs = "?", desc = "CREATE da tabela (constraints, índices, comentários) + clone" })
end

return M
