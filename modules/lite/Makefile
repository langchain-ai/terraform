# LangSmith Lite: one box, everything on it. Each target is one verb of bin/lite; `make` lists them.
# Settings given as NAME=value (make up box=m) reach bin/lite's environment and are saved in the tfvars;
# ARGS passes Terraform flags; YES=1 and VERBOSE=1 pass through too.

LITE := bin/lite
VERBS := up plan preflight export access status load down secrets values pins render check tf

.DEFAULT_GOAL := help
.PHONY: help $(VERBS)

help:
	@$(LITE) help

$(VERBS):
	@$(LITE) $@ $(ARGS)
