-- lbd: extras da grade de resultado do dbee
--   o            -> order by na coluna sob o cursor (repetir alterna asc/desc); reexecuta a query
--   O            -> desfaz a ordenação (volta à query original)
--   <leader>SK   -> modo registro: "Coluna: valor" da linha sob o cursor, com n/p, s (A→Z) e yv
local sql = require("lbd.sql")

local M = {}

-- call_id -> { base = query original, col = posição, dir = "asc"|"desc", nome = coluna }
local ordens = {}

local function api()
  return require("dbee.api")
end

local function eh_resultado(bufnr)
  return vim.api.nvim_buf_get_name(bufnr or 0):match("dbee%-result") ~= nil
end

local function buffer_resultado()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and eh_resultado(b) then
      return b
    end
  end
end

local function call_atual()
  local call = api().ui.result_get_call()
  if not call then
    vim.notify("Nenhum resultado na tela.", vim.log.levels.WARN)
    return nil
  end
  if call.state ~= "archived" and call.state ~= "retrieving" then
    vim.notify("O resultado atual não tem linhas (estado: " .. call.state .. ").", vim.log.levels.WARN)
    return nil
  end
  return call
end

---------------------------------------------------------------------------
-- ORDER BY pela coluna sob o cursor
---------------------------------------------------------------------------

