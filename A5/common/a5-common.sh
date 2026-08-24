#!/usr/bin/env bash
# Common output/reporting library for the A5 evaluator.

set -o pipefail

RED='\033[0;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'; NC='\033[0m'

A5_DOMAIN="${A5_DOMAIN:-atlas.a5.test}"
A5_ROOT_PASS="${A5_ROOT_PASS:-Skill39@A5}"
A5_LDAP_USER_PASS="${A5_LDAP_USER_PASS:-Skill39@A5}"
A5_LDAP_READER_PASS="${A5_LDAP_READER_PASS:-Skill39@A5-Reader}"
A5_REPORT_DIR="${A5_REPORT_DIR:-./reports}"
A5_PAUSE="${A5_PAUSE:-1}"
A5_TIMEOUT="${A5_TIMEOUT:-6}"
A5_CMD_TIMEOUT="${A5_CMD_TIMEOUT:-180}"
A5_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
A5_PACKAGE_DIR="$(cd "$A5_COMMON_DIR/.." && pwd)"
A5_CRITERIA_MAP="${A5_CRITERIA_MAP:-$A5_PACKAGE_DIR/criteria/a5_criteria_map.tsv}"
A5_RESULTS_TSV="${A5_RESULTS_TSV:-$A5_REPORT_DIR/a5-results.tsv}"
A5_DETAIL_LOG="${A5_DETAIL_LOG:-$A5_REPORT_DIR/a5-detail.log}"
A5_LAST_CONTEXT_ID=""
A5_PENDING_OUTPUT=""

mkdir -p "$A5_REPORT_DIR"

decode_newlines() {
  local value="${1%$'\r'}"
  value="${value//\\n/$'\n'}"
  printf '%s' "$value"
}

