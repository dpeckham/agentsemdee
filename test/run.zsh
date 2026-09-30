#!/usr/bin/env zsh
# Tests for discovery rules, redaction, and preview safety.
#
# Every case builds a throwaway home and project under a temp directory and
# runs the real script against it with a scrubbed environment, so the results
# never depend on the configuration of the machine running the tests.

emulate -R zsh
setopt extendedglob pipefail

ROOT=${${(%):-%x}:A:h:h}
BIN=$ROOT/bin/agentsemdee
TMP=$(mktemp -d)
TMP=${TMP:A}
trap 'command rm -rf -- "$TMP"' EXIT

typeset -i PASS=0 FAIL=0
OUT=''

# Tool directories pinned by the project, resolved once with the real HOME.
typeset -a tooldirs
if (( $+commands[mise] )); then
  tooldirs=(${(f)"$(command mise -C $ROOT bin-paths 2>/dev/null)"})
  tooldirs=(${(M)tooldirs:#*/installs/(fzf|bat|jq)/*})
fi
TEST_PATH=${(j.:.)tooldirs}:${commands[git]:h}:/usr/bin:/bin

SYS=$TMP/sys
if [[ $OSTYPE == darwin* ]]; then
  CLAUDE_MANAGED="$SYS/Library/Application Support/ClaudeCode"
else
  CLAUDE_MANAGED=$SYS/etc/claude-code
fi

# mk FILE [CONTENT]: create a file and its parent directories.
mk() {
  command mkdir -p -- ${1:h}
  print -r -- "${2:-content}" > $1
}

# repo DIR: make DIR a git repository.
repo() {
  command mkdir -p -- $1
  command git -C $1 init -q
}

# run HOME DIR [VAR=VALUE...]: inspect DIR and keep the TSV in OUT.
run() {
  local h=$1 d=$2
  shift 2
  OUT=$(env -i PATH=$TEST_PATH HOME=$h AGENTSEMDEE_SYSROOT=$SYS AGENTSEMDEE_TOOLS_READY=1 \
    AGENTSEMDEE_CLAUDE_VERSION=2.1.285 AGENTSEMDEE_CODEX_VERSION=0.159.2 \
    AGENTSEMDEE_OPENCODE_VERSION=2.0.20 "$@" $BIN --tsv --all $d)
}

# field COLUMN PATH: print one TSV column for the row of PATH.
field() {
  print -r -- "$OUT" | command awk -F'\t' -v p="$2" -v c="$1" '$3 == p { print $c }'
}

# expect DESCRIPTION ACTUAL WANTED
expect() {
  if [[ $2 == $3 ]]; then
    (( PASS++ ))
  else
    (( FAIL++ ))
    print -r -- "FAIL: $1"
    print -r -- "      wanted: $3"
    print -r -- "      got:    $2"
  fi
}

# state DESCRIPTION AGENT PATH WANTED: check one agent's state for a file.
# WANTED "absent" means the file has no row at all.
state() {
  local col got
  case $2 in
    c) col=5 ;;
    x) col=7 ;;
    o) col=9 ;;
  esac
  got=$(field $col $3)
  expect "$1" "${got:-absent}" $4
}

V1=AGENTSEMDEE_OPENCODE_VERSION=1.4.0

# ---------------------------------------------------------------------------
# A plain home with nothing but a Claude user instruction file.
H=$TMP/home
mk $H/.claude/CLAUDE.md

# --- CLAUDE.md and AGENTS.md side by side -----------------------------------
P=$H/code/both
repo $P
mk $P/CLAUDE.md
mk $P/AGENTS.md
run $H $P
state 'claude loads CLAUDE.md'                  c $P/CLAUDE.md loaded
state 'claude skips AGENTS.md beside CLAUDE.md' c $P/AGENTS.md skipped
state 'codex loads AGENTS.md'                   x $P/AGENTS.md loaded
state 'codex does not read CLAUDE.md'           x $P/CLAUDE.md -
state 'opencode 2 loads AGENTS.md'              o $P/AGENTS.md loaded
state 'opencode 2 does not read CLAUDE.md'      o $P/CLAUDE.md -
expect 'AGENTS.md is project scope' "$(field 1 $P/AGENTS.md)" project
expect 'AGENTS.md is an instruction file' "$(field 2 $P/AGENTS.md)" instructions
run $H $P $V1
state 'opencode 1 loads AGENTS.md'                  o $P/AGENTS.md loaded
state 'opencode 1 skips CLAUDE.md beside AGENTS.md' o $P/CLAUDE.md skipped

