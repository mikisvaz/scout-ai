# scout-ai subsystem studies

Ten curated subsystem studies of the scout-ai repository, promoted from the
2026-09-10/11 Cortex subsystem studies. Each file records **verified
behavior** (data model, invariants, APIs, flows, exact semantics), the
**still-open sharp edges**, open questions, and the evidence anchors
(file:line references against this checkout plus probe receipts).

The studies complement `doc/`, they do not replace it: `doc/` is normative
and describes intended use, while these files go deeper into internals,
invariants and traps, and cross-reference doc pages by path instead of
restating them.

## Reading order

`entry-cli` (how you get in) -> `chat` (the data model) -> `backends` +
`tools` (inference and tool dispatch) -> `agent-delegation` +
`agentworkflow` + `agent-society` (the agent layer) -> `provenance` (what it
all left behind). `embed-image` and `model-ml` are self-contained side
layers.

## Studies

| file | subsystem |
|---|---|
| [chat.md](chat.md) | Chat data model and compilation pipeline |
| [provenance.md](provenance.md) | Provenance, receipts, token accounting |
| [agent-delegation.md](agent-delegation.md) | Agent class and delegation semantics |
| [backends.md](backends.md) | LLM backend layer and inference loop |
| [tools.md](tools.md) | Tool definitions, dispatch, MCP |
| [agentworkflow.md](agentworkflow.md) | AgentWorkflow mixin and job binding |
| [embed-image.md](embed-image.md) | Embeddings, RAG, images, multimodal input |
| [model-ml.md](model-ml.md) | ScoutModel / Torch / HuggingFace ML layer |
| [entry-cli.md](entry-cli.md) | Entry points, CLI, config surface |
| [agent-society.md](agent-society.md) | Agent directories and society harness |

## Findings index

Cross-subsystem findings, numbered as in the source studies. Only
**still-open** items are described here; fixed ones are listed in one line
each.

### Fixed in the working tree (2026-09-11, uncommitted)

| # | finding | where |
|---|---|---|
| F1 | `attach` tool never attached PDFs (normalization overwrite + bare-`case` dispatcher); now `auto`-only normalization with a subject-form dispatcher, unknown types raise. `test/scout/llm/agent/test_attach.rb` 8/0. | [embed-image.md](embed-image.md) |
| F2 | MCP server serving broken against `mcp` gem 1.1.0 (keyword invocation, lost `self` binding, non-`Response` return, Symbol tool names); fixed in `lib/scout/llm/mcp.rb`, `test/scout/llm/tools/test_mcp.rb` 3/0, re-verified on `mcp` 1.5.1. | [tools.md](tools.md) |
| F5 | `LLM.embed` never merged endpoint YAML (extensionless `exists?`) and failed silently on a missing endpoint; now matches the ask/image contract. `test/scout/llm/test_embed.rb` 6/0. | [embed-image.md](embed-image.md) |
| F7 | Default TorchModel train block assigned an SGD optimizer to `@criterion`, breaking default training; one-line fix plus a gated regression test (2/0). | [model-ml.md](model-ml.md) |

### Still open

