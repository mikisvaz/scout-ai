# huggingface_model.py
import importlib
from typing import Optional, Any

def import_module_class(module: str, class_name: str) -> Any:
    """Dynamically import a class from a module."""
    mod = importlib.import_module(module)
    return getattr(mod, class_name)

def load_model(task: Optional[str], checkpoint: str, **kwargs) -> Any:
    """Load a Huggingface model by task and checkpoint"""
    if task is None or task.lower() == 'embedding':
        model_class = import_module_class('transformers', 'AutoModel')
    elif ":" in task:
        module, class_name = task.split(":")
        model_class = import_module_class(module, class_name)
    else:
        model_class = import_module_class('transformers', f'AutoModelFor{task}')
    return model_class.from_pretrained(checkpoint, **kwargs)

def load_tokenizer(checkpoint: str, **kwargs) -> Any:
    """Load a Huggingface tokenizer"""
    tokenizer_class = import_module_class('transformers', 'AutoTokenizer')
    return tokenizer_class.from_pretrained(checkpoint, **kwargs)

def load_model_and_tokenizer(task: Optional[str], checkpoint: str, **kwargs):
    model = load_model(task, checkpoint, **kwargs)
    tokenizer = load_tokenizer(checkpoint, **kwargs)
    return model, tokenizer
