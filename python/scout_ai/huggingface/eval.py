def forward(model, features):
    return model(**features)

def get_logits(predictions):
    logits = predictions["logits"]
    return [v.detach().cpu().numpy() for v in logits]

def eval_model(model, tokenizer, texts, return_logits=True):
    features = tokenizer(texts, return_tensors='pt', truncation=True).to(model.device)
    model.eval()
    predictions = forward(model, features)
    if return_logits:
        return get_logits(predictions)
    return predictions

def eval_causal_lm_chat(
    model, tokenizer, messages,
    chat_template=None,
    chat_template_kwargs=None,
    generation_kwargs=None
):
    """
    Evaluate a CausalLM model given chat messages. Uses tokenizer's chat template by default.

    Args:
        model: Huggingface CausalLM
        tokenizer: Huggingface tokenizer
        messages: List[Dict[str, str]] (OpenAI API style, 'role' and 'content')
        chat_template: (Optional) Override string for the chat template.
        chat_template_kwargs: (Optional) Dict, kwargs for apply_chat_template (like tokenize, add_generation_prompt, etc).
        generation_kwargs: (Optional) Dict for model.generate

    Returns:
        Generated text (or list, depending on settings).
    """
    chat_template_kwargs = chat_template_kwargs or {}
    generation_kwargs = generation_kwargs or {}

    # If the tokenizer has a chat template (HF 4.34+)
    if hasattr(tokenizer, "___apply_chat_template"):
        kwargs = dict(add_generation_prompt=True, tokenize=False)
        kwargs.update(chat_template_kwargs)
        if chat_template is not None:
            # Override the template (may require tokenizer._chat_template)
            tokenizer._chat_template = chat_template
        prompt = tokenizer.apply_chat_template(messages, **kwargs)
    else:
        # Fallback: simple concatenation
        prompt = "\n".join([msg['content'] for msg in messages])

    # Tokenize as usual
    inputs = tokenizer(prompt, return_tensors='pt').to(model.device)
    model.eval()
    # Use generate
    output_ids = model.generate(**inputs, **generation_kwargs)
    # Decode only the newly generated tokens (not the prompt)
    output_text = tokenizer.decode(
        output_ids[0, inputs["input_ids"].shape[1]:], skip_special_tokens=True
    )
    return output_text
