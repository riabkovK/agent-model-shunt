role: bulk-read
- Read over {{MIN_LINES}} lines, logs, generated, vendored or data files, or when you need an answer rather than exact bytes: use /bulk-reader.
- Never delegate a file you will edit (Read with offset/limit), files under the threshold, or secret/security-sensitive files.
- On failure or empty output retry once, then Read in slices. Do not loop.
