local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua").setup()
local check, lines, last_note = H.check, H.lines, H.last_note

assert(vim.fn.exepath("gh"):find("tests/bin/gh$"), "run this spec through tests/run.sh so the fake gh is on PATH")
vim.env.GH_FAKE_LOG = H.tmp .. "/gh.log"
vim.env.GH_FAKE_HEAD = H.head
vim.env.GH_FAKE_THREADS = H.tmp .. "/threads.json"

local function thread(path, line, side, resolved, comments)
  return {
    id = ("PRRT_%s_%s"):format(path, tostring(line)),
    isResolved = resolved,
    path = path,
    line = line or vim.NIL,
    diffSide = side,
    comments = { nodes = comments },
  }
end
vim.fn.writefile({
  vim.json.encode({
    thread("src/cart.lua", 17, "RIGHT", false, {
      { author = { login = "alice" }, body = "\r\nWhy apply_discount here?\r\nIt is global." },
      { author = { login = "bob" }, body = "Agreed." },
    }),
    thread("src/cart.lua", 3, "LEFT", false, { { author = vim.NIL, body = "Old value was fine" } }),
    thread("src/cart.lua", 5, "RIGHT", true, { { author = { login = "carol" }, body = "done" } }),
    thread("src/discount.lua", nil, "RIGHT", false, { { author = { login = "dan" }, body = "outdated" } }),
  }),
}, vim.env.GH_FAKE_THREADS)

