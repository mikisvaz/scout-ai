# Model

The Model subsystem in scout-ai provides a small, composable framework to wrap machine‑learning models (pure Ruby, Python/PyTorch, and Hugging Face Transformers) with a consistent API for evaluation, training, feature extraction, post‑processing, and persistence.

It consists of a base class (ScoutModel) and higher-level implementations:
- PythonModel — instantiate and drive Python classes via ScoutPython.
- TorchModel — drive arbitrary PyTorch modules with simple training/eval loops, tensor helpers, and state save/load.
- HuggingfaceModel — convenience wrapper for Transformers models and tokenizers, with specializations:
  - SequenceClassificationModel — text classification.
  - CausalModel — chat/causal generation.
  - NextTokenModel — next-token fine-tuning pipeline.

This document covers the common API, how to customize models with feature extraction and post-processing, saving/loading models and their behavior, and several concrete examples (including how ExTRI2 uses a Hugging Face model inside a Workflow).

---

## Core concepts and base API (ScoutModel)

ScoutModel is the foundation. You create a model object, attach blocks describing how to evaluate, train, extract features, and post-process, and optionally persist both its behavior and state in a directory.

Constructor:
- ScoutModel.new(directory = nil, options = {})
  - directory (optional) — if provided, model behavior/state can be saved and later restored from here.
  - options — free-form hash for your parameters (e.g., hyperparameters). These are persisted to options.json in the directory and merged on restore.

Key responsibilities:
- Provide hooks to set the model’s:
  - init — how to initialize internal state (e.g., load a Python object).
  - eval — how to evaluate one sample.
  - eval_list — how to evaluate a list (batch) of samples (by default dispatches to eval).
  - extract_features / extract_features_list — how to map raw inputs to “features” the model expects.
  - post_process / post_process_list — transform raw predictions/logits to final outputs.
  - train — how to fit with accumulated training data (features and labels).

- Build and hold training data:
  - add(sample, label = nil)
  - add_list(list, labels = nil or Hash mapping sample->label)
  - Internal arrays @features and @labels are filled after feature extraction.

- Persist behavior and state:
  - save — persists options, all behavior blocks (as .rb) and state (see below).
  - restore — loads behavior and options; if the model has a directory, init/load_state are called on demand.

- A directory-bound state file:
  - state_file — shorthand for directory.state; used by implementations to store learned parameters.

Execution helpers (util/run.rb):
- execute(method, *args) — run a stored Proc with arity checks.
- init { ... } / init() — define or execute the initialization method.
- eval(sample=nil) { ... } — define or run the eval method; calls extract_features and post_process around your block as needed.
- eval_list(list=nil) { ... } — define or run the list version; defaults to mapping eval unless you override.
- post_process(result=nil) { ... }, post_process_list(list=nil) { ... } — define or run post-processing.
- train { ... } / train() — define or run training using @features/@labels.
- extract_features(sample=nil) { ... }, extract_features_list(list=nil) { ... } — define or run feature extraction.

Persistence (util/save.rb):
- save — writes options.json; saves each defined Proc to a .rb file beside the state (using method_source); calls save_state if @state exists.
- restore — loads behavior (.rb), options, and sets up init/load_state/save_state blocks.
- save_state { |state_file, state| ... } — define or execute logic to persist the current @state.
- load_state { |state_file| ... } — define or execute logic to restore @state.

Minimal example (pure Ruby)
```ruby
model = ScoutModel.new
model.eval do |sample, list=nil|
  if list
    list.map { |x| x * 2 }
  else
    sample * 2
  end
end

model.eval(1)             # => 2
model.eval_list([1, 2])   # => [2, 4]
```

Persisting behavior/state
```ruby
TmpFile.with_file do |dir|
  model = ScoutModel.new dir, factor: 4
  model.eval { |x, list=nil| list ? list.map { |v| v * @options[:factor] } : x * @options[:factor] }
  model.save

  # Later
  reloaded = ScoutModel.new dir
  reloaded.eval(1)           # => 4
  reloaded.eval_list([1,2])  # => [4,8]
end
```

