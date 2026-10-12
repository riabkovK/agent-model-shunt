.PHONY: test test-docker test-local test-py test-bash32 test-py311

TEST_IMAGE := agent-model-shunt-tests
TEST_IMAGE_BASH32 := agent-model-shunt-tests-bash32
TEST_IMAGE_PY311 := agent-model-shunt-tests-py311

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
	docker run --rm --entrypoint pytest -v "$(CURDIR):/code" -w /code $(TEST_IMAGE) -q test/py

test-local:
	bats test

test-py:
	pytest -q test/py

# The same suite under bash 3.2 (the macOS system bash).
test-bash32:
	docker build -q -t $(TEST_IMAGE_BASH32) -f test/Dockerfile.bash32 .
	docker run --rm -v "$(CURDIR):/code" -w /code $(TEST_IMAGE_BASH32) -j 4 test
	docker run --rm --entrypoint pytest -v "$(CURDIR):/code" -w /code $(TEST_IMAGE_BASH32) -q test/py

# bats under bash 3.2 plus pytest on Python 3.11, the minimum the Python core supports.
test-py311:
	docker build -q -t $(TEST_IMAGE_PY311) -f test/Dockerfile.py311 .
	docker run --rm -v "$(CURDIR):/code" -w /code $(TEST_IMAGE_PY311) bats -j 4 test
	docker run --rm -v "$(CURDIR):/code" -w /code $(TEST_IMAGE_PY311) pytest -q test/py
