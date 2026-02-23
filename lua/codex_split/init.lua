local M = {}
M._fallback_term = nil

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

local function cmd_equal(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

local function get_term_job_id(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local ok, job_id = pcall(vim.api.nvim_buf_get_var, buf, "terminal_job_id")
  if ok and type(job_id) == "number" and job_id > 0 then
    return job_id
  end
  return nil
end

local function send_input_when_ready(buf, input, initial_delay_ms)
  initial_delay_ms = initial_delay_ms or 50
  local attempts = 0
  local max_attempts = 40

  local function try_send()
    attempts = attempts + 1
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end

    local job_id = get_term_job_id(buf)
    if job_id and vim.fn.jobwait({ job_id }, 0)[1] == -1 then
      vim.fn.chansend(job_id, input)
      return
    end

    if attempts < max_attempts then
      vim.defer_fn(try_send, 50)
    else
      notify("Codex terminal was not ready for input.", vim.log.levels.WARN)
    end
  end

  vim.defer_fn(try_send, initial_delay_ms)
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

local function find_existing_snacks_terminal(codex_cmd)
  local ok, Snacks = pcall(require, "snacks")
  if not (ok and Snacks and Snacks.terminal and Snacks.terminal.list) then
    return nil
  end

  for _, term in ipairs(Snacks.terminal.list()) do
    if term and term.buf and term.buf > 0 and vim.api.nvim_buf_is_valid(term.buf) then
      local ok_var, meta = pcall(vim.api.nvim_buf_get_var, term.buf, "snacks_terminal")
      if ok_var and type(meta) == "table" and cmd_equal(meta.cmd, codex_cmd) then
        return term
      end
    end
  end

  return nil
end

---@return integer|nil buf, boolean created
local function open_or_reuse_terminal(cwd)
  if not has_cmd(M.config.codex.cmd) then
    notify("`codex` was not found on your PATH. Install it (npm i -g @openai/codex or brew install codex).", vim.log.levels.ERROR)
    return nil, false
  end

  local codex_cmd = build_codex_cmd(nil)

  if M.config.use_snacks then
    local ok, Snacks = pcall(require, "snacks")
    if ok and Snacks and Snacks.terminal then
      local existing = find_existing_snacks_terminal(codex_cmd)
      if existing then
        existing:show()
        return existing.buf, false
      end

      local opts = vim.tbl_deep_extend("force", {}, M.config.term or {})
      opts.win = vim.tbl_deep_extend("force", {}, M.config.win or {}, opts.win or {})
      opts.cwd = cwd or opts.cwd
      local term = Snacks.terminal.open(codex_cmd, opts)
      return term and term.buf or nil, true
    end
  end

  local fallback = M._fallback_term
  if fallback and fallback.buf and vim.api.nvim_buf_is_valid(fallback.buf) then
    local job_id = get_term_job_id(fallback.buf)
    if job_id and vim.fn.jobwait({ job_id }, 0)[1] == -1 then
      if fallback.win and vim.api.nvim_win_is_valid(fallback.win) then
        vim.api.nvim_set_current_win(fallback.win)
      else
        vim.cmd("vsplit")
        vim.cmd("wincmd L")
        fallback.win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(fallback.win, fallback.buf)
      end
      vim.cmd("startinsert")
      return fallback.buf, false
    end
  end

  -- Fallback: built-in terminal split
  vim.cmd("vsplit")
  vim.cmd("wincmd L")

  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)

  vim.fn.termopen(codex_cmd, {
    cwd = cwd,
    on_exit = function()
      close_term_window(win)
    end,
  })
  M._fallback_term = { buf = buf, win = win }
  vim.cmd("startinsert")
  return buf, true
end

-- ---------------------------
-- Public API
-- ---------------------------

---Open Codex in a right split (reuses an existing Codex terminal when possible).
function M.open()
  open_or_reuse_terminal(resolve_cwd(0, vim.fn.getcwd(0)))
end

---Open/reuse Codex and type a mention of the current buffer's file into the terminal.
---If called with a visual range, include the selected line numbers.
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

  local buf, created = open_or_reuse_terminal(cwd)
  if buf then
    local initial_delay = created and 1000 or 50
    send_input_when_ready(buf, prompt, initial_delay)
  end
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
    desc = "Open/reuse Codex and insert current file prompt (visual mode includes line range)",
    range = true,
  })
end

return M