---

## PythonModel: wrap Python classes

PythonModel specializes ScoutModel to initialize a Python class instance (via ScoutPython) and keep it in @state.

Constructor:
- PythonModel.new(dir, python_class = nil, python_module = :model, options = {})
  - dir — directory holding model.py or any Python package you want on sys.path.
  - python_class/python_module — class and module to import; if python_module omitted, defaults to :model.
  - options — additional keyword arguments passed to the Python class initializer.

Initialization:
- On init, PythonModel adjusts paths, ensures ScoutPython is initialized, and builds an instance:
  - ScoutPython.class_new_obj(python_module, python_class, **options.except(...))

From tests (python/test_base.rb):
```ruby
TmpFile.with_path do |dir|
  dir['model.py'].write <<~PY
    class TestModel:
      def __init__(self, delta):
        self.delta = delta
      def eval(self, x):
        return [e + self.delta for e in x]
  PY

  model = PythonModel.new dir, 'TestModel', :model, delta: 1

  model.eval do |sample, list=nil|
    init unless state
    if list
      state.eval(list)       # Python: returns list
    else
      state.eval([sample])[0]
    end
  end

  model.eval(1)                 # => 2
  model.eval_list([3,5])        # => [4,6]

  model.save
  model2 = ScoutModel.new dir   # generic loader from directory works too
  model2.eval(1)                # => 2

  model3 = ScoutModel.new dir, delta: 2
  model3.eval(1)                # => 3
end
```

Notes:
- Behavior blocks (eval/extract_features/train/post_process) are still Ruby procs you define; inside, you can call Python methods on state.
- Options are persisted and merged on restore, allowing default hyperparameter overrides.

---

## TorchModel: PyTorch convenience

TorchModel extends PythonModel with a ready-to-use setup for PyTorch nn.Modules, training loop, tensor helpers, and state I/O.

Highlights:
- torch helpers (torch/helpers.rb):
  - TorchModel.init_python — imports torch and utility modules once.
  - TorchModel::Tensor — wrapper adding to_ruby/to_ruby!/del for tensor lifecycle management.
  - device(options) / dtype(options) — configure device/dtype from options (e.g., device: 'cuda').
  - tensor(obj, device, dtype) — build a torch.tensor; result responds to .to_ruby / .del.

- Save/Load (torch/load_and_save.rb):
  - TorchModel.save(state_file, state) — saves both architecture (torch.save(model)) and weights (state_dict) into state_file(.architecture).
  - TorchModel.load(state_file, state=nil) — loads architecture and then weights.
  - reset_state — clear current state and remove persisted files.

- Introspection (torch/introspection.rb):
  - get_layer(state, layer_path = nil), get_weights(state, layer_path)
  - freeze_layer(state, layer_path, requires_grad=false) — recursively freezes a submodule.

- Training loop (torch.rb):
  - Provide your nn.Module as state (e.g., via model.state = ScoutPython.torch.nn.Linear.new(1,1)).
  - Set criterion/optimizer or rely on defaults:
    - TorchModel.optimizer(model, training_args) — default SGD(lr: 0.01).
    - TorchModel.criterion(model, training_args) — default MSELoss.
  - options[:training_args] may set epochs, batch_size, learning_rate, etc.

Example (from tests/test_torch.rb)
```ruby
TorchModel.init_python
model = TorchModel.new dir
model.state = ScoutPython.torch.nn.Linear.new(1, 1)
model.criterion = ScoutPython.torch.nn.MSELoss.new()

model.extract_features { |f| [f] }
model.post_process     { |v, list| list ? v.map(&:first) : v.first }

# Train y ~ 2x
model.add 5.0,  [10.0]
model.add 10.0, [20.0]
model.options[:training_args][:epochs] = 1000
model.train

w = model.get_weights.to_ruby.first.first
# w between 1.8 and 2.2
```

