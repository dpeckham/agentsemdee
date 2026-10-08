# core.bash: shared state, directory context, and the report protocol.
#
# Each agent module calls amd_report once per file it knows about. The core
# merges those reports by path, so a file that several agents read becomes one
# row with one state per agent.
#
# Paths can come from repositories the user has not reviewed, so they are
# never used as array subscripts inside (( )) or [[ -v ]], where bash would
# evaluate them a second time.

declare -ga AMD_AGENTS=(c x o)
declare -gA AMD_AGENT_NAME=([c]='Claude Code' [x]='Codex' [o]='OpenCode')
declare -gA AMD_AGENT_CMD=([c]=claude [x]=codex [o]=opencode)
declare -gA AMD_AGENT_SHORT=([c]=Claude [x]=Codex [o]=OpenCode)
declare -ga AMD_SCOPES=(managed user above project local)
declare -gA AMD_SCOPE_TITLE=(
  [managed]='Managed'
  [user]='User global'
  [above]='Above the project'
  [project]='Project shared (team)'
  [local]='Project local (you)'
)
declare -gA AMD_KIND_RANK=([instructions]=1 [settings]=2 [mcp]=3 [skills]=4)

declare -ga AMD_ORDER=()              # paths, in first-report order
declare -gA AMD_SCOPE=() AMD_KIND=() AMD_EXISTS=()
declare -gA AMD_STATE=() AMD_REASON=()  # keyed "<agent>:<path>"
declare -gA AMD_VER=()                # agent letter -> installed version, or ''

# Rows nested under another row: one per skill inside a skills folder.
# They live in the tables above but not in AMD_ORDER, so they always follow
# their folder. AMD_CHILDREN maps a folder to its children, separated by
# AMD_SEP.
declare -gA AMD_CHILDREN=() AMD_LABEL=() AMD_NOTE=()
declare -g AMD_SEP=$'\x1f'

# Directory that holds admin-installed files. Tests point this at a fixture.
declare -g AMD_SYSROOT=${AGENTSEMDEE_SYSROOT:-}

# amd_have COMMAND: true when an external command is on PATH.
amd_have() {
  type -P -- "$1" >/dev/null 2>&1
}

# amd_say TEXT...: print each argument on its own line, verbatim.
amd_say() {
  printf '%s\n' "$@"
}

# git, with repository-supplied hooks into command execution switched off.
# This tool runs in directories the user has not necessarily vetted.
amd_git() {
  command git -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
}

