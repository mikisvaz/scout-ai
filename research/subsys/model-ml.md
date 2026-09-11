# 08 - ScoutModel / Torch / HuggingFace ML layer

> Investigation, not normative documentation. Verified behavior of the ML
> model subsystem and the Python SDK's ML half. Normative reference:
> `doc/Model.md` (classified there as "ML model subsystem, separate from
> harness").

## Scope

`lib/scout/model/**` (ScoutModel, PythonModel, TorchModel, HuggingfaceModel
and specializations) and the ML half of `python/scout_ai/**` (`util`, `data`,
`huggingface/*`). The agent/chat half of the Python SDK is covered only at
the boundary.

## Verified behavior

### Placement and load graph

- The subsystem is **not required by `lib/scout-ai.rb`**. The only in-repo
  require site is the LLM huggingface backend
  (`lib/scout/llm/backends/huggingface.rb:35-36`), which is the single seam
  to the agent layer.
- Class hierarchy: `CausalModel -> HuggingfaceModel -> TorchModel ->
  PythonModel -> ScoutModel`; `NextTokenModel -> CausalModel`;
  `SequenceClassificationModel -> HuggingfaceModel`.

### ScoutModel core

Dual-purpose registration API (`util/run.rb`): each of `init`, `eval`,
`eval_list`, `extract_features`, `extract_features_list`, `post_process`,
`post_process_list`, `train`, `save_state`, `load_state` takes an optional
block - **with** a block it registers the Proc, **without** it it executes
the stored one. `execute(method, *args)` runs a Proc via `instance_exec` or
returns `args.first` when the method is nil, so an unregistered
`post_process`/`extract_features` is an identity pass.

- `eval(sample)`: `features = extract_features sample`; `init unless @state`;
  an arity-2 eval block receives `(features, nil)`, an arity-1 block
  `(features)`; then `post_process result`.
- `eval_list(list)`: `extract_features_list list`; prefers `@eval_list`; else
  an arity-2 eval block receives `(nil, list)`; else maps `eval` per element.
  An arity-2 block therefore serves both single and list evaluation.
- `train`: registers or `execute @train, @features, @labels`, then
  **`save_state`** - every train auto-persists state when a state hook
  exists.
- `add(sample, label = nil)` / `add_list(list, labels = nil|Hash)` fill
  `@features`/`@labels` after feature extraction; Hash labels keyed by sample
  work.
- Constructor: `directory` is Path-ified and `restore` is called immediately
  when present; `@features`/`@labels` reset to `[]` after restore.

### Persistence model

`save` (util/save.rb:50-67) writes:

1. `options.json` (JSON dump of `@options`).
2. One `.rb` file per registered block (`eval.rb`, `eval_list.rb`,
   `extract_features.rb`, `extract_features_list.rb`, `post_process.rb`,
   `post_process_list.rb`, `train.rb`, `init.rb`, `load_state.rb`,
   `save_state.rb`) via `method_source`'s `Proc#source` - i.e. the
   **original call-site source** (`m.eval { |v| v * 2 }` persists the literal
   line including the receiver and call).
3. `save_state if @state`.

`restore` loads all ten blocks plus options. `load_method` returns the plain
file content when `directory[name]` exists without the `.rb` extension, else
`load_ruby_code` on `directory[name.rb]`.

`load_ruby_code` applies `code.sub!(/.*(\sdo\b|{)/, 'Proc.new\1')` - a single
greedy `.*` prefix strip up to the **last** ` do` or `{` on the line - then
`instance_eval`s it. Because the saved line is the call site, the rewrite
turns `  m.eval { |v| v * 2 }` into `Proc.new{ |v| v * 2 }`. Round-trips
verified for: single-line braces, do/end multiline, do/end with nested braces
and hash literals, ternary with braces, arity-2 do/end.

`state_file` = `directory.state`; nil without a directory (and `save` then
fails on `save_options`).

Options merge on restore (`load_options`): file options merge **over**
constructor options - saved values win. Verified concretely: a model saved
with `checkpoint: "saved/ckpt"` and reloaded as
`HuggingfaceModel.new("CausalLM", "NEW/ckpt", dir)` still reports
`"saved/ckpt"`.

### PythonModel

Constructor `initialize(dir, python_class = nil, python_module = nil,
options = nil)`; when `options` is nil and `python_module` is a Hash, the
third argument is treated as options and the module defaults to `:model`.
The class/module are stored into options, and only when
`options[:python_class]` is set an `init` block is registered that adds
`Scout.python.find(:lib)` and `directory` to the Python path,
`ScoutPython.init_scout`, then `ScoutPython.class_new_obj(module, class,
**options.except(:python_class, :python_module))` - the leftover options are
the Python kwargs. TorchModel/HuggingfaceModel pass `nil, nil` and therefore
inherit no PythonModel init block; they define their own.

### TorchModel

- Accessors `criterion`, `optimizer`, `device`, `dtype`; `fix_options`
  normalizes `training_args`/`training_kwargs`/`training_x` into
  `options[:training_args]`.
- Default `train` block (torch.rb:24-58): `TorchModel.init_python`, device/
  dtype resolution, `state.to(device)`,
  `@optimizer ||= TorchModel.optimizer(...)`,
  `@criterion ||= TorchModel.criterion(state, options[:training_args] || {})`
  (fixed 2026-09-11, uncommitted - it previously assigned
  `TorchModel.optimizer(...)` to `@criterion`, an SGD optimizer, so the
  default train path died with `PyCall::PyError TypeError: Non-callable
  Python object was given` unless the user set `model.criterion` by hand;
  see F7), full-batch tensors, then an epoch loop
  `optimizer.zero_grad -> state.call(inputs) -> loss -> backward -> step`
  under `Log::ProgressBar.with_bar`. `epochs` default 3; `batch_size` from
  `options[:batch_size]` or `training_args[:batch_size]`, else 1.
- Default `eval` block: arity-2 (`features, list`), `state.eval`, chunks the
  list by batch_size, `state.call(tensor)`, `Tensor#to_ruby!` per chunk
  (frees the tensor), returns `res[0]` for a single input.
- Helpers (`torch/helpers.rb`): `TorchModel.init_python` (guarded by
  `@@init_python`; imports `torch`, `scout`, `scout_ai`, `scout_ai.util`,
  `torch.nn`), `optimizer` -> SGD with `lr = training_args[:learning_rate]
  || 0.01`, `criterion` -> `MSELoss`, device/dtype resolution (String/Symbol
  -> torch object; nil device -> `scout_ai.util.device()`), `tensor(obj,
  device, dtype)`.
- `Tensor` module: `to_ruby` (numpy2ruby), `to_ruby!` (to_ruby + `del`),
  `del` (to cpu, detach, `grad = nil`, `untyped_storage.resize_ 0`, rescue ->
  `Log.exception`), `length` (`PyCall.len`).
- `torch/load_and_save.rb`: `save_state` = `torch.save(state.state_dict(),
  state_file)`; `save_architecture` = `torch.save(state, state_file +
  '.architecture')`; `load_state` = `state.load_state_dict(torch.load(...))`;
  `load_architecture` = `torch.load(..., weights_only: false)`;
  `TorchModel.save(state_file, state)` saves both; `TorchModel.load` loads
  architecture then weights; instance `reset_state` clears `@trainer`/`@state`
  and removes both files.
- `torch/introspection.rb`: `get_layer`, `get_weights`,
  `freeze_layer(state, layer, requires_grad = false)` plus instance
  delegators.
- `torch/dataloader.rb`: `TorchModel.feature_tsv(elements, labels = nil,
  class_labels = nil)` builds a TSV (`key_field ID`, field `features`, `:flat`
  or `:list`, plus a `label` field when labels are given; labels mapped
  through the `class_labels` index when provided) and
  `TorchModel.text_dataset(file, elements, labels, class_labels)` writes it -
  pure Ruby+TSV, no torch needed.

### HuggingfaceModel and specializations

- `fix_options`: folds `training_args|training_kwargs` ->
  `training_options`, pulls `training_*` keys, same for tokenizer, then
  re-exposes `options[:training_args]`/`options[:tokenizer_args]`.
  Normalization matrix: `{training: {num_train_epochs: 3}}` ->
  `training_args = {training: {num_train_epochs: 3}}` (the nested hash is
  **not** flattened); `{training_num_train_epochs: 3}` ->
  `training_args = {num_train_epochs: 3}`; the same pair of shapes for
  tokenizer args; everything else (`trust_remote_code`, `torch_dtype`)
  stays top-level.
- Constructor `(task = nil, checkpoint = nil, dir = nil, options = {})` ->
  `super(dir, nil, nil, options)`, `fix_options`, then
  `options[:checkpoint] = checkpoint; options[:task] = task`. Ordering: the
  super already ran `restore`, so the file wins when a directory is present.
- `init` block: `TorchModel.init_python`; the checkpoint is `state_file`
  **when it is an existing directory**, else `options[:checkpoint]` (so
  re-init from a saved dir silently ignores the checkpoint); the model is
  loaded via `ScoutPython.call_method("scout_ai.huggingface.model",
  :load_model, task, checkpoint, **options.except(:training_args,
  :tokenizer_args, :task, :checkpoint, :class_labels, :model_options,
  :return_logits, :chat_template, :chat_template_kwargs,
  :generation_kwargs))`; the tokenizer checkpoint is
  `tokenizer_args[:checkpoint] || checkpoint` and the tokenizer is loaded
  with all `tokenizer_args` as kwargs. `@state` is a **pair**
  `[model, tokenizer]`.
- `load_state` / `save_state`: `model.from_pretrained(state_file)` /
  `model.save_pretrained(state_file)` (+ tokenizer) - `directory.state` is a
  **directory** for HF models, unlike TorchModel's two files.
- Python `scout_ai/huggingface/model.py`: `load_model(task, checkpoint,
  **kwargs)` -> `AutoModel` when task is nil or `embedding`, `module:Class`
  when the task contains `:`, else `transformers.AutoModelFor{task}`;
  `load_tokenizer` -> `AutoTokenizer`; `load_model_and_tokenizer`.

`SequenceClassificationModel`: `eval` calls `eval_model(model, tokenizer,
texts, options[:locate_tokens])`; a single input returns `res[0]`;
`post_process` is an argmax over logits mapped through
`options[:class_labels]`. `train` writes `dataset.tsv` (+ `checkpoints/`)
under `directory` (or a `TmpFile.tmp_file` dir removed afterwards), builds
`training_args(checkpoint_dir, options[:training_args])`, materializes the
dataset with `HuggingfaceModel.text_dataset`, then `train_model(model,
tokenizer, training_args_obj, dataset_file, options[:class_weights])`.
Python-side `training_args` wraps `transformers.TrainingArguments`;
`train_model` tokenizes (json/tsv/in-memory) and, with `class_weights`,
subclasses `Trainer` with a weighted `CrossEntropyLoss` in `compute_loss`.

`CausalModel`: `eval(messages, list)` calls `eval_causal_lm_chat(model,
tokenizer, messages, chat_template, chat_template_kwargs,
generation_kwargs, tool_argument)`; **`chat(messages, tools = nil,
runtime_options = {})`** merges runtime options (generation_kwargs /
tool_argument / response_parser) and calls the tool-aware
`eval_causal_lm_response`. `train(pairs, labels)` -> `train_rlhf(state_file,
tokenizer, pairs, labels, options[:rlhf_config])` then `load_state`. Python
`eval.py`: `eval_causal_lm_chat` renders `tokenizer.apply_chat_template` (or
joins message contents as a fallback), `model.generate`, decodes only the
newly generated ids (`skip_special_tokens=True`);
`eval_causal_lm_response` additionally runs `parse_causal_lm_response` ->
the `tokenizer.parse_response` hook, else `<tool_call>...</tool_call>` regex
blocks, else a plain content message.

`NextTokenModel`: its `train` block calls
`train_next_token(model:, tokenizer:, dataset:, output_dir:,
**options[:training_args])` with `output_dir` = `directory['output'].find`
when a directory exists. Python `train/next_token.py`: a self-contained
next-token loop - tokenize with `max_length` padding + labels = input_ids,
`DataCollatorForLanguageModeling(mlm=False)`, AdamW + linear scheduler,
fp16/bf16 autocast, eval loss/ppl, best/step/epoch checkpoints with
`save_total_limit`, optional `resume_from_checkpoint` loading
`pytorch_model.bin` via `load_state_dict`. LoRA is a placeholder (logs "not
yet implemented").

### Python SDK

Two independent stories in one package:

1. **Agent/chat SDK** - the pip-installable `scout-ai` wheel, no hard
   dependencies (`ml`/`huggingface` extras bring numpy/pandas/torch and
   datasets/transformers/trl): `Agent`, `Chat`, `Message`,
   `ScoutRunner`/`CommandError`, `load_agent`. The runner shells out to the
   `scout-ai` CLI (`SCOUT_AI_COMMAND` env override) - Ruby stays the source
   of truth.
2. **ML helpers**, imported lazily and only when the extras are present:
   `util` (`set_seed`, `deterministic`, `device`, `model_device` - torch
   required) and `data` (`TSVDataset`, a torch Dataset over a pandas TSV
   read through the scout-rig `scout.tsv`/`tsv_pandas` helper;
   `tsv_dataset`, `tsv`, `tsv_loader`, `data_dir`), plus
   `scout_ai/huggingface/data.py` (datasets-based `load_tsv`/`load_json`,
   `tokenize_dataset` with `max_length=32` default, list datasets).

How Ruby finds the package: `TorchModel.init_python` / the PythonModel init
add `Scout.python.find(:lib)` to `ScoutPython.paths` - the repo's `python/`
directory plus scout-rig's, both appended to `sys.path`. The
`:scout_ai_lib` pathmap registered by `lib/scout-ai.rb` is how
`Scout.python.find(:lib)` locates `python/` next to `lib/`. This is why the
SDK works from a checkout without `pip install`.

Tests: the seven Python tests that need no ML dependencies pass
(`test_chat_agent.py`, `test_runner.py`, `test_huggingface_eval.py`).

## Sharp edges and known issues

- **Restore precedence inversion** (F6, open): `load_options` merges saved
  `options.json` **over** constructor options, and
  `HuggingfaceModel#initialize` assigns `checkpoint` after `super` already
  restored - a reloaded model silently ignores a fresh `checkpoint`
  argument. The `doc/Model.md` example only works because that option was
  never persisted.
- **`save_method`'s String branch is dead/broken** (open):
  `when String === train_method` references an undefined local (`value` is
  the parameter); it would raise `NameError` if ever hit. Only the Proc
  branch is reachable today.
- **Proc-source persistence is fragile** (open): a block body containing a
  string with an unbalanced `}` produces an unloadable `eval.rb`
  (SyntaxError on reload) - the greedy `.*` match eats to the last `{`
  inside the string. A body whose first line ends with a hash literal
  `{ a: 1 }` is rewritten to `Proc.new{ a: 1 }`, which parses as a block,
  not a hash; do/end call sites round-trip because the regex finds the ` do`
  first. Worth a sanitizer or a documented constraint.
- **`eval_model`'s `return_logits` parameter receives
  `options[:locate_tokens]`** (open): the option named `return_logits`
  (used by `doc/Model.md`'s example) lands in the loader's `except` list and
  is never forwarded, so logits always come back; the actually-read name is
  `locate_tokens`, which appears nowhere in the docs.
- **`rlhf.py` hardcodes `device = 'cuda'`** (open): CPU-only hosts cannot run
  PPO; and it ends with `model.save`, which is not a standard
  transformers/trl method (`save_pretrained` is).
- **`fix_options` nested-hash shape** (open): `{training: {...}}` yields
  `training_args = {training: {...}}` rather than the inner hash - if
  `training:` was meant to be equivalent to `training_args:`, HF
  `TrainingArguments` receives a wrong kwarg.
- **`reset_state` doc drift**: `doc/Model.md` omits that it also clears
  `@trainer`, which is never set anywhere in the subsystem (harmless, stale).
- **Fixed 2026-09-11, uncommitted:** F7 - the default TorchModel train block
  assigned an SGD optimizer to `@criterion` (copy-paste), so default training
  was broken without a manual `model.criterion`. One-line fix in
  `lib/scout/model/python/torch.rb` with a gated regression test in
  `test/scout/model/python/test_torch.rb` (2/0; needs both `PYTHON` and
  `SCOUT_TEST_PYTHON` pointing at the torch env, or neither - with only the
  latter, PyCall imports a python without torch).

## Open questions

- Is the ExTRI2 `return_logits: true` option functional at all (see above)?
  Needs the ExTRI2 workflow to decide; no code in this repo reads
  `locate_tokens` other than the classification eval call.
- Does anything outside the LLM huggingface backend use this subsystem
  in-repo? `grep` says no; the ExTRI2 usage lives in a separate workflow
  repository. Worth a cross-repo check before any refactor.
- HuggingFace weights behaviour was never probed (no
  torch/transformers/datasets installed in the study environment; the repo's
  own `test/support/availability.rb` refuses network downloads) - HF weights
  claims are code-read only.

## Evidence

Provenance: derived from the 2026-09-10/11 Cortex subsystem studies, probed
against this checkout at HEAD `a992a33` plus the uncommitted 2026-09-11 fix
sweep. The TorchModel criterion fix (F7) in that sweep is in scope here and
is described as current behavior above.

- Code: `lib/scout/model/base.rb` (19 lines); `util/run.rb`;
  `util/save.rb:2-26,29-36,46-67` (state_file, load_ruby_code, load_method,
  save_method, save/restore); `python/base.rb` (25 lines);
  `python/torch.rb:4-10,24-93` (current fixed form);
  `python/torch/{helpers,dataloader,load_and_save,introspection}.rb`;
  `python/huggingface.rb`; `python/huggingface/{causal,classification}.rb`;
  `python/huggingface/causal/next_token.rb`;
  `lib/scout/llm/backends/huggingface.rb:34-44`;
  `python/scout_ai/{__init__,util,data}.py`;
  `python/scout_ai/huggingface/{model,eval,data,rlhf}.py`;
  `python/scout_ai/huggingface/train/{__init__,next_token}.py`;
  `test/support/availability.rb`.
- Ruby test runs: `test/scout/model/test_base.rb` 2/0;
  `test/scout/model/util/test_save.rb` 1/0;
  `test/scout/model/python/test_base.rb` 1/0;
  `test/scout/model/python/test_torch.rb` 2/0 after the fix (omitted without
  the torch env); `test_huggingface.rb` 6/0; the HF model tests are omitted
  by the availability gate (model not cached). Python: 7/7 OK.
- Probe receipts: Cortex probe artifact `probe/model_ml.rb` (Observation
  `model_ml`, property job `Observation/probe/model_ml_017c...json`) covering
  the hierarchy, the save file list, Proc-source round-trips, arity-2
  dispatch, the `fix_options` matrix, checkpoint-restore semantics and
  code-fact greps; plus throwaway probes under `tmp/probe_model_ml/`.
