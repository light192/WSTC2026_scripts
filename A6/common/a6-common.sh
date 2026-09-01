#!/usr/bin/env bash
# Common output/reporting library for the A6 evaluator.

set -o pipefail

RED='\033[0;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'; NC='\033[0m'

A6_DOMAIN="${A6_DOMAIN:-nova.a6.test}"
A6_ROOT_PASS="${A6_ROOT_PASS:-Skill39@A6}"
A6_LDAP_USER_PASS="${A6_LDAP_USER_PASS:-Skill39@A6}"
A6_LDAP_READER_PASS="${A6_LDAP_READER_PASS:-Reader39@A6}"
A6_GRAFANA_PASS="${A6_GRAFANA_PASS:-Skill39-A6-Monitor!}"
A6_REPORT_DIR="${A6_REPORT_DIR:-./reports}"
A6_PAUSE="${A6_PAUSE:-1}"
A6_TIMEOUT="${A6_TIMEOUT:-6}"
A6_CMD_TIMEOUT="${A6_CMD_TIMEOUT:-180}"
A6_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
A6_PACKAGE_DIR="$(cd "$A6_COMMON_DIR/.." && pwd)"
A6_CRITERIA_MAP="${A6_CRITERIA_MAP:-$A6_PACKAGE_DIR/criteria/a6_criteria_map.tsv}"
A6_RESULTS_TSV="${A6_RESULTS_TSV:-$A6_REPORT_DIR/a6-results.tsv}"
A6_DETAIL_LOG="${A6_DETAIL_LOG:-$A6_REPORT_DIR/a6-detail.log}"
A6_LAST_CONTEXT_ID=""
A6_PENDING_OUTPUT=""

mkdir -p "$A6_REPORT_DIR"

decode_newlines() {
  local value="${1%$'\r'}"
  value="${value//\\n/$'\n'}"
  printf '%s' "$value"
}

pause_if_needed() {
  [ "$A6_PAUSE" = 1 ] || return 0
  if { exec 9</dev/tty; } 2>/dev/null; then
    read -r -p "Press [ENTER] to continue..." <&9
    exec 9<&-
  else
    echo "Interactive console not available; continuing without pause."
  fi
}

section() {
  echo
  echo -e "${PURPLE}======================================================================================${NC}"
  echo -e "${PURPLE}$*${NC}"
  echo -e "${PURPLE}======================================================================================${NC}"
}

# Thin rule used to separate the logical blocks within a single criterion's
# output (context -> manual commands -> live command output -> verdict), and
# to mark the start of a new criterion. Distinct from section()'s heavier
# '=' banner, which separates whole A6 criteria (A, B, C, ...).
DIVIDER='------------------------------------------------------------------------------------'
divider() { echo -e "${PURPLE}${DIVIDER}${NC}"; }

print_criterion_context() {
  local id="$1"
  [ "$A6_LAST_CONTEXT_ID" = "$id" ] && return 0
  A6_LAST_CONTEXT_ID="$id"
  awk -F'\t' -v id="$id" -v blue="$BLUE" -v nc="$NC" '
    NR>1 && $1==id {
      print blue "Criterion: " $1 " - " $3 nc
      print blue "Recommended launch point:" nc; print $5
      print blue "Commands for manual verification:" nc
      print "Ready-to-copy commands without evaluator scaffolding are shown below."
      print blue "Expected result:" nc; print $7
      if ($8!="") { print blue "Notes:" nc; print $8 }
      exit
    }' "$A6_CRITERIA_MAP" | tee -a "$A6_DETAIL_LOG"
}

