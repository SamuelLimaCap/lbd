-- lbd: utilitários para rodar SQL pelo dbee e ler o resultado (CSV preserva ordem e nomes repetidos de colunas).
local M = {}

local TERMINAIS = { archived = true, executing_failed = true, retrieving_failed = true, canceled = true }

-- Parser CSV (RFC 4180): aspas, vírgulas e quebras de linha dentro do campo.
---@return string[][] linhas (a 1ª é o cabeçalho)
function M.parse_csv(texto)
  local linhas, linha, campo = {}, {}, {}
  local i, n, entre_aspas = 1, #texto, false
  while i <= n do
    local c = texto:sub(i, i)
    if entre_aspas then
      if c == '"' then
        if texto:sub(i + 1, i + 1) == '"' then
          table.insert(campo, '"')
          i = i + 1
        else
          entre_aspas = false
        end
      else
        table.insert(campo, c)
      end
    elseif c == '"' then
      entre_aspas = true
    elseif c == "," then
      table.insert(linha, table.concat(campo))
      campo = {}
    elseif c == "\n" or c == "\r" then
      if c == "\r" and texto:sub(i + 1, i + 1) == "\n" then
        i = i + 1
      end
      table.insert(linha, table.concat(campo))
      table.insert(linhas, linha)
      linha, campo = {}, {}
    else
      table.insert(campo, c)
    end
    i = i + 1
  end
  if #campo > 0 or #linha > 0 then
    table.insert(linha, table.concat(campo))
    table.insert(linhas, linha)
  end
  return linhas
end

-- Exporta linhas [from, to) de uma chamada já concluída como CSV parseado.
---@return string[] cabecalho, string[][] linhas
function M.ler(call_id, from, to)
  local arquivo = vim.fn.tempname() .. ".csv"
  local opts = { extra_arg = arquivo }
  if from then
    opts.from, opts.to = from, to
  end
  require("dbee.api").core.call_store_result(call_id, "csv", "file", opts)
  local fh = io.open(arquivo, "r")
  local texto = fh and fh:read("*a") or ""
  if fh then
    fh:close()
  end
  os.remove(arquivo)
  local linhas = M.parse_csv(texto)
  local cabecalho = table.remove(linhas, 1) or {}
  return cabecalho, linhas
end

-- Execução síncrona (para listas pequenas, ~1s).
function M.executar(conn_id, query)
  local api = require("dbee.api")
  local call = api.core.connection_execute(conn_id, query)
  vim.wait(30000, function()
    for _, c in ipairs(api.core.connection_get_calls(conn_id) or {}) do
      if c.id == call.id and TERMINAIS[c.state] then
        call = c
        return true
      end
    end
    return false
  end, 50)
  return call
end

-- Execução assíncrona de baixo nível: cb(call) quando a chamada termina (sem ler o resultado).
-- Retorna a chamada (já com id) para permitir cancelamento.
local pendentes, ouvindo = {}, false
function M.chamar(conn_id, query, cb)
  local api = require("dbee.api")
  if not ouvindo then
    ouvindo = true
    api.core.register_event_listener("call_state_changed", function(data)
      local call = data.call
      local fn = pendentes[call.id]
      if not fn or not TERMINAIS[call.state] then
        return
      end
      pendentes[call.id] = nil
      vim.schedule(function()
        fn(call)
      end)
    end)
  end
  local call = api.core.connection_execute(conn_id, query)
  pendentes[call.id] = cb
  return call
end

-- Execução assíncrona com leitura: cb(cabecalho, linhas) em sucesso, cb(nil, nil, erro) em falha.
function M.executar_async(conn_id, query, cb)
  M.chamar(conn_id, query, function(call)
    if call.state ~= "archived" then
      return cb(nil, nil, call.error or call.state)
    end
    local ok, cab, linhas = pcall(M.ler, call.id)
    if ok then
      cb(cab, linhas)
    else
      cb(nil, nil, cab)
    end
  end)
end

-- Quantidade de linhas de uma chamada concluída (renderiza 0 linhas num buffer oculto só p/ obter o total)
local buf_contagem
function M.total_linhas(call_id)
  if not (buf_contagem and vim.api.nvim_buf_is_valid(buf_contagem)) then
    buf_contagem = vim.api.nvim_create_buf(false, true)
  end
  local ok, n = pcall(function()
    return require("dbee.api.state").handler():call_display_result(call_id, buf_contagem, 0, 0)
  end)
  return ok and n or nil
end

-- Remove ";" finais (o Oracle recusa) e espaços
function M.limpar(query)
  query = vim.trim(query)
  while query:sub(-1) == ";" do
    query = vim.trim(query:sub(1, -2))
  end
  return query
end

-- Primeira palavra da query, ignorando comentários (select/with/update/delete/...)
function M.comando(query)
  local s = query:gsub("%-%-[^\n]*", ""):gsub("/%*.-%*/", "")
  return (vim.trim(s):match("^(%a+)") or ""):lower()
end

return M
