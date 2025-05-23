import os
import math
import time
import shutil
import random
from dataclasses import dataclass
from typing import List, Optional, Dict, Any, Union

import torch
from torch.utils.data import DataLoader
from datasets import Dataset, load_dataset

from transformers import (
    PreTrainedModel, 
    PreTrainedTokenizer, 
    get_scheduler, 
    DataCollatorForLanguageModeling
)
from torch.optim import AdamW
from transformers.utils import logging

logger = logging.get_logger(__name__)

def set_seed(seed: int):
    random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)
    try:
        import numpy as np
        np.random.seed(seed)
    except ImportError:
        pass

@dataclass
class TrainingState:
    global_step: int = 0
    best_eval_loss: float = float("inf")

def tokenize_function(examples, tokenizer, max_seq_length):
    # examples: dict with key 'text' or single texts
    # Always output input_ids and attention_mask
    output = tokenizer(
        examples["text"] if "text" in examples else examples,
        truncation=True,
        padding="max_length",
        max_length=max_seq_length,
        return_attention_mask=True,
    )
    output["labels"] = output["input_ids"].copy()
    return output

def group_texts(examples, block_size):
    # For paragraph-based datasets: simply return; for huge files, use this.
    concatenated = {k: sum(examples[k], []) for k in examples.keys()}
    total_length = len(concatenated[list(examples.keys())[0]])
    # Drop the small remainder
    total_length = (total_length // block_size) * block_size
    result = {
        k: [t[i : i + block_size] for i in range(0, total_length, block_size)]
        for k, t in concatenated.items()
    }
    return result

def train_next_token(
    model: PreTrainedModel,
    tokenizer: PreTrainedTokenizer,
    dataset: Union[List[str], Dataset],
    *,
    output_dir: str,
    eval_dataset: Optional[Union[List[str], Dataset]] = None,
    max_seq_length: int = 2048,
    batch_size: int = 8,
    gradient_accumulation_steps: int = 1,
    num_train_epochs: int = 3,
    learning_rate: float = 1e-4,
    weight_decay: float = 0.01,
    lr_scheduler_type: str = "linear",
    warmup_steps: int = 0,
    logging_steps: int = 50,
    eval_steps: int = 200,
    save_steps: int = 500,
    save_total_limit: int = 3,
    fp16: bool = False,
    bf16: bool = False,
    max_train_steps: int = None,
    seed: int = 42,
    report_to: str = "none",  # or "wandb", "tensorboard"
    use_lora: bool = False,
    lora_config: Optional[dict] = None,
    resume_from_checkpoint: str = None,
    callbacks: Optional[List] = None,
    device_map: str = "auto",
    dataloader_num_workers: int = 4,
    group_by_length: bool = False,
    description: str = "",
):
    """
    Fine-tunes a causal LM for next-token prediction.
    """
    #assert isinstance(model, PreTrainedModel), "Model must be a HuggingFace PreTrainedModel"
    #assert isinstance(tokenizer, PreTrainedTokenizer), "Tokenizer must be a HuggingFace PreTrainedTokenizer"
    assert isinstance(dataset, (list, Dataset)), "Dataset must be a HuggingFace Dataset or a list of texts"

    set_seed(seed)
    os.makedirs(output_dir, exist_ok=True)

    device = "cuda" if torch.cuda.is_available() else "cpu"
    n_gpus = torch.cuda.device_count()

    if resume_from_checkpoint:
        logger.info(f"Loading checkpoint from {resume_from_checkpoint}")
        model.load_state_dict(torch.load(os.path.join(resume_from_checkpoint, "pytorch_model.bin")))

    model.to(device)

    if fp16:
        scaler = torch.cuda.amp.GradScaler()
    else:
        scaler = None

    # 1. Prepare Dataset
    if isinstance(dataset, list):
        dataset = Dataset.from_dict({"text": dataset})

    if eval_dataset is not None and isinstance(eval_dataset, list):
        eval_dataset = Dataset.from_dict({"text": eval_dataset})

    # Tokenization and formatting
    def preprocess(examples):
        return tokenize_function(examples, tokenizer, max_seq_length)

    dataset = dataset.map(preprocess, batched=True, remove_columns=list(dataset.column_names))
    if eval_dataset is not None:
        eval_dataset = eval_dataset.map(preprocess, batched=True, remove_columns=list(eval_dataset.column_names))

    # 2. Loader & Collator
    data_collator = DataCollatorForLanguageModeling(tokenizer, mlm=False)

    train_loader = DataLoader(
        dataset,
        batch_size=batch_size,
        shuffle=True,
        collate_fn=data_collator,
        num_workers=dataloader_num_workers,
        drop_last=True,
    )
    eval_loader = None
    if eval_dataset is not None:
        eval_loader = DataLoader(
            eval_dataset, 
            batch_size=batch_size,
            shuffle=False,
            collate_fn=data_collator, 
            num_workers=dataloader_num_workers,
        )

    # 3. Optimizer & Scheduler
    no_decay = ["bias", "LayerNorm.weight"]
    grouped_params = [
        {
            "params": [
                p for n, p in model.named_parameters() if not any(nd in n for nd in no_decay)
            ],
            "weight_decay": weight_decay,
        },
        {
            "params": [
                p for n, p in model.named_parameters() if any(nd in n for nd in no_decay)
            ],
            "weight_decay": 0.0,
        },
    ]

    optimizer = AdamW(grouped_params, lr=learning_rate)

    total_train_steps = (
        max_train_steps if max_train_steps is not None
        else (len(train_loader) * num_train_epochs) // gradient_accumulation_steps
    )

    lr_scheduler = get_scheduler(
        lr_scheduler_type,
        optimizer=optimizer,
        num_warmup_steps=warmup_steps,
        num_training_steps=total_train_steps,
    )

    # 4. LoRA/PEFT Support (placeholder)
    if use_lora:
        logger.warning("PEFT/LoRA integration not yet implemented. Skipping.")

    # 5. Checkpoint Management
    saved_checkpoints = []

    # 6. Training Loop
    state = TrainingState()
    model.train()
    start_time = time.time()
    for epoch in range(num_train_epochs):
        logger.info(f"Epoch {epoch+1}/{num_train_epochs}")
        for step, batch in enumerate(train_loader):
            true_step = state.global_step + 1
            batch = {k: v.to(device) for k, v in batch.items()}
            with torch.cuda.amp.autocast(dtype=torch.float16 if fp16 else torch.bfloat16 if bf16 else torch.float32, enabled=(fp16 or bf16)):
                outputs = model(**batch)
                loss = outputs.loss
                loss = loss / gradient_accumulation_steps

            if fp16:
                scaler.scale(loss).backward()
            else:
                loss.backward()

            if true_step % gradient_accumulation_steps == 0:
                if fp16:
                    scaler.step(optimizer)
                    scaler.update()
                else:
                    optimizer.step()
                optimizer.zero_grad()
                lr_scheduler.step()

            if true_step % logging_steps == 0:
                logger.info(f"Step {true_step}: loss {loss.item() * gradient_accumulation_steps:.4f}")

            if eval_loader is not None and true_step % eval_steps == 0:
                eval_loss = evaluate(model, eval_loader, device, fp16, bf16)
                logger.info(f"Step {true_step}: eval_loss {eval_loss:.4f}, ppl {math.exp(eval_loss):.2f}")
                # Save best
                if eval_loss < state.best_eval_loss:
                    state.best_eval_loss = eval_loss
                    save_checkpoint(model, output_dir, f"best")
            if true_step % save_steps == 0:
                ckpt_dir = save_checkpoint(model, output_dir, f"step-{true_step}")
                saved_checkpoints.append(ckpt_dir)
                # Cleanup
                if len(saved_checkpoints) > save_total_limit:
                    old = saved_checkpoints.pop(0)
                    shutil.rmtree(old, ignore_errors=True)
            state.global_step = true_step
            if max_train_steps is not None and true_step >= max_train_steps:
                break
        # End-of-epoch eval/save
        if eval_loader is not None:
            eval_loss = evaluate(model, eval_loader, device, fp16, bf16)
            logger.info(f"Epoch {epoch+1} end: eval_loss {eval_loss:.4f}, ppl {math.exp(eval_loss):.2f}")
            if eval_loss < state.best_eval_loss:
                state.best_eval_loss = eval_loss
                save_checkpoint(model, output_dir, "best")
        save_checkpoint(model, output_dir, f"epoch-{epoch+1}")
    logger.info(f"Training completed in {time.time() - start_time:.2f} sec on {device}")

def evaluate(model, eval_loader, device, fp16, bf16):
    model.eval()
    losses = []
    for batch in eval_loader:
        batch = {k: v.to(device) for k, v in batch.items()}
        with torch.no_grad():
            with torch.cuda.amp.autocast(dtype=torch.float16 if fp16 else torch.bfloat16 if bf16 else torch.float32, enabled=(fp16 or bf16)):
                outputs = model(**batch)
            losses.append(outputs.loss.item())
    model.train()
    return sum(losses) / len(losses)

def save_checkpoint(model, output_dir, tag):
    output_ckpt_dir = os.path.join(output_dir, tag)
    os.makedirs(output_ckpt_dir, exist_ok=True)
    model.save_pretrained(output_ckpt_dir)
    return output_ckpt_dir

def main():
    from transformers import AutoModelForCausalLM, AutoTokenizer

    # Example tiny dataset: few sentences
    train_texts = [
        "The quick brown fox jumps over the lazy dog.",
        "Artificial intelligence is the future.",
        "Llama models are great for language tasks.",
        "Open source is important for research.",
    ]
    eval_texts = [
        "Transformers enable powerful NLP models.",
        "Fine-tuning improves performance."
    ]

    #model_name = "openlm-research/open_llama_3b"  # Replace with your local/other HF Llama checkpoint as needed
    model_name = "distilgpt2"  # Replace with your local/other HF Llama checkpoint as needed

    tokenizer = AutoTokenizer.from_pretrained(model_name, use_fast=True)
    # Make sure tokenizer pads on right for causal LMs (Llama does not have pad by default)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    model = AutoModelForCausalLM.from_pretrained(model_name)

    train_next_token(
        model=model,
        tokenizer=tokenizer,
        dataset=train_texts,
        output_dir="./output_test",
        eval_dataset=eval_texts,
        max_seq_length=32,
        batch_size=2,
        num_train_epochs=1,
        gradient_accumulation_steps=1,
        learning_rate=5e-5,
        fp16=False,  # Change to True if running on GPU with enough VRAM
        bf16=False,
        logging_steps=1,
        eval_steps=2,
        save_steps=10
    )

if __name__ == "__main__":
    main()
