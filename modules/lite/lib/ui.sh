#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# How every Lite command reads, on the laptop and on the box (install.sh ships this file with box/):
# a heading, one line a step ending ok or FAILED, aligned fields, rows of checks, and the next command.
#
# Colour only on a terminal, and never with NO_COLOR set (no-color.org); FORCE_COLOR=1 keeps it on the
# box when the laptop's own output is a terminal but ssh's is a pipe. Works on bash 3.2 (macOS).
# shellcheck disable=SC2034  # the colour codes are read by the files that source this one

if [[ (-t 1 || "${FORCE_COLOR:-}" == 1) && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' CYAN=$'\e[36m' OFF=$'\e[0m'
else
  BOLD='' DIM='' RED='' GREEN='' YELLOW='' CYAN='' OFF=''
fi

heading() { printf '\n%s%s%s  %s%s%s\n\n' "$BOLD" "$1" "$OFF" "$DIM" "${2:-}" "$OFF"; }

field() { printf '  %s%-18s%s %s\n' "$DIM" "$1" "$OFF" "$2"; }

next() { printf '\n  %snext%s               %s%s%s\n\n' "$DIM" "$OFF" "$CYAN" "$*" "$OFF"; }

warn() { printf '  %swarning%s            %s\n' "$YELLOW" "$OFF" "$*" >&2; }

# fail "what failed" ["why or what to do" ...]
fail() {
  local line
  printf '\n  %sERROR%s  %s\n' "$RED" "$OFF" "$1" >&2
  shift
  for line in "$@"; do printf '         %s\n' "$line" >&2; done
  printf '\n' >&2
  exit 1
}

# row ok|warn|FAIL "check" "detail"
row() {
  local colour="$GREEN"
  case "$1" in warn) colour="$YELLOW" ;; FAIL) colour="$RED" ;; esac
  printf '  %s%-5s%s %-12s %s%s%s\n' "$colour" "$1" "$OFF" "$2" "$DIM" "$3" "$OFF"
}

LOG_DIR=""
start_log() {
  LOG_DIR="$1/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$LOG_DIR"
}

# run LABEL "what it does" COMMAND [ARG ...]: the step's output goes to its log, shown only on failure.
run() {
  local label="$1" what="$2" log
  shift 2
  log="${LOG_DIR:?start_log first}/$label.log"
  # A label repeated in one command (a render case) keeps every log.
  local n=2
  while [[ -e "$log" ]]; do log="$LOG_DIR/$label.$((n++)).log"; done
  printf '  %-18s %s%s%s ' "$label" "$DIM" "$what" "$OFF"
  if "$@" >"$log" 2>&1; then
    printf '%sok%s\n' "$GREEN" "$OFF"
    return 0
  fi
  printf '%sFAILED%s\n\n' "$RED" "$OFF"
  tail -n 30 "$log" | sed 's/^/      /' >&2
  printf '\n      %sthe whole log: %s%s\n\n' "$DIM" "$log" "$OFF" >&2
  exit 1
}
