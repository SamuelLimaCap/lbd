-- lbd: seletor de database (Postgres) / schema (Oracle) na conexão ATIVA do Dbee,
-- como o seletor da barra do DBeaver.
--   Postgres -> troca o database com o recurso nativo do dbee (connection_select_database).
--   Oracle   -> ALTER SESSION SET CURRENT_SCHEMA (mesmo que o DBeaver faz por baixo).
local sql = require("lbd.sql")

local M = {}

-- Avisa o autocomplete que o escopo (database/schema) da conexão mudou
local function escopo_mudou(conn_id, escopo)
  pcall(function()
    require("lbd.completar").definir_escopo(conn_id, escopo)
  end)
end

local function primeira_coluna(call)
  local _, linhas = sql.ler(call.id)
  local valores = {}
  for _, l in ipairs(linhas) do
    if l[1] and l[1] ~= "" then
      table.insert(valores, l[1])
    end
  end
  return valores
end

local function postgres(api, conn)
  local atual, databases = api.core.connection_list_databases(conn.id)
  table.sort(databases)
  vim.ui.select(databases, { prompt = ("Database [%s] (atual: %s)"):format(conn.name, atual) }, function(db)
    if not db then
      return
    end
    api.core.connection_select_database(conn.id, db)
    pcall(api.ui.drawer_refresh)
    escopo_mudou(conn.id, db)
    vim.notify(("%s → database %s"):format(conn.name, db))
  end)
end

local function oracle(api, conn)
  local lista = sql.executar(conn.id, "select username from all_users order by username")
  if lista.state ~= "archived" then
    vim.notify("Falha ao listar schemas: " .. (lista.error or lista.state), vim.log.levels.ERROR)
    return
  end
  local atual = primeira_coluna(sql.executar(conn.id, "select sys_context('USERENV','CURRENT_SCHEMA') from dual"))[1]

  vim.ui.select(primeira_coluna(lista), { prompt = ("Schema [%s] (atual: %s)"):format(conn.name, atual or "?") }, function(schema)
    if not schema then
      return
    end
    -- Aspas: usernames de all_users já vêm no case exato
    local alter = sql.executar(conn.id, ('alter session set current_schema = "%s"'):format(schema))
    if alter.state ~= "archived" then
      vim.notify("Falha ao trocar schema: " .. (alter.error or alter.state), vim.log.levels.ERROR)
      return
    end
    escopo_mudou(conn.id, schema)
    vim.notify(("%s → schema %s"):format(conn.name, schema))
  end)
end

function M.escolher()
  local api = require("dbee.api")
  local conn = api.core.get_current_connection()
  if not conn then
    vim.notify("Nenhuma conexão ativa: abra o Dbee (<leader>D) e use `cw` numa conexão.", vim.log.levels.WARN)
    return
  end
  if conn.type == "postgres" then
    postgres(api, conn)
  elseif conn.type == "oracle" then
    oracle(api, conn)
  else
    vim.notify("Seletor não suportado para conexões do tipo " .. conn.type, vim.log.levels.WARN)
  end
end

return M