local function thread_loads()
  return #vim.tbl_filter(function(l)
    return l:find("reviewThreads(", 1, true) ~= nil
  end, vim.fn.readfile(vim.env.GH_FAKE_LOG))
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
  local files, base, head = unpack(H.review_wins())
  local files_buf = vim.api.nvim_win_get_buf(files)
  local ns = vim.api.nvim_get_namespaces().agentic_review_comments
  local function open(name)
    vim.api.nvim_set_current_win(files)
    for i, l in ipairs(lines(files_buf)) do
      if l:find(name, 1, true) then
        vim.api.nvim_win_set_cursor(files, { i, 0 })
      end
    end
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  end
  local function marks(win)
    local found = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(win), ns, 0, -1, { details = true })) do
      found[#found + 1] = { line = m[2] + 1, text = m[4].virt_text[1][1], sign = vim.trim(m[4].sign_text or "") }
    end
    return found
  end

  -- Open threads load with the review and sit on their side of the diff.
  open(" cart.lua")
  vim.wait(5000, function()
    return #marks(head) > 0
  end)
  check(
    "head thread with reply count",
    vim.deep_equal(marks(head), { { line = 17, text = "alice: Why apply_discount here? +1", sign = "C" } }),
    marks(head)
  )
  check(
    "base thread, deleted author",
    vim.deep_equal(marks(base), { { line = 3, text = "ghost: Old value was fine", sign = "C" } }),
    marks(base)
  )
  check("panel counts open threads", lines(files_buf)[2]:find("· 2 threads$") ~= nil, lines(files_buf)[2])

  -- :ReviewThread reads the whole thread under the cursor.
  vim.api.nvim_set_current_win(head)
  vim.api.nvim_win_set_cursor(head, { 17, 0 })
  vim.cmd("ReviewThread")
  local float = H.floats()[1]
  local body = float and lines(vim.api.nvim_win_get_buf(float)) or {}
  check(
    "thread float",
    vim.deep_equal(body, { "**alice**", "", "Why apply_discount here?", "It is global.", "", "**bob**", "Agreed." }),
    body
  )
  local title = float and vim.api.nvim_win_get_config(float).title[1][1] or ""
  check("thread float title", title == " src/cart.lua:17 ", title)
  vim.api.nvim_feedkeys("q", "x", false)
  check("q closes the thread", #H.floats() == 0)
  vim.api.nvim_win_set_cursor(head, { 1, 0 })
  rg.thread()
  check("line without threads", last_note() == "No open GitHub comments on line 1", last_note())

  -- The go-to-file picker counts each file's open threads.
  rg.files()
  local picker = H.floats()[1]
  local pbuf = picker and vim.api.nvim_win_get_buf(picker)
  local function right_text(fragment)
    local pns = vim.api.nvim_get_namespaces().agentic_review_pane
    for i, l in ipairs(lines(pbuf)) do
      if l:find(fragment, 1, true) then
        local out = {}
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(pbuf, pns, { i - 1, 0 }, { i - 1, -1 }, { details = true })) do
          if m[4].virt_text_pos == "right_align" then
            for _, chunk in ipairs(m[4].virt_text) do
              out[#out + 1] = chunk[1]
            end
          end
        end
        return table.concat(out)
      end
    end
    return ""
  end
  check("picker counts threads", right_text(" cart.lua"):find("^2 threads  ") ~= nil, right_text(" cart.lua"))
  check("picker skips outdated threads", not right_text(" discount.lua"):find("thread"), right_text(" discount.lua"))
  vim.api.nvim_feedkeys("q", "x", false)

  -- r in the thread float replies to that thread in the pending review.
  vim.api.nvim_set_current_win(head)
  vim.api.nvim_win_set_cursor(head, { 17, 0 })
  vim.cmd("ReviewThread")
  vim.api.nvim_feedkeys("r", "x", false)
  vim.wait(3000, function()
    local w = H.floats()[1]
    return w and vim.api.nvim_win_get_config(w).title[1][1]:find("reply on src/cart.lua:17", 1, true) ~= nil
  end)
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(H.floats()[1]), 0, -1, false, { "Fixed in the next commit" })
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
  vim.api.nvim_feedkeys(vim.keycode(":write<CR>"), "xt", false)
  local replied = vim.wait(5000, function()
    return last_note():find("Reply added to your pending review", 1, true) ~= nil
  end)
  check("reply added", replied, H.notes)
  local call = vim.tbl_filter(function(l)
    return l:find("addPullRequestReviewThreadReply", 1, true) ~= nil
  end, vim.fn.readfile(vim.env.GH_FAKE_LOG))[1] or ""
  check(
    "reply goes to the thread and the pending review",
    call:find("thread=PRRT_src/cart.lua_17", 1, true)
      and call:find("review=PRR_1", 1, true)
      and call:find("body=Fixed in the next commit", 1, true),
    call
  )
  check(
    "reply counted on the mark",
    vim.deep_equal(marks(head), { { line = 17, text = "alice: Why apply_discount here? +2", sign = "C" } }),
    marks(head)
  )
  vim.api.nvim_set_current_win(head)
  vim.cmd("ReviewThread")
  float = H.floats()[1]
  body = float and lines(vim.api.nvim_win_get_buf(float)) or {}
  check(
    "reply in the float",
    vim.deep_equal(vim.list_slice(body, 8), { "", "**me** · pending", "Fixed in the next commit" }),
    body
  )
  vim.api.nvim_feedkeys("q", "x", false)

  -- A comment this session added that GitHub already lists is drawn once.
  vim.api.nvim_set_current_win(base)
  vim.api.nvim_win_set_cursor(base, { 3, 0 })
  rg.comment()
  vim.wait(3000, function()
    return #H.floats() == 1
  end)
  vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(H.floats()[1]), 0, -1, false, { "Old value was fine" })
  -- Headless Neovim applies the float's pending startinsert only once keys arrive, so leave insert mode first.
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
  vim.api.nvim_feedkeys(vim.keycode(":write<CR>"), "xt", false)
  local sent = vim.wait(5000, function()
    return last_note():find("Added to your pending review", 1, true) ~= nil
  end)
  check("no duplicate mark", sent and #marks(base) == 1, { sent, marks(base), H.notes })

  -- Submitting loads the threads again, so the comments just sent show from GitHub.
  local before = thread_loads()
  vim.ui.select = function(_, _, cb)
    cb("Comment")
  end
  rg.submit()
  vim.wait(3000, function()
    return #H.floats() == 1
  end)
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
  vim.api.nvim_feedkeys(vim.keycode(":write<CR>"), "xt", false)
  vim.wait(5000, function()
    return thread_loads() > before
  end)
  check("threads reload after submit", thread_loads() == before + 1, { before, thread_loads(), last_note() })

  open(" discount.lua")
  check("outdated thread left out", #marks(head) == 0, marks(head))
end)
