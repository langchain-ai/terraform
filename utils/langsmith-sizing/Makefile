# The front door: one target per step of size -> deploy -> verify. `make` alone says what each does.
# Every recipe forwards to the CLI; the logic lives in the package, so a person without make runs
# the same commands (the README shows them).

# A sizing is a folder named for who it is for. OUT moves it, for example into a project's own folder.
NAME  ?= $(PRESET)
ROOT  ?= out
OUT   ?= $(ROOT)/$(NAME)
# Unset, the chart is the one a saved sizing was made on, else charts.yaml's default.
CHART ?=
# Inputs, as the CLI takes them: PRESET alone, or USERS with TRACES_PER_SECOND; a variable given
# replaces the preset's or the saved sizing's value. ARGS carries any other flag, ARGS="--redis operator".
PRESET ?=
USERS ?=
TRACES_PER_SECOND ?=
TRACES_PER_MONTH ?=
PEAK_TRACES_PER_SECOND ?=
RUNS_PER_TRACE ?=
RETENTION_DAYS ?=
ARGS ?=
# The load test: seconds to run and ramp. PEAK=1 sends the plan's peak rate instead of its average.
DURATION ?= 600
RAMP ?= 60
PEAK ?=
LOGS := $(ROOT)/.logs

SIZING := uv run --quiet langsmith-sizing
LOADTEST := uv run --quiet --directory ../langsmith-load-test load-test
INPUTS := $(if $(CHART),--chart $(CHART)) $(if $(PRESET),--preset $(PRESET)) $(if $(USERS),--users $(USERS)) $(if $(TRACES_PER_SECOND),--traces-per-second $(TRACES_PER_SECOND)) $(if $(TRACES_PER_MONTH),--traces-per-month $(TRACES_PER_MONTH)) $(if $(PEAK_TRACES_PER_SECOND),--peak-traces-per-second $(PEAK_TRACES_PER_SECOND)) $(if $(RUNS_PER_TRACE),--runs-per-trace $(RUNS_PER_TRACE)) $(if $(RETENTION_DAYS),--retention-days $(RETENTION_DAYS)) $(ARGS)

# One line a gate: its name, then ok or FAILED with the tail of its log. A gate's output goes to
# $(LOGS)/<gate>.log, never to the screen, unless it failed. No pipe: one through tail would hide a
# failing exit code from make.
B := $(shell [ -t 1 ] && [ -z "$$NO_COLOR" ] && printf '\033[1m')
G := $(shell [ -t 1 ] && [ -z "$$NO_COLOR" ] && printf '\033[1;32m')
R := $(shell [ -t 1 ] && [ -z "$$NO_COLOR" ] && printf '\033[1;31m')
C := $(shell [ -t 1 ] && [ -z "$$NO_COLOR" ] && printf '\033[36m')
D := $(shell [ -t 1 ] && [ -z "$$NO_COLOR" ] && printf '\033[2m')
X := $(shell [ -t 1 ] && [ -z "$$NO_COLOR" ] && printf '\033[0m')
define gate
	@mkdir -p $(LOGS); printf '  %-34s ' "$(1)"; start=$$(date +%s); \
	if $(2) > "$(LOGS)/$(1).log" 2>&1; then printf '$(G)ok$(X)   $(D)%ss$(X)\n' $$(( $$(date +%s) - start )); \
	else printf '$(R)FAILED$(X)  $(D)%s$(X)\n' "$(LOGS)/$(1).log"; tail -n 25 "$(LOGS)/$(1).log" | sed 's/^/      /'; exit 1; fi
endef
define need_name
	@test -n "$(NAME)" || { printf '$(R)error$(X) give NAME=<customer>, the sizing folder under $(ROOT)/ (make list shows them)\n' >&2; exit 2; }
endef

.DEFAULT_GOAL := help
.PHONY: help setup wizard plan show list presets load compare chart check lint types test params citations load-test-check reference figures report

help: ## this screen
	@printf '\n$(B)langsmith-sizing$(X)  size a self-hosted LangSmith install from its load, deploy it, prove it\n\n'
	@printf '  $(B)1  size$(X)     $(C)make wizard NAME=acme$(X)                 $(D)asks about the load and the install, saves $(ROOT)/acme/$(X)\n'
	@printf '             $(C)make plan NAME=acme PRESET=lite$(X)       $(D)the same, asking nothing; again later re-sizes from the saved answers$(X)\n'
	@printf '  $(B)2  deploy$(X)   $(D)provision from $(ROOT)/acme/stores.json, then helm upgrade --install with $(ROOT)/acme/values.yaml$(X)\n'
	@printf '  $(B)3  prove$(X)    $(C)make load NAME=acme$(X)                   $(D)sends the planned load at the install$(X)\n'
	@printf '             $(C)make compare NAME=acme$(X)                $(D)one verdict per promise the plan makes$(X)\n\n'
	@printf '$(B)Targets$(X)\n'
	@awk -F':.*## ' '/^[a-z-]+:.*## /{printf "  $(C)%-18s$(X) %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\n$(B)Inputs$(X)  $(D)NAME= PRESET= USERS= TRACES_PER_SECOND= TRACES_PER_MONTH= PEAK_TRACES_PER_SECOND= RUNS_PER_TRACE= RETENTION_DAYS= CHART= ARGS="--redis operator ..." OUT=<folder>$(X)\n'
	@printf '$(B)Docs$(X)    $(D)README.md, docs/how-it-sizes.md, docs/autoscaling.md, docs/monitoring.md$(X)\n\n'

