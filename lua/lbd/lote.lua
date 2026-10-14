-- lbd: rodar a MESMA query em vários schemas (Oracle) ou databases (Postgres).
--   <leader>da -> confirmação -> escolhe o servidor -> marca schemas/databases (com TODOS) -> roda
--   Lista ao vivo por base: ✔ ok (linhas) / ✘ erro (mensagem) / ⏳ rodando. <leader>dl reabre a lista.
--
-- Execução em conexões TEMPORÁRIAS (até 4 em paralelo), numa fonte própria escondida da árvore:
-- não mexe no schema/database que você está usando.
--   Oracle SELECT  -> ALTER SESSION SET CURRENT_SCHEMA + query (mesma conexão, em sequência)
--   Oracle demais  -> bloco PL/SQL único (alter session + execute immediate + commit): o comando
--                     nunca cai em outro schema, mesmo que o pool troque de sessão
--   Postgres       -> troca o database da conexão temporária e roda (cada comando é efetivado pelo servidor)
local sql = require("lbd.sql")

local M = {}

local PARALELO = 4
local FONTE = "lbd-lote"

-- Schemas de sistema do Oracle 11g (não tem ALL_USERS.ORACLE_MAINTAINED): ficam fora do "TODOS"
local SISTEMA_ORACLE = {}
for _, s in ipairs({
  "ANONYMOUS", "APEX_030200", "APEX_040000", "APEX_040200", "APEX_PUBLIC_USER", "APPQOSSYS", "BI", "CTXSYS",
  "DBSNMP", "DIP", "DMSYS", "EXFSYS", "FLOWS_FILES", "HR", "IX", "MDDATA", "MDSYS", "MGMT_VIEW", "OE",
  "OLAPSYS", "ORACLE_OCM", "ORDDATA", "ORDPLUGINS", "ORDSYS", "OUTLN", "OWBSYS", "OWBSYS_AUDIT", "PM",
  "SCOTT", "SH", "SI_INFORMTN_SCHEMA", "SPATIAL_CSW_ADMIN_USR", "SPATIAL_WFS_ADMIN_USR", "SYS", "SYSMAN",
  "SYSTEM", "TSMSYS", "WMSYS", "XDB", "XS$NULL",
}) do
  SISTEMA_ORACLE[s] = true
end

local function api()
  return require("dbee.api")
end

local function agora()
  return vim.uv.hrtime() / 1e9
end

---------------------------------------------------------------------------
-- Fonte de conexões temporárias (escondida da árvore do Dbee)
---------------------------------------------------------------------------
local fonte = { conns = {} }
function fonte:name()
  return FONTE
end
function fonte:load()
  return self.conns
end

local fonte_registrada = false
local function preparar_fonte()
  if fonte_registrada then
    return
  end
  api().core.add_source(fonte)
  local handler = require("dbee.api.state").handler()
  local original = handler.get_sources
  handler.get_sources = function(self)
    local lista = {}
    for _, s in ipairs(original(self)) do
      if s:name() ~= FONTE then
        table.insert(lista, s)
      end
    end
    return lista
  end
  fonte_registrada = true
end

-- Recria as conexões temporárias (o reload fecha as anteriores)
local function abrir_conexoes(base, n)
  preparar_fonte()
  fonte.conns = {}
  local ids = {}
  for i = 1, n do
    local id = "lbd-lote-" .. i
    table.insert(fonte.conns, { id = id, name = "lote " .. i, type = base.type, url = base.url })
    table.insert(ids, id)
  end
  api().core.source_reload(FONTE)
  return ids
end

---------------------------------------------------------------------------
-- Janelas: confirmação e seleção (checklist)
---------------------------------------------------------------------------
local function janela(buf, titulo, rodape, largura, altura)
  local w = math.min(largura + 2, vim.o.columns - 6)
  local h = math.max(1, math.min(altura, vim.o.lines - 8))
  return vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = w,
    height = h,
    row = math.floor((vim.o.lines - h) / 2) - 1,
    col = math.floor((vim.o.columns - w) / 2),
    border = "rounded",
    title = titulo,
    title_pos = "center",
    footer = rodape,
    footer_pos = "center",
  })
