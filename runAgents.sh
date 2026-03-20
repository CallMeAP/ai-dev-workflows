#!/bin/bash
set -euo pipefail

# =============================================================================
# Agent Team Orchestrator
# Runs: Ticket Writer → QA → Impl → QA → Refactor Style
# =============================================================================

WORKFLOWS_DIR="/home/alex/Entwicklung/ai-dev-workflows"
MEMORY_DIR="$WORKFLOWS_DIR/memory"
BACKUP_DIR="/tmp/ai-dev-workflows-backup-$(date +%Y%m%d-%H%M%S)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters for summary
PHASE1_ROUNDS=0
PHASE2_ROUNDS=0
PHASE3_ROUNDS=0
FINAL_STATUS="COMPLETED"

# =============================================================================
# Parse arguments
# =============================================================================
TASK_DESC=""
SPEC_FILE=""

usage() {
  echo "Usage: $0 -t \"task description\" [-s /path/to/spec.md]"
  echo "  -t  Task description (mandatory)"
  echo "  -s  Path to spec file (optional)"
  exit 1
}

while getopts "t:s:h" opt; do
  case $opt in
    t) TASK_DESC="$OPTARG" ;;
    s) SPEC_FILE="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

if [ -z "$TASK_DESC" ]; then
  echo -e "${RED}Error: -t \"task description\" is mandatory${NC}"
  usage
fi

if [ -n "$SPEC_FILE" ] && [ ! -f "$SPEC_FILE" ]; then
  echo -e "${RED}Error: spec file not found: $SPEC_FILE${NC}"
  exit 1
fi

# Resolve spec file to absolute path
if [ -n "$SPEC_FILE" ]; then
  SPEC_FILE="$(realpath "$SPEC_FILE")"
fi

# Project dir = where the script was called from
PROJECT_DIR="$(pwd)"

echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE}  Agent Team Orchestrator${NC}"
echo -e "${BLUE}=============================================${NC}"
echo -e "Task:    ${TASK_DESC}"
echo -e "Spec:    ${SPEC_FILE:-none}"
echo -e "Project: ${PROJECT_DIR}"
echo -e "${BLUE}=============================================${NC}"

# =============================================================================
# Backup and clear memory
# =============================================================================
backup_memory() {
  local has_files=false
  for dir in "$MEMORY_DIR"/*/; do
    if [ "$(ls -A "$dir" 2>/dev/null)" ]; then
      has_files=true
      break
    fi
  done

  if [ "$has_files" = true ]; then
    echo -e "${YELLOW}Backing up existing memory to $BACKUP_DIR${NC}"
    mkdir -p "$BACKUP_DIR"
    for dir in "$MEMORY_DIR"/*/; do
      if [ "$(ls -A "$dir" 2>/dev/null)" ]; then
        local subdir
        subdir=$(basename "$dir")
        mkdir -p "$BACKUP_DIR/$subdir"
        mv "$dir"* "$BACKUP_DIR/$subdir/"
      fi
    done
    echo -e "${GREEN}Backup complete${NC}"
  else
    echo -e "${GREEN}Memory is clean, no backup needed${NC}"
  fi
}

# =============================================================================
# Build spec reference for prompts
# =============================================================================
spec_ref() {
  if [ -n "$SPEC_FILE" ]; then
    echo "Spec file: $SPEC_FILE"
  else
    echo "No spec file provided."
  fi
}

