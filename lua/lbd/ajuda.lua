-- lbd: ajuda de atalhos. Fonte única usada por:
--   * nó "help" da árvore do Dbee (substitui o help padrão, que só listava a árvore)
--   * "?" na grade de resultado e no modo registro
--   * :BancoAjuda
local M = {}

-- Ações padrão da árvore do dbee traduzidas (a lista real vem da config de mappings do drawer)
local ACOES_ARVORE = {
  refresh = "atualizar a árvore",
  action_1 = "abrir nota / executar helper / trocar database",
  action_2 = "ativar conexão / renomear nota",
  action_3 = "apagar nota ou conexão",
  toggle = "expandir/recolher",
  collapse = "recolher",
  expand = "expandir",
  menu_confirm = "menu: confirmar",
  menu_yank = "menu: copiar",
  menu_close = "menu: fechar",
}

local SECOES = {
  {
    id = "geral",
    titulo = "Geral (qualquer janela)",
    itens = {
      { "<leader>D", "abrir/fechar o Dbee" },
      { "<leader>ds", "selecionar database (PG) / schema (Oracle)" },
      { "<leader>SK", "modo registro da linha do resultado" },
      { "<leader>dc", "colunas de uma tabela (busca) + Java/Hibernate" },
      { "<leader>dC", "colunas da tabela sob o cursor" },
      { "<leader>da", "rodar a query em várias bases (lote)" },
      { "<leader>dl", "reabrir a lista do último lote" },
      { ":BancoSelecionar", "mesmo que <leader>ds" },
      { ":BancoColunas [tabela]", "mesmo que <leader>dc" },
      { ":BancoLote / :BancoLoteLista", "mesmo que <leader>da / <leader>dl" },
      { ":BancoRecarregarAutocomplete", "recarregar tabelas/colunas" },
      { ":BancoAjuda", "esta ajuda" },
    },
  },
  {
    id = "editor",
    titulo = "Editor de SQL",
    itens = {
      { "<CR>", "rodar o bloco sob o cursor (até linha em branco)" },
      { "BB", "rodar a nota inteira (normal)" },
      { "BB (visual)", "rodar só a seleção" },
      { "BQ", "rodar a query sob o cursor (até o ; ou / do PL/SQL)" },
      { "<leader>cf", "formatar o SQL (dialeto da conexão ativa)" },
      { "autocomplete", "tabelas do schema atual; colunas das tabelas do FROM" },
      { "alias.", "colunas só daquela tabela/alias" },
    },
  },
  {
    id = "resultado",
    titulo = "Grade de resultado",
    itens = {
      { "o", "order by na coluna sob o cursor (de novo: asc/desc)" },
      { "O", "desfazer o order by" },
      { "<leader>SK", "modo registro (Coluna: valor) da linha" },
      { "L / H", "próxima / página anterior" },
      { "F / E", "primeira / última página" },
      { "yac / yaj", "copiar linha (CSV / JSON)" },
      { "yaC / yaJ", "copiar tudo (CSV / JSON)" },
      { "<C-c>", "cancelar a query" },
      { "?", "esta ajuda" },
    },
  },
  {
    id = "registro",
    titulo = "Modo registro (<leader>SK)",
    itens = {
      { "n / p", "próximo / registro anterior" },
      { "s", "alternar colunas A→Z / ordem original" },
      { "yv", "copiar o valor da linha" },
      { "q / <Esc>", "fechar" },
      { "?", "esta ajuda" },
    },
  },
  {
    id = "colunas",
    titulo = "Colunas da tabela (<leader>dc)",
    itens = {
      { "/  n / N", "buscar (buffer normal)" },
      { "s", "ordenar: original → nome A→Z → nome Z→A" },
      { "v / V / <C-v> + y", "copiar seleção (<C-v> = bloco, p/ pegar uma coluna)" },
      { "yA", "copiar tudo" },
      { "yj", "copiar o campo Java da coluna sob o cursor" },
      { "yJ", "copiar todos os campos Java" },
      { "t", "trocar de tabela" },
      { "q / <Esc>", "fechar" },
      { "?", "esta ajuda" },
    },
  },
  {
    id = "lote_selecao",
    titulo = "Lote: escolher schemas/databases",
    itens = {
      { "<Space> / x", "marcar/desmarcar a linha" },
      { "a", "TODOS (os visíveis, exceto sistema)" },
      { "/", "filtrar por nome" },
      { "c", "limpar o filtro" },
      { "<CR>", "rodar nos marcados" },
      { "q / <Esc>", "cancelar" },
      { "?", "esta ajuda" },
    },
  },
  {
    id = "lote_lista",
    titulo = "Lote: lista de resultados",
    itens = {
      { "<CR>", "abrir o resultado daquela base" },
      { "e", "ver o erro completo" },
      { "x", "mostrar só os erros / todos" },
      { "y", "copiar o resumo" },
      { "<C-c>", "parar o lote (cancela o que falta)" },
      { "q / <Esc>", "fechar (o lote continua; <leader>dl reabre)" },
      { "?", "esta ajuda" },
    },
  },
}