end

local function buffer_temporario(linhas)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, linhas)
  vim.bo[buf].modifiable = false
  return buf
end

local function confirmar(titulo, linhas, cb)
  local buf = buffer_temporario(linhas)
  local largura = 50
  for _, l in ipairs(linhas) do
    largura = math.max(largura, vim.fn.strdisplaywidth(l))
  end
  local win = janela(buf, " " .. titulo .. " ", " <CR>/s continuar · q/n cancelar ", largura, #linhas)
  local respondido = false
  local function responder(sim)
    if respondido then
      return
    end
    respondido = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    vim.schedule(function()
      cb(sim)
    end)
  end
  for _, k in ipairs({ "<CR>", "s", "S", "y" }) do
    vim.keymap.set("n", k, function() responder(true) end, { buffer = buf, nowait = true })
  end
  for _, k in ipairs({ "q", "n", "N", "<Esc>" }) do
    vim.keymap.set("n", k, function() responder(false) end, { buffer = buf, nowait = true })
  end
end

---@param itens { valor: string, sistema: boolean }[]
local function selecionar(titulo, itens, cb)
  local marcado, filtro, mapa = {}, "", {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local ns = vim.api.nvim_create_namespace("lbd_lote_sel")
  local win

  local function visiveis()
    local lista = {}
    for _, it in ipairs(itens) do
      if filtro == "" or it.valor:lower():find(filtro:lower(), 1, true) then
        table.insert(lista, it)
      end
    end
    return lista
  end

  local function selecionados()
    local lista = {}
    for _, it in ipairs(itens) do
      if marcado[it.valor] then
        table.insert(lista, it.valor)
      end
    end
    return lista
  end

  local function desenhar()
    local vis = visiveis()
    local alvos_todos, marcados_todos = 0, 0
    for _, it in ipairs(vis) do
      if not it.sistema then
        alvos_todos = alvos_todos + 1
        if marcado[it.valor] then
          marcados_todos = marcados_todos + 1
        end
      end
    end
    local caixa_todos = (alvos_todos > 0 and marcados_todos == alvos_todos) and "[x]"
      or (marcados_todos > 0 and "[-]" or "[ ]")
    local texto = { ("%s ★ TODOS (%s, exceto sistema)"):format(caixa_todos, filtro == "" and "todos" or "visíveis") }
    mapa = { [1] = "TODOS" }
    for _, it in ipairs(vis) do
      table.insert(texto, ("%s %s%s"):format(marcado[it.valor] and "[x]" or "[ ]", it.valor, it.sistema and "  (sistema)" or ""))
      mapa[#texto] = it
    end
    if #vis == 0 then
      table.insert(texto, "   (nada com o filtro '" .. filtro .. "' — c limpa)")
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, texto)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = #texto[1], hl_group = "Title" })
    for l, it in pairs(mapa) do
      if type(it) == "table" and it.sistema then
        vim.api.nvim_buf_set_extmark(buf, ns, l - 1, 0, { end_col = #texto[l], hl_group = "Comment" })
      end
    end
    local largura = 50
    for _, l in ipairs(texto) do
      largura = math.max(largura, vim.fn.strdisplaywidth(l))
    end
    local titulo_win = (" %s · %d marcado(s)%s "):format(titulo, #selecionados(), filtro ~= "" and (" · filtro: " .. filtro) or "")
    local rodape = " <Space> marcar · a TODOS · / filtrar · c limpar · <CR> rodar · q cancelar · ? ajuda "
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_config(win, { title = titulo_win, title_pos = "center" })
    else
      win = janela(buf, titulo_win, rodape, math.max(largura, #rodape), #itens + 1)
      vim.wo[win].cursorline = true
    end
  end

  local function alternar_todos()
    local vis, todos_marcados = visiveis(), true
    for _, it in ipairs(vis) do
      if not it.sistema and not marcado[it.valor] then
        todos_marcados = false
      end
    end
    for _, it in ipairs(vis) do
      if not it.sistema then
        marcado[it.valor] = not todos_marcados
      end
    end
    desenhar()
  end

  local function alternar_linha()
    local l = vim.api.nvim_win_get_cursor(win)[1]
    local it = mapa[l]
    if it == "TODOS" then
      return alternar_todos()
    end
    if type(it) == "table" then
      marcado[it.valor] = not marcado[it.valor]
      desenhar()
      pcall(vim.api.nvim_win_set_cursor, win, { math.min(l + 1, vim.api.nvim_buf_line_count(buf)), 0 })
    end
  end

  local function fechar(resultado)
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    vim.schedule(function()
      cb(resultado)
    end)
  end

  local function map(k, fn)
    vim.keymap.set("n", k, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("<Space>", alternar_linha)
  map("x", alternar_linha)
  map("<Tab>", alternar_linha)
  map("a", alternar_todos)
  map("/", function()
    filtro = vim.fn.input("Filtrar por nome: ", filtro)
    desenhar()
    pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
  end)
  map("c", function()
    filtro = ""
    desenhar()
  end)
  map("<CR>", function()
    local sel = selecionados()
    if #sel == 0 then
      return vim.notify("Marque ao menos um (a = TODOS).", vim.log.levels.WARN)
    end
    fechar(sel)
  end)
  map("q", function() fechar(nil) end)
  map("<Esc>", function() fechar(nil) end)
  map("?", function() require("lbd.ajuda").mostrar({ "lote_selecao" }) end)

  desenhar()
end

---------------------------------------------------------------------------
-- Execução e lista de resultados
---------------------------------------------------------------------------
local L -- último lote
local ns_lista = vim.api.nvim_create_namespace("lbd_lote_lista")

function M.eh_do_lote(call_id)
  if not L then
    return false
  end
  for _, a in ipairs(L.alvos) do
    if a.call and a.call.id == call_id then
      return true
    end
  end
  return false
end

local ICONES = { fila = "·", rodando = "⏳", ok = "✔", erro = "✘", cancelado = "⊘" }
local HL = { ok = "DiagnosticOk", erro = "DiagnosticError", rodando = "DiagnosticWarn", cancelado = "Comment", fila = "Comment" }

local function contar()
  local c = { ok = 0, erro = 0, rodando = 0, fila = 0, cancelado = 0 }
  for _, a in ipairs(L.alvos) do
    c[a.estado] = c[a.estado] + 1
  end
  return c
end

local function resumo(call)
  local ok, cab, linhas = pcall(sql.ler, call.id, 0, 1)
  if not ok then
    return "ok"
  end
  if cab[1] == "Rows Affected" then
    return ((linhas[1] or {})[1] or "?") .. " linha(s) afetada(s)"
  end
  if #cab == 0 or cab[1] == "No Results" then
    return L.oracle_bloco and "executado (commit)" or "executado"
  end
  local n = sql.total_linhas(call.id)
  return (n and tostring(n) or "?") .. " linha(s)"
end

local function texto_lista()
  local largura = 10
  for _, a in ipairs(L.alvos) do
    largura = math.max(largura, vim.fn.strdisplaywidth(a.nome))
  end
  local texto, mapa = {}, {}
  table.insert(texto, "Query: " .. (L.query:gsub("%s+", " "):sub(1, 150)))
  table.insert(texto, "")
  for _, a in ipairs(L.alvos) do
    if not L.so_erros or a.estado == "erro" then
      local detalhe = ({
        fila = "na fila",
        rodando = "rodando…",
        cancelado = "não executado (lote parado)",
      })[a.estado] or (a.msg or "")
      detalhe = detalhe:gsub("%s+", " ")
      local tempo = a.tempo and ("%6.2fs  "):format(a.tempo) or "         "
      table.insert(texto, ("%s %s%s  %s%s"):format(ICONES[a.estado], a.nome, string.rep(" ", largura - vim.fn.strdisplaywidth(a.nome)), tempo, detalhe))
      mapa[#texto] = a
    end
  end
  if L.so_erros and #texto == 2 then
    table.insert(texto, "  (nenhum erro)")
  end
  return texto, mapa
end

local function titulo_lista()
  local c = contar()
  local feitos = c.ok + c.erro + c.cancelado
  local fim = L.fim or agora()
  local status = (c.rodando + c.fila == 0) and (L.parado and "parado" or "concluído") or "rodando"
  return (" Lote · %s · %s · %d/%d · ✔ %d  ✘ %d · %.1fs%s "):format(
    L.conn.name, status, feitos, #L.alvos, c.ok, c.erro, fim - L.inicio, L.so_erros and " · só erros" or "")
end

local function desenhar_lista()
  if not (L and L.buf and vim.api.nvim_buf_is_valid(L.buf)) then
    return
  end
  local texto, mapa = texto_lista()
  L.mapa = mapa
  vim.bo[L.buf].modifiable = true
  vim.api.nvim_buf_set_lines(L.buf, 0, -1, false, texto)
  vim.bo[L.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(L.buf, ns_lista, 0, -1)
  vim.api.nvim_buf_set_extmark(L.buf, ns_lista, 0, 0, { end_col = #texto[1], hl_group = "Comment" })
  for l, a in pairs(mapa) do
    vim.api.nvim_buf_set_extmark(L.buf, ns_lista, l - 1, 0, { end_col = #texto[l], hl_group = HL[a.estado] })
  end
  if L.win and vim.api.nvim_win_is_valid(L.win) then
    vim.api.nvim_win_set_config(L.win, { title = titulo_lista(), title_pos = "center" })
  end
end

local function alvo_da_linha()
  return L and L.mapa and L.mapa[vim.api.nvim_win_get_cursor(0)[1]]
end

local function fechar_lista()
  if L and L.win and vim.api.nvim_win_is_valid(L.win) then
    vim.api.nvim_win_close(L.win, true)
  end
end

local function parar()
  if not L or L.fim then
    return
  end
  L.parado = true
  for _, a in ipairs(L.alvos) do
    if a.estado == "fila" then
      a.estado = "cancelado"
    elseif a.estado == "rodando" and a.call then
      pcall(api().core.call_cancel, a.call.id)
    end
  end
  desenhar_lista()
  vim.notify("Lote: parando (as que já estavam rodando serão canceladas).")
end

local function criar_buffer_lista()
  L.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[L.buf].bufhidden = "hide"
  vim.bo[L.buf].filetype = "lbdlote"
  local function map(k, fn)
    vim.keymap.set("n", k, fn, { buffer = L.buf, nowait = true, silent = true })
  end
  map("<CR>", function()
    local a = alvo_da_linha()
    if not a then
      return
    end
    if a.estado == "erro" then
      return require("lbd.ajuda").janela("Erro em " .. a.nome, vim.split(a.msg or "", "\n"))
    end
    if a.estado ~= "ok" or not a.call then
      return vim.notify(a.nome .. ": ainda sem resultado (" .. a.estado .. ").", vim.log.levels.INFO)
    end
    fechar_lista()
    require("dbee").open()
    api().ui.result_set_call(a.call)
    vim.notify(("Resultado de %s — <leader>dl volta para a lista do lote"):format(a.nome))
  end)
  map("e", function()
    local a = alvo_da_linha()
    if a then
      require("lbd.ajuda").janela(a.nome .. " · " .. a.estado, vim.split(a.msg or "(sem mensagem)", "\n"))
    end
  end)
  map("x", function()
    L.so_erros = not L.so_erros
    desenhar_lista()
  end)
  map("y", function()
    local texto = texto_lista()
    table.insert(texto, 1, vim.trim(titulo_lista()))
    vim.fn.setreg(vim.v.register, table.concat(texto, "\n"))
    vim.notify("Resumo do lote copiado.")
  end)
  map("<C-c>", parar)
  map("q", fechar_lista)
  map("<Esc>", fechar_lista)
  map("?", function() require("lbd.ajuda").mostrar({ "lote_lista" }) end)
end

local function abrir_lista()
  if not L then
    return vim.notify("Nenhum lote rodado nesta sessão.", vim.log.levels.INFO)
  end
  if L.win and vim.api.nvim_win_is_valid(L.win) then
    return vim.api.nvim_set_current_win(L.win)
  end
  if not (L.buf and vim.api.nvim_buf_is_valid(L.buf)) then
    criar_buffer_lista()
  end
  desenhar_lista()
  local largura = 60
  for _, l in ipairs(vim.api.nvim_buf_get_lines(L.buf, 0, -1, false)) do
    largura = math.max(largura, vim.fn.strdisplaywidth(l))
  end
  L.win = janela(L.buf, titulo_lista(), " <CR> resultado · e erro · x só erros · y copiar · <C-c> parar · q fechar · ? ajuda ",
    math.min(largura, 140), #L.alvos + 2)
  vim.wo[L.win].cursorline = true
  vim.wo[L.win].wrap = false
  pcall(vim.api.nvim_win_set_cursor, L.win, { 3, 0 })
end

M.reabrir = abrir_lista

local function executar(base, query, nomes)
  local oracle = base.type == "oracle"
  local cmd = sql.comando(query)
  local eh_consulta = cmd == "select" or cmd == "with"
  L = {
    conn = base,
    query = query,
    alvos = {},
    inicio = agora(),
    oracle_bloco = oracle and not eh_consulta,
    so_erros = false,
  }
  for _, n in ipairs(nomes) do
    table.insert(L.alvos, { nome = n, estado = "fila" })
  end
  local este = L
  local workers = abrir_conexoes(base, math.min(PARALELO, #nomes))
  local proxima = 1

  local function concluir_se_acabou()
    for _, a in ipairs(este.alvos) do
      if a.estado == "fila" or a.estado == "rodando" then
        return
      end
    end
    if este.fim then
      return
    end
    este.fim = agora()
    desenhar_lista()
    local c = contar()
    vim.notify(("Lote %s: ✔ %d  ✘ %d%s — <leader>dl abre a lista"):format(
      este.parado and "parado" or "concluído", c.ok, c.erro, c.cancelado > 0 and ("  ⊘ " .. c.cancelado) or ""),
      c.erro > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
  end

  local function seguinte(worker)
    if L ~= este then
      return -- um lote novo substituiu este
    end
    if este.parado then
      return concluir_se_acabou()
    end
    local a = este.alvos[proxima]
    if not a then
      return concluir_se_acabou()
    end
    proxima = proxima + 1
    a.estado = "rodando"
    a.inicio = agora()
    desenhar_lista()

    local function terminar(call, erro)
      a.tempo = agora() - a.inicio
      a.call = call or a.call
      if erro then
        a.estado, a.msg = "erro", erro
      elseif call.state == "archived" then
        a.estado, a.msg = "ok", resumo(call)
      elseif call.state == "canceled" then
        a.estado, a.msg = "cancelado", "cancelado"
      else
        a.estado, a.msg = "erro", call.error or call.state
      end
      desenhar_lista()
      seguinte(worker)
    end

    if oracle and eh_consulta then
      a.call = sql.chamar(worker, ('alter session set current_schema = "%s"'):format(a.nome), function(c)
        if c.state ~= "archived" then
          return terminar(nil, "não entrou no schema: " .. (c.error or c.state))
        end
        if este.parado then
          a.estado = "cancelado"
          desenhar_lista()
          return seguinte(worker)
        end
        a.call = sql.chamar(worker, query, terminar)
      end)
    elseif oracle then
      -- Bloco único: o comando sempre roda no schema certo, com commit explícito.
      -- (o dbee corta o ";" final, por isso o comentário depois do "end;")
      local bloco = ("begin execute immediate 'alter session set current_schema = \"%s\"'; execute immediate '%s'; commit; end; -- lbd")
        :format(a.nome, query:gsub("'", "''"))
      a.call = sql.chamar(worker, bloco, terminar)
    else
      local ok, err = pcall(api().core.connection_select_database, worker, a.nome)
      if not ok then
        return terminar(nil, "não conectou no database: " .. tostring(err))
      end
      a.call = sql.chamar(worker, query, terminar)
    end
  end

  abrir_lista()
  for _, w in ipairs(workers) do
    seguinte(w)
  end
end

---------------------------------------------------------------------------
-- Fluxo do atalho
---------------------------------------------------------------------------
local function conexoes_usuario()
  local lista = {}
  for _, s in ipairs(api().core.get_sources()) do
    for _, c in ipairs(api().core.source_get_connections(s:name()) or {}) do
      if c.type == "oracle" or c.type == "postgres" then
        table.insert(lista, c)
      end
    end
  end
  table.sort(lista, function(a, b)
    return a.name < b.name
  end)
  return lista
end

local function alvos_de(conn)
  local itens = {}
  if conn.type == "oracle" then
    local call = sql.executar(conn.id, "select username from all_users order by username")
    if call.state ~= "archived" then
      vim.notify("Falha ao listar schemas de " .. conn.name .. ": " .. (call.error or call.state), vim.log.levels.ERROR)
      return nil
    end
    local _, linhas = sql.ler(call.id)
    for _, l in ipairs(linhas) do
      table.insert(itens, { valor = l[1], sistema = SISTEMA_ORACLE[l[1]] == true })
    end
  else
    local ok, atual, dbs = pcall(api().core.connection_list_databases, conn.id)
    if not ok then
      vim.notify("Falha ao listar databases de " .. conn.name .. ": " .. tostring(atual), vim.log.levels.ERROR)
      return nil
    end
    local vistos = {}
    for _, d in ipairs(vim.list_extend({ atual }, dbs or {})) do
      if d and d ~= "" and not vistos[d] then
        vistos[d] = true
        table.insert(itens, { valor = d, sistema = false })
      end
    end
    table.sort(itens, function(a, b)
      return a.valor < b.valor
    end)
  end
  -- sistema por último
  table.sort(itens, function(a, b)
    if a.sistema ~= b.sistema then
      return not a.sistema
    end
    return a.valor < b.valor
  end)
  return itens
end

-- Query a usar: seleção visual ou bloco sob o cursor (como o <CR> do editor)
local function query_do_editor()
  local modo = vim.fn.mode()
  if modo == "v" or modo == "V" or modo == "\22" then
    local partes = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = modo })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    return table.concat(partes, "\n")
  end
  return require("lbd.completar").query_atual(0, vim.api.nvim_win_get_cursor(0)[1])
end

function M.iniciar(query)
  if L and not L.fim then
    vim.notify("Já existe um lote rodando — <leader>dl abre a lista (<C-c> nela para parar).", vim.log.levels.WARN)
    return
  end
  query = sql.limpar(query or query_do_editor())
  if query == "" then
    return vim.notify("Nenhuma query sob o cursor (ou selecionada).", vim.log.levels.WARN)
  end

  local previa = { "Rodar esta query em VÁRIAS bases (schemas/databases)?", "" }
  for i, l in ipairs(vim.split(query, "\n")) do
    if i > 12 then
      table.insert(previa, "  …")
      break
    end
    table.insert(previa, "  " .. l)
  end
  confirmar("Rodar em várias bases", previa, function(sim)
    if not sim then
      return
    end
    local conns = conexoes_usuario()
    vim.ui.select(conns, {
      prompt = "Em qual servidor?",
      format_item = function(c)
        return ("%s  (%s)"):format(c.name, c.type)
      end,
    }, function(conn)
      if not conn then
        return
      end
      local itens = alvos_de(conn)
      if not itens then
        return
      end
      local tipo = conn.type == "oracle" and "schemas" or "databases"
      selecionar(("Escolha os %s · %s"):format(tipo, conn.name), itens, function(nomes)
        if not nomes then
          return
        end
        local cmd = sql.comando(query)
        if cmd ~= "select" and cmd ~= "with" then
          local resp = vim.fn.input(("ATENÇÃO: %s será executado e EFETIVADO (commit) em %d %s de %s.\nDigite SIM para confirmar: ")
            :format(cmd:upper(), #nomes, tipo, conn.name))
          if resp ~= "SIM" then
            return vim.notify("Lote cancelado.", vim.log.levels.INFO)
          end
        end
        executar(conn, query, nomes)
      end)
    end)
  end)
end

return M
