# scout-ai

scout-ai adds machine-learning, LLM, and “agentic AI” capabilities to the Scout framework. It focuses on:

- Training and inference with HuggingFace and Torch (via Python helpers).
- Using TSV-based datasets and producing model artifacts reproducibly.
- Running ad‑hoc Python from Ruby (PyCall), including pandas DataFrame <-> TSV conversions.
- Building workflow-driven training/evaluation pipelines with provenance and caching.

scout-ai sits on top of the core Scout packages:
- scout-essentials — low-level utilities (Annotation, Open, Path, Persist, CMD, Log, ConcurrentStream, etc.)
- scout-gear — basic modules such as TSV, Entity, KnowledgeBase, Workflow, WorkQueue, etc.
- scout-rig — language bridges (Python, etc.)
- scout-camp — remote servers, cloud deployments, web UIs, cross-site tools
- scout-ai — ML/LLM training and agentic utilities (this repository)

Repositories are available under https://github.com/mikisvaz (e.g. https://github.com/mikisvaz/scout-gear).

Rbbt is the bioinformatics framework Scout was refactored out of and still hosts many end-to-end examples and workflows. Explore https://github.com/Rbbt-Workflows for usage patterns and inspiration.


## Contents

- Overview and requirements
- Python bridge and helpers (scout and scout_ai packages)
- TSV datasets and pandas conversions
- Training and inference examples
- Workflows for ML/LLM pipelines
- Command Line Interface (scout …) discovery
- Documentation references


## Overview and requirements

scout-ai provides Ruby APIs and Python helpers you can call from Ruby to:
- Prepare datasets from TSVs (tabular data is first-class in Scout).
- Train HuggingFace models (classification, causal LM, RLHF scaffold).
- Evaluate models and run chat-style generation.
- Orchestrate the above with Workflow tasks that persist, stream, and track provenance.

Requirements:
- Ruby with the Scout stack (scout-essentials, scout-gear, scout-rig, scout-ai)
- Python 3 with:
  - numpy and pandas
  - torch and transformers (for most training/inference)
  - datasets, accelerate, peft, trl (for advanced cases like RLHF)
- Ruby gem pycall to bridge Ruby and Python


## Python bridge and helpers

ScoutPython is the core bridge between Ruby and Python. scout-ai ships additional Python helpers under the python/scout_ai package.

Highlights:
- Initialize Python and import modules succinctly:
  ```ruby
  ScoutPython.run :numpy, as: :np do
    np.arange(5).tolist   # => [0,1,2,3,4]
  end
  ```
- Execute in a background Python thread and stop it when done:
  ```ruby
  out = ScoutPython.run_threaded :sys do
    sys.version
  end
  ScoutPython.stop_thread
  ```
- Run ad‑hoc Python scripts with Ruby variables (including TSV). The script must set a Python variable named `result`:
  ```ruby
  res = ScoutPython.script <<~PY, value: 2
    result = value * 3
  PY
  # => 6
  ```

Python-side packages:
- scout
  - TSV IO that respects Scout headers: `scout.tsv(path)` → pandas DataFrame
  - `scout.save_tsv(path, df)` to persist DataFrames
  - Minimal workflow helpers to call Scout CLI from Python
- scout_ai
  - Utilities for ML with HuggingFace/Torch:
    - util: `set_seed`, `deterministic`, `device`, `model_device`
    - TSV datasets: `tsv_dataset`, `TSVDataset`, `tsv_loader`
    - huggingface.data: `load_tsv`, `load_json`, `tokenize_dataset`, `list_dataset`
    - huggingface.model: `load_model`, `load_tokenizer`, `load_model_and_tokenizer`
    - huggingface.eval: `eval_model`, `eval_causal_lm_chat`
    - huggingface.train: `training_args`, `train_model`
    - huggingface.train.next_token: `train_next_token` loop for causal LMs
    - huggingface.rlhf: `train_rlhf` scaffold (TRL)
    - visualization/toy data under `scout_ai.atcold.*`


## TSV datasets and pandas conversions

Scout treats TSVs as the lingua franca for data.