# --- AGENTS.md only ---------------------------------------------------------
P=$H/code/agents-only
repo $P
mk $P/AGENTS.md
run $H $P
state 'claude loads a lone AGENTS.md' c $P/AGENTS.md loaded
run $H $P AGENTSEMDEE_CLAUDE_VERSION=2.1.200
state 'claude before 2.1.277 skips AGENTS.md' c $P/AGENTS.md skipped

# --- CLAUDE.md only, OpenCode fallback --------------------------------------
P=$H/code/claude-only
repo $P
mk $P/CLAUDE.md
run $H $P $V1
state 'opencode 1 falls back to project CLAUDE.md' o $P/CLAUDE.md loaded
state 'opencode 1 falls back to user CLAUDE.md'    o $H/.claude/CLAUDE.md loaded
run $H $P $V1 OPENCODE_DISABLE_CLAUDE_CODE=1
state 'opencode 1 honors the compatibility switch' o $P/CLAUDE.md skipped
run $H $P
state 'opencode 2 ignores user CLAUDE.md' o $H/.claude/CLAUDE.md -

# --- CLAUDE.md that imports AGENTS.md ---------------------------------------
P=$H/code/import
repo $P
mk $P/CLAUDE.md $'@AGENTS.md\n\n## Claude only\n'
mk $P/AGENTS.md
run $H $P
state 'claude loads an imported AGENTS.md' c $P/AGENTS.md loaded

# --- CLAUDE.md symlinked to AGENTS.md ---------------------------------------
P=$H/code/symlink
repo $P
mk $P/AGENTS.md
command ln -s AGENTS.md $P/CLAUDE.md
run $H $P
state 'claude reads AGENTS.md through a symlink' c $P/AGENTS.md loaded

# --- Project instructions set to load both ----------------------------------
H2=$TMP/home-both
mk $H2/.claude/settings.json '{"pluginConfigs":{"agents-md@builtin":{"options":{"instructionFiles":"claude-md-and-agents-md"}}}}'
P=$H2/code/both
repo $P
mk $P/CLAUDE.md
mk $P/AGENTS.md
run $H2 $P
state 'claude loads both when the setting says so' c $P/AGENTS.md loaded

# --- Working in a subdirectory of a monorepo --------------------------------
R=$H/code/mono
A=$R/packages/app
repo $R
mk $R/CLAUDE.md
mk $R/AGENTS.md
mk $R/.claude/settings.json '{}'
mk $R/.mcp.json '{"mcpServers":{}}'
mk $R/.claude/skills/alpha/SKILL.md $'---\ndescription: First skill\n---\n'
mk $R/.claude/skills/beta/SKILL.md $'---\ndescription: Second skill\n---\n'
mk $A/.claude/settings.json '{"claudeMdExcludes":["**/mono/CLAUDE.md"]}'
mk $A/AGENTS.md
mk $A/AGENTS.override.md
mk $A/CLAUDE.local.md
run $H $A
state 'claude skips shared settings above the start directory' c $R/.claude/settings.json skipped
state 'claude loads shared settings in the start directory'    c $A/.claude/settings.json loaded
state 'claude keeps local settings at the repository root'     c $R/.claude/settings.local.json missing
expect 'local settings are local scope' "$(field 1 $R/.claude/settings.local.json)" local
expect 'CLAUDE.local.md is local scope' "$(field 1 $A/CLAUDE.local.md)" local
state 'claude honors claudeMdExcludes'            c $R/CLAUDE.md skipped
state 'claude reads .mcp.json from a parent'      c $R/.mcp.json loaded
state 'claude reads skills from the repo root'    c $R/.claude/skills loaded
state 'opencode 2 reads claude skills'            o $R/.claude/skills loaded
state 'codex loads the root AGENTS.md'            x $R/AGENTS.md loaded
state 'codex prefers AGENTS.override.md'          x $A/AGENTS.override.md loaded
state 'codex skips AGENTS.md beside an override'  x $A/AGENTS.md skipped
state 'opencode 2 loads every AGENTS.md on the path' o $R/AGENTS.md loaded
state 'opencode 2 loads the nearest AGENTS.md'       o $A/AGENTS.md loaded
plain=$(env -i PATH=$TEST_PATH HOME=$H AGENTSEMDEE_SYSROOT=$SYS AGENTSEMDEE_TOOLS_READY=1 \
  AGENTSEMDEE_CLAUDE_VERSION=2.1.285 AGENTSEMDEE_CODEX_VERSION=0.159.2 \
  AGENTSEMDEE_OPENCODE_VERSION=2.0.20 $BIN --plain $A)
