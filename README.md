# codex.nvim

A tiny Neovim plugin that opens the **OpenAI Codex CLI** in a **right-side terminal split** (via `snacks.nvim`), plus a command to open/reuse Codex and insert the current buffer file reference.

You should probably just create your own instead of using this, since Codex can spit out a plugin like this pretty quick.

## Requirements

- Neovim 0.11.6+
- [`folke/snacks.nvim`](https://github.com/folke/snacks.nvim)
- The Codex CLI installed (`codex` on your PATH)

## Installation (lazy.nvim)

```lua
{
  "dimfeld/codex.nvim",
  dependencies = {
    "folke/snacks.nvim",
  },
  opts = {
    codex = {
      args = { "--model", "gpt-5.3-codex-spark" },
    },
    -- win = { width = 0.5 },
    -- focus_existing_on_here = true, -- focus existing Codex terminal on :CodexHere
  },
}
```

## Commands

- `:Codex`
  - Opens `codex` in a right split terminal.
  - Reuses an existing Codex terminal if one is already running.

- `:CodexHere`
  - Opens/reuses `codex`, then inserts only the current file reference as terminal input.

Tip: In visual mode, select lines, hit `:`, then run `CodexHere`.

## Suggested keymaps

```lua
vim.keymap.set("n", "<leader>cc", "<cmd>CodexHere<cr>", { desc = "Codex: current file" })
vim.keymap.set("v", "<leader>cc", ":'<,'>CodexHere<cr>", { desc = "Codex: selection range" })
vim.keymap.set("n", "<leader>cC", "<cmd>Codex<cr>", { desc = "Codex: open" })
```