# =============================================================================
# Stream claude output live — extracts text deltas from stream-json
# =============================================================================
stream_claude() {
  local prompt="$1"
  local system_prompt_file="$2"

  cd "$PROJECT_DIR"
  claude -p "$prompt" \
    --append-system-prompt-file "$WORKFLOWS_DIR/$system_prompt_file" \
    --allowedTools "Bash,Read,Write,Edit,Glob,Grep,Agent" \
    --output-format stream-json \
    --verbose 2>&1 | while IFS= read -r line; do
      # Extract assistant text deltas
      local text
      text=$(echo "$line" | jq -r '
        select(.type == "assistant")
        | .message.content[]?
        | select(.type == "text")
        | .text // empty
      ' 2>/dev/null) || true
      if [ -n "$text" ]; then
        printf "%s" "$text"
      fi

      # Show tool use (what the agent is doing)
      local tool_name
      tool_name=$(echo "$line" | jq -r '
        select(.type == "assistant")
        | .message.content[]?
        | select(.type == "tool_use")
        | .name // empty
      ' 2>/dev/null) || true
      if [ -n "$tool_name" ]; then
        printf "\n${YELLOW}[tool: %s]${NC} " "$tool_name"
      fi

      # Show sub-agent spawns
      local agent_desc
      agent_desc=$(echo "$line" | jq -r '
        select(.type == "assistant")
        | .message.content[]?
        | select(.type == "tool_use" and .name == "Agent")
        | .input.description // empty
      ' 2>/dev/null) || true
      if [ -n "$agent_desc" ]; then
        printf "${BLUE}→ %s${NC}\n" "$agent_desc"
      fi
    done
  echo ""
}

# =============================================================================
# Run a team via claude CLI with live streaming
# =============================================================================
run_team() {
  local prompt="$1"
  local system_prompt_file="$2"
  local label="$3"

  echo ""
  echo -e "${BLUE}==== $label ====${NC}"
  echo -e "${BLUE}System prompt: $system_prompt_file${NC}"
  echo ""

  stream_claude "$prompt" "$system_prompt_file" || true
}

# =============================================================================
# Evaluate QA reports — returns 0 (YES) or 1 (NO)
# =============================================================================
evaluate_qa() {
  local phase_name="$1"
  local qa_dir="$MEMORY_DIR/3_qa"

  local qa_files
  qa_files=$(find "$qa_dir" -name "*.md" -type f 2>/dev/null | sort)

  if [ -z "$qa_files" ]; then
    echo -e "${YELLOW}No QA reports found, assuming pass${NC}"
    return 0
  fi

  local qa_content=""
  for f in $qa_files; do
    qa_content+="--- $(basename "$f") ---"$'\n'
    qa_content+="$(cat "$f")"$'\n\n'
  done

  echo -e "${YELLOW}Evaluating QA reports for $phase_name...${NC}"

  local result
  result=$(claude -p "$(cat <<EOF
You are evaluating QA reports from $phase_name.

QA Reports:
$qa_content

Does the work pass QA and is ready to proceed to the next phase?
Consider: are there any HIGH or MEDIUM severity confirmed issues remaining?

Reply with EXACTLY one word on the first line: YES or NO
Then a one-line reason on the second line.
EOF
)" --max-turns 1 2>/dev/null || echo "YES (evaluator failed, proceeding)")

  echo -e "Evaluator says: ${result}"

  if echo "$result" | head -1 | grep -qi "YES"; then
    echo -e "${GREEN}QA passed for $phase_name${NC}"
    return 0
  else
    echo -e "${RED}QA failed for $phase_name${NC}"
    return 1
  fi
}

# =============================================================================
# Phase 1: Tickets (max 3 rounds)
# =============================================================================
phase1_tickets() {
  echo ""
  echo -e "${BLUE}=============================================${NC}"
  echo -e "${BLUE}  PHASE 1: Ticket Creation${NC}"
  echo -e "${BLUE}=============================================${NC}"

  for round in 1 2 3; do
    PHASE1_ROUNDS=$round
    echo -e "${YELLOW}--- Phase 1, Round $round ---${NC}"

    # Run Ticket Writer
    run_team "$(cat <<EOF
Deploy ticket writer team.
Task: $TASK_DESC
$(spec_ref)
Read all existing files in $MEMORY_DIR/ to make yourself familiar with prior work.
This is Phase 1, Round $round.
EOF
)" "1_agent_team_ticket_writer.md" "Ticket Writer Team (Phase 1, Round $round)"

    # Run QA on tickets
    run_team "$(cat <<EOF
Deploy QA team to audit the tickets created by the ticket writer team.
Task: $TASK_DESC
$(spec_ref)
Read all existing files in $MEMORY_DIR/ to make yourself familiar with prior work.
Focus your audit on the ticket quality in $MEMORY_DIR/1_tickets/.
This is Phase 1, Round $round — QA review.
EOF
)" "3_agent_team_QA.md" "QA Team — Ticket Review (Phase 1, Round $round)"

    # Evaluate
    if evaluate_qa "Phase 1 Round $round"; then
      echo -e "${GREEN}Phase 1 complete after $round round(s)${NC}"
      return 0
    fi

    if [ "$round" -eq 3 ]; then
      echo -e "${YELLOW}WARNING: Phase 1 did not pass QA after 3 rounds. Continuing anyway.${NC}"
      return 0
    fi

    echo -e "${YELLOW}Re-running ticket writer...${NC}"
  done
}

# =============================================================================
# Phase 2: Implementation (max 3 rounds)
# =============================================================================
phase2_implementation() {
  echo ""
  echo -e "${BLUE}=============================================${NC}"
  echo -e "${BLUE}  PHASE 2: Implementation${NC}"
  echo -e "${BLUE}=============================================${NC}"

  for round in 1 2 3; do
    PHASE2_ROUNDS=$round
    echo -e "${YELLOW}--- Phase 2, Round $round ---${NC}"

    # Run Impl Team
    local impl_prompt
    if [ "$round" -eq 1 ]; then
      impl_prompt="Deploy implementer team to implement the tasks."
    else
      impl_prompt="Deploy implementer team to fix the issues found by QA in the previous round."
    fi

    run_team "$(cat <<EOF
$impl_prompt
Task: $TASK_DESC
$(spec_ref)
Read all existing files in $MEMORY_DIR/ to make yourself familiar with prior work, especially tickets in $MEMORY_DIR/1_tickets/.
This is Phase 2, Round $round.
EOF
)" "2_agent_team_impl.md" "Implementer Team (Phase 2, Round $round)"

    # Run QA on implementation
    run_team "$(cat <<EOF
Deploy QA team to audit the implementation.
Task: $TASK_DESC
$(spec_ref)
Read all existing files in $MEMORY_DIR/ to make yourself familiar with prior work.
Focus your audit on the code implementation, not the tickets.
This is Phase 2, Round $round — QA review.
EOF
)" "3_agent_team_QA.md" "QA Team — Impl Review (Phase 2, Round $round)"

    # Evaluate
    if evaluate_qa "Phase 2 Round $round"; then
      echo -e "${GREEN}Phase 2 complete after $round round(s)${NC}"
      return 0
    fi

    if [ "$round" -eq 3 ]; then
      echo -e "${YELLOW}WARNING: Phase 2 did not pass QA after 3 rounds. Continuing anyway.${NC}"
      return 0
    fi

    echo -e "${YELLOW}Re-running implementer for bug fixes...${NC}"
  done
}

