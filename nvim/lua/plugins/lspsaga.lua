return {
    "nvimdev/lspsaga.nvim",
    event = { "BufRead", "BufNewFile" },
    config = function()
        require("lspsaga").setup({
            symbol_in_winbar = {
                separator = "  ",
            },
        })
    end,
    dependencies = {
        "nvim-treesitter/nvim-treesitter",
        "nvim-tree/nvim-web-devicons",
    },
}
