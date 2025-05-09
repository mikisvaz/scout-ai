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

def tokenize_dataset(tokenizer, dataset):
    return dataset.map(lambda subset: subset if ("input_ids" in subset.keys()) else tokenizer(subset["text"], truncation=True), batched=True)

def tsv_dataset(tokenizer, tsv_file):
    dataset = load_tsv(tsv_file)
    return tokenize_dataset(tokenizer, dataset)

def json_dataset(tokenizer, json_file):
    dataset = load_json(json_file)
    return tokenize_dataset(tokenizer, dataset)

