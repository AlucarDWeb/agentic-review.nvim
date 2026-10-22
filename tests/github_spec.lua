local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua").setup()
local check, last_note = H.check, H.last_note

vim.env.GH_FAKE_LOG = H.tmp .. "/gh.log"
vim.env.GH_FAKE_HEAD = H.head
assert(vim.fn.exepath("gh"):find("tests/bin/gh$"), "run this spec through tests/run.sh so the fake gh is on PATH")

local function calls()
  local list = {}
  if vim.fn.filereadable(vim.env.GH_FAKE_LOG) == 1 then
    for _, l in ipairs(vim.fn.readfile(vim.env.GH_FAKE_LOG)) do
      list[#list + 1] = vim.json.decode(l)
    end
  end
  return list
end

local function query_of(call)
  for _, a in ipairs(call) do
    if a:find("^query=") then
      return a
    end
  end
  return ""
end

local function calls_with(fragment)
  return vim.tbl_filter(function(call)
    return query_of(call):find(fragment, 1, true) ~= nil
  end, calls())
end

local function vars(call)
  local v = {}
  for i = 1, #(call or {}) - 1 do
    if call[i] == "-f" or call[i] == "-F" then
      local k, val = call[i + 1]:match("^([^=]+)=(.*)$")
      if k ~= "query" then
        v[k] = val
      end
    end
  end
  return v
end

local function compose_buf()
  for _, w in ipairs(H.floats()) do
    return vim.api.nvim_win_get_buf(w), w
  end
end

-- Headless Neovim applies the float's pending startinsert only once keys arrive, so leave insert mode first.
local function normal(keys)
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

-- What typing in the float does: run an Ex command from the command line.
local function typed(cmd)
  normal(":" .. cmd .. "<CR>")
end

H.run(function()
  local rg = require("agentic_review")
  rg.setup({
    agent = {
      name = "none",
      cmd = function()
        return { "true" }
      end,
    },
    auto_tour = false,
  })
  rg.open("")
  vim.wait(5000, function()
    return #vim.api.nvim_list_tabpages() == 2
  end)
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local files_buf = vim.api.nvim_win_get_buf(wins[1])
  local function open_file(name)
    vim.api.nvim_set_current_win(wins[1])
    for i, l in ipairs(H.lines(files_buf)) do
      if l:find(name, 1, true) then
        vim.api.nvim_win_set_cursor(wins[1], { i, 0 })
      end
    end
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  end
  local function panel_progress()
    return vim.api.nvim_buf_get_lines(files_buf, 1, 2, false)[1]
  end

  -- The head side of a file with uncommitted changes would not match GitHub's line numbers.
  open_file("cart.lua")
  vim.api.nvim_win_set_cursor(wins[3], { 17, 0 })
  rg.comment()
  vim.wait(3000, function()
    return last_note():find("not in the PR", 1, true) ~= nil
  end)
  check("dirty head side refused", last_note():find("src/cart.lua has changes that are not in the PR", 1, true) ~= nil)
  check("no float when refused", compose_buf() == nil)

  local before = #calls()
  vim.api.nvim_set_current_win(wins[2])
  vim.api.nvim_win_set_cursor(wins[2], { 10, 0 })
  rg.comment()
  check("outside diff refused before gh", last_note():find("outside the diff", 1, true) ~= nil and #calls() == before)

  -- A base side comment creates the pending review, then adds a thread to it.
  vim.api.nvim_win_set_cursor(wins[2], { 3, 0 })
  rg.comment()
  vim.wait(3000, function()
    return compose_buf() ~= nil
  end)
  local buf, win = compose_buf()
  check("compose float opened", buf ~= nil)
  local title = win and vim.api.nvim_win_get_config(win).title
  check("compose title", title and title[1][1]:find("PR #7 · src/cart.lua:3 (base)", 1, true) ~= nil, title)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Why 33?", "Second line." })
  typed("write")
  vim.wait(5000, function()
    return last_note():find("Added to your pending review", 1, true) ~= nil
  end)
  vim.wait(100)
  local start, threads = calls_with("addPullRequestReview("), calls_with("addPullRequestReviewThread")
  check(
    "pending review created once",
    #start == 1 and vars(start[1]).commit == H.head and vars(start[1]).pr == "PR_7",
    start
  )
  local v = vars(threads[1])
  check(
    "thread vars",
    #threads == 1
      and v.line == "3"
      and v.side == "LEFT"
      and v.path == "src/cart.lua"
      and v.startLine == nil
      and v.body == "Why 33?\nSecond line."
      and v.review == "PRR_1",
    v
  )
  check("float closed after write", compose_buf() == nil)
  check("still four review windows", #vim.api.nvim_tabpage_list_wins(0) == 4)
  check("panel counts comment", panel_progress():find("1 pending comment$") ~= nil, panel_progress())
  local ns = vim.api.nvim_create_namespace("agentic_review_comments")
  local marks = vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(wins[2]), ns, 0, -1, { details = true })
  check("comment mark on base line 3", #marks == 1 and marks[1][2] == 2 and marks[1][4].virt_text[1][1] == "  Why 33?")

  -- A head side range with a suggestion block, sent with :wq, reuses the pending review.
  open_file("discount.lua")
  vim.cmd("1,2ReviewComment")
  vim.wait(3000, function()
    return compose_buf() ~= nil
  end)
  buf = compose_buf()
  vim.cmd("stopinsert")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Round this." })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_feedkeys("gs", "x", false)
  local body = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  check(
    "suggestion block",
    body == "Round this.\n```suggestion\nlocal M = {}\nfunction M.apply(x) return x * 0.9 end\n```",
    body
  )
  typed("wq")
  vim.wait(5000, function()
    return #calls_with("addPullRequestReviewThread") == 2
  end)
  vim.wait(100)
  v = vars(calls_with("addPullRequestReviewThread")[2])
  check(
    "range thread vars",
    v.startLine == "1"
      and v.startSide == "RIGHT"
      and v.line == "2"
      and v.side == "RIGHT"
      and v.path == "src/discount.lua",
    v
  )
  check("no second pending review", #calls_with("addPullRequestReview(") == 1)
  check(":wq closed only the float", #vim.api.nvim_tabpage_list_wins(0) == 4, #vim.api.nvim_tabpage_list_wins(0))

  -- Autosave plugins write every modified buffer; only a command typed in the float sends the comment.
  before = #calls()
  vim.api.nvim_win_set_cursor(wins[3], { 1, 0 })
  rg.comment()
  vim.wait(3000, function()
    return compose_buf() ~= nil
  end)
  vim.api.nvim_buf_set_lines(compose_buf(), 0, -1, false, { "autosaved draft" })
  vim.cmd("silent! wall")
  vim.wait(300)
  check("autosave does not send", compose_buf() ~= nil and #calls() == before, #calls() - before)
  normal("q")
  vim.wait(200)
  check("q cancels without sending", compose_buf() == nil and #calls() == before, #calls() - before)

  vim.api.nvim_win_set_cursor(wins[3], { 2, 0 })
  rg.comment()
  vim.wait(3000, function()
    return compose_buf() ~= nil
  end)
  vim.api.nvim_buf_set_lines(compose_buf(), 0, -1, false, { "via ctrl-s" })
  vim.api.nvim_feedkeys(vim.keycode("<C-s>"), "xt", false)
  vim.wait(5000, function()
    return #calls_with("addPullRequestReviewThread") == 3
  end)
  check("<C-s> sends", vars(calls_with("addPullRequestReviewThread")[3]).body == "via ctrl-s")

  vim.ui.select = function(_, _, cb)
    cb("Approve")
  end
  vim.ui.input = function(_, cb)
    cb("LGTM")
  end
  rg.submit()
  vim.wait(5000, function()
    return last_note():find("Review submitted", 1, true) ~= nil
  end)
  v = vars(calls_with("submitPullRequestReview")[1])
  check("submit vars", v.event == "APPROVE" and v.body == "LGTM" and v.review == "PRR_1", v)
  check("comments cleared", panel_progress():find("pending") == nil, panel_progress())
  rg.submit()
  vim.wait(3000, function()
    return last_note():find("no pending review", 1, true) ~= nil
  end)
  check("submit without pending", last_note():find("You have no pending review on PR #7", 1, true) ~= nil)

  -- A local HEAD that differs from the PR head would put comments on the wrong lines.
  rg.close()
  vim.env.GH_FAKE_HEAD = "0123456789abcdef0123456789abcdef01234567"
  rg.open("")
  vim.wait(5000, function()
    return #vim.api.nvim_list_tabpages() == 2
  end)
  wins = vim.api.nvim_tabpage_list_wins(0)
  files_buf = vim.api.nvim_win_get_buf(wins[1])
  open_file("discount.lua")
  vim.api.nvim_win_set_cursor(wins[3], { 2, 0 })
  rg.comment()
  vim.wait(3000, function()
    return last_note():find("is not the PR head", 1, true) ~= nil
  end)
  check("head mismatch refused", last_note():find("is not the PR head 01234567", 1, true) ~= nil, last_note())
  rg.close()
  local real = vim.fn.bufnr(H.repo .. "/src/discount.lua")
  check("marks cleared on real buffer after close", #vim.api.nvim_buf_get_extmarks(real, ns, 0, -1, {}) == 0)
end)