expect 'skills folders show a count' \
  "$(print -r -- "$plain" | command grep -c -F '../../.claude/skills/  2 skills')" 1
expect 'plain output has no color when piped' "${plain//[^$'\e']/}" ''
expect 'rows are hidden without --all' "${(M)${(f)plain}:#*settings.local.json*}" ''

# --- One row per skill ------------------------------------------------------
S=$R/.claude/skills/alpha/SKILL.md
state 'each skill gets its own row'            c $S loaded
state 'a skill inherits its folder state'      o $S loaded
state 'a skill is blank for agents that skip the folder' x $S -
expect 'skill rows have their own kind' "$(field 2 $S)" skill
expect 'skill rows share the folder scope' "$(field 1 $S)" project
expect 'skill rows sit under their folder' \
  "$(print -r -- "$plain" | command grep -A1 -F '../../.claude/skills/' | command tail -n 1 | command sed 's/^[^a-z]*//')" 'alpha  skill'

# --- Skills that share a name -----------------------------------------------
H8=$TMP/home-skills
mk $H8/.claude/skills/alpha/SKILL.md
mk $H8/.claude/skills/synced/account/docx/SKILL.md
mk $H8/.claude/skills/.trash/old/SKILL.md
P8=$H8/code/p
repo $P8
mk $P8/.claude/skills/alpha/SKILL.md
mk $P8/.claude/skills/beta/SKILL.md
run $H8 $P8
state 'claude lets a personal skill shadow a project skill' c $P8/.claude/skills/alpha/SKILL.md skipped
state 'opencode still loads the shadowed skill'            o $P8/.claude/skills/alpha/SKILL.md loaded
state 'claude loads a project skill with a unique name'    c $P8/.claude/skills/beta/SKILL.md loaded
state 'claude loads the personal skill'                    c $H8/.claude/skills/alpha/SKILL.md loaded
state 'claude lists synced skills'                         c $H8/.claude/skills/synced/account/docx/SKILL.md loaded
state 'trashed skills are left out'                        c $H8/.claude/skills/.trash/old/SKILL.md absent
mk $CLAUDE_MANAGED/.claude/skills/alpha/SKILL.md
run $H8 $P8
state 'claude lets an organization skill shadow a personal one' c $H8/.claude/skills/alpha/SKILL.md skipped
state 'claude loads the organization skill' c $CLAUDE_MANAGED/.claude/skills/alpha/SKILL.md loaded
command rm -rf -- $SYS

# --- Codex project trust ----------------------------------------------------
P=$H/code/trust
repo $P
mk $P/.codex/config.toml 'model = "x"'
run $H $P
state 'codex skips project config until trusted' x $P/.codex/config.toml skipped
H3=$TMP/home-trust
P3=$H3/code/trust
repo $P3
mk $P3/.codex/config.toml 'model = "x"'
mk $H3/.codex/config.toml "model = \"y\"

[mcp_servers.docs]
command = \"npx\"

