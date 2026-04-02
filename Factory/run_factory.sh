#!/usr/bin/env bash
# run_factory.sh
# Studio.92 — Builder Launcher
#
# Thin wrapper around the direct agentic builder CLI.
#
# USAGE:
#   ./Factory/run_factory.sh --review "Scaffold an iOS app shell"
#   ./Factory/run_factory.sh --plan "Research the latest App Store privacy manifest rules"
#   ./Factory/run_factory.sh --full-send --model opus "Fix the build and prepare TestFlight upload"

set -euo pipefail

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[0;33m'
BLU='\033[0;34m'
BLD='\033[1m'
RST='\033[0m'

FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$FACTORY_DIR")"

MODE_FLAG="--review"
MODEL_FLAG=""
MAX_ITERATIONS_FLAG=""
DRY_RUN=false
GOAL=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] "<goal>"

Options:
  --plan                Read-only planning mode
  --review              Review mode (default)
  --full-send           Full autonomous execution mode
  --model <model>       opus | sonnet | haiku
  --max-iterations <n>  Maximum tool-use loops
  --dry-run             Print prompt and tools without calling the API
  --help                Show this message
EOF
}

header() {
  echo ""
  echo -e "${BLD}${BLU}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
  echo -e "${BLD}${BLU}  $1${RST}"
  echo -e "${BLD}${BLU}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
}

log_warn()    { echo -e "${YEL}⚠  $*${RST}"; }
log_error()   { echo -e "${RED}✖  $*${RST}" >&2; }
log_success() { echo -e "${GRN}✓  $*${RST}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)                MODE_FLAG="--plan"; shift ;;
    --review)              MODE_FLAG="--review"; shift ;;
    --full-send)           MODE_FLAG="--full-send"; shift ;;
    --model)
      [[ $# -lt 2 ]] && { log_error "--model requires a value"; usage; exit 1; }
      MODEL_FLAG="--model $2"
      shift 2
      ;;
    --max-iterations)
      [[ $# -lt 2 ]] && { log_error "--max-iterations requires a value"; usage; exit 1; }
      MAX_ITERATIONS_FLAG="--max-iterations $2"
      shift 2
      ;;
    --dry-run)             DRY_RUN=true; shift ;;
    --help|-h)             usage; exit 0 ;;
    *)
      GOAL="$1"
      shift
      ;;
  esac
done

if [[ -z "$GOAL" ]]; then
  log_error "Goal argument is required."
  usage
  exit 1
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && [[ "$DRY_RUN" != true ]]; then
  log_error "ANTHROPIC_API_KEY is required for live runs."
  exit 1
fi

header "Studio.92 Builder"
echo -e "  ${BLD}Goal:${RST} $GOAL"
echo -e "  ${BLD}Mode:${RST} ${MODE_FLAG#--}"
echo -e "  ${BLD}Time:${RST} $(date '+%Y-%m-%d %H:%M:%S')"

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  log_warn "OPENAI_API_KEY not set — web research and advanced terminal execution may be reduced."
fi

cd "$REPO_ROOT"

if $DRY_RUN; then
  log_success "Printing dry-run prompt preview."
  exec swift run council "$MODE_FLAG" ${MODEL_FLAG:-} ${MAX_ITERATIONS_FLAG:-} --dry-run "$GOAL"
fi

exec swift run council "$MODE_FLAG" ${MODEL_FLAG:-} ${MAX_ITERATIONS_FLAG:-} "$GOAL"
