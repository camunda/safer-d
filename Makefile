.PHONY: build test self-check e2e lint check

build:
	dub build -q :check

test:
	dub test -q
	dub test -q :check

# safer-d holds itself to its own rules (safer-d.json at the root).
self-check: build
	./safer-d-check --root .

# `init` makes a project that tests, runs, and fails its build on a violation.
e2e: build
	scripts/e2e.sh

lint:
	dub run -q dscanner@0.16.0-beta.5 -- --styleCheck --config dscanner.ini source check/source

check: test self-check e2e lint
