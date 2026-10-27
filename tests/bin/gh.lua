-- Stands in for the GitHub CLI in github_spec.lua: logs each call and answers like the GraphQL API.
-- _G.arg also holds the script name at 0 and Neovim's own arguments below it, so copy only the list part.
local args = {}
for i = 1, #_G.arg do
  args[i] = _G.arg[i]
end
local log = assert(os.getenv("GH_FAKE_LOG"), "GH_FAKE_LOG is not set")
local pending = log .. ".pending"

local file = assert(io.open(log, "a"))
file:write(vim.json.encode(args), "\n")
file:close()

local function reply(data)
  io.write(vim.json.encode(data), "\n")
  os.exit(0)
end

local REVIEW_URL = "https://github.com/acme/demo/pull/7#pullrequestreview-1"

if args[1] == "pr" and args[2] == "view" then
  reply({ number = 7, url = "https://github.com/acme/demo/pull/7", headRefOid = os.getenv("GH_FAKE_HEAD") })
end

if args[1] == "api" and args[2] == "graphql" then
  local query = ""
  for _, a in ipairs(args) do
    if a:find("^query=") then
      query = a
    end
  end
  if query:find("reviews(states: PENDING", 1, true) then
    local nodes = { { id = "PRR_other", url = "x", author = { login = "other" } } }
    if vim.uv.fs_stat(pending) then
      nodes[#nodes + 1] = { id = "PRR_1", url = REVIEW_URL, author = { login = "me" } }
    end
    reply({
      data = { viewer = { login = "me" }, repository = { pullRequest = { id = "PR_7", reviews = { nodes = nodes } } } },
    })
  end
  if query:find("addPullRequestReviewThread", 1, true) then
    -- GH_FAKE_REFUSE_LINE stands for a line that is in the local diff but not in GitHub's.
    local refuse = os.getenv("GH_FAKE_REFUSE_LINE")
    for i = 1, #args - 1 do
      if refuse and args[i] == "-F" and args[i + 1] == "line=" .. refuse then
        io.stderr:write("gh: Line could not be resolved\n")
        os.exit(1)
      end
    end
    reply({ data = { addPullRequestReviewThread = { thread = { id = "T1" } } } })
  end
  if query:find("addPullRequestReview(", 1, true) then
    io.open(pending, "w"):close()
    reply({ data = { addPullRequestReview = { pullRequestReview = { id = "PRR_1", url = REVIEW_URL } } } })
  end
  if query:find("submitPullRequestReview", 1, true) then
    os.remove(pending)
    reply({ data = { submitPullRequestReview = { pullRequestReview = { url = REVIEW_URL } } } })
  end
end

io.stderr:write("fake gh: unhandled call " .. table.concat(args, " ") .. "\n")
os.exit(1)
