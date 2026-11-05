-- A stand-in for an interactive agent, run with `nvim -l`. It answers each request in $AGENTIC_REVIEW_DIR/inbox
-- with $FAKE_REPLY in the outbox and logs the requests. A prompt with SLOW gets no answer, one with EXIT ends the
-- process with code 3.
local dir = assert(os.getenv("AGENTIC_REVIEW_DIR"))
local reply = os.getenv("FAKE_REPLY") or "ok"

local function append(path, value)
  local file = assert(io.open(path, "a"))
  file:write(vim.json.encode(value), "\n")
  file:close()
end

io.stdout:write("fake session ready\n")
local offset, partial, pending = 0, "", nil
while true do
  local file = io.open(dir .. "/inbox", "r")
  if file then
    file:seek("set", offset)
    local data = file:read("*a") or ""
    file:close()
    offset = offset + #data
    partial = partial .. data
    for line in partial:gmatch("([^\n]*)\n") do
      local req = vim.json.decode(line)
      append(dir .. "/requests", req)
      if req.type == "abort" then
        if pending then
          append(dir .. "/outbox", { id = pending, text = "", aborted = true })
          pending = nil
        end
      elseif req.prompt:find("EXIT", 1, true) then
        os.exit(3)
      elseif req.prompt:find("SLOW", 1, true) then
        pending = req.id
      else
        append(dir .. "/outbox", { id = req.id, text = reply })
      end
    end
    partial = partial:match("[^\n]*$")
  end
  vim.uv.sleep(50)
end