local function secao_arvore(mappings)
  local itens = {}
  for _, km in ipairs(mappings or {}) do
    if type(km.action) == "string" then
      local modo = km.mode ~= "n" and km.mode ~= "" and (" (" .. km.mode .. ")") or ""
      table.insert(itens, { km.key .. modo, ACOES_ARVORE[km.action] or km.action })
    end
  end
  return { id = "arvore", titulo = "Árvore (esta janela)", itens = itens }
end

local function secoes(mappings)
  local lista = vim.deepcopy(SECOES)
  if mappings then
    table.insert(lista, 2, secao_arvore(mappings))
  end
  return lista
end

local function linha(tecla, desc, largura)
  return tecla .. string.rep(" ", math.max(1, largura - vim.fn.strdisplaywidth(tecla))) .. desc
end

---Substitui o nó "help" da árvore do dbee por um com todas as seções
function M.setup()
  local convert = require("dbee.ui.drawer.convert")
  local NuiTree = require("nui.tree")
  local utils = require("dbee.utils")

  convert.help_node = function(mappings)
    local filhos = {}
    for _, s in ipairs(secoes(mappings)) do
      local itens = {}
      for i, e in ipairs(s.itens) do
        table.insert(itens, NuiTree.Node({ id = "__lbd_help_" .. s.id .. "_" .. i, name = linha(e[1], e[2], 12), type = "" }))
      end
      table.insert(filhos, NuiTree.Node({ id = "__lbd_help_secao_" .. s.id, name = s.titulo, type = "" }, itens))
    end
    local node = NuiTree.Node({ id = "__help_node__", name = "help (atalhos)", type = "help" }, filhos)
    if utils.once("help_expand_once_id") then
      node:expand()
    end
    return node
  end

  vim.api.nvim_create_user_command("BancoAjuda", function()
    M.mostrar()
  end, { desc = "Atalhos do lbd/Dbee" })
end

---Janela flutuante de texto simples (q/<Esc> fecham). Linhas sem recuo são destacadas como título.
---@param titulo string
---@param texto string[]
---@param destacar_titulos? boolean
function M.janela(titulo, texto, destacar_titulos)
  local largura = 20
  for _, l in ipairs(texto) do
    largura = math.max(largura, vim.fn.strdisplaywidth(l))
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, texto)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local h = math.max(1, math.min(#texto, vim.o.lines - 6))
  local w = math.min(largura + 2, vim.o.columns - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = w,
    height = h,
    row = math.floor((vim.o.lines - h) / 2) - 1,
    col = math.floor((vim.o.columns - w) / 2),
    border = "rounded",
    title = " " .. titulo .. " ",
    title_pos = "center",
    footer = " q / <Esc> fechar ",
    footer_pos = "center",
  })
  vim.wo[win].wrap = true
  if destacar_titulos then
    local ns = vim.api.nvim_create_namespace("lbd_ajuda")
    for i, l in ipairs(texto) do
      if l ~= "" and not l:match("^  ") then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { end_col = #l, hl_group = "Title" })
      end
    end
  end
  for _, lhs in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", lhs, function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end, { buffer = buf, nowait = true, silent = true })
  end
  return win
end

---Mostra a ajuda numa janela flutuante (todas as seções, ou só as pedidas)
---@param ids? string[]
function M.mostrar(ids)
  local texto = {}
  for _, s in ipairs(secoes(nil)) do
    if not ids or vim.tbl_contains(ids, s.id) then
      if #texto > 0 then
        table.insert(texto, "")
      end
      table.insert(texto, s.titulo)
      for _, e in ipairs(s.itens) do
        table.insert(texto, "  " .. linha(e[1], e[2], 32))
      end
    end
  end
  return M.janela("Atalhos do lbd", texto, true)
end

return M