pause_if_needed() {
  [ "$A5_PAUSE" = 1 ] || return 0
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

# Best-effort, non-invasive hint: on a bare Linux VGA/virtual console (TERM=linux,
# e.g. hypervisor console view without SSH/X11) the loaded console font often has
# no Cyrillic glyphs, so UTF-8 Cyrillic text renders as CP437-style pseudographics
# even though the bytes/encoding are correct. This never modifies system state.
#
# IMPORTANT: this hint is intentionally written in plain ASCII, NOT Russian.
# If the console font can't render Cyrillic, a Cyrillic-language explanation of
# that exact problem is unreadable too - so this must stay ASCII-only to work.

# Safe, session-only, best-effort attempt to load a Cyrillic-capable console
# font. Never touches /etc (no persistent config change), never errors out if
# setfont/fonts are missing, and only runs on a bare VGA console as root.
console_font_autofix() {
  [ "${TERM:-}" = "linux" ] || return 1
  [ "$(id -u 2>/dev/null)" = 0 ] || return 1
  command -v setfont >/dev/null 2>&1 || return 1
  local f
  for f in /usr/share/consolefonts/*[Cc]yr* /usr/share/consolefonts/Uni2-Terminus* \
           /usr/share/consolefonts/Uni3-Terminus* /usr/share/consolefonts/LatKaCyrHeb*; do
    [ -e "$f" ] || continue
    setfont "$f" >/dev/null 2>&1 && return 0
  done
  return 1
}

console_font_hint() {
  [ "${TERM:-}" = "linux" ] || return 0
  [ "${A5_CONSOLE_HINT_SHOWN:-0}" = 1 ] && return 0
  A5_CONSOLE_HINT_SHOWN=1
  local autofixed=0
  console_font_autofix && autofixed=1
  echo "############################################################"
  echo "# NOTE (plain ASCII on purpose - see why below):"
  echo "# You are on a bare VGA/virtual console (TERM=linux, no SSH)."
  if [ "$autofixed" = 1 ]; then
    echo "# Attempted an automatic session-only console font fix (setfont)."
    echo "# If the Cyrillic text below now looks correct, you're done -"
    echo "# nothing was changed permanently (font reverts on reboot/logout)."
    echo "# If it STILL looks like symbols/pseudographics, use the manual"
    echo "# steps below."
  else
    echo "# If the Cyrillic text below looks like symbols/pseudographics,"
    echo "# it is NOT a script bug: the loaded console font has no"
    echo "# Cyrillic glyphs, even though the UTF-8 bytes are correct."
    echo "# (Automatic fix attempt did not find/apply a Cyrillic font.)"
  fi
  echo "#"
  echo "# Quick fix (run as root, in another window/session):"
  echo "#   ls /usr/share/consolefonts/ | grep -i cyr"
  echo "#   setfont <name-you-found>        # e.g.: setfont LatKaCyrHeb-16"
  echo "# Permanent fix:"
  echo "#   dpkg-reconfigure console-setup  # pick UTF-8 + a Cyrillic-capable"
  echo "#                                   # charset, then run: setupcon"
  echo "#"
  echo "# Easiest option: connect to idm-a5 over SSH from a normal terminal"
  echo "# on your own machine (PuTTY / Windows Terminal / any modern app) -"
  echo "# those always have full Cyrillic font support."
  echo "#"
  echo "# This does NOT affect PASS/FAIL or the score: report files"
  echo "# (a5-results.tsv etc.) are always written in correct UTF-8"
  echo "# regardless of what this screen can display."
  echo "############################################################"
}

print_criterion_context() {
  local id="$1"
  [ "$A5_LAST_CONTEXT_ID" = "$id" ] && return 0
  A5_LAST_CONTEXT_ID="$id"
  awk -F'\t' -v id="$id" -v blue="$BLUE" -v nc="$NC" '
    NR>1 && $1==id {
      print blue "Критерий: " $1 " — " $3 nc
      print blue "Рекомендуемая точка запуска:" nc; print $5
      print blue "Команды для ручной проверки:" nc
      print "Готовые команды без служебной логики evaluator показаны ниже."
      print blue "Ожидаемый результат:" nc; print $7
      if ($8!="") { print blue "Примечания:" nc; print $8 }
      exit
    }' "$A5_CRITERIA_MAP" | tee -a "$A5_DETAIL_LOG"
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
show_output() { [ -z "$A5_PENDING_OUTPUT" ] || A5_PENDING_OUTPUT+=$'\n'; A5_PENDING_OUTPUT+="${1:-(пустой вывод)}"; }
flush_output() {
  [ -n "$A5_PENDING_OUTPUT" ] || return 0
  echo -e "${BLUE}Завершение команды:${NC}" | tee -a "$A5_DETAIL_LOG"
  printf '%s\n' "$A5_PENDING_OUTPUT" | tee -a "$A5_DETAIL_LOG"
  A5_PENDING_OUTPUT=""
}

record_result() {
  local id="$1" mark="$2" status="$3" msg="$4"
  print_criterion_context "$id"; flush_output
  printf '%s\t%s\t%s\t%s\n' "$id" "$mark" "$status" "${msg//$'\t'/ }" >> "$A5_RESULTS_TSV"
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
  local summary="$A5_REPORT_DIR/a5-summary.txt"
  awk -F'\t' 'NR>1 {
      total+=$2; count[$3]++;
      if($3=="PASS") score+=$2;
      else if($3=="PART") { msg=$4; sub(/^awarded=/,"",msg); sub(/;.*/,"",msg); score+=msg+0; missed[$3]+=$2-(msg+0) }
      else missed[$3]+=$2
    }
    END { printf "Сводка проверки A5\n===================\n";
      printf "Засчитано: %.2f / %.2f\n",score,total;
      printf "PASS: %d, PART: %d, FAIL: %d, WARN: %d, SKIP: %d\n",count["PASS"],count["PART"],count["FAIL"],count["WARN"],count["SKIP"];
      printf "Не засчитано: %.2f; частично потеряно: %.2f; предупреждения: %.2f; пропущено: %.2f\n",missed["FAIL"],missed["PART"],missed["WARN"],missed["SKIP"] }' \
    "$A5_RESULTS_TSV" | tee "$summary"
}
