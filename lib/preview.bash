# preview.bash: the right-hand pane of the viewer.
#
# The viewer passes the selected row back as one tab-separated line, so the
# pane needs no second discovery pass. File content is cleaned of terminal
# control characters, and settings files are masked, before anything prints.

declare -gA AMD_SCOPE_HELP=(
  [managed]='Files an administrator installs for everyone on this machine.

Claude Code treats them as locked policy: nothing you set overrides them.

Codex enforces requirements.toml. Its system config.toml is only a default, which your user config overrides.

OpenCode 1.x loads managed config last, so it overrides everything else.'
  [user]='Your own files, applied in every project.

They load first, so project files refine or override them.'
  [above]='Directories above the project root.

Some agents keep walking upward past the repository. Claude Code reads instruction files and .mcp.json all the way to the filesystem root. OpenCode 2 reads AGENTS.md up to your home directory.'
  [project]='Files that live in the repository and are meant to be committed, so the whole team gets them.

Rows run from the repository root down to the inspected directory. Where files conflict, the lower row wins.'
  [local]='Your personal files for this project.

They are meant to stay out of git, and they override the shared project files.'
)

declare -gA AMD_STATE_LABEL=(
  [loaded]='loaded'
  [skipped]='present, not loaded'
  [missing]='read if created'
  [-]='does not read this file'
)

# Strip terminal control characters, keeping tabs and newlines. A file in an
# unfamiliar repository must not be able to drive the terminal.
_amd_sanitize() {
  LC_ALL=C command tr -d '\000-\010\013-\037\177'
}

# _amd_highlight LANGUAGE: syntax-color stdin when bat is available.
_amd_highlight() {
  if amd_have bat; then
    command bat --color=always --style=plain --paging=never --language="$1" 2>/dev/null
  else
    command cat
  fi
}

