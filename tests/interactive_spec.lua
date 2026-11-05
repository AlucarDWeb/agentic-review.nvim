local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua").setup()
local check, lines, text = H.check, H.lines, H.text

H.run(function()
  local rg = require("agentic_review")
  local function arg_after(argv, flag)
    for i, a in ipairs(argv) do
      if a == flag then
        return argv[i + 1]
      end
    end
  end

  -- pi starts with the plugin's extension and bash, and counts as missing without a configured extension.
  local pi = rg.adapters.pi
  local argv, session, env = pi.interactive({ system = "s", label = "l", root = H.repo, dir = "/d" }, pi)
  local ext = argv[vim.fn.index(argv, "-e") + 2]
  check("pi loads the plugin's extension", ext and ext:match("/pi/agentic%-review%.ts$") and vim.uv.fs_stat(ext), argv)
  check("pi session tools", arg_after(argv, "--tools") == "read,grep,find,ls,bash", argv)
  check("pi session dir", env and env.AGENTIC_REVIEW_DIR == "/d" and session and session:match("^review%-"), env)
  check("pi missing extension", not pi.available(vim.tbl_extend("force", pi, { extensions = { "/no/such/ext" } })))

  -- claude's hooks append one line per event, and a request waits until the prompt is ready.
  local outbox = H.tmp .. "/claude outbox"
  local cargv = rg.adapters.claude.interactive({ system = "s", label = "l", root = H.repo, outbox = outbox })
  local hooks = vim.json.decode(arg_after(cargv, "--settings")).hooks
  for _, ev in ipairs({
    { hook_event_name = "SessionStart", session_id = "c1" },
    { hook_event_name = "Stop", session_id = "c1", last_assistant_message = "two\nlines" },
  }) do
    vim.system({ "sh", "-c", hooks[ev.hook_event_name][1].hooks[1].command }, { stdin = vim.json.encode(ev) }):wait()
  end
  local got = vim.tbl_map(rg.adapters.claude.reply, vim.fn.readfile(outbox))
  check("claude ready line", got[1] and got[1].ready and got[1].session == "c1", got)
  check("claude reply line", got[2] and got[2].text == "two\nlines", got)
  local echoed = ""
  local cat = vim.fn.jobstart({ "cat" }, {
    on_stdout = function(_, data)
      echoed = echoed .. table.concat(data, "\n")
    end,
  })
  local t = { job = cat }
  rg.adapters.claude.deliver(t, { prompt = "hello" })
  check("claude waits for the prompt", t.waiting and t.waiting.prompt == "hello" and echoed == "")
  t.ready = true
  rg.adapters.claude.deliver(t, { prompt = "hello" })
  vim.wait(2000, function()
    return echoed:find("\r", 1, true) ~= nil
  end)
  check("claude pastes the request", echoed:find("\27[200~hello\27[201~", 1, true) ~= nil, echoed)
  vim.fn.jobstop(cat)

  local report = table.concat({
    "[high] src/cart.lua:17: apply_discount is never defined",
    "Nothing requires the discount module.",
    "",
    "[low] src/discount.lua:2: rounding drifts",
    "It multiplies floats.",
  }, "\n")
  local ctxs = {}
  local fake = {
    tagged = true,
    models = { explain = "small", review = "big" },
    cmd = function()
      error("the headless process must not start")
    end,
    interactive = function(ctx)
      ctxs[#ctxs + 1] = ctx
      return { vim.v.progpath, "-l", H.root .. "/tests/bin/fake_session.lua" },
        "sess-i",
        { AGENTIC_REVIEW_DIR = ctx.dir, FAKE_REPLY = report }
    end,
  }
  rg.setup({
    agent = { "missing", "fake" },
    adapters = { missing = { bin = "agentic-review-no-such-agent" }, fake = fake },
    interactive = true,
    findings_picker = true,
    auto_tour = false,
    review_prompt = "/my-review",
    review_shell = true,
  })
  rg.open("")
  vim.wait(5000, function()
    return #vim.api.nvim_list_tabpages() == 2
  end)

  local wins, pane = {}, nil
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_get_name(buf) == "review://files" then
      wins.files = win
    elseif vim.bo[buf].buftype == "terminal" then
      wins.agent = win
    elseif vim.api.nvim_win_get_config(win).relative == "" then
      wins[wins.base and "head" or "base"] = win
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == "review://agent" then
      pane = buf
    end
  end
  check("session starts in the agent pane", wins.agent ~= nil and #ctxs == 1, ctxs)
  check("first installed agent", wins.agent and vim.wo[wins.agent].winbar:find("fake", 1, true) ~= nil)
  check("session prompt", ctxs[1] and ctxs[1].system:find("terminal pane", 1, true) ~= nil)

  local function requests()
    local path = ctxs[#ctxs].dir .. "/requests"
    return vim.uv.fs_stat(path) and vim.tbl_map(vim.json.decode, vim.fn.readfile(path)) or {}
  end
  local function idle()
    return vim.wait(5000, function()
      local win = wins.agent
      return win and vim.api.nvim_win_is_valid(win) and vim.wo[win].winbar:find("idle", 1, true) ~= nil
    end, 20)
  end

  vim.api.nvim_set_current_win(wins.files)
  for i, l in ipairs(lines(vim.api.nvim_win_get_buf(wins.files))) do
    if l:find(" cart.lua", 1, true) then
      vim.api.nvim_win_set_cursor(wins.files, { i, 0 })
    end
  end
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  rg.action("explain")
  vim.wait(5000, function()
    return pane and text(pane):find("_%d+s_") ~= nil
  end)
  local req = requests()[1] or {}
  check("explain sent to the session", (req.prompt or ""):find("Explain", 1, true) and req.model == "small", req)
  check("explain without the full shell", req.full_shell == false, req)
  check("reply kept in the pane buffer", pane and text(pane):find("apply_discount", 1, true) ~= nil)
  idle()

  rg.action("review")
  vim.wait(5000, function()
    return #H.floats() == 1
  end)
  req = requests()[2] or {}
  check("review request", req.prompt == "/my-review" and req.model == "big" and req.full_shell == true, req)
  check("review findings", H.last_note() == "2 findings", H.last_note())
  local float = H.floats()[1]
  local rows = float and lines(vim.api.nvim_win_get_buf(float)) or {}
  check("picker groups by severity", rows[1] == " High  1" and rows[4] == " Low  1", rows)
  if float then
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  end
  check(
    "picker opens the finding",
    #H.floats() == 0 and vim.api.nvim_get_current_win() == wins.head and vim.api.nvim_win_get_cursor(wins.head)[1] == 17,
    { #H.floats(), vim.api.nvim_win_get_cursor(0) }
  )

  local file = io.open(ctxs[1].dir .. "/outbox", "a")
  file:write(vim.json.encode({ text = "[medium] src/cart.lua:3: typed in the session\nBody." }), "\n")
  file:close()
  vim.wait(5000, function()
    return H.last_note() == "1 finding"
  end)
  check("typed reply keeps its findings", H.last_note() == "1 finding", H.last_note())
  vim.wait(1000, function()
    return #H.floats() == 1
  end)
  vim.api.nvim_feedkeys("q", "x", false)

  idle()
  rg.action("ask", "SLOW question")
  vim.wait(2000, function()
    return #requests() == 3
  end)
  rg.cancel()
  vim.wait(3000, function()
    return #requests() == 4
  end)
  check("cancel aborts in the session", (requests()[4] or {}).type == "abort", requests())

  rg.action("ask", "EXIT now")
  vim.wait(5000, function()
    return vim.api.nvim_win_get_buf(wins.agent) == pane
  end)
  check("pane back after the session exits", vim.api.nvim_win_get_buf(wins.agent) == pane)
  check("exit noted", H.last_note():find("exited with code 3", 1, true) ~= nil, H.last_note())
  check("running request ends", text(pane):find("_error: the agent session exited_", 1, true) ~= nil)

  rg.action("ask", "again")
  vim.wait(5000, function()
    return #ctxs == 2
  end)
  check("next request restarts the session", #ctxs == 2 and ctxs[2].session == "sess-i", ctxs[2])
  local term = vim.api.nvim_win_get_buf(wins.agent)
  rg.close()
  vim.wait(5000, function()
    return not vim.api.nvim_buf_is_valid(term)
  end)
  check("close ends the session", not vim.api.nvim_buf_is_valid(term))
end)
