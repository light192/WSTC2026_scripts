#!/usr/bin/env bash
# A2 Shanghai-Shenzhen evaluation common library.

set -o pipefail

RED='\033[0;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

A2_DOMAIN="${A2_DOMAIN:-atlas.a2.lab}"
A2_PASS="${A2_PASS:-Skill39@A1}"
A2_READER_PASS="${A2_READER_PASS:-Skill39@A2reader}"
A2_BASE_DN="${A2_BASE_DN:-dc=atlas,dc=a2,dc=lab}"
A2_BIND_DN="${A2_BIND_DN:-cn=admin,${A2_BASE_DN}}"
A2_READER_DN="${A2_READER_DN:-uid=ldap-reader,ou=ServiceAccounts,${A2_BASE_DN}}"
A2_DNS_IP="${A2_DNS_IP:-10.22.40.10}"
A2_REPORT_DIR="${A2_REPORT_DIR:-./reports}"
A2_PAUSE="${A2_PAUSE:-1}"
A2_TIMEOUT="${A2_TIMEOUT:-6}"
A2_CMD_TIMEOUT="${A2_CMD_TIMEOUT:-180}"
A2_RESULTS_TSV="${A2_RESULTS_TSV:-$A2_REPORT_DIR/a2-results.tsv}"
A2_DETAIL_LOG="${A2_DETAIL_LOG:-$A2_REPORT_DIR/a2-detail.log}"
A2_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
A2_PACKAGE_DIR="$(cd "$A2_COMMON_DIR/.." && pwd)"
A2_CRITERIA_MAP="${A2_CRITERIA_MAP:-$A2_PACKAGE_DIR/criteria/a2_criteria_map.tsv}"
A2_LAST_CONTEXT_ID=""
A2_PENDING_OUTPUT=""

mkdir -p "$A2_REPORT_DIR"

if [ ! -s "$A2_RESULTS_TSV" ]; then
  printf "CriterionID\tMaxMark\tStatus\tMessage\n" > "$A2_RESULTS_TSV"
fi

decode_field() {
  local value="$1"
  value="${value%$'\r'}"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
    value="${value//\"\"/\"}"
  fi
  printf '%b' "$value"
}

pause_if_needed() {
  if [ "${A2_PAUSE}" = "1" ]; then
    if { exec 9</dev/tty; } 2>/dev/null; then
      read -r -p "Нажмите [ENTER], чтобы продолжить..." <&9
      exec 9<&-
    else
      echo "Пауза включена, но интерактивная консоль недоступна; продолжаю без ожидания."
    fi
  fi
}

section() {
  echo ""
  echo -e "${PURPLE}######################################################################################${NC}"
  echo -e "${PURPLE}$*${NC}"
  echo -e "${PURPLE}######################################################################################${NC}"
  echo ""
}

cmd_show() {
  echo -e "${BLUE}Команда:${NC}"
  printf "%s\n" "$*"
}

show_output() {
  local text="${1:-}"
  [ -n "$text" ] || text="(пустой вывод)"
  if [ -n "$A2_PENDING_OUTPUT" ]; then
    A2_PENDING_OUTPUT+=$'\n'
  fi
  A2_PENDING_OUTPUT+="$text"
}

flush_output() {
  [ -n "$A2_PENDING_OUTPUT" ] || return 0
  echo -e "${BLUE}Фактический вывод:${NC}" | tee -a "$A2_DETAIL_LOG"
  printf "%s\n" "$A2_PENDING_OUTPUT" | tee -a "$A2_DETAIL_LOG"
  A2_PENDING_OUTPUT=""
}

