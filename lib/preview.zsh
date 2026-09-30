# preview.zsh: the right-hand pane of the viewer.
#
# The viewer passes the selected row back as one tab-separated line, so the
# pane needs no second discovery pass. File content is cleaned of terminal
# control characters, and settings files are masked, before anything prints.

typeset -gA AMD_SCOPE_HELP=(
  managed 'Files an administrator installs for everyone on this machine.

Claude Code treats them as locked policy: nothing you set overrides them.

Codex enforces requirements.toml. Its system config.toml is only a default, which your user config overrides.

OpenCode 1.x loads managed config last, so it overrides everything else.'
  user 'Your own files, applied in every project.

They load first, so project files refine or override them.'
  above 'Directories above the project root.

Some agents keep walking upward past the repository. Claude Code reads instruction files and .mcp.json all the way to the filesystem root. OpenCode 2 reads AGENTS.md up to your home directory.'
  project 'Files that live in the repository and are meant to be committed, so the whole team gets them.

Rows run from the repository root down to the inspected directory. Where files conflict, the lower row wins.'
  local 'Your personal files for this project.

They are meant to stay out of git, and they override the shared project files.'
)

typeset -gA AMD_STATE_LABEL=(
  loaded  'loaded'
  skipped 'present, not loaded'
  missing 'read if created'
  -       'does not read this file'
)

# Strip terminal control characters, keeping tabs and newlines. A file in an
# unfamiliar repository must not be able to drive the terminal.
_amd_sanitize() {
  LC_ALL=C command tr -d '\000-\010\013-\037\177'
}

# _amd_highlight LANGUAGE: syntax-color stdin when bat is available.
_amd_highlight() {
  if (( $+commands[bat] )); then
    command bat --color=always --style=plain --paging=never --language=$1 2>/dev/null
  else
    command cat
  fi
}

# _amd_width -> REPLY is the pane width in columns.
_amd_width() {
  REPLY=${FZF_PREVIEW_COLUMNS:-0}
  (( REPLY > 0 )) || REPLY=${COLUMNS:-0}
  (( REPLY > 0 )) || REPLY=80
}

# _amd_wrap INDENT: fold stdin to the pane width with a left margin.
_amd_wrap() {
  _amd_width
  local width=$(( REPLY - $1 - 1 ))
  (( width < 20 )) && width=20
  command fold -s -w $width | command sed "s/^/${(l:$1:: :):-}/"
}

# _amd_size BYTES -> REPLY in human units.
_amd_size() {
  local b=$1
  if (( b < 1024 )); then
    REPLY="$b B"
  elif (( b < 1048576 )); then
    printf -v REPLY '%.1f KB' $(( b / 1024.0 ))
  else
    printf -v REPLY '%.1f MB' $(( b / 1048576.0 ))
  fi
}

# _amd_git_state PATH -> REPLY is tracked | ignored | untracked | ''.
_amd_git_state() {
  emulate -L zsh
  local p=$1 dir=${1:h} listed
  REPLY=''
  (( $+commands[git] )) || return 0
  [[ -d $dir ]] || return 0
  amd_git -C $dir rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  listed=$(amd_git -C $dir ls-files -- ${p:t} 2>/dev/null | head -n 1)
  if [[ -n $listed ]]; then
    REPLY=tracked
  elif amd_git -C $dir check-ignore -q -- ${p:t} 2>/dev/null; then
    REPLY=ignored
  else
    REPLY=untracked
  fi
}

# amd_preview LINE: render the pane for one viewer row.
amd_preview() {
  emulate -L zsh
  setopt extendedglob
  local -a f=("${(@ps:\t:)1}")
  amd_colors on
  case ${f[1]:-} in
    F)   _amd_preview_file "${(@)f}" ;;
    H|N) _amd_preview_scope ${f[2]:-} ;;
    *)   return 0 ;;
  esac
}

