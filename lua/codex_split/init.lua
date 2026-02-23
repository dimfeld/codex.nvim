local M = {}

---@class CodexSplitConfig
---@field codex { cmd: string|string[], args?: string[] }
---@field win table  -- snacks.win.Config subset
---@field term table -- snacks.terminal.Opts subset
---@field cwd nil|string|fun(bufnr: integer, filepath: string):string  -- nil uses current Neovim cwd
---@field use_snacks boolean
---@field use_at_file_mention boolean
---@field prompt { file: string, range: string }
---@field commands { codex: string, here: string }

local defaults = {
  codex = {
    cmd = "codex",
    -- This flag makes TUIs behave better inside Neovim terminals (no alternate screen).
    -- Remove it if you prefer Codex's default behavior.
    args = { "--no-alt-screen" },
  },
  -- If set to "git_root", Codex is launched from the repo root of the current buffer (best default).
  -- Set to nil to use Neovim's current working directory.
  cwd = "git_root",

  use_snacks = true,
  -- Codex supports @file references; keep this true if you want the special file mention syntax.
  use_at_file_mention = true,

  -- Window options for Snacks.terminal (snacks.win.Config)
  win = {
    position = "right",
    width = 0.45,
    enter = true,
  },

  -- Terminal options for Snacks.terminal (snacks.terminal.Opts)
  term = {
    interactive = true,
    auto_close = true,
  },

  prompt = {
    -- {file} will be replaced with either "@path" or "path" depending on use_at_file_mention.
    file = "I'm working on {file}.",
    range = "I'm working on {file}. Please focus on lines {start}-{end}.",
  },

  commands = {
    codex = "Codex",
    here = "CodexHere",
  },
}

---@type CodexSplitConfig
M.config = vim.deepcopy(defaults)

-- ---------------------------
-- Helpers
-- ---------------------------

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "codex-split.nvim" })
end

local function has_cmd(bin)
  local name = bin
  if type(bin) == "table" then
    name = bin[1]
  end
  return type(name) == "string" and vim.fn.executable(name) == 1
end

local function trim_trailing_slash(p)
  return (p:gsub("/+$", ""))
end

local function path_join(a, b)
  if a:sub(-1) == "/" then
    return a .. b
  end
  return a .. "/" .. b
end

local function relpath(root, path)
  root = trim_trailing_slash(vim.fn.fnamemodify(root, ":p"))
  path = vim.fn.fnamemodify(path, ":p")
  if path:sub(1, #root) == root then
    local rel = path:sub(#root + 1)
    if rel:sub(1, 1) == "/" then
      rel = rel:sub(2)
    end
    return rel ~= "" and rel or vim.fn.fnamemodify(path, ":t")
  end
  return path
end

local function find_git_root(start_dir)
  -- Prefer vim.fs if available
  if vim.fs and vim.fs.find then
    local git = vim.fs.find(".git", { path = start_dir, upward = true })[1]
    if git then
      return vim.fs.dirname(git)
    end
  end

  -- Fallback to finddir
  local gitdir = vim.fn.finddir(".git", start_dir .. ";")
  if gitdir and gitdir ~= "" then
    return vim.fn.fnamemodify(gitdir, ":h")
  end

  return nil
end

local function resolve_cwd(bufnr, filepath)
  local cwd_cfg = M.config.cwd
  if cwd_cfg == nil then
    return vim.fn.getcwd(0)
  end

  if cwd_cfg == "git_root" then
    local dir = vim.fn.fnamemodify(filepath, ":p:h")
    return find_git_root(dir) or vim.fn.getcwd(0)
  end

  if type(cwd_cfg) == "function" then
    local ok, ret = pcall(cwd_cfg, bufnr, filepath)
    if ok and type(ret) == "string" and ret ~= "" then
      return ret
    end
    return vim.fn.getcwd(0)
  end

  if type(cwd_cfg) == "string" then
    return cwd_cfg
  end

  return vim.fn.getcwd(0)
end

local function interpolate(template, vars)
  return (template:gsub("{(.-)}", function(k)
    local v = vars[k]
    if v == nil then
      return "{" .. k .. "}"
    end
    return tostring(v)
  end))
end

local function current_file(bufnr)
  bufnr = bufnr or 0
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == nil or name == "" then
    return nil
  end
  return name
end

local function build_codex_cmd(prompt)
  local cfg = M.config.codex
  local cmd = {}

  if type(cfg.cmd) == "table" then
    vim.list_extend(cmd, cfg.cmd)
  else
    table.insert(cmd, cfg.cmd)
  end

  if cfg.args and type(cfg.args) == "table" then
    vim.list_extend(cmd, cfg.args)
  end

  if prompt and prompt ~= "" then
    table.insert(cmd, prompt)
  end

  return cmd
end

local function close_term_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end)
end

local function open_terminal(cmd, cwd)
  if not has_cmd(M.config.codex.cmd) then
    notify("`codex` was not found on your PATH. Install it (npm i -g @openai/codex or brew install codex).", vim.log.levels.ERROR)
    return
  end

  if M.config.use_snacks then
    local ok, Snacks = pcall(require, "snacks")
    if ok and Snacks and Snacks.terminal then
      local opts = vim.tbl_deep_extend("force", {}, M.config.term or {})
      opts.win = vim.tbl_deep_extend("force", {}, M.config.win or {}, opts.win or {})
      opts.cwd = cwd or opts.cwd
      Snacks.terminal.open(cmd, opts)
      return
    end
  end

  -- Fallback: built-in terminal split
  vim.cmd("vsplit")
  vim.cmd("wincmd L")

  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)

  vim.fn.termopen(cmd, {
    cwd = cwd,
    on_exit = function()
      close_term_window(win)
    end,
  })
  vim.cmd("startinsert")
end

-- ---------------------------
-- Public API
-- ---------------------------

---Open Codex in a right split (no preloaded prompt).
function M.open()
  open_terminal(build_codex_cmd(nil), resolve_cwd(0, vim.fn.getcwd(0)))
end

---Open Codex preloaded with a mention of the current buffer's file.
---If called with a visual range, also mention the selected line numbers.
---@param opts? {range?: integer, line1?: integer, line2?: integer}
function M.open_here(opts)
  opts = opts or {}

  local bufnr = 0
  local abs = current_file(bufnr)
  if not abs then
    notify("Current buffer has no file path. Save it first.", vim.log.levels.ERROR)
    return
  end

  local cwd = resolve_cwd(bufnr, abs)
  local file = relpath(cwd, abs)
  local file_ref = M.config.use_at_file_mention and ("@" .. file) or file

  local prompt
  if opts.range and opts.range > 0 and opts.line1 and opts.line2 then
    local l1, l2 = opts.line1, opts.line2
    if l2 < l1 then
      l1, l2 = l2, l1
    end
    prompt = interpolate(M.config.prompt.range, { file = file_ref, start = l1, ["end"] = l2 })
  else
    prompt = interpolate(M.config.prompt.file, { file = file_ref })
  end

  open_terminal(build_codex_cmd(prompt), cwd)
end

---Setup the plugin and define user commands.
---@param opts? CodexSplitConfig
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  -- user commands
  vim.api.nvim_create_user_command(M.config.commands.codex, function()
    require("codex_split").open()
  end, { desc = "Open Codex in a right split (terminal)" })

  vim.api.nvim_create_user_command(M.config.commands.here, function(cmd_opts)
    require("codex_split").open_here(cmd_opts)
  end, {
    desc = "Open Codex preloaded with current file (and selection line range in visual mode)",
    range = true,
  })
end

return M
