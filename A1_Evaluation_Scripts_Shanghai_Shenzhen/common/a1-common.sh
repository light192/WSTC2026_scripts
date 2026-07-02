#!/usr/bin/env bash
# A1 Shanghai–Shenzhen evaluation common library
# Source this file from remote/local check scripts.

set -o pipefail

RED='\033[0;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

A1_DOMAIN="${A1_DOMAIN:-orion.a1.test}"
A1_PASS="${A1_PASS:-Skill39@A1}"
A1_BASE_DN="${A1_BASE_DN:-dc=orion,dc=a1,dc=test}"
A1_LDAP_URI="${A1_LDAP_URI:-ldap://id-a1.orion.a1.test}"
A1_DNS_IP="${A1_DNS_IP:-10.11.40.10}"
A1_REPORT_DIR="${A1_REPORT_DIR:-./reports}"
A1_PAUSE="${A1_PAUSE:-0}"
A1_TIMEOUT="${A1_TIMEOUT:-6}"
A1_RESULTS_TSV="${A1_RESULTS_TSV:-$A1_REPORT_DIR/a1-results.tsv}"
A1_DETAIL_LOG="${A1_DETAIL_LOG:-$A1_REPORT_DIR/a1-detail.log}"

mkdir -p "$A1_REPORT_DIR"

if [ ! -s "$A1_RESULTS_TSV" ]; then
  printf "CriterionID\tMaxMark\tStatus\tMessage\n" > "$A1_RESULTS_TSV"
fi

pause_if_needed() {
  if [ "${A1_PAUSE}" = "1" ]; then
    read -r -p "Нажмите [ENTER], чтобы продолжить..."
  fi
}

section() {
  echo ""
  echo -e "${PURPLE}######################################################################################${NC}"
  echo -e "${PURPLE}$*${NC}"
  echo -e "${PURPLE}######################################################################################${NC}"
  echo ""
}

step() {
  echo -e "${YELLOW}Шаг: $*${NC}"
}

cmd_show() {
  echo -e "${BLUE}Команда: $*${NC}"
}

detail() {
  echo "$*" | tee -a "$A1_DETAIL_LOG"
}

record_result() {
  local id="$1"; shift
  local mark="$1"; shift
  local status="$1"; shift
  local msg="$*"
  printf "%s\t%s\t%s\t%s\n" "$id" "$mark" "$status" "$msg" >> "$A1_RESULTS_TSV"
  case "$status" in
    PASS) echo -e "${GREEN}OK [$id/$mark] - $msg${NC}" ;;
    FAIL) echo -e "${RED}FAILED [$id/$mark] - $msg${NC}" ;;
    WARN) echo -e "${YELLOW}WARN [$id/$mark] - $msg${NC}" ;;
    SKIP) echo -e "${CYAN}SKIP [$id/$mark] - $msg${NC}" ;;
    *) echo "[$status] [$id/$mark] $msg" ;;
  esac
}

pass() { record_result "$1" "$2" PASS "$3"; }
fail() { record_result "$1" "$2" FAIL "$3"; }
warn() { record_result "$1" "$2" WARN "$3"; }
skip() { record_result "$1" "$2" SKIP "$3"; }

run_local() {
  local command="$1"
  cmd_show "$command"
  bash -lc "$command" 2>&1 | tee -a "$A1_DETAIL_LOG"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

contains_all() {
  local haystack="$1"; shift
  local needle
  for needle in "$@"; do
    echo "$haystack" | grep -Fq "$needle" || return 1
  done
  return 0
}

contains_regex_all() {
  local haystack="$1"; shift
  local needle
  for needle in "$@"; do
    echo "$haystack" | grep -Eq "$needle" || return 1
  done
  return 0
}

write_summary() {
  local summary="$A1_REPORT_DIR/a1-summary.txt"
  awk -F'\t' '
    NR>1 {
      total += $2;
      if ($3=="PASS") pass += $2;
      if ($3=="FAIL") fail += $2;
      if ($3=="WARN") warn += $2;
      if ($3=="SKIP") skip += $2;
      count[$3]++
    }
    END {
      printf "A1 Evaluation Summary\n";
      printf "=====================\n";
      printf "Passed marks: %.2f / %.2f\n", pass, total;
      printf "Failed marks: %.2f\n", fail;
      printf "Warn marks:   %.2f\n", warn;
      printf "Skip marks:   %.2f\n", skip;
      printf "\nCounts:\n";
      for (s in count) printf "  %s: %d\n", s, count[s];
    }
  ' "$A1_RESULTS_TSV" | tee "$summary"
}

