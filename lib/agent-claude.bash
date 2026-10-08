# agent-claude.bash: what Claude Code reads for the inspected directory.
#
# Sources: code.claude.com/docs (memory, settings, managed-settings, skills,
# mcp) and the behavior of Claude Code 2.1.285. Version gates below name the
# release that introduced each rule.

# _amd_glob_match PATH PATTERN: match a settings glob against a path. Only
# "*" and "?" keep their meaning. Every other character is literal, because
# the patterns can come from a repository the user has not reviewed.
_amd_glob_match() {
  local s=$2 pat='' c i
  for (( i = 0; i < ${#s}; i++ )); do
    c=${s:i:1}
    case $c in
      '*'|'?') pat+=$c ;;
      *)       pat+="\\$c" ;;
    esac
  done
  # shellcheck disable=SC2053 # pat is a pattern on purpose.
  [[ $1 == $pat ]]
}

amd_agent_claude() {
  local a=c ver=${AMD_VER[c]}
  local cfg statefile mdir plist=''
  if [[ -n ${CLAUDE_CONFIG_DIR:-} ]]; then
    amd_realpath "$CLAUDE_CONFIG_DIR"
    cfg=$REPLY
    statefile=$cfg/.claude.json
  else
    cfg=$AMD_HOME/.claude
    statefile=$AMD_HOME/.claude.json
  fi
  if [[ $OSTYPE == darwin* ]]; then
    mdir="$AMD_SYSROOT/Library/Application Support/ClaudeCode"
    plist="$AMD_SYSROOT/Library/Managed Preferences/com.anthropic.claudecode.plist"
  else
    mdir=$AMD_SYSROOT/etc/claude-code
  fi

  # Version gates. An unknown version is treated as current.
  local agents_native=1 local_at_root=1
  if [[ -n $ver ]]; then
    amd_ver_ge "$ver" 2.1.277 || agents_native=0
    amd_ver_ge "$ver" 2.1.211 || local_at_root=0
  fi

  # Where the personal project settings file lives. Inside a git repository it
  # sits at the main checkout's root, unless that root is the home directory
  # or is not owned by this user.
  local localfile=$AMD_CWD/.claude/settings.local.json local_at=cwd
  if (( local_at_root )) && [[ -n $AMD_MAIN_ROOT && $AMD_MAIN_ROOT != "$AMD_HOME" ]] \
     && [[ -O $AMD_MAIN_ROOT && -O $AMD_MAIN_ROOT/.git ]] \
     && [[ ! -e $AMD_MAIN_ROOT/.claude || -O $AMD_MAIN_ROOT/.claude ]]; then
    localfile=$AMD_MAIN_ROOT/.claude/settings.local.json
    local_at=root
  fi

  # The "Project instructions" setting. Project and local files cannot set it.
  local mode=claude-md-or-agents-md v f
  local q='.pluginConfigs["agents-md@builtin"].options.instructionFiles // empty'
  for f in "$cfg/settings.json" "$mdir/managed-settings.json"; do
    v=$(amd_json_get "$f" "$q")
    [[ -n $v ]] && mode=$v
  done

  local -a excludes=()
  local line
  for f in "$mdir/managed-settings.json" "$cfg/settings.json" \
           "$AMD_CWD/.claude/settings.json" "$localfile"; do
    while IFS= read -r line; do
      [[ -n $line ]] && excludes+=("$line")
    done < <(amd_json_get "$f" '.claudeMdExcludes[]? // empty')
  done

  # ---- Managed -----------------------------------------------------------
  amd_report $a managed settings "$mdir/managed-settings.json" loaded \
    'Locked organization policy. Nothing in user, project, or local settings overrides it.' 1
  amd_report $a managed settings "$mdir/managed-settings.d" loaded \
    'Drop-in policy files, merged with managed-settings.json.'
  [[ -n $plist ]] && amd_report $a managed settings "$plist" loaded \
    'Device-management profile. Takes priority over the managed settings files.'
  amd_report $a managed mcp "$mdir/managed-mcp.json" loaded \
    'A fixed set of MCP servers deployed by your organization.'
  local managed_md='Organization instructions. Loaded first in every session and cannot be excluded.'
  amd_report $a managed instructions "$mdir/CLAUDE.md" loaded "$managed_md" 1
  amd_report $a managed skills "$mdir/.claude/skills" loaded \
    'Organization skills. They win over personal and project skills of the same name.'
  declare -g AMD_CLAUDE_MANAGED_SKILLS=$mdir/.claude/skills
  declare -g AMD_CLAUDE_USER_SKILLS=$cfg/skills

  # ---- User global -------------------------------------------------------
  amd_report $a user settings "$cfg/settings.json" loaded \
    'Your settings for every project. Lowest precedence: shared project, local, and managed files override it key by key, while list values such as permission rules merge.' 1
  if [[ $mode == managed-only ]]; then
    amd_report $a user instructions "$cfg/CLAUDE.md" skipped \
      'Project instructions is set to managed-only, so only organization instructions load.' 1
  else
    amd_report $a user instructions "$cfg/CLAUDE.md" loaded \
      'Your instructions for every project. Loaded before project instructions.' 1
  fi
  amd_report $a user instructions "$cfg/rules" loaded \
    'Your personal rules. Loaded before project rules.'
  amd_report $a user skills "$cfg/skills" loaded \
    'Your personal skills, available in every project. They win over project skills of the same name.' 1
  amd_report $a user mcp "$statefile" loaded \
    'Written by Claude Code. Holds your user-scope MCP servers and the local-scope servers for each project, next to sign-in and app state.' 1

  # ---- Instruction files along the directory chain ------------------------
  # Any Claude instruction file on the path stops AGENTS.md from loading. The
  # user-level file does not count.
  local blocker='' d i
  for (( i = ${#AMD_CHAIN[@]} - 1; i >= 0 && ${#blocker} == 0; i-- )); do
    d=${AMD_CHAIN[i]}
    for f in "$d/CLAUDE.md" "$d/.claude/CLAUDE.md" "$d/CLAUDE.local.md"; do
      [[ $f == "$cfg/CLAUDE.md" ]] && continue
      if [[ -e $f ]]; then
        blocker=$f
        break
      fi
    done
  done
  local blocker_shown=''
  if [[ -n $blocker ]]; then
    amd_show_path "$blocker"
    blocker_shown=$REPLY
  fi

  local scope lscope state reason pat at_cwd at_edge
  for d in "${AMD_CHAIN[@]}"; do
    amd_dir_scope "$d"
    scope=$REPLY
    lscope=$scope
    [[ $scope == project ]] && lscope=local
    at_cwd=0; [[ $d == "$AMD_CWD" ]] && at_cwd=1
    at_edge=$at_cwd; [[ $d == "$AMD_PROJECT_ROOT" ]] && at_edge=1

    for f in "$d/CLAUDE.md" "$d/.claude/CLAUDE.md" "$d/CLAUDE.local.md"; do
      [[ $f == "$cfg/CLAUDE.md" ]] && continue
      state=loaded
      reason='Loaded at launch. Instruction files concatenate from the filesystem root down to the working directory, so files closer to it are read last.'
      if [[ $f == */CLAUDE.local.md ]]; then
        reason='Your private instructions for this directory. Loaded right after the CLAUDE.md beside it.'
      fi
      if [[ $mode == managed-only ]]; then
        state=skipped
        reason='Project instructions is set to managed-only, so only organization instructions load.'
      else
        for pat in "${excludes[@]}"; do
          if _amd_glob_match "$f" "$pat"; then
            state=skipped
            reason="Excluded by the claudeMdExcludes pattern \"$pat\" in settings."
            break
          fi
        done
      fi
      case $f in
        */.claude/CLAUDE.md) amd_report $a "$scope" instructions "$f" $state "$reason" ;;
        */CLAUDE.local.md)   amd_report $a "$lscope" instructions "$f" $state "$reason" $at_cwd ;;
        *)                   amd_report $a "$scope" instructions "$f" $state "$reason" $at_cwd ;;
      esac
    done

    if [[ $d/.claude/rules != "$cfg/rules" ]]; then
      if [[ $mode == managed-only ]]; then
        amd_report $a "$scope" instructions "$d/.claude/rules" skipped \
          'Project instructions is set to managed-only, so launch-time rules do not load.'
      else
        amd_report $a "$scope" instructions "$d/.claude/rules" loaded \
          'Project rules. Rules without a paths field load at launch. Path-scoped rules load when Claude reads a matching file.'
      fi
    fi

    for f in "$d/AGENTS.md" "$d/.claude/AGENTS.md"; do
      state=loaded
      if (( ! agents_native )); then
        state=skipped
        reason="Claude Code $ver predates native AGENTS.md support, which arrived in 2.1.277."
        if [[ -e $d/CLAUDE.md && $f -ef $d/CLAUDE.md ]]; then
          state=loaded
          reason='Read through the CLAUDE.md symlink in the same directory.'
        elif _amd_claude_imports "$d" "$f"; then
          state=loaded
          reason='Imported by the CLAUDE.md in the same directory.'
        fi
      elif [[ $mode == managed-only ]]; then
        state=skipped
        reason='Project instructions is set to managed-only, so only organization instructions load.'
      elif [[ -e $d/CLAUDE.md && $f -ef $d/CLAUDE.md ]]; then
        reason='Read through the CLAUDE.md symlink in the same directory. The content loads once.'
      elif _amd_claude_imports "$d" "$f"; then
        reason='Imported by the CLAUDE.md in the same directory, so it loads as part of that file.'
      elif [[ $mode == claude-md-and-agents-md ]]; then
        reason='Project instructions is set to load AGENTS.md alongside CLAUDE.md. It is read after the CLAUDE.md files in the same directory.'
      elif [[ $mode == claude-md ]]; then
        state=skipped
        reason='Project instructions is set to claude-md, so AGENTS.md is never read.'
      elif [[ -n $blocker ]]; then
        state=skipped
        reason="A Claude instruction file is on the path ($blocker_shown), so AGENTS.md is not read. Import it from CLAUDE.md, or set Project instructions to claude-md-and-agents-md, to load both."
      else
        reason='Loaded because no CLAUDE.md or CLAUDE.local.md exists in this directory or above it.'
      fi
      if [[ $f == */.claude/AGENTS.md ]]; then
        amd_report $a "$scope" instructions "$f" $state "$reason"
      else
        amd_report $a "$scope" instructions "$f" $state "$reason" $at_edge
      fi
    done

    amd_report $a "$scope" mcp "$d/.mcp.json" loaded \
      'Project-scoped MCP servers. Each server needs your approval before first use. Where two files define the same server name, the one closer to the working directory wins.' $at_cwd
  done

  # ---- Settings ----------------------------------------------------------
  if [[ $AMD_CWD/.claude != "$cfg" ]]; then
    amd_report $a project settings "$AMD_CWD/.claude/settings.json" loaded \
      'Shared project settings, read from the directory Claude starts in. Overrides your user settings. A few security-sensitive keys are ignored when set here.' 1
  fi
  for d in "${AMD_CHAIN[@]}"; do
    [[ $d == "$AMD_CWD" || $d/.claude == "$cfg" ]] && continue
    amd_dir_scope "$d"
    [[ $REPLY == project ]] || continue
    amd_report $a project settings "$d/.claude/settings.json" skipped \
      'Not read from here. Claude reads shared settings only from the directory it starts in, so start Claude in this directory to use the file.'
  done

  reason='Your personal settings for this project. Overrides the shared project settings. Approvals you save with "don'\''t ask again" land here.'
  if [[ $local_at == root && $localfile != "$AMD_CWD/.claude/settings.local.json" ]]; then
    reason+=' Kept at the repository root'
    [[ $AMD_MAIN_ROOT != "$AMD_GIT_ROOT" ]] && reason+=' of the main checkout, because this is a linked worktree'
    reason+=', so it applies across the whole repository.'
  fi
  amd_report $a local settings "$localfile" loaded "$reason" 1
  if [[ $localfile != "$AMD_CWD/.claude/settings.local.json" ]]; then
    amd_report $a local settings "$AMD_CWD/.claude/settings.local.json" loaded \
      'Older location, still read. Where both files set the same key the repository-root file wins, and permission rules from both apply.'
  fi

  # ---- Skills ------------------------------------------------------------
  # From the starting directory up to the root of the current checkout.
  local stop=${AMD_GIT_ROOT:-$AMD_CWD} inside=0
  for d in "${AMD_CHAIN[@]}"; do
    [[ $d == "$stop" ]] && inside=1
    (( inside )) || continue
    [[ $d/.claude == "$cfg" ]] && continue
    at_cwd=0; [[ $d == "$AMD_CWD" ]] && at_cwd=1
    amd_report $a project skills "$d/.claude/skills" loaded \
      'Project skills. Loaded from the starting directory and every parent up to the repository root.' $at_cwd
  done
  if [[ -n $AMD_GIT_ROOT && $AMD_MAIN_ROOT != "$AMD_GIT_ROOT" && ! -d $AMD_GIT_ROOT/.claude/skills ]] \
     && (( agents_native )); then
    amd_report $a project skills "$AMD_MAIN_ROOT/.claude/skills" loaded \
      'Skills from the main checkout. Used because this linked worktree has no .claude/skills at its root.'
  fi
}

# _amd_claude_imports DIR AGENTS_FILE: true when a CLAUDE.md in DIR imports
# that AGENTS.md with the @path syntax.
_amd_claude_imports() {
  local d=$1 target=$2 src ref
  for src in "$d/CLAUDE.md" "$d/.claude/CLAUDE.md"; do
    [[ -f $src && -r $src ]] || continue
    case "$src|$target" in
      "$d/CLAUDE.md|$d/AGENTS.md")                 ref='(\./)?AGENTS\.md' ;;
      "$d/CLAUDE.md|$d/.claude/AGENTS.md")         ref='(\./)?\.claude/AGENTS\.md' ;;
      "$d/.claude/CLAUDE.md|$d/AGENTS.md")         ref='\.\./AGENTS\.md' ;;
      "$d/.claude/CLAUDE.md|$d/.claude/AGENTS.md") ref='(\./)?AGENTS\.md' ;;
      *) continue ;;
    esac
    command grep -Eq "(^|[[:space:]])@${ref}([[:space:]]|\$)" -- "$src" 2>/dev/null && return 0
  done
  return 1
}

