local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua").setup()
local check, text, floats = H.check, H.text, H.floats

local function title(win)
  return vim.api.nvim_win_get_config(win).title[1][1]
end

local function footer(win)
  return vim.api.nvim_win_get_config(win).footer[1][1]
end

H.run(function()
  local rg = require("agentic_review")
  local spawned, prompts, systems = 0, {}, {}
  local opts = {
    session = "q-1",
    on_spawn = function(ctx)
      spawned = spawned + 1
      systems[#systems + 1] = ctx.system
    end,
    on_prompt = function(prompt)
      prompts[#prompts + 1] = prompt
    end,
  }
  local long = {}
  for i = 1, 30 do
    long[i] = "line " .. i
  end
  rg.setup({
    agent = "short",
    adapters = {
      short = H.fake_agent("Short answer. See src/cart.lua:3", opts),
      long = H.fake_agent(table.concat(long, "\n"), opts),
    },
    auto_tour = false,
  })

  -- With no review open, explain on a selection opens a float under it.
  vim.cmd("edit src/discount.lua")
  local source = vim.api.nvim_get_current_win()
  rg.action("explain", nil, { 1, 2 })
  local f = floats()[1]
  check("float opened", f ~= nil)
  local cfg = vim.api.nvim_win_get_config(f)
  check(
    "anchored under the selection",
    cfg.relative == "win" and cfg.win == source and cfg.anchor == "NW" and cfg.bufpos[1] == 1,
    cfg
  )
  check("title", title(f):find("Explain · src/discount.lua:1-2", 1, true) ~= nil, title(f))
  check("float focused", vim.api.nvim_get_current_win() == f)
  local qbuf = vim.api.nvim_win_get_buf(f)
  H.wait_answers(qbuf, 1)
  check("answer streamed", text(qbuf):find("Short answer", 1, true) ~= nil, text(qbuf))
  check(
    "code-oriented prompt",
    (prompts[1] or ""):find("^Explain what this code does") ~= nil
      and prompts[1]:find("Lines 1-2 of src/discount.lua", 1, true) ~= nil,
    prompts[1]
  )
  check("quick system prompt", (systems[1] or ""):find("floating window under the code", 1, true) ~= nil)
  cfg = vim.api.nvim_win_get_config(f)
  check("height fits content", cfg.height == vim.api.nvim_win_text_height(f, {}).all and cfg.height < 15, cfg.height)
  check(
    "footer idle with hints",
    footer(f):find("short · idle · a ask · s split · q close", 1, true) ~= nil,
    footer(f)
  )

  -- A follow-up reuses the process, and the view starts at the new question.
  vim.ui.input = function(_, cb)
    cb("and the rounding?")
  end
  vim.api.nvim_feedkeys("a", "x", false)
  H.wait_answers(qbuf, 2)
  check("follow-up same process", spawned == 1 and prompts[2] == "and the rounding?", { spawned, prompts[2] })
  local header
  for i, l in ipairs(H.lines(qbuf)) do
    if l == "## Ask" then
      header = i
    end
  end
  local top = vim.api.nvim_win_call(f, function()
    return vim.fn.line("w0")
  end)
  check("view starts at follow-up", top == header, { header, top })

  -- <CR> on a path:line closes the float and jumps in the source window.
  for i = vim.api.nvim_buf_line_count(qbuf), 1, -1 do
    if vim.api.nvim_buf_get_lines(qbuf, i - 1, i, false)[1]:find("cart.lua:3", 1, true) then
      vim.api.nvim_win_set_cursor(f, { i, 0 })
      break
    end
  end
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  check(
    "jumped in source window",
    vim.api.nvim_get_current_win() == source
      and vim.api.nvim_buf_get_name(0):find("src/cart.lua$") ~= nil
      and vim.api.nvim_win_get_cursor(0)[1] == 3
  )
  check("float closed on jump", #floats() == 0)

  -- The last answer comes back on demand; s moves it to a split that then takes new answers.
  rg.answer()
  f = floats()[1]
  check("last answer reopened", f ~= nil and vim.api.nvim_win_get_buf(f) == qbuf)
  vim.api.nvim_feedkeys("s", "x", false)
  local split = vim.api.nvim_get_current_win()
  check(
    "moved to split",
    #floats() == 0 and vim.api.nvim_win_get_buf(split) == qbuf and vim.wo[split].winbar:find("a ask", 1, true) ~= nil
  )
  vim.api.nvim_set_current_win(source)
  rg.action("ask", "what about line 3?", { 3, 3 })
  H.wait_answers(qbuf, 3)
  check("answer went to split", #floats() == 0 and text(qbuf):find("what about line 3?", 1, true) ~= nil)
  vim.api.nvim_set_current_win(split)
  vim.api.nvim_feedkeys("q", "x", false)
  check("q closes split", not vim.api.nvim_win_is_valid(split) and vim.api.nvim_get_current_win() == source)

  -- A float that follows the split must not inherit its winbar, which would not fit in one row.
  rg.config.agent = "long"
  rg.action("deep", nil, { 1, 1 })
  f = floats()[1]
  check("float opens after split", f ~= nil and vim.wo[f].winbar == "")
  H.wait_answers(qbuf, 4)
  check("height capped", vim.api.nvim_win_get_config(f).height == 15, vim.api.nvim_win_get_config(f).height)
  check("follows tail", vim.api.nvim_win_get_cursor(f)[1] == vim.api.nvim_buf_line_count(qbuf))
  check("adapter switch restarted process", spawned == 2)
  vim.api.nvim_feedkeys("q", "x", false)

  -- Near the bottom of the window the float opens above the code.
  vim.cmd("enew")
  vim.api.nvim_buf_set_lines(
    0,
    0,
    -1,
    false,
    vim.tbl_map(function(i)
      return "row " .. i
    end, vim.fn.range(1, 200))
  )
  vim.cmd("normal! 120Gzb")
  rg.config.agent = "short"
  rg.action("explain")
  f = floats()[1]
  cfg = vim.api.nvim_win_get_config(f)
  check("flips above near bottom", cfg.anchor == "SW" and cfg.bufpos[1] == 119, cfg)
  vim.api.nvim_feedkeys("q", "x", false)

  rg.config.adapters.slow = {
    cmd = function()
      return { "sh", "-c", "sleep 30" }
    end,
  }
  rg.config.agent = "slow"
  vim.cmd("edit src/discount.lua")
  rg.action("explain")
  f = floats()[1]
  vim.wait(200)
  check("working in footer", footer(f):find("working", 1, true) ~= nil)
  vim.api.nvim_feedkeys(vim.keycode("<C-c>"), "x", false)
  check("cancelled", text(qbuf):find("_cancelled_", 1, true) ~= nil and footer(f):find("idle", 1, true) ~= nil)
  vim.api.nvim_feedkeys("q", "x", false)

  -- In the review tab actions use the side pane; in other tabs they use the float.
  rg.config.agent = "short"
  rg.open("")
  vim.wait(5000, function()
    return #vim.api.nvim_list_tabpages() == 2
  end)
  local pane = vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_list_wins(0)[4])
  rg.action("explain")
  H.wait_answers(pane, 1)
  check("review tab uses pane", #floats() == 0 and text(pane):find("## Explain", 1, true) ~= nil)
  vim.cmd("tabnew src/discount.lua")
  rg.action("explain", nil, { 2, 2 })
  check("other tab gets a float", #floats() == 1)
  vim.api.nvim_feedkeys("q", "x", false)
  vim.cmd("tabclose")
  rg.close()

  H.git("stash", "-q")
  rg.open("HEAD")
  vim.wait(3000, function()
    return H.last_note():find("No changes", 1, true) ~= nil
  end)
  check(
    "no changes message",
    H.last_note():find("No changes in feature vs HEAD", 1, true) ~= nil and #vim.api.nvim_list_tabpages() == 1,
    H.last_note()
  )
  H.git("stash", "pop", "-q")

  local entry = H.store_entry("quick|" .. H.repo)
  check("quick session stored", entry and entry.session == "q-1", entry)
end)
