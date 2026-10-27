local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua").setup()
local check, lines, last_note = H.check, H.lines, H.last_note

assert(vim.fn.exepath("gh"):find("tests/bin/gh$"), "run this spec through tests/run.sh so the fake gh is on PATH")
-- Every file matches the PR head, so only the file this spec dirties later is refused.
H.git("commit", "-qam", "more")
vim.env.GH_FAKE_LOG = H.tmp .. "/gh.log"
vim.env.GH_FAKE_HEAD = H.git("rev-parse", "HEAD")

local function threads()
  local list = {}
  if vim.fn.filereadable(vim.env.GH_FAKE_LOG) == 0 then
    return list
  end
  for _, l in ipairs(vim.fn.readfile(vim.env.GH_FAKE_LOG)) do
    local call = vim.json.decode(l)
    if table.concat(call, " "):find("addPullRequestReviewThread", 1, true) then
      local v = {}
      for i = 1, #call - 1 do
        local k, val = call[i + 1]:match("^([^=]+)=(.*)$")
        if (call[i] == "-f" or call[i] == "-F") and k ~= "query" then
          v[k] = val
        end
      end
      list[#list + 1] = v
    end
  end
  return list
end

local function thread_on(path, line)
  for _, v in ipairs(threads()) do
    if v.path == path and v.line == line then
      return v
    end
  end
end

local function stored()
  local store = vim.json.decode(table.concat(vim.fn.readfile(H.store), "\n"))
  for k, v in pairs(store) do
    if k:find("|feature vs", 1, true) then
      return v.findings
    end
  end
end

local function wait_note(fragment)
  return vim.wait(5000, function()
    return last_note():find(fragment, 1, true) ~= nil
  end, 20)
end

H.run(function()
  local rg = require("agentic_review")
  local review = table.concat({
    "Findings.",
    "",
    "1. **[high]** `src/cart.lua:17` — apply_discount is never defined",
    "Nothing requires the discount module.",
    "Fix: require it.",
    "",
    "Checked the rest.",
    "",
    "[low] ./src/discount.lua:2: rounding drifts",
    "It multiplies floats.",
  }, "\n")
  local deep = table.concat({
    "Checked the hunk and its callers.",
    "",
    "[question] `cart.lua:10`: is line 10 still read?",
    "It sits between the two hunks.",
    "",
    "[medium] src/cart.lua:17: same line as the review finding",
    "",
    "[low] lib/missing.lua:3: not in the change",
    "",
    "### [low] util.lua:2: rounding moved without a test",
    "- the old helper rounded half up",
    "  - and nothing checks it",
    "",
    "[low] docs/README.md:4: More is vague",
    "",
    "[medium] src/discount.lua:3: GitHub refuses this line",
  }, "\n")
  local deep_prompts = {}
  rg.setup({
    agent = "rev",
    auto_tour = false,
    adapters = {
      rev = H.fake_agent(review),
      deep = H.fake_agent(deep, {
        on_prompt = function(prompt)
          deep_prompts[#deep_prompts + 1] = prompt
        end,
      }),
    },
  })
  rg.open("")
  vim.wait(5000, function()
    return #vim.api.nvim_list_tabpages() == 2
  end)
  local files, _, head, agent = unpack(H.review_wins())
  local files_buf, pane = vim.api.nvim_win_get_buf(files), vim.api.nvim_win_get_buf(agent)
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
  local function marks()
    local found = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(head), ns, 0, -1, { details = true })) do
      local d = m[4]
      found[#found + 1] =
        { line = m[2] + 1, text = d.virt_text[1][1], sign = vim.trim(d.sign_text or ""), pos = d.virt_text_pos }
    end
    table.sort(found, function(a, b)
      return a.line < b.line
    end)
    return found
  end
  local function progress()
    return lines(files_buf)[2]
  end

  -- Numbered, bold and dash-separated headings parse, and so does a path with a ./ prefix.
  open(" cart.lua")
  rg.action("review")
  H.wait_answers(pane, 1)
  check("review count", last_note() == "2 findings", last_note())
  local list = stored() or {}
  check(
    "decorated heading parsed",
    list[1]
      and list[1].path == "src/cart.lua"
      and list[1].line == 17
      and list[1].title == "apply_discount is never defined"
      and list[1].detail == "Nothing requires the discount module.\nFix: require it.",
    list[1]
  )
  check("./ prefix resolved", list[2] and list[2].path == "src/discount.lua" and list[2].line == 2, list[2])
  local pns = vim.api.nvim_get_namespaces().agentic_review_pane
  local badge
  for i, l in ipairs(lines(pane)) do
    if l:find("**[high]**", 1, true) then
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(pane, pns, { i - 1, 0 }, { i - 1, -1 }, { details = true })) do
        badge = badge or (m[4].hl_group == "AgenticReviewHigh" and l:sub(m[3] + 1, m[4].end_col))
      end
    end
  end
  check("decorated heading painted", badge == "[high]", badge)

  -- A deep dive adds its findings, resolving bare file names and skipping a line that already has one.
  rg.config.agent = "deep"
  vim.api.nvim_set_current_win(head)
  vim.api.nvim_win_set_cursor(head, { 17, 0 })
  rg.action("deep")
  H.wait_answers(pane, 2)
  check(
    "deep prompt asks for findings",
    (deep_prompts[1] or ""):find("[severity] path:line: title", 1, true) ~= nil,
    deep_prompts[1]
  )
  check("deep note", last_note() == "4 new findings from the deep dive, 1 outside the change", last_note())
  list = stored() or {}
  local by = {}
  for _, x in ipairs(list) do
    by[x.path .. ":" .. x.line] = x
  end
  check("six findings, no duplicate", #list == 6 and by["src/cart.lua:17"].severity == "high", list)
  check("bare name resolved", by["src/cart.lua:10"] and by["src/cart.lua:10"].source == "deep", by["src/cart.lua:10"])
  check(
    "heading finding keeps its list",
    by["src/util.lua:2"]
      and by["src/util.lua:2"].detail == "- the old helper rounded half up\n  - and nothing checks it",
    by["src/util.lua:2"]
  )
  check(
    "marks at the right edge with a sign",
    vim.deep_equal(marks(), {
      { line = 10, text = "[question] is line 10 still read?", sign = "?", pos = "right_align" },
      { line = 17, text = "[high] apply_discount is never defined", sign = "H", pos = "right_align" },
    }),
    marks()
  )
  check("panel counts findings", progress():find("· 6 findings$") ~= nil, progress())

  -- A second review replaces its own findings and keeps the deep dive's.
  rg.config.agent = "rev"
  rg.action("review")
  H.wait_answers(pane, 3)
  list = stored() or {}
  local deep_kept = #vim.tbl_filter(function(x)
    return x.source == "deep"
  end, list)
  check("review keeps deep findings", #list == 6 and deep_kept == 4, list)

  -- A finding outside every hunk becomes a file comment that names its line.
  vim.api.nvim_set_current_win(head)
  vim.api.nvim_win_set_cursor(head, { 10, 0 })
  rg.comment()
  vim.wait(3000, function()
    return #H.floats() == 1
  end)
  local float = H.floats()[1]
  local title = float and vim.api.nvim_win_get_config(float).title[1][1] or ""
  check("file comment title", title:find("src/cart.lua:10 · file comment", 1, true) ~= nil, title)
  local draft = float and lines(vim.api.nvim_win_get_buf(float)) or {}
  check("file comment draft", draft[1] == "Line 10: is line 10 still read?", draft)
  vim.api.nvim_feedkeys(vim.keycode(":write<CR>"), "xt", false)
  wait_note("Added to your pending review")
  local v = threads()[1] or {}
  check(
    "file thread vars",
    v.subjectType == "FILE"
      and v.line == nil
      and v.side == nil
      and v.path == "src/cart.lua"
      and v.body == "Line 10: is line 10 still read?\n\nIt sits between the two hunks.",
    v
  )
  check("posted finding shows as a comment", marks()[1].sign == "C" and marks()[1].line == 10, marks())

  -- C sends the rest: a refused line falls back to a file comment, and a dirty file is reported.
  vim.fn.writefile({ "# Demo", "", "Some text", "More", "local edit" }, H.repo .. "/docs/README.md")
  vim.env.GH_FAKE_REFUSE_LINE = "3"
  vim.api.nvim_set_current_win(files)
  vim.api.nvim_feedkeys("C", "x", false)
  wait_note("Added 4 findings")
  local note = last_note()
  check(
    "summary note",
    note:find("Added 4 findings to your pending review on PR #7, 1 as a file comment", 1, true) ~= nil
      and note:find("1 finding not added:\ndocs/README.md:4: docs/README.md has changes", 1, true) ~= nil,
    note
  )
  v = thread_on("src/cart.lua", "17") or {}
  check(
    "line thread from the review",
    v.side == "RIGHT"
      and v.body == "apply_discount is never defined\n\nNothing requires the discount module.\nFix: require it.",
    v
  )
  v = thread_on("src/util.lua", "2") or {}
  check("deleted file on the base side", v.side == "LEFT" and v.subjectType == nil, v)
  local refused
  for _, t in ipairs(threads()) do
    if t.path == "src/discount.lua" and t.subjectType == "FILE" then
      refused = t
    end
  end
  check("refused line sent as a file comment", refused and refused.body == "Line 3: GitHub refuses this line", refused)
  check("one pending review", #vim.tbl_filter(function(l)
    return l:find("addPullRequestReview(", 1, true) ~= nil
  end, vim.fn.readfile(vim.env.GH_FAKE_LOG)) == 1)
  local posted = #vim.tbl_filter(function(x)
    return x.posted
  end, stored() or {})
  check("posted flags saved", posted == 5, stored())
  check("panel after sending", progress():find("· 1 finding · 5 pending comments$") ~= nil, progress())

  -- Running it again sends only what is left.
  vim.env.GH_FAKE_REFUSE_LINE = nil
  H.git("checkout", "--", "docs/README.md")
  local before = #threads()
  rg.comment_all()
  wait_note("Added 1 finding")
  check("second run sends the rest", #threads() == before + 1 and thread_on("docs/README.md", "4") ~= nil, threads())
  rg.comment_all()
  check("nothing left", last_note():find("No findings to add", 1, true) ~= nil, last_note())

  -- Sent findings stay sent after the review reopens.
  rg.close()
  rg.open("")
  vim.wait(5000, function()
    return #vim.api.nvim_list_tabpages() == 2
  end)
  files, _, head = unpack(H.review_wins())
  files_buf = vim.api.nvim_win_get_buf(files)
  open(" cart.lua")
  check("no marks for sent findings", #marks() == 0, marks())
  check("panel shows no findings", progress():find("finding") == nil, progress())
end)
