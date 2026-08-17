## What and why

<!-- What changed, and why that was the right call. The diff shows the what. -->

## Verified with

- [ ] `bash tests/validate-configs.sh`
- [ ] `make lint`
- [ ] `make up && make smoke`
- [ ] `cd examples/wordcount && mvn verify` (if Java changed)

## Checklist

- [ ] New configuration properties carry an inline comment explaining the value
- [ ] `docs/04-configuration-reference.md` updated if properties changed
- [ ] No learning-mode relaxation leaked into `conf/cluster` or `conf/ha`
