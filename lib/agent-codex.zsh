# agent-codex.zsh: what Codex reads for the inspected directory.
#
# Sources: the Codex docs (AGENTS.md guide, config basics and advanced,
# skills) and path constants in the Codex CLI 0.159.2 binary.

# _amd_codex_trust FILE -> fills the associative array named "trust" in the
# caller with project path -> trust_level, from [projects."<path>"] tables.
_amd_codex_trust() {
  emulate -L zsh
  local file=$1 line cur=''
  local MATCH MBEGIN MEND; local -a match mbegin mend
  [[ -r $file && -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ '^[[:space:]]*\[projects\.(.*)\][[:space:]]*(#.*)?$' ]]; then
      cur=$match[1]
      cur=${cur#[\"\']}
      cur=${cur%[\"\']}
      continue
    elif [[ $line =~ '^[[:space:]]*\[' ]]; then
      cur=''
      continue
    fi
    if [[ -n $cur && $line =~ '^[[:space:]]*trust_level[[:space:]]*=[[:space:]]*"([a-z]+)"' ]]; then
      trust[$cur]=$match[1]
    fi
  done < $file
}

amd_agent_codex() {
  emulate -L zsh
  setopt extendedglob
  local a=x
  local ch=${${CODEX_HOME:-$AMD_HOME/.codex}:A}
  local ucfg=$ch/config.toml etc=$AMD_SYSROOT/etc/codex
  local reason state f d

  # ---- Settings that change discovery ------------------------------------
  local -a markers=(.git) fallbacks=()
  local max_bytes=32768
  if amd_toml_top $ucfg project_root_markers; then
    amd_toml_strings $REPLY
    markers=($reply)
  fi
  if amd_toml_top $ucfg project_doc_fallback_filenames; then
    amd_toml_strings $REPLY
    fallbacks=($reply)
  fi
  if amd_toml_top $ucfg project_doc_max_bytes && [[ $REPLY == <-> ]]; then
    max_bytes=$REPLY
  fi
  local -A trust
  _amd_codex_trust $ucfg

  local -a servers
  if [[ -r $ucfg && -f $ucfg ]]; then
    servers=(${(u)${(f)"$(command sed -n 's/^[[:space:]]*\[mcp_servers\.\([^].]*\).*/\1/p' -- $ucfg 2>/dev/null)"}})
  fi

  # ---- Managed -----------------------------------------------------------
  amd_report $a managed settings $etc/requirements.toml loaded \
    'Admin-enforced requirements. They constrain what every other config layer may set.' 1
  amd_report $a managed settings $etc/managed_config.toml loaded \
    'Admin-managed config, applied on top of your user config.'
  if [[ $OSTYPE == darwin* ]]; then
    amd_report $a managed settings "$AMD_SYSROOT/Library/Managed Preferences/com.openai.codex.plist" loaded \
      'Device-management profile for Codex.'
  fi
  amd_report $a managed settings $etc/config.toml loaded \
    'System-wide defaults. Unlike the other managed files this is the lowest-precedence layer: your user config overrides it.'
  amd_report $a managed skills $etc/skills loaded \
    'Admin-installed skills for every user of this machine.'

  # ---- User global -------------------------------------------------------
  reason='Your config for every project. Profiles, trusted project config, and command-line flags override it. It also records which projects you trust.'
  (( ${#servers} )) && reason+=" Defines ${#servers} MCP server$( (( ${#servers} == 1 )) || print -n s)."
  amd_report $a user settings $ucfg loaded $reason 1

  if [[ -s $ch/AGENTS.override.md ]]; then
    amd_report $a user instructions $ch/AGENTS.override.md loaded \
      'Global instructions. The override file takes the place of AGENTS.md at this level.'
    amd_report $a user instructions $ch/AGENTS.md skipped \
      'AGENTS.override.md in the same directory takes its place.'
  else
    amd_report $a user instructions $ch/AGENTS.override.md skipped \
      'Empty, so Codex skips it.'
    if [[ -e $ch/AGENTS.md && ! -s $ch/AGENTS.md ]]; then
      amd_report $a user instructions $ch/AGENTS.md skipped 'Empty, so Codex skips it.'
    else
      amd_report $a user instructions $ch/AGENTS.md loaded \
        'Global instructions, loaded before any project file.' 1
    fi
  fi
  amd_report $a user skills $ch/skills loaded \
    'Your skills in the Codex home directory, including the ones bundled with Codex.'
  amd_report $a user skills $AMD_HOME/.agents/skills loaded \
    'Your personal skills, available in every repository.' 1

  # ---- Project root ------------------------------------------------------
  # Codex walks up to the nearest directory holding a root marker. Without
  # one it looks at the working directory only.
  local root='' m
  for d in ${(Oa)AMD_CHAIN}; do
    for m in $markers; do
      if [[ -e $d/$m ]]; then
        root=$d
        break 2
      fi
    done
  done
  [[ -n $root ]] || root=$AMD_CWD
  local -a dirs
  local inside=0
  for d in $AMD_CHAIN; do
    [[ $d == $root ]] && inside=1
    (( inside )) && dirs+=($d)
  done

  local trusted='' t
  for d in $AMD_CWD $root $AMD_MAIN_ROOT; do
    [[ -n $d ]] || continue
    t=${trust[$d]:-}
    [[ $t == trusted ]] && trusted=trusted
    [[ $t == untrusted && -z $trusted ]] && trusted=untrusted
  done

  # ---- Instructions: one file per directory, root to cwd ------------------
  local used=0 size picked scope slot
  local -a names=(AGENTS.override.md AGENTS.md $fallbacks)
  for d in $dirs; do
    amd_dir_scope $d
    scope=$REPLY
    slot=0; [[ $d == $AMD_CWD || $d == $root ]] && slot=1
    picked=''
    for f in $names; do
      if [[ -s $d/$f ]]; then
        picked=$f
        break
      fi
    done
    for f in $names; do
      if [[ ! -e $d/$f ]]; then
        [[ $f == AGENTS.md ]] && amd_report $a $scope instructions $d/$f loaded \
          'Codex takes one instruction file per directory, from the project root down to the working directory.' $slot
        continue
      fi
      if [[ ! -s $d/$f ]]; then
        amd_report $a $scope instructions $d/$f skipped 'Empty, so Codex skips it.'
      elif [[ $f != $picked ]]; then
        amd_report $a $scope instructions $d/$f skipped \
          "$picked in the same directory takes its place. Codex reads at most one instruction file per directory."
      elif (( used >= max_bytes )); then
        amd_report $a $scope instructions $d/$f skipped \
          "Earlier files already fill the $max_bytes-byte budget set by project_doc_max_bytes."
      else
        size=$(command wc -c < $d/$f 2>/dev/null)
        size=${size//[^0-9]/}
        reason='Loaded. Codex takes one instruction file per directory, from the project root down to the working directory, and later files refine earlier ones.'
        (( used + ${size:-0} > max_bytes )) && reason+=" Cut short: the combined size passes the $max_bytes-byte budget set by project_doc_max_bytes."
        (( used += ${size:-0} ))
        amd_report $a $scope instructions $d/$f loaded $reason
      fi
    done
  done

  # ---- Project config and skills -----------------------------------------
  for d in $dirs; do
    [[ $d/.codex == $ch ]] && continue
    amd_dir_scope $d
    scope=$REPLY
    slot=0; [[ $d == $root ]] && slot=1
    case $trusted in
      trusted)
        amd_report $a $scope settings $d/.codex/config.toml loaded \
          'Project config. Overrides your user config, and the file closest to the working directory wins.' $slot ;;
      untrusted)
        amd_report $a $scope settings $d/.codex/config.toml skipped \
          'This project is marked untrusted in your Codex config, so Codex ignores its .codex layers.' $slot ;;
      *)
        amd_report $a $scope settings $d/.codex/config.toml skipped \
          'This project is not marked trusted in your Codex config, so Codex ignores its .codex layers until you trust it.' $slot ;;
    esac
    amd_report $a $scope skills $d/.agents/skills loaded \
      'Repository skills. Codex scans .agents/skills in every directory from the working directory up to the repository root.' $slot
  done
}
