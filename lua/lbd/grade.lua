-- lbd: grade de resultado montada pelo lbd (no lugar da tabela do backend Go do dbee) + painel de valor.
--   * cada célula numa linha só, cortada em MAX colunas ("…"); quebra de linha vira "⏎"
--   * XML/JSON grande vira "‹XML 12,1 KB› <tag raiz>" (a tabela original punha o XML inteiro: 40 MB por página)
--   * cores: cabeçalho, <nil>, resumo de XML/JSON e "…"; fundo alternado nas linhas; coluna sob o cursor
--   * cabeçalho fixo: ao rolar, os nomes das colunas continuam no topo (acompanha a rolagem lateral)
--   * barra: "conexão › database/schema" antes da paginação do dbee
--   * <leader>z: maximiza a grade (editor reduzido a 1 linha); entrar no editor desfaz
--   * painel flutuante no canto superior direito do editor (janela acima da grade) com o valor inteiro
--     da célula sob o cursor: abre sozinho numa célula cortada e acompanha o cursor; some fora da grade
--   * busca feita no painel fica guardada e é reaplicada a cada troca de registro
-- Cópias (yac/yaj...), order by (o/O) e modo registro continuam lendo o valor completo do dbee.
local M = {}

local MAX = 50
local ATRASO_MS = 100
local RODAPE_FORA = " <C-l> entra · / busca · Y copia tudo · K fecha "
local RODAPE_DENTRO = " <C-h> sai · / busca (fica guardada) · Y copia tudo · <Esc> limpa a busca "

local ns = vim.api.nvim_create_namespace("lbd_grade")
local ns_coluna = vim.api.nvim_create_namespace("lbd_grade_coluna")

-- bufnr da grade -> { call_id, from, total, cab, linhas, inicios, celulas }
--   inicios[i]   = coluna de tela onde começa a coluna i (no "│" que a antecede)
--   celulas[l][i] = { ini, fim } em bytes (0-based, fim exclusivo) do espaço da coluna i na linha l do buffer
local paginas = {}

-- estado do painel
local P = {
  buf = nil, win = nil, grade = nil, -- janela da grade que abriu o painel
  desligado = false, -- K desligou: não abre sozinho
  ativo = false, -- já abriu nesta grade (passa a acompanhar qualquer coluna)
  busca = nil, match = nil,
  chave = nil, valor = "", titulo = "",
}
local cache_fmt = {}
local timer

-- cabeçalho fixo (por janela da grade) e coluna destacada
local fixos = {} -- win da grade -> { win, buf }
local coluna_atual = {} -- bufnr -> col destacada

-- maximizar
local Z = { ativo = false }

-- winbar original do dbee por janela (antes do prefixo do lbd)
local barras = {}
local MARCA = "%#LbdBarraConexao#"

local function eh_resultado(bufnr)
  return vim.api.nvim_buf_get_name(bufnr or 0):match("dbee%-result") ~= nil
end

---------------------------------------------------------------------------
-- Cores (acompanham o tema)
---------------------------------------------------------------------------
local function misturar(a, b, t)
  local function canal(c, s)
    return math.floor(c / 2 ^ s) % 256
  end
  local r = 0
  for _, s in ipairs({ 16, 8, 0 }) do
    local v = math.floor(canal(a, s) * (1 - t) + canal(b, s) * t + 0.5)
    r = r + v * 2 ^ s
  end
  return r
end

local function cores()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local titulo = vim.api.nvim_get_hl(0, { name = "Title", link = false })
  local hl = vim.api.nvim_set_hl
  hl(0, "LbdGradeCabecalho", { fg = titulo.fg, bold = true, default = true })
  hl(0, "LbdGradeNulo", { link = "Comment", default = true })
  hl(0, "LbdGradeCorte", { link = "Comment", default = true })
  hl(0, "LbdGradeResumo", { link = "Special", default = true })
  hl(0, "LbdGradeSeparador", { link = "NonText", default = true })
  hl(0, "LbdBarraConexao", { fg = titulo.fg, bold = true, default = true })
  if normal.bg and normal.fg then
    hl(0, "LbdGradeZebra", { bg = misturar(normal.bg, normal.fg, 0.04), default = true })
    hl(0, "LbdGradeColuna", { bg = misturar(normal.bg, normal.fg, 0.10), default = true })
  else -- tema transparente: sem cor de fundo para misturar
    hl(0, "LbdGradeZebra", { link = "CursorLine", default = true })
    hl(0, "LbdGradeColuna", { link = "Visual", default = true })
  end
