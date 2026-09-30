# agentsemdee

A terminal viewer for the agent configuration that applies to a directory.

Coding agents read instructions, settings, MCP servers, and skills from many
places: admin-installed files, your home directory, folders above the
project, the repository, and personal files inside it. Each agent has its own
rules for which of those it loads. agentsemdee lists every location for
Claude Code, Codex, and OpenCode in one table and says, per agent, whether
the file is loaded and why.

It is read-only. It never writes to any configuration file.

```
 C X O
 ── Managed ─────────────────────────────────────
        none
 ── User global ─────────────────────────────────
 ●      ~/.claude/CLAUDE.md  instructions
 ── Project shared (team) ───────────────────────
 ●      ../../CLAUDE.md  instructions
 ○ ● ●  ../../AGENTS.md  instructions
 ○      ../../.claude/settings.json  settings
   ○    ../../.codex/config.toml  settings
 ●      ../../.mcp.json  mcp
 ●   ●  ../../.claude/skills/  2 skills
 ○   ●    deploy  skill
 ●   ●    review  skill
 ○ ○ ●  ./AGENTS.md  instructions
   ●    ./AGENTS.override.md  instructions
 ●      ./.claude/settings.json  settings
 ── Project local (you) ─────────────────────────
 ●      ./CLAUDE.local.md  instructions
```

## Install

Tools are managed with [mise](https://mise.jdx.dev). zsh and git come from
the system.

```sh
mise install
ln -s "$PWD/bin/agentsemdee" ~/.local/bin/agentsemdee   # optional
```

The script puts the fzf, bat, and jq versions pinned in `mise.toml` on its
own PATH, so it behaves the same from any directory.

## Use

```sh
agentsemdee              # open the viewer for the current directory
agentsemdee path/to/dir  # inspect another directory
agentsemdee --all        # include locations that do not exist yet
agentsemdee --plain      # print the table
agentsemdee --tsv        # one line per file with reasons, for scripts
```

When output is not a terminal, the table is printed instead of the viewer.

Viewer keys:

| Key | Action |
| --- | --- |
| type | filter rows by path |
| up, down | move |
| enter | open the file in `$VISUAL` or `$EDITOR`, or a pager if neither is set |
| ctrl-a | show or hide empty slots |
| pgup, pgdn | scroll the preview |
| esc | quit |

## Reading the table

The columns are C for Claude Code, X for Codex, and O for OpenCode.

| Mark | Meaning |
| --- | --- |
| `●` | the agent loads this file |
| `○` | the file exists, but this agent does not load it; the preview says why |
| `·` | the agent would read this location if the file existed |
| blank | the agent never reads this location |

Rows run from the broadest scope to the most specific, so lower rows win.
Managed policy is the exception: it cannot be overridden.

| Scope | What is in it |
| --- | --- |
| Managed | files an administrator installs for everyone on the machine |
| User global | your own files, applied in every project |
| Above the project | folders above the repository that some agents still read |
| Project shared (team) | files meant to be committed, from the repository root down |
| Project local (you) | your personal files for this project, meant to stay out of git |

The preview pane shows the selected file with a header: its scope, size, git
state, and one line per agent with the reason for its mark.

Each skills folder is followed by one indented row per skill. Selecting one
shows its `SKILL.md`. A skill starts with the mark of its folder. Claude Code
then marks a skill as not loaded when a skill with the same name exists at a
higher level: organization skills win over personal ones, and personal ones
win over project ones. Skills kept in a subfolder, such as the ones Claude
Code syncs or Codex bundles, show that subfolder as their note.

## What it covers

Four kinds of configuration: instruction files, settings files, MCP server
config, and skills folders.

Not covered yet: hooks, subagents, commands, agent memory, plugins, and
anything set per session through flags, environment variables, or profiles.
Remote sources are not files and do not appear: Claude Code server-managed
settings, Codex cloud-managed defaults, and OpenCode remote config. Files
that load only when an agent touches a subdirectory are not listed either,
nor are extra files named by the OpenCode `instructions` key.

## Where the rules come from

Each agent module in `lib/` encodes that agent's discovery rules and cites
its sources. The rules change between releases, so the detected version of
each agent selects the rule set and appears in the viewer.

| Agent | Checked against | Source |
| --- | --- | --- |
| Claude Code | 2.1.285 | code.claude.com/docs, and the installed binary for `.mcp.json` lookup |
| Codex | 0.159.2 | the Codex docs, and path constants in the installed binary |
| OpenCode 1.x | docs only | opencode.ai/docs and the 1.x instruction loader source |
| OpenCode 2.x | 2.0.20 | discovery code in the installed binary |

OpenCode changed its rules in 2.x. Version 1.x falls back to `CLAUDE.md`
when no `AGENTS.md` exists. Version 2.x reads only `AGENTS.md`, and walks up
to the home directory instead of stopping at the repository root.

## Safety

The viewer is often on screen during calls and recordings, and it is run in
repositories that have not been reviewed. Three measures follow from that.

- Secret values in settings and MCP files are masked before display: values
  under `env` and `headers`, values of keys such as `token` or `api_key`,
  credentials inside URLs, and common token formats. Masking is line based
  and best effort. Opening the file with enter shows the real content.
- `~/.claude.json` is never shown whole. Only its MCP server entries appear.
- Terminal control characters are stripped from file content before it is
  printed, so a file cannot drive the terminal.

## Layout

```
bin/agentsemdee         entry point and argument handling
lib/core.zsh            directory context and the report protocol
lib/agent-claude.zsh    Claude Code rules
lib/agent-codex.zsh     Codex rules
lib/agent-opencode.zsh  OpenCode rules, 1.x and 2.x
lib/render.zsh          rows, plain table, TSV
lib/preview.zsh         preview pane
lib/redact.zsh          secret masking
lib/ui.zsh              the fzf viewer
test/run.zsh            tests
```

An agent module calls `amd_report` once per location it knows about, with a
state and a one-sentence reason. The core merges reports by path, so a file
that several agents read becomes one row. Adding an agent means adding a
module, a column letter in `lib/core.zsh`, and tests.

## Test

```sh
mise run test
```

The tests build throwaway homes and repositories under a temp directory and
run the real script against them with a scrubbed environment.