Persist and reuse
```ruby
model.save
reloaded = ScoutModel.new dir
y = reloaded.eval(100.0) # ~ 200
```

Tips:
- Manage tensor memory with Tensor#del after large batch evaluations if needed.
- You can freeze layers by name path ("encoder.layer.0") before training.

---

## HuggingfaceModel: Transformers integration

HuggingfaceModel is a TorchModel specializing initialization and save/load to work with transformers:
- Loads a model and tokenizer via Python functions (python/scout_ai/huggingface/model.py):
  - load_model(task, checkpoint, **kwargs)
  - load_tokenizer(checkpoint, **kwargs)
- Persists using save_pretrained/from_pretrained into directory.state (a directory).

Options normalization:
- fix_options: splits options into:
  - training_args (or via training: …),
  - tokenizer_args (or via tokenizer: …),
  - plus task / checkpoint.
- Any model/tokenizer kwargs not in training_args or tokenizer_args are passed through on load.

Save/Load:
- save_state — model.save_pretrained and tokenizer.save_pretrained into state_file dir.
- load_state — model.from_pretrained and tokenizer.from_pretrained when present.

You typically use one of its specializations:

### SequenceClassificationModel

Purpose: text classification (logits to label).

Behavior:
- eval: calls Python eval_model(model, tokenizer, texts, locate_tokens?) to produce logits (default return_logits = true).
- post_process: argmax across logits, mapping to class labels if provided.

Training:
- train: builds a TSV (text,label), constructs TrainingArguments and uses Trainer/train (python/scout_ai/huggingface/train).
- Accepts optional class_weights to weight CrossEntropy in a custom Trainer.

Example training (from tests)
```ruby
model = SequenceClassificationModel.new 'bert-base-uncased', nil, class_labels: %w(Bad Good)
model.init

10.times do
  model.add "The dog", 'Bad'
  model.add "The cat", 'Good'
end

model.train
model.eval("This is dog")  # => "Bad"
model.eval("This is cat")  # => "Good"
```

Notes:
- post_process maps argmax index to options[:class_labels]. Raw logits can be left to downstream code by customizing post_process.

### CausalModel

Purpose: chat/causal generation.

Behavior:
- eval(messages, list=nil): calls Python eval_causal_lm_chat(model, tokenizer, messages, chat_template, chat_template_kwargs, generation_kwargs) to return generated text, using tokenizer.apply_chat_template when available.

Training:
- train(pairs, labels): hooks a basic RLHF pipeline (python/scout_ai/huggingface/rlhf.py) using PPO. You supply:
  - pairs: array of [messages, response] pairs,
  - labels: rewards for each pair.
- After training, it reloads state from disk.

Usage example (test/test_causal.rb):
```ruby
model = CausalModel.new 'mistralai/Mistral-7B-Instruct-v0.3'
model.init
model.eval([
  {role: :system, content: "You are a calculator, just reply with the answer"},
  {role: :user, content: " 1 + 2 ="}
])
# => "3"
```

### NextTokenModel

Purpose: next-token fine-tuning for Causal LM.

Adds a custom train block that:
- Builds tokenized dataset from a list of strings.
- Trains with a simple language modeling loop (python/scout_ai/huggingface/train/next_token.py).
- Writes checkpoints under directory/output.

From tests (huggingface/causal/test_next_token.rb):
```ruby
model = NextTokenModel.new model_name, tmp_dir, training_num_train_epochs: 1000, training_learning_rate: 0.1

chat = Chat.setup []
chat.user "say hi"
pp model.eval chat   # generation before training

state, tok = model.init
tok.pad_token = tok.eos_token

train_texts = ["say hi, no!", "say hi, hi", ...]
model.add_list train_texts.shuffle
model.train

pp model.eval chat   # improved generations
model.save
reloaded = PythonModel.new tmp_dir
pp reloaded.eval chat
```

---

## Feature extraction and post-processing

