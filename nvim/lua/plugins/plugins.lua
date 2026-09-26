return {{
    "LazyVim/LazyVim",
    opts = {
        news = {
            headlines = false,
        },
        -- No extras here. The list is in lazyvim.json, which is the file LazyVim
        -- reads, and there were two of them: this one and that one, with ten
        -- entries in common and fifteen appearing in only one of the two. The
        -- effective set was their union, 25 entries, and neither file said so.
        --
        -- What the union contained is the other half of the problem. lang.angular,
        -- lang.prisma, lang.css, lang.html and lang.tailwind are one person's
        -- web stack, in a niri rice, and each one pulls in a language server and
        -- a formatter that then have to be installed and kept working. They are
        -- gone from both files. Add one back in lazyvim.json, and remember the
        -- matching entry in the mason spec below.
    }

}, {
    "mason-org/mason.nvim",
    opts = function(_, opts)
        -- Deduplicated on the way in. taplo and eslint_d each appeared twice in
        -- the literal below, once under the Formatters comment and once under
        -- the Linters one, so mason was asked to install the same tool twice on
        -- every fresh machine. vim.list_extend does not check.
        -- Kept in step with the extras in lazyvim.json. A language server or
        -- formatter named in formatters_by_ft or linters_by_ft that is missing
        -- here is a tool that silently never runs, which is how selene,
        -- htmlhint, stylelint, tflint and typos came to be configured and not
        -- installed.
        local wanted = { -- Servers
            "lua-language-server", "pyright", "ruff-lsp", "typescript-language-server",
            "json-lsp", "yaml-language-server", "taplo", "marksman", "gopls", "clangd",
            -- Formatters
            "stylua", "prettierd", "eslint_d", "shfmt", "gofumpt", "goimports",
            "black", "isort", "clang-format",
            -- Linters
            "shellcheck", "ruff", "selene", "yamllint", "markdownlint", "hadolint", "typos",
        }
        local seen = {}
        for _, tool in ipairs(wanted) do
            if not seen[tool] then
                seen[tool] = true
                table.insert(opts.ensure_installed, tool)
            end
        end
    end
}, {
    "mfussenegger/nvim-lint",
    event = "LazyFile",
    opts = {
        linters_by_ft = {
            lua = {"selene"},
            python = {"ruff"},
            javascript = {"eslint_d"},
            typescript = {"eslint_d"},
            javascriptreact = {"eslint_d"},
            typescriptreact = {"eslint_d"},
            vue = {"eslint_d"},
            yaml = {"yamllint"},
            markdown = {"markdownlint"},
            sh = {"shellcheck"},
            dockerfile = {"hadolint"},
            ["*"] = {"typos"}
        },
        linters = {
            typos = {
                condition = function(ctx)
                    return vim.fs.find({"typos.toml", ".typos.toml"}, {
                        path = ctx.filename,
                        upward = true
                    })[1]
                end
            }
        }
    }
}, {
    "stevearc/conform.nvim",
    opts = {
        formatters_by_ft = {
            lua = {"stylua"},
            python = {"isort", "black"},
            javascript = {"prettierd"},
            typescript = {"prettierd"},
            javascriptreact = {"prettierd"},
            typescriptreact = {"prettierd"},
            vue = {"prettierd"},
            html = {"prettierd"},
            css = {"prettierd"},
            scss = {"prettierd"},
            json = {"prettierd"},
            jsonc = {"prettierd"},
            yaml = {"prettierd"},
            markdown = {"prettierd"},
            sh = {"shfmt"},
            go = {"gofumpt", "goimports"},
            toml = {"taplo"},
            cpp = {"clang-format"},
            c = {"clang-format"},
            ["*"] = {"trim_whitespace"}
        },
        formatters = {
            prettierd = {
                prepend_args = {"--tab-width", "2", "--single-quote", "true", "--trailing-comma", "es5",
                                "--print-width", "100", "--semi", "true"}
            },
            shfmt = {
                prepend_args = {"-i", "2", "-ci", "-sr"}
            },
            stylua = {
                prepend_args = {"--indent-type", "Spaces", "--indent-width", "2", "--column-width", "120"}
            },
            black = {
                prepend_args = {"--line-length", "88", "--target-version", "py38"}
            },
            ["clang-format"] = {
                -- No --style here on purpose. A --style argument overrides the
                -- .clang-format file outright, so passing --style=Google made
                -- the nvim/.clang-format in this repo dead: its IndentWidth 2,
                -- ColumnLimit 80 and BreakBeforeBraces Attach were never
                -- applied. clang-format finds the file by itself from the
                -- buffer's directory, which is what makes those settings mean
                -- anything. Add the argument only if you want to pin a style
                -- regardless of whatever the project has.
                prepend_args = {}
            }
        },
        -- Format on save, per filetype. This is the one place it is set, so
        -- that it cannot disagree with formatters_by_ft above the way the
        -- previous unconditional BufWritePre in config/options.lua did.
        format_on_save = function(buf)
            local conform = require("conform")
            local fts = conform.list_formatters(buf)
            -- Files with no formatter configured are left alone, which is what
            -- keeps a save in a .md or .txt file from being rewritten.
            return #fts > 0
        end,
    }
}, {
    "RedsXDD/neopywal.nvim",
    name = "neopywal",
    lazy = false,
    priority = 1000,
    config = function()
        require("neopywal").setup({
            transparent_background = true,
            use_palette = {
                dark = "pywal",
                light = "pywal"
            }
        })
        vim.cmd.colorscheme("neopywal-dark")
    end
}}
