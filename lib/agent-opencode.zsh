# agent-opencode.zsh: what OpenCode reads for the inspected directory.
#
# OpenCode 1.x and 2.x discover files differently, so there are two rule
# sets. The 1.x rules follow opencode.ai/docs and the instruction loader in
# the 1.x source. The 2.x rules follow the discovery code shipped in the
# OpenCode 2.0.20 binary. Without an installed OpenCode, the 1.x rules apply.

amd_agent_opencode() {
  emulate -L zsh
  setopt extendedglob
  local ver=$AMD_VER[o]
  if [[ -n $ver ]] && amd_ver_ge $ver 2.0.0; then
    _amd_opencode_v2
  else
    _amd_opencode_v1
  fi
}

# Rows shared by both generations: the global config directory.
# Sets "g" (global config dir) in the caller.
_amd_opencode_global() {
  g=${${XDG_CONFIG_HOME:-$AMD_HOME/.config}:A}/opencode
  local want_slot=1
  [[ -e $g/opencode.jsonc ]] && want_slot=0
  amd_report o user settings $g/opencode.json loaded \
    'Your config for every project, including MCP servers under the mcp key. Project config overrides it, and non-conflicting keys merge.' $want_slot
  amd_report o user settings $g/opencode.jsonc loaded \
    'Your config for every project, including MCP servers under the mcp key. Project config overrides it, and non-conflicting keys merge.'
  amd_report o user instructions $g/AGENTS.md loaded \
    'Your instructions for every project. Combined with the project instructions.' 1
  local s
  for s in skills skill; do
    amd_report o user skills $g/$s loaded 'Your personal OpenCode skills.'
  done
}

