# The front door: one target per step. `make` alone says what each does. Every recipe forwards to the
# CLI (`uv run load-test`), so a person without make runs the same commands (the README shows them).

# A sizing saved by ../langsmith-sizing (make plan NAME=acme): its load profile is what this sends, and
# the results land beside it, where `make compare NAME=acme` there reads them.
NAME ?=
SIZINGS ?= ../langsmith-sizing/out
PROFILE ?= $(if $(NAME),$(SIZINGS)/$(NAME)/load-profile.json)
RESULTS ?= $(if $(NAME),$(SIZINGS)/$(NAME)/results.json,out/results.json)
# Seconds to run after the ramp, and the ramp. PEAK=1 sends the profile's peak rate instead of its average.
DURATION ?= 600
RAMP ?= 60
PEAK ?=
# Any other flag, for example ARGS="--max-in-flight 2000".
ARGS ?=
LOGS := out/.logs

B := $(shell [ -t 1 ] && [ -z "$$NO_COLOR" ] && printf '\033[1m')
G := $(shell [ -t 1 ] && [ -z "$$NO_COLOR" ] && printf '\033[1;32m')
R := $(shell [ -t 1 ] && [ -z "$$NO_COLOR" ] && printf '\033[1;31m')
C := $(shell [ -t 1 ] && [ -z "$$NO_COLOR" ] && printf '\033[36m')
D := $(shell [ -t 1 ] && [ -z "$$NO_COLOR" ] && printf '\033[2m')
X := $(shell [ -t 1 ] && [ -z "$$NO_COLOR" ] && printf '\033[0m')
# One line a gate, its output in $(LOGS)/<gate>.log unless it failed. No pipe on the gate itself: one
# through tail would hide its exit code from make.
define gate
	@mkdir -p $(LOGS); printf '  %-24s ' "$(1)"; start=$$(date +%s); \
	if $(2) > "$(LOGS)/$(1).log" 2>&1; then printf '$(G)ok$(X)   $(D)%ss$(X)\n' $$(( $$(date +%s) - start )); \
	else printf '$(R)FAILED$(X)  $(D)%s$(X)\n' "$(LOGS)/$(1).log"; tail -n 25 "$(LOGS)/$(1).log" | sed 's/^/      /'; exit 1; fi
endef
define need_env
	@test -f .env || { printf '$(R)error$(X) no .env here: cp .env.example .env, then set the endpoint, API key, project and LANGSMITH_TRACING=true\n' >&2; exit 2; }
endef

.DEFAULT_GOAL := help
.PHONY: help setup smoke run check

help: ## this screen
	@printf '\n$(B)langsmith-load-test$(X)  send a sizing plan'"'"'s load at your install, read it back, measure lag and loss\n\n'
	@printf '  $(B)1  connect$(X)  $(D)cp .env.example .env, then set the endpoint, API key, project and LANGSMITH_TRACING=true$(X)\n'
	@printf '  $(B)2  check$(X)    $(C)make smoke$(X)              $(D)10 traces in 30 s: confirm they appear in the project before raising the load$(X)\n'
	@printf '  $(B)3  run$(X)      $(C)make run NAME=acme$(X)      $(D)the load sizing acme was planned for, results saved beside its plan$(X)\n'
	@printf '  $(B)4  judge$(X)    $(D)in ../langsmith-sizing: $(X)$(C)make compare NAME=acme$(X)\n\n'
	@printf '$(B)Targets$(X)\n'
	@awk -F':.*## ' '/^[a-z-]+:.*## /{printf "  $(C)%-10s$(X) %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\n$(B)Inputs$(X)  $(D)NAME= (a sizing in $(SIZINGS)/) or PROFILE=<load-profile.json>, DURATION=$(DURATION) RAMP=$(RAMP) PEAK=1 RESULTS= ARGS="..."$(X)\n'
	@printf '$(B)Never$(X)   $(D)against an install you do not own: it writes traces and feedback to the project in .env$(X)\n\n'

setup: ## install the dependencies (needs uv)
	$(call gate,uv sync,uv sync --group dev)

smoke: ## a small test: 10 traces or 30 s, one user
	$(need_env)
	@uv run --quiet load-test --users 1 --duration-seconds 30 --run-limit 10 --pause-seconds 1

run: ## send a profile's load with reads (NAME= or PROFILE=); saves the results
	$(need_env)
	@test -n "$(PROFILE)" || { printf '$(R)error$(X) give NAME=<sizing> (a folder in $(SIZINGS)/) or PROFILE=<load-profile.json>\n' >&2; exit 2; }
	@test -f "$(PROFILE)" || { printf '$(R)error$(X) %s is missing: in ../langsmith-sizing, make plan NAME=%s first\n' "$(PROFILE)" "$(or $(NAME),<sizing>)" >&2; exit 2; }
	@mkdir -p $(dir $(RESULTS))
	@uv run --quiet load-test --profile $(abspath $(PROFILE)) $(if $(PEAK),--peak) --read --duration-seconds $(DURATION) --ramp-up-seconds $(RAMP) --results $(abspath $(RESULTS)) $(ARGS)

check: ## every gate CI runs: ruff, mypy --strict, the offline tests
	@printf '\n$(B)Gates$(X)  $(D)logs in $(LOGS)/$(X)\n'
	$(call gate,lint,uv run --group dev ruff check src tests)
	$(call gate,types,uv run --group dev mypy --strict -p loadtest)
	$(call gate,tests,uv run python -m unittest discover -s tests)
	@printf '  $(G)every gate passed$(X)\n\n'