print_criterion_context() {
  local id="$1"
  [ "$A2_LAST_CONTEXT_ID" = "$id" ] && return 0
  A2_LAST_CONTEXT_ID="$id"
  [ -r "$A2_CRITERIA_MAP" ] || return 0

  awk -F'\t' -v id="$id" -v blue="$BLUE" -v nc="$NC" '
    NR == 1 { next }
    $1 == id {
      runfrom = $5
      if (runfrom == "Run from ops-ws-a2 unless command uses ssh root@<ip>") {
        runfrom = "Запуск с ops-ws-a2, если команда явно не использует ssh root@<ip>"
      }
      command = $6
      gsub(/\\n/, "\n", command)
      if (command ~ /^".*"$/) {
        sub(/^"/, "", command)
        sub(/"$/, "", command)
        gsub(/""/, "\"", command)
      }
      print blue "Критерий: " $1 " - " $3 nc
      print blue "Точка запуска / цель:" nc
      print runfrom
      print blue "Команды проверки:" nc
      print command
      print blue "Ожидаемый результат:" nc
      print $7
      if ($8 != "") {
        print blue "Примечания:" nc
        print $8
      }
      found = 1
      exit
    }
  ' "$A2_CRITERIA_MAP" | tee -a "$A2_DETAIL_LOG"
}

step() {
  local id="$1"
  shift || true
  echo -e "${YELLOW}Шаг: $id $*${NC}"
  print_criterion_context "$id"
}

record_result() {
  local id="$1"; shift
  local mark="$1"; shift
  local status="$1"; shift
  local msg="$*"
  print_criterion_context "$id"
  flush_output
  printf "%s\t%s\t%s\t%s\n" "$id" "$mark" "$status" "$msg" >> "$A2_RESULTS_TSV"
  case "$status" in
    PASS) echo -e "${GREEN}OK [$id/$mark] - $msg${NC}" ;;
    FAIL) echo -e "${RED}НЕ ЗАСЧИТАНО [$id/$mark] - $msg${NC}" ;;
    WARN) echo -e "${YELLOW}ПРЕДУПРЕЖДЕНИЕ [$id/$mark] - $msg${NC}" ;;
    SKIP) echo -e "${CYAN}ПРОПУЩЕНО [$id/$mark] - $msg${NC}" ;;
    *) echo "[$status] [$id/$mark] $msg" ;;
  esac
  pause_if_needed
}

pass() { record_result "$1" "$2" PASS "$3"; }
fail() { record_result "$1" "$2" FAIL "$3"; }
warn() { record_result "$1" "$2" WARN "$3"; }
skip() { record_result "$1" "$2" SKIP "$3"; }

contains_all() {
  local haystack="$1"; shift
  local needle
  for needle in "$@"; do
    printf "%s\n" "$haystack" | grep -Fq "$needle" || return 1
  done
  return 0
}

contains_any() {
  local haystack="$1"; shift
  local needle
  for needle in "$@"; do
    printf "%s\n" "$haystack" | grep -Fq "$needle" && return 0
  done
  return 1
}

contains_regex_all() {
  local haystack="$1"; shift
  local needle
  for needle in "$@"; do
    printf "%s\n" "$haystack" | grep -Eiq "$needle" || return 1
  done
  return 0
}

contains_regex_any() {
  local haystack="$1"; shift
  local needle
  for needle in "$@"; do
    printf "%s\n" "$haystack" | grep -Eiq "$needle" && return 0
  done
  return 1
}

count_regex() {
  local haystack="$1"
  local needle="$2"
  printf "%s\n" "$haystack" | grep -Eic "$needle" || true
}

write_summary() {
  local summary="$A2_REPORT_DIR/a2-summary.txt"
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
      printf "Сводка проверки A2\n";
      printf "=====================\n";
      printf "Засчитано баллов: %.2f / %.2f\n", pass, total;
      printf "Не засчитано:     %.2f\n", fail;
      printf "Предупреждения:   %.2f\n", warn;
      printf "Пропущено:        %.2f\n", skip;
      printf "\nКоличество:\n";
      for (s in count) {
        label=s;
        if (s=="PASS") label="OK";
        if (s=="FAIL") label="Не засчитано";
        if (s=="WARN") label="Предупреждения";
        if (s=="SKIP") label="Пропущено";
        printf "  %s: %d\n", label, count[s];
      }
    }
  ' "$A2_RESULTS_TSV" | tee "$summary"
}
