local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua").setup()
local check, text = H.check, H.text

H.run(function()
  local rg = require("agentic_review")
  local function arg_after(argv, flag)
    for i, a in ipairs(argv) do
      if a == flag then
        return argv[i + 1]
      end
    end
  end

  local ctx = { system = "s", label = "l", root = H.repo }
  check(
    "claude git-only by default",
    arg_after(rg.adapters.claude.cmd(ctx), "--allowedTools"):find("git diff", 1, true)
  )
  ctx.full_shell = true
  check("claude full shell", arg_after(rg.adapters.claude.cmd(ctx), "--allowedTools") == "Read,Grep,Glob,Bash")

  local own = vim.tbl_extend("force", rg.adapters.pi, { extensions = { "/x/bridge" }, skills = { "~/skill" } })
  local argv = rg.adapters.pi.cmd(ctx, own)
  local line = table.concat(argv, " ")
  check("pi loads the extension", line:find("-e /x/bridge", 1, true) ~= nil, argv)
  check("pi loads the skill", line:find("--skill " .. vim.fn.expand("~/skill"), 1, true) ~= nil, argv)
  check("pi bash for a full shell", arg_after(argv, "--tools") == "read,grep,find,ls,bash", argv)
  ctx.full_shell = nil
  check("pi read-only otherwise", arg_after(rg.adapters.pi.cmd(ctx, own), "--tools") == "read,grep,find,ls")

  -- A partial table under pi's name keeps pi's encode and parse.
  local events = {
    '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"pi says hello"}}',
    '{"type":"agent_settled","aborted":false}',
  }
  local script = "while read l; do printf '%s\\n' "
    .. table.concat(vim.tbl_map(vim.fn.shellescape, events), " ")
    .. "; done"
  local spawns, prompts = {}, {}
  rg.setup({
    agent = "pi",
    auto_tour = false,
    review_prompt = "/skill:review",
    review_shell = function(c)
      return c.root == H.repo
    end,
    adapters = {
      pi = {
        skills = { "/x/skill" },
        cmd = function(c, a)
          local _, session = rg.adapters.pi.cmd(c, a)
          spawns[#spawns + 1] = { full_shell = c.full_shell, system = c.system, session = session, skills = a.skills }
          return { "sh", "-c", script }, session
        end,
        encode = function(prompt)
          prompts[#prompts + 1] = prompt
          return rg.adapters.pi.encode(prompt)
        end,
      },
    },
  })
  rg.open("")
  vim.wait(5000, function()
    return #vim.api.nvim_list_tabpages() == 2
  end)
  local pane = vim.api.nvim_win_get_buf(H.review_wins()[4])

  rg.action("explain")
  H.wait_answers(pane, 1)
  rg.action("review")
  H.wait_answers(pane, 2)
  rg.action("explain")
  H.wait_answers(pane, 3)

  check("pi parse kept", select(2, text(pane):gsub("pi says hello", "")) == 3, text(pane))
  check("adapter fields reach cmd", spawns[1] and spawns[1].skills and spawns[1].skills[1] == "/x/skill", spawns[1])
  check(
    "review restarts with a full shell, then without",
    #spawns == 3 and not spawns[1].full_shell and spawns[2].full_shell and not spawns[3].full_shell,
    spawns
  )
  check(
    "same session across restarts",
    #spawns == 3 and spawns[1].session == spawns[2].session and spawns[2].session == spawns[3].session,
    spawns
  )
  check("full shell prompt", spawns[2] and spawns[2].system:find("runs any command", 1, true) ~= nil)
  check("read-only prompt", spawns[1] and spawns[1].system:find("You are read-only", 1, true) ~= nil)
  check("review prompt sent", prompts[2] == "/skill:review", prompts)

  rg.config.review_shell = false
  rg.action("review")
  H.wait_answers(pane, 4)
  check("no restart without a full shell", #spawns == 3, #spawns)
end)
