#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# _sizing.sh — Checks for the one sizing every AWS install runs from 0.18, which
# langsmith-values.yaml sets. Sourced by deploy.sh, which stops on a 0.17 sizing
# file and warns about base values without the sizing, and by status.sh, which
# reports both.

# _old_sizing_files <values_dir>
# Prints the name of each 0.17 langsmith-values-sizing-*.yaml in the directory,
# one per line. make init-values copied the profile's file there on 0.17, and
# deploy.sh no longer loads it, so any value in it would silently stop applying.
_old_sizing_files() {
  local f
  for f in "$1"/langsmith-values-sizing-*.yaml; do
    [[ -e "$f" ]] && echo "${f##*/}"
  done
  return 0
}

# _base_sizing_gaps <langsmith-values.yaml>
# make init-values copies langsmith-values.yaml only when helm/values has none,
# so a copy made on 0.17 lacks the sizing. Prints each part of the sizing the file
# does not set, one per line: backend, frontend, and
# config.settings.redisRunsExpirySeconds. Prints nothing for a missing file.
_base_sizing_gaps() {
  [[ -f "$1" ]] || return 0
  awk '
    /^[^ #]/ { top = $1; sub(/:.*/, "", top); keys[top] = 1 }
    top == "config" && /^[[:space:]]+redisRunsExpirySeconds:/ { expiry = 1 }
    END {
      if (!("backend" in keys)) print "backend"
      if (!("frontend" in keys)) print "frontend"
      if (!expiry) print "config.settings.redisRunsExpirySeconds"
    }
  ' "$1"
}
