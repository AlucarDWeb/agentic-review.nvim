local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua").setup()
local check, lines, text = H.check, H.lines, H.text

H.run(function()
  local rg = require("agentic_review")
  local report = table.concat({
    "# Review report",
    "",
    "4 inline finding(s) would be posted.",
    "",
    "## Critical (severity >= 7)",
    "",
    "### `src/cart.lua:17` (severity 8)",
    "",
    "`apply_discount` is never defined.",
    "",
    "## Important (severity 4-6)",
    "",
    "### `src/cart.lua:3` (severity 5)",
    "",
    "33 looks arbitrary.",
    "",
    "### `elsewhere/x.lua:1` (severity 6)",
    "",
    "Off the change.",
    "",
    "## Suggestions (severity <= 3)",
    "",
    "### `src/discount.lua:2` (severity 2)",
    "",
    "Rounding drifts.",
    "",
    "It multiplies floats.",
    "",
    "```suggestion",
    "# not a heading",
    "return math.floor(x * 100 + 0.5) / 100",
    "```",
    "",
    "## Review body (summary / off-diff findings)",
    "",
    "Summary text.",
  }, "\n")
  local prompts, contexts = {}, {}
  local fake = H.fake_agent(report, {
    on_prompt = function(prompt)
      prompts[#prompts + 1] = prompt
    end,
  })
  rg.setup({
    agent = "fake",
    auto_tour = false,
    adapters = { fake = fake },
    review_prompt = function(ctx)
      contexts[#contexts + 1] = ctx
      return ctx.pr and ("/my-review " .. ctx.pr) or "/my-review"
    end,
  })

  vim.cmd("edit src/cart.lua")
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
  check("prompt sent as is", prompts[1] == "/my-review", prompts[1])
  check("context", contexts[1] and contexts[1].root == H.repo and contexts[1].pr == nil, contexts[1])
  check("count note", H.last_note() == "3 findings, 1 outside the change", H.last_note())
  local want = {
    { line = 3, text = "[medium] 33 looks arbitrary.", hl = "DiagnosticWarn" },
    { line = 17, text = "[high] apply_discount is never defined.", hl = "DiagnosticError" },
  }
  check("heading findings marked", vim.deep_equal(marks(), want), marks())

  local pns = vim.api.nvim_get_namespaces().agentic_review_pane
  local badge
  for i, l in ipairs(lines(pane)) do
    if l:find("(severity 8)", 1, true) then
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(pane, pns, { i - 1, 0 }, { i - 1, -1 }, { details = true })) do
        if m[4].hl_group ~= "AgenticReviewRef" then
          badge = l:sub(m[3] + 1, m[4].end_col) .. "=" .. m[4].hl_group
        end
      end
    end
  end
  check("score painted as badge", badge == "(severity 8)=AgenticReviewHigh", badge)

  open(" discount.lua")
  want = { { line = 2, text = "[low] Rounding drifts.", hl = "DiagnosticInfo" } }
  check("low score", vim.deep_equal(marks(), want), marks())

  -- c on any paragraph of a heading finding drafts its whole body, code block included.
  vim.env.GH_FAKE_LOG, vim.env.GH_FAKE_HEAD = H.tmp .. "/gh.log", H.head
  vim.api.nvim_set_current_win(agent)
  for i = vim.api.nvim_buf_line_count(pane), 1, -1 do
    if vim.api.nvim_buf_get_lines(pane, i - 1, i, false)[1]:find("not a heading", 1, true) then
      vim.api.nvim_win_set_cursor(agent, { i, 0 })
      break
    end
  end
  vim.api.nvim_feedkeys("c", "x", false)
  vim.wait(3000, function()
    return #H.floats() == 1
  end)
  local float = H.floats()[1]
  local draft = float and lines(vim.api.nvim_win_get_buf(float)) or {}
  check(
    "draft is the whole body",
    vim.deep_equal(draft, {
      "Rounding drifts.",
      "",
      "It multiplies floats.",
      "",
      "```suggestion",
      "# not a heading",
      "return math.floor(x * 100 + 0.5) / 100",
      "```",
    }),
    draft
  )
  if float then
    vim.api.nvim_win_close(float, true)
  end

  vim.api.nvim_set_current_win(agent)
  for i, l in ipairs(lines(pane)) do
    if l == "Summary text." then
      vim.api.nvim_win_set_cursor(agent, { i, 0 })
    end
  end
  vim.api.nvim_feedkeys("c", "x", false)
  check("summary is no finding", H.last_note():find("Move the cursor to a finding", 1, true) ~= nil, H.last_note())

  rg.config.review_prompt = "/other-review"
  rg.action("review")
  H.wait_answers(pane, 2)
  check("string prompt", prompts[2] == "/other-review", prompts[2])
  check("pane shows report", text(pane):find("Review report", 1, true) ~= nil)

  rg.config.review_prompt = function() end
  rg.action("review")
  H.wait_answers(pane, 3)
  check(
    "nil falls back to the built-in prompt",
    (prompts[3] or ""):find("careful reviewer", 1, true) ~= nil,
    prompts[3]
  )
end)
