local M = {}

M.adapters = {}

M.config = {
  -- Name of an adapter in `adapters` or M.adapters, or an adapter table.
  agent = "claude",
  adapters = {},
  model = nil,
  models = {},
  files_height = 8,
  agent_width = 0.33,
  agent_height = 0.33,
  min_diff_width = 80,
  float_width = 100,
  float_height = 15,
  auto_tour = true,
  max_context_lines = 300,
  max_tour_lines = 1500,
}

local function decode(line)
  local ok, ev = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  return ok and type(ev) == "table" and ev or nil
end

local CLAUDE_TOOLS = table.concat({
  "Read",
  "Grep",
  "Glob",
  "Bash(git diff:*)",
  "Bash(git show:*)",
  "Bash(git log:*)",
  "Bash(git blame:*)",
  "Bash(git grep:*)",
}, ",")

M.adapters.claude = {
  persistent = true,
  shell = true,
  models = { tour = "sonnet", explain = "sonnet", explore = "sonnet", deep = "opus", ask = "sonnet", review = "opus" },
  cmd = function(ctx)
    local cmd = {
      "claude",
      "-p",
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
      "--verbose",
      "--include-partial-messages",
      "--tools",
      "Read,Grep,Glob,Bash",
      "--allowedTools",
      CLAUDE_TOOLS,
      -- dontAsk denies every tool call outside the allowlist instead of prompting, which headless mode cannot do.
      "--permission-mode",
      "dontAsk",
      "--strict-mcp-config",
      "--append-system-prompt",
      ctx.system,
      "--name",
      "review: " .. ctx.label,
    }
    if ctx.model then
      vim.list_extend(cmd, { "--model", ctx.model })
    end
    if ctx.session then
      vim.list_extend(cmd, { "--resume", ctx.session })
    end
    return cmd
  end,
  encode = function(prompt)
    return vim.json.encode({ type = "user", message = { role = "user", content = prompt } })
  end,
  set_model = function(model)
    return vim.json.encode({
      type = "control_request",
      request_id = "model-" .. vim.uv.hrtime(),
      request = { subtype = "set_model", model = model },
    })
  end,
  parse = function(line, emit)
    local ev = decode(line)
    if not ev then
      return
    end
    if ev.type == "system" and ev.subtype == "init" then
      emit.session(ev.session_id)
    elseif ev.type == "stream_event" then
      local e = ev.event
      if e and e.type == "content_block_delta" and e.delta and e.delta.type == "text_delta" then
        emit.text(e.delta.text)
      end
    elseif ev.type == "assistant" and ev.message then
      for _, block in ipairs(ev.message.content or {}) do
        if block.type == "tool_use" then
          emit.tool(block.name, block.input)
        end
      end
    elseif ev.type == "result" then
      emit.done(ev.is_error and (ev.result or ev.subtype) or nil)
    end
  end,
}

M.adapters.pi = {
  persistent = true,
  -- pi cannot limit bash to git commands, so it runs without a shell.
  shell = false,
  cmd = function(ctx)
    local session = ctx.session or ("review-" .. vim.fn.sha256(ctx.root .. ctx.label .. vim.uv.hrtime()):sub(1, 24))
    local cmd = {
      "pi",
      "--mode",
      "rpc",
      "--no-extensions",
      "--no-mcp",
      "--no-skills",
      "--tools",
      "read,grep,find,ls",
      "--append-system-prompt",
      ctx.system,
      "--session-id",
      session,
      "--name",
      "review: " .. ctx.label,
    }
    if ctx.model then
      vim.list_extend(cmd, { "--model", ctx.model })
    end
    return cmd, session
  end,
  encode = function(prompt)
    return vim.json.encode({ type = "prompt", message = prompt })
  end,
  parse = function(line, emit)
    local ev = decode(line)
    if not ev then
      return
    end
    if ev.type == "message_update" then
      local e = ev.assistantMessageEvent
      if e and e.type == "text_delta" then
        emit.text(e.delta)
      end
    elseif ev.type == "tool_execution_start" then
      emit.tool(ev.toolName, ev.args)
    elseif ev.type == "message_end" and ev.message and ev.message.stopReason == "error" then
      emit.text(("\n_%s_\n"):format(ev.message.errorMessage or "error"))
    elseif ev.type == "response" and ev.success == false then
      emit.done(ev.error)
    elseif ev.type == "agent_settled" then
      emit.done()
    end
  end,
}

local ACTIONS = {
  explain = {
    title = "Explain",
    prompt = "Explain this change: what it does, why the author probably made it, and how it fits the rest of the diff.",
  },
  explore = {
    title = "Explore",
    prompt = "Explore the code around this change. Find who calls or uses the symbols it touches, what they depend on, "
      .. "and other places that may need the same change. Cite every location as path:line.",
  },
  deep = {
    title = "Deep dive",
    prompt = "Go deep on this change. Look for correctness bugs, edge cases, lifecycle and concurrency problems, "
      .. "error handling gaps and missing tests. Read the surrounding code to check each claim, and mark anything "
      .. "you could not verify.",
  },
}

local TOUR = "Give a short overview of what this change does, in 3 to 6 sentences. Then list the order in which to "
  .. "read the files so the change makes sense, one line per file saying why. End with a fenced code block tagged "
  .. "review-order that lists the paths in that order, one per line."

