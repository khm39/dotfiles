-- Terminal GUI Color
vim.opt.termguicolors = true

-- Line numbers
vim.opt.number = true

-- Indentation
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.expandtab = true

-- Folding
vim.o.foldenable = true
vim.o.foldmethod = "indent"
vim.opt.foldcolumn = "1"
vim.o.foldlevel = 99
vim.opt.fillchars:append({
    fold = " ",
    foldopen = "",
    foldsep = " ",
    foldclose = "",
})

