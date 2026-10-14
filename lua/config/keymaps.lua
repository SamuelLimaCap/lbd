local keymap = vim.keymap
local opts = { noremap = true, silent = true }

keymap.set("n", "x", '"_x')

-- keymap.set("n", , )

--increment / Decrement
keymap.set("n", "+", "<C-a>")
keymap.set("n", "-", "<C-x>")

-- Save file and quit
keymap.set("n", "<Leader>w", ":update<Return>", opts)
keymap.set("n", "<Leader>q", ":quit<Return>", opts)
keymap.set("n", "<Leader>qa", ":qa<Return>", opts)

-- Tabs
keymap.set("n", "te", ":tabedit")
keymap.set("n", "<tab>", ":tabnext<Return>")
keymap.set("n", "<s-tab>", ":tabprev<Return>")
keymap.set("n", "tw", ":tabprev<Return>")

-- Split window
keymap.set("n", "ss", ":split<Return>", opts)
keymap.set("n", "sv", ":vsplit<Return>", opts)

-- Move window
keymap.set("n", "sh", "<C-w>h")
keymap.set("n", "sj", "<C-w>j")
keymap.set("n", "sk", "<C-w>k")
keymap.set("n", "sl", "<C-w>l")

-- Resize window
keymap.set("n", "<C-S-h>", "<C-w><")
keymap.set("n", "<C-S-l>", "<C-w>>")
keymap.set("n", "<C-S-j>", "<C-w>-")
keymap.set("n", "<C-S-k>", "<C-w>+")

keymap.set("n", "<C-j>", function()
  vim.diagnostic.goto_next()
end, opts)

keymap.set("n", "<C-k>", function()
  vim.diagnostic.goto_prev()
end, opts)

-- Fix highlight treesiter
keymap.set("n", "<Leader>he <CR>", ":TSEnable highlight")

-- Terminal keymaps

keymap.set("n", "<leader>Bth", ":ToggleTerm direction=horizontal <CR>", { desc = "Open terminal(horizontal)" })

keymap.set("n", "<leader>rls", ":StartLiveServerOnPort 5500")

keymap.set("n", "<Leader>cz", ":NoNeckPain")

-- Delete error window
keymap.set(
  "n",
  "<leader>wed",
  "3<C-w>j<Leader>wd<Leader>w1",
  { desc = "Delete error window", silent = true, remap = true }
)