From Ruby:
- Convert TSV to pandas DataFrame and back:
  ```ruby
  df = ScoutPython.tsv2df(tsv)   # TSV → pandas DataFrame
  tsv2 = ScoutPython.df2tsv(df)  # DataFrame → TSV
  ```

From Python:
- Use `scout.tsv(path)` to read a TSV (headers and types are honored) and `scout.save_tsv(path, df)` to persist a DataFrame back to a TSV stream with headers.


## Training and inference examples

HuggingFace text classification (Ruby driving Python):

```ruby
# Prepare a simple TSV with columns: Text, label
tsv = TSV.setup([], key_field: "Id", fields: %w[Text label], type: :list)
tsv["ex1"] = ["a positive text", "pos"]
tsv["ex2"] = ["a negative text", "neg"]

TmpFile.with_dir do |dir|
  data_file = dir["train.tsv"].tap { |p| Open.write(p, tsv.to_s) }
  out_dir   = dir["model"]

  ScoutPython.script <<~PY, train: data_file, outdir: out_dir
    import scout
    import scout_ai.huggingface.train as train_mod
    from scout_ai.huggingface.model import load_model, load_tokenizer
    from scout_ai.huggingface.train import training_args, train_model
    import pandas as pd

    df  = scout.tsv(train)                      # pandas DataFrame with index=Id
    labels = sorted(df['label'].unique())
    label2id = {l:i for i,l in enumerate(labels)}

    model_name = "distilbert-base-uncased"
    tok = load_tokenizer(model_name)
    mdl = load_model(model_name, num_labels=len(labels), label2id=label2id)

    args = training_args(
      output_dir=outdir,
      num_train_epochs=1,
      per_device_train_batch_size=8,
      logging_steps=10,
      save_strategy="no",
      evaluation_strategy="no",
    )

    # train_model accepts a dataset compatible with HF datasets or a DataFrame via helper pipeline
    train_model(mdl, tok, args, df)

    result = outdir
  PY

  # out_dir now contains the fine-tuned model; you can persist/link it as a Step artifact
end
```

Causal LM chat-style inference:

```ruby
msg = ScoutPython.script <<~PY, model_name: "gpt2", prompt: "Hello! How are you?"
  from scout_ai.huggingface.model import load_model_and_tokenizer
  from scout_ai.huggingface.eval import eval_causal_lm_chat

  tok, mdl = load_model_and_tokenizer(model_name)
  responses = eval_causal_lm_chat(mdl, tok, [prompt], max_new_tokens=40, temperature=0.8)
  result = responses[0]
PY
# => generated string
```

Torch datasets from TSV:

```ruby
ScoutPython.run 'scout_ai.huggingface.data', import: :load_tsv do
  # In Python context load a TSV into a datasets.Dataset
end

# Or construct a torch Dataset / DataLoader in a single Python block
ScoutPython.script <<~PY, path: "/path/to/data.tsv"
  from scout_ai.huggingface.data import load_tsv
  from scout_ai.huggingface.data import tokenize_dataset
  from scout_ai.util import set_seed, device
  import transformers as tr

  ds = load_tsv(path)                             # HF datasets.Dataset
  tokenizer = tr.AutoTokenizer.from_pretrained("distilbert-base-uncased")
  ds_tok = tokenize_dataset(ds, tokenizer, text_field="Text")
  result = len(ds_tok)
PY
```


## Workflows for ML/LLM pipelines

Use Workflow to codify training/inference with reproducible persistence and provenance.

A minimal training Workflow task that calls Python:

```ruby
module HF
  extend Workflow
  self.name = "HF"

  input :train_tsv, :path, "Training TSV (Id,Text,label)"
  input :model_name, :string, "Base model", "distilbert-base-uncased"
  task :train_classifier => :path do |train_tsv, model_name|
    out = file("model") # Step-local output directory
    ScoutPython.script <<~PY, train: train_tsv.find, outdir: out, base_model: model_name
      import scout
      from scout_ai.huggingface.model import load_model, load_tokenizer
      from scout_ai.huggingface.train import training_args, train_model

      df  = scout.tsv(train)
      labels = sorted(df['label'].unique())
      label2id = {l:i for i,l in enumerate(labels)}

      tok = load_tokenizer(base_model)
      mdl = load_model(base_model, num_labels=len(labels), label2id=label2id)
      args = training_args(output_dir=outdir, num_train_epochs=1, per_device_train_batch_size=8)
      train_model(mdl, tok, args, df)
      result = outdir
    PY
    out
  end
end

# Run and persist a job
HF.job(:train_classifier, "demo", train_tsv: "/data/train.tsv").run
```

