local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua").setup()
local check, lines = H.check, H.lines

H.run(function()
  local rg = require("agentic_review")
  local long = ("The ticket asks for 30, and every caller rounds the value again before showing it. "):rep(4)
  local answer = table.concat({
    "Three problems.",
    "",
    "[medium] src/cart.lua:3: 33 looks arbitrary",
    vim.trim(long),
    "",
    "[high] src/cart.lua:17: apply_discount is never defined",
    "Nothing requires the discount module.",
    "",
    "[low] src/discount.lua:2: rounding drifts",
    "It multiplies floats.",
    "",
    "[question] elsewhere.lua:1: outside the change",
  }, "\n")
  rg.setup({ agent = "fake", auto_tour = false, adapters = { fake = H.fake_agent(answer) } })
  rg.open("")
  vim.wait(5000, function()
    return #vim.api.nvim_list_tabpages() == 2
  end)
  local files, base, head, agent = unpack(H.review_wins())
  local pane = vim.api.nvim_win_get_buf(agent)
  local function open(name)
    vim.api.nvim_set_current_win(files)
    for i, l in ipairs(lines(vim.api.nvim_win_get_buf(files))) do
      if l:find(name, 1, true) then
        vim.api.nvim_win_set_cursor(files, { i, 0 })
      end
    end
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  end

  open(" cart.lua")
  rg.action("review")
  H.wait_answers(pane, 1)

  local function row(needle)
    for i, l in ipairs(lines(pane)) do
      if l == needle then
        return i
      end
    end
  end
  local high, medium, low = row("### High (1)"), row("### Medium (1)"), row("### Low (1)")
  check("grouped by severity", high and medium and low and high < medium and medium < low, lines(pane))
  check("no group for findings outside the change", row("### Question (1)") == nil)
  check(
    "group lists its findings",
    high and lines(pane)[high + 2] == "[high] src/cart.lua:17: apply_discount is never defined",
    lines(pane)
  )

  local cns = vim.api.nvim_get_namespaces().agentic_review_comments
  local ans = vim.api.nvim_get_namespaces().agentic_review_align
  local function below(lnum)
    local buf = vim.api.nvim_win_get_buf(head)
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, cns, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })) do
      if m[4].virt_lines then
        return vim.tbl_map(function(l)
          return l[2][1]
        end, m[4].virt_lines)
      end
    end
    return {}
  end
  local detail = below(3)
  local info = vim.fn.getwininfo(head)[1]
  local width = vim.api.nvim_win_get_width(head) - info.textoff - 4
  check("detail under the line", table.concat(detail, " ") == vim.trim(long), detail)
  check("detail wrapped to the window", #detail > 1 and #vim.tbl_filter(function(l)
    return vim.fn.strdisplaywidth(l) > width
  end, detail) == 0, detail)
  check("short detail is one line", vim.deep_equal(below(17), { "Nothing requires the discount module." }), below(17))

  local blanks = {}
  local base_buf = vim.api.nvim_win_get_buf(base)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(base_buf, ans, 0, -1, { details = true })) do
    blanks[#blanks + 1] = { line = m[2] + 1, count = #m[4].virt_lines }
  end
  check(
    "base side padded at the same lines",
    vim.deep_equal(blanks, { { line = 3, count = #detail }, { line = 17, count = 1 } }),
    blanks
  )
  vim.api.nvim_win_set_cursor(head, { 1, 0 })
  vim.cmd("redraw")
  local left, right = vim.fn.screenpos(base, 20, 1).row, vim.fn.screenpos(head, 20, 1).row
  check("sides stay level", left > 0 and left == right, { left, right })

  vim.env.GH_FAKE_LOG, vim.env.GH_FAKE_HEAD = H.tmp .. "/gh.log", H.head
  vim.api.nvim_set_current_win(agent)
  vim.api.nvim_win_set_cursor(agent, { low + 2, 0 })
  vim.api.nvim_feedkeys("c", "x", false)
  vim.wait(3000, function()
    return #H.floats() == 1
  end)
  local float = H.floats()[1]
  local draft = float and lines(vim.api.nvim_win_get_buf(float)) or {}
  check(
    "c on a grouped finding drafts it",
    vim.deep_equal(draft, { "rounding drifts", "", "It multiplies floats." }),
    draft
  )
end)
