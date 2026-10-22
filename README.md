# agentic-review.nvim

Code review in Neovim with a headless coding agent next to the diff.

Open a branch or a GitHub pull request in a review tab: the changed files in a suggested reading order, a side-by-side diff, and a pane where the agent explains, explores or digs into the hunk under the cursor. Outside a review, the same actions answer in a float under the code you select. Comments you write go to your pending GitHub review, which nobody sees until you submit it.

The agent runs read-only. The plugin drives [Claude Code](https://github.com/anthropics/claude-code) or [pi](https://github.com/earendil-works/pi) out of the box, and any other headless CLI through a small adapter in your config.

## Requirements

- Neovim 0.10 or newer
- git
- An agent CLI: `claude` (Claude Code) or `pi`, logged in, or your own adapter
- The [GitHub CLI](https://cli.github.com) `gh`, logged in, for pull requests and comments
- Optional: a Markdown renderer such as [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) for the agent's answers

Run `:checkhealth agentic_review` to see what is missing.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "AlucarDWeb/agentic-review.nvim",
  cmd = { "Review", "ReviewClose", "ReviewCancel", "ReviewRefs", "ReviewAsk", "ReviewComment", "ReviewSubmit" },
  keys = {
    { "<leader>R", "", desc = "+review" },
    { "<leader>Rr", "<cmd>Review<cr>", desc = "Review branch vs base" },
    {
      "<leader>RP",
      function()
        vim.ui.input({ prompt = "PR number: " }, function(n)
          if n and n ~= "" then
            require("agentic_review").open(n)
          end
        end)
      end,
      desc = "Review a PR",
    },
    { "<leader>Re", function() require("agentic_review").action("explain") end, mode = { "n", "x" }, desc = "Explain" },
    { "<leader>Rx", function() require("agentic_review").action("explore") end, mode = { "n", "x" }, desc = "Explore around" },
    { "<leader>Rd", function() require("agentic_review").action("deep") end, mode = { "n", "x" }, desc = "Deep dive" },
    { "<leader>Ra", function() require("agentic_review").action("ask") end, mode = { "n", "x" }, desc = "Ask" },
    { "<leader>Rf", function() require("agentic_review").answer() end, desc = "Show last answer" },
    { "<leader>Rg", function() require("agentic_review").comment() end, mode = { "n", "x" }, desc = "Comment on GitHub" },
    { "<leader>RS", "<cmd>ReviewSubmit<cr>", desc = "Submit GitHub review" },
    { "<leader>Rn", function() require("agentic_review").next(1) end, desc = "Next file" },
    { "<leader>RN", function() require("agentic_review").next(-1) end, desc = "Previous file" },
    { "<leader>Rv", function() require("agentic_review").toggle_viewed() end, desc = "Mark viewed, go to next" },
    { "<leader>Rl", "<cmd>ReviewRefs<cr>", desc = "Answer refs to quickfix" },
    { "<leader>Rc", "<cmd>ReviewCancel<cr>", desc = "Cancel agent answer" },
    { "<leader>Rq", "<cmd>ReviewClose<cr>", desc = "Close review" },
  },
  opts = {},
}
```

The plugin sets no global keymaps; the table above is a suggestion. Without lazy.nvim, call `require("agentic_review").setup({})` once.

## Reviewing a branch or a pull request

| Command | What it reviews |
| --- | --- |
| `:Review` | The current branch against its merge-base with `origin/HEAD` (falling back to `origin/main`, `origin/master`, `main`, `master`), uncommitted changes included |
| `:Review <ref>` | The same, against another base: `:Review origin/develop`, or `:Review HEAD` for uncommitted changes only |
| `:Review #123` | A pull request, through `gh`. It is fetched, not checked out, so the head side shows read-only revisions. If the PR is already checked out, the head side is your working tree and LSP works there |
| `:Review!` | Any of the above, ignoring the saved session |

The review opens in its own tab, from left to right: the changed files, the base and head versions in Neovim's diff mode, and the agent pane. On open the agent writes a short overview and reorders the files into a suggested reading order (`auto_tour`).

- Files panel: `<CR>` opens a file, `v` toggles viewed, `t` runs the tour again, `q` closes the review
- Diff: `]c` and `[c` move between hunks
- Agent pane: `<CR>` or `gf` jumps to the `path:line` under the cursor

The agent's session, the file order, viewed marks and the pane transcript are saved under `stdpath("state")`. Running the same `:Review` again resumes the session and skips the tour. Untracked files do not appear, because `git diff` ignores them; `git add -N <file>` makes them show up.

## Asking the agent

| Function | Prompt |
| --- | --- |
| `action("explain")` | What the code does and why it is written that way |
| `action("explore")` | Callers, dependencies and related code, with `path:line` references |
| `action("deep")` | Correctness bugs, edge cases, lifecycle and concurrency problems, missing tests, each checked against the code |
| `action("ask")` | Your own question (`:ReviewAsk [question]` takes a range) |

In normal mode an action uses the hunk under the cursor, in visual mode the selection, and in the files panel the whole file. In the review tab the answer streams into the agent pane, which keeps the review conversation.

Outside the review tab, in any buffer, the answer opens in a float under the selected code (or the cursor line plus 5 lines each side). It opens above the code near the bottom of the window and grows with the answer up to `float_height`. Each repository has its own session, so follow-ups remember earlier questions.

| Key in the float | Effect |
| --- | --- |
| `a` | Ask a follow-up |
| `<CR>`, `gf` | Jump to the `path:line` under the cursor |
| `s` | Move the answer to a right split; later answers stream there until you close it |
| `<C-c>` | Cancel the running answer |
| `q`, `<Esc>` | Close |

`require("agentic_review").answer()` reopens the last answer, and `:ReviewRefs` sends every `path:line` in it to the quickfix list.

## Commenting on GitHub

On a line or selection in the diff, `:ReviewComment` (or `require("agentic_review").comment()`) opens a float for the comment. `:w`, `:wq` or `<C-s>` adds it to your pending review on the pull request, `gs` inserts a `suggestion` block with the selected lines, and `q` cancels. `:ReviewSubmit` submits the review as Comment, Approve or Request changes.

Only a write command typed in the float sends the comment, so autosave setups that run `:wall` on `InsertLeave` or `TextChanged` do not post drafts. Before anything is sent, the plugin refuses:

- lines outside a hunk, which GitHub does not accept
- a local `HEAD` that differs from the PR head
- head side comments on a file with unpushed or unsaved changes

In each of these cases the line numbers would not match GitHub. For a branch review, the PR is the one `gh pr view` finds for the branch.

## Agents

`claude` runs `claude -p` with stream-json input and output as one process per conversation. Its tools are limited to `Read`, `Grep`, `Glob` and single `git diff`, `show`, `log`, `blame` and `grep` commands, with `--permission-mode dontAsk` and `--strict-mcp-config`. Your Claude Code hooks and `CLAUDE.md` files still apply.

`pi` runs `pi --mode rpc` with `read`, `grep`, `find` and `ls`, and without extensions, skills or MCP. pi cannot limit `bash` to git commands, so it gets no shell, and each message includes the diff it needs.

`model` is passed to the agent's `--model` flag.

### Custom adapters

An adapter is a table in `adapters`, picked by name with `agent`:

| Field | Meaning |
| --- | --- |
| `cmd(ctx)` | Returns the argv, and optionally a session id. `ctx` has `system`, `prompt`, `session`, `root`, `label` and `model` |
| `persistent` | When true, the process starts once and each prompt is written to its stdin with `encode(prompt)` |
| `parse(line, emit)` | Turns one stdout line into `emit.text(s)`, `emit.tool(name, input)`, `emit.session(id)` and `emit.done(err)` |
| `shell` | Whether the agent can run git; the system prompt changes accordingly |

Without `parse`, stdout streams into the answer as plain text and the end of the process ends the answer. A minimal one-shot adapter:

```lua
opts = {
  agent = "mycli",
  adapters = {
    mycli = {
      cmd = function(ctx)
        return { "mycli", "--print", ctx.system .. "\n\n" .. ctx.prompt }
      end,
    },
  },
}
```

That adapter starts from scratch on every question. A `persistent` one with `parse`, or a `cmd` that resumes `ctx.session`, keeps the conversation. The built-in adapters in `lua/agentic_review/init.lua` are complete examples.

## Configuration

Defaults:

```lua
{
  agent = "claude", -- adapter name, or an adapter table
  adapters = {},
  model = nil,
  files_width = 34, -- files panel, in columns
  agent_width = 0.33, -- agent pane and the quick split, as a fraction of the screen
  float_width = 100,
  float_height = 15,
  auto_tour = true, -- overview and reading order when a review opens
  max_context_lines = 300, -- longest hunk or selection sent with an action
  max_tour_lines = 1500, -- diff sent with the tour to agents without a shell
}
```

## Development

```sh
tests/run.sh                  # every spec, each in its own headless Neovim
tests/run.sh github_spec.lua  # one spec
stylua --check lua tests
```

The specs build a throwaway git repository and use fake agents and a fake `gh`, so they need neither network access nor accounts.

## License

MIT
