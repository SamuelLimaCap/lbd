local function create_pg_commands()
  -- lbd: adaptado do vim-dadbod para o nvim-dbee.
  -- Aceita o id ("dbeaver-sinc1"), o nome completo ou só a 1ª palavra do nome ("sinc1", "postgres").
  local function find_connection(db_name)
    local api = require("dbee.api")
    for _, source in ipairs(api.core.get_sources()) do
      for _, conn in ipairs(api.core.source_get_connections(source:name()) or {}) do
        if conn.id == db_name or conn.name == db_name or conn.name:match("^(%S+)") == db_name then
          return conn
        end
      end
    end
    return nil
  end

  -- Executa a query na conexão pedida (ou na atual) e mostra o resultado no Dbee
  local function execute_query(query, title, db_name)
    local api = require("dbee.api")

    if db_name then
      local conn = find_connection(db_name)
      if not conn then
        vim.notify(string.format("Conexão '%s' não encontrada no Dbee!", db_name), vim.log.levels.ERROR)
        return
      end
      api.core.set_current_connection(conn.id)
    elseif not api.core.get_current_connection() then
      vim.notify("Nenhuma conexão selecionada! Abra o Dbee (<leader>D) e escolha uma.", vim.log.levels.WARN)
      return
    end

    require("dbee").execute(query)
    vim.notify(title .. ": query executada! Aguarde os resultados...", vim.log.levels.INFO)
  end

  -- Comando 1: Listar triggers de uma tabela
  vim.api.nvim_create_user_command("PgListTriggers", function(opts)
    local args = vim.split(opts.args, "%s+")
    local db_name = nil
    local table_name = nil

    if #args == 0 then
      vim.notify("Uso: :PgListTriggers [nome_conexao] nome_da_tabela", vim.log.levels.ERROR)
      return
    elseif #args == 1 then
      table_name = args[1]
    else
      db_name = args[1]
      table_name = args[2]
    end

    local query = string.format(
      [[
SELECT 
    t.tgname AS trigger_name,
    t.tgenabled AS enabled,
    p.proname AS function_name,
    CASE t.tgtype & 2
        WHEN 2 THEN 'BEFORE'
        ELSE 'AFTER'
    END AS timing,
    CASE t.tgtype & 28
        WHEN 4 THEN 'INSERT'
        WHEN 8 THEN 'DELETE'
        WHEN 16 THEN 'UPDATE'
        WHEN 12 THEN 'INSERT OR DELETE'
        WHEN 20 THEN 'INSERT OR UPDATE'
        WHEN 24 THEN 'DELETE OR UPDATE'
        WHEN 28 THEN 'INSERT OR DELETE OR UPDATE'
    END AS event
FROM pg_trigger t
JOIN pg_class c ON t.tgrelid = c.oid
JOIN pg_namespace n ON c.relnamespace = n.oid
JOIN pg_proc p ON t.tgfoid = p.oid
WHERE c.relname = '%s'
  AND n.nspname = 'public'
  AND NOT t.tgisinternal
ORDER BY t.tgname;
]],
      table_name
    )

    execute_query(query, "Triggers: " .. table_name, db_name)
  end, { nargs = "+", desc = "Listar triggers de uma tabela PostgreSQL" })

  -- Comando 2: Listar todas as funções do banco
  vim.api.nvim_create_user_command("PgListFunctions", function(opts)
    local db_name = opts.args ~= "" and opts.args or nil
    local query = [[
SELECT 
    n.nspname AS schema,
    p.proname AS function_name,
    pg_catalog.pg_get_function_arguments(p.oid) AS arguments,
    CASE p.prokind
        WHEN 'f' THEN 'FUNCTION'
        WHEN 'p' THEN 'PROCEDURE'
        WHEN 'a' THEN 'AGGREGATE'
        WHEN 'w' THEN 'WINDOW'
    END AS type,
    pg_catalog.obj_description(p.oid, 'pg_proc') AS description
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY schema, function_name;
]]

    execute_query(query, "PostgreSQL Functions", db_name)
  end, { nargs = "?", desc = "Listar todas as funções PostgreSQL" })

  -- Comando 3: Mostrar código de uma função
  vim.api.nvim_create_user_command("PgShowFunction", function(opts)
    local args = vim.split(opts.args, "%s+")
    local db_name = nil
    local function_name = nil

    if #args == 0 then
      vim.notify("Uso: :PgShowFunction [nome_conexao] nome_da_funcao", vim.log.levels.ERROR)
      return
    elseif #args == 1 then
      function_name = args[1]
    else
      db_name = args[1]
      function_name = args[2]
    end

    local query = string.format(
      [[
SELECT pg_get_functiondef(p.oid) AS function_definition
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE p.proname = '%s'
  AND n.nspname = 'public';
]],
      function_name
    )

    execute_query(query, "Function: " .. function_name, db_name)
  end, { nargs = "+", desc = "Mostrar código de uma função PostgreSQL" })
end

-- Criar os comandos quando o Neovim iniciar
vim.api.nvim_create_autocmd("VimEnter", {
  callback = create_pg_commands,
})

return {}