end

---------------------------------------------------------------------------
-- Células
---------------------------------------------------------------------------
local function tamanho(n)
  if n < 1024 then
    return n .. " B"
  elseif n < 1024 * 1024 then
    return (("%.1f KB"):format(n / 1024):gsub("%.", ","))
  end
  return (("%.1f MB"):format(n / 1024 / 1024):gsub("%.", ","))
end

local function tipo_de(v)
  local c = v:match("^%s*(.)")
  if c == "<" and v:find(">", 1, true) then
    return "xml"
  elseif (c == "{" or c == "[") and #v > 1 then
    return "json"
  end
end

local function cortar(s, max)
  if vim.api.nvim_strwidth(s) <= max then
    return s
  end
  s = vim.fn.strcharpart(s, 0, max - 1)
  while vim.api.nvim_strwidth(s) > max - 1 do
    s = vim.fn.strcharpart(s, 0, vim.fn.strchars(s) - 1)
  end
  return s .. "…"
end

-- Texto da célula na grade e se ela foi resumida/cortada
local function celula(v)
  if v == nil or v == "" then
    return "", false
  end
  local longo = #v > MAX or v:find("[\r\n\t]") ~= nil
  if not longo then
    return v, false
  end
  local tipo = #v > MAX and tipo_de(v)
  local s
  if tipo == "xml" then
    local inicio = v:sub(1, 4000):gsub("^%s*<%?xml.-%?>", ""):gsub("%s+", " ")
    s = ("‹XML %s› %s"):format(tamanho(#v), inicio:match("<[^>]*>") or "")
  elseif tipo == "json" then
    s = ("‹JSON %s› %s"):format(tamanho(#v), (v:sub(1, 400):gsub("%s+", " ")))
  else
    s = v:sub(1, MAX * 4):gsub("\r?\n", "⏎"):gsub("[\r\t]", " ")
  end
  return cortar(s, MAX), true
end

local function preencher(s, largura)
  return s .. string.rep(" ", largura - vim.api.nvim_strwidth(s))
end

-- Monta as linhas da grade no mesmo formato da tabela do dbee (" n │ col │ col"),
-- para o order by, o modo registro e as cópias do dbee continuarem achando linha/coluna.
-- Devolve também as posições das células (cores e coluna destacada).
local function montar(cab, linhas, from)
  local ncol = #cab
  local textos, larguras = {}, {}
  larguras[0] = #tostring(from + #linhas)
  for i = 1, ncol do
    larguras[i] = vim.api.nvim_strwidth(cab[i])
  end
  for r, l in ipairs(linhas) do
    textos[r] = {}
    for i = 1, ncol do
      local t = celula(l[i])
      textos[r][i] = t
      larguras[i] = math.max(larguras[i], vim.api.nvim_strwidth(t))
    end
  end

  local inicios, pos = {}, larguras[0] + 3
  for i = 1, ncol do
    inicios[i] = pos
    pos = pos + larguras[i] + 3
  end

  -- linha + { [i] = { ini, fim, texto_ini, texto_fim } } em bytes
  local function linha(indice, celulas)
    local s = " " .. indice .. " "
    local partes, spans, b = { s }, {}, #s
    for i = 1, ncol do
      b = b + #"│"
      local cel = " " .. preencher(celulas[i], larguras[i]) .. " "
      spans[i] = { b, b + #cel, b + 1, b + 1 + #celulas[i] }
      partes[#partes + 1] = cel
      b = b + #cel
    end
    local texto = table.concat(partes, "│"):gsub("%s+$", "")
    for _, sp in ipairs(spans) do
      sp[2] = math.min(sp[2], #texto)
    end
    return texto, spans
  end

  local out, celulas = {}, {}
  out[1], celulas[1] = linha(string.rep(" ", larguras[0]), cab)
  local sep = { string.rep("─", larguras[0] + 2) }
  for i = 1, ncol do
    sep[#sep + 1] = string.rep("─", larguras[i] + 2)
  end
  out[2] = table.concat(sep, "┼")
  for r = 1, #linhas do
    local n = tostring(from + r)
    out[r + 2], celulas[r + 2] = linha(string.rep(" ", larguras[0] - #n) .. n, textos[r])
  end
  return out, inicios, celulas, textos
end

-- Cores do cabeçalho (também usadas no cabeçalho fixo)
local function pintar_cabecalho(buf, spans)
  for _, sp in ipairs(spans) do
    if sp[4] > sp[3] then
      vim.api.nvim_buf_set_extmark(buf, ns, 0, sp[3], { end_col = sp[4], hl_group = "LbdGradeCabecalho", priority = 70 })
    end
  end
end

local function pintar(buf, pg, textos)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  pintar_cabecalho(buf, pg.celulas[1])
  for r, linha in ipairs(pg.linhas) do
    local l = r + 1 -- 0-based no buffer
    if r % 2 == 0 then
      vim.api.nvim_buf_set_extmark(buf, ns, l, 0, { line_hl_group = "LbdGradeZebra", priority = 50 })
    end
    for i, sp in ipairs(pg.celulas[r + 2]) do
      local t = textos[r][i]
      local grupo
      if linha[i] == "<nil>" then
        grupo = "LbdGradeNulo"
      elseif t:sub(1, #"‹") == "‹" then
        local fim = t:find("›", 1, true)
        if fim then
          vim.api.nvim_buf_set_extmark(buf, ns, l, sp[3], { end_col = sp[3] + fim + #"›" - 1, hl_group = "LbdGradeResumo", priority = 70 })
        end
      end
      if grupo then
        vim.api.nvim_buf_set_extmark(buf, ns, l, sp[3], { end_col = sp[4], hl_group = grupo, priority = 70 })
      elseif t:sub(-#"…") == "…" then
        vim.api.nvim_buf_set_extmark(buf, ns, l, sp[4] - #"…", { end_col = sp[4], hl_group = "LbdGradeCorte", priority = 70 })
      end
    end
  end
end

---------------------------------------------------------------------------
-- Barra: "conexão › database/schema · <paginação do dbee>"
---------------------------------------------------------------------------
local function onde()
  local ok, conn = pcall(function()
    return require("dbee.api").core.get_current_connection()
  end)
  if not ok or not conn then
    return nil
  end
  local base
  pcall(function()
    base = require("lbd.completar").escopo_atual(conn.id)
  end)
  if not base and conn.type == "postgres" and conn.url then
    base = conn.url:match("^%a+://[^/]*/([^?/]+)")
  end
  local nome = conn.name:match("^(%S+)") or conn.name
  return nome, base
end

local function esc(s)
  return (s:gsub("%%", "%%%%"))
end

local function atualizar_barra(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local atual = vim.wo[win].winbar or ""
  if atual:sub(1, #MARCA) ~= MARCA then
    barras[win] = atual -- o dbee acabou de escrever a dele
  end
  local dbee = barras[win] or ""
  if dbee == "" then
    return
  end
  local nome, base = onde()
  if not nome then
    return
  end
  local prefixo = MARCA .. esc(nome) .. "%*" .. (base and (" › " .. esc(base)) or "") .. " · "
  if Z.ativo then
    dbee = dbee:gsub("%%=", " · ⤢ maximizado%%=", 1)
  end
  vim.wo[win].winbar = prefixo .. dbee
end

---------------------------------------------------------------------------
-- Coluna sob o cursor e cabeçalho fixo
---------------------------------------------------------------------------
local function coluna_em(win)
  local pg = paginas[vim.api.nvim_win_get_buf(win)]
  if not pg then
    return nil
  end
  local tela = vim.api.nvim_win_call(win, function()
    return vim.fn.virtcol(".")
  end)
  local col
  for i, ini in ipairs(pg.inicios) do
    if tela >= ini then
      col = i
    end
  end
  return col, pg
end

local function destacar(buf, pg, col, so_cabecalho)
  vim.api.nvim_buf_clear_namespace(buf, ns_coluna, 0, -1)
  if not col then
    return
  end
  for l, spans in pairs(pg.celulas) do
    if l == 1 or not so_cabecalho then
      local sp = spans[col]
      if sp and sp[2] > sp[1] then
        vim.api.nvim_buf_set_extmark(buf, ns_coluna, l - 1, sp[1], { end_col = sp[2], hl_group = "LbdGradeColuna", priority = 60 })
      end
    end
  end
end

local function fechar_fixo(win)
  local f = fixos[win]
  if f and f.win and vim.api.nvim_win_is_valid(f.win) then
    vim.api.nvim_win_close(f.win, true)
  end
  if f then
    f.win = nil
  end
end

local function atualizar_fixo(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local pg = paginas[buf]
  local topo = vim.fn.line("w0", win)
  if not pg or topo <= 2 then
    return fechar_fixo(win)
  end
  local f = fixos[win] or {}
  fixos[win] = f
  if not (f.buf and vim.api.nvim_buf_is_valid(f.buf)) then
    f.buf = vim.api.nvim_create_buf(false, true)
  end
  vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, vim.api.nvim_buf_get_lines(buf, 0, 2, false))
  vim.api.nvim_buf_clear_namespace(f.buf, ns, 0, -1)
  pintar_cabecalho(f.buf, pg.celulas[1])
  destacar(f.buf, { celulas = { pg.celulas[1] } }, coluna_atual[buf], true)

  -- posição absoluta (relative="win" desloca a coluna quando a janela não começa na borda esquerda)
  local info = vim.fn.getwininfo(win)[1]
  local cfg = {
    relative = "editor", row = info.winrow - 1 + info.winbar, col = info.wincol - 1 + info.textoff,
    width = math.max(1, info.width - info.textoff), height = 2,
    style = "minimal", focusable = false, zindex = 40,
  }
  if f.win and vim.api.nvim_win_is_valid(f.win) then
    vim.api.nvim_win_set_config(f.win, cfg)
  else
    f.win = vim.api.nvim_open_win(f.buf, false, cfg)
    vim.wo[f.win].wrap = false
    vim.api.nvim_win_call(f.win, function()
      vim.fn.matchadd("LbdGradeSeparador", [[─\|│\|┼]])
    end)
  end
  local esquerda = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().leftcol
  end)
  vim.api.nvim_win_call(f.win, function()
    vim.fn.winrestview({ leftcol = esquerda, topline = 1, lnum = 1 })
  end)
end

local function atualizar_coluna(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local col, pg = coluna_em(win)
  if not pg then
    return
  end
  if coluna_atual[buf] ~= col then
    coluna_atual[buf] = col
    destacar(buf, pg, col, false)
    local f = fixos[win]
    if f and f.win and vim.api.nvim_win_is_valid(f.win) then
      destacar(f.buf, { celulas = { pg.celulas[1] } }, col, true)
    end
  end
end

---------------------------------------------------------------------------
-- Substitui a renderização da página do dbee
---------------------------------------------------------------------------
local function instalar()
  local Handler = require("dbee.handler")
  if Handler._lbd_grade then
    return
  end
  local original = Handler.call_display_result
  Handler._lbd_grade = original
  function Handler:call_display_result(id, bufnr, from, to)
    -- contagem (0 linhas) e buffers que não são a grade: comportamento original
    if to - from <= 0 or not eh_resultado(bufnr) then
      return original(self, id, bufnr, from, to)
    end
    local ok, total = pcall(function()
      local cab, linhas = require("lbd.sql").ler(id, from, to)
      local texto, inicios, celulas, textos = montar(cab, linhas, from)
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, texto)
      vim.bo[bufnr].modifiable = false
      local n = require("lbd.sql").total_linhas(id) or (from + #linhas)
      local pg = { call_id = id, from = from, total = n, cab = cab, linhas = linhas, inicios = inicios, celulas = celulas }
      paginas[bufnr] = pg
      pintar(bufnr, pg, textos)
      coluna_atual[bufnr] = nil
      return n
    end)
    if not ok then
      vim.notify("lbd: grade própria falhou, usando a do dbee: " .. tostring(total), vim.log.levels.WARN)
      paginas[bufnr] = nil
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      return original(self, id, bufnr, from, to)
    end
    -- o dbee escreve a winbar depois que esta função retorna
    vim.schedule(function()
      local w = vim.fn.bufwinid(bufnr)
      if w ~= -1 then
        atualizar_barra(w)
        atualizar_coluna(w)
        atualizar_fixo(w)
      end
      M.atualizar()
    end)
    return total
  end
end

---------------------------------------------------------------------------
-- Maximizar (<leader>z)
---------------------------------------------------------------------------
local function janela_editor(grade)
  local id = vim.api.nvim_win_call(grade, function()
    return vim.fn.win_getid(vim.fn.winnr("k"))
  end)
  if id ~= 0 and id ~= grade then
    return id
  end
end

local function restaurar()
  if not Z.ativo then
    return
  end
  Z.ativo = false
  if Z.editor and vim.api.nvim_win_is_valid(Z.editor) then
    pcall(vim.api.nvim_win_set_height, Z.editor, Z.altura_editor)
  end
  atualizar_barra(Z.grade)
  if Z.grade and vim.api.nvim_win_is_valid(Z.grade) then
    vim.schedule(function()
      atualizar_fixo(Z.grade)
    end)
  end
end

function M.maximizar()
  local grade = vim.api.nvim_get_current_win()
  if Z.ativo then
    return restaurar()
  end
  local editor = janela_editor(grade)
  if not editor then
    return vim.notify("Não achei o editor acima da grade.", vim.log.levels.WARN)
  end
  Z.ativo, Z.grade, Z.editor, Z.altura_editor = true, grade, editor, vim.api.nvim_win_get_height(editor)
  vim.api.nvim_win_set_height(editor, 1)
  atualizar_barra(grade)
  vim.schedule(function()
    atualizar_fixo(grade)
    M.atualizar()
  end)
end

---------------------------------------------------------------------------
-- Painel de valor
---------------------------------------------------------------------------

-- Registro e coluna sob o cursor na grade
local function sob_cursor(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local pg = paginas[buf]
  if not pg then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local n = tonumber((vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""):match("^%s*(%d+)%s*│"))
  if not n then
    return nil
  end
  local linha = pg.linhas[n - pg.from]
  local col = coluna_em(win)
  if not linha or not col then
    return nil
  end
  return { pg = pg, n = n, col = col, valor = linha[col] or "" }
end

local PY = {
  xml = "import sys,xml.dom.minidom as m\ns=sys.stdin.read()\nprint(m.parseString(s.encode()).toprettyxml(indent='  '))",
  json = "import sys,json\nprint(json.dumps(json.loads(sys.stdin.read()),indent=2,ensure_ascii=False))",
}

-- Valor inteiro pronto para ler: XML/JSON de uma linha só são indentados (python3); o resto vai como está
local function formatado(valor, tipo)
  local texto = valor
  if PY[tipo] and not (tipo == "xml" and valor:find("\n")) then
    local ok, r = pcall(function()
      return vim.system({ "python3", "-I", "-c", PY[tipo] }, { stdin = valor, text = true }):wait(3000)
    end)
    if ok and r.code == 0 and r.stdout ~= "" then
      texto = r.stdout
    end
  end
  local linhas = vim.split((texto:gsub("\r", "")), "\n", { plain = true })
  while #linhas > 1 and linhas[#linhas] == "" do
    linhas[#linhas] = nil
  end
  return linhas
end

local function padrao(busca)
  if vim.o.ignorecase and not (vim.o.smartcase and busca:find("%u")) then
    return "\\c" .. busca
  end
  return busca
end

local function dentro()
  return P.win and vim.api.nvim_get_current_win() == P.win
end

-- Canto superior direito do editor; com a grade maximizada (editor com 1 linha), da própria grade
local function config(editor, grade)
  local alvo = vim.api.nvim_win_get_height(editor) >= 8 and editor or grade
  local w = vim.api.nvim_win_get_width(alvo)
  local h = vim.api.nvim_win_get_height(alvo)
  local pos = vim.api.nvim_win_get_position(alvo)
  return {
    relative = "editor",
    anchor = "NE",
    row = pos[1],
    col = pos[2] + w,
    width = math.min(math.max(40, math.floor(w * 0.6)), w - 2),
    height = math.max(3, (alvo == editor) and (h - 2) or math.floor(h * 0.6)),
    border = "rounded",
    title = P.titulo,
    title_pos = "center",
    footer = dentro() and RODAPE_DENTRO or RODAPE_FORA,
    footer_pos = "center",
    focusable = true,
    zindex = 45,
  }
end

local function fechar_janela()
  if P.win and vim.api.nvim_win_is_valid(P.win) then
    vim.api.nvim_win_close(P.win, true)
  end
  P.win, P.match = nil, nil
end

local function voltar()
  if P.grade and vim.api.nvim_win_is_valid(P.grade) then
    vim.api.nvim_set_current_win(P.grade)
  end
end

local function aplicar_busca(contar_so)
  if not (P.win and vim.api.nvim_win_is_valid(P.win)) then
    return
  end
  local total = 0
  vim.api.nvim_win_call(P.win, function()
    if P.match then
      pcall(vim.fn.matchdelete, P.match)
      P.match = nil
    end
    if not P.busca or P.busca == "" then
      return
    end
    P.match = vim.fn.matchadd("Search", padrao(P.busca), 10)
    if not contar_so then
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      if vim.fn.search(P.busca, "cW") > 0 then
        vim.cmd("normal! zz")
      end
    end
    local ok, sc = pcall(vim.fn.searchcount, { pattern = P.busca, maxcount = 9999, recompute = true })
    total = ok and sc.total or 0
  end)
  local titulo = P.titulo
  if P.busca and P.busca ~= "" then
    titulo = titulo .. ("· /%s: %d ocorrência%s "):format(P.busca, total, total == 1 and "" or "s")
  end
  vim.api.nvim_win_set_config(P.win, { title = titulo, title_pos = "center" })
end

local function criar_buffer()
  if P.buf and vim.api.nvim_buf_is_valid(P.buf) then
    return
  end
  P.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[P.buf].bufhidden = "hide"
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = P.buf, nowait = true, silent = true, desc = desc })
  end
  map("<C-h>", voltar, "Painel: voltar para a grade")
  map("q", voltar, "Painel: voltar para a grade")
  map("Y", function()
    vim.fn.setreg(vim.v.register, P.valor)
    vim.notify(("Valor copiado (%s)."):format(tamanho(#P.valor)))
  end, "Painel: copiar o valor inteiro")
  map("<Esc>", function()
    P.busca = nil
    vim.cmd("nohlsearch")
    aplicar_busca(true)
  end, "Painel: limpar a busca guardada")
end

local function mostrar(info, grade)
  local editor = janela_editor(grade)
  if not editor then
    return
  end
  P.grade = grade
  local chave = ("%s:%d:%d"):format(info.pg.call_id, info.n, info.col)
  local tipo = tipo_de(info.valor)
  local nome = info.pg.cab[info.col] or "?"
  P.titulo = (" Registro %d/%d · %s · %s "):format(info.n, info.pg.total or 0, nome, tamanho(#info.valor))

  criar_buffer()
  if chave ~= P.chave then
    P.chave, P.valor = chave, info.valor
    if not cache_fmt[chave] then
      cache_fmt[chave] = formatado(info.valor, tipo)
    end
    vim.bo[P.buf].modifiable = true
    vim.api.nvim_buf_set_lines(P.buf, 0, -1, false, cache_fmt[chave])
    vim.bo[P.buf].modifiable = false
    vim.bo[P.buf].filetype = tipo or "text"
  end

  local cfg = config(editor, grade)
  if P.win and vim.api.nvim_win_is_valid(P.win) then
    vim.api.nvim_win_set_config(P.win, cfg)
  else
    P.win = vim.api.nvim_open_win(P.buf, false, cfg)
    vim.wo[P.win].wrap = false
    vim.wo[P.win].cursorline = true
    vim.wo[P.win].number = false
    vim.wo[P.win].relativenumber = false
    vim.wo[P.win].signcolumn = "no"
    P.match = nil
  end
  aplicar_busca(false)
end

-- Chamado ao mover o cursor na grade (com atraso) e ao trocar de página
function M.atualizar()
  local win = vim.api.nvim_get_current_win()
  if P.desligado or not eh_resultado(vim.api.nvim_win_get_buf(win)) then
    return
  end
  local info = sob_cursor(win)
  if not info then
    return
  end
  if not P.ativo then
    if not select(2, celula(info.valor)) then
      return
    end
    P.ativo = true
  end
  mostrar(info, win)
end

function M.alternar()
  if P.win and vim.api.nvim_win_is_valid(P.win) then
    P.desligado, P.ativo = true, false
    fechar_janela()
    vim.notify("Painel de valor desligado (K liga de novo).")
    return
  end
  P.desligado, P.ativo = false, true
  M.atualizar()
end

function M.entrar()
  if P.win and vim.api.nvim_win_is_valid(P.win) then
    vim.api.nvim_set_current_win(P.win)
  else
    vim.notify("Painel fechado: pare o cursor numa célula cortada ou use K.", vim.log.levels.INFO)
  end
end

function M.setup()
  instalar()
  cores()
  local g = vim.api.nvim_create_augroup("lbd_grade", { clear = true })

  vim.api.nvim_create_autocmd("ColorScheme", { group = g, callback = cores })

  vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter" }, {
    group = g,
    callback = function(ev)
      if not eh_resultado(ev.buf) then
        return
      end
      local function map(lhs, fn, desc)
        vim.keymap.set("n", lhs, fn, { buffer = ev.buf, nowait = true, silent = true, desc = desc })
      end
      map("K", M.alternar, "Resultado: ligar/desligar o painel de valor")
      map("<C-l>", M.entrar, "Resultado: entrar no painel de valor")
      map("<leader>z", M.maximizar, "Resultado: maximizar/restaurar a grade")
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = g,
    callback = function(ev)
      if not eh_resultado(ev.buf) then
        return
      end
      atualizar_coluna(vim.api.nvim_get_current_win())
      timer = timer or vim.uv.new_timer()
      timer:stop()
      timer:start(ATRASO_MS, 0, vim.schedule_wrap(M.atualizar))
    end,
  })

  -- cabeçalho fixo acompanha a rolagem (vertical e lateral) e o tamanho da janela
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
    group = g,
    callback = function()
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if eh_resultado(vim.api.nvim_win_get_buf(w)) then
          atualizar_fixo(w)
        end
      end
      if P.win and vim.api.nvim_win_is_valid(P.win) and P.grade and vim.api.nvim_win_is_valid(P.grade) then
        local editor = janela_editor(P.grade)
        if editor then
          vim.api.nvim_win_set_config(P.win, config(editor, P.grade))
          aplicar_busca(true)
        end
      end
    end,
  })

  -- painel some quando o foco vai para fora da grade (editar o SQL), volta ao retornar à grade;
  -- entrar no editor também desfaz o maximizar
  vim.api.nvim_create_autocmd("WinEnter", {
    group = g,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if win == P.win then
        vim.api.nvim_win_set_config(P.win, { footer = RODAPE_DENTRO, footer_pos = "center" })
        return
      end
      if Z.ativo and win == Z.editor then
        restaurar()
      end
      if eh_resultado(vim.api.nvim_win_get_buf(win)) then
        if P.win and vim.api.nvim_win_is_valid(P.win) then
          vim.api.nvim_win_set_config(P.win, { footer = RODAPE_FORA, footer_pos = "center" })
        end
        vim.schedule(M.atualizar)
      else
        fechar_janela()
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = g,
    callback = function(ev)
      local w = tonumber(ev.match)
      if w == P.grade then
        fechar_janela()
      end
      if fixos[w] then
        fechar_fixo(w)
        fixos[w] = nil
      end
      barras[w] = nil
      if Z.ativo and (w == Z.grade or w == Z.editor) then
        Z.ativo = false
      end
    end,
  })

  -- busca feita no painel fica guardada
  vim.api.nvim_create_autocmd("CmdlineLeave", {
    group = g,
    pattern = { "/", "?" },
    callback = function()
      if not dentro() or vim.v.event.abort then
        return
      end
      local termo = vim.fn.getcmdline()
      if termo ~= "" then
        P.busca = termo
        vim.schedule(function()
          aplicar_busca(true)
        end)
      end
    end,
  })
end

-- para testes
M._montar, M._celula, M._estado, M._fixos, M._Z = montar, celula, P, fixos, Z

return M
