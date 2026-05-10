#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$BASE_DIR/.." && pwd)"
source "$BASE_DIR/lib/log.sh"

clear
printf "\n"
banner "SOC Lab Interactive"
printf "\n"
info "Type a soc-lab command without prefix (example: stack status)"
info "Built-ins: help, shortcuts, clear, exit"

print_help() {
  section "Command Palette"
  printf "  %-18s %-24s %s\n" "Group" "Command" "Description"
  printf "  %-18s %-24s %s\n" "-----" "-------" "-----------"
  printf "  %-18s %-24s %s\n" "stack" "stack install" "Install local dependencies"
  printf "  %-18s %-24s %s\n" "stack" "stack start" "Start SOC stack"
  printf "  %-18s %-24s %s\n" "stack" "stack status" "Show service status"
  printf "  %-18s %-24s %s\n" "stack" "stack stop" "Stop stack, keep volumes"
  printf "  %-18s %-24s %s\n" "stack" "stack reset" "Stop stack and wipe volumes"
  printf "  %-18s %-24s %s\n" "capture" "capture replay <pcap>" "Replay a PCAP through Suricata"
  printf "  %-18s %-24s %s\n" "capture" "capture live [iface] [sec]" "Continuous capture + replay"
  printf "  %-18s %-24s %s\n" "capture" "capture upload ..." "Upload non-Suricata logs"
  printf "  %-18s %-24s %s\n" "rules" "rules reload" "Refresh Suricata rules"
  printf "  %-18s %-24s %s\n" "so" "so sync" "Load SO templates + pipelines"
  printf "  %-18s %-24s %s\n" "health" "health check" "Stack health summary"

  section "Examples"
  printf "  %s\n" "stack start"
  printf "  %s\n" "capture replay <pcap>"
  printf "  %s\n" "capture replay <pcap> --now"
  printf "  %s\n" "capture upload <log-file> --build-pipeline"
  printf "  %s\n" "capture live <iface> <rotation-seconds>"

  section "Built-ins"
  printf "  %-16s %s\n" "help" "Show this command palette"
  printf "  %-16s %s\n" "shortcuts" "Alias for help"
  printf "  %-16s %s\n" "clear" "Clear screen and redraw header"
  printf "  %-16s %s\n" "exit | quit | q" "Leave interactive shell"
  printf "\n"
}

print_help

while true; do
  read -r -e -p "soc-lab> " line || break
  line="${line#${line%%[![:space:]]*}}"
  line="${line%${line##*[![:space:]]}}"
  [[ -z "$line" ]] && continue

  case "$line" in
    exit|quit|q)
      ok "Bye"
      break
      ;;
    help)
      print_help
      continue
      ;;
    clear)
      clear
      printf "\n"
      banner "SOC Lab Interactive"
      printf "\n"
      continue
      ;;
    shortcuts)
      print_help
      continue
      ;;
  esac

  if [[ "$line" == soc-lab* ]]; then
    line="${line#soc-lab }"
  fi

  printf "\n"
  SOC_LAB_SHELL=1 bash -lc "\"$REPO_ROOT/soc-lab\" $line"
  rc=$?
  printf "\n"
  if [[ "$rc" -ne 0 ]]; then
    warn "Command exited with status $rc"
  fi
done
