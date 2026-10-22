local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua").setup()
local check, text = H.check, H.text

H.run(function()
  local rg = require("agentic_review")

  -- pi's RPC events, in the shapes its docs/json.md describes.
  local pi_events = {
    '{"type":"response","command":"prompt","success":true,"data":{"disposition":"started"}}',
    '{"type":"agent_start"}',
    '{"type":"tool_execution_start","toolCallId":"c1","toolName":"read","args":{"path":"src/cart.lua"}}',
    '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"pi says "}}',
    '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"hello"}}',
    '{"type":"agent_end","messages":[],"willRetry":false}',
    '{"type":"agent_settled","aborted":false}',
  }
  local script = "while read l; do printf '%s\\n' "
    .. table.concat(vim.tbl_map(vim.fn.shellescape, pi_events), " ")
    .. "; done"
  local fake_pi = vim.tbl_extend("force", rg.adapters.pi, {
    cmd = function(ctx)
      local _, session = rg.adapters.pi.cmd(ctx)
      return { "sh", "-c", script }, session
    end,
  })

  rg.setup({ agent = "fakepi", adapters = { fakepi = fake_pi }, auto_tour = false })
  rg.open("")
  vim.wait(5000, function()
    return #vim.api.nvim_list_tabpages() == 2
  end)
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local agent_buf = vim.api.nvim_win_get_buf(wins[4])

  rg.action("explain")
  H.wait_answers(agent_buf, 1)
  check("pi parse text", text(agent_buf):find("pi says hello", 1, true) ~= nil, text(agent_buf))
  check("pi parse tool", text(agent_buf):find("> read `src/cart.lua`", 1, true) ~= nil, text(agent_buf))
  rg.action("deep")
  H.wait_answers(agent_buf, 2)
  check("pi second turn same process", select(2, text(agent_buf):gsub("pi says hello", "")) == 2, text(agent_buf))
  local entry = H.store_entry(H.repo .. "|feature vs main")
  check("pi client session id", entry and entry.session and entry.session:match("^review%-%x+$") ~= nil, entry)

  local system
  rg.config.adapters.spy = {
    cmd = function(ctx)
      system = ctx.system
      return { "sh", "-c", "printf ok" }
    end,
  }
  rg.config.agent = "spy"
  rg.action("explain")
  H.wait_answers(agent_buf, 3)
  check("no-shell agent told it has no shell", (system or ""):find("You have no shell", 1, true) ~= nil, system)

  rg.config.adapters.slow = {
    cmd = function()
      return { "sh", "-c", "sleep 30" }
    end,
  }
  rg.config.agent = "slow"
  rg.action("explain")
  vim.wait(200)
  check("busy winbar", vim.wo[wins[4]].winbar:find("working", 1, true) ~= nil, vim.wo[wins[4]].winbar)
  rg.cancel()
  check(
    "cancelled",
    text(agent_buf):find("_cancelled_", 1, true) ~= nil and vim.wo[wins[4]].winbar:find("idle", 1, true) ~= nil
  )

  rg.config.adapters.broken = {
    cmd = function()
      return { "sh", "-c", "echo 'boom' >&2; exit 3" }
    end,
  }
  rg.config.agent = "broken"
  rg.action("explain")
  H.wait_answers(agent_buf, 5)
  check("process failure shown", text(agent_buf):find("_error: boom_", 1, true) ~= nil, text(agent_buf):sub(-200))
end)
