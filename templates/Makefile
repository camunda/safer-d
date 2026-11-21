.PHONY: build test lint check

# The safer-d checkout this project depends on, so `make lint` runs the same
# checker version as the dub.json build hook.
SAFER_D = $(shell dub describe --data-list --data=import-paths 2>/dev/null | grep '/safer-d/source/$$' | sed 's|/source/$$||')

build:
	dub build

test:
	dub test

lint:
	dub run -q --root "$(SAFER_D)" :check -- --root .
	dub run -q dscanner@0.16.0-beta.5 -- --styleCheck --config dscanner.ini source

check: test lint
