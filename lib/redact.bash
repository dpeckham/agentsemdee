# redact.bash: mask secrets before config files reach the screen.
#
# Settings and MCP files routinely carry API keys in env blocks, headers, and
# URLs. The viewer is often on screen during calls and recordings, so it never
# prints those values. Redaction is line based and deliberately greedy: it
# would rather hide a harmless value than show a secret. Opening the file in
# an editor shows the real content.

declare -g AMD_MASK='[redacted]'

# Key names whose string values are always masked.
declare -g AMD_SENSITIVE_KEY='(token|secret|password|passwd|api[_-]?key|authorization|credential|private[_-]?key|access[_-]?key|bearer|cookie|session[_-]?key)'
# Key names that look sensitive but hold a pointer to a secret, not the secret.
declare -g AMD_POINTER_KEY='(env[_-]?var|envvar|helper|_file|_path|_cmd|_command)$'
# Containers in which every string value is masked.
declare -g AMD_SECRET_BLOCK='(env|environment|headers|http_headers|env_http_headers)'

# _amd_gsub STRING ERE FUNC -> REPLY
# Replace every match of ERE. FUNC reads AMD_M (see amd_match) and sets REPLY.
_amd_gsub() {
  local rest=$1 re=$2 fn=$3 out=''
  while [[ -n $rest ]] && amd_match "$rest" "$re"; do
    # An empty match would never advance.
    [[ -n ${AMD_M[0]} ]] || break
    rest=$AMD_POST
    out+=$AMD_PRE
    "$fn"
    out+=$REPLY
  done
  REPLY=$out$rest
}

# A value that only references an environment variable is not a secret.
_amd_is_reference() {
  [[ $1 == *'${'* || $1 == *'{env:'* || $1 == *'{file:'* || $1 == '$'[A-Za-z_]* ]]
}