# _amd_width -> REPLY is the pane width in columns.
_amd_width() {
  local w
  for w in "${FZF_PREVIEW_COLUMNS:-}" "${COLUMNS:-}" 80; do
    if [[ $w =~ ^[0-9]+$ ]] && (( 10#$w > 0 )); then
      REPLY=$(( 10#$w ))
      return
    fi
  done
}

# _amd_wrap INDENT: fold stdin to the pane width with a left margin.
_amd_wrap() {
  local pad
  _amd_width
  local width=$(( REPLY - $1 - 1 ))
  (( width < 20 )) && width=20
  printf -v pad '%*s' "$1" ''
  command fold -s -w "$width" | command sed "s/^/$pad/"
}

# _amd_size BYTES -> REPLY in human units, to one decimal place.
_amd_size() {
  local b=$1 unit tenths
  if (( b < 1024 )); then
    REPLY="$b B"
    return
  elif (( b < 1048576 )); then
    unit=1024 REPLY=KB
  else
    unit=1048576 REPLY=MB
  fi
  tenths=$(( (b * 10 + unit / 2) / unit ))
  REPLY="$(( tenths / 10 )).$(( tenths % 10 )) $REPLY"
}

# _amd_git_state PATH -> REPLY is tracked | ignored | untracked | ''.
_amd_git_state() {
  local p=$1 dir name=${1##*/} listed
  amd_dirname "$p"
  dir=$REPLY
  REPLY=''
  amd_have git || return 0
  [[ -d $dir ]] || return 0
  amd_git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  listed=$(amd_git -C "$dir" ls-files -- "$name" 2>/dev/null | head -n 1)
  if [[ -n $listed ]]; then
    REPLY=tracked
  elif amd_git -C "$dir" check-ignore -q -- "$name" 2>/dev/null; then
    REPLY=ignored
  else
    REPLY=untracked
  fi
}

# amd_preview LINE: render the pane for one viewer row.
amd_preview() {
  local -a f
  amd_split "$1" $'\t'
  f=("${reply[@]}")
  amd_colors on
  case ${f[0]:-} in
    F)   _amd_preview_file "${f[@]}" ;;
    H|N) _amd_preview_scope "${f[1]:-}" ;;
    *)   return 0 ;;
  esac
}

_amd_preview_scope() {
  local scope=$1
  [[ -n ${AMD_SCOPE_TITLE[$scope]:-} ]] || return 0
  amd_say "${AMD_C[bold]}${AMD_SCOPE_TITLE[$scope]}${AMD_C[reset]}" ''
  amd_say "${AMD_SCOPE_HELP[$scope]}" | _amd_wrap 0
}

_amd_preview_file() {
  local scope=$2 kind=$3 p=$4 exists=$5
  local -a states=("$6" "$8" "${10}") reasons=("$7" "$9" "${11}")
  local shown meta git_state='' i a bytes width name state
  _amd_width
  width=$REPLY

  AMD_KIND[$p]=$kind
  amd_show_path "$p"
  amd_visible "$REPLY"
  shown=$REPLY
  [[ -d $p || $kind == skills ]] && shown+=/
  amd_say "${AMD_C[bold]}$shown${AMD_C[reset]}"
  amd_tilde "$p"
  amd_visible "$REPLY"
  [[ ${shown%/} != "$REPLY" ]] && amd_say "${AMD_C[dim]}$REPLY${AMD_C[reset]}"

  meta="${AMD_SCOPE_TITLE[$scope]} · $kind"
  if [[ $exists == 1 ]]; then
    if [[ -d $p ]]; then
      amd_detail "$p"
      meta+=" · $REPLY"
    else
      bytes=$(command wc -c < "$p" 2>/dev/null)
      bytes=${bytes//[!0-9]/}
      _amd_size $(( 10#${bytes:-0} ))
      meta+=" · $REPLY"
    fi
    _amd_git_state "$p"
    git_state=$REPLY
    [[ -n $git_state ]] && meta+=" · $git_state in git"
  else
    meta+=' · not present'
  fi
  amd_say "${AMD_C[dim]}$meta${AMD_C[reset]}"
  if [[ -L $p ]]; then
    amd_realpath "$p"
    amd_visible "$REPLY"
    amd_say "${AMD_C[dim]}symlink to $REPLY${AMD_C[reset]}"
  fi
  if [[ $scope == local && $git_state == tracked ]]; then
    amd_say "${AMD_C[red]}Tracked in git. This file is personal and is meant to stay uncommitted.${AMD_C[reset]}" | _amd_wrap 0
  elif [[ $scope == local && $git_state == untracked ]]; then
    amd_say "${AMD_C[yellow]}Not ignored by git, so it could be committed by accident.${AMD_C[reset]}" | _amd_wrap 0
  fi
  amd_say ''

  i=0
  for a in "${AMD_AGENTS[@]}"; do
    state=${states[i]}
    printf -v name '%-12.12s' "${AMD_AGENT_NAME[$a]}"
    if [[ $state == - ]]; then
      amd_say " ${AMD_C[dim]}  $name ${AMD_STATE_LABEL[-]}${AMD_C[reset]}"
    else
      amd_dot "$state"
      amd_say " $REPLY ${AMD_C[bold]}$name${AMD_C[reset]} ${AMD_STATE_LABEL[$state]:-}"
      amd_say "${reasons[i]}" | _amd_wrap 3
    fi
    (( i++ ))
  done

  amd_repeat $(( width - 1 )) ─
  amd_say "${AMD_C[dim]}$REPLY${AMD_C[reset]}"
  if [[ $exists != 1 ]]; then
    amd_say "${AMD_C[dim]}Nothing here yet.${AMD_C[reset]}"
    return 0
  fi
  _amd_preview_content "$kind" "$p"
}

# How much of a file the pane reads.
declare -g AMD_PREVIEW_BYTES=262144

_amd_preview_content() {
  local kind=$1 p=$2 name=${2##*/} format=json lang=json

  if [[ -d $p ]]; then
    _amd_preview_dir "$p"
    return 0
  fi
  if [[ ! -f $p || ! -r $p ]]; then
    amd_say "${AMD_C[dim]}Not a readable file.${AMD_C[reset]}"
    return 0
  fi
  if [[ $name == .claude.json ]]; then
    _amd_preview_claude_state "$p"
    return 0
  fi
  if [[ $kind == instructions || $kind == skill ]]; then
    command head -c $AMD_PREVIEW_BYTES -- "$p" | _amd_sanitize | _amd_highlight markdown
    return 0
  fi

  amd_say "${AMD_C[dim]}Secret values are masked. Press enter to open the file itself.${AMD_C[reset]}" | _amd_wrap 0
  amd_say ''
  case $name in
    *.toml) format=toml; lang=toml ;;
  esac
  if [[ $name == *.plist ]]; then
    if amd_have plutil && amd_have jq; then
      command plutil -convert json -o - -- "$p" 2>/dev/null | command jq . 2>/dev/null \
        | _amd_sanitize | amd_redact json | _amd_highlight json
    else
      amd_say "${AMD_C[dim]}plutil and jq are needed to show a managed preferences file.${AMD_C[reset]}"
    fi
  elif [[ $name == *.json ]] && amd_have jq && command jq -e . -- "$p" >/dev/null 2>&1; then
    # Pretty-print first so the line-based masking sees one key per line.
    command jq . -- "$p" | command head -c $AMD_PREVIEW_BYTES | _amd_sanitize | amd_redact json | _amd_highlight json
  else
    command head -c $AMD_PREVIEW_BYTES -- "$p" | _amd_sanitize | amd_redact $format | _amd_highlight $lang
  fi
}

# ~/.claude.json mixes MCP servers with sign-in and app state. Show only the
# MCP servers that apply here.
_amd_preview_claude_state() {
  local p=$1
  amd_say "${AMD_C[dim]}Showing MCP servers only. The file also holds sign-in and app state, which is not displayed. Secret values are masked.${AMD_C[reset]}" | _amd_wrap 0
  amd_say ''
  if ! amd_have jq; then
    amd_say "${AMD_C[dim]}jq is needed to read this file.${AMD_C[reset]}"
    return 0
  fi
  command jq --arg cwd "$AMD_CWD" --arg root "$AMD_PROJECT_ROOT" --arg main "$AMD_MAIN_ROOT" '
    . as $doc
    | {
        "user scope, every project": ($doc.mcpServers // {}),
        "local scope, this project": (
          [$cwd, $root, $main] | map(select(length > 0)) | unique
          | map(. as $k | {key: $k, value: ($doc.projects[$k].mcpServers // null)})
          | map(select(.value != null and (.value | length) > 0))
          | from_entries
        )
      }' -- "$p" 2>/dev/null | _amd_sanitize | amd_redact json | _amd_highlight json
}

_amd_preview_dir() {
  local p=$1 f l name desc n
  local -a found
  case ${p##*/} in
    skills|skill)
      amd_skill_files "$p"
      found=("${reply[@]}")
      if (( ${#found[@]} == 0 )); then
        amd_say "${AMD_C[dim]}No skills here.${AMD_C[reset]}"
        return 0
      fi
      for f in "${found[@]}"; do
        name=${f%/*}
        name=${name##*/}
        desc=''
        n=0
        while IFS= read -r l || [[ -n $l ]]; do
          (( ++n > 40 )) && break
          if [[ $l == description:* ]]; then
            desc=${l#description:}
            desc=${desc#"${desc%%[! ]*}"}
            # A folded or literal block puts the text on the next line.
            if [[ $desc == '>'* || $desc == '|'* ]]; then
              IFS= read -r desc
              desc=${desc#"${desc%%[! ]*}"}
            fi
            break
          fi
        done < "$f"
        desc=${desc#[\"\']}
        desc=${desc%[\"\']}
        amd_visible "$name"
        amd_say " ${AMD_C[bold]}$REPLY${AMD_C[reset]}"
        if [[ -n $desc ]]; then
          amd_visible "${desc:0:240}"
          amd_say "${AMD_C[dim]}$REPLY${AMD_C[reset]}" | _amd_wrap 3
        fi
      done ;;
    rules)
      amd_files "$p" '**/*.md'
      found=("${reply[@]}")
      for f in "${found[@]}"; do
        amd_visible "${f#"$p"/}"
        if command grep -Eq '^paths:' -- "$f" 2>/dev/null; then
          amd_say " $REPLY  ${AMD_C[dim]}path-scoped${AMD_C[reset]}"
        else
          amd_say " $REPLY  ${AMD_C[dim]}loads at launch${AMD_C[reset]}"
        fi
      done
      (( ${#found[@]} )) || amd_say "${AMD_C[dim]}No rule files here.${AMD_C[reset]}" ;;
    *)
      shopt -s nullglob
      found=("$p"/*)
      shopt -u nullglob
      for f in "${found[@]}"; do
        amd_visible "${f##*/}"
        amd_say " $REPLY"
      done
      (( ${#found[@]} )) || amd_say "${AMD_C[dim]}Empty directory.${AMD_C[reset]}" ;;
  esac
}
