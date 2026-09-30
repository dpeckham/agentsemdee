# render.zsh: turn collected reports into rows for the viewer, a plain table,
# or tab-separated output.

typeset -gA AMD_C

# amd_colors on|off
amd_colors() {
  if [[ $1 == on ]]; then
    AMD_C=(reset $'\e[0m' bold $'\e[1m' dim $'\e[2m'
           green $'\e[32m' yellow $'\e[33m' cyan $'\e[36m' red $'\e[31m')
  else
    AMD_C=(reset '' bold '' dim '' green '' yellow '' cyan '' red '')
  fi
}

# amd_dot STATE -> REPLY is the one-cell marker for an agent column.
amd_dot() {
  case $1 in
    loaded)  REPLY="${AMD_C[green]}●${AMD_C[reset]}" ;;
    skipped) REPLY="${AMD_C[yellow]}○${AMD_C[reset]}" ;;
    missing) REPLY="${AMD_C[dim]}·${AMD_C[reset]}" ;;
    *)       REPLY=' ' ;;
  esac
}

# _amd_display PATH -> REPLY is the list line: three markers, path, note.
_amd_display() {
  emulate -L zsh
  local p=$1 a dots='' shown detail
  for a in $AMD_AGENTS; do
    amd_dot ${AMD_STATE[$a:$p]:--}
    dots+=" $REPLY"
  done
  if (( ${+AMD_LABEL[$p]} )); then
    # A nested row: indented under its folder, named by its label.
    shown="  ${(V)AMD_LABEL[$p]}"
    detail=$AMD_NOTE[$p]
  else
    amd_show_path $p
    shown=${(V)REPLY}
    [[ -d $p || $AMD_KIND[$p] == skills ]] && shown+=/
    amd_detail $p
    detail=$REPLY
  fi
  if (( AMD_EXISTS[$p] )); then
    REPLY="$dots  $shown  ${AMD_C[dim]}$detail${AMD_C[reset]}"
  else
    REPLY="$dots  ${AMD_C[dim]}$shown  $detail${AMD_C[reset]}"
  fi
}

# _amd_section SCOPE -> REPLY is the divider line that opens a scope.
_amd_section() {
  local title=$AMD_SCOPE_TITLE[$1]
  local fill=$(( 44 - ${#title} ))
  (( fill < 3 )) && fill=3
  REPLY=" ${AMD_C[bold]}── $title ${(l:$fill::─:):-}${AMD_C[reset]}"
}

# amd_agent_legend [short] -> REPLY names each column with its detected
# version. The short form fits the viewer's narrow list pane.
amd_agent_legend() {
  emulate -L zsh
  local a out='' v name
  for a in $AMD_AGENTS; do
    v=$AMD_VER[$a]
    name=$AMD_AGENT_NAME[$a]
    if [[ ${1:-} == short ]]; then
      name=$AMD_AGENT_SHORT[$a]
      [[ -n $v ]] || v='absent'
    else
      [[ -n $v ]] || v='not installed'
    fi
    out+="${(U)a} $name $v  "
  done
  REPLY=${out%  }
}

# amd_emit MODE ALL
#   rows   tab-separated lines for the viewer; the last field is what it shows
#   plain  the table as text
#   tsv    one line per file, for scripts
# Row fields: type scope kind path exists, then state and reason per agent.
amd_emit() {
  emulate -L zsh
  local mode=$1 all=$2 scope p a line T=$'\t'
  local -a fields rows

  case $mode in
    rows)
      print -r -- "T${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T} ${AMD_C[bold]}C X O${AMD_C[reset]}" ;;
    plain)
      amd_tilde $AMD_CWD
      print -r -- "${AMD_C[bold]}agentsemdee${AMD_C[reset]}  $REPLY"
      amd_agent_legend
      print -r -- "${AMD_C[dim]}$REPLY${AMD_C[reset]}"
      print
      print -r -- " ${AMD_C[bold]}C X O${AMD_C[reset]}" ;;
    tsv)
      print -r -- "scope${T}kind${T}path${T}exists${T}claude${T}claude_reason${T}codex${T}codex_reason${T}opencode${T}opencode_reason" ;;
  esac

  for scope in $AMD_SCOPES; do
    amd_scope_paths $scope $all
    # "Above the project" is only worth a heading when something is in it.
    [[ $scope == above && ${#reply} -eq 0 ]] && continue
    if [[ $mode != tsv ]]; then
      _amd_section $scope
      if [[ $mode == rows ]]; then
        print -r -- "H${T}${scope}${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}$REPLY"
      else
        print -r -- "$REPLY"
      fi
      if (( ${#reply} == 0 )); then
        line="        ${AMD_C[dim]}none${AMD_C[reset]}"
        if [[ $mode == rows ]]; then
          print -r -- "N${T}${scope}${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}$line"
        else
          print -r -- "$line"
        fi
      fi
    fi
    # Each listed path is followed by its nested rows, if it has any.
    rows=()
    for p in $reply; do
      rows+=($p ${(ps:\0:)AMD_CHILDREN[$p]:-})
    done
    for p in $rows; do
      fields=()
      for a in $AMD_AGENTS; do
        fields+=("${AMD_STATE[$a:$p]:--}" "${AMD_REASON[$a:$p]:--}")
      done
      case $mode in
        tsv)
          print -r -- "${scope}${T}${AMD_KIND[$p]}${T}${p}${T}${AMD_EXISTS[$p]}${T}${(pj:\t:)fields}" ;;
        rows)
          _amd_display $p
          print -r -- "F${T}${scope}${T}${AMD_KIND[$p]}${T}${p}${T}${AMD_EXISTS[$p]}${T}${(pj:\t:)fields}${T}$REPLY" ;;
        plain)
          _amd_display $p
          print -r -- "$REPLY" ;;
      esac
    done
  done

  if [[ $mode == plain ]]; then
    print
    amd_dot loaded;  line=" $REPLY loaded"
    amd_dot skipped; line+="   $REPLY present, not loaded"
    (( all )) && { amd_dot missing; line+="   $REPLY read if created" }
    print -r -- "$line"
    print -r -- " ${AMD_C[dim]}Lower rows win. Managed is the exception: it cannot be overridden.${AMD_C[reset]}"
  fi
}
