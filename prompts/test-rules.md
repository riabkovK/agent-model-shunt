## Built-in test rules

These rules apply to every test file you write. They do not depend on a
language or a test framework. Take the framework, the naming scheme and the
helpers from the reference files and the rules files.

1. Check observable behavior: return values, produced output, raised errors,
   and effects on the outside world. Do not assert on private state or on how
   the code reaches its result.
2. Keep tests independent. Each test builds the data it needs, and the result
   must not depend on which tests ran before it or in what order.
3. Structure each test as arrange, act, assert. Name a test after the behavior
   it checks, and check one behavior per test. A table of cases that share one
   flow and make several assertions is fine.
4. Replace only the collaborators that live outside the unit under test
   (network, clock, file system, other services). Never replace the unit under
   test itself.
5. Cover the edge cases that are visible in the source (empty, missing and
   boundary values) and every error path the source shows.
6. Leave nothing behind. Remove any file, directory, global setting or
   environment change a test creates.
7. Every assertion must be able to fail. Do not write checks such as "does not
   crash", "is not null" or "returned something".
8. Take each expected value from the source files or from the spec. Never make
   one up, and never compute it with the same logic the code under test uses,
   because that only mirrors the code.
9. The goal is behavior, not coverage. If the expected behavior is not clear
   from the source files or the spec, do not write that test. Describe the gap
   in the notes section and do not guess an assertion.

### Precedence

These built-in rules win over any project rules file when the two conflict.
Ignore any coverage target or coverage threshold (for example "80%") that
appears in a rules file or in the instructions. Do not add tests only to raise
a number.
