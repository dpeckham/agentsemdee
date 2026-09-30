# core.zsh: shared state, directory context, and the report protocol.
#
# Each agent module calls amd_report once per file it knows about. The core
# merges those reports by path, so a file that several agents read becomes one
# row with one state per agent.

typeset -ga AMD_AGENTS=(c x o)
typeset -gA AMD_AGENT_NAME=(c 'Claude Code' x 'Codex' o 'OpenCode')
typeset -gA AMD_AGENT_CMD=(c claude x codex o opencode)
typeset -gA AMD_AGENT_SHORT=(c Claude x Codex o OpenCode)
typeset -ga AMD_SCOPES=(managed user above project local)
typeset -gA AMD_SCOPE_TITLE=(
  managed 'Managed'
  user    'User global'
  above   'Above the project'
  project 'Project shared (team)'
  local   'Project local (you)'
)
typeset -gA AMD_KIND_RANK=(instructions 1 settings 2 mcp 3 skills 4)

typeset -ga AMD_ORDER                 # paths, in first-report order
typeset -gA AMD_SCOPE AMD_KIND AMD_EXISTS
typeset -gA AMD_STATE AMD_REASON      # keyed "<agent>:<path>"
typeset -gA AMD_VER                   # agent letter -> installed version, or ''

# Rows nested under another row: one per skill inside a skills folder.
# They live in the tables above but not in AMD_ORDER, so they always follow
# their folder. AMD_CHILDREN maps a folder to its NUL-separated children.
typeset -gA AMD_CHILDREN AMD_LABEL AMD_NOTE

# Directory that holds admin-installed files. Tests point this at a fixture.
typeset -g AMD_SYSROOT=${AGENTSEMDEE_SYSROOT:-}

# git, with repository-supplied hooks into command execution switched off.
# This tool runs in directories the user has not necessarily vetted.
amd_git() {
  command git -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
}

