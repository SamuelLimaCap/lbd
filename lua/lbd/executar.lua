-- lbd: rodar o statement sob o cursor sem selecionar nada (BQ no editor do Dbee).
-- Diferente do <CR> do dbee (treesitter + para na linha em branco), aqui o recorte é por texto:
--   * ";" e linha só com "/" separam statements (fora de string/comentário/parênteses não importa)
--   * bloco PL/SQL no Oracle (DECLARE/BEGIN/CREATE PROCEDURE...): os ";" internos não separam,
--     o bloco vai até a linha "/" (ou o fim da nota)
--   * linha em branco só separa quando a próxima linha começa um comando novo (SELECT, INSERT...)
--     e a anterior não deixou nada pendente (UNION, vírgula, parêntese aberto...) — então uma query
--     com linha em branco no meio continua inteira
local M = {}

local INICIO = {
  SELECT = true, WITH = true, INSERT = true, UPDATE = true, DELETE = true, MERGE = true,
  CREATE = true, ALTER = true, DROP = true, TRUNCATE = true, GRANT = true, REVOKE = true,
  COMMENT = true, BEGIN = true, DECLARE = true, EXPLAIN = true, CALL = true, EXEC = true,
}
-- Palavra no fim da linha anterior que indica que a query continua depois da linha em branco
local PENDENTE = {
  UNION = true, ALL = true, INTERSECT = true, MINUS = true, EXCEPT = true, AS = true, AND = true,
  OR = true, NOT = true, ON = true, FROM = true, WHERE = true, JOIN = true, BY = true, SELECT = true,
  SET = true, THEN = true, ELSE = true, WHEN = true, IN = true, INTO = true, VALUES = true,
}
local Q_FECHA = { ["["] = "]", ["{"] = "}", ["("] = ")", ["<"] = ">" }

local function eh_bloco(limpo)
  local u = limpo:upper()
  if u:match("^%s*DECLARE%f[%W]") or u:match("^%s*BEGIN%f[%W]") then
    return true
  end
  local resto = u:match("^%s*CREATE%s+(.*)")
  if not resto then
    return false
  end
  resto = resto:gsub("^OR%s+REPLACE%s+", ""):gsub("^NON", ""):gsub("^EDITIONABLE%s+", "")
  for _, tipo in ipairs({ "PROCEDURE", "FUNCTION", "PACKAGE", "TRIGGER", "TYPE%s+BODY" }) do
    if resto:match("^" .. tipo .. "%f[%W]") then
      return true
    end
  end
  return false
end

local function primeira_palavra(linha)
  return (linha:match("^%s*([%a_]+)") or ""):upper()
end

-- A linha em branco em `r` (1-based) separa o statement atual do próximo?
local function separa_em_branco(linhas, r, cur, oracle)
  local prox
  for j = r + 1, #linhas do
    if not linhas[j]:match("^%s*$") then
      prox = linhas[j]
      break
    end
  end
  if not prox or not INICIO[primeira_palavra(prox)] then
    return false
  end
  if oracle and eh_bloco(cur.limpo) then
    return false
  end
  local ant = linhas[cur.ultima_linha]:gsub("%-%-.*$", ""):gsub("%s+$", "")
  if ant:match("[,(=<>+%-*/|]$") then
    return false
  end
  if PENDENTE[(ant:match("([%a_]+)$") or ""):upper()] then
    return false
  end
  -- CTE: "WITH x AS (...)" + linha em branco + SELECT principal
  if primeira_palavra(cur.limpo) == "WITH" and ant:match("%)$") then
    return false
  end
  return true
end