A key pattern is to keep evaluation logic generic and tailor feature extraction and post‑processing for each task.

- extract_features(sample) and extract_features_list(list) let you shape inputs into the structure your model consumes.
- post_process(result) or post_process_list(list) convert raw outputs to your final format (e.g., argmax to label, logits to softmax).

ExTRI2 workflow example (SequenceClassification)
```ruby
# tri_sentences task uses a Huggingface SequenceClassification model
tri_model = Rbbt.models[tri_model].find unless File.exist?(tri_model)
model = HuggingfaceModel.new 'SequenceClassification', tri_model, nil,
  tokenizer_args: { model_max_length: 512, truncation: true },
  return_logits: true

# Convert the TSV row into the sequence model expects
model.extract_features do |_, feature_list|
  feature_list.collect do |text, tf, tg|
    text.sub("[TF]", "<TF>#{tf}</TF>").sub("[TG]", "<TG>#{tg}</TG>")
  end
end

model.init

# Evaluate as a batch (tsv.slice returns [["Text","TF","Gene"], ...])
predictions = model.eval_list tsv.slice(["Text", "TF", "Gene"]).values

# Write classifier output back to TSV
tsv.add_field "Valid score" do
  non_valid, valid = predictions.shift
  begin
    Misc.softmax([valid, non_valid]).first
  rescue
    0
  end
end

tsv.add_field "Valid" do |_, values|
  values.last > 0.5 ? "Valid" : "Non valid"
end
```

Key takeaways:
- Use extract_features to canonicalize input format independent of how your rows are structured.
- Batch evaluation with eval_list on large tables; then write back into TSV columns.
- Persist the model directory to reuse across runs.

---

## Training data management

Collect samples:
- add(sample, label=nil)
- add_list(list, labels=nil)
  - labels may be an Array aligned with list or a Hash mapping sample->label.

In Torch/HF paths, training consumes @features/@labels after feature extraction:
- SequenceClassificationModel’s train writes a TSV dataset to disk, builds TrainingArguments, tokenizes, and runs transformers.Trainer.
- TorchModel’s train uses a simple loop with SGD and MSELoss by default (override criterion/optimizer if needed).

---

## Persistence and restore

Behavior and state are independent:
- Behavior (Ruby Procs for eval/extract_features/train/etc.) are saved to .rb sibling files in directory; they are reloaded and instance_eval’ed on restore.
- Options are persisted to options.json and merged on restore.
- State depends on implementation:
  - TorchModel: two files — state (weights) and architecture dump (.architecture).
  - HuggingfaceModel: directory with tokenizer+model via save_pretrained.
  - PythonModel: you define save_state/load_state (or rely on higher-level class).

Common methods:
- save — writes options, behavior files, and calls save_state if @state exists.
- restore — loads behavior files and options; state is lazy-initialized by calling init/load_state when used next.

---

## Devices, tensors, and memory notes (PyTorch)

- Choose device automatically or pass options: { device: 'cuda' } or { device: 'cpu' }.
- TorchModel::Tensor#to_ruby converts tensors to Ruby arrays via numpy; #to_ruby! also calls .del to free GPU memory (detach, move to CPU, clear grads and storage).
- Freeze layers if fine-tuning only a head: TorchModel.freeze_layer(state, "encoder.layer.0", false).

---

## Building your own specializations

You can layer new classes over PythonModel/TorchModel/HuggingfaceModel to produce high-level behaviors:

- Override initialize to:
  - Call super(...) with task/checkpoint/dir/options.
  - Provide eval blocks suited for your task (e.g., locate tokens, decode strategies).
  - Provide post_process/post_process_list.
  - Provide train with your pipeline (tokenization, trainer, or custom loop).
  - Optionally override save_state/load_state.

- Or, stick with a plain ScoutModel and define init/eval/train/… blocks directly—particularly useful for lightweight pure-Ruby or ad‑hoc model logic.

---

## Patterns and recommendations

