import scout
import pandas as pd
import datasets
from typing import Any, Dict, List

def load_tsv(tsv_file):
    tsv = scout.tsv(tsv_file)
    ds = datasets.Dataset.from_pandas(tsv)
    d = datasets.DatasetDict()
    d["train"] = ds
    return d

def load_json(json_file):
    return datasets.load_dataset('json', data_files=[json_file])

def tokenize_dataset(tokenizer, dataset, max_length=32):
    def preprocess_function(examples):
        return tokenizer(examples["text"], truncation=True, padding="max_length", max_length=max_length)
    if isinstance(dataset, datasets.DatasetDict):
        for split in dataset:
            dataset[split] = dataset[split].map(preprocess_function, batched=True)
        return dataset
    else:
        return dataset.map(preprocess_function, batched=True)

def tsv_dataset(tokenizer, tsv_file):
    dataset = load_tsv(tsv_file)
    return tokenize_dataset(tokenizer, dataset)

def json_dataset(tokenizer, json_file):
    dataset = load_json(json_file)
    return tokenize_dataset(tokenizer, dataset)

def list_dataset(tokenizer, texts, labels=None, max_length=32):
    data_dict = {"text": texts}
    if labels is not None:
        data_dict["label"] = labels
    ds = datasets.Dataset.from_dict(data_dict)

    def preprocess_function(examples):
        output = tokenizer(examples["text"], truncation=True, padding="max_length", max_length=max_length)
        if "label" in examples:
            output["label"] = examples["label"]
        return output

    tokenized_ds = ds.map(preprocess_function, batched=True)
    return tokenized_ds

