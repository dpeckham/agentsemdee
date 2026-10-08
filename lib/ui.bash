# ui.bash: the interactive viewer, built on fzf.
#
# fzf owns the screen: the list on the left, the preview pane on the right,
# filtering, and scrolling. This file only wires rows and key bindings to it.

declare -g AMD_FZF_MIN=0.63.0

# amd_ui ALL: open the viewer. ALL=1 starts with empty slots shown.
amd_ui() {
  local all=$1 have re='[0-9]+\.[0-9]+\.[0-9]+'
  if ! amd_have fzf; then
    amd_say "agentsemdee: the viewer needs fzf. Run 'mise install' in $AMD_ROOT, or use --plain." >&2
    return 1
  fi
  have=$(command fzf --version 2>/dev/null)
  [[ $have =~ $re ]] && have=${BASH_REMATCH[0]}
  if ! amd_ver_ge "$have" $AMD_FZF_MIN; then
    amd_say "agentsemdee: fzf $have is too old, $AMD_FZF_MIN or newer is needed. Run 'mise install' in $AMD_ROOT, or use --plain." >&2
    return 1
  fi

  export AGENTSEMDEE_SELF=$AMD_SELF
  export AGENTSEMDEE_DIR=$AMD_CWD

  amd_colors on
  amd_collect

  local label footer prompt='> ' d1 d2 d3
  amd_tilde "$AMD_CWD"
  amd_visible "$REPLY"
  label=" agentsemdee  $REPLY "
  amd_dot loaded;  d1=$REPLY
  amd_dot skipped; d2=$REPLY
  amd_dot missing; d3=$REPLY
  # Each footer line stays under 56 columns so it fits the list pane.
  amd_agent_legend short
  footer=" $d1 loaded   $d2 present, not loaded   $d3 read if created"$'\n'
  footer+=" $REPLY"$'\n'
  footer+=" ${AMD_C[dim]}lower rows win · enter open · ctrl-a empty slots"$'\n'
  footer+=" pgup/pgdn scroll preview · esc quit${AMD_C[reset]}"
  [[ $all == 1 ]] && prompt='all> '

  # The user's own fzf defaults could change the layout or add bindings.
  # shellcheck disable=SC2016 # fzf expands these variables, not this shell.
  amd_emit rows "$all" | FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' command fzf \
    --ansi --no-sort --no-multi --layout=reverse --cycle --gutter=' ' \
    --delimiter=$'\t' --with-nth=12 --header-lines=1 \
    --border=rounded --border-label="$label" --border-label-pos=3 \
    --prompt="$prompt" --info=inline-right \
    --footer="$footer" \
    --preview='"$AGENTSEMDEE_SELF" --preview {}' \
    --preview-window='right,60%,wrap-word,border-left,<60(down,55%,wrap-word,border-top)' \
    --bind='enter:execute("$AGENTSEMDEE_SELF" --open {4})' \
    --bind='ctrl-a:transform("$AGENTSEMDEE_SELF" --toggle-all)' \
    --bind='pgdn:preview-page-down,pgup:preview-page-up' \
    >/dev/null
  local rc=$?
  # 130 is fzf's exit code for esc and ctrl-c, and 1 means nothing matched.
  (( rc == 130 || rc == 1 )) && rc=0
  return $rc
}

# amd_toggle_all: print the fzf actions that flip the empty-slot view. The
# prompt doubles as the state, which fzf exposes as FZF_PROMPT.
amd_toggle_all() {
  # shellcheck disable=SC2016 # fzf expands AGENTSEMDEE_SELF.
  if [[ ${FZF_PROMPT:-} == all* ]]; then
    amd_say 'change-prompt[> ]+reload("$AGENTSEMDEE_SELF" --rows)'
  else
    amd_say 'change-prompt[all> ]+reload("$AGENTSEMDEE_SELF" --rows --all)'
  fi
}

# amd_open PATH: hand an existing file or directory to the user's editor.
# Without an editor configured, fall back to a pager so nothing is changed.
amd_open() {
  local p=$1
  local -a ed pager
  [[ -n $p && $p == /* && -e $p ]] || return 0
  read -ra ed <<< "${VISUAL:-${EDITOR:-}}"
  read -ra pager <<< "${PAGER:-less}"
  (( ${#pager[@]} )) || pager=(less)
  if (( ${#ed[@]} )) && amd_have "${ed[0]}"; then
    "${ed[@]}" "$p"
  elif [[ -d $p ]]; then
    command ls -la -- "$p" | "${pager[@]}"
  else
    "${pager[@]}" "$p"
  fi
}
