return {
    "akinsho/bufferline.nvim",
    lazy = false,
    dependencies = "nvim-tree/nvim-web-devicons",
    opts = {
        options = {
            numbers = "both",
            offsets = {
                {
                    filetype = "neo-tree",
                    text = "Neo Tree",
                    separator = true,
                    text_align = "left",
                },
            },
        }
    },
}
