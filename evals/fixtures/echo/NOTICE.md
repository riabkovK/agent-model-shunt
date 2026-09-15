# Fixture provenance

The `.go` files in this directory are verbatim, unmodified copies from
[labstack/echo](https://github.com/labstack/echo), pinned to release
[`v5.3.1`](https://github.com/labstack/echo/releases/tag/v5.3.1), used here
only as realistic input for `evals/baseline-benchmark.sh` and
`evals/benchmark.sh` (token/latency measurement, not redistribution as part
of this project). `LICENSE` in this directory is echo's own MIT license,
kept alongside per its terms.

Re-fetch with the exact commands used to pull them:

```bash
BASE="https://raw.githubusercontent.com/labstack/echo/v5.3.1"
for f in echo.go context.go router.go group.go middleware/cors.go middleware/cors_test.go LICENSE; do
  curl -s -o "$(basename "$f")" "$BASE/$f"
done
```