-- Lista de statements: { sr, sc, er, ec (0-based, ec exclusivo), bloco }
function M.statements(linhas, oracle)
  local lista = {}
  local cur -- { sr, sc, er, ec, limpo, prof, ultima_linha }
  local estado, fecha -- estado: nil | "'" | '"' | "q" | "$" | "*"

  local function marca(r, i)
    if not cur then
      cur = { sr = r - 1, sc = i - 1, limpo = "", prof = 0 }
    end
    cur.er, cur.ec, cur.ultima_linha = r - 1, i, r
  end
  local function fechar()
    if cur then
      cur.bloco = oracle and eh_bloco(cur.limpo)
      table.insert(lista, cur)
      cur = nil
    end
  end

  for r, linha in ipairs(linhas) do
    if not estado and cur and linha:match("^%s*$") and cur.prof <= 0 and separa_em_branco(linhas, r, cur, oracle) then
      fechar()
    elseif not estado and linha:match("^%s*/%s*$") then
      fechar()
    else
      local i, n = 1, #linha
      while i <= n do
        local c = linha:sub(i, i)
        if estado == "*" then
          if linha:sub(i, i + 1) == "*/" then
            marca(r, i + 1)
            estado, i = nil, i + 1
          end
        elseif estado == "'" or estado == '"' then
          marca(r, i)
          if c == estado then
            if linha:sub(i + 1, i + 1) == estado then
              i = i + 1 -- '' escapado
              marca(r, i)
            else
              estado = nil
            end
          end
        elseif estado == "q" then
          marca(r, i)
          if c == fecha and linha:sub(i + 1, i + 1) == "'" then
            i = i + 1
            marca(r, i)
            estado = nil
          end
        elseif estado == "$" then
          marca(r, i)
          if linha:sub(i, i + #fecha - 1) == fecha then
            i = i + #fecha - 1
            marca(r, i)
            estado = nil
          end
        elseif c:match("%s") then
          if cur then
            cur.limpo = cur.limpo .. " "
          end
        elseif linha:sub(i, i + 1) == "--" then
          break
        elseif linha:sub(i, i + 1) == "/*" then
          marca(r, i + 1)
          estado, i = "*", i + 1
        elseif c == "'" or c == '"' then
          marca(r, i)
          cur.limpo = cur.limpo .. " " .. c .. c .. " "
          estado = c
        elseif c:lower() == "q" and linha:sub(i + 1, i + 1) == "'" and not linha:sub(i - 1, i - 1):match("[%w_$#]") then
          local d = linha:sub(i + 2, i + 2)
          marca(r, i + 2)
          cur.limpo = cur.limpo .. " '' "
          estado, fecha, i = "q", Q_FECHA[d] or d, i + 2
        elseif c == "$" and not oracle and not linha:sub(i - 1, i - 1):match("[%w_]") and linha:match("^%$[%a_]*[%w_]-%$", i) then
          fecha = linha:match("^%$[%a_]*[%w_]-%$", i)
          marca(r, i + #fecha - 1)
          cur.limpo = cur.limpo .. " '' "
          estado, i = "$", i + #fecha - 1
        elseif c == ";" then
          if cur and not (oracle and eh_bloco(cur.limpo)) then
            marca(r, i)
            fechar()
          elseif cur then
            marca(r, i)
            cur.limpo = cur.limpo .. ";"
          end
        else
          marca(r, i)
          cur.limpo = cur.limpo .. c
          if c == "(" then
            cur.prof = cur.prof + 1
          elseif c == ")" then
            cur.prof = cur.prof - 1
          end
        end
        i = i + 1
      end
      if cur then
        cur.limpo = cur.limpo .. " "
      end
    end
  end
  fechar()
  return lista
end

-- Statement que contém a posição (row/col 0-based)
function M.no_cursor(lista, row, col)
  local escolhido
  for _, st in ipairs(lista) do
    if st.sr <= row and row <= st.er then
      if st.sr == st.er and row == st.sr then
        -- vários na mesma linha: o que contém a coluna, senão o último que começa antes dela
        if col < st.ec or not escolhido then
          if not escolhido or st.sc <= col then
            escolhido = st
          end
        end
      else
        return st
      end
    end
  end
  return escolhido
end

-- Texto pronto para mandar ao banco
function M.texto(buf, st)
  local q = table.concat(vim.api.nvim_buf_get_text(buf, st.sr, st.sc, st.er, st.ec, {}), "\n")
  q = vim.trim(q)
  if st.bloco then
    -- o driver Oracle do dbee corta um ";" do fim; o bloco precisa do "END;"
    return q:match(";$") and (q .. ";") or q
  end
  return (q:gsub("[;%s]+$", ""))
end

function M.rodar()
  local api = require("dbee.api")
  local conn = api.core.get_current_connection()
  if not conn then
    return vim.notify("Nenhuma conexão ativa no Dbee.", vim.log.levels.WARN)
  end
  local buf = vim.api.nvim_get_current_buf()
  local linhas = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local pos = vim.api.nvim_win_get_cursor(0)
  local st = M.no_cursor(M.statements(linhas, conn.type == "oracle"), pos[1] - 1, pos[2])
  if not st then
    return vim.notify("Nenhuma query sob o cursor.", vim.log.levels.WARN)
  end

  -- destaca o que vai rodar (igual ao <CR> do dbee)
  local ns = vim.api.nvim_create_namespace("lbd_executar")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, st.sr, 0, { end_row = st.er + 1, end_col = 0, hl_group = "DiffText", priority = 100 })
  vim.defer_fn(function()
    pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
  end, 750)

  require("dbee").execute(M.texto(buf, st))
end

return M
