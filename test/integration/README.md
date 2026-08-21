# Infrastructure (real infrastructure) tests

Collected by `rake test_infrastructure` only; the default `rake test` task
explicitly excludes test/integration/**/test_*.rb and must never attempt any
inference.

## Endpoint targets

- `test/scout/llm/test_infrastructure.rb` - general suite. Uses the endpoint
  named `test` when it is defined at installation level
  (~/.scout/etc/AI/test.yaml and friends); when it is not defined it
  specifies no endpoint at all and the installation default applies. Omits
  with a detected reason when neither can serve an ask.

- `test/scout/llm/backends/test_endpoints.rb` - per-backend suite. For each
  backend (openai, responses, anthropic, ollama, bedrock, openwebui, relay)
  it looks for an endpoint with the same name; missing endpoints omit with
  the detected reason, configured ones run the three probes and report
  latency/tokens in the shared summary.

The repo deliberately ships only the offline `mock` endpoint
(test/etc/AI/mock.yaml) so that `mock` is always available offline while the
`test` and backend endpoints remain the user's own, installation-level
configuration. Neither `rake test` nor `rake test_infrastructure` defines
them repo-side.

## Probe reporting

Probes never raise: outcomes are collected by
`test/support/infrastructure_probes.rb`, printed at the end of the run, and
written to `results/infrastructure_summary.md` as a table of
target | probe | OK/FAIL/OMIT | latency | answer/reason.
