# codex-split.nvim

A tiny Neovim plugin that opens the **OpenAI Codex CLI** in a **right-side terminal split** (via `snacks.nvim`), plus a command to open/reuse Codex and insert text mentioning the current buffer’s file (and visual selection line range).

## Requirements

- Neovim 0.9.4+
- [`folke/snacks.nvim`](https://github.com/folke/snacks.nvim)
- The Codex CLI installed (`codex` on your PATH)

## Installation (lazy.nvim)

```lua
{
  "yourname/codex-split.nvim",
  dependencies = {
    "folke/snacks.nvim",
  },
  config = function()
    require("codex_split").setup({
      -- optional overrides
      -- win = { width = 0.5 },
      -- codex = { args = { "--no-alt-screen", "--model", "gpt-5.3-codex" } },
    })
  end,
}
```

## Commands

- `:Codex`
  - Opens `codex` in a right split terminal.
  - Reuses an existing Codex terminal if one is already running.

- `:CodexHere`
  - In normal mode: opens/reuses `codex`, then inserts a prompt mentioning the current file as terminal input.
  - In visual mode: opens/reuses `codex`, then inserts a prompt mentioning the current file **and** the selected line range.

Tip: In visual mode, select lines, hit `:`, then run `CodexHere`.

## Suggested keymaps

```lua
vim.keymap.set("n", "<leader>cc", "<cmd>CodexHere<cr>", { desc = "Codex: current file" })
vim.keymap.set("v", "<leader>cc", "<cmd>CodexHere<cr>", { desc = "Codex: selection range" })
vim.keymap.set("n", "<leader>cC", "<cmd>Codex<cr>", { desc = "Codex: open" })
```