# Callback: mask the string value of a  key: "value"  or  key = "value"  pair
# when the key name is sensitive. AMD_M[1] is the key, AMD_M[2] the separator
# with its spacing, AMD_M[3] the quoted value.
_amd_cb_pair() {
  local whole=${AMD_M[0]} key=${AMD_M[1],,} val=${AMD_M[3]}
  if [[ $key =~ $AMD_SENSITIVE_KEY && ! $key =~ $AMD_POINTER_KEY ]] \
     && (( ${#val} > 2 )) && ! _amd_is_reference "$val"; then
    REPLY="${whole:0:${#whole}-${#val}}\"$AMD_MASK\""
  else
    REPLY=$whole
  fi
}

# Callback: mask any quoted value that follows a separator. AMD_M[1] is the
# separator with its spacing, AMD_M[2] the quoted value.
_amd_cb_value() {
  local whole=${AMD_M[0]} sep=${AMD_M[1]} val=${AMD_M[2]}
  if (( ${#val} > 2 )) && ! _amd_is_reference "$val"; then
    REPLY="$sep\"$AMD_MASK\""
  else
    REPLY=$whole
  fi
}

_amd_cb_url()       { REPLY="${AMD_M[1]}$AMD_MASK@"; }
_amd_cb_mask()      { REPLY=$AMD_MASK; }
_amd_cb_flag()      { REPLY="${AMD_M[1]}$AMD_MASK"; }
_amd_cb_flag_next() { REPLY="${AMD_M[1]}\"$AMD_MASK\""; }

# _amd_brace_depth TEXT -> REPLY is the count of "{" minus "}" outside
# double-quoted strings.
_amd_brace_depth() {
  local s=${1//\"*([!\"])\"/} opens closes
  opens=${s//[!\{]/}
  closes=${s//[!\}]/}
  REPLY=$(( ${#opens} - ${#closes} ))
}

# amd_redact FORMAT: filter stdin to stdout. FORMAT is "toml" or "json".
amd_redact() {
  # Byte semantics, so a line that is not valid UTF-8 still matches.
  local LC_ALL=C
  local format=${1:-json} line low head tail
  local depth=0 in_table=0 mask_next=0

  local str='"(\\.|[^"\\])*"'
  local qstr=$str"|'[^']*'"
  local json_pair='"([A-Za-z0-9_.-]+)"([[:space:]]*:[[:space:]]*)('$str')'
  local toml_pair='"?([A-Za-z0-9_.-]+)"?([[:space:]]*=[[:space:]]*)('$qstr')'
  local json_value='(:[[:space:]]*)('$str')'
  local toml_value='(=[[:space:]]*)('$qstr')'
  local json_block='"'$AMD_SECRET_BLOCK'"[[:space:]]*:[[:space:]]*\{'
  local toml_block='(^|[[:space:],{])'$AMD_SECRET_BLOCK'[[:space:]]*=[[:space:]]*\{'
  local toml_header='^[[:space:]]*\[\[?([^]]*)\]\]?[[:space:]]*(#.*)?$'
  local toml_secret_table="(^|\\.)\"?${AMD_SECRET_BLOCK}\"?\$"
  # A secret flag alone on its line, as in a pretty-printed args array. Its
  # value is the string on the following line.
  local flag_alone='^[[:space:]]*"--?[a-z-]*(key|token|password|secret)[a-z-]*"[[:space:]]*,?[[:space:]]*$'
  local lone_string='^([[:space:]]*)("(\\.|[^"\\])*")(.*)$'

  while IFS= read -r line || [[ -n $line ]]; do
    low=${line,,}

    if (( mask_next )); then
      mask_next=0
      if [[ $line =~ $lone_string ]] && ! _amd_is_reference "${BASH_REMATCH[2]}"; then
        line="${BASH_REMATCH[1]}\"$AMD_MASK\"${BASH_REMATCH[4]}"
        low=${line,,}
      fi
    fi
    [[ $low =~ $flag_alone ]] && mask_next=1

    if [[ $format == toml ]]; then
      if [[ $line =~ $toml_header ]]; then
        in_table=0
        head=${BASH_REMATCH[1],,}
        [[ $head =~ $toml_secret_table ]] && in_table=1
      elif (( in_table )) || [[ $low =~ $toml_block ]]; then
        _amd_gsub "$line" "$toml_value" _amd_cb_value; line=$REPLY
      else
        _amd_gsub "$line" "$toml_pair" _amd_cb_pair; line=$REPLY
      fi
    else
      if (( depth > 0 )); then
        _amd_gsub "$line" "$json_value" _amd_cb_value; line=$REPLY
        _amd_brace_depth "$line"
        (( depth += REPLY ))
        (( depth < 0 )) && depth=0
      elif amd_match "$low" "$json_block"; then
        # Mask everything after the opening brace, then track nesting so the
        # lines that follow are masked until the object closes.
        head=${line:0:${#line}-${#AMD_POST}}
        tail=${line:${#head}}
        _amd_gsub "$tail" "$json_value" _amd_cb_value; tail=$REPLY
        _amd_brace_depth "$tail"
        (( depth = 1 + REPLY ))
        (( depth < 0 )) && depth=0
        line=$head$tail
      else
        _amd_gsub "$line" "$json_pair" _amd_cb_pair; line=$REPLY
      fi
    fi

    # Shapes that are secrets wherever they appear.
    _amd_gsub "$line" '([A-Za-z][A-Za-z0-9+.-]*://)[^/@[:space:]"'\'']+:[^/@[:space:]"'\'']+@' _amd_cb_url; line=$REPLY
    _amd_gsub "$line" '(--?[A-Za-z-]*(key|token|password|secret)[A-Za-z-]*=)[^"'\''[:space:],]+' _amd_cb_flag; line=$REPLY
    _amd_gsub "$line" '("--?[A-Za-z-]*(key|token|password|secret)[A-Za-z-]*"[[:space:]]*,[[:space:]]*)'"$str" _amd_cb_flag_next; line=$REPLY
    _amd_gsub "$line" '(sk|pk|rk)-[A-Za-z0-9_-]{16,}' _amd_cb_mask; line=$REPLY
    _amd_gsub "$line" '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}' _amd_cb_mask; line=$REPLY
    _amd_gsub "$line" 'github_pat_[A-Za-z0-9_]{20,}' _amd_cb_mask; line=$REPLY
    _amd_gsub "$line" 'xox[abprs]-[A-Za-z0-9-]{10,}' _amd_cb_mask; line=$REPLY
    _amd_gsub "$line" 'AKIA[0-9A-Z]{16}' _amd_cb_mask; line=$REPLY
    _amd_gsub "$line" 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*' _amd_cb_mask; line=$REPLY

    amd_say "$line"
  done
}
