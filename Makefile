.PHONY: test test-docker test-local

TEST_IMAGE := agent-model-shunt-tests

# Default: run in a container (bats/bats + jq) so contributors and CI don't
# need bats-core installed on the host. Falls back to a local `bats` binary
# only if Docker isn't available.
test:
	@if command -v docker >/dev/null 2>&1; then \
		$(MAKE) test-docker; \
	elif command -v bats >/dev/null 2>&1; then \
		$(MAKE) test-local; \
	else \
		echo "Neither docker nor bats found. Install Docker, or bats-core (+ bats-support, bats-assert, jq) to run tests." >&2; \
		exit 1; \
	fi

test-docker:
	docker build -q -t $(TEST_IMAGE) -f test/Dockerfile .
	docker run --rm -v "$(CURDIR):/code" -w /code $(TEST_IMAGE) test

test-local:
	bats test
