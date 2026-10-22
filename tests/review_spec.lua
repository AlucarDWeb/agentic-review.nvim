local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua").setup()
local check, lines, text = H.check, H.lines, H.text

H.run(function()
  local rg = require("agentic_review")
  local tour = "Overview text. See src/cart.lua:17.\n\n```review-order\nsrc/discount.lua\nsrc/cart.lua\n```"
  local captured = {}
  local oneshot = {
    cmd = function(ctx)
      captured[#captured + 1] = ctx.prompt
      return { "sh", "-c", "printf 'Plain answer, see src/discount.lua:2\\n'" }
    end,
  }
  rg.setup({
    agent = "fake",
    adapters = {
      fake = H.fake_agent(tour, { session = "sess-123", tool = H.repo .. "/src/cart.lua" }),
      oneshot = oneshot,
    },
  })
  vim.cmd("edit src/cart.lua")
  rg.open("")
  vim.wait(5000, function()
    return #vim.api.nvim_list_tabpages() == 2
  end)
  local wins = H.review_wins()
  check("four windows", #wins == 4, #wins)
  local files_buf, agent_buf = vim.api.nvim_win_get_buf(wins[1]), vim.api.nvim_win_get_buf(wins[4])

  -- The tour runs on open and reorders the files.
  H.wait_answers(agent_buf, 1)
  local pane = text(agent_buf)
  check("tour header", pane:find("## Tour", 1, true) ~= nil, pane)
  check("tool line relative", pane:find("> Read `src/cart.lua`", 1, true) ~= nil, pane)
  check("blank line before text", pane:find("`src/cart.lua`\n\nOverview", 1, true) ~= nil, pane)
  local panel = lines(files_buf)
  check("label", panel[1] == "feature vs main", panel[1])
  check("5 files", #panel == 8, panel)
  check("tour reordered: discount first", panel[4]:find("discount.lua", 1, true) ~= nil, panel)
  check("rename shown", text(files_buf):find("R README.md", 1, true) ~= nil, panel)
  check("binary shown", text(files_buf):find("logo.png bin", 1, true) ~= nil, panel)
  check("winbar", vim.wo[wins[4]].winbar:find("fake · idle", 1, true) ~= nil, vim.wo[wins[4]].winbar)
  check("diff on", vim.wo[wins[2]].diff and vim.wo[wins[3]].diff)

  -- Opening cart.lua puts the real file on the head side and the cursor on the first hunk.
  vim.api.nvim_set_current_win(wins[1])
  for i, l in ipairs(lines(files_buf)) do
    if l:find("cart.lua", 1, true) then
      vim.api.nvim_win_set_cursor(wins[1], { i, 0 })
    end
  end
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  local head_name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(wins[3]))
  check("head is real file", head_name == H.repo .. "/src/cart.lua", head_name)
  check("base is revision", vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(wins[2])):find("^review://") ~= nil)
  check("focus head", vim.api.nvim_get_current_win() == wins[3])
  check("cursor at first hunk", vim.api.nvim_win_get_cursor(wins[3])[1] <= 3, vim.api.nvim_win_get_cursor(wins[3]))
  check("base has no filetype", vim.bo[vim.api.nvim_win_get_buf(wins[2])].filetype == "")

  -- Explain sends only the hunk under the cursor, including uncommitted lines.
  rg.config.agent = "oneshot"
  vim.api.nvim_win_set_cursor(wins[3], { 17, 0 })
  rg.action("explain")
  H.wait_answers(agent_buf, 2)
  pane = text(agent_buf)
  check("explain header", pane:find("## Explain · `src/cart.lua:14`", 1, true) ~= nil, pane)
  check("explain answer", pane:find("Plain answer", 1, true) ~= nil, pane)
  check("prompt has hunk", (captured[1] or ""):find("+local line17 = apply_discount(17)", 1, true) ~= nil, captured[1])
  check("prompt hunk excludes first hunk", not (captured[1] or ""):find("line3 = 33", 1, true), captured[1])
  check("prompt has uncommitted line", (captured[1] or ""):find("+local uncommitted = true", 1, true) ~= nil)

  vim.cmd("2,4ReviewAsk why 33?")
  H.wait_answers(agent_buf, 3)
  check("ask range header", text(agent_buf):find("## Ask · `src/cart.lua:2-4`", 1, true) ~= nil, text(agent_buf))
  check(
    "ask prompt",
    (captured[2] or ""):find("^why 33%?") ~= nil and captured[2]:find("head side", 1, true) ~= nil,
    captured[2]
  )

  rg.refs()
  local qf = vim.fn.getqflist()
  check("refs", #qf == 1 and qf[1].lnum == 2, qf)
  vim.cmd("cclose")

  -- <CR> on a path:line in the pane opens that changed file at the line.
  vim.api.nvim_set_current_win(wins[4])
  for i = vim.api.nvim_buf_line_count(agent_buf), 1, -1 do
    if vim.api.nvim_buf_get_lines(agent_buf, i - 1, i, false)[1]:find("discount.lua:2", 1, true) then
      vim.api.nvim_win_set_cursor(wins[4], { i, 0 })
      break
    end
  end
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  check(
    "jump selected file",
    vim.api.nvim_get_current_win() == wins[3] and vim.api.nvim_win_get_cursor(wins[3])[1] == 2,
    vim.api.nvim_win_get_cursor(wins[3])
  )
  check("added file base empty", table.concat(lines(vim.api.nvim_win_get_buf(wins[2])), "") == "")

  local before = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(wins[3]))
  rg.toggle_viewed()
  local after = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(wins[3]))
  check("viewed advances", before ~= after, { before, after })
  check("viewed count", lines(files_buf)[2] == "1/5 viewed", lines(files_buf)[2])

  -- Closing and reopening restores the session, order, viewed marks and transcript without a new tour.
  rg.config.agent = "fake"
  rg.action("explain")
  H.wait_answers(agent_buf, 4)
  rg.close()
  check("tab closed", #vim.api.nvim_list_tabpages() == 1)
  rg.open("")
  vim.wait(5000, function()
    return #vim.api.nvim_list_tabpages() == 2
  end)
  wins = H.review_wins()
  files_buf, agent_buf = vim.api.nvim_win_get_buf(wins[1]), vim.api.nvim_win_get_buf(wins[4])
  vim.wait(300)
  check("reopen viewed kept", lines(files_buf)[2] == "1/5 viewed", lines(files_buf))
  check("reopen order kept", lines(files_buf)[4]:find("discount.lua", 1, true) ~= nil, lines(files_buf))
  check("transcript restored", text(agent_buf):find("Plain answer", 1, true) ~= nil)
  check("no second tour", select(2, text(agent_buf):gsub("## Tour", "")) == 1, text(agent_buf))
  local entry = H.store_entry(H.repo .. "|feature vs main")
  check("session stored", entry and entry.session == "sess-123", entry)

  rg.close()
  rg.open("", true)
  vim.wait(5000, function()
    return #vim.api.nvim_list_tabpages() == 2
  end)
  wins = H.review_wins()
  H.wait_answers(vim.api.nvim_win_get_buf(wins[4]), 1)
  check("fresh: viewed reset", lines(vim.api.nvim_win_get_buf(wins[1]))[2] == "0/5 viewed")
  check("fresh: tour again", text(vim.api.nvim_win_get_buf(wins[4])):find("## Tour", 1, true) ~= nil)

  vim.cmd("tabclose")
  check("manual tabclose resets", pcall(rg.next, 1))
end)
