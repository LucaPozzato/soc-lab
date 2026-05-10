#!/bin/bash

_LOG_COLOR=1
if [[ -n "${NO_COLOR:-}" ]]; then
  _LOG_COLOR=0
fi

if [[ "$_LOG_COLOR" -eq 1 ]]; then
  C_RESET='\033[0m'
  C_BOLD='\033[1m'
  C_DIM='\033[2m'
  C_RED='\033[38;5;203m'
  C_GREEN='\033[38;5;114m'
  C_YELLOW='\033[38;5;221m'
  C_CYAN='\033[38;5;117m'
  C_ACCENT='\033[38;5;110m'
  C_ACCENT_DIM='\033[38;5;67m'
else
  C_RESET=''
  C_BOLD=''
  C_DIM=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_CYAN=''
  C_ACCENT=''
  C_ACCENT_DIM=''
fi

_HAS_GUM=0
_RENDERER="fallback"
_RENDERER_REASON="gum disabled"

renderer_name() {
  printf "%s (%s)" "$_RENDERER" "$_RENDERER_REASON"
}

banner() {
  if [[ "${SOC_LAB_NO_BANNER:-0}" == "1" ]]; then
    return
  fi
  local title="$1"
  local stamp="$(date '+%Y-%m-%d %H:%M:%S')"
  if [[ "${SOC_LAB_DEBUG_RENDERER:-0}" == "1" ]]; then
    printf "%b\n" "${C_DIM}renderer: $(renderer_name)${C_RESET}"
  fi
  printf "%b\n" "${C_BOLD}${C_ACCENT}  ███████╗ ██████╗  ██████╗      ██╗      █████╗ ██████╗ ${C_RESET}"
  printf "%b\n" "${C_BOLD}${C_ACCENT}  ██╔════╝██╔═══██╗██╔════╝      ██║     ██╔══██╗██╔══██╗${C_RESET}"
  printf "%b\n" "${C_BOLD}${C_ACCENT}  ███████╗██║   ██║██║      ███╗ ██║     ███████║██████╔╝${C_RESET}"
  printf "%b\n" "${C_BOLD}${C_ACCENT}  ╚════██║██║   ██║██║      ╚══╝ ██║     ██╔══██║██╔══██╗${C_RESET}"
  printf "%b\n" "${C_BOLD}${C_ACCENT}  ███████║╚██████╔╝╚██████╗      ███████╗██║  ██║██████╔╝${C_RESET}"
  printf "%b\n" "${C_BOLD}${C_ACCENT}  ╚══════╝ ╚═════╝  ╚═════╝      ╚══════╝╚═╝  ╚═╝╚═════╝ ${C_RESET}"
  printf "%b\n" "${C_ACCENT_DIM}${title}${C_RESET} ${C_DIM}• ${stamp}${C_RESET}"
}

run_step() {
  shift
  "$@"
}

section() {
  printf "\n%b\n" "${C_BOLD}${C_ACCENT}== $* ==${C_RESET}"
}

info()    { printf "%b\n" "${C_CYAN}[*]${C_RESET} $*"; }
ok()      { printf "%b\n" "${C_GREEN}[+]${C_RESET} $*"; }
warn()    { printf "%b\n" "${C_YELLOW}[!]${C_RESET} $*"; }
err()     { printf "%b\n" "${C_RED}[x]${C_RESET} $*" >&2; }
die()     { err "$*"; exit 1; }

progress() {
  local current="$1" total="$2" text="$3"
  printf "%b\n" "${C_ACCENT}[${current}/${total}]${C_RESET} $text"
}
