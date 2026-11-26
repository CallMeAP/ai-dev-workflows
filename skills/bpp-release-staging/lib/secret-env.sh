# shellcheck shell=bash
# get_secret <development|staging>: prints the stage's DB connection string on stdout,
# only for capture by the caller: conn=$(get_secret staging)
# Exit: 0 ok, 2 unknown stage or backend, 3 not found, 4 env file mode/owner wrong,
#       5 Keychain timeout, denied or no timeout tool.
# Backend: BPP_RELEASE_SECRETS=keychain|envfile, else Keychain on macOS, env file elsewhere.
# Never prints the value anywhere but stdout; error messages name only stage and file.

_secret_backend() {
  if [ -n "${BPP_RELEASE_SECRETS:-}" ]; then
    printf '%s\n' "$BPP_RELEASE_SECRETS"
  elif [ "$(uname)" = Darwin ]; then
    printf 'keychain\n'
  else
    printf 'envfile\n'
  fi
}

# Prints "<mode> <uid>" of a file (GNU stat first, then BSD stat).
_secret_stat() {
  stat -c '%a %u' "$1" 2>/dev/null || stat -f '%Lp %u' "$1" 2>/dev/null
}

# _secret_unquote <value>: removes the quotes around a quoted value, plus a trailing
# "# comment" after the closing quote. Unquoted values come back as they are (a # may be
# part of a password).
_secret_unquote() {
  local value=$1 q body head tail
  q=${value%"${value#?}"}
  case "$q" in
    \"|\') ;;
    *) printf '%s\n' "$value"; return 0 ;;
  esac
  body=${value#?}
  case "$body" in
    *"$q")
      printf '%s\n' "${body%?}"
      return 0
      ;;
  esac
  # try each closing quote from the right: after it only spaces, then "#"
  head=$body
  while :; do
    case "$head" in *"$q"*) ;; *) break ;; esac
    head=${head%"$q"*}
    tail=${body#"$head$q"}
    while :; do
      case "$tail" in [[:space:]]*) tail=${tail#?} ;; *) break ;; esac
    done
    case "$tail" in
      '#'*) printf '%s\n' "$head"; return 0 ;;
    esac
  done
  printf '%s\n' "$value"
}

_secret_from_envfile() {
  local stage=$1 file key line value st cr
  file=${BPP_RELEASE_ENV_FILE:-$HOME/.bpp-release.env}
  if [ ! -f "$file" ]; then
    printf 'secret-env: env file %s not found\n' "$file" >&2
    return 3
  fi
  st=$(_secret_stat "$file")
  if [ "$st" != "600 $(id -u)" ]; then
    printf 'secret-env: %s must have mode 600 and be owned by the current user (fix: chmod 600 %s)\n' "$file" "$file" >&2
    return 4
  fi
  key="BPP_DB_$(printf '%s' "$stage" | tr '[:lower:]' '[:upper:]')="
  cr=$(printf '\r')
  # Read line by line; the file is never sourced, so nothing in it runs.
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%"$cr"}
    # trailing spaces and tabs
    while :; do
      case "$line" in *[[:space:]]) line=${line%?} ;; *) break ;; esac
    done
    # allow leading spaces and an "export " prefix
    while [ "${line# }" != "$line" ]; do line=${line# }; done
    line=${line#export }
    case "$line" in
      "$key"*) ;;
      *) continue ;;
    esac
    value=$(_secret_unquote "${line#"$key"}")
    if [ -z "$value" ]; then
      break
    fi
    printf '%s\n' "$value"
    return 0
  done < "$file"
  printf 'secret-env: no value for %s in %s\n' "${key%=}" "$file" >&2
  return 3
}

_secret_from_keychain() {
  local stage=$1 tbin value rc
  tbin=${TIMEOUT_BIN:-$(command -v timeout || command -v gtimeout)}
  if [ -z "$tbin" ]; then
    printf 'secret-env: no timeout tool found (install coreutils); refusing to call security without one\n' >&2
    return 5
  fi
  value=$("$tbin" "${BPP_KEYCHAIN_TIMEOUT:-10}" security find-generic-password -s "bpp-db-$stage" -a bpp -w 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 44 ]; then
    printf 'secret-env: Keychain entry bpp-db-%s not found\n' "$stage" >&2
    return 3
  fi
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    printf 'secret-env: Keychain read of bpp-db-%s timed out (popup or locked Keychain?)\n' "$stage" >&2
    return 5
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'secret-env: Keychain read of bpp-db-%s failed (exit %s: denied or locked?)\n' "$stage" "$rc" >&2
    return 5
  fi
  if [ -z "$value" ]; then
    printf 'secret-env: Keychain entry bpp-db-%s is empty\n' "$stage" >&2
    return 3
  fi
  printf '%s\n' "$value"
}

get_secret() {
  local stage=${1:-}
  case "$stage" in
    development|staging) ;;
    *)
      printf 'secret-env: unknown stage "%s" (allowed: development, staging)\n' "$stage" >&2
      return 2
      ;;
  esac
  case "$(_secret_backend)" in
    keychain) _secret_from_keychain "$stage" ;;
    envfile) _secret_from_envfile "$stage" ;;
    *)
      printf 'secret-env: unknown BPP_RELEASE_SECRETS "%s" (allowed: keychain, envfile)\n' "$BPP_RELEASE_SECRETS" >&2
      return 2
      ;;
  esac
}
