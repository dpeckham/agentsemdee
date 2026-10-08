# render.bash: turn collected reports into rows for the viewer, a plain table,
# or tab-separated output.

declare -gA AMD_C=()

# amd_colors on|off
amd_colors() {
  if [[ $1 == on ]]; then
    AMD_C=([reset]=$'\e[0m' [bold]=$'\e[1m' [dim]=$'\e[2m'
           [green]=$'\e[32m' [yellow]=$'\e[33m' [cyan]=$'\e[36m' [red]=$'\e[31m')
  else
    AMD_C=([reset]='' [bold]='' [dim]='' [green]='' [yellow]='' [cyan]='' [red]='')
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

# amd_repeat COUNT TEXT -> REPLY is TEXT repeated COUNT times.
amd_repeat() {
  local n=$1
  printf -v REPLY '%*s' "$n" ''
  REPLY=${REPLY// /$2}
}

# _amd_display PATH -> REPLY is the list line: three markers, path, note.
_amd_display() {
  local p=$1 a dots='' shown detail
  for a in "${AMD_AGENTS[@]}"; do
    amd_dot "${AMD_STATE[$a:$p]:--}"
    dots+=" $REPLY"
  done
  if [[ -n ${AMD_LABEL[$p]+x} ]]; then
    # A nested row: indented under its folder, named by its label.
    amd_visible "${AMD_LABEL[$p]}"
    shown="  $REPLY"
    detail=${AMD_NOTE[$p]}
  else
    amd_show_path "$p"
    amd_visible "$REPLY"
    shown=$REPLY
    [[ -d $p || ${AMD_KIND[$p]} == skills ]] && shown+=/
    amd_detail "$p"
    detail=$REPLY
  fi
  if [[ ${AMD_EXISTS[$p]} == 1 ]]; then
    REPLY="$dots  $shown  ${AMD_C[dim]}$detail${AMD_C[reset]}"
  else
    REPLY="$dots  ${AMD_C[dim]}$shown  $detail${AMD_C[reset]}"
  fi
}

# _amd_section SCOPE -> REPLY is the divider line that opens a scope.
_amd_section() {
  local title=${AMD_SCOPE_TITLE[$1]}
  local fill=$(( 44 - ${#title} ))
  (( fill < 3 )) && fill=3
  amd_repeat $fill ─
  REPLY=" ${AMD_C[bold]}── $title $REPLY${AMD_C[reset]}"
}

# amd_agent_legend [short] -> REPLY names each column with its detected
# version. The short form fits the viewer's narrow list pane.
amd_agent_legend() {
  local a out='' v name
  for a in "${AMD_AGENTS[@]}"; do
    v=${AMD_VER[$a]}
    name=${AMD_AGENT_NAME[$a]}
    if [[ ${1:-} == short ]]; then
      name=${AMD_AGENT_SHORT[$a]}
      [[ -n $v ]] || v='absent'
    else
      [[ -n $v ]] || v='not installed'
    fi
    out+="${a^^} $name $v  "
  done
  REPLY=${out%  }
}

# amd_emit MODE ALL
#   rows   tab-separated lines for the viewer; the last field is what it shows
#   plain  the table as text
#   tsv    one line per file, for scripts
# Row fields: type scope kind path exists, then state and reason per agent.
amd_emit() {
  local mode=$1 all=$2 scope p a line fields T=$'\t'
  local -a paths rows parts

  case $mode in
    rows)
      amd_say "T${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T} ${AMD_C[bold]}C X O${AMD_C[reset]}" ;;
    plain)
      amd_tilde "$AMD_CWD"
      amd_say "${AMD_C[bold]}agentsemdee${AMD_C[reset]}  $REPLY"
      amd_agent_legend
      amd_say "${AMD_C[dim]}$REPLY${AMD_C[reset]}" ''
      amd_say " ${AMD_C[bold]}C X O${AMD_C[reset]}" ;;
    tsv)
      amd_say "scope${T}kind${T}path${T}exists${T}claude${T}claude_reason${T}codex${T}codex_reason${T}opencode${T}opencode_reason" ;;
  esac

  for scope in "${AMD_SCOPES[@]}"; do
    amd_scope_paths "$scope" "$all"
    paths=("${reply[@]}")
    # "Above the project" is only worth a heading when something is in it.
    [[ $scope == above && ${#paths[@]} -eq 0 ]] && continue
    if [[ $mode != tsv ]]; then
      _amd_section "$scope"
      if [[ $mode == rows ]]; then
        amd_say "H${T}${scope}${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}$REPLY"
      else
        amd_say "$REPLY"
      fi
      if (( ${#paths[@]} == 0 )); then
        line="        ${AMD_C[dim]}none${AMD_C[reset]}"
        if [[ $mode == rows ]]; then
          amd_say "N${T}${scope}${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}-${T}$line"
        else
          amd_say "$line"
        fi
      fi
    fi
    # Each listed path is followed by its nested rows, if it has any.
    rows=()
    for p in "${paths[@]}"; do
      rows+=("$p")
      amd_split "${AMD_CHILDREN[$p]:-}" "$AMD_SEP"
      rows+=("${reply[@]}")
    done
    for p in "${rows[@]}"; do
      parts=()
      for a in "${AMD_AGENTS[@]}"; do
        parts+=("${AMD_STATE[$a:$p]:--}" "${AMD_REASON[$a:$p]:--}")
      done
      amd_join "$T" "${parts[@]}"
      fields=$REPLY
      case $mode in
        tsv)
          amd_say "${scope}${T}${AMD_KIND[$p]}${T}${p}${T}${AMD_EXISTS[$p]}${T}${fields}" ;;
        rows)
          _amd_display "$p"
          amd_say "F${T}${scope}${T}${AMD_KIND[$p]}${T}${p}${T}${AMD_EXISTS[$p]}${T}${fields}${T}$REPLY" ;;
        plain)
          _amd_display "$p"
          amd_say "$REPLY" ;;
      esac
    done
  done

  if [[ $mode == plain ]]; then
    amd_say ''
    amd_dot loaded;  line=" $REPLY loaded"
    amd_dot skipped; line+="   $REPLY present, not loaded"
    if [[ $all == 1 ]]; then
      amd_dot missing
      line+="   $REPLY read if created"
    fi
    amd_say "$line"
    amd_say " ${AMD_C[dim]}Lower rows win. Managed is the exception: it cannot be overridden.${AMD_C[reset]}"
  fi
}