_amd_preview_scope() {
  local scope=$1
  [[ -n ${AMD_SCOPE_TITLE[$scope]:-} ]] || return 0
  print -r -- "${AMD_C[bold]}$AMD_SCOPE_TITLE[$scope]${AMD_C[reset]}"
  print
  print -r -- "$AMD_SCOPE_HELP[$scope]" | _amd_wrap 0
}

_amd_preview_file() {
  emulate -L zsh
  setopt extendedglob
  local scope=$2 kind=$3 p=$4 exists=$5
  local -a states=($6 $8 ${10}) reasons=("$7" "$9" "${11}")
  local shown meta git_state i a bytes width
  _amd_width
  width=$REPLY

  AMD_KIND[$p]=$kind
  amd_show_path $p
  shown=${(V)REPLY}
  [[ -d $p || $kind == skills ]] && shown+=/
  print -r -- "${AMD_C[bold]}$shown${AMD_C[reset]}"
  amd_tilde $p
  [[ ${shown%/} != $REPLY ]] && print -r -- "${AMD_C[dim]}${(V)REPLY}${AMD_C[reset]}"

  meta="$AMD_SCOPE_TITLE[$scope] · $kind"
  if (( exists )); then
    if [[ -d $p ]]; then
      amd_detail $p
      meta+=" · $REPLY"
    else
      bytes=$(command wc -c < $p 2>/dev/null)
      bytes=${bytes//[^0-9]/}
      _amd_size ${bytes:-0}
      meta+=" · $REPLY"
    fi
    _amd_git_state $p
    git_state=$REPLY
    [[ -n $git_state ]] && meta+=" · $git_state in git"
  else
    meta+=' · not present'
  fi
  print -r -- "${AMD_C[dim]}$meta${AMD_C[reset]}"
  if [[ -L $p ]]; then
    print -r -- "${AMD_C[dim]}symlink to ${(V)${p:A}}${AMD_C[reset]}"
  fi
  if [[ $scope == local && $git_state == tracked ]]; then
    print -r -- "${AMD_C[red]}Tracked in git. This file is personal and is meant to stay uncommitted.${AMD_C[reset]}" | _amd_wrap 0
  elif [[ $scope == local && $git_state == untracked ]]; then
    print -r -- "${AMD_C[yellow]}Not ignored by git, so it could be committed by accident.${AMD_C[reset]}" | _amd_wrap 0
  fi
  print

  i=0
  for a in $AMD_AGENTS; do
    (( i++ ))
    amd_dot $states[i]
    if [[ $states[i] == - ]]; then
      print -r -- " ${AMD_C[dim]}  ${(r:12:)AMD_AGENT_NAME[$a]} $AMD_STATE_LABEL[-]${AMD_C[reset]}"
      continue
    fi
    print -r -- " $REPLY ${AMD_C[bold]}${(r:12:)AMD_AGENT_NAME[$a]}${AMD_C[reset]} $AMD_STATE_LABEL[$states[i]]"
    print -r -- "$reasons[i]" | _amd_wrap 3
  done

  print -r -- "${AMD_C[dim]}${(l:$(( width - 1 ))::─:):-}${AMD_C[reset]}"
  if (( ! exists )); then
    print -r -- "${AMD_C[dim]}Nothing here yet.${AMD_C[reset]}"
    return 0
  fi
  _amd_preview_content $kind $p
}

# How much of a file the pane reads.
typeset -g AMD_PREVIEW_BYTES=262144

_amd_preview_content() {
  emulate -L zsh
  setopt extendedglob
  local kind=$1 p=$2 name=${2:t} format=json lang=json

  if [[ -d $p ]]; then
    _amd_preview_dir $p
    return 0
  fi
  if [[ ! -f $p || ! -r $p ]]; then
    print -r -- "${AMD_C[dim]}Not a readable file.${AMD_C[reset]}"
    return 0
  fi
  if [[ $name == .claude.json ]]; then
    _amd_preview_claude_state $p
    return 0
  fi
  if [[ $kind == (instructions|skill) ]]; then
    command head -c $AMD_PREVIEW_BYTES -- $p | _amd_sanitize | _amd_highlight markdown
    return 0
  fi

  print -r -- "${AMD_C[dim]}Secret values are masked. Press enter to open the file itself.${AMD_C[reset]}" | _amd_wrap 0
  print
  case $name in
    *.toml) format=toml; lang=toml ;;
  esac
  if [[ $name == *.plist ]]; then
    if (( $+commands[plutil] && $+commands[jq] )); then
      command plutil -convert json -o - -- $p 2>/dev/null | command jq . 2>/dev/null \
        | _amd_sanitize | amd_redact json | _amd_highlight json
    else
      print -r -- "${AMD_C[dim]}plutil and jq are needed to show a managed preferences file.${AMD_C[reset]}"
    fi
  elif [[ $name == *.json ]] && (( $+commands[jq] )) && command jq -e . -- $p >/dev/null 2>&1; then
    # Pretty-print first so the line-based masking sees one key per line.
    command jq . -- $p | command head -c $AMD_PREVIEW_BYTES | _amd_sanitize | amd_redact json | _amd_highlight json
  else
    command head -c $AMD_PREVIEW_BYTES -- $p | _amd_sanitize | amd_redact $format | _amd_highlight $lang
  fi
}

