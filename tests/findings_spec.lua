local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua").setup()
local check, lines, text = H.check, H.lines, H.text

H.run(function()
  local rg = require("agentic_review")
  local answer = table.concat({
    "Two problems.",
    "",
    "[high] src/cart.lua:17: `apply_discount` is never defined",
    "Nothing requires the discount module.",
    "",
    "[question] src/cart.lua:3: is 33 the value the ticket asks for?",
    "",
    "- [low] `src/discount.lua:2`: rounding drifts",
    "It multiplies floats.",
  }, "\n")
  local prompts, models = {}, {}
  local fake = H.fake_agent(answer, {
    tool = H.repo .. "/src/cart.lua",
    on_spawn = function(ctx)
      models[#models + 1] = ctx.model
    end,
    on_prompt = function(prompt)
      prompts[#prompts + 1] = prompt
    end,
  })
  fake.models = { review = "big" }
  rg.setup({ agent = "fake", auto_tour = false, adapters = { fake = fake } })

  vim.cmd("edit src/cart.lua")
  rg.action("review")
  check("needs the review tab", H.last_note():find("needs the review tab", 1, true) ~= nil, H.last_note())

  rg.open("")
  vim.wait(5000, function()
    return #vim.api.nvim_list_tabpages() == 2
  end)
  local files, _, head, agent = unpack(H.review_wins())
  local pane = vim.api.nvim_win_get_buf(agent)
  local ns = vim.api.nvim_get_namespaces().agentic_review_comments

  local function open(name)
    vim.api.nvim_set_current_win(files)
    for i, l in ipairs(lines(vim.api.nvim_win_get_buf(files))) do
      if l:find(name, 1, true) then
        vim.api.nvim_win_set_cursor(files, { i, 0 })
      end
    end
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  end

  local function marks()
    local found = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(head), ns, 0, -1, { details = true })) do
      local chunk = m[4].virt_text[1]
      found[#found + 1] = { line = m[2] + 1, text = vim.trim(chunk[1]), hl = chunk[2] }
    end
    return found
  end

  open(" cart.lua")
  rg.action("review")
  H.wait_answers(pane, 1)
  check("review header", text(pane):find("## Review", 1, true) ~= nil, text(pane))

  -- The pane colours tool calls, severity badges, titles, path:line references and timing lines.
  local pns = vim.api.nvim_get_namespaces().agentic_review_pane
  local function painted(fragment)
    for i, l in ipairs(lines(pane)) do
      if l:find(fragment, 1, true) then
        local groups = {}
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(pane, pns, { i - 1, 0 }, { i - 1, -1 }, { details = true })) do
          groups[#groups + 1] = l:sub(m[3] + 1, m[4].end_col) .. "=" .. m[4].hl_group
        end
        table.sort(groups)
        return groups
      end
    end
  end
  check(
    "tool line colours",
    vim.deep_equal(painted("> Read"), { "Read=AgenticReviewTool", "`src/cart.lua`=AgenticReviewCommand" }),
    painted("> Read")
  )
  check(
    "finding colours",
    vim.deep_equal(painted("[high]"), {
      "[high]=AgenticReviewHigh",
      "apply_discount` is never defined=AgenticReviewTitle",
      "src/cart.lua:17=AgenticReviewRef",
    }),
    painted("[high]")
  )
  check(
    "timing line dimmed",
    vim.deep_equal(painted("s_"), { lines(pane)[#lines(pane) - 1] .. "=AgenticReviewMeta" }),
    painted("s_")
  )
  local badge = vim.api.nvim_get_hl(0, { name = "AgenticReviewHigh" })
  check("severity badge has a background", badge.bg ~= nil or badge.link ~= nil, badge)
  vim.api.nvim_set_hl(0, "AgenticReviewTool", { fg = 0xff00ff })
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  check("user colours survive", vim.api.nvim_get_hl(0, { name = "AgenticReviewTool" }).fg == 0xff00ff)
  check(
    "whole change in prompt",
    (prompts[1] or ""):find("careful reviewer", 1, true) ~= nil and prompts[1]:find("src/discount.lua", 1, true) ~= nil,
    prompts[1]
  )
  check("history pass for a shell agent", prompts[1]:find("git blame", 1, true) ~= nil)
  check("confidence filter", prompts[1]:find("drop anything under 80", 1, true) ~= nil)
  check("review model", models[1] == "big", models)
  check("count note", H.last_note() == "3 findings", H.last_note())
  local want = {
    { line = 3, text = "[question] is 33 the value the ticket asks for?", hl = "DiagnosticHint" },
    { line = 17, text = "[high] apply_discount is never defined", hl = "DiagnosticError" },
  }
  check("finding marked in diff", vim.deep_equal(marks(), want), marks())

  open(" discount.lua")
  want = { { line = 2, text = "[low] rounding drifts", hl = "DiagnosticInfo" } }
  check("finding follows file", vim.deep_equal(marks(), want), marks())

  -- Findings are saved with the review and come back when it reopens.
  rg.close()
  rg.open("")
  vim.wait(5000, function()
    return #vim.api.nvim_list_tabpages() == 2
  end)
  files, _, head = unpack(H.review_wins())
  open(" cart.lua")
  check("findings restored", #marks() == 2 and marks()[2].line == 17, marks())

  -- r in the files panel runs the review again.
  pane = vim.api.nvim_win_get_buf(H.review_wins()[4])
  local before = H.answers(pane)
  vim.api.nvim_set_current_win(files)
  vim.api.nvim_feedkeys("r", "x", false)
  H.wait_answers(pane, before + 1)
  check("r reviews again", #prompts == 2 and prompts[2]:find("careful reviewer", 1, true) ~= nil)

  -- c on a finding's paragraph drafts a pending GitHub comment from it, at the finding's line.
  vim.env.GH_FAKE_LOG, vim.env.GH_FAKE_HEAD = H.tmp .. "/gh.log", H.head
  local agent_win = H.review_wins()[4]
  local function pane_cursor(fragment)
    vim.api.nvim_set_current_win(agent_win)
    for i = vim.api.nvim_buf_line_count(pane), 1, -1 do
      if vim.api.nvim_buf_get_lines(pane, i - 1, i, false)[1]:find(fragment, 1, true) then
        return vim.api.nvim_win_set_cursor(agent_win, { i, 0 })
      end
    end
  end
  pane_cursor("Two problems.")
  vim.api.nvim_feedkeys("c", "x", false)
  check("c outside a finding", H.last_note():find("Move the cursor to a finding", 1, true) ~= nil, H.last_note())

  pane_cursor("It multiplies floats.")
  vim.api.nvim_feedkeys("c", "x", false)
  vim.wait(3000, function()
    return #H.floats() == 1
  end)
  local float = H.floats()[1]
  local draft = float and lines(vim.api.nvim_win_get_buf(float)) or {}
  check("draft from finding", vim.deep_equal(draft, { "rounding drifts", "", "It multiplies floats." }), draft)
  local title = float and vim.api.nvim_win_get_config(float).title[1][1] or ""
  check("draft at finding line", title:find("src/discount.lua:2", 1, true) ~= nil, title)
  check("draft opens in normal mode", vim.api.nvim_get_mode().mode == "n")
  vim.api.nvim_feedkeys(vim.keycode(":write<CR>"), "xt", false)
  vim.wait(5000, function()
    return H.last_note():find("Added to your pending review", 1, true) ~= nil
  end)
  local thread
  for _, l in ipairs(vim.fn.readfile(vim.env.GH_FAKE_LOG)) do
    local call = vim.json.decode(l)
    if table.concat(call, " "):find("addPullRequestReviewThread", 1, true) then
      thread = {}
      for i = 1, #call - 1 do
        local k, v = call[i + 1]:match("^([^=]+)=(.*)$")
        if (call[i] == "-f" or call[i] == "-F") and k ~= "query" then
          thread[k] = v
        end
      end
    end
  end
  check(
    "finding sent as thread",
    thread
      and thread.path == "src/discount.lua"
      and thread.line == "2"
      and thread.side == "RIGHT"
      and thread.body == "rounding drifts\n\nIt multiplies floats.",
    thread
  )

  check("claude reviews on opus", rg.adapters.claude.models.review == "opus")
end)