# amd_realpath PATH -> REPLY is the absolute path with symlinks resolved.
# Trailing parts that do not exist are kept as written.
amd_realpath() {
  local p=$1 target dir n=0
  [[ $p == /* ]] || p=$PWD/$p
  while [[ -L $p ]] && (( n++ < 40 )); do
    target=$(command readlink -- "$p") || break
    [[ $target == /* ]] || target=${p%/*}/$target
    p=$target
  done
  if [[ -d $p ]] && REPLY=$(CDPATH='' cd -P -- "$p" 2>/dev/null && pwd -P); then
    return 0
  fi
  dir=${p%/*}
  [[ -n $dir ]] || dir=/
  if [[ $dir == "$p" ]]; then
    REPLY=$p
    return 0
  fi
  amd_realpath "$dir"
  REPLY=${REPLY%/}/${p##*/}
}

# amd_dirname PATH -> REPLY is the parent directory.
amd_dirname() {
  REPLY=${1%/*}
  [[ -n $REPLY ]] || REPLY=/
}

# amd_split STRING SEPARATOR -> reply holds the fields, empty ones included.
amd_split() {
  local rest=$1 sep=$2
  reply=()
  [[ -n $rest ]] || return 0
  while [[ $rest == *"$sep"* ]]; do
    reply+=("${rest%%"$sep"*}")
    rest=${rest#*"$sep"}
  done
  reply+=("$rest")
}

# amd_join SEPARATOR WORD... -> REPLY is the words joined by SEPARATOR.
amd_join() {
  local sep=$1
  shift
  REPLY=''
  (( $# )) || return 0
  printf -v REPLY "%s${sep//%/%%}" "$@"
  REPLY=${REPLY%"$sep"}
}

# amd_files DIR PATTERN [dot] -> reply holds the regular files, or symlinks
# to them, matching DIR/PATTERN. With "dot", hidden names match too.
amd_files() {
  local f
  local -a found
  shopt -s nullglob globstar
  [[ ${3:-} == dot ]] && shopt -s dotglob
  # shellcheck disable=SC2206 # PATTERN is meant to glob.
  found=("$1"/$2)
  shopt -u nullglob globstar dotglob
  reply=()
  for f in "${found[@]}"; do
    [[ -f $f ]] && reply+=("$f")
  done
}

# amd_init_context DIR
# Resolve the directory being inspected and the project it belongs to.
amd_init_context() {
  local dir=${1:-$PWD}
  if [[ ! -d $dir ]]; then
    amd_say "agentsemdee: not a directory: $dir" >&2
    return 1
  fi
  amd_realpath "$dir"
  declare -g AMD_CWD=$REPLY
  amd_realpath "$HOME"
  declare -g AMD_HOME=$REPLY
  if [[ $AMD_CWD == *[$'\t\n']* || $AMD_HOME == *[$'\t\n']* ]]; then
    amd_say "agentsemdee: paths containing tabs or newlines are not supported" >&2
    return 1
  fi

  declare -g AMD_GIT_ROOT='' AMD_MAIN_ROOT=''
  local top common
  if amd_have git; then
    top=$(amd_git -C "$AMD_CWD" rev-parse --show-toplevel 2>/dev/null)
    if [[ -n $top ]]; then
      amd_realpath "$top"
      AMD_GIT_ROOT=$REPLY
      AMD_MAIN_ROOT=$AMD_GIT_ROOT
      # In a linked worktree the common git dir belongs to the main checkout.
      common=$(amd_git -C "$AMD_CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
      if [[ ${common##*/} == .git ]]; then
        amd_realpath "${common%/*}"
        AMD_MAIN_ROOT=$REPLY
      fi
    fi
  fi
  declare -g AMD_PROJECT_ROOT=${AMD_GIT_ROOT:-$AMD_CWD}

  # Every directory from the filesystem root down to the inspected one.
  declare -ga AMD_CHAIN=()
  local d=$AMD_CWD
  while true; do
    AMD_CHAIN=("$d" "${AMD_CHAIN[@]}")
    [[ $d == / ]] && break
    amd_dirname "$d"
    d=$REPLY
  done
}

# amd_detect_versions
# Fill AMD_VER. AGENTSEMDEE_<CMD>_VERSION overrides detection; it is also how
# the viewer hands results to its own subprocesses instead of re-running them.
amd_detect_versions() {
  local a cmd var out re='[0-9]+\.[0-9]+\.[0-9]+'
  for a in "${AMD_AGENTS[@]}"; do
    cmd=${AMD_AGENT_CMD[$a]}
    var=AGENTSEMDEE_${cmd^^}_VERSION
    if [[ -n ${!var+x} ]]; then
      AMD_VER[$a]=${!var}
    else
      AMD_VER[$a]=''
      if amd_have "$cmd"; then
        out=$(command "$cmd" --version </dev/null 2>/dev/null | head -n 1)
        [[ $out =~ $re ]] && AMD_VER[$a]=${BASH_REMATCH[0]}
      fi
    fi
    export "$var=${AMD_VER[$a]}"
  done
}

