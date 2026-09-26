-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
-- File handling: Swap, Backup, Undo
-- Store swap files in the same directory as the file being edited
vim.opt.swapfile = true
vim.opt.directory = "."

-- Store backup files in the same directory as the file being edited
vim.opt.backup = false -- Disable backups if you prefer (they can clutter directories)
-- If you want backups, uncomment the lines below and comment the line above
-- vim.opt.backup = true
-- vim.opt.backupdir = "."

-- Persistent undo history (stored in a central location)
vim.opt.undofile = true
-- Single slash: the trailing "//" was a typo. Neovim tolerates it, so it was
-- never noticed, but the directory it names is not the one that reads well in
-- :checkhealth undodir.
vim.opt.undodir = vim.fn.stdpath("data") .. "/undo"

-- -- Enable true colors for proper colorscheme support
-- vim.opt.termguicolors = true
-- vim.cmd("set t_Co=256")

-- Ensure terminal opens in current working directory
vim.api.nvim_create_autocmd("TermOpen", {
    callback = function()
        vim.opt_local.number = false
        vim.opt_local.relativenumber = false
        vim.opt_local.signcolumn = "no"
    end
})

-- This used to register its own unconditional BufWritePre that called
-- conform.format() on every buffer. LazyVim's conform already registers one
-- that respects format_on_save.formatters_by_ft, so the two both ran: the
-- buffer was formatted twice on every save, and filetypes that LazyVim
-- deliberately does not format on save were formatted anyway, with no pcall
-- around it. Nothing is registered here now; see lua/plugins/plugins.lua for
-- the formatters_by_ft table, and enable format_on_save there.

-- Formatting on save is opt-in per filetype in LazyVim, and the list of
-- filetypes to enable it for is set in the conform spec rather than here, so
-- that the two cannot drift apart. Uncomment to turn it on:
--
-- require("conform").setup({
--   format_on_save = function(buf)
--     local fts = require("conform").list_formatters(buf)
--     return vim.tbl_contains(fts, "prettierd") or vim.tbl_contains(fts, "stylua")
--   end,
-- })