All Workflow features apply: dependency graphs, streaming, info files, provenance reporting, orchestrated production with resource limits, and inputs archiving.


## Command Line Interface (scout …)

Scout discovers command-line scripts under scout_commands across installed packages using the Path subsystem. You compose commands by adding terms until a script path is resolved; if a directory is reached, the CLI lists available subcommands.

General usage:
- Listing:
  - `scout` shows top-level groups discovered.
  - `scout tsv`, `scout workflow`, `scout kb` list their subcommands if a directory is selected.
- Executing:
  - `scout tsv <subcommand> [options]` runs `scout_commands/tsv/<subcommand>`.
  - `scout workflow <subcommand> …` runs workflow-related scripts (installed by your workflows under share/scout_commands/workflow).
  - `scout kb <subcommand> …` operates on KnowledgeBase registries and indices.

Examples (from core packages):
- TSV:
  - `scout tsv` — discover TSV utilities (attach, translate, paste, etc., depending on installed scripts).
- Workflow:
  - `scout workflow list`
  - `scout workflow task <Workflow> <task> [task-input-options...]`
  - `scout workflow prov <step_path>`
  - `scout workflow process --continuous --produce_cpus 8`
- KnowledgeBase:
  - `scout kb register <name> <file> --source "FieldA" --target "FieldB"`
  - `scout kb query <name> "Miki~"`

Under the hood, the dispatcher uses Path to find scripts provided by all Scout packages and your installed workflows. Arguments after the resolved script are parsed by the script itself using SOPT (SimpleOPT).


## Documentation references

scout-ai
- Python (ScoutPython) — bridging Ruby and Python, pandas / TSV conversions, and bundled Python helpers (scout and scout_ai)
  - doc/Python.md

Foundations (from other Scout packages)
- Annotation — lightweight annotations on objects and arrays
- CMD — robust external command execution with streaming and error handling
- ConcurrentStream — concurrency-aware IO streams with join/abort semantics
- IndiferentHash — indifferent Hash access and option utilities
- Log — logging, color, progress bars
- NamedArray — arrays with named fields and accessors
- Open — unified file/stream IO, pipes, gzip, remote fetch, locking
- Path — logical-to-physical path mapping and discovery
- Persist — typed serialization, locking, caching, TSV persistence engines

Data and workflows (from scout-gear)
- TSV — table model and rich streaming/transformation API
- Entity — typed entities with properties and format/identifier translation
- Association — build pairwise association indices from TSVs
- KnowledgeBase — register and query multiple association databases
- Workflow — define tasks, Steps, orchestration, CLI integration
- WorkQueue — multi-process pipelines

Each module has a doc/*.md in its respective repository. See:
- https://github.com/mikisvaz/scout-essentials
- https://github.com/mikisvaz/scout-gear
- https://github.com/mikisvaz/scout-rig

Examples and larger pipelines
- Rbbt-Workflows organization: https://github.com/Rbbt-Workflows
  - Many examples of TSV processing, workflows, and end-to-end analyses that informed Scout’s design.


## Notes

- Training helpers assume Python dependencies are installed in the environment where PyCall points. Use `ScoutPython.run_log(:sys) { ... }` to inspect `sys.executable` and `sys.path`.
- All persisted artifacts (model checkpoints, logs, info JSON) created in Workflow tasks live under `var/jobs/<Workflow>/<task>/<id>` unless configured otherwise; use `Step.prov_report(step)` or `scout workflow prov` to inspect provenance.
- For remote or queued execution, pair Scout workflows with scout-camp utilities and Workflow queue/SLURM helpers.

Use scout-ai to keep your ML/LLM experiments reproducible: compose TSV data wrangling, Python model training/evaluation, and CLI automation into robust, inspectable pipelines.