local M = {}

function M.check()
  local health = vim.health
  health.start("agentic-review")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10 or newer is required")
  end

  if vim.fn.executable("git") == 1 then
    health.ok("git found")
  else
    health.error("git not found: every review needs it")
  end

  if vim.fn.executable("gh") == 0 then
    health.warn("gh not found: `:Review #<number>` and GitHub comments need the GitHub CLI")
  elseif vim.system({ "gh", "auth", "status" }, { text = true }):wait().code ~= 0 then
    health.warn("gh is not logged in: run `gh auth login`")
  else
    health.ok("gh found and logged in")
  end

  local rg = require("agentic_review")
  local name, a, installed = rg._agent()
  local agent = rg.config.agent
  if type(agent) == "table" and vim.islist(agent) then
    health.info(("Agents in order: %s. Using %q"):format(table.concat(agent, ", "), tostring(name)))
  end
  if not a then
    health.error(("Agent %q has no adapter"):format(tostring(name)))
  elseif not (a.bin or a.available) then
    health.info(("Agent %q is a custom adapter, so its executable is not checked"):format(name))
  elseif installed then
    health.ok(("Agent %q: %s found"):format(name, a.bin or name))
  else
    health.error(("Agent %q: %s not found on PATH, or one of its extensions is missing"):format(name, a.bin or name))
  end
  if rg.config.interactive and a and not a.interactive then
    health.warn(("Agent %q has no interactive interface, so the agent pane stays headless"):format(name))
  end

  local ok, image = pcall(function()
    return rawget(_G, "Snacks") and Snacks.image
  end)
  if not require("agentic_review").config.images then
    health.info("Image previews are off (`images = false`)")
  elseif not (ok and image and image.supports_terminal) then
    health.info("Image previews need snacks.nvim with `image.enabled`; changed images show their size instead")
  elseif image.supports_terminal() then
    health.ok("Image previews: snacks.nvim found and the terminal speaks the kitty graphics protocol")
  else
    health.warn(
      "Image previews: this terminal does not report kitty graphics support to snacks.nvim. Inside a multiplexer "
        .. "that forwards it, set SNACKS_GHOSTTY=1 or SNACKS_KITTY=1"
    )
  end
end

return M
