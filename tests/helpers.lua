-- Shared setup for the headless specs: a throwaway git repository, an isolated state directory and reporting.
local H = {}

H.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local results, failed = {}, 0

function H.check(name, cond, info)
  if cond then
    results[#results + 1] = "PASS " .. name
  else
    failed = failed + 1
    results[#results + 1] = "FAIL " .. name .. "  -> " .. vim.inspect(info)
  end
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

function H.git(...)
  local cmd = { "git", "-c", "core.hooksPath=/dev/null", "-c", "user.name=test", "-c", "user.email=test@example.com" }
  local res = vim.system(vim.list_extend(cmd, { ... }), { cwd = H.repo, text = true }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. ": " .. res.stderr)
  return vim.trim(res.stdout)
end

-- main has src/cart.lua, src/util.lua and README.md. feature changes cart.lua lines 3 and 17, adds
-- src/discount.lua and logo.png, deletes src/util.lua and moves README.md to docs/. cart.lua also gets one
-- uncommitted line at the end.
function H.setup()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  H.tmp = vim.uv.fs_realpath(tmp)
  H.repo = H.tmp .. "/repo"
  vim.env.XDG_STATE_HOME = H.tmp .. "/state"
  H.store = H.tmp .. "/state/nvim/agentic_review.json"
  vim.o.columns, vim.o.lines = 220, 50

  local cart = {}
  for i = 1, 20 do
    cart[i] = ("local line%d = %d"):format(i, i)
  end
  vim.fn.mkdir(H.repo, "p")
  H.git("init", "-q", "-b", "main")
  write(H.repo .. "/src/cart.lua", table.concat(cart, "\n") .. "\n")
  write(H.repo .. "/src/util.lua", "local M = {}\nfunction M.round(x) return math.floor(x + 0.5) end\nreturn M\n")
  write(H.repo .. "/README.md", "# Demo\n\nSome text\n")
  H.git("add", "-A")
  H.git("commit", "-qm", "base")

  H.git("checkout", "-qb", "feature")
  cart[3] = "local line3 = 33 -- changed"
  cart[17] = "local line17 = apply_discount(17)"
  write(H.repo .. "/src/cart.lua", table.concat(cart, "\n") .. "\n")
  write(H.repo .. "/src/discount.lua", "local M = {}\nfunction M.apply(x) return x * 0.9 end\nreturn M\n")
  H.git("rm", "-q", "src/util.lua")
  vim.fn.mkdir(H.repo .. "/docs", "p")
  H.git("mv", "README.md", "docs/README.md")
  write(H.repo .. "/docs/README.md", "# Demo\n\nSome text\nMore\n")
  write(H.repo .. "/logo.png", "\137PNG\r\n\26\n\0\0")
  H.git("add", "-A")
  H.git("commit", "-qm", "feature")
  H.head = H.git("rev-parse", "HEAD")
  write(H.repo .. "/src/cart.lua", table.concat(cart, "\n") .. "\nlocal uncommitted = true\n")

  vim.fn.chdir(H.repo)
  H.notes = {}
  vim.notify = function(msg)
    H.notes[#H.notes + 1] = msg
  end
  return H
end

function H.last_note()
  return H.notes[#H.notes] or ""
end

function H.lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

function H.text(buf)
  return table.concat(H.lines(buf), "\n")
end

-- Each finished answer ends with a "_<seconds>s_" line.
function H.answers(buf)
  return select(2, H.text(buf):gsub("_%d+s_", ""))
end

function H.wait_answers(buf, n)
  return vim.wait(5000, function()
    return H.answers(buf) >= n
  end, 20)
end

function H.floats()
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
  end, vim.api.nvim_tabpage_list_wins(0))
end

function H.store_entry(key)
  return vim.json.decode(table.concat(vim.fn.readfile(H.store), "\n"))[key]
end

-- A persistent adapter that answers every prompt with `text`, in Claude Code's stream-json format.
function H.fake_agent(text, opts)
  opts = opts or {}
  local delta =
    { type = "stream_event", event = { type = "content_block_delta", delta = { type = "text_delta", text = text } } }
  local events = { '{"type":"system","subtype":"init","session_id":"' .. (opts.session or "sess-1") .. '"}' }
  if opts.tool then
    events[#events + 1] = vim.json.encode({
      type = "assistant",
      message = { content = { { type = "tool_use", name = "Read", input = { file_path = opts.tool } } } },
    })
  end
  events[#events + 1] = vim.json.encode(delta)
  events[#events + 1] = '{"type":"result","is_error":false}'
  local script = "while read l; do printf '%s\\n' "
    .. table.concat(vim.tbl_map(vim.fn.shellescape, events), " ")
    .. "; done"
  return {
    persistent = true,
    shell = true,
    cmd = function(ctx)
      if opts.on_spawn then
        opts.on_spawn(ctx)
      end
      return { "sh", "-c", script }
    end,
    encode = function(prompt)
      if opts.on_prompt then
        opts.on_prompt(prompt)
      end
      return vim.json.encode({ prompt = prompt })
    end,
    parse = require("agentic_review").adapters.claude.parse,
  }
end

function H.run(fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    H.check("spec ran to the end", false, err)
  end
  io.stdout:write("\n", table.concat(results, "\n"), "\n", ("%d passed, %d failed\n"):format(#results - failed, failed))
  vim.cmd(failed == 0 and "qa!" or "cquit 1")
end

return H