- Start simple with ScoutModel for logic prototyping; then move to PythonModel/TorchModel/Hugging Face when integrating Python models.
- Always isolate feature extraction from evaluation to keep eval focused on the lower-level API your model expects.
- Persist: pass a directory when you want to reuse a model and its learned parameters across runs; call save after training.
- For table‑driven workflows, use eval_list and TSV traversal to batch efficiently (see ExTRI2 usage).
- In TorchModel, explicitly set criterion/optimizer where the default (SGD + MSELoss) is not appropriate.

---

## API quick reference

Common (ScoutModel)
- new(directory=nil, options={})
- init { ... } / init() → @state
- eval(sample=nil) { |features| ... } → result
- eval_list(list=nil) { |list| ... } → array of results
- extract_features(sample=nil) { ... }, extract_features_list(list=nil) { ... }
- post_process(result=nil) { ... }, post_process_list(list=nil) { ... }
- train { |features, labels| ... } / train()
- add(sample, label=nil), add_list(list, labels=nil or Hash)
- save / restore
- save_state { |state_file, state| ... }, load_state { |state_file| ... }
- directory, state_file, options

PythonModel
- new(dir, python_class=nil, python_module=:model, options={})
- On init: state is an instance of the Python class.

TorchModel
- state (PyTorch nn.Module)
- criterion, optimizer, device, dtype
- TorchModel.init_python
- TorchModel.tensor(obj, device, dtype) → Tensor wrapper
- TorchModel.save(state_file, state) / TorchModel.load(state_file, state=nil)
- TorchModel.get_layer(state, path), freeze_layer(state, path, requires_grad=false)

HuggingfaceModel
- new(task=nil, checkpoint=nil, dir=nil, options={})
  - options: training_args (or training: {}), tokenizer_args (or tokenizer: {})
- save_state/load_state via save_pretrained/from_pretrained

SequenceClassificationModel
- class_labels (optional)
- train(texts, labels)
- eval(text or list of texts) → label(s) or your post_process

CausalModel
- eval(messages) → generated text
- train(pairs, rewards) — RLHF pipeline

NextTokenModel
- train(texts) — next-token fine-tuning loop

---

## CLI

No dedicated “model” CLI commands are shipped in scout-ai. You will typically:
- Invoke models programmatically from Ruby code, or
- Use them inside Workflows (see ExTRI2 below), then drive training/eval via Workflow’s CLI (scout workflow task …).

Refer to the Workflow documentation for CLI usage if you integrate models into tasks.

---

## Example: using a Hugging Face classifier inside a Workflow (ExTRI2)

The ExTRI2 workflow builds sequence classification models to validate TRI sentences and determine Mode of Regulation (MoR). It uses HuggingfaceModel and custom feature extraction to mark [TF]/[TG] mentions:

```ruby
model = HuggingfaceModel.new 'SequenceClassification', tri_model, nil,
  tokenizer_args: { model_max_length: 512, truncation: true },
  return_logits: true

model.extract_features do |_, rows|
  rows.map do |text, tf, tg|
    text.sub("[TF]", "<TF>#{tf}</TF>").sub("[TG]", "<TG>#{tg}</TG>")
  end
end

model.init
predictions = model.eval_list tsv.slice(["Text", "TF", "Gene"]).values

tsv.add_field "Valid score" do
  non_valid, valid = predictions.shift
  Misc.softmax([valid, non_valid]).first rescue 0
end

tsv.add_field "Valid" do |_, row|
  row.last > 0.5 ? "Valid" : "Non valid"
end
```

This pattern—feature extraction tied to the row schema, batch evaluation, then TSV augmentation—is representative of how to fold models into reproducible pipelines.

---

Model provides the minimal structure needed to adapt, persist, and reuse models across Ruby and Python ecosystems, while keeping your training/evaluation logic concise and testable. Use the base hooks for clarity, leverage Torch/HF helpers when needed, and integrate with Workflows to scale out training and inference.