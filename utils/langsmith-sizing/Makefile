# The front door: one target per step of size -> deploy -> verify. `make` alone says what each does.
# Every recipe forwards to the CLI; the logic lives in the package, so a person without make runs
# the same commands (the README shows them).

# charts.yaml is the one place a chart version is written.
CHART ?= $(shell sed -n 's/^default: //p' charts.yaml)
OUT   ?= out
# Same inputs as the CLI: PRESET alone, or USERS with TRACES_PER_SECOND. A variable given replaces
# the preset's value. ARGS carries any other flag, for example ARGS="--redis operator".
PRESET ?=
USERS ?=
TRACES_PER_SECOND ?=
PEAK_TRACES_PER_SECOND ?=
RUNS_PER_TRACE ?=
RETENTION_DAYS ?=
ARGS ?=
# The load test: seconds to run and ramp. PEAK=1 sends the plan's peak rate instead of its average.
DURATION ?= 600
RAMP ?= 60
PEAK ?=
PLAN ?= $(OUT)/plan.json
RESULTS ?= $(OUT)/results.json

SIZING := uv run langsmith-sizing
LOADTEST := uv run --directory ../langsmith-load-test load-test
INPUTS := --chart $(CHART) $(if $(PRESET),--preset $(PRESET)) $(if $(USERS),--users $(USERS)) $(if $(TRACES_PER_SECOND),--traces-per-second $(TRACES_PER_SECOND)) $(if $(PEAK_TRACES_PER_SECOND),--peak-traces-per-second $(PEAK_TRACES_PER_SECOND)) $(if $(RUNS_PER_TRACE),--runs-per-trace $(RUNS_PER_TRACE)) $(if $(RETENTION_DAYS),--retention-days $(RETENTION_DAYS)) $(ARGS)

.DEFAULT_GOAL := help
.PHONY: help setup check lint types test params citations load-test-check reference figures wizard plan values stores profile load compare report

help: ## this list
	@echo "langsmith-sizing: size an install, deploy it, verify it."
	@echo ""
	@echo "  1. make setup                              install the dependencies (needs uv; helm for the chart tests)"
	@echo "  2. make wizard USERS=10 TRACES_PER_SECOND=5 PEAK_TRACES_PER_SECOND=15   ask, size, write all four files to OUT=$(OUT): plan.json, values.yaml, stores.json, load-profile.json"
	@echo "     or one file per target with the same inputs: make plan | values | stores | profile (each writes only its own file; make load needs profile)"
	@echo "  3. deploy with $(OUT)/values.yaml and provision from $(OUT)/stores.json (your Helm or Terraform)"
	@echo "  4. make load                               send the load at your instance (reads ../langsmith-load-test/.env; needs $(OUT)/load-profile.json from make wizard or make profile)"
	@echo "  5. make compare                            the load test's results against the plan"
	@echo ""
	@awk -F':.*## ' '/^[a-z-]+:.*## /{printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "Inputs: CHART=$(CHART) PRESET= USERS= TRACES_PER_SECOND= PEAK_TRACES_PER_SECOND= RUNS_PER_TRACE= RETENTION_DAYS= ARGS='' YES=1 (the wizard asks nothing)"
	@echo "Presets: see presets/README.md. All six carry an open question and none is proven."
	@echo "Next: make wizard USERS=10 TRACES_PER_SECOND=5 PEAK_TRACES_PER_SECOND=15"

setup: ## install the package and the load test's dependencies
	uv sync --group dev
	uv sync --directory ../langsmith-load-test

check: lint types test params citations load-test-check ## every gate CI runs (helm required; citations need the network)

# CI sets this so a missing helm fails the chart tests instead of skipping them green.
test: ## the package's tests
	LANGSMITH_SIZING_REQUIRE_HELM=1 uv run python -m unittest discover -s tests

lint: ## ruff
	uv run --group dev ruff check src tests

types: ## mypy --strict
	uv run --group dev mypy --strict src

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

figures: ## draw each figure whose data changed, light and dark, to docs/figures/ (needs Chrome, FONTS= the brand faces' folder, LOGOS= the logos' folder; DRAFT=1 without them)
	uv run python -m langsmith_sizing.figures $(if $(FONTS),--fonts $(FONTS)) $(if $(LOGOS),--logos $(LOGOS)) $(if $(DRAFT),--draft)

# The wizard asks for what a flag and the preset leave open; --yes stops it asking.
wizard: ## ask each input, print the headline, write the four files to OUT
	$(SIZING) wizard $(INPUTS) --out $(OUT) $(if $(YES),--yes)

# A failed command must not leave an empty file for compare or load to read: write, then move.
$(OUT):
	mkdir -p $@

plan: | $(OUT) ## size the load: OUT/plan.json
	$(SIZING) size $(INPUTS) > $(OUT)/plan.json.tmp && mv $(OUT)/plan.json.tmp $(OUT)/plan.json

values: | $(OUT) ## the chart values that apply the plan: OUT/values.yaml
	$(SIZING) values $(INPUTS) > $(OUT)/values.yaml.tmp && mv $(OUT)/values.yaml.tmp $(OUT)/values.yaml

stores: | $(OUT) ## what to provision per data store: OUT/stores.json
	$(SIZING) stores $(INPUTS) > $(OUT)/stores.json.tmp && mv $(OUT)/stores.json.tmp $(OUT)/stores.json

profile: | $(OUT) ## the load the plan was sized for, as the load test reads it: OUT/load-profile.json
	$(SIZING) load-profile $(INPUTS) > $(OUT)/load-profile.json.tmp && mv $(OUT)/load-profile.json.tmp $(OUT)/load-profile.json

# Never run against an instance you do not own: it writes traces and feedback to the project in .env.
# The load test reads LANGSMITH_ENDPOINT, LANGSMITH_API_KEY and LANGSMITH_PROJECT from its own .env.
load: ## run the load test with OUT/load-profile.json (make wizard or make profile first; needs ../langsmith-load-test/.env); writes OUT/results.json
	@test -f $(OUT)/load-profile.json || { echo "error: $(OUT)/load-profile.json is missing: run make wizard, or make profile with the same inputs, first" >&2; exit 1; }
	$(LOADTEST) --profile $(abspath $(OUT))/load-profile.json $(if $(PEAK),--peak) --read --duration-seconds $(DURATION) --ramp-up-seconds $(RAMP) --results $(abspath $(RESULTS))

compare: ## the results against the plan, one verdict per promise; exit 1 on a failed one
	$(SIZING) compare --plan $(PLAN) --results $(RESULTS)

report: ## the four presets with module profiles (minimum, dev, production, production-large) beside the modules' profiles
	$(SIZING) profile-report --chart $(CHART)