# amd_init_context DIR
# Resolve the directory being inspected and the project it belongs to.
amd_init_context() {
  emulate -L zsh
  local dir=${1:-$PWD}
  if [[ ! -d $dir ]]; then
    print -u2 -r -- "agentsemdee: not a directory: $dir"
    return 1
  fi
  typeset -g AMD_CWD=${dir:A}
  typeset -g AMD_HOME=${HOME:A}
  if [[ $AMD_CWD == *[$'\t\n']* || $AMD_HOME == *[$'\t\n']* ]]; then
    print -u2 -r -- "agentsemdee: paths containing tabs or newlines are not supported"
    return 1
  fi

  typeset -g AMD_GIT_ROOT='' AMD_MAIN_ROOT=''
  local top common
  if (( $+commands[git] )); then
    top=$(amd_git -C $AMD_CWD rev-parse --show-toplevel 2>/dev/null)
    if [[ -n $top ]]; then
      AMD_GIT_ROOT=${top:A}
      AMD_MAIN_ROOT=$AMD_GIT_ROOT
      # In a linked worktree the common git dir belongs to the main checkout.
      common=$(amd_git -C $AMD_CWD rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
      [[ ${common:t} == .git ]] && AMD_MAIN_ROOT=${common:h:A}
    fi
  fi
  typeset -g AMD_PROJECT_ROOT=${AMD_GIT_ROOT:-$AMD_CWD}

  # Every directory from the filesystem root down to the inspected one.
  typeset -ga AMD_CHAIN=()
  local d=$AMD_CWD
  while true; do
    AMD_CHAIN=($d $AMD_CHAIN)
    [[ $d == / ]] && break
    d=${d:h}
  done
}

# amd_detect_versions
# Fill AMD_VER. AGENTSEMDEE_<CMD>_VERSION overrides detection; it is also how
# the viewer hands results to its own subprocesses instead of re-running them.
amd_detect_versions() {
  emulate -L zsh
  local a cmd var out
  local MATCH MBEGIN MEND
  for a in $AMD_AGENTS; do
    cmd=$AMD_AGENT_CMD[$a]
    var=AGENTSEMDEE_${(U)cmd}_VERSION
    if (( ${(P)+var} )); then
      AMD_VER[$a]=${(P)var}
    else
      AMD_VER[$a]=''
      if (( $+commands[$cmd] )); then
        out=$(command $cmd --version </dev/null 2>/dev/null | head -n 1)
        [[ $out =~ '[0-9]+\.[0-9]+\.[0-9]+' ]] && AMD_VER[$a]=$MATCH
      fi
    fi
    export $var=$AMD_VER[$a]
  done
}

# amd_ver_ge A B: true when dotted version A >= B.
amd_ver_ge() {
  emulate -L zsh
  local -a a=(${(s:.:)1}) b=(${(s:.:)2})
  local i
  for i in 1 2 3; do
    (( ${a[i]:-0} > ${b[i]:-0} )) && return 0
    (( ${a[i]:-0} < ${b[i]:-0} )) && return 1
  done
  return 0
}

# amd_dir_scope DIR -> REPLY is "project" or "above".
amd_dir_scope() {
  local root=${AMD_PROJECT_ROOT%/}
  if [[ $1 == $AMD_PROJECT_ROOT || $1 == $root/* ]]; then
    REPLY=project
  else
    REPLY=above
  fi
}

# amd_report AGENT SCOPE KIND PATH STATE REASON [SLOT]
#   STATE  loaded | skipped
#   SLOT   1 to keep the row as an empty slot when PATH does not exist
# The first report for a path fixes its scope and kind.
amd_report() {
  local agent=$1 scope=$2 kind=$3 p=$4 state=$5 reason=$6 slot=${7:-0}
  local exists=1
  if [[ ! -e $p ]]; then
    (( slot )) || return 0
    exists=0
    state=missing
  fi
  if (( ! ${+AMD_SCOPE[$p]} )); then
    AMD_ORDER+=($p)
    AMD_SCOPE[$p]=$scope
    AMD_KIND[$p]=$kind
    AMD_EXISTS[$p]=$exists
  fi
  (( ${+AMD_STATE[$agent:$p]} )) && return 0
  AMD_STATE[$agent:$p]=$state
  AMD_REASON[$agent:$p]=$reason
}

# amd_collect: run every agent module against the current context.
amd_collect() {
  AMD_ORDER=()
  AMD_SCOPE=() AMD_KIND=() AMD_EXISTS=() AMD_STATE=() AMD_REASON=()
  AMD_CHILDREN=() AMD_LABEL=() AMD_NOTE=()
  amd_agent_claude
  amd_agent_codex
  amd_agent_opencode
  amd_expand_skills
}

# amd_expand_skills: give every skills folder one child row per skill, so
# each SKILL.md can be selected and read on its own.
#
# A skill starts with the state its folder has for each agent. An agent
# module may define amd_skill_rule_<agent> FOLDER FILE GROUP to refine that:
# it returns true and sets reply=(state reason) when its own rules say
# something more specific, such as one skill shadowing another.
amd_expand_skills() {
  emulate -L zsh
  setopt extendedglob
  local p f a rel group fn
  local -a kids files
  for p in $AMD_ORDER; do
    [[ $AMD_KIND[$p] == skills && -d $p ]] || continue
    amd_skill_files $p
    files=($reply)
    kids=()
    for f in $files; do
      (( ${+AMD_SCOPE[$f]} )) && continue
      kids+=($f)
      AMD_SCOPE[$f]=$AMD_SCOPE[$p]
      AMD_KIND[$f]=skill
      AMD_EXISTS[$f]=1
      AMD_LABEL[$f]=${f:h:t}
      # Skills grouped one level down, such as synced/ or .system/, carry
      # the group name as their note.
      rel=${${f:h}#$p/}
      group=''
      [[ $rel == */* ]] && group=${rel%%/*}
      AMD_NOTE[$f]=${group:-skill}
      for a in $AMD_AGENTS; do
        (( ${+AMD_STATE[$a:$p]} )) || continue
        AMD_STATE[$a:$f]=$AMD_STATE[$a:$p]
        AMD_REASON[$a:$f]=$AMD_REASON[$a:$p]
        fn=amd_skill_rule_$a
        if (( $+functions[$fn] )) && $fn $p $f "$group"; then
          AMD_STATE[$a:$f]=$reply[1]
          AMD_REASON[$a:$f]=$reply[2]
        fi
      done
    done
    (( ${#kids} )) && AMD_CHILDREN[$p]=${(pj:\0:)kids}
  done
}

# amd_scope_paths SCOPE ALL -> reply holds the paths to list for that scope.
# Managed and user rows keep report order, which groups them by agent. Rows
# tied to the directory tree sort outermost first, so lower rows win.
amd_scope_paths() {
  emulate -L zsh
  local scope=$1 all=$2 p owner depth i=0
  local -a keyed
  reply=()
  for p in $AMD_ORDER; do
    (( i++ ))
    [[ $AMD_SCOPE[$p] == $scope ]] || continue
    (( AMD_EXISTS[$p] || all )) || continue
    depth=0
    if [[ $scope != (managed|user) ]]; then
      owner=${p:h}
      [[ ${owner:t} == (.claude|.codex|.opencode|.agents) ]] && owner=${owner:h}
      [[ $owner == / ]] || depth=${#${owner//[^\/]/}}
      depth=${(l:3::0:)depth}${AMD_KIND_RANK[$AMD_KIND[$p]]:-9}
    fi
    keyed+=("${depth}${(l:5::0:)i}"$'\t'"$p")
  done
  for p in ${(o)keyed}; do
    reply+=("${p#*$'\t'}")
  done
}

# amd_show_path PATH -> REPLY is the short form shown in the list.
# Paths inside the project are relative to the inspected directory.
amd_show_path() {
  emulate -L zsh
  local p=$1 d=$AMD_CWD prefix='' i
  if [[ $p == ${AMD_CWD%/}/* ]]; then
    REPLY=./${p#${AMD_CWD%/}/}
    return
  fi
  for i in 1 2 3; do
    [[ $d == / ]] && break
    d=${d:h}
    prefix+=../
    amd_dir_scope $d
    [[ $REPLY == project ]] || break
    if [[ $p == ${d%/}/* ]]; then
      REPLY=$prefix${p#${d%/}/}
      return
    fi
  done
  amd_tilde $p
}

# amd_tilde PATH -> REPLY with the home directory shortened to "~".
amd_tilde() {
  if [[ $1 == $AMD_HOME ]]; then
    REPLY='~'
  elif [[ $1 == $AMD_HOME/* ]]; then
    REPLY="~/${1#$AMD_HOME/}"
  else
    REPLY=$1
  fi
}

# amd_detail PATH -> REPLY is the dim note after the path: kind, or a count.
amd_detail() {
  emulate -L zsh
  setopt extendedglob
  local p=$1 kind=$AMD_KIND[$p]
  local -a found
  if [[ ! -d $p ]]; then
    REPLY=$kind
    return
  fi
  case ${p:t} in
    skills|skill)
      amd_skill_files $p
      found=($reply)
      REPLY="${#found} skill"; (( ${#found} == 1 )) || REPLY+=s ;;
    rules)
      found=($p/**/*.md(N-.))
      REPLY="${#found} rule"; (( ${#found} == 1 )) || REPLY+=s ;;
    *)
      found=($p/*(N-.))
      REPLY="${#found} file"; (( ${#found} == 1 )) || REPLY+=s ;;
  esac
}

# amd_json_get FILE FILTER: print jq -r output, or nothing when the file is
# absent, unreadable, not valid JSON, or jq is not installed.
amd_json_get() {
  [[ -r $1 && -f $1 ]] || return 0
  (( $+commands[jq] )) || return 0
  command jq -r "$2" -- "$1" 2>/dev/null
  return 0
}

# amd_toml_top FILE KEY -> REPLY is the raw value of a top-level key.
# Only keys before the first table header count, which is what "top-level"
# means in TOML. Arrays may span lines.
amd_toml_top() {
  emulate -L zsh
  local file=$1 key=$2 line buf='' collecting=0
  local MATCH MBEGIN MEND; local -a match mbegin mend
  REPLY=''
  [[ -r $file && -f $file ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    if (( collecting )); then
      buf+=" $line"
      [[ $line == *']'* ]] && break
      continue
    fi
    [[ $line =~ '^[[:space:]]*\[' ]] && break
    if [[ $line =~ "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)\$" ]]; then
      buf=$match[1]
      if [[ $buf == '['* && $buf != *']'* ]]; then
        collecting=1
        continue
      fi
      break
    fi
  done < $file
  REPLY=$buf
  [[ -n $buf ]]
}

# amd_toml_strings TEXT -> reply holds each quoted string found in TEXT.
amd_toml_strings() {
  emulate -L zsh
  local rest=$1 re=$'"(\\\\.|[^"\\\\])*"|\'[^\']*\''
  local MATCH MBEGIN MEND
  reply=()
  while [[ -n $rest && $rest =~ $re ]]; do
    reply+=("${MATCH[2,-2]}")
    rest=${rest[MEND+1,-1]}
  done
}

# amd_skill_files DIR -> reply holds the SKILL.md files under a skills folder.
# Skills sit one level down, or deeper when an agent groups them, as Codex
# does under .system and Claude Code does under synced. Trash and staging
# folders are left out.
amd_skill_files() {
  emulate -L zsh
  setopt extendedglob
  local p=$1
  reply=($p/*/SKILL.md(ND-.) $p/*/*/SKILL.md(ND-.) $p/*/*/*/SKILL.md(ND-.))
  reply=(${reply:#*/(.trash|.bucket-*)/*})
}
