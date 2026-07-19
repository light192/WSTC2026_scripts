#!/usr/bin/env bash
# Common output/reporting library for the A3 evaluator.

set -o pipefail

RED='\033[0;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'; NC='\033[0m'

A3_DOMAIN="${A3_DOMAIN:-nova.a3.test}"
A3_ROOT_PASS="${A3_ROOT_PASS:-Skill39@A3}"
A3_REPORT_DIR="${A3_REPORT_DIR:-./reports}"
A3_PAUSE="${A3_PAUSE:-1}"
A3_TIMEOUT="${A3_TIMEOUT:-6}"
A3_CMD_TIMEOUT="${A3_CMD_TIMEOUT:-180}"
A3_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
A3_PACKAGE_DIR="$(cd "$A3_COMMON_DIR/.." && pwd)"
A3_CRITERIA_MAP="${A3_CRITERIA_MAP:-$A3_PACKAGE_DIR/criteria/a3_criteria_map.tsv}"
A3_RESULTS_TSV="${A3_RESULTS_TSV:-$A3_REPORT_DIR/a3-results.tsv}"
A3_DETAIL_LOG="${A3_DETAIL_LOG:-$A3_REPORT_DIR/a3-detail.log}"
A3_LAST_CONTEXT_ID=""
A3_PENDING_OUTPUT=""

mkdir -p "$A3_REPORT_DIR"

decode_newlines() {
  local value="${1%$'\r'}"
  value="${value//\\n/$'\n'}"
  printf '%s' "$value"
}

pause_if_needed() {
  [ "$A3_PAUSE" = 1 ] || return 0
  if { exec 9</dev/tty; } 2>/dev/null; then
    read -r -p "Нажмите [ENTER], чтобы продолжить..." <&9
    exec 9<&-
  else
    echo "Интерактивная консоль недоступна; продолжаю без паузы."
  fi
}

section() {
  echo
  echo -e "${PURPLE}======================================================================================${NC}"
  echo -e "${PURPLE}$*${NC}"
  echo -e "${PURPLE}======================================================================================${NC}"
}

print_criterion_context() {
  local id="$1"
  [ "$A3_LAST_CONTEXT_ID" = "$id" ] && return 0
  A3_LAST_CONTEXT_ID="$id"
  awk -F'\t' -v id="$id" -v blue="$BLUE" -v nc="$NC" '
    NR>1 && $1==id {
      print blue "Критерий: " $1 " — " $3 nc
      print blue "Рекомендуемая точка запуска:" nc; print $5
      print blue "Команды для ручной проверки:" nc
      print "Готовые команды без служебной логики evaluator показаны ниже."
      print blue "Ожидаемый результат:" nc; print $7
      if ($8!="") { print blue "Примечания:" nc; print $8 }
      exit
    }' "$A3_CRITERIA_MAP" | tee -a "$A3_DETAIL_LOG"
}

step() { local id="$1"; shift; echo -e "${YELLOW}Шаг: $id $*${NC}"; print_criterion_context "$id"; }
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
  echo -e "${BLUE}Готовые команды для копирования и ручной проверки:${NC}"
  printf '%s\n' "$display"
  echo -e "${BLUE}Автоматическая проверка запускается evaluator без вывода служебной обвязки.${NC}"
}
show_output() { [ -z "$A3_PENDING_OUTPUT" ] || A3_PENDING_OUTPUT+=$'\n'; A3_PENDING_OUTPUT+="${1:-(пустой вывод)}"; }
flush_output() {
  [ -n "$A3_PENDING_OUTPUT" ] || return 0
  echo -e "${BLUE}Завершение команды:${NC}" | tee -a "$A3_DETAIL_LOG"
  printf '%s\n' "$A3_PENDING_OUTPUT" | tee -a "$A3_DETAIL_LOG"
  A3_PENDING_OUTPUT=""
}

record_result() {
  local id="$1" mark="$2" status="$3" msg="$4"
  print_criterion_context "$id"; flush_output
  printf '%s\t%s\t%s\t%s\n' "$id" "$mark" "$status" "${msg//$'\t'/ }" >> "$A3_RESULTS_TSV"
  case "$status" in
    PASS) echo -e "${GREEN}PASS [$id/$mark] — $msg${NC}" ;;
    FAIL) echo -e "${RED}FAIL [$id/$mark] — $msg${NC}" ;;
    PART)
      local awarded="${msg#awarded=}"
      awarded="${awarded%%;*}"
      echo -e "${PURPLE}PART [$id $awarded/$mark] — ${msg#*;}${NC}"
      ;;
    WARN) echo -e "${YELLOW}WARN [$id/$mark] — $msg${NC}" ;;
    SKIP) echo -e "${CYAN}SKIP [$id/$mark] — $msg${NC}" ;;
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
  local summary="$A3_REPORT_DIR/a3-summary.txt"
  awk -F'\t' 'NR>1 {
      total+=$2; count[$3]++;
      if($3=="PASS") score+=$2;
      else if($3=="PART") { msg=$4; sub(/^awarded=/,"",msg); sub(/;.*/,"",msg); score+=msg+0; missed[$3]+=$2-(msg+0) }
      else missed[$3]+=$2
    }
    END { printf "Сводка проверки A3\n===================\n";
      printf "Засчитано: %.2f / %.2f\n",score,total;
      printf "PASS: %d, PART: %d, FAIL: %d, WARN: %d, SKIP: %d\n",count["PASS"],count["PART"],count["FAIL"],count["WARN"],count["SKIP"];
      printf "Не засчитано: %.2f; частично потеряно: %.2f; предупреждения: %.2f; пропущено: %.2f\n",missed["FAIL"],missed["PART"],missed["WARN"],missed["SKIP"] }' \
    "$A3_RESULTS_TSV" | tee "$summary"
}