[projects.\"$P3\"]
trust_level = \"trusted\"
"
run $H3 $P3
state 'codex loads project config once trusted' x $P3/.codex/config.toml loaded
expect 'codex counts MCP servers' "${(M)$(field 8 $H3/.codex/config.toml):#*1 MCP server.*}" \
  "$(field 8 $H3/.codex/config.toml)"

# --- Codex instruction size budget ------------------------------------------
H4=$TMP/home-cap
mk $H4/.codex/config.toml 'project_doc_max_bytes = 100'
R4=$H4/code/cap
repo $R4
mk $R4/AGENTS.md "${(l:150::x:):-}"
mk $R4/sub/AGENTS.md
run $H4 $R4/sub
state 'codex loads the file that crosses the budget' x $R4/AGENTS.md loaded
state 'codex skips files past the budget'            x $R4/sub/AGENTS.md skipped

# --- Codex global override --------------------------------------------------
H5=$TMP/home-override
mk $H5/.codex/AGENTS.md
mk $H5/.codex/AGENTS.override.md
P5=$H5/code/p
repo $P5
run $H5 $P5
state 'codex loads the global override'         x $H5/.codex/AGENTS.override.md loaded
state 'codex skips the global file beside it'   x $H5/.codex/AGENTS.md skipped

# --- OpenCode global instruction precedence ---------------------------------
H6=$TMP/home-opencode
mk $H6/.claude/CLAUDE.md
mk $H6/.config/opencode/AGENTS.md
P6=$H6/code/p
repo $P6
run $H6 $P6 $V1
state 'opencode 1 prefers its own global file' o $H6/.config/opencode/AGENTS.md loaded
state 'opencode 1 then skips user CLAUDE.md'   o $H6/.claude/CLAUDE.md skipped

# --- Instruction files above the project ------------------------------------
H7=$TMP/home-above
mk $H7/AGENTS.md
P7=$H7/code/p
repo $P7
run $H7 $P7
state 'opencode 2 walks up to the home directory' o $H7/AGENTS.md loaded
state 'claude walks up past the repository'       c $H7/AGENTS.md loaded
state 'codex stops at the repository root'        x $H7/AGENTS.md -
expect 'files above the repository get their own scope' "$(field 1 $H7/AGENTS.md)" above
run $H7 $P7 $V1
state 'opencode 1 stops at the worktree root' o $H7/AGENTS.md -

# --- Managed files ----------------------------------------------------------
mk $CLAUDE_MANAGED/managed-settings.json '{}'
mk $CLAUDE_MANAGED/CLAUDE.md
mk $SYS/etc/codex/requirements.toml 'x = 1'
run $H $H/code/both
state 'claude loads managed settings'     c $CLAUDE_MANAGED/managed-settings.json loaded
state 'claude loads managed instructions' c $CLAUDE_MANAGED/CLAUDE.md loaded
state 'codex loads admin requirements'    x $SYS/etc/codex/requirements.toml loaded
expect 'managed files are managed scope' "$(field 1 $CLAUDE_MANAGED/CLAUDE.md)" managed
command rm -rf -- $SYS

# --- Linked git worktree ----------------------------------------------------
M=$H/code/main
repo $M
mk $M/README.md
command git -C $M add README.md
command git -C $M -c user.name=t -c user.email=t@example.com commit -q -m init
W=$H/code/linked
command git -C $M worktree add -q $W -b linked 2>/dev/null
run $H $W
state 'claude keeps local settings in the main checkout' c $M/.claude/settings.local.json missing

# --- Outside a git repository -----------------------------------------------
P=$H/plain/dir
mk $P/AGENTS.md
mk $H/plain/AGENTS.md
run $H $P
state 'codex reads only the working directory outside a repo' x $H/plain/AGENTS.md -
state 'codex still reads the working directory'               x $P/AGENTS.md loaded
state 'claude walks up outside a repo'                        c $H/plain/AGENTS.md loaded

# --- Empty slots ------------------------------------------------------------
OUT=$(env -i PATH=$TEST_PATH HOME=$H AGENTSEMDEE_SYSROOT=$SYS AGENTSEMDEE_TOOLS_READY=1 \
  AGENTSEMDEE_CLAUDE_VERSION=2.1.285 AGENTSEMDEE_CODEX_VERSION=0.159.2 \
  AGENTSEMDEE_OPENCODE_VERSION=2.0.20 $BIN --tsv $H/code/both)
expect 'missing files are left out by default' \
  "$(print -r -- "$OUT" | command awk -F'\t' 'NR > 1 && $4 == 0' | command wc -l | command tr -d ' ')" 0

# ---------------------------------------------------------------------------
# Redaction and preview safety.
source $ROOT/lib/core.zsh
source $ROOT/lib/redact.zsh
source $ROOT/lib/render.zsh
source $ROOT/lib/preview.zsh

# Token-shaped samples are assembled here instead of written out, so the
# repository never contains a string that a secret scanner would flag.
FAKE_SK=sk-ant-${(l:24::A:):-}
FAKE_GH=ghp_${(l:30::Z:):-}

typeset -a SECRETS=(
  $FAKE_SK hunter2 SUPERSECRETVALUE abc123secret
  ZZZsecretZZZ $FAKE_GH realbearervalue DEEPSECRET
  p4ssw0rd plain-token-value toml-secret-key tok-secret inline-secret
  single-secret table-secret hdr-secret
)
JSON_SAMPLE='{
  "apiKeyHelper": "/usr/local/bin/get-key",
  "env": {
    "ANTHROPIC_API_KEY": "@SK@",
    "DATABASE_URL": "postgres://admin:hunter2@db.internal:5432/app",
    "PLAIN": "SUPERSECRETVALUE",
    "REF": "${MY_TOKEN}"
  },
  "mcpServers": {
    "gh": {
      "args": ["-y", "server", "--token=abc123secret", "--api-key", "ZZZsecretZZZ"],
      "env": { "GITHUB_TOKEN": "@GH@" },
      "headers": {
        "Authorization": "Bearer realbearervalue",
        "X-Nested": { "deep": "DEEPSECRET" }
      },
      "url": "https://user:p4ssw0rd@example.com/mcp"
    }
  },
  "githubToken": "plain-token-value",
  "after": "visible-after-block"
}'
JSON_SAMPLE=${JSON_SAMPLE//@SK@/$FAKE_SK}
JSON_SAMPLE=${JSON_SAMPLE//@GH@/$FAKE_GH}
TOML_SAMPLE='api_key = "toml-secret-key"
bearer_token_env_var = "MY_ENV_NAME"
[mcp_servers.docs]
args = ["-y", "thing", "--token=tok-secret"]
env = { API_KEY = "inline-secret", OTHER = '\''single-secret'\'' }

[mcp_servers.docs.env]
FOO = "table-secret"
[mcp_servers.web]
http_headers = { "X-Api" = "hdr-secret" }
visible = "visible-after-table"'

masked_json=$(print -r -- "$JSON_SAMPLE" | amd_redact json)
masked_toml=$(print -r -- "$TOML_SAMPLE" | amd_redact toml)
leaks=''
for s in $SECRETS; do
  [[ $masked_json == *$s* || $masked_toml == *$s* ]] && leaks+=" $s"
done
expect 'no secret survives redaction' "$leaks" ''
expect 'env references stay readable'   "${(M)masked_json:#*'${MY_TOKEN}'*}" "$masked_json"
expect 'pointer keys stay readable'     "${(M)masked_json:#*/usr/local/bin/get-key*}" "$masked_json"
expect 'masking stops after the block'  "${(M)masked_json:#*visible-after-block*}" "$masked_json"
expect 'env var names stay readable'    "${(M)masked_toml:#*MY_ENV_NAME*}" "$masked_toml"
expect 'masking stops after the table'  "${(M)masked_toml:#*visible-after-table*}" "$masked_toml"

expect 'control characters are stripped' \
  "$(print -rn -- $'safe\e]0;owned\a\e[31mtext' | _amd_sanitize)" 'safe]0;owned[31mtext'

# The preview of a settings file, end to end, through the real script.
P=$H/code/secrets
repo $P
mk $P/.mcp.json "$JSON_SAMPLE"
mk $P/AGENTS.md $'# Title\n\e]0;owned\a\nbody text'
typeset -a penv=(PATH=$TEST_PATH HOME=$H AGENTSEMDEE_SYSROOT=$SYS AGENTSEMDEE_TOOLS_READY=1
  AGENTSEMDEE_CLAUDE_VERSION=2.1.285 AGENTSEMDEE_CODEX_VERSION=0.159.2
  AGENTSEMDEE_OPENCODE_VERSION=2.0.20 AGENTSEMDEE_DIR=$P)
rows=$(env -i $penv $BIN --rows)
row=${(M)${(f)rows}:#*$'\t'$P/.mcp.json$'\t'*}
shown=$(env -i $penv $BIN --preview "$row")
leaks=''
for s in $SECRETS; do
  [[ $shown == *$s* ]] && leaks+=" $s"
done
expect 'the preview pane masks secrets' "$leaks" ''
expect 'the preview pane explains the state' "${(M)shown:#*Project-scoped*}" "$shown"
row=${(M)${(f)rows}:#*$'\t'$P/AGENTS.md$'\t'*}
shown=$(env -i $penv $BIN --preview "$row")
expect 'the preview pane shows instruction text' "${(M)shown:#*body text*}" "$shown"
expect 'the preview pane drops escape sequences from files' "${(M)shown:#*$'\e]0;'*}" ''
mk $P/.claude/skills/deploy/SKILL.md $'---\ndescription: Ship it\n---\nskill body text'
rows=$(env -i $penv $BIN --rows)
row=${(M)${(f)rows}:#*$'\t'$P/.claude/skills/deploy/SKILL.md$'\t'*}
shown=$(env -i $penv $BIN --preview "$row")
expect 'the preview pane shows a skill file' "${(M)shown:#*skill body text*}" "$shown"

# Settings globs are matched literally apart from * and ?.
source $ROOT/lib/agent-claude.zsh
_amd_glob_match /a/mono/CLAUDE.md '**/mono/CLAUDE.md'; expect 'glob star matches' $? 0
_amd_glob_match /a/b/CLAUDE.md '/a/[b]/CLAUDE.md';     expect 'brackets are literal' $? 1
_amd_glob_match /a/b/CLAUDE.md '/a/(b|c)/CLAUDE.md';   expect 'groups are literal' $? 1

print -r -- "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