# amd_skill_rule_c FOLDER FILE GROUP: Claude Code's per-skill rules.
# Returns true with reply=(state reason) when a skill's state differs from
# its folder's. Skills are matched by directory name, which is the command
# name unless frontmatter overrides it.
amd_skill_rule_c() {
  local folder=$1 name=${2%/*} group=$3
  name=${name##*/}
  [[ ${AMD_STATE[c:$folder]:-} == loaded ]] || return 1
  if [[ $folder == "$AMD_CLAUDE_USER_SKILLS" && $group == synced ]]; then
    reply=(loaded 'Synced from your claude.ai account. Loaded in sessions signed in with that account. If another skill or command has the same name, this one runs only under its full name.')
    return 0
  fi
  # Grouped folders other than synced are not part of the documented layout.
  [[ -z $group ]] || return 1
  [[ $folder == "$AMD_CLAUDE_MANAGED_SKILLS" ]] && return 1
  if [[ -f $AMD_CLAUDE_MANAGED_SKILLS/$name/SKILL.md ]]; then
    reply=(skipped "Shadowed. Your organization installs a skill named $name, and organization skills win over personal and project skills.")
    return 0
  fi
  [[ $folder == "$AMD_CLAUDE_USER_SKILLS" ]] && return 1
  if [[ -f $AMD_CLAUDE_USER_SKILLS/$name/SKILL.md ]]; then
    reply=(skipped "Shadowed. You have a personal skill named $name, and personal skills win over project skills of the same name.")
    return 0
  fi
  return 1
}