setup: ## install the package and the load test (needs uv; helm reads the chart)
	$(call gate,uv sync,uv sync --group dev)
	$(call gate,uv sync load test,uv sync --directory ../langsmith-load-test)
	@command -v helm >/dev/null || printf '  $(R)helm is not on PATH$(X): sizing reads the chart with it (https://helm.sh/docs/intro/install/)\n'

wizard: ## ask, size, save the folder (NAME=; PRESET= to start from one, or it offers them)
	$(need_name)
	@$(SIZING) wizard $(INPUTS) --out $(OUT)

plan: ## size and save the folder, asking nothing (NAME= with PRESET=, USERS=..., or its saved inputs)
	$(need_name)
	@$(SIZING) plan $(INPUTS) --out $(OUT)

show: ## a saved sizing's plan again (NAME=)
	$(need_name)
	@$(SIZING) show --out $(OUT)

list: ## every saved sizing under ROOT
	@$(SIZING) list --root $(ROOT)

presets: ## the named loads a sizing can start from
	@$(SIZING) presets

chart: ## chart values at CHART (KEY=a.dotted.key, repeatable as ARGS="--key ...")
	@$(SIZING) chart-info --chart $(or $(CHART),$(shell sed -n 's/^default: //p' charts.yaml)) $(if $(KEY),--key $(KEY)) $(ARGS)

# Never run against an instance you do not own: it writes traces and feedback to the project in .env.
# The load test reads LANGSMITH_ENDPOINT, LANGSMITH_API_KEY and LANGSMITH_PROJECT from its own .env.
load: ## send the planned load at your install (NAME=; needs ../langsmith-load-test/.env); saves results.json
	$(need_name)
	@test -f $(OUT)/load-profile.json || { printf '$(R)error$(X) $(OUT)/load-profile.json is missing: run make wizard NAME=$(NAME) or make plan NAME=$(NAME) first\n' >&2; exit 2; }
	$(LOADTEST) --profile $(abspath $(OUT))/load-profile.json $(if $(PEAK),--peak) --read --duration-seconds $(DURATION) --ramp-up-seconds $(RAMP) --results $(abspath $(OUT))/results.json

compare: ## the load test's results against the plan; exit 1 on a failed promise (NAME=)
	$(need_name)
	@$(SIZING) compare --plan $(OUT)/plan.json --results $(OUT)/results.json --save $(OUT)/verdicts.json

check: ## every gate CI runs (helm required; citations need the network)
	@printf '\n$(B)Gates$(X)  $(D)logs in $(LOGS)/$(X)\n'
	$(call gate,lint,uv run --group dev ruff check src tests)
	$(call gate,types,uv run --group dev mypy --strict src)
	$(call gate,tests,env LANGSMITH_SIZING_REQUIRE_HELM=1 uv run python -m unittest discover -s tests)
	$(call gate,params against every planned chart,uv run langsmith-sizing check-params)
	$(call gate,citations at the pinned docs,uv run langsmith-sizing check-citations)
	$(call gate,load test lint,uv run --directory ../langsmith-load-test --group dev ruff check src tests)
	$(call gate,load test types,uv run --directory ../langsmith-load-test --group dev mypy --strict -p loadtest)
	$(call gate,load test tests,uv run --directory ../langsmith-load-test python -m unittest discover -s tests)
	@printf '  $(G)every gate passed$(X)\n\n'

# The gates one at a time, with their output on the screen.
lint: ## ruff
	uv run --group dev ruff check src tests
types: ## mypy --strict
	uv run --group dev mypy --strict src
# CI sets this so a missing helm fails the chart tests instead of skipping them green.
test: ## the package's tests
	LANGSMITH_SIZING_REQUIRE_HELM=1 uv run python -m unittest discover -s tests
# Both chart lines the package plans for: a release candidate can change a default under a parameter.
params: ## check-params against every chart in charts.yaml
	uv run langsmith-sizing check-params
citations: ## check-citations at the pinned docs commit
	uv run langsmith-sizing check-citations
load-test-check: ## the load test's ruff, mypy --strict and offline tests
	uv run --directory ../langsmith-load-test --group dev ruff check src tests
	uv run --directory ../langsmith-load-test --group dev mypy --strict -p loadtest
	uv run --directory ../langsmith-load-test python -m unittest discover -s tests

# Every field the outputs can carry, with its type, unit and meaning, written from real plans. A test
# fails when docs/fields.md differs, so a new field cannot ship undocumented.
reference: ## rewrite docs/fields.md, the docs' generated tables, and the load test's results fields
	uv run python -m langsmith_sizing.schema_doc
	uv run python -m langsmith_sizing.docs_gen
	uv run --directory ../langsmith-load-test python tests/results_fields.py

figures: ## redraw each figure whose data changed (needs Chrome, FONTS= the brand faces, LOGOS= the logos; DRAFT=1 without)
	uv run python -m langsmith_sizing.figures $(if $(FONTS),--fonts $(FONTS)) $(if $(LOGOS),--logos $(LOGOS)) $(if $(DRAFT),--draft)

report: ## the module profiles' presets beside the modules' hand-written profiles
	@$(SIZING) profile-report --chart $(or $(CHART),$(shell sed -n 's/^default: //p' charts.yaml))
