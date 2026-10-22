local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua").setup()
local check = H.check

H.run(function()
  local rg = require("agentic_review")
  local spawns, switches = {}, {}
  local function fake(live)
    local a = H.fake_agent("ok", {
      session = "s-1",
      on_spawn = function(ctx)
        spawns[#spawns + 1] = { model = ctx.model or false, session = ctx.session or false }
      end,
    })
    a.models = { explain = "small", deep = "big" }
    if live then
      a.set_model = function(model)
        switches[#switches + 1] = model
        return vim.json.encode({ type = "control_request", model = model })
      end
    end
    return a
  end
  rg.setup({ agent = "live", auto_tour = false, adapters = { live = fake(true), restart = fake(false) } })
  rg.open("")
  vim.wait(5000, function()
    return #vim.api.nvim_list_tabpages() == 2
  end)
  local agent_win = H.review_wins()[4]
  local pane = vim.api.nvim_win_get_buf(agent_win)
  local answers = 0
  local function run(name)
    rg.action(name)
    answers = answers + 1
    H.wait_answers(pane, answers)
  end

  run("explain")
  check("action model at spawn", #spawns == 1 and spawns[1].model == "small", spawns)
  check("model in winbar", vim.wo[agent_win].winbar:find("live · small · idle", 1, true) ~= nil)

  run("deep")
  check("switch in place", #spawns == 1 and vim.deep_equal(switches, { "big" }), { spawns, switches })
  check("winbar follows", vim.wo[agent_win].winbar:find("live · big · idle", 1, true) ~= nil)
  run("deep")
  check("same model no switch", #switches == 1, switches)

  -- The user's models win over the adapter's, and `model` covers every action `models` leaves out.
  rg.config.models, rg.config.model = { deep = "mine" }, "every"
  run("deep")
  run("explain")
  check("models, then model", vim.deep_equal(switches, { "big", "mine", "every" }), switches)
  rg.config.models, rg.config.model = {}, nil

  -- Without set_model the process restarts on the same session.
  rg.config.agent = "restart"
  run("explain")
  run("deep")
  check("restart resumes session", #spawns == 3 and spawns[3].model == "big" and spawns[3].session == "s-1", spawns)
  rg.close()

  -- A quick follow-up stays on the model of the question that started the thread.
  rg.config.agent = "live"
  vim.cmd("edit src/discount.lua")
  rg.action("deep", nil, { 1, 1 })
  local qbuf = vim.api.nvim_win_get_buf(H.floats()[1])
  H.wait_answers(qbuf, 1)
  vim.ui.input = function(_, cb)
    cb("why?")
  end
  vim.api.nvim_feedkeys("a", "x", false)
  H.wait_answers(qbuf, 2)
  check("follow-up keeps model", spawns[#spawns].model == "big" and #switches == 3, { spawns, switches })

  local req = vim.json.decode(rg.adapters.claude.set_model("opus"))
  check(
    "claude set_model request",
    req.type == "control_request" and req.request.subtype == "set_model" and req.request.model == "opus",
    req
  )
  check("claude deep on opus", rg.adapters.claude.models.deep == "opus")
end)