step() { local id="$1"; shift; divider; echo -e "${YELLOW}Step: $id $*${NC}"; print_criterion_context "$id"; }
cmd_show() {
  local id automatic display
  if [ "$#" -eq 1 ]; then
    id=""; automatic="$1"
  else
    id="$1"; automatic="$2"
  fi
  if declare -F manual_commands_for >/dev/null 2>&1; then
    display="$(manual_commands_for "$id" "$automatic")"
  else
    display="$automatic"
  fi
  divider
  echo -e "${BLUE}Ready-to-copy commands for manual verification:${NC}"
  printf '%s\n' "$display"
  echo -e "${BLUE}The automatic check runs below without extra scaffolding output.${NC}"
}
show_output() { [ -z "$A6_PENDING_OUTPUT" ] || A6_PENDING_OUTPUT+=$'\n'; A6_PENDING_OUTPUT+="${1:-(empty output)}"; }
flush_output() {
  [ -n "$A6_PENDING_OUTPUT" ] || return 0
  echo -e "${BLUE}Command output:${NC}" | tee -a "$A6_DETAIL_LOG"
  printf '%s\n' "$A6_PENDING_OUTPUT" | tee -a "$A6_DETAIL_LOG"
  A6_PENDING_OUTPUT=""
}

record_result() {
  local id="$1" mark="$2" status="$3" msg="$4"
  print_criterion_context "$id"; flush_output
  printf '%s\t%s\t%s\t%s\n' "$id" "$mark" "$status" "${msg//$'\t'/ }" >> "$A6_RESULTS_TSV"
  divider
  case "$status" in
    PASS) echo -e "${GREEN}PASS [$id/$mark] - $msg${NC}" ;;
    FAIL) echo -e "${RED}FAIL [$id/$mark] - $msg${NC}" ;;
    PART)
      local awarded="${msg#awarded=}"
      awarded="${awarded%%;*}"
      echo -e "${PURPLE}PART [$id $awarded/$mark] - ${msg#*;}${NC}"
      ;;
    WARN) echo -e "${YELLOW}WARN [$id/$mark] - $msg${NC}" ;;
    SKIP) echo -e "${CYAN}SKIP [$id/$mark] - $msg${NC}" ;;
  esac
  pause_if_needed
}

pass() { record_result "$1" "$2" PASS "$3"; }
fail() { record_result "$1" "$2" FAIL "$3"; }
part() { record_result "$1" "$2" PART "awarded=$3;$4"; }
warn() { record_result "$1" "$2" WARN "$3"; }
skip() { record_result "$1" "$2" SKIP "$3"; }
contains_all() { local h="$1" n; shift; for n in "$@"; do grep -Fq "$n" <<<"$h" || return 1; done; }
contains_any() { local h="$1" n; shift; for n in "$@"; do grep -Fq "$n" <<<"$h" && return 0; done; return 1; }
regex_all() { local h="$1" n; shift; for n in "$@"; do grep -Eiq "$n" <<<"$h" || return 1; done; }
regex_any() { local h="$1" n; shift; for n in "$@"; do grep -Eiq "$n" <<<"$h" && return 0; done; return 1; }
count_regex() { grep -Eic "$2" <<<"$1" || true; }

write_summary() {
  local summary="$A6_REPORT_DIR/a6-summary.txt"
  awk -F'\t' 'NR>1 {
      total+=$2; count[$3]++;
      if($3=="PASS") score+=$2;
      else if($3=="PART") { msg=$4; sub(/^awarded=/,"",msg); sub(/;.*/,"",msg); score+=msg+0; missed[$3]+=$2-(msg+0) }
      else missed[$3]+=$2
    }
    END { printf "A6 verification summary\n========================\n";
      printf "Awarded: %.2f / %.2f\n",score,total;
      printf "PASS: %d, PART: %d, FAIL: %d, WARN: %d, SKIP: %d\n",count["PASS"],count["PART"],count["FAIL"],count["WARN"],count["SKIP"];
      printf "Not awarded: %.2f; partially lost: %.2f; warnings: %.2f; skipped: %.2f\n",missed["FAIL"],missed["PART"],missed["WARN"],missed["SKIP"] }' \
    "$A6_RESULTS_TSV" | tee "$summary"
}