# =============================================================================
# Phase 3: Refactor Style (max 2 rounds)
# =============================================================================
phase3_refactor() {
  echo ""
  echo -e "${BLUE}=============================================${NC}"
  echo -e "${BLUE}  PHASE 3: Refactor Style${NC}"
  echo -e "${BLUE}=============================================${NC}"

  for round in 1 2; do
    PHASE3_ROUNDS=$round
    echo -e "${YELLOW}--- Phase 3, Round $round ---${NC}"

    # Run Refactor Style Team
    run_team "$(cat <<EOF
Deploy refactor style team on the implementation files that were modified.
Task: $TASK_DESC
Read all existing files in $MEMORY_DIR/ to make yourself familiar with prior work.
This is Phase 3, Round $round.
EOF
)" "4_agent_team_refactor_style.md" "Refactor Style Team (Phase 3, Round $round)"

    # Check build
    echo -e "${YELLOW}Checking build...${NC}"
    cd "$PROJECT_DIR"
    if dotnet build 2>&1 | grep -qiE "warning|error"; then
      local warnings
      warnings=$(dotnet build 2>&1 | grep -ciE "warning" || true)
      local errors
      errors=$(dotnet build 2>&1 | grep -ciE "error" || true)
      echo -e "${YELLOW}Build: $errors error(s), $warnings warning(s)${NC}"

      if [ "$round" -eq 2 ]; then
        echo -e "${YELLOW}WARNING: Build still has warnings after 2 rounds.${NC}"
        return 0
      fi
      echo -e "${YELLOW}Re-running refactor...${NC}"
    else
      echo -e "${GREEN}Build is clean${NC}"
      echo -e "${GREEN}Phase 3 complete after $round round(s)${NC}"
      return 0
    fi
  done
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
  echo ""
  echo -e "${BLUE}=============================================${NC}"
  echo -e "${BLUE}  SUMMARY${NC}"
  echo -e "${BLUE}=============================================${NC}"
  echo -e "Status:          ${GREEN}$FINAL_STATUS${NC}"
  echo -e "Phase 1 rounds:  $PHASE1_ROUNDS"
  echo -e "Phase 2 rounds:  $PHASE2_ROUNDS"
  echo -e "Phase 3 rounds:  $PHASE3_ROUNDS"
  echo ""
  echo -e "${BLUE}Generated reports:${NC}"
  find "$MEMORY_DIR" -name "*.md" -type f | sort | while read -r f; do
    echo "  $f"
  done
  echo ""
  echo -e "${BLUE}=============================================${NC}"
}

# =============================================================================
# Main
# =============================================================================
main() {
  backup_memory

  phase1_tickets
  phase2_implementation
  phase3_refactor

  print_summary
}

main
