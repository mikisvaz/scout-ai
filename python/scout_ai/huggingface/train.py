from transformers import TrainingArguments, Trainer
from typing import Any
from .data import json_dataset, tsv_dataset, tokenize_dataset

def training_args(*args, **kwargs) -> TrainingArguments:
    return TrainingArguments(*args, **kwargs)

def train_model(model: Any, tokenizer: Any, training_args: TrainingArguments, dataset: Any, class_weights=None, **kwargs):
    for param in model.parameters():
        param.data = param.data.contiguous()

    if (isinstance(dataset, str)):
        if (dataset.endswith('.json')):
            tokenized_dataset = json_dataset(tokenizer, dataset)
        else:
            tokenized_dataset = tsv_dataset(tokenizer, dataset)
    else:
        tokenized_dataset = tokenize_dataset(tokenizer, dataset)

    if class_weights is not None:
        import torch
        from torch import nn
        class WeightTrainer(Trainer):
            def compute_loss(self, model, inputs, return_outputs=False):
                labels = inputs.get("labels")
                outputs = model(**inputs)
                logits = outputs.get('logits')
                loss_fct = nn.CrossEntropyLoss(weight=torch.tensor(class_weights).to(model.device))
                loss = loss_fct(logits.view(-1, model.config.num_labels), labels.view(-1))
                return (loss, outputs) if return_outputs else loss
        trainer = WeightTrainer(model, training_args, train_dataset=tokenized_dataset["train"], tokenizer=tokenizer, **kwargs)
    else:
        trainer = Trainer(model, training_args, train_dataset=tokenized_dataset["train"], tokenizer=tokenizer, **kwargs)
    trainer.train()
