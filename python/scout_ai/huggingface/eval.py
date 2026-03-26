import json
import re


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


def _move_to_device(inputs, device):
    if hasattr(inputs, "to"):
        return inputs.to(device)

    if isinstance(inputs, dict):
        return {
            key: value.to(device) if hasattr(value, "to") else value
            for key, value in inputs.items()
        }

    return inputs


def _prepare_tools(tools, tool_argument="tools"):
    if tools is None:
        return None

    prepared = []
    for tool in tools:
        if isinstance(tool, dict):
            tool = dict(tool)
            function = tool.get("function")

            if tool_argument != "tools" and isinstance(function, dict):
                prepared.append(function)
            elif tool_argument == "tools" and function is None and "name" in tool and "parameters" in tool:
                prepared.append({"type": "function", "function": tool})
            else:
                prepared.append(tool)
        else:
            prepared.append(tool)

    return prepared


def _prepare_chat_inputs(
    model, tokenizer, messages,
    tools=None,
    chat_template=None,
    chat_template_kwargs=None,
    tool_argument=None,
):
    chat_template_kwargs = dict(chat_template_kwargs or {})
    tool_argument = tool_argument or "tools"

    if hasattr(tokenizer, "apply_chat_template"):
        kwargs = dict(
            add_generation_prompt=True,
            tokenize=True,
            return_dict=True,
            return_tensors="pt",
        )
        kwargs.update(chat_template_kwargs)

        if chat_template is not None:
            kwargs["chat_template"] = chat_template

        prepared_tools = _prepare_tools(tools, tool_argument)
        if prepared_tools:
            kwargs[tool_argument] = prepared_tools

        rendered = tokenizer.apply_chat_template(messages, **kwargs)

        if isinstance(rendered, str):
            inputs = tokenizer(rendered, return_tensors="pt")
        else:
            inputs = rendered
    else:
        prompt = "\n".join(str(message.get("content", "")) for message in messages)
        inputs = tokenizer(prompt, return_tensors="pt")

    return _move_to_device(inputs, model.device)


def _decode_generated_text(tokenizer, inputs, output_ids):
    input_ids = inputs["input_ids"]
    return tokenizer.decode(
        output_ids[0, input_ids.shape[1]:],
        skip_special_tokens=True,
    )


def _normalize_tool_call(tool_call, index=0):
    if tool_call is None:
        return None

    if "function" in tool_call and isinstance(tool_call["function"], dict):
        function = dict(tool_call["function"])
    else:
        function = {
            "name": tool_call.get("name"),
            "arguments": tool_call.get("arguments", tool_call.get("parameters", {})),
        }

    arguments = function.get("arguments", {})
    if isinstance(arguments, str):
        try:
            arguments = json.loads(arguments)
        except Exception:
            pass

    return {
        "id": tool_call.get("id") or tool_call.get("call_id") or f"call_{index}",
        "type": "function",
        "function": {
            "name": function.get("name"),
            "arguments": arguments,
        },
    }


def _normalize_response(parsed, raw_text=None):
    if parsed is None:
        return {"role": "assistant", "content": (raw_text or "").strip()}

    if isinstance(parsed, str):
        return {"role": "assistant", "content": parsed.strip()}

    if isinstance(parsed, list):
        return {
            "role": "assistant",
            "content": "",
            "tool_calls": [
                tool_call
                for tool_call in (
                    _normalize_tool_call(tool_call, index)
                    for index, tool_call in enumerate(parsed)
                )
                if tool_call is not None
            ],
        }

    message = dict(parsed)
    message.setdefault("role", "assistant")

    if "tool_calls" in message:
        message["tool_calls"] = [
            tool_call
            for tool_call in (
                _normalize_tool_call(tool_call, index)
                for index, tool_call in enumerate(message.get("tool_calls", []))
            )
            if tool_call is not None
        ]
    elif "name" in message and ("arguments" in message or "parameters" in message):
        message["tool_calls"] = [_normalize_tool_call(message, 0)]
        message.setdefault("content", "")

    if message.get("content") is None:
        message["content"] = ""

    if raw_text is not None and "content" not in message:
        message["content"] = raw_text.strip()

    return message


def _parse_tool_call_blocks(output_text):
    matches = re.findall(r"<tool_call>\s*(.*?)\s*</tool_call>", output_text, re.DOTALL)
    if not matches:
        return None

    tool_calls = []
    for match in matches:
        try:
            payload = json.loads(match)
        except Exception:
            continue

        payloads = payload if isinstance(payload, list) else [payload]
        for item in payloads:
            normalized = _normalize_tool_call(item, len(tool_calls))
            if normalized is not None:
                tool_calls.append(normalized)

    if not tool_calls:
        return None

    content = re.sub(r"<tool_call>\s*.*?\s*</tool_call>", "", output_text, flags=re.DOTALL).strip()
    return {
        "role": "assistant",
        "content": content,
        "tool_calls": tool_calls,
    }


def parse_causal_lm_response(tokenizer, output_text, response_parser=None):
    if response_parser not in (False, "false", "none"):
        if hasattr(tokenizer, "parse_response"):
            try:
                parsed = tokenizer.parse_response(output_text)
                normalized = _normalize_response(parsed, raw_text=output_text)
                if normalized.get("tool_calls") or normalized.get("content") or normalized.get("thinking"):
                    return normalized
            except Exception:
                pass

        parsed = _parse_tool_call_blocks(output_text)
        if parsed is not None:
            return parsed

    return {"role": "assistant", "content": output_text.strip()}


def eval_causal_lm_chat(
    model, tokenizer, messages,
    chat_template=None,
    chat_template_kwargs=None,
    generation_kwargs=None,
    tool_argument=None,
):
    generation_kwargs = dict(generation_kwargs or {})

    inputs = _prepare_chat_inputs(
        model, tokenizer, messages,
        chat_template=chat_template,
        chat_template_kwargs=chat_template_kwargs,
        tool_argument=tool_argument,
    )

    model.eval()
    output_ids = model.generate(**inputs, **generation_kwargs)
    return _decode_generated_text(tokenizer, inputs, output_ids)


def eval_causal_lm_response(
    model, tokenizer, messages,
    tools=None,
    chat_template=None,
    chat_template_kwargs=None,
    generation_kwargs=None,
    tool_argument=None,
    response_parser=None,
):
    generation_kwargs = dict(generation_kwargs or {})

    chat_template = None
    inputs = _prepare_chat_inputs(
        model, tokenizer, messages,
        tools=tools,
        chat_template=chat_template,
        chat_template_kwargs=chat_template_kwargs,
        tool_argument=tool_argument,
    )

    model.eval()
    output_ids = model.generate(**inputs, **generation_kwargs)
    output_text = _decode_generated_text(tokenizer, inputs, output_ids)
    return parse_causal_lm_response(tokenizer, output_text, response_parser=response_parser)