-- A single-agent take on a full PR review: passes over the change, then a confidence filter.
local function review_prompt(shell)
  local passes = {
    "Read the diff, then the code each change relies on (base classes, framework types, callers) instead of "
      .. "trusting names.",
    "For each input that worked before the change, work out what happens now, on success and on failure.",
    "Check lifecycle (everything the change creates or subscribes to is torn down on every path, the success "
      .. "path included), threading (which thread runs each closure, and whether it touches UI) and data flow "
      .. "(who sets the values the new code reads, and from which entry points).",
    "Check coverage: which new branch has no test, and which new test cannot fail.",
    "Read the CLAUDE.md files at the repository root and in the directories the change touches, and the "
      .. "comments in the modified code, and check that the change follows them.",
  }
  if shell then
    passes[#passes + 1] = "Read git log and git blame for the modified lines, and check that the change does "
      .. "not undo an earlier fix."
  end
  local lines = { "Review this change the way a careful reviewer would before approving it, in these passes:" }
  for i, pass in ipairs(passes) do
    lines[#lines + 1] = ("%d. %s"):format(i, pass)
  end
  vim.list_extend(lines, {
    "",
    "Report only correctness and behaviour problems: bugs, regressions, missing teardown, guidance from a "
      .. "CLAUDE.md or a code comment that the change breaks, and untested branches that hide one of those. Leave "
      .. "out style, naming, readability, wording and suggestions to consider, problems on lines the change did not "
      .. "touch or that existed before it, anything a compiler, linter or CI would catch, and changes that are "
      .. "clearly intentional. When in doubt, leave it out.",
    "Check each candidate against the code, rate your confidence that it is real from 0 to 100, and drop "
      .. "anything under 80. A concern that matters but that you could not confirm in the code is a question, "
      .. "not a bug.",
    "Severity: high when users or data are affected on a common path, medium for a real problem on a rare path, "
      .. "low for a real problem with small impact, question for an unconfirmed concern.",
    "Order the findings from most to least severe. Start each one on its own line as "
      .. "`[severity] path:line: title`, on a line the change added or modified, numbered in the new version of "
      .. "the file (the old version for a deleted file). Below it, in two to four sentences, give the problem, a "
      .. "concrete input or sequence that shows it, and the fix. If nothing is worth raising, say so in one line.",
  })
  return table.concat(lines, "\n")
end

local REF = "([%w%._%-/]+%.%w+):(%d+)"
local FINDING = "^[%s%-%*]*%[(%a+)%]%s+`?" .. REF .. "`?:?%s*(.*)$"
local HEADER = 3
local STATUS_HL = { A = "Added", M = "Changed", R = "Changed", C = "Changed", T = "Changed", D = "Removed" }
local SEVERITY_HL =
  { high = "DiagnosticError", medium = "DiagnosticWarn", low = "DiagnosticInfo", question = "DiagnosticHint" }
local STORE = vim.fn.stdpath("state") .. "/agentic_review.json"
local ns = vim.api.nvim_create_namespace("agentic_review")
local cns = vim.api.nvim_create_namespace("agentic_review_comments")
local pns = vim.api.nvim_create_namespace("agentic_review_pane")
local BADGES = {
  high = { "AgenticReviewHigh", "DiagnosticError" },
  medium = { "AgenticReviewMedium", "DiagnosticWarn" },
  low = { "AgenticReviewLow", "DiagnosticInfo" },
  question = { "AgenticReviewQuestion", "DiagnosticHint" },
}

-- Severity tags are badges in the theme's diagnostic colours; the other groups are plain links.
local function define_highlights()
  local function fg(name)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    return ok and hl.fg or nil
  end
  local ink = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg or 0
  for _, badge in pairs(BADGES) do
    local color = fg(badge[2])
    vim.api.nvim_set_hl(
      0,
      badge[1],
      color and { fg = ink, bg = color, bold = true, default = true } or { link = badge[2], default = true }
    )
  end
  local links = {
    AgenticReviewTool = "Function",
    AgenticReviewCommand = "String",
    AgenticReviewRef = "Underlined",
    AgenticReviewTitle = "Title",
    AgenticReviewMeta = "Comment",
    AgenticReviewError = "DiagnosticError",
  }
  for name, target in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

-- Colours rows first to last-1 of a pane: tool calls, findings, path:line references and timing lines.
local function paint(buf, first, last)
  vim.api.nvim_buf_clear_namespace(buf, pns, first, last)
  local function hl(row, s, e, group)
    vim.api.nvim_buf_set_extmark(buf, pns, row, s, { end_col = e, hl_group = group, priority = 5000 })
  end
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, first, last, false)) do
    local row = first + i - 1
    local tool, detail = line:match("^> ([%w_]+) (`.*`)$")
    tool = tool or line:match("^> ([%w_]+)$")
    if tool then
      hl(row, 2, 2 + #tool, "AgenticReviewTool")
      if detail then
        hl(row, 3 + #tool, #line, "AgenticReviewCommand")
      end
    elseif line:match("^_%d+s_$") or line == "_cancelled_" then
      hl(row, 0, #line, "AgenticReviewMeta")
    elseif line:match("^_error: .*_$") then
      hl(row, 0, #line, "AgenticReviewError")
    else
      local severity = line:match(FINDING)
      local badge = severity and BADGES[severity:lower()]
      if badge then
        local s, e = line:find("%[%a+%]")
        hl(row, s - 1, e, badge[1])
        local title = line:find("[^`:%s]", select(2, line:find(REF, e)) + 1)
        if title then
          hl(row, title - 1, #line, "AgenticReviewTitle")
        end
      end
      for s, _, _, e in line:gmatch("()" .. REF .. "()") do
        hl(row, s - 1, e - 1, "AgenticReviewRef")
      end
    end
  end
end

local GH_PENDING = [[
query($owner: String!, $repo: String!, $number: Int!) {
  viewer { login }
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      id
      reviews(states: PENDING, first: 20) { nodes { id url author { login } } }
    }
  }
}]]

local GH_START = [[
mutation($pr: ID!, $commit: GitObjectID!) {
  addPullRequestReview(input: {pullRequestId: $pr, commitOID: $commit}) { pullRequestReview { id url } }
}]]

local GH_THREAD = [[
mutation($review: ID!, $path: String!, $line: Int!, $side: DiffSide!, $startLine: Int, $startSide: DiffSide,
  $body: String!) {
  addPullRequestReviewThread(input: {pullRequestReviewId: $review, path: $path, line: $line, side: $side,
    startLine: $startLine, startSide: $startSide, body: $body}) { thread { id } }
}]]

local GH_SUBMIT = [[
mutation($review: ID!, $event: PullRequestReviewEvent!, $body: String) {
  submitPullRequestReview(input: {pullRequestReviewId: $review, event: $event, body: $body}) {
    pullRequestReview { url }
  }
}]]

-- A conversation owns one agent process and the buffer its answers stream into. The review has one, and
-- each repository gets a quick one for questions asked outside the review tab.
local function conversation(fields)
  return vim.tbl_extend("force", { queue = {}, stderr = "", reply = "", last_reply = "" }, fields)
end

local state, agent
local quick = {}

local function reset()
  state = { wins = {}, bufs = {}, files = {}, viewed = {}, comments = {}, findings = {} }
  agent = conversation({ kind = "review" })
end
reset()

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Review" })
end

local function adapter_name()
  local a = M.config.agent
  return type(a) == "table" and (a.name or "custom") or a
end

local function adapter()
  local a = M.config.agent
  if type(a) == "string" then
    a = M.config.adapters[a] or M.adapters[a]
  end
  return a
end

local function win_ok(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function split_lines(text)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

local function git(args, cwd)
  local res = vim.system({ "git", unpack(args) }, { cwd = cwd or state.root, text = true }):wait()
  if res.code == 0 then
    return res.stdout
  end
end

local function run(cmd, cwd)
  local co = coroutine.running()
  vim.system(cmd, { cwd = cwd, text = true }, function(res)
    vim.schedule(function()
      coroutine.resume(co, res)
    end)
  end)
  local res = coroutine.yield()
  if res.code ~= 0 then
    error(vim.trim(res.stderr ~= "" and res.stderr or res.stdout), 0)
  end
  return vim.trim(res.stdout)
end

local function async(fn)
  coroutine.wrap(function()
    local ok, err = pcall(fn)
    if not ok then
      notify(tostring(err), vim.log.levels.ERROR)
    end
  end)()
end

local function relative(path, root)
  root = root or state.root
  local prefix = root and root .. "/"
  if prefix and path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end
  return path
end

local function diff_range()
  return state.head and { state.base, state.head } or { state.base }
end

local function fence(lang, lines, max)
  max = max or M.config.max_context_lines
  if #lines > max then
    local cut = #lines - max
    lines = vim.list_slice(lines, 1, max)
    lines[#lines + 1] = ("[%d more lines cut]"):format(cut)
  end
  return ("```%s\n%s\n```"):format(lang, table.concat(lines, "\n"))
end

local function file_summary(f)
  local stats = f.binary and "binary" or ("+%d -%d"):format(f.added or 0, f.removed or 0)
  return ("%s %s%s (%s)"):format(f.status, f.old_path and (f.old_path .. " -> ") or "", f.path, stats)
end

local function index_of(f)
  for i, x in ipairs(state.files) do
    if x == f then
      return i
    end
  end
end

local function find_file(path)
  for _, f in ipairs(state.files) do
    if f.path == path then
      return f
    end
  end
end

local function next_unviewed(from)
  local n, i = #state.files, from and index_of(from) or 0
  for k = 1, n do
    local f = state.files[(i + k - 1) % n + 1]
    if not state.viewed[f.path] then
      return f
    end
  end
end

-- Paths missing from `paths` keep their relative order after the listed ones.
local function order(files, paths)
  if type(paths) ~= "table" then
    return files
  end
  local rank, idx = {}, {}
  for i, p in ipairs(paths) do
    p = vim.trim(p)
    rank[p] = rank[p] or i
  end
  for i, f in ipairs(files) do
    idx[f] = #paths + i
  end
  local sorted = vim.list_slice(files)
  table.sort(sorted, function(a, b)
    return (rank[a.path] or idx[a]) < (rank[b.path] or idx[b])
  end)
  return sorted
end

local function read_store()
  local file = io.open(STORE, "r")
  if not file then
    return {}
  end
  local data = decode(file:read("*a"))
  file:close()
  return data or {}
end

local function write_store(store)
  vim.fn.mkdir(vim.fs.dirname(STORE), "p")
  local file = io.open(STORE, "w")
  if file then
    file:write(vim.json.encode(store))
    file:close()
  end
end

local function persist()
  if not state.key then
    return
  end
  local store = read_store()
  store[state.key] = {
    agent = adapter_name(),
    session = agent.session,
    order = vim.tbl_map(function(f)
      return f.path
    end, state.files),
    viewed = state.viewed,
    findings = state.findings,
  }
  write_store(store)
end

local function transcript_path()
  return vim.fn.stdpath("state") .. "/agentic_review/" .. vim.fn.sha256(state.key):sub(1, 16) .. ".md"
end

local function save_transcript()
  local buf = state.bufs.agent
  if not (state.key and buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local path = transcript_path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, 0, -1, false), path)
end

local fit_float, float_status

local function displays(win, buf)
  return win_ok(win) and vim.api.nvim_win_get_buf(win) == buf
end

local function pane_append(c, text)
  local buf = c.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local n = vim.api.nvim_buf_line_count(buf)
  local lines = vim.split(text, "\n", { plain = true })
  lines[1] = vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1] .. lines[1]
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, n - 1, n, false, lines)
  vim.bo[buf].modifiable = false
  paint(buf, n - 1, -1)
  local win = c.win
  if displays(win, buf) and (win ~= vim.api.nvim_get_current_win() or vim.api.nvim_win_get_cursor(win)[1] >= n) then
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  end
  if c.kind == "quick" then
    fit_float(c)
  end
end

-- Each kind of output starts after a blank line, so Markdown never folds text into a preceding quote or heading.
local function pane_write(c, kind, text)
  local buf = c.buf
  if c.last and kind ~= c.last and buf and vim.api.nvim_buf_is_valid(buf) then
    local n = vim.api.nvim_buf_line_count(buf)
    local tail = vim.api.nvim_buf_get_lines(buf, math.max(0, n - 2), n, false)
    if tail[#tail] ~= "" then
      pane_append(c, "\n\n")
    elseif #tail == 2 and tail[1] ~= "" then
      pane_append(c, "\n")
    end
  end
  if kind == "header" and buf and vim.api.nvim_buf_is_valid(buf) then
    c.turn_start = vim.api.nvim_buf_line_count(buf)
  end
  pane_append(c, text)
  c.last = kind
end

local function tool_line(name, input, root)
  input = type(input) == "table" and input or {}
  local detail = tostring(input.command or input.file_path or input.pattern or input.path or "")
  detail = relative(detail, root):gsub("\n", " ")
  if #detail > 80 then
    detail = detail:sub(1, 77) .. "..."
  end
  return detail == "" and ("> %s\n"):format(name) or ("> %s `%s`\n"):format(name, detail)
end

local function status(c)
  local text = c.busy and "working" or "idle"
  if #c.queue > 0 then
    text = ("%s, %d queued"):format(text, #c.queue)
  end
  text = ("%s · %s"):format(c.model and (adapter_name() .. " · " .. c.model) or adapter_name(), text)
  if c.kind == "quick" then
    return float_status(c, text)
  end
  if win_ok(state.wins.agent) then
    vim.wo[state.wins.agent].winbar = " " .. text
  end
end

local function rules(a, where)
  local lines = {}
  if a.shell then
    lines[1] = "Your shell runs only single git inspection commands (diff, show, log, blame, grep), "
      .. "without pipes or &&. Use the file tools for everything else."
  end
  return vim.list_extend(lines, {
    "You are read-only: never try to edit files or run anything other than git inspection commands.",
    where,
    "Cite code as path:line relative to the repository root, so the reader can jump to it.",
    "Say when something is unverified and how to check it.",
  })
end

local function system_prompt(a)
  local lines = {
    "You are guiding a developer through a code review inside Neovim.",
    ("The change under review is %s. Base commit: %s. Head: %s."):format(
      state.label,
      state.base,
      state.head and ("commit " .. state.head) or "the working tree"
    ),
  }
  if not a.shell then
    lines[#lines + 1] = "You have no shell, so you cannot run git. Each message includes the diff it is about; "
      .. "read files in the working tree for surrounding code."
    if state.head then
      lines[#lines + 1] = "The working tree is not the head revision, so files you read may differ from the change."
    end
  elseif state.head then
    lines[#lines + 1] = (
      "The working tree is not the head revision. Read head files with `git show %s:<path>` "
      .. "and changes with `git diff %s %s -- <path>`."
    ):format(state.head, state.base, state.head)
  else
    lines[#lines + 1] = ("Read files from the working tree. See changes with `git diff %s -- <path>`."):format(
      state.base
    )
  end
  vim.list_extend(
    lines,
    rules(
      a,
      "Your answers appear in a narrow Markdown side panel that adds its own heading per answer. Do not write "
        .. "headings, keep answers short, and avoid tables and long code blocks."
    )
  )
  return table.concat(lines, "\n")
end

local function quick_prompt(c, a)
  local lines = {
    "You are helping a developer understand code inside Neovim.",
    ("The repository root is %s. Each message quotes the code it is about."):format(c.root),
  }
  if not a.shell then
    lines[#lines + 1] = "You have no shell, so you cannot run git. Read files with the file tools."
  end
  vim.list_extend(
    lines,
    rules(
      a,
      "Your answers appear in a small floating window under the code, about 15 lines tall. Answer in a few "
        .. "short paragraphs or a short list, with no headings, tables or long code blocks."
    )
  )
  return table.concat(lines, "\n")
end

local function remember_session(c)
  if c.kind == "review" then
    persist()
  end
end

local finish, pump

local function emitter(c)
  local emit = {}
  function emit.session(id)
    if id and id ~= c.session then
      c.session = id
      remember_session(c)
    end
  end
  function emit.text(text)
    if text and text ~= "" then
      c.reply = c.reply .. text
      pane_write(c, "text", text)
    end
  end
  function emit.tool(name, input)
    pane_write(c, "tool", tool_line(name, input, c.root))
  end
  function emit.done(err)
    if c.busy then
      finish(c, err)
    end
  end
  return emit
end

local function spawn(c, a, prompt)
  c.stderr = ""
  local argv, session = a.cmd({
    system = c.kind == "review" and system_prompt(a) or quick_prompt(c, a),
    label = c.label,
    root = c.root,
    model = c.model,
    session = c.session,
    prompt = prompt,
  })
  if session and session ~= c.session then
    c.session = session
    remember_session(c)
  end
  local emit = emitter(c)
  local partial = ""
  local job
  job = vim.system(argv, {
    cwd = c.root,
    stdin = a.persistent or false,
    stdout = function(_, data)
      if not data then
        return
      end
      vim.schedule(function()
        if job ~= c.job then
          return
        end
        if not a.parse then
          return emit.text(data)
        end
        partial = partial .. data
        while true do
          local nl = partial:find("\n", 1, true)
          if not nl then
            break
          end
          local line = partial:sub(1, nl - 1)
          partial = partial:sub(nl + 1)
          if line ~= "" then
            a.parse(line, emit)
          end
        end
      end)
    end,
    stderr = function(_, data)
      if data then
        vim.schedule(function()
          c.stderr = c.stderr .. data
        end)
      end
    end,
  }, function(res)
    vim.schedule(function()
      if job ~= c.job then
        return
      end
      c.job = nil
      if c.busy then
        local stderr = vim.trim(c.stderr)
        finish(c, res.code ~= 0 and (stderr ~= "" and stderr or ("exited with code " .. res.code)) or nil)
      end
    end)
  end)
  c.job = job
end

finish = function(c, err)
  c.busy = false
  if err then
    pane_write(c, "meta", ("_error: %s_\n"):format(tostring(err):gsub("\n", " ")))
  end
  pane_write(c, "meta", ("_%ds_\n"):format(math.floor((vim.uv.now() - c.started) / 1000 + 0.5)))
  c.last_reply = c.reply
  local cb = c.on_done
  c.on_done = nil
  if cb and not err then
    cb(c.reply)
  end
  if c.kind == "review" then
    save_transcript()
  end
  pump(c)
end

pump = function(c)
  if c.busy or #c.queue == 0 then
    return status(c)
  end
  local item = table.remove(c.queue, 1)
  local a = adapter()
  if c.adapter and c.adapter ~= a then
    if c.job then
      pcall(c.job.kill, c.job, 15)
      c.job = nil
    end
    c.session = nil
  end
  c.adapter = a
  local model = M.config.models[item.action] or M.config.model or (a.models or {})[item.action]
  local switch = a.persistent and c.job and model ~= c.model
  c.busy, c.reply, c.on_done, c.started = true, "", item.on_done, vim.uv.now()
  c.action, c.model = item.action, model
  pane_write(c, "header", item.header)
  status(c)
  local ok, err = pcall(function()
    if switch and model and a.set_model then
      c.job:write(a.set_model(model) .. "\n")
    elseif switch then
      -- The new process resumes the same session, so only the model changes.
      pcall(c.job.kill, c.job, 15)
      c.job = nil
    end
    if a.persistent then
      if not c.job then
        spawn(c, a)
      end
      c.job:write(a.encode(item.prompt) .. "\n")
    else
      spawn(c, a, item.prompt)
    end
  end)
  if not ok then
    finish(c, err)
  end
end

local function send(c, action, header, prompt, on_done)
  table.insert(c.queue, { action = action, header = header, prompt = prompt, on_done = on_done })
  pump(c)
end

local function ask(action, header, prompt, on_done)
  send(agent, action, header, prompt, on_done)
end

local function stop(c)
  local job = c.job
  c.job, c.busy, c.queue, c.on_done = nil, false, {}, nil
  if job then
    pcall(job.kill, job, 15)
  end
end

local function buf_text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

local function hunks()
  local base = vim.api.nvim_win_get_buf(state.wins.base)
  local head = vim.api.nvim_win_get_buf(state.wins.head)
  local diff = (vim.text and vim.text.diff or vim.diff)(
    buf_text(base),
    buf_text(head),
    { ctxlen = 3, algorithm = "histogram" }
  )
  local list, cur = {}, nil
  for _, line in ipairs(vim.split(diff or "", "\n", { plain = true })) do
    local os, oc, hs, hc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if os then
      cur = {
        old_start = tonumber(os),
        old_count = tonumber(oc) or 1,
        new_start = tonumber(hs),
        new_count = tonumber(hc) or 1,
        lines = { line },
      }
      list[#list + 1] = cur
    elseif cur and line ~= "" then
      cur.lines[#cur.lines + 1] = line
    end
  end
  return list
end

local function hunk_at(side, lnum)
  local best, dist
  for _, h in ipairs(hunks()) do
    local s = side == "base" and h.old_start or h.new_start
    local e = s + (side == "base" and h.old_count or h.new_count) - 1
    local d = lnum < s and s - lnum or lnum > e and lnum - e or 0
    if not dist or d < dist then
      best, dist = h, d
    end
  end
  return best
end

local function scratch(win, name, lines, path)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_win_set_buf(win, buf)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  -- Highlight without setting 'filetype', so LSP clients and linters never attach to a revision buffer.
  local ft = vim.filetype.match({ filename = path, buf = buf })
  local lang = ft and vim.treesitter.language.get_lang(ft)
  if not (lang and pcall(vim.treesitter.start, buf, lang)) and ft then
    vim.bo[buf].syntax = ft
  end
end

local function revision(rev, path)
  local out = git({ "show", rev .. ":" .. path })
  return out and split_lines(out) or {}
end

local function render_files()
  local buf = state.bufs.files
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local viewed = 0
  for _, f in ipairs(state.files) do
    if state.viewed[f.path] then
      viewed = viewed + 1
    end
  end
  local progress = ("%d/%d viewed"):format(viewed, #state.files)
  if #state.comments > 0 then
    progress = ("%s · %d pending comment%s"):format(progress, #state.comments, #state.comments == 1 and "" or "s")
  end
  local lines = { state.label, progress, "" }
  local marks = {
    { 0, 0, #lines[1], "Title" },
    { 1, 0, #lines[2], viewed == #state.files and "Added" or "Comment" },
  }
  for i, f in ipairs(state.files) do
    local name, dir = vim.fs.basename(f.path), vim.fs.dirname(f.path)
    local stats = f.binary and "bin" or ("+%d -%d"):format(f.added or 0, f.removed or 0)
    local prefix = (f == state.current and "▸" or " ") .. (state.viewed[f.path] and "✓" or " ") .. " "
    local line = ("%s%s %s %s%s"):format(prefix, f.status, name, stats, dir ~= "." and ("  " .. dir) or "")
    local row, col = HEADER + i - 1, #prefix
    lines[#lines + 1] = line
    marks[#marks + 1] = { row, col, col + 1, STATUS_HL[f.status] or "Normal" }
    marks[#marks + 1] = { row, col + 2 + #name + 1, #line, "Comment" }
    if f == state.current then
      marks[#marks + 1] = { row, col + 2, col + 2 + #name, "Special" }
    end
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
end

local function file_under_cursor()
  if vim.api.nvim_get_current_win() ~= state.wins.files then
    return
  end
  return state.files[vim.api.nvim_win_get_cursor(0)[1] - HEADER]
end

local function diffoff()
  for _, win in ipairs({ state.wins.base, state.wins.head }) do
    if win_ok(win) then
      vim.api.nvim_win_call(win, function()
        vim.cmd("diffoff")
      end)
    end
  end
end

local function clear_marks()
  for _, win in ipairs({ state.wins.base, state.wins.head }) do
    if win_ok(win) then
      vim.api.nvim_buf_clear_namespace(vim.api.nvim_win_get_buf(win), cns, 0, -1)
    end
  end
end

local function finding_at(f, side, lnum)
  for _, x in ipairs(state.findings) do
    if x.path == f.path and x.line == lnum and (side == "LEFT") == (f.status == "D") then
      return x
    end
  end
end

local function mark_lines()
  clear_marks()
  local f = state.current
  for side, win in pairs({ LEFT = state.wins.base, RIGHT = state.wins.head }) do
    for _, c in ipairs(state.comments) do
      if f and win_ok(win) and c.path == f.path and c.side == side then
        local text = "  " .. c.body:match("^[^\n]*"):sub(1, 60)
        pcall(vim.api.nvim_buf_set_extmark, vim.api.nvim_win_get_buf(win), cns, c.line - 1, 0, {
          virt_text = { { text, "DiagnosticHint" } },
          virt_text_pos = "eol",
        })
      end
    end
  end
  local win = f and f.status == "D" and state.wins.base or state.wins.head
  for _, x in ipairs(state.findings) do
    if f and win_ok(win) and x.path == f.path then
      local text = ("  [%s] %s"):format(x.severity, (x.title:gsub("`", "")):sub(1, 80))
      pcall(vim.api.nvim_buf_set_extmark, vim.api.nvim_win_get_buf(win), cns, x.line - 1, 0, {
        virt_text = { { text, SEVERITY_HL[x.severity] or "DiagnosticHint" } },
        virt_text_pos = "eol",
      })
    end
  end
end

-- An added or deleted file has nothing on one side, so the other side takes all the room.
local function split_diff()
  local wins, f = state.wins, state.current
  if not (win_ok(wins.base) and win_ok(wins.head)) then
    return
  end
  local total = vim.api.nvim_win_get_width(wins.base) + vim.api.nvim_win_get_width(wins.head)
  local base = math.floor(total / 2)
  if f and f.status == "A" then
    base = 1
  elseif f and f.status == "D" then
    base = total - 1
  end
  vim.api.nvim_win_set_width(wins.base, base)
end

local function show(f)
  local wins = state.wins
  if not (f and win_ok(wins.base) and win_ok(wins.head)) then
    return
  end
  state.current = f
  clear_marks()
  diffoff()
  local old = f.old_path or f.path
  if f.binary then
    scratch(wins.base, "review://base/" .. old, { "(binary file)" }, old)
    scratch(wins.head, "review://head/" .. f.path, { "(binary file)" }, f.path)
  else
    scratch(
      wins.base,
      ("review://%s/%s"):format(state.base:sub(1, 8), old),
      f.status == "A" and {} or revision(state.base, old),
      old
    )
    if state.head then
      local lines = f.status == "D" and {} or revision(state.head, f.path)
      scratch(wins.head, ("review://%s/%s"):format(state.head:sub(1, 8), f.path), lines, f.path)
    elseif f.status == "D" then
      scratch(wins.head, "review://deleted/" .. f.path, {}, f.path)
    else
      vim.api.nvim_win_call(wins.head, function()
        vim.cmd("edit " .. vim.fn.fnameescape(state.root .. "/" .. f.path))
      end)
    end
    for _, win in ipairs({ wins.base, wins.head }) do
      vim.api.nvim_win_call(win, function()
        vim.cmd("diffthis")
      end)
    end
    local first = hunks()[1]
    if first then
      pcall(vim.api.nvim_win_set_cursor, wins.head, { math.max(first.new_start, 1), 0 })
    end
  end
  split_diff()
  render_files()
  mark_lines()
  if win_ok(wins.files) then
    pcall(vim.api.nvim_win_set_cursor, wins.files, { HEADER + index_of(f), 0 })
  end
  vim.api.nvim_set_current_win(f.status == "D" and wins.base or wins.head)
end

local SEVERITY_RANK = { high = 4, medium = 3, low = 2, question = 1 }

-- The changed files as a tree grouped by directory, filtered live by a search line drawn over its first row.
local function pick_file()
  if not (state.tab and #state.files > 0) then
    return
  end
  local back = vim.api.nvim_get_current_win()
  local query, selected, rows, closed = "", state.current, {}, false
  local width = math.min(100, vim.o.columns - 8)
  local dirs = {}
  for _, f in ipairs(state.files) do
    dirs[vim.fs.dirname(f.path)] = true
  end
  local height = math.max(3, math.min(vim.o.lines - 8, 2 + #state.files + vim.tbl_count(dirs)))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = "rounded",
    style = "minimal",
    title = " Go to file ",
    title_pos = "left",
    footer = " j/k move · / search · <CR> open · v viewed · q close ",
    footer_pos = "left",
  })
  vim.wo[win].wrap = false
  local prompt

  local close
  -- Leaving for any window but the list or its search line closes the picker.
  local function leave(target)
    vim.api.nvim_create_autocmd("WinLeave", {
      buffer = target,
      callback = function()
        vim.schedule(function()
          local cur = vim.api.nvim_get_current_win()
          if cur ~= win and cur ~= prompt then
            close()
          end
        end)
      end,
    })
  end

  local function findings_of(f)
    local count, worst = 0, nil
    for _, x in ipairs(state.findings) do
      if x.path == f.path then
        count = count + 1
        if not worst or (SEVERITY_RANK[x.severity] or 0) > (SEVERITY_RANK[worst] or 0) then
          worst = x.severity
        end
      end
    end
    return count, worst
  end

  local function render()
    local matches = state.files
    if query ~= "" then
      local hits = {}
      for _, path in
        ipairs(vim.fn.matchfuzzy(
          vim.tbl_map(function(f)
            return f.path
          end, state.files),
          query
        ))
      do
        hits[path] = true
      end
      matches = vim.tbl_filter(function(f)
        return hits[f.path]
      end, state.files)
    end
    local groups, order = {}, {}
    for _, f in ipairs(matches) do
      local dir = vim.fs.dirname(f.path)
      if not groups[dir] then
        groups[dir] = {}
        order[#order + 1] = dir
      end
      table.insert(groups[dir], f)
    end
    local lines, marks = { "", ("─"):rep(width) }, {}
    rows = {}
    local function mark(row, s, e, group)
      marks[#marks + 1] = { row, s, e, group }
    end
    for _, dir in ipairs(order) do
      local label = dir == "." and "./" or dir .. "/"
      if vim.fn.strdisplaywidth(label) > width - 1 then
        label = "…" .. label:sub(-(width - 2))
      end
      lines[#lines + 1] = label
      mark(#lines - 1, 0, #label, "Directory")
      for i, f in ipairs(groups[dir]) do
        local branch = i == #groups[dir] and "└─ " or "├─ "
        local dot = f == state.current and "● " or (state.viewed[f.path] and "✓ " or "· ")
        local name = vim.fs.basename(f.path)
        local line = branch .. dot .. f.status .. " " .. name
        lines[#lines + 1] = line
        rows[#lines] = f
        local row = #lines - 1
        mark(row, 0, #branch + #dot, "NonText")
        mark(row, #branch + #dot, #branch + #dot + 1, STATUS_HL[f.status] or "Normal")
        if f == state.current then
          mark(row, #line - #name, #line, "Special")
        end
      end
    end
    if not vim.tbl_contains(matches, selected) then
      selected = matches[1]
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, pns, 0, -1)
    for _, m in ipairs(marks) do
      vim.api.nvim_buf_set_extmark(buf, pns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
    end
    local count = query == "" and ("%d files"):format(#state.files) or ("%d of %d"):format(#matches, #state.files)
    vim.api.nvim_buf_set_extmark(buf, pns, 0, 0, {
      virt_text = { { query == "" and "/ search files" or ("/ " .. query), query == "" and "Comment" or "Normal" } },
      virt_text_pos = "overlay",
    })
    local tally = { virt_text = { { count, "Comment" } }, virt_text_pos = "right_align" }
    vim.api.nvim_buf_set_extmark(buf, pns, 0, 0, tally)
    if win_ok(prompt) then
      vim.api.nvim_buf_set_extmark(
        vim.api.nvim_win_get_buf(prompt),
        pns,
        0,
        0,
        vim.tbl_extend("force", tally, { id = 2 })
      )
    end
    for lnum, f in pairs(rows) do
      local stats = f.binary and "bin" or ("+%d -%d"):format(f.added or 0, f.removed or 0)
      local chunks = {}
      local count_f, worst = findings_of(f)
      if count_f > 0 then
        chunks[#chunks + 1] = { (" %d %s "):format(count_f, worst), BADGES[worst] and BADGES[worst][1] or "Comment" }
        chunks[#chunks + 1] = { "  " }
      end
      chunks[#chunks + 1] = { stats, "Comment" }
      vim.api.nvim_buf_set_extmark(buf, pns, lnum - 1, 0, { virt_text = chunks, virt_text_pos = "right_align" })
      if f == selected then
        vim.api.nvim_buf_set_extmark(buf, pns, lnum - 1, 0, { line_hl_group = "PmenuSel", priority = 10 })
        pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
      end
    end
  end

  close = function()
    if closed then
      return
    end
    closed = true
    if win_ok(prompt) then
      pcall(vim.api.nvim_win_close, prompt, true)
    end
    if win_ok(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    vim.cmd("stopinsert")
  end

  local function move(delta)
    local list = {}
    for lnum in pairs(rows) do
      list[#list + 1] = lnum
    end
    table.sort(list)
    for i, lnum in ipairs(list) do
      if rows[lnum] == selected then
        selected = rows[list[math.max(1, math.min(#list, i + delta))]]
        return render()
      end
    end
  end

  local function open()
    local f = selected
    close()
    if f then
      if win_ok(back) then
        vim.api.nvim_set_current_win(back)
      end
      show(f)
    end
  end

  local function search()
    prompt = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
      relative = "win",
      win = win,
      row = 0,
      col = 0,
      width = width,
      height = 1,
      style = "minimal",
      zindex = 60,
    })
    local pbuf = vim.api.nvim_win_get_buf(prompt)
    vim.bo[pbuf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { query })
    vim.api.nvim_buf_set_extmark(pbuf, pns, 0, 0, {
      id = 1,
      virt_text = { { "/ ", "Special" } },
      virt_text_pos = "inline",
      right_gravity = false,
    })
    leave(pbuf)
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      buffer = pbuf,
      callback = function()
        query = vim.api.nvim_buf_get_lines(pbuf, 0, 1, false)[1] or ""
        render()
      end,
    })
    local function pmap(lhs, fn)
      vim.keymap.set({ "i", "n" }, lhs, fn, { buffer = pbuf, nowait = true })
    end
    pmap("<CR>", open)
    pmap("<Esc>", function()
      vim.cmd("stopinsert")
      pcall(vim.api.nvim_win_close, prompt, true)
      prompt = nil
      vim.api.nvim_set_current_win(win)
    end)
    for _, lhs in ipairs({ "<Down>", "<C-n>", "<C-j>" }) do
      pmap(lhs, function()
        move(1)
      end)
    end
    for _, lhs in ipairs({ "<Up>", "<C-p>", "<C-k>" }) do
      pmap(lhs, function()
        move(-1)
      end)
    end
    render()
    vim.cmd("startinsert!")
  end

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true })
  end
  for _, lhs in ipairs({ "j", "<Down>", "<C-n>" }) do
    map(lhs, function()
      move(1)
    end)
  end
  for _, lhs in ipairs({ "k", "<Up>", "<C-p>" }) do
    map(lhs, function()
      move(-1)
    end)
  end
  map("<CR>", open)
  map("/", search)
  map("v", function()
    if selected then
      state.viewed[selected.path] = not state.viewed[selected.path] or nil
      persist()
      render_files()
      render()
    end
  end)
  map("q", close)
  map("<Esc>", close)
  leave(buf)
  render()
end

local function file_diff(f)
  local args = vim.list_extend({ "diff", "--no-color", "-M" }, diff_range())
  vim.list_extend(args, { "--", f.path, f.old_path })
  return split_lines(git(args) or "")
end

-- Returns a short location for the pane header and the code block the prompt is about.
local function context(range)
  local win, f = vim.api.nvim_get_current_win(), state.current
  if win == state.wins.files then
    f = file_under_cursor() or f
    return f.path, ("The whole change to %s:\n%s"):format(f.path, fence("diff", file_diff(f)))
  end
  if f and (win == state.wins.base or win == state.wins.head) then
    local side = win == state.wins.base and "base" or "head"
    local path = side == "base" and (f.old_path or f.path) or f.path
    if range then
      local lines = vim.api.nvim_buf_get_lines(0, range[1] - 1, range[2], false)
      return ("%s:%d-%d"):format(path, range[1], range[2]),
        ("Lines %d-%d of %s on the %s side:\n%s"):format(range[1], range[2], path, side, fence("", lines))
    end
    local h = hunk_at(side, vim.api.nvim_win_get_cursor(win)[1])
    if h then
      return ("%s:%d"):format(f.path, h.new_start), ("This hunk of %s:\n%s"):format(f.path, fence("diff", h.lines))
    end
  end
  local path = relative(vim.api.nvim_buf_get_name(0))
  local cursor = vim.api.nvim_win_get_cursor(win)[1]
  local l1, l2 = unpack(range or { math.max(1, cursor - 5), cursor + 5 })
  local lines = vim.api.nvim_buf_get_lines(0, l1 - 1, l2, false)
  l2 = l1 + #lines - 1
  return ("%s:%d-%d"):format(path, l1, l2),
    ("Lines %d-%d of %s, which is outside the diff:\n%s"):format(l1, l2, path, fence("", lines))
end

local function selection()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    return { math.min(a, b), math.max(a, b) }
  end
end

-- The path:line under the cursor, or else the first one on the line.
local function ref_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local first, hit
  for s, path, lnum, e in line:gmatch("()" .. REF .. "()") do
    first = first or { path, tonumber(lnum) }
    if col >= s and col < e then
      hit = { path, tonumber(lnum) }
    end
  end
  local target = hit or first
  if target then
    return target[1], target[2]
  end
end

local function jump()
  local path, lnum = ref_under_cursor()
  if not path then
    return
  end
  path = relative(path)
  local f = find_file(path)
  if f then
    if f ~= state.current then
      show(f)
    end
    vim.api.nvim_set_current_win(state.wins.head)
  else
    local abs = state.root .. "/" .. path
    if not vim.uv.fs_stat(abs) then
      return notify("Not found: " .. path, vim.log.levels.WARN)
    end
    clear_marks()
    diffoff()
    vim.api.nvim_set_current_win(state.wins.head)
    vim.cmd("edit " .. vim.fn.fnameescape(abs))
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
  vim.cmd("normal! zz")
end

local function panel(name, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  if ft then
    vim.bo[buf].filetype = ft
  end
  return buf
end

local QUICK_ACTIONS = {
  explain = { title = "Explain", prompt = "Explain what this code does and why it is written this way." },
  explore = {
    title = "Explore",
    prompt = "Explore the code around this. Find who calls or uses it, what it depends on, and related code "
      .. "worth knowing. Cite every location as path:line.",
  },
  deep = {
    title = "Deep dive",
    prompt = "Go deep on this code. Look for correctness bugs, edge cases, lifecycle and concurrency problems, "
      .. "error handling gaps and missing tests. Read the surrounding code to check each claim, and mark anything "
      .. "you could not verify.",
  },
}

local function in_review()
  return state.tab ~= nil and vim.api.nvim_get_current_tabpage() == state.tab
end

local function root_of(buf)
  local file = vim.api.nvim_buf_get_name(buf)
  local dir = file ~= "" and vim.fs.dirname(file) or vim.fn.getcwd()
  if not vim.uv.fs_stat(dir) then
    dir = vim.fn.getcwd()
  end
  local root = git({ "rev-parse", "--show-toplevel" }, dir)
  return root and vim.trim(root) or dir
end

local function cancel(c)
  if not (c and c.busy) then
    return
  end
  stop(c)
  pane_write(c, "meta", "_cancelled_\n")
  if c.kind == "review" then
    save_transcript()
  end
  status(c)
end

local function follow_up(c)
  vim.ui.input({ prompt = "Follow-up: " }, function(q)
    if q and vim.trim(q) ~= "" then
      send(c, c.action, ("## Ask\n_%s_\n"):format(q), q)
    end
  end)
end

local function close_quick(c)
  local win = vim.api.nvim_get_current_win()
  if not displays(win, c.buf) then
    return
  end
  if win == c.float then
    c.float = nil
  end
  if win_ok(c.source) and c.source ~= win then
    vim.api.nvim_set_current_win(c.source)
  end
  pcall(vim.api.nvim_win_close, win, true)
end

local function quick_jump(c)
  local path, lnum = ref_under_cursor()
  if not path then
    return
  end
  local rel = relative(path, c.root)
  local abs = rel:sub(1, 1) == "/" and rel or (c.root .. "/" .. rel)
  if not vim.uv.fs_stat(abs) then
    return notify("Not found: " .. rel, vim.log.levels.WARN)
  end
  if vim.api.nvim_get_current_win() == c.float then
    pcall(vim.api.nvim_win_close, c.float, true)
    c.float = nil
  end
  if win_ok(c.source) then
    vim.api.nvim_set_current_win(c.source)
  else
    vim.cmd("wincmd p")
  end
  vim.cmd("edit " .. vim.fn.fnameescape(abs))
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
  vim.cmd("normal! zz")
end

local function to_split(c)
  if win_ok(c.float) then
    pcall(vim.api.nvim_win_close, c.float, true)
  end
  c.float = nil
  if win_ok(c.source) then
    vim.api.nvim_set_current_win(c.source)
  end
  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, c.buf)
  vim.api.nvim_win_set_width(win, math.floor(vim.o.columns * M.config.agent_width))
  local wo = vim.wo[win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn, wo.spell = false, false, "no", "0", false
  wo.wrap, wo.linebreak, wo.winfixwidth, wo.winfixbuf = true, true, true, true
  c.win = win
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(c.buf), 0 })
  status(c)
end

local function quick_for(root)
  local c = quick[root]
  if c and vim.api.nvim_buf_is_valid(c.buf) then
    return c
  end
  if c then
    stop(c)
  end
  c = conversation({ kind = "quick", root = root, label = "ask " .. vim.fs.basename(root) })
  c.buf = panel("review://ask" .. root, "markdown")
  vim.bo[c.buf].bufhidden = "hide"
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, function()
      fn(c)
    end, { buffer = c.buf, nowait = true, desc = desc })
  end
  map("q", close_quick, "Close")
  map("<Esc>", close_quick, "Close")
  map("<CR>", quick_jump, "Jump to path:line")
  map("gf", quick_jump, "Jump to path:line")
  map("a", follow_up, "Ask a follow-up")
  map("s", to_split, "Move to a side split")
  map("<C-c>", cancel, "Cancel the answer")
  quick[root] = c
  return c
end

-- A question asked from the code starts over, so neither the float nor the agent carries earlier questions.
local function new_thread(c)
  stop(c)
  c.session, c.last, c.turn_start = nil, nil, nil
  vim.bo[c.buf].modifiable = true
  vim.api.nvim_buf_set_lines(c.buf, 0, -1, false, {})
  vim.bo[c.buf].modifiable = false
end

-- The conversation for the current buffer: the quick buffer itself, or the repository the file belongs to.
local function quick_here()
  local buf = vim.api.nvim_get_current_buf()
  for _, c in pairs(quick) do
    if c.buf == buf then
      return c
    end
  end
  return quick[root_of(buf)]
end

local function open_float(c, source, l1, l2, title)
  if win_ok(c.float) then
    pcall(vim.api.nvim_win_close, c.float, true)
  end
  local info = vim.fn.getwininfo(source)[1]
  local first, last = vim.fn.screenpos(source, l1, 1).row, vim.fn.screenpos(source, l2, 1).row
  if first == 0 or last == 0 then
    local cursor = vim.api.nvim_win_get_cursor(source)[1]
    l1, l2 = cursor, cursor
    first = vim.fn.screenpos(source, cursor, 1).row
    last = first
  end
  local below = info.winrow + info.height - 1 - last
  local above = first - info.winrow
  local up = below < M.config.float_height + 2 and above > below
  c.max_height = math.max(3, math.min(M.config.float_height, (up and above or below) - 2))
  c.source = source
  c.float = vim.api.nvim_open_win(c.buf, true, {
    relative = "win",
    win = source,
    bufpos = { (up and l1 or l2) - 1, 0 },
    anchor = up and "SW" or "NW",
    row = up and 0 or 1,
    col = 0,
    width = math.max(20, math.min(M.config.float_width, info.width - info.textoff - 2)),
    -- Neovim restores the window options this buffer last had, and a winbar from the side split needs a second row.
    height = 2,
    border = "rounded",
    style = "minimal",
    title = " " .. title .. " ",
    title_pos = "left",
  })
  c.win = c.float
  vim.wo[c.float].winbar = ""
  vim.wo[c.float].wrap = true
  vim.wo[c.float].linebreak = true
  vim.wo[c.float].winfixbuf = true
  vim.api.nvim_win_set_cursor(c.float, { vim.api.nvim_buf_line_count(c.buf), 0 })
  fit_float(c)
  status(c)
end

-- The float grows with the answer up to its cap and shows the current question from its heading.
fit_float = function(c)
  local win = c.float
  if not displays(win, c.buf) then
    return
  end
  local n = vim.api.nvim_buf_line_count(c.buf)
  local start = math.min(c.turn_start or 1, n)
  local needed = vim.api.nvim_win_text_height(win, { start_row = start - 1, end_row = n - 1 }).all
  local height = math.max(1, math.min(c.max_height or M.config.float_height, needed))
  vim.api.nvim_win_set_config(win, { height = height })
  if needed <= height and vim.api.nvim_win_get_cursor(win)[1] == n then
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = start })
    end)
  end
end

float_status = function(c, text)
  local win = c.win
  if not displays(win, c.buf) then
    return
  end
  if win == c.float then
    vim.api.nvim_win_set_config(win, {
      footer = (" %s · a ask · s split · q close "):format(text),
      footer_pos = "right",
    })
  else
    vim.wo[win].winbar = (" %s · a ask · q close"):format(text)
  end
end

local function quick_action(name, question, range)
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  for _, c in pairs(quick) do
    if c.buf == buf then
      return follow_up(c)
    end
  end
  local root = root_of(buf)
  local cursor = vim.api.nvim_win_get_cursor(win)[1]
  local l1, l2 = unpack(range or { math.max(1, cursor - 5), cursor + 5 })
  local lines = vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false)
  l2 = l1 + #lines - 1
  local file = vim.api.nvim_buf_get_name(buf)
  local path = file ~= "" and relative(file, root) or "an unsaved buffer"
  local where = ("%s:%d-%d"):format(path, l1, l2)
  local ctx = ("Lines %d-%d of %s:\n%s"):format(l1, l2, path, fence(vim.bo[buf].filetype, lines))
  local a1, a2 = unpack(range or { cursor, cursor })
  local function go(title, instruction, sub)
    local c = quick_for(root)
    new_thread(c)
    local split
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= c.float and vim.api.nvim_win_get_buf(w) == c.buf then
        split = w
      end
    end
    if split then
      c.win, c.source = split, win
    else
      open_float(c, win, a1, a2, ("%s · %s"):format(title, where))
    end
    send(c, name, ("## %s · `%s`\n%s"):format(title, where, sub or ""), instruction .. "\n\n" .. ctx)
  end
  if name == "ask" then
    if question and vim.trim(question) ~= "" then
      return go("Ask", question, "_" .. question .. "_\n")
    end
    return vim.ui.input({ prompt = "Ask about " .. where .. ": " }, function(q)
      if q and vim.trim(q) ~= "" then
        go("Ask", q, "_" .. q .. "_\n")
      end
    end)
  end
  local a = QUICK_ACTIONS[name]
  if not a then
    return notify("Unknown action: " .. name, vim.log.levels.WARN)
  end
  go(a.title, a.prompt)
end

local function arrange()
  local wins = state.wins
  if not (win_ok(wins.files) and win_ok(wins.agent)) then
    return
  end
  local agent_w = math.floor(vim.o.columns * M.config.agent_width)
  local stacked = (vim.o.columns - agent_w - 2) / 2 < M.config.min_diff_width
  -- J and L span the whole screen, so moving the files panel last keeps it under everything.
  vim.api.nvim_win_call(wins.agent, function()
    vim.cmd("wincmd " .. (stacked and "J" or "L"))
  end)
  vim.api.nvim_win_call(wins.files, function()
    vim.cmd("wincmd J")
  end)
  vim.wo[wins.agent].winfixwidth = not stacked
  vim.wo[wins.agent].winfixheight = stacked
  vim.wo[wins.files].winfixwidth, vim.wo[wins.files].winfixheight = false, true
  vim.api.nvim_win_set_height(wins.files, math.min(M.config.files_height, HEADER + math.max(#state.files, 1)))
  if stacked then
    vim.api.nvim_win_set_height(wins.agent, math.floor(vim.o.lines * M.config.agent_height))
  else
    vim.api.nvim_win_set_width(wins.agent, agent_w)
  end
  split_diff()
  state.size = vim.o.columns .. "x" .. vim.o.lines
end

-- Comments on the finding whose heading is on or above the cursor in the agent pane.
local function comment_finding()
  local buf = state.bufs.agent
  local function line_at(i)
    return i >= 1 and vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
  end
  for i = vim.api.nvim_win_get_cursor(0)[1], 1, -1 do
    local line = line_at(i)
    local severity, path, lnum = line:match(FINDING)
    if severity then
      local f = find_file(relative(path))
      if not f then
        return notify("Not part of this change: " .. path, vim.log.levels.WARN)
      end
      if f ~= state.current then
        show(f)
      end
      local win = f.status == "D" and state.wins.base or state.wins.head
      vim.api.nvim_set_current_win(win)
      pcall(vim.api.nvim_win_set_cursor, win, { tonumber(lnum), 0 })
      return M.comment()
    end
    if line:match("^## ") or (vim.trim(line) == "" and not line_at(i - 1):match(FINDING)) then
      break
    end
  end
  notify("Move the cursor to a finding to comment on it", vim.log.levels.WARN)
end

local function layout()
  vim.cmd("tabnew")
  state.tab = vim.api.nvim_get_current_tabpage()
  vim.bo.bufhidden = "wipe"
  local wins = state.wins
  wins.files = vim.api.nvim_get_current_win()
  for _, name in ipairs({ "base", "head", "agent" }) do
    vim.cmd("rightbelow vsplit")
    wins[name] = vim.api.nvim_get_current_win()
  end
  state.bufs.files = panel("review://files")
  state.bufs.agent = panel("review://agent", "markdown")
  vim.api.nvim_win_set_buf(wins.files, state.bufs.files)
  vim.api.nvim_win_set_buf(wins.agent, state.bufs.agent)
  for _, win in ipairs({ wins.files, wins.agent }) do
    local wo = vim.wo[win]
    wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn = false, false, "no", "0"
    wo.winfixwidth, wo.winfixbuf, wo.list, wo.spell = true, true, false, false
  end
  vim.wo[wins.files].cursorline = true
  vim.wo[wins.files].wrap = false
  vim.wo[wins.agent].wrap = true
  vim.wo[wins.agent].linebreak = true
  arrange()

  local function map(buf, lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end
  map(state.bufs.files, "<CR>", function()
    show(file_under_cursor())
  end, "Open file diff")
  map(state.bufs.files, "v", M.toggle_viewed, "Toggle viewed")
  map(state.bufs.files, "t", M.tour, "Run the tour again")
  map(state.bufs.files, "r", function()
    M.action("review")
  end, "Review the whole change")
  map(state.bufs.files, "q", M.close, "Close review")
  map(state.bufs.files, "f", pick_file, "Go to a changed file")
  map(state.bufs.agent, "<CR>", jump, "Jump to path:line")
  map(state.bufs.agent, "gf", jump, "Jump to path:line")
  map(state.bufs.agent, "c", comment_finding, "Comment on the finding in your pending GitHub review")
end

local function changed_files(spec)
  local range = spec.head and { spec.base, spec.head } or { spec.base }
  local status = run(vim.list_extend({ "git", "diff", "--name-status", "-M", "-z" }, range), spec.root)
  local numstat = run(vim.list_extend({ "git", "diff", "--numstat", "-M", "-z" }, range), spec.root)
  local files, by_path = {}, {}
  local t, i = vim.split(status, "\0", { plain = true }), 1
  while i <= #t and t[i] ~= "" do
    local code = t[i]:sub(1, 1)
    local f = { status = code }
    if code == "R" or code == "C" then
      f.old_path, f.path, i = t[i + 1], t[i + 2], i + 3
    else
      f.path, i = t[i + 1], i + 2
    end
    files[#files + 1] = f
    by_path[f.path] = f
  end
  -- numstat -z writes renames as "added\tremoved\t\0old\0new\0".
  t, i = vim.split(numstat, "\0", { plain = true }), 1
  while i <= #t and t[i] ~= "" do
    local added, removed, path = t[i]:match("^(%S+)\t(%S+)\t(.*)$")
    if path == "" then
      path, i = t[i + 2], i + 3
    else
      i = i + 1
    end
    local f = path and by_path[path]
    if f then
      f.binary = added == "-"
      f.added, f.removed = tonumber(added), tonumber(removed)
    end
  end
  return files
end

local function default_base(root)
  local ok, ref = pcall(run, { "git", "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD" }, root)
  if ok and ref ~= "" then
    return ref
  end
  for _, candidate in ipairs({ "origin/main", "origin/master", "main", "master" }) do
    if pcall(run, { "git", "rev-parse", "--verify", "--quiet", candidate }, root) then
      return candidate
    end
  end
  error("No base branch found. Pass one, for example :Review origin/develop", 0)
end

local function start(spec, fresh)
  if state.tab then
    M.close()
  end
  local key = spec.root .. "|" .. spec.key
  local saved = (not fresh and read_store()[key]) or {}
  state.root, state.base, state.head, state.label, state.key, state.pr =
    spec.root, spec.base, spec.head, spec.label, key, spec.pr
  state.files = order(spec.files, saved.order)
  state.viewed = type(saved.viewed) == "table" and saved.viewed or {}
  state.findings = type(saved.findings) == "table" and saved.findings or {}
  agent.root, agent.label = state.root, state.label
  agent.session = saved.agent == adapter_name() and saved.session or nil
  layout()
  agent.buf, agent.win = state.bufs.agent, state.wins.agent
  local transcript = transcript_path()
  if saved.order and vim.uv.fs_stat(transcript) then
    vim.bo[state.bufs.agent].modifiable = true
    vim.api.nvim_buf_set_lines(state.bufs.agent, 0, -1, false, vim.fn.readfile(transcript))
    vim.bo[state.bufs.agent].modifiable = false
    paint(state.bufs.agent, 0, -1)
    agent.last = "meta"
  end
  show(next_unviewed() or state.files[1])
  persist()
  status(agent)
  if not agent.session and M.config.auto_tour then
    M.tour()
  end
end

function M.open(arg, fresh)
  arg = vim.trim(arg or "")
  if not adapter() then
    return notify("Unknown review agent: " .. tostring(adapter_name()), vim.log.levels.ERROR)
  end
  local dir = vim.fn.expand("%:p:h")
  if dir == "" or not vim.uv.fs_stat(dir) then
    dir = vim.fn.getcwd()
  end
  local root = git({ "rev-parse", "--show-toplevel" }, dir)
  if not root then
    return notify("Not inside a git repository", vim.log.levels.WARN)
  end
  root = vim.trim(root)
  async(function()
    local spec = { root = root }
    local pr = arg:match("^#?(%d+)$")
    if pr then
      notify("Fetching PR #" .. pr)
      local fields = "number,title,body,url,baseRefName,headRefOid"
      local info = decode(run({ "gh", "pr", "view", pr, "--json", fields }, root))
      run({ "git", "fetch", "--quiet", "origin", info.baseRefName }, root)
      if run({ "git", "rev-parse", "HEAD" }, root) ~= info.headRefOid then
        if not pcall(run, { "git", "cat-file", "-e", info.headRefOid .. "^{commit}" }, root) then
          run({ "git", "fetch", "--quiet", "origin", ("pull/%d/head"):format(info.number) }, root)
        end
        spec.head = info.headRefOid
      end
      spec.base = run({ "git", "merge-base", "origin/" .. info.baseRefName, info.headRefOid }, root)
      spec.label = ("PR #%d %s"):format(info.number, info.title)
      spec.key = "pr#" .. info.number
      spec.pr = info
    else
      local ref = arg ~= "" and arg or default_base(root)
      spec.base = run({ "git", "merge-base", ref, "HEAD" }, root)
      spec.label = ("%s vs %s"):format(run({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, root), ref)
      spec.key = spec.label
    end
    spec.files = changed_files(spec)
    if #spec.files == 0 then
      return notify(
        ("No changes in %s. Select code and run :ReviewAsk, or an action, to ask about it."):format(spec.label)
      )
    end
    start(spec, fresh)
  end)
end

local function whole_change(intro, instruction)
  local lines = { intro .. " Changed files (status, path, lines added and removed):" }
  for _, f in ipairs(state.files) do
    lines[#lines + 1] = file_summary(f)
  end
  if state.pr then
    vim.list_extend(
      lines,
      { "", "PR title: " .. state.pr.title, "PR description:", (state.pr.body or ""):sub(1, 4000) }
    )
  end
  if not adapter().shell then
    local diff = git(vim.list_extend({ "diff", "--no-color", "-M" }, diff_range())) or ""
    vim.list_extend(lines, { "", fence("diff", split_lines(diff), M.config.max_tour_lines) })
  end
  vim.list_extend(lines, { "", instruction })
  return table.concat(lines, "\n")
end

-- A finding's detail is the paragraph under its heading line.
local function parse_findings(reply)
  local found, current = {}, nil
  for line in (reply .. "\n"):gmatch("([^\n]*)\n") do
    local severity, path, lnum, title = line:match(FINDING)
    if severity then
      current =
        { severity = severity:lower(), path = relative(path), line = tonumber(lnum), title = title, detail = "" }
      found[#found + 1] = current
    elseif current and vim.trim(line) == "" then
      current = current.detail == "" and current or nil
    elseif current then
      current.detail = vim.trim(current.detail .. " " .. vim.trim(line))
    end
  end
  return found
end

local function review_change()
  ask("review", "## Review\n", whole_change("Review the change below.", review_prompt(adapter().shell)), function(reply)
    state.findings = parse_findings(reply)
    persist()
    mark_lines()
    notify(("%d finding%s"):format(#state.findings, #state.findings == 1 and "" or "s"))
  end)
end

function M.tour()
  if not state.tab then
    return
  end
  ask("tour", "## Tour\n", whole_change("Start the review.", TOUR), function(reply)
    local block = reply:match("```review%-order[^\n]*\n(.-)```")
    if block then
      state.files = order(state.files, split_lines(block))
      persist()
      render_files()
    end
  end)
end

function M.action(name, question, range)
  range = range or selection()
  if name == "review" then
    if not in_review() then
      return notify("Reviewing the whole change needs the review tab, see :Review", vim.log.levels.WARN)
    end
    return review_change()
  end
  if not in_review() then
    return quick_action(name, question, range)
  end
  local where, ctx = context(range)
  local function send(title, instruction, sub)
    ask(name, ("## %s · `%s`\n%s"):format(title, where, sub or ""), instruction .. "\n\n" .. ctx)
  end
  if name == "ask" then
    if question and vim.trim(question) ~= "" then
      return send("Ask", question, "_" .. question .. "_\n")
    end
    return vim.ui.input({ prompt = "Ask about " .. where .. ": " }, function(q)
      if q and vim.trim(q) ~= "" then
        send("Ask", q, "_" .. q .. "_\n")
      end
    end)
  end
  local a = ACTIONS[name]
  if not a then
    return notify("Unknown review action: " .. name, vim.log.levels.WARN)
  end
  send(a.title, a.prompt)
end

function M.next(delta)
  if not state.tab or #state.files == 0 then
    return
  end
  local i = index_of(state.current) or 1
  show(state.files[(i - 1 + delta) % #state.files + 1])
end

function M.files()
  if not state.tab then
    return notify("No review open. Start one with :Review", vim.log.levels.WARN)
  end
  if not in_review() then
    vim.api.nvim_set_current_tabpage(state.tab)
  end
  pick_file()
end

function M.toggle_viewed()
  if not state.tab then
    return
  end
  local in_panel = vim.api.nvim_get_current_win() == state.wins.files
  local f = file_under_cursor() or state.current
  if not f then
    return
  end
  state.viewed[f.path] = not state.viewed[f.path] or nil
  persist()
  if state.viewed[f.path] and not in_panel then
    local nxt = next_unviewed(f)
    if nxt then
      return show(nxt)
    end
    notify(("All %d files viewed"):format(#state.files))
  end
  render_files()
end

function M.answer()
  local c = quick_here()
  if not c then
    return notify("No answers yet for this repository")
  end
  local win = vim.api.nvim_get_current_win()
  if displays(win, c.buf) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(win)[1]
  open_float(c, win, cursor, cursor, "Last answer")
end

function M.refs()
  local c = in_review() and agent or quick_here()
  if not (c and c.root) then
    return notify("No answers yet")
  end
  local items, seen = {}, {}
  for _, line in ipairs(vim.split(c.busy and c.reply or c.last_reply, "\n", { plain = true })) do
    for path, lnum in line:gmatch(REF) do
      path = relative(path, c.root)
      local id = path .. ":" .. lnum
      if not seen[id] then
        seen[id] = true
        items[#items + 1] = { filename = c.root .. "/" .. path, lnum = tonumber(lnum), text = vim.trim(line) }
      end
    end
  end
  if #items == 0 then
    return notify("No path:line references in the last answer")
  end
  vim.fn.setqflist({}, " ", { title = "Review refs", items = items })
  vim.cmd("botright copen")
end

local function pull_request()
  if not state.gh then
    local info = state.pr or decode(run({ "gh", "pr", "view", "--json", "number,url,headRefOid" }, state.root))
    local owner, repo = info.url:match("^https?://[^/]+/([^/]+)/([^/]+)/pull/%d+")
    state.gh = { owner = owner, repo = repo, number = info.number, head = info.headRefOid }
  end
  return state.gh
end

local function graphql(query, vars)
  local cmd = { "gh", "api", "graphql", "-f", "query=" .. query }
  for k, v in pairs(vars) do
    vim.list_extend(cmd, { type(v) == "number" and "-F" or "-f", k .. "=" .. v })
  end
  return decode(run(cmd, state.root)).data
end

-- GitHub allows one pending review per user and PR, and only its author can see it.
local function pending_review(pr)
  local data = graphql(GH_PENDING, { owner = pr.owner, repo = pr.repo, number = pr.number })
  local node = data.repository.pullRequest
  for _, review in ipairs(node.reviews.nodes) do
    if review.author and review.author.login == data.viewer.login then
      return review, node.id
    end
  end
  return nil, node.id
end

-- Ex commands that write the current buffer, with the shortest abbreviation Vim accepts for each.
local WRITE_CMDS = { write = 1, wq = 2, xit = 1, exit = 3, update = 2, wall = 2, wqall = 3, xall = 2 }

local function writes(cmd)
  for full, min in pairs(WRITE_CMDS) do
    if #cmd >= min and full:sub(1, #cmd) == cmd then
      return true
    end
  end
  return false
end

local function compose(title, lines, on_submit, draft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  pcall(vim.api.nvim_buf_set_name, buf, "review://comment/" .. buf)
  vim.bo[buf].filetype = "markdown"
  if draft then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(draft, "\n", { plain = true }))
  end
  local width, height = math.min(80, vim.o.columns - 4), math.min(12, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
    footer = lines and " :w or <C-s> add · q cancel · gs suggestion " or " :w or <C-s> add · q cancel ",
    footer_pos = "center",
  })
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local function submit()
    local body = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    if body == "" then
      return notify("Empty comment, nothing added", vim.log.levels.WARN)
    end
    vim.bo[buf].modified = false
    -- Closing on the next tick lets :wq quit the float itself instead of the window under it.
    vim.schedule(close)
    on_submit(body)
  end
  -- Autosave (:wall on InsertLeave or TextChanged) writes this buffer too, so only a command typed here sends it.
  local typed = false
  vim.api.nvim_create_autocmd("CmdlineLeave", {
    buffer = buf,
    callback = function()
      local cmd = vim.fn.getcmdline():match("^[%s:]*(%a+)")
      typed = vim.fn.getcmdtype() == ":" and not vim.v.event.abort and cmd ~= nil and writes(cmd)
      if typed then
        vim.api.nvim_create_autocmd("SafeState", {
          once = true,
          callback = function()
            typed = false
          end,
        })
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      if typed then
        typed = false
        submit()
      end
    end,
  })
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    vim.cmd("stopinsert")
    submit()
  end, { buffer = buf, desc = "Add comment" })
  vim.keymap.set("n", "q", function()
    vim.bo[buf].modified = false
    close()
  end, { buffer = buf, nowait = true, desc = "Cancel comment" })
  if lines then
    vim.keymap.set("n", "gs", function()
      local row = vim.api.nvim_win_get_cursor(win)[1]
      local block = vim.list_extend({ "```suggestion" }, vim.list_extend(vim.list_slice(lines), { "```" }))
      vim.api.nvim_buf_set_lines(buf, row, row, false, block)
    end, { buffer = buf, desc = "Insert a suggestion block" })
  end
  if not draft then
    vim.cmd("startinsert")
  end
end

function M.comment(range)
  if not state.tab then
    return notify("No review open. Start one with :Review", vim.log.levels.WARN)
  end
  range = range or selection()
  local win, f = vim.api.nvim_get_current_win(), state.current
  if not f or (win ~= state.wins.base and win ~= state.wins.head) then
    return notify("Move the cursor to a line in the diff to comment on it", vim.log.levels.WARN)
  end
  local side = win == state.wins.base and "LEFT" or "RIGHT"
  local cursor = vim.api.nvim_win_get_cursor(win)[1]
  local l1, l2 = unpack(range or { cursor, cursor })
  local inside = false
  for _, h in ipairs(hunks()) do
    local s = side == "LEFT" and h.old_start or h.new_start
    local e = s + (side == "LEFT" and h.old_count or h.new_count) - 1
    inside = inside or (l1 >= s and l2 <= e)
  end
  if not inside then
    return notify(
      ("Lines %d-%d are outside the diff, and GitHub only takes comments inside a hunk"):format(l1, l2),
      vim.log.levels.WARN
    )
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local lines, modified = vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false), vim.bo[buf].modified
  local finding = not range and finding_at(f, side, l1)
  local draft = finding and vim.trim(finding.title .. "\n\n" .. (finding.detail or ""))
  async(function()
    local pr = pull_request()
    if not state.head then
      local head = run({ "git", "rev-parse", "HEAD" }, state.root)
      if head ~= pr.head then
        error(
          ("Local HEAD %s is not the PR head %s. Push or pull first so line numbers match GitHub."):format(
            head:sub(1, 8),
            pr.head:sub(1, 8)
          ),
          0
        )
      end
      if
        side == "RIGHT"
        and (modified or not pcall(run, { "git", "diff", "--quiet", "HEAD", "--", f.path }, state.root))
      then
        error(f.path .. " has changes that are not in the PR, so line numbers would not match GitHub. Push first.", 0)
      end
    end
    local where = ("%s:%s%s"):format(f.path, l1 == l2 and l1 or (l1 .. "-" .. l2), side == "LEFT" and " (base)" or "")
    compose(("PR #%d · %s"):format(pr.number, where), side == "RIGHT" and lines or nil, function(body)
      async(function()
        if not state.tab then
          return notify("The review was closed, so the comment was not added", vim.log.levels.WARN)
        end
        local review, pr_id = pending_review(pr)
        if not review then
          review =
            graphql(GH_START, { pr = pr_id, commit = state.head or pr.head }).addPullRequestReview.pullRequestReview
        end
        local vars = { review = review.id, path = f.path, line = l2, side = side, body = body }
        if l1 ~= l2 then
          vars.startLine, vars.startSide = l1, side
        end
        graphql(GH_THREAD, vars)
        table.insert(state.comments, { path = f.path, side = side, line = l2, body = body })
        render_files()
        mark_lines()
        notify(
          ("Added to your pending review on PR #%d. Submit it with :ReviewSubmit or at %s"):format(
            pr.number,
            review.url
          )
        )
      end)
    end, draft)
  end)
end

function M.submit()
  if not state.tab then
    return notify("No review open. Start one with :Review", vim.log.levels.WARN)
  end
  async(function()
    local pr = pull_request()
    local review = pending_review(pr)
    if not review then
      return notify(("You have no pending review on PR #%d"):format(pr.number))
    end
    local events = { Comment = "COMMENT", Approve = "APPROVE", ["Request changes"] = "REQUEST_CHANGES" }
    vim.ui.select({ "Comment", "Approve", "Request changes" }, {
      prompt = ("Submit your review on PR #%d as"):format(pr.number),
    }, function(choice)
      if not choice then
        return
      end
      vim.ui.input({ prompt = "Review summary (optional): " }, function(body)
        if body == nil then
          return
        end
        async(function()
          local vars = { review = review.id, event = events[choice] }
          if vim.trim(body) ~= "" then
            vars.body = body
          end
          local data = graphql(GH_SUBMIT, vars)
          state.comments = {}
          render_files()
          mark_lines()
          notify("Review submitted: " .. data.submitPullRequestReview.pullRequestReview.url)
        end)
      end)
    end)
  end)
end

function M.cancel()
  cancel(in_review() and agent or quick_here())
end

function M.close()
  if not state.key then
    return
  end
  stop(agent)
  persist()
  save_transcript()
  clear_marks()
  local tab = state.tab
  reset()
  if tab and vim.api.nvim_tabpage_is_valid(tab) then
    if #vim.api.nvim_list_tabpages() == 1 then
      vim.cmd("tabnew")
    end
    vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(tab))
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  local cmd = vim.api.nvim_create_user_command
  cmd("Review", function(o)
    M.open(o.args, o.bang)
  end, { nargs = "?", bang = true, desc = "Guided review against a base ref or #PR (! starts fresh)" })
  cmd("ReviewClose", M.close, { desc = "Close the review" })
  cmd("ReviewCancel", M.cancel, { desc = "Stop the running agent answer" })
  cmd("ReviewRefs", M.refs, { desc = "Send path:line references of the last answer to quickfix" })
  cmd("ReviewAsk", function(o)
    M.action("ask", o.args, o.range > 0 and { o.line1, o.line2 } or nil)
  end, { nargs = "*", range = true, desc = "Ask the review agent about the hunk or range" })
  cmd("ReviewComment", function(o)
    M.comment(o.range > 0 and { o.line1, o.line2 } or nil)
  end, { range = true, desc = "Add a comment on the line or range to your pending GitHub review" })
  cmd("ReviewSubmit", M.submit, { desc = "Submit your pending GitHub review" })
  cmd("ReviewFiles", M.files, { desc = "Go to a changed file in the review" })
  local group = vim.api.nvim_create_augroup("agentic_review", { clear = true })
  define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_highlights })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      if state.tab and not vim.api.nvim_tabpage_is_valid(state.tab) then
        M.close()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResized", "TabEnter" }, {
    group = group,
    callback = function()
      local size = vim.o.columns .. "x" .. vim.o.lines
      if state.tab == vim.api.nvim_get_current_tabpage() and state.size ~= size then
        arrange()
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      persist()
      save_transcript()
      stop(agent)
      for _, c in pairs(quick) do
        stop(c)
      end
    end,
  })
end

return M
