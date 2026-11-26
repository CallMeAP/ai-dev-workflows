# shellcheck shell=bash
# redact_stream <conn-string>: copies stdin to stdout and replaces the whole connection string
# and its password value with ***. Pure bash, so the secret never shows up in any argv.

# _redact_password <conn-string>: prints the Password=/Pwd= value (quotes removed), or nothing.
_redact_password() {
  local rest=$1 part key value lkey
  while [ -n "$rest" ]; do
    part=${rest%%;*}
    if [ "$part" = "$rest" ]; then rest=''; else rest=${rest#*;}; fi
    case "$part" in *=*) ;; *) continue ;; esac
    key=${part%%=*}
    value=${part#*=}
    # key: no spaces, lower case (bash 3.2 has no ${x,,}; tr only sees the key)
    lkey=$(printf '%s' "$key" | tr -d ' \t' | tr '[:upper:]' '[:lower:]')
    case "$lkey" in
      password|pwd)
        case "$value" in
          \"*\") value=${value#\"}; value=${value%\"} ;;
          \'*\') value=${value#\'}; value=${value%\'} ;;
        esac
        printf '%s' "$value"
        return 0
        ;;
    esac
  done
}

redact_stream() {
  local conn=${1:-} pw line
  pw=$(_redact_password "$conn")
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$conn" ]; then line=${line//"$conn"/***}; fi
    if [ -n "$pw" ]; then line=${line//"$pw"/***}; fi
    printf '%s\n' "$line"
  done
}