-- Posição (1..N) e nome da coluna sob o cursor, pela posição na TELA (funciona com acentos)
local function coluna_sob_cursor()
  local cab = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or ""
  local cursor = vim.fn.virtcol(".")
  local seps, ini = {}, 1
  while true do
    local p = cab:find("│", ini, true)
    if not p then
      break
    end
    table.insert(seps, { byte = p, tela = vim.fn.strdisplaywidth(cab:sub(1, p - 1)) + 1 })
    ini = p + 1
  end
  local n = 0
  for _, s in ipairs(seps) do
    if s.tela < cursor then
      n = n + 1
    end
  end
  if n == 0 then
    return nil
  end
  local fim = seps[n + 1] and (seps[n + 1].byte - 1) or #cab
  local nome = vim.trim(cab:sub(seps[n].byte + #"│", fim))
  return n, nome
end

local function limpar_query(q)
  q = vim.trim(q)
  while q:sub(-1) == ";" do
    q = vim.trim(q:sub(1, -2))
  end
  return q
end

local function eh_select(q)
  local sem_coment = q:gsub("%-%-[^\n]*", ""):gsub("/%*.-%*/", "")
  local w = vim.trim(sem_coment):match("^(%a+)")
  return w and (w:lower() == "select" or w:lower() == "with")
end

local function executar_e_mostrar(query, info)
  local conn = api().core.get_current_connection()
  if not conn then
    vim.notify("Nenhuma conexão ativa.", vim.log.levels.WARN)
    return
  end
  local call = api().core.connection_execute(conn.id, query)
  api().ui.result_set_call(call)
  if info then
    ordens[call.id] = info
  end
end

function M.ordenar()
  if not eh_resultado() then
    return vim.notify("Use o order by dentro da grade de resultado.", vim.log.levels.WARN)
  end
  local call = call_atual()
  if not call then
    return
  end
  -- Resultado do lote veio de uma conexão temporária: reexecutar na conexão ativa cairia em outra base
  if require("lbd.lote").eh_do_lote(call.id) then
    return vim.notify("Order by não disponível em resultado de lote (rode a query direto nessa base).", vim.log.levels.WARN)
  end
  local col, nome = coluna_sob_cursor()
  if not col then
    return vim.notify("Posicione o cursor numa coluna de dados (não na numeração).", vim.log.levels.WARN)
  end
  local info = ordens[call.id]
  local base = info and info.base or limpar_query(call.query)
  if not eh_select(base) then
    return vim.notify("Order by só funciona em consultas SELECT/WITH.", vim.log.levels.WARN)
  end
  local dir = (info and info.col == col and info.dir == "asc") and "desc" or "asc"
  -- Ordena pela POSIÇÃO (igual no Postgres e no Oracle). No Postgres a subquery tolera nomes repetidos;
  -- no Oracle não (ORA-00918) -> nesse caso o listener abaixo refaz com o ORDER BY direto na query.
  local q = ("select * from (\n%s\n) lbd_ordem order by %d %s"):format(base, col, dir)
  local novo = { base = base, col = col, dir = dir, nome = nome }
  novo.alternativa = ("%s\norder by %d %s"):format(base, col, dir)
  executar_e_mostrar(q, novo)
  vim.notify(("Ordenado por %s (%s)"):format(nome, dir))
end

-- Oracle + colunas com nome repetido (ex.: dois ID num join): a subquery falha com ORA-00918;
-- tenta de novo pondo o ORDER BY no fim da query original.
local function ouvir_falhas()
  api().core.register_event_listener("call_state_changed", function(data)
    local call = data.call
    local info = ordens[call.id]
    if not info or not info.alternativa or call.state ~= "executing_failed" then
      return
    end
    if not (call.error or ""):find("ORA%-00918") then
      return
    end
    vim.schedule(function()
      local atual = api().ui.result_get_call()
      if atual and atual.id == call.id then
        executar_e_mostrar(info.alternativa, vim.tbl_extend("force", info, { alternativa = false }))
        vim.notify(("Ordenado por %s (%s) — colunas repetidas: ORDER BY aplicado direto na query"):format(info.nome, info.dir))
      end
    end)
  end)
end

function M.desfazer_ordem()
  local call = api().ui.result_get_call()
  local info = call and ordens[call.id]
  if not info then
    return vim.notify("Este resultado não foi ordenado pelo lbd.", vim.log.levels.INFO)
  end
  executar_e_mostrar(info.base, nil)
  vim.notify("Ordenação removida.")
end

---------------------------------------------------------------------------
-- Modo registro (<leader>SK)
---------------------------------------------------------------------------
local R = { buf = nil, win = nil, call = nil, idx = 1, total = nil, alfabetica = false, valores = {} }
local ns = vim.api.nvim_create_namespace("lbd_registro")

local function total_linhas(call)
  return sql.total_linhas(call.id)
end

-- Índice (1-based, absoluto) da linha da grade sob o cursor
local function linha_sob_cursor()
  local row = vim.fn.search([[^\s*\d\+\s*│]], "bnc")
  if row == 0 then
    row = vim.fn.search([[^\s*\d\+\s*│]], "nc") -- cursor no cabeçalho: pega a 1ª linha
  end
  if row == 0 then
    return 1
  end
  return tonumber((vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""):match("%d+")) or 1
end

-- Leva o cursor da grade até a linha do registro (se ela estiver na página visível)
local function sincronizar_grade(idx)
  local b = buffer_resultado()
  local w = b and vim.fn.bufwinid(b) or -1
  if w == -1 then
    return
  end
  for i, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
    if tonumber(l:match("^%s*(%d+)%s*│")) == idx then
      pcall(vim.api.nvim_win_set_cursor, w, { i, 0 })
      return
    end
  end
end

local function fechar()
  if R.win and vim.api.nvim_win_is_valid(R.win) then
    vim.api.nvim_win_close(R.win, true)
  end
  R.win = nil
end

local function formatar(v)
  if v == nil then
    return ""
  end
  return (v:gsub("\r?\n", " ⏎ "):gsub("\t", "  "))
end

local function desenhar()
  local cab, linhas = sql.ler(R.call.id, R.idx - 1, R.idx)
  local linha = linhas[1]
  if not linha then
    return false
  end

  local pares = {}
  for i, nome in ipairs(cab) do
    table.insert(pares, { nome = nome, valor = linha[i], pos = i })
  end
  if R.alfabetica then
    table.sort(pares, function(a, b)
      return a.nome:lower() < b.nome:lower()
    end)
  end

  local largura_nome = 0
  for _, p in ipairs(pares) do
    largura_nome = math.max(largura_nome, vim.fn.strdisplaywidth(p.nome))
  end

  local texto, largura = {}, 40
  R.valores = {}
  for _, p in ipairs(pares) do
    local l = p.nome .. string.rep(" ", largura_nome - vim.fn.strdisplaywidth(p.nome)) .. " : " .. formatar(p.valor)
    table.insert(texto, l)
    table.insert(R.valores, p.valor or "")
    largura = math.max(largura, vim.fn.strdisplaywidth(l))
  end

  vim.bo[R.buf].modifiable = true
  vim.api.nvim_buf_set_lines(R.buf, 0, -1, false, texto)
  vim.bo[R.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(R.buf, ns, 0, -1)
  for i, p in ipairs(pares) do
    vim.api.nvim_buf_set_extmark(R.buf, ns, i - 1, 0, { end_col = #p.nome, hl_group = "Identifier" })
  end

  local titulo = (" Registro %d/%s · %s "):format(R.idx, R.total and tostring(R.total) or "?", R.alfabetica and "colunas A→Z" or "ordem original")
  local cfg = {
    relative = "editor",
    width = math.min(largura + 2, vim.o.columns - 8),
    height = math.max(1, math.min(#texto, vim.o.lines - 8)),
    title = titulo,
    title_pos = "center",
    footer = " n/p próximo/anterior · s A→Z · yv copiar valor · q fechar · ? ajuda ",
    footer_pos = "center",
    border = "rounded",
  }
  cfg.row = math.floor((vim.o.lines - cfg.height) / 2) - 1
  cfg.col = math.floor((vim.o.columns - cfg.width) / 2)

  if R.win and vim.api.nvim_win_is_valid(R.win) then
    vim.api.nvim_win_set_config(R.win, cfg)
  else
    R.win = vim.api.nvim_open_win(R.buf, true, cfg)
    vim.wo[R.win].wrap = false
    vim.wo[R.win].cursorline = true
  end
  sincronizar_grade(R.idx)
  return true
end

local function mover(delta)
  local novo = R.idx + delta
  if novo < 1 then
    return vim.notify("Já está no primeiro registro.", vim.log.levels.INFO)
  end
  if R.total and novo > R.total then
    return vim.notify("Já está no último registro.", vim.log.levels.INFO)
  end
  local anterior = R.idx
  R.idx = novo
  if not desenhar() then
    R.idx = anterior
    vim.notify("Não há mais registros.", vim.log.levels.INFO)
  end
end

local function criar_buffer()
  if R.buf and vim.api.nvim_buf_is_valid(R.buf) then
    return
  end
  R.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[R.buf].bufhidden = "hide"
  vim.bo[R.buf].filetype = "lbdregistro"
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = R.buf, nowait = true, silent = true, desc = desc })
  end
  map("n", function() mover(1) end, "Registro: próximo")
  map("p", function() mover(-1) end, "Registro: anterior")
  map("s", function()
    R.alfabetica = not R.alfabetica
    desenhar()
  end, "Registro: alternar colunas A→Z / ordem original")
  map("yv", function()
    local v = R.valores[vim.api.nvim_win_get_cursor(0)[1]] or ""
    vim.fn.setreg(vim.v.register, v)
    vim.notify("Valor copiado.")
  end, "Registro: copiar o valor da linha")
  map("q", fechar, "Registro: fechar")
  map("<Esc>", fechar, "Registro: fechar")
  map("?", function() require("lbd.ajuda").mostrar({ "registro" }) end, "Registro: ajuda")
end

function M.registro()
  local call = call_atual()
  if not call then
    return
  end
  local idx = eh_resultado() and linha_sob_cursor() or 1
  criar_buffer()
  R.call, R.idx = call, idx
  R.total = total_linhas(call)
  if not desenhar() then
    vim.notify("Não foi possível ler o registro " .. idx .. ".", vim.log.levels.WARN)
  end
end

---------------------------------------------------------------------------
-- Atalhos da grade (o dbee recria/reconfigura o buffer; reaplicamos sempre que ele aparece)
---------------------------------------------------------------------------
function M.setup()
  ouvir_falhas()
  vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter" }, {
    group = vim.api.nvim_create_augroup("lbd_resultado", { clear = true }),
    callback = function(ev)
      if not eh_resultado(ev.buf) then
        return
      end
      local function map(lhs, fn, desc)
        vim.keymap.set("n", lhs, fn, { buffer = ev.buf, nowait = true, silent = true, desc = desc })
      end
      map("o", M.ordenar, "Resultado: order by na coluna (asc/desc)")
      map("O", M.desfazer_ordem, "Resultado: desfazer order by")
      map("?", function() require("lbd.ajuda").mostrar({ "resultado", "registro" }) end, "Resultado: ajuda")
    end,
  })
end

return M
