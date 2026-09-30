# redact.zsh: mask secrets before config files reach the screen.
#
# Settings and MCP files routinely carry API keys in env blocks, headers, and
# URLs. The viewer is often on screen during calls and recordings, so it never
# prints those values. Redaction is line based and deliberately greedy: it
# would rather hide a harmless value than show a secret. Opening the file in
# an editor shows the real content.

typeset -g AMD_MASK='[redacted]'

# Key names whose string values are always masked.
typeset -g AMD_SENSITIVE_KEY='(token|secret|password|passwd|api[_-]?key|authorization|credential|private[_-]?key|access[_-]?key|bearer|cookie|session[_-]?key)'
# Key names that look sensitive but hold a pointer to a secret, not the secret.
typeset -g AMD_POINTER_KEY='(env[_-]?var|envvar|helper|_file|_path|_cmd|_command)$'
# Containers in which every string value is masked.
typeset -g AMD_SECRET_BLOCK='(env|environment|headers|http_headers|env_http_headers)'

# _amd_gsub STRING ERE FUNC -> REPLY
# Replace every match of ERE. FUNC reads $MATCH and $match and sets REPLY.
_amd_gsub() {
  emulate -L zsh
  local rest=$1 re=$2 fn=$3 out='' pre
  local MATCH MBEGIN MEND; local -a match mbegin mend
  while [[ -n $rest && $rest =~ $re ]]; do
    (( MEND >= MBEGIN )) || break
    pre=${rest[1,MBEGIN-1]}
    rest=${rest[MEND+1,-1]}
    $fn
    out+=$pre$REPLY
  done
  REPLY=$out$rest
}

# A value that only references an environment variable is not a secret.
_amd_is_reference() {
  [[ $1 == *'${'* || $1 == *'{env:'* || $1 == *'{file:'* || $1 == '$'[A-Za-z_]* ]]
}