# ~/.claude.json mixes MCP servers with sign-in and app state. Show only the
# MCP servers that apply here.
_amd_preview_claude_state() {
  emulate -L zsh
  local p=$1
  print -r -- "${AMD_C[dim]}Showing MCP servers only. The file also holds sign-in and app state, which is not displayed. Secret values are masked.${AMD_C[reset]}" | _amd_wrap 0
  print
  if (( ! $+commands[jq] )); then
    print -r -- "${AMD_C[dim]}jq is needed to read this file.${AMD_C[reset]}"
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
      }' -- $p 2>/dev/null | _amd_sanitize | amd_redact json | _amd_highlight json
}

_amd_preview_dir() {
  emulate -L zsh
  setopt extendedglob
  local p=$1 f l name desc n
  local -a found
  case ${p:t} in
    skills|skill)
      amd_skill_files $p
      found=($reply)
      if (( ${#found} == 0 )); then
        print -r -- "${AMD_C[dim]}No skills here.${AMD_C[reset]}"
        return 0
      fi
      for f in $found; do
        name=${f:h:t}
        desc=''
        n=0
        while IFS= read -r l || [[ -n $l ]]; do
          (( ++n > 40 )) && break
          if [[ $l == description:* ]]; then
            desc=${${l#description:}## #}
            # A folded or literal block puts the text on the next line.
            if [[ $desc == ('>'|'|')* ]]; then
              IFS= read -r desc
              desc=${desc## #}
            fi
            break
          fi
        done < $f
        desc=${${desc#[\"\']}%[\"\']}
        print -r -- " ${AMD_C[bold]}${(V)name}${AMD_C[reset]}"
        [[ -n $desc ]] && print -r -- "${AMD_C[dim]}${(V)desc[1,240]}${AMD_C[reset]}" | _amd_wrap 3
      done ;;
    rules)
      found=($p/**/*.md(N-.))
      for f in $found; do
        if command grep -Eq '^paths:' -- $f 2>/dev/null; then
          print -r -- " ${(V)f#$p/}  ${AMD_C[dim]}path-scoped${AMD_C[reset]}"
        else
          print -r -- " ${(V)f#$p/}  ${AMD_C[dim]}loads at launch${AMD_C[reset]}"
        fi
      done
      (( ${#found} )) || print -r -- "${AMD_C[dim]}No rule files here.${AMD_C[reset]}" ;;
    *)
      found=($p/*(N))
      for f in $found; do
        print -r -- " ${(V)f:t}"
      done
      (( ${#found} )) || print -r -- "${AMD_C[dim]}Empty directory.${AMD_C[reset]}" ;;
  esac
}
