-- lbd: cliente de banco (Postgres + Oracle) via nvim-dbee.
-- O dbee usa drivers próprios (Go), então não precisa de psql/sqlplus instalados.
-- Conexões (com usuário/senha) ficam FORA da config, em ~/.local/share/lbd/conexoes.json (chmod 600).
local conexoes = vim.fn.stdpath("data") .. "/conexoes.json"

return {
  {
    "kndndrj/nvim-dbee",
    dependencies = { "MunifTanjim/nui.nvim" },
    build = function()
      -- Baixa o binário pré-compilado do backend (não precisa de Go)
      require("dbee").install()
    end,
    lazy = false,
    keys = {
      { "<leader>D", function() require("dbee").toggle() end, desc = "Banco: abrir/fechar Dbee" },
      { "<leader>ds", function() require("lbd.seletor").escolher() end, desc = "Banco: selecionar database/schema" },
      { "<leader>SK", function() require("lbd.resultado").registro() end, desc = "Banco: modo registro (Coluna: valor)" },
      { "<leader>dc", function() require("lbd.colunas").abrir() end, desc = "Banco: colunas da tabela (+ Java/Hibernate)" },
      { "<leader>dC", function() require("lbd.colunas").abrir(vim.fn.expand("<cword>")) end, desc = "Banco: colunas da tabela sob o cursor" },
      { "<leader>da", function() require("lbd.lote").iniciar() end, mode = { "n", "x" }, desc = "Banco: rodar a query em várias bases (lote)" },
      { "<leader>dl", function() require("lbd.lote").reabrir() end, desc = "Banco: reabrir a lista do último lote" },
    },
    config = function()
      require("dbee").setup({
        sources = {
          require("dbee.sources").FileSource:new(conexoes),
        },
        editor = {
          -- a lista substitui a padrão (mesclagem por índice), então os mappings do dbee vão repetidos aqui
          mappings = {
            { key = "BB", mode = "v", action = "run_selection" },
            { key = "BB", mode = "n", action = "run_file" },
            { key = "<CR>", mode = "n", action = "run_under_cursor" },
            -- query sob o cursor até o ";" (ou "/" no PL/SQL), sem precisar selecionar
            { key = "BQ", mode = "n", action = function() require("lbd.executar").rodar() end },
          },
        },
      })
      -- Postgres: lista os databases do servidor; Oracle: lista os schemas (como no DBeaver)
      vim.api.nvim_create_user_command("BancoSelecionar", function()
        require("lbd.seletor").escolher()
      end, { desc = "Selecionar database (Postgres) / schema (Oracle) da conexão ativa" })

      require("lbd.completar").setup() -- autocomplete: escopo acompanha a troca de database
      require("lbd.resultado").setup() -- grade: o/O (order by), ? (ajuda)
      require("lbd.colunas").setup() -- :BancoColunas [tabela]
      require("lbd.ajuda").setup() -- help da árvore com todos os atalhos + :BancoAjuda

      -- Lote: mesma query em vários schemas (Oracle) / databases (Postgres)
      vim.api.nvim_create_user_command("BancoLote", function()
        require("lbd.lote").iniciar()
      end, { desc = "Rodar a query sob o cursor em várias bases" })
      vim.api.nvim_create_user_command("BancoLoteLista", function()
        require("lbd.lote").reabrir()
      end, { desc = "Reabrir a lista do último lote" })
    end,
  },

  -- Formatação de SQL (<leader>cf): sql-formatter com o dialeto da conexão ativa do Dbee
  -- (Oracle -> plsql, Postgres -> postgresql). Só sob demanda: não formata ao salvar.
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = { sql = { "sql_formatter" } },
      formatters = {
        sql_formatter = {
          prepend_args = function()
            local ok, conn = pcall(function()
              return require("dbee.api").core.get_current_connection()
            end)
            local tipo = ok and conn and conn.type
            local dialeto = tipo == "oracle" and "plsql" or tipo == "postgres" and "postgresql" or "sql"
            return { "-l", dialeto, "-c", '{"keywordCase":"upper","tabWidth":2,"expressionWidth":80}' }
          end,
        },
      },
    },
    init = function()
      vim.api.nvim_create_autocmd("FileType", {
        pattern = "sql",
        callback = function(ev)
          vim.b[ev.buf].autoformat = false
        end,
      })
    end,
  },
  {
    "mason-org/mason.nvim",
    opts = { ensure_installed = { "sql-formatter" } },
  },

  -- Autocomplete de tabelas/colunas (só do schema/database atual) nos arquivos SQL
  {
    "saghen/blink.cmp",
    opts = {
      sources = {
        per_filetype = {
          sql = { inherit_defaults = true, "lbd" },
        },
        providers = {
          lbd = {
            name = "Banco",
            module = "lbd.completar",
            score_offset = 50, -- tabelas/colunas antes das palavras do buffer
          },
        },
      },
    },
  },
}
