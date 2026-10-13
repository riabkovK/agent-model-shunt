.PHONY: test test-docker test-local test-py test-bash32 test-py311

# A hung bats run (leaked parallel slot) fails after this many seconds.
BATS_TIMEOUT := 900
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
	docker run --rm --init --entrypoint timeout -v "$(CURDIR):/code" -w /code $(TEST_IMAGE) $(BATS_TIMEOUT) bats test
	docker run --rm -e PYTHONDONTWRITEBYTECODE=1 --entrypoint pytest -v "$(CURDIR):/code" -w /code $(TEST_IMAGE) -q -p no:cacheprovider test/py

# Host run: bats smoke tests, then pytest. Without a host pytest, falls back to
# the Python 3.11 test image (build it with `make test-py311` or the docker build line there).
test-local:
	timeout $(BATS_TIMEOUT) bats -j 4 test
	@if command -v pytest >/dev/null 2>&1; then \
		pytest -q -p no:cacheprovider test/py; \
	elif command -v docker >/dev/null 2>&1; then \
		echo "pytest not found on the host, running it in the $(TEST_IMAGE_PY311) container"; \
		docker build -q -t $(TEST_IMAGE_PY311) -f test/Dockerfile.py311 . >/dev/null; \
		docker run --rm -e PYTHONDONTWRITEBYTECODE=1 --init -v "$(CURDIR):/code" -w /code $(TEST_IMAGE_PY311) pytest -q -p no:cacheprovider test/py; \
	else \
		echo "pytest not found and no docker, cannot run test/py" >&2; exit 1; \
	fi

test-py:
	pytest -q -p no:cacheprovider test/py

# The same suite under bash 3.2 (the macOS system bash).
test-bash32:
	docker build -q -t $(TEST_IMAGE_BASH32) -f test/Dockerfile.bash32 .
	docker run --rm --init --entrypoint timeout -v "$(CURDIR):/code" -w /code $(TEST_IMAGE_BASH32) $(BATS_TIMEOUT) bats -j 4 test
	docker run --rm -e PYTHONDONTWRITEBYTECODE=1 --entrypoint pytest -v "$(CURDIR):/code" -w /code $(TEST_IMAGE_BASH32) -q -p no:cacheprovider test/py

# bats under bash 3.2 plus pytest on Python 3.11, the minimum the Python core supports.
test-py311:
	docker build -q -t $(TEST_IMAGE_PY311) -f test/Dockerfile.py311 .
	docker run --rm --init --entrypoint timeout -v "$(CURDIR):/code" -w /code $(TEST_IMAGE_PY311) $(BATS_TIMEOUT) bats -j 4 test
	docker run --rm -e PYTHONDONTWRITEBYTECODE=1 -v "$(CURDIR):/code" -w /code $(TEST_IMAGE_PY311) pytest -q -p no:cacheprovider test/py