# Callback: mask the string value of a  key: "value"  or  key = "value"  pair
# when the key name is sensitive. match[1] is the key, match[2] the separator
# with its spacing, match[3] the quoted value.
_amd_cb_pair() {
  local whole=$MATCH key=${match[1]:l} sep=$match[2] val=$match[3]
  local MATCH MBEGIN MEND; local -a match mbegin mend
  if [[ $key =~ $AMD_SENSITIVE_KEY && ! $key =~ $AMD_POINTER_KEY ]] \
     && [[ ${#val} -gt 2 ]] && ! _amd_is_reference $val; then
    REPLY="${whole[1,$(( ${#whole} - ${#val} ))]}\"$AMD_MASK\""
  else
    REPLY=$whole
  fi
}

# Callback: mask any quoted value that follows a separator. match[1] is the
# separator with its spacing, match[2] the quoted value.
_amd_cb_value() {
  local whole=$MATCH sep=$match[1] val=$match[2]
  if [[ ${#val} -gt 2 ]] && ! _amd_is_reference $val; then
    REPLY="$sep\"$AMD_MASK\""
  else
    REPLY=$whole
  fi
}

_amd_cb_url()  { REPLY="${match[1]}$AMD_MASK@" }
_amd_cb_mask() { REPLY=$AMD_MASK }
_amd_cb_flag() { REPLY="${match[1]}$AMD_MASK" }
_amd_cb_flag_next() { REPLY="${match[1]}\"$AMD_MASK\"" }

# amd_redact FORMAT: filter stdin to stdout. FORMAT is "toml" or "json".
amd_redact() {
  emulate -L zsh
  setopt extendedglob
  local format=${1:-json} line low
  local depth=0 in_table=0 mask_next=0 opens closes stripped
  local MATCH MBEGIN MEND; local -a match mbegin mend

  local str='"(\\.|[^"\\])*"'
  local qstr=$str"|'[^']*'"
  local json_pair='"([A-Za-z0-9_.-]+)"([[:space:]]*:[[:space:]]*)('$str')'
  local toml_pair='"?([A-Za-z0-9_.-]+)"?([[:space:]]*=[[:space:]]*)('$qstr')'
  local json_value='(:[[:space:]]*)('$str')'
  local toml_value='(=[[:space:]]*)('$qstr')'
  local json_block='"'$AMD_SECRET_BLOCK'"[[:space:]]*:[[:space:]]*\{'
  local toml_block='(^|[[:space:],{])'$AMD_SECRET_BLOCK'[[:space:]]*=[[:space:]]*\{'
  local toml_header='^[[:space:]]*\[\[?([^]]*)\]\]?[[:space:]]*(#.*)?$'
  # A secret flag alone on its line, as in a pretty-printed args array. Its
  # value is the string on the following line.
  local flag_alone='^[[:space:]]*"--?[a-z-]*(key|token|password|secret)[a-z-]*"[[:space:]]*,?[[:space:]]*$'
  local lone_string='^([[:space:]]*)("(\\.|[^"\\])*")(.*)$'

  while IFS= read -r line || [[ -n $line ]]; do
    low=${line:l}

    if (( mask_next )); then
      mask_next=0
      if [[ $line =~ $lone_string ]] && ! _amd_is_reference $match[2]; then
        line="${match[1]}\"$AMD_MASK\"${match[4]}"
        low=${line:l}
      fi
    fi
    [[ $low =~ $flag_alone ]] && mask_next=1

    if [[ $format == toml ]]; then
      if [[ $line =~ $toml_header ]]; then
        in_table=0
        [[ ${match[1]:l} =~ "(^|\\.)\"?${AMD_SECRET_BLOCK}\"?\$" ]] && in_table=1
      elif (( in_table )) || [[ $low =~ $toml_block ]]; then
        _amd_gsub "$line" $toml_value _amd_cb_value; line=$REPLY
      else
        _amd_gsub "$line" $toml_pair _amd_cb_pair; line=$REPLY
      fi
    else
      if (( depth > 0 )); then
        _amd_gsub "$line" $json_value _amd_cb_value; line=$REPLY
        stripped=${line//\"[^\"]#\"/}
        opens=${#${stripped//[^\{]/}}
        closes=${#${stripped//[^\}]/}}
        (( depth += opens - closes ))
        (( depth < 0 )) && depth=0
      elif [[ $low =~ $json_block ]]; then
        # Mask everything after the opening brace, then track nesting so the
        # lines that follow are masked until the object closes.
        local head=${line[1,MEND]} tail=${line[MEND+1,-1]}
        _amd_gsub "$tail" $json_value _amd_cb_value; tail=$REPLY
        stripped=${tail//\"[^\"]#\"/}
        opens=${#${stripped//[^\{]/}}
        closes=${#${stripped//[^\}]/}}
        (( depth = 1 + opens - closes ))
        (( depth < 0 )) && depth=0
        line=$head$tail
      else
        _amd_gsub "$line" $json_pair _amd_cb_pair; line=$REPLY
      fi
    fi

    # Shapes that are secrets wherever they appear.
    _amd_gsub "$line" '([A-Za-z][A-Za-z0-9+.-]*://)[^/@[:space:]"'\'']+:[^/@[:space:]"'\'']+@' _amd_cb_url; line=$REPLY
    _amd_gsub "$line" '(--?[A-Za-z-]*(key|token|password|secret)[A-Za-z-]*=)[^"'\''[:space:],]+' _amd_cb_flag; line=$REPLY
    _amd_gsub "$line" '("--?[A-Za-z-]*(key|token|password|secret)[A-Za-z-]*"[[:space:]]*,[[:space:]]*)'$str _amd_cb_flag_next; line=$REPLY
    _amd_gsub "$line" '(sk|pk|rk)-[A-Za-z0-9_-]{16,}' _amd_cb_mask; line=$REPLY
    _amd_gsub "$line" '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}' _amd_cb_mask; line=$REPLY
    _amd_gsub "$line" 'github_pat_[A-Za-z0-9_]{20,}' _amd_cb_mask; line=$REPLY
    _amd_gsub "$line" 'xox[abprs]-[A-Za-z0-9-]{10,}' _amd_cb_mask; line=$REPLY
    _amd_gsub "$line" 'AKIA[0-9A-Z]{16}' _amd_cb_mask; line=$REPLY
    _amd_gsub "$line" 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*' _amd_cb_mask; line=$REPLY

    print -r -- "$line"
  done
}