# amd_ver_ge A B: true when dotted version A >= B.
amd_ver_ge() {
  local -a a b
  local i x y
  IFS=. read -ra a <<< "$1"
  IFS=. read -ra b <<< "$2"
  for i in 0 1 2; do
    x=${a[i]:-0} y=${b[i]:-0}
    x=${x//[!0-9]/} y=${y//[!0-9]/}
    (( 10#${x:-0} > 10#${y:-0} )) && return 0
    (( 10#${x:-0} < 10#${y:-0} )) && return 1
  done
  return 0
}

# amd_dir_scope DIR -> REPLY is "project" or "above".
amd_dir_scope() {
  local root=${AMD_PROJECT_ROOT%/}
  if [[ $1 == "$AMD_PROJECT_ROOT" || $1 == "$root"/* ]]; then
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
    [[ $slot == 1 ]] || return 0
    exists=0
    state=missing
  fi
  if [[ -z ${AMD_SCOPE[$p]+x} ]]; then
    AMD_ORDER+=("$p")
    AMD_SCOPE[$p]=$scope
    AMD_KIND[$p]=$kind
    AMD_EXISTS[$p]=$exists
  fi
  [[ -n ${AMD_STATE[$agent:$p]+x} ]] && return 0
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
  local p f a fdir rel group fn
  local -a kids files
  for p in "${AMD_ORDER[@]}"; do
    [[ ${AMD_KIND[$p]} == skills && -d $p ]] || continue
    amd_skill_files "$p"
    files=("${reply[@]}")
    kids=()
    for f in "${files[@]}"; do
      [[ -n ${AMD_SCOPE[$f]+x} ]] && continue
      kids+=("$f")
      fdir=${f%/*}
      AMD_SCOPE[$f]=${AMD_SCOPE[$p]}
      AMD_KIND[$f]=skill
      AMD_EXISTS[$f]=1
      AMD_LABEL[$f]=${fdir##*/}
      # Skills grouped one level down, such as synced/ or .system/, carry
      # the group name as their note.
      rel=${fdir#"$p"/}
      group=''
      [[ $rel == */* ]] && group=${rel%%/*}
      AMD_NOTE[$f]=${group:-skill}
      for a in "${AMD_AGENTS[@]}"; do
        [[ -n ${AMD_STATE[$a:$p]+x} ]] || continue
        AMD_STATE[$a:$f]=${AMD_STATE[$a:$p]}
        AMD_REASON[$a:$f]=${AMD_REASON[$a:$p]}
        fn=amd_skill_rule_$a
        if declare -F "$fn" >/dev/null && "$fn" "$p" "$f" "$group"; then
          AMD_STATE[$a:$f]=${reply[0]}
          AMD_REASON[$a:$f]=${reply[1]}
        fi
      done
    done
    if (( ${#kids[@]} )); then
      amd_join "$AMD_SEP" "${kids[@]}"
      AMD_CHILDREN[$p]=$REPLY
    fi
  done
}

# amd_scope_paths SCOPE ALL -> reply holds the paths to list for that scope.
# Managed and user rows keep report order, which groups them by agent. Rows
# tied to the directory tree sort outermost first, so lower rows win.
amd_scope_paths() {
  local scope=$1 all=$2 p owner depth slashes line i=0
  local -a keyed=()
  reply=()
  for p in "${AMD_ORDER[@]}"; do
    (( i++ ))
    [[ ${AMD_SCOPE[$p]} == "$scope" ]] || continue
    [[ ${AMD_EXISTS[$p]} == 1 || $all == 1 ]] || continue
    depth=''
    if [[ $scope != managed && $scope != user ]]; then
      amd_dirname "$p"
      owner=$REPLY
      case ${owner##*/} in
        .claude|.codex|.opencode|.agents) amd_dirname "$owner"; owner=$REPLY ;;
      esac
      slashes=''
      [[ $owner == / ]] || slashes=${owner//[!\/]/}
      printf -v depth '%03d%s' "${#slashes}" "${AMD_KIND_RANK[${AMD_KIND[$p]}]:-9}"
    fi
    printf -v line '%s%05d\t%s' "$depth" "$i" "$p"
    keyed+=("$line")
  done
  (( ${#keyed[@]} )) || return 0
  while IFS= read -r line; do
    reply+=("${line#*$'\t'}")
  done < <(printf '%s\n' "${keyed[@]}" | LC_ALL=C command sort)
}

# amd_show_path PATH -> REPLY is the short form shown in the list.
# Paths inside the project are relative to the inspected directory.
amd_show_path() {
  local p=$1 d=$AMD_CWD prefix='' i
  if [[ $p == "${AMD_CWD%/}"/* ]]; then
    REPLY=./${p#"${AMD_CWD%/}"/}
    return
  fi
  for i in 1 2 3; do
    [[ $d == / ]] && break
    amd_dirname "$d"
    d=$REPLY
    prefix+=../
    amd_dir_scope "$d"
    [[ $REPLY == project ]] || break
    if [[ $p == "${d%/}"/* ]]; then
      REPLY=$prefix${p#"${d%/}"/}
      return
    fi
  done
  amd_tilde "$p"
}

# amd_tilde PATH -> REPLY with the home directory shortened to "~".
amd_tilde() {
  if [[ $1 == "$AMD_HOME" ]]; then
    REPLY='~'
  elif [[ $1 == "$AMD_HOME"/* ]]; then
    REPLY="~/${1#"$AMD_HOME"/}"
  else
    REPLY=$1
  fi
}

# amd_visible TEXT -> REPLY with control characters shown as ^X, so a file
# name cannot drive the terminal.
amd_visible() {
  local s=$1 out='' c i code
  if [[ $s != *[[:cntrl:]]* ]]; then
    REPLY=$s
    return
  fi
  for (( i = 0; i < ${#s}; i++ )); do
    c=${s:i:1}
    if [[ $c == [[:cntrl:]] ]]; then
      printf -v code '%d' "'$c"
      if (( code == 127 )); then
        out+='^?'
      else
        printf -v c "\\x$(printf '%02x' $(( code + 64 )))"
        out+="^$c"
      fi
    else
      out+=$c
    fi
  done
  REPLY=$out
}

# amd_count N WORD -> REPLY is "N WORD", plural unless N is 1.
amd_count() {
  REPLY="$1 $2"
  [[ $1 == 1 ]] || REPLY+=s
}

# amd_detail PATH -> REPLY is the dim note after the path: kind, or a count.
amd_detail() {
  local p=$1
  if [[ ! -d $p ]]; then
    REPLY=${AMD_KIND[$p]}
    return
  fi
  case ${p##*/} in
    skills|skill)
      amd_skill_files "$p"
      amd_count "${#reply[@]}" skill ;;
    rules)
      amd_files "$p" '**/*.md'
      amd_count "${#reply[@]}" rule ;;
    *)
      amd_files "$p" '*'
      amd_count "${#reply[@]}" file ;;
  esac
}

# amd_json_get FILE FILTER: print jq -r output, or nothing when the file is
# absent, unreadable, not valid JSON, or jq is not installed.
amd_json_get() {
  [[ -r $1 && -f $1 ]] || return 0
  amd_have jq || return 0
  command jq -r "$2" -- "$1" 2>/dev/null
  return 0
}

# amd_toml_top FILE KEY -> REPLY is the raw value of a top-level key.
# Only keys before the first table header count, which is what "top-level"
# means in TOML. Arrays may span lines.
amd_toml_top() {
  local file=$1 key=$2 line buf='' collecting=0
  local header='^[[:space:]]*\['
  local assign="^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)\$"
  REPLY=''
  [[ -r $file && -f $file ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    if (( collecting )); then
      buf+=" $line"
      [[ $line == *']'* ]] && break
      continue
    fi
    [[ $line =~ $header ]] && break
    if [[ $line =~ $assign ]]; then
      buf=${BASH_REMATCH[1]}
      if [[ $buf == '['* && $buf != *']'* ]]; then
        collecting=1
        continue
      fi
      break
    fi
  done < "$file"
  REPLY=$buf
  [[ -n $buf ]]
}

# amd_match TEXT ERE -> true when ERE matches somewhere in TEXT. Sets
# AMD_PRE to the text before the match, AMD_POST to the text after it, and
# AMD_M to the match (AMD_M[0]) and its groups (AMD_M[1] on).
amd_match() {
  local re="($2)(.*)\$"
  [[ $1 =~ $re ]] || return 1
  local n=${#BASH_REMATCH[@]}
  AMD_POST=${BASH_REMATCH[n-1]}
  AMD_M=("${BASH_REMATCH[@]:1:n-2}")
  AMD_PRE=${1:0:${#1}-${#BASH_REMATCH[0]}}
}

# amd_toml_strings TEXT -> reply holds each quoted string found in TEXT.
amd_toml_strings() {
  local rest=$1 re=$'"(\\\\.|[^"\\\\])*"|\'[^\']*\'' m
  reply=()
  while [[ -n $rest ]] && amd_match "$rest" "$re"; do
    m=${AMD_M[0]}
    reply+=("${m:1:${#m}-2}")
    rest=$AMD_POST
  done
}

# amd_skill_files DIR -> reply holds the SKILL.md files under a skills folder.
# Skills sit one level down, or deeper when an agent groups them, as Codex
# does under .system and Claude Code does under synced. Trash and staging
# folders are left out.
amd_skill_files() {
  local p=$1 f
  local -a all=()
  amd_files "$p" '*/SKILL.md' dot;     all+=("${reply[@]}")
  amd_files "$p" '*/*/SKILL.md' dot;   all+=("${reply[@]}")
  amd_files "$p" '*/*/*/SKILL.md' dot; all+=("${reply[@]}")
  reply=()
  for f in "${all[@]}"; do
    [[ $f == */.trash/* || $f == */.bucket-*/* ]] || reply+=("$f")
  done
}