_amd_opencode_v2() {
  emulate -L zsh
  setopt extendedglob
  local a=o g d f s scope slot
  _amd_opencode_global

  amd_report $a user skills $AMD_HOME/.claude/skills loaded \
    'Read for compatibility. OpenCode also loads skills written for Claude Code.'
  amd_report $a user skills $AMD_HOME/.agents/skills loaded \
    'Read for compatibility. OpenCode also loads skills from the shared .agents directory.' 1

  # Instructions: every AGENTS.md from the working directory up to the home
  # directory when the project sits under it, otherwise up to the project.
  local stop=$AMD_PROJECT_ROOT inside=0
  [[ $AMD_CWD == $AMD_HOME || $AMD_CWD == $AMD_HOME/* ]] && stop=$AMD_HOME
  local stop_shown
  amd_tilde $stop
  stop_shown=$REPLY
  for d in $AMD_CHAIN; do
    [[ $d == $stop ]] && inside=1
    (( inside )) || continue
    [[ $d/AGENTS.md == $g/AGENTS.md ]] && continue
    amd_dir_scope $d
    scope=$REPLY
    slot=0; [[ $d == $AMD_CWD || $d == $AMD_PROJECT_ROOT ]] && slot=1
    amd_report $a $scope instructions $d/AGENTS.md loaded \
      "Loaded. OpenCode 2 reads every AGENTS.md from the working directory up to $stop_shown, together with the global one." $slot
  done

  # Config and skills: every directory from the filesystem root down.
  for d in $AMD_CHAIN; do
    amd_dir_scope $d
    scope=$REPLY
    slot=0
    [[ $d == $AMD_PROJECT_ROOT && ! -e $d/opencode.jsonc ]] && slot=1
    for f in opencode.json opencode.jsonc; do
      [[ $d/$f == $g/$f ]] && continue
      s=0; [[ $f == opencode.json ]] && s=$slot
      amd_report $a $scope settings $d/$f loaded \
        'Project config, including MCP servers under the mcp key. Files merge from the outermost directory inward, so the one closest to the working directory wins.' $s
    done
    [[ $d/.opencode == $g ]] && continue
    for f in opencode.json opencode.jsonc; do
      amd_report $a $scope settings $d/.opencode/$f loaded \
        'Project config inside the .opencode directory. Merged after the config file beside it.'
    done
    for s in skills skill; do
      amd_report $a $scope skills $d/.opencode/$s loaded 'Project skills for OpenCode.'
    done
    [[ $d/.claude == $AMD_HOME/.claude ]] || amd_report $a $scope skills $d/.claude/skills loaded \
      'Read for compatibility. OpenCode also loads skills written for Claude Code.'
    [[ $d/.agents == $AMD_HOME/.agents ]] || amd_report $a $scope skills $d/.agents/skills loaded \
      'Read for compatibility. OpenCode also loads skills from the shared .agents directory.'
  done
}

_amd_opencode_v1() {
  emulate -L zsh
  setopt extendedglob
  local a=o g d f s scope slot reason
  local compat=1 compat_prompt=1 compat_skills=1
  [[ -n ${OPENCODE_DISABLE_CLAUDE_CODE:-} ]] && compat=0
  (( compat )) || { compat_prompt=0; compat_skills=0 }
  [[ -n ${OPENCODE_DISABLE_CLAUDE_CODE_PROMPT:-} ]] && compat_prompt=0
  [[ -n ${OPENCODE_DISABLE_CLAUDE_CODE_SKILLS:-} ]] && compat_skills=0

  # ---- Managed -----------------------------------------------------------
  local mdir=$AMD_SYSROOT/etc/opencode
  [[ $OSTYPE == darwin* ]] && mdir="$AMD_SYSROOT/Library/Application Support/opencode"
  amd_report $a managed settings $mdir/opencode.json loaded \
    'Managed config. Loaded last, so it overrides global and project config.' 1
  amd_report $a managed settings $mdir/opencode.jsonc loaded \
    'Managed config. Loaded last, so it overrides global and project config.'

  # ---- User global -------------------------------------------------------
  _amd_opencode_global
  local claude_md=$AMD_HOME/.claude/CLAUDE.md
  if (( ! compat_prompt )); then
    amd_report $a user instructions $claude_md skipped \
      'Claude Code compatibility is switched off by an OPENCODE_DISABLE_CLAUDE_CODE variable.'
  elif [[ -e $g/AGENTS.md ]]; then
    amd_report $a user instructions $claude_md skipped \
      'OpenCode uses the first global instruction file it finds, and its own global AGENTS.md comes first.'
  else
    amd_report $a user instructions $claude_md loaded \
      'Loaded as a fallback, because OpenCode has no global AGENTS.md of its own.'
  fi
  if (( compat_skills )); then
    amd_report $a user skills $AMD_HOME/.claude/skills loaded \
      'Read for compatibility. OpenCode also loads skills written for Claude Code.'
  else
    amd_report $a user skills $AMD_HOME/.claude/skills skipped \
      'Claude Code compatibility is switched off by an OPENCODE_DISABLE_CLAUDE_CODE variable.'
  fi
  amd_report $a user skills $AMD_HOME/.agents/skills loaded \
    'Read for compatibility. OpenCode also loads skills from the shared .agents directory.' 1

  # ---- Project: from the worktree root down to the working directory ------
  # Outside a git repository OpenCode 1.x treats the filesystem root as the
  # worktree, so the walk covers every ancestor.
  local stop=${AMD_GIT_ROOT:-/} inside=0
  local -a dirs
  for d in $AMD_CHAIN; do
    [[ $d == $stop ]] && inside=1
    (( inside )) && dirs+=($d)
  done

  # The first file name with any match wins, and every match of it loads.
  local -a names=(AGENTS.md)
  (( compat_prompt )) && names+=(CLAUDE.md)
  names+=(CONTEXT.md)
  local winner=''
  for f in $names; do
    for d in $dirs; do
      if [[ -e $d/$f ]]; then
        winner=$f
        break 2
      fi
    done
  done
  for d in $dirs; do
    amd_dir_scope $d
    scope=$REPLY
    slot=0; [[ $d == $AMD_CWD || $d == $AMD_PROJECT_ROOT ]] && slot=1
    for f in AGENTS.md CLAUDE.md CONTEXT.md; do
      if [[ $f == CLAUDE.md ]] && (( ! compat_prompt )); then
        amd_report $a $scope instructions $d/$f skipped \
          'Claude Code compatibility is switched off by an OPENCODE_DISABLE_CLAUDE_CODE variable.'
      elif [[ $f == $winner || ( -z $winner && $f == AGENTS.md ) ]]; then
        reason='Loaded. OpenCode reads every AGENTS.md from the working directory up to the worktree root.'
        [[ $f == CLAUDE.md ]] && reason='Loaded as a fallback, because no AGENTS.md exists between the working directory and the worktree root.'
        [[ $f == CONTEXT.md ]] && reason='Loaded as a deprecated fallback, because no AGENTS.md or CLAUDE.md exists on the path.'
        if [[ $f == AGENTS.md ]]; then
          amd_report $a $scope instructions $d/$f loaded $reason $slot
        else
          amd_report $a $scope instructions $d/$f loaded $reason
        fi
      else
        amd_report $a $scope instructions $d/$f skipped \
          "OpenCode uses the first instruction file name it finds, and $winner exists on the path, so $f is ignored."
      fi
    done
  done

  for d in $dirs; do
    amd_dir_scope $d
    scope=$REPLY
    slot=0
    [[ $d == $AMD_PROJECT_ROOT && ! -e $d/opencode.jsonc ]] && slot=1
    if [[ $d/opencode.json != $g/opencode.json ]]; then
      amd_report $a $scope settings $d/opencode.json loaded \
        'Project config, including MCP servers under the mcp key. Overrides your global config.' $slot
      amd_report $a $scope settings $d/opencode.jsonc loaded \
        'Project config, including MCP servers under the mcp key. Overrides your global config.'
    fi
    [[ $d/.opencode == $g ]] && continue
    for f in opencode.json opencode.jsonc; do
      amd_report $a $scope settings $d/.opencode/$f loaded \
        'Project config inside the .opencode directory. Loaded after the project config file.'
    done
    for s in skills skill; do
      amd_report $a $scope skills $d/.opencode/$s loaded 'Project skills for OpenCode.'
    done
    if [[ $d/.claude != $AMD_HOME/.claude ]]; then
      if (( compat_skills )); then
        amd_report $a $scope skills $d/.claude/skills loaded \
          'Read for compatibility. OpenCode also loads skills written for Claude Code.'
      else
        amd_report $a $scope skills $d/.claude/skills skipped \
          'Claude Code compatibility is switched off by an OPENCODE_DISABLE_CLAUDE_CODE variable.'
      fi
    fi
    [[ $d/.agents == $AMD_HOME/.agents ]] || amd_report $a $scope skills $d/.agents/skills loaded \
      'Read for compatibility. OpenCode also loads skills from the shared .agents directory.'
  done
}