| # | finding | owner |
|---|---|---|
| F3 | `scout-ai config set ...` does not exist although two maintained user docs instruct it; workaround is hand-writing `~/.scout/etc/AI/<endpoint>.yaml` or `-ck key=value`. | [entry-cli.md](entry-cli.md) |
| F4 | `introduce:` generates zero tools - documentation injection only, despite ToolCalling.md's claim. Whole-workflow tooling needs a bare `tool: MyWorkflow`. | [tools.md](tools.md) |
| F6 | Model restore precedence inversion: `load_options` merges the saved `options.json` over constructor options, so a reloaded model ignores a fresh `checkpoint` argument. | [model-ml.md](model-ml.md) |
| F8 | No retry/backoff at the backend layer despite Backends.md's claim; a `query` raise propagates raw (only OpenWebUI's `Misc.insist` and the optional `Agent#process_exception` hook exist). | [backends.md](backends.md) |
| F9 | No streaming anywhere (`stream_results` does not exist); the only stream token is ollama's `stream: false`. | [backends.md](backends.md) |
| F10 | Tool-definition `defaults` **override** model arguments and hide the input from the visible schema (`function_arguments.merge(defaults)`). | [tools.md](tools.md) |
| F11 | Dead/broken dispatch branches: embed `:relay`/`:openwebui`, image `:relay`/`:bedrock`, `:glm` missing from image dispatch, bedrock embed unreachable. | [embed-image.md](embed-image.md) |
| F12 | Chat comments do not exist in the format; a `#` line becomes a user message. | [chat.md](chat.md) |
| F13 | No dynamic backend module resolution (registry only), incomplete documented backend list, and model config leaks across backends via the shared `key:model` token. | [backends.md](backends.md) |
| F14 | Stale context-strategy bounds in docs (the default is `shorten_tools_epoch_increment`, threshold 50 / keep 20 / cap 80, not `shorten_tools` MAX_TOOL_CALLS 40). | [chat.md](chat.md), [backends.md](backends.md) |
| F15 | Symbol-named KB databases break the tool layer on reload (registry YAML round-trips symbol keys; `get_database('name')` string lookup misses). | [tools.md](tools.md) |
| F16 | `scout agent kb` hard-codes `Scout.var.Agent[agent]`; `Chat.load_workflow` (`tool:` roles) uses only `Scout.chats.Agent`, diverging from `load_agent`'s five roots. | [agent-society.md](agent-society.md) |
| F17 | `inherit: 'tools'` scope drift: docs say caller *task* tooling, code copies the whole *current chat's* tooling. | [agent-delegation.md](agent-delegation.md) |
| F18 | Anthropic image support does not exist despite Backends.md's description (inherits the default `input_image` shape; only GLM uses a nested `image_url`), and `encode_image` maps only jpg/jpeg/png - other extensions become `data:image/extension;base64,...`. | [embed-image.md](embed-image.md) |
| F19 | `start_chat.chat` silently ignored / empty seed; `@@agent_workflow` cache never invalidated and process-global. | [agent-society.md](agent-society.md) |
| F20 | MultiAgentWorkflows.md's first snippet would fail; `tooling` destructively mutates the job chat; the shipped "depencencies" misspelling is load-bearing (the recycle filter matches it); no dedicated AgentWorkflow developer doc; `include_workflow` required, not `include`. | [agentworkflow.md](agentworkflow.md) |
| F21 | `openai.rb`'s `defaults` stripping is dead code (deletes at the wrapper level where `:parameters` is nil); only huggingface digs correctly. | [backends.md](backends.md) |
| F22 | Provenance doc drift: two log globs not three; `resets/` invisible to traversal; the optional 7th `detail` yield undocumented but load-bearing; checkout-vs-gem `Chat.live_report` trap. | [provenance.md](provenance.md) |

### Open decisions that span subsystems

- Whether tool-definition defaults should apply only when the model omits the
  input (F10) - it affects every `tool: WF task name=value` user and any
  brief tool-provisioning grammar built on it.
- `inherit: 'tools'` scope (F17): caller-task-scoped or whole-current-chat
  scoped; a regression test pinning whichever is intended would help.
- `Chat.load_workflow` vs `load_agent` lookup divergence (F16): can the same
  `tool: Name` and `agent: Name` resolve to different directories, and does
  anything depend on it?
- Model config cross-talk (F13): intended isolation mechanism or config
  hazard?
- Whether retry/backoff and streaming (F8/F9) should be implemented or the
  docs corrected.
- Whether `LLM.embed` should cache (ask and image both do).
- The dead-but-implemented branches (bedrock embed, glm image): remove,
  implement dispatch, or document as unreachable.
- The supported `mcp` gem version range (server side) - the fixed handler
  contract is stable across 1.1.0-1.5.1 but `mcp` is not a declared runtime
  dependency.

## Provenance

All ten studies derive from the 2026-09-10/11 Cortex subsystem studies,
probed against this checkout at HEAD `a992a33` plus the uncommitted
2026-09-11 fix sweep (attach, MCP serving, embed endpoint YAML, TorchModel
criterion, each with regression tests). Probing was offline throughout: fake
clients, local HTTP stubs, the test mock backend, synthetic fixtures under
`Dir.mktmpdir`, and code reading. No paid API calls, no network LLM usage,
no HuggingFace downloads (the repo's own
`test/support/availability.rb` gates those), and no live running workflows -
provider-rejection questions and live `.info` latency measurements remain
open for that reason. Reusable probes are versioned Cortex artifacts under
`probe/` executed through the `Observation/probe` property (for example
`probe/mcp_serving_dispatch.rb`, `probe/scout_agent_delegation_api.rb`,
`probe/model_ml.rb`, `probe/agentworkflow_*.rb`); each study's Evidence
section names its own probes.

When reproducing: the installed gem may differ from this checkout (2.0.0 vs
2.1.0 at study time), so pin `-I<checkout>/lib` or `RUBYOPT` when probing
from the checkout.
