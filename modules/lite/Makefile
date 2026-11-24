# LangSmith Lite: one box, everything on it. Each target is one verb of bin/lite; `make` lists them.
# Terraform flags pass through ARGS (make plan ARGS="-var box=m"); YES=1 and VERBOSE=1 pass through too.

LITE := bin/lite
VERBS := init secrets preflight plan up install access status load down values pins render check tf

.DEFAULT_GOAL := help
.PHONY: help $(VERBS)

help:
	@$(LITE) help

$(VERBS):
	@$(LITE) $@ $(ARGS)
