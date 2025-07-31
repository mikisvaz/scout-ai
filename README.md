# Writing Scout-AI Agents: A Practical Guide

## Table of Contents

1. **Introduction to Scout-AI Agents**
2. **Basic Agent Lifecycle**
3. **Advanced Features**
   - **Working with Endpoints**
   - **Integrating Tasks and Tools**
   - **File and Directory Interaction**
   - **Handling Images**
   - **Iterating Over Dictionaries**
4. **Structured Outputs**
   - **Simple JSON Responses**
   - **Structured Output with Custom Formats**
   - **Schema-based Responses**
5. **Maintaining and Extending Workflow Context**
6. **Saving Chats and Answers**
7. **Other Capabilities and Tips**
8. **Best Practices & Scout-AI Principles**
9. **Examples**
   - **Minimal Agent**
   - **Task-Integrating Agent**
   - **Image Analysis Agent**
10. **Conclusion**

---

## 1. Introduction to Scout-AI Agents

Scout-AI agents provide a high-level, scriptable interface to orchestrate conversations, integrate tasks from machine learning workflows, and automate data-driven analysis—all with an intuitive and extensible Ruby API. Agents are designed for reusability and modularity, supporting a wide range of interaction and workflow automation scenarios.

---

## 2. Basic Agent Lifecycle

The core pattern for effective agent use aligns with Scout-AI’s lifecycle model: **initialize once, configure chat context, and reuse the agent for repeated runs**.

```ruby
require 'scout-ai'

agent = LLM::Agent.new        # Initialize agent only once

agent.start_chat.import 'system/biologist'
agent.start_chat.import 'intro/setup'
agent.start_chat.import 'intro/results'

# Now, whenever you want to start a new conversation with the same setup:
agent.start                  # New clean chat with previous start_chat setup
agent.user "What are the main findings?"
agent.chat
```

- `start_chat` lets you **set the initial prompts, imports, or system messages** for all new conversations managed by this agent.
- After calling `start`, the agent’s chat session is reinitialized with the contents of `start_chat`. This lets you rerun analyses or prompts with a consistent context at any time.
- Agents are **reusable**: set up common context up front, and `start` as many times as you wish.

---

## 3. Advanced Features

### Working with Endpoints

Endpoints control which backend model or engine is used for a specific agent reply (for example, sending queries to "sambanova" or "websearch"):

```ruby
agent.endpoint :sambanova
agent.user "Explain the significance."
agent.chat
```

- **Note**: The endpoint is only active for the *next* assistant reply. After each assistant message (i.e., after `.chat`), the endpoint variable is reset and must be set again if you wish to keep using the same backend.

### Integrating Tasks and Tools

Agents can execute tasks within workflows or expose tools directly to the user:

```ruby
# Run a specific workflow task and include its result
agent.task AGS, :list_tfs, treatment: t, time_point: tp, direction: "down"

# Offer tool access in the chat itself
agent.tool "AGS", "list_tfs", "list_tgs" # Only makes these tasks available to the user
agent.tool "AGS"                         # Makes all tasks in workflow AGS available
```

- If you add a `tool` role message, the user can directly request these tools during the chat.
- If the workflow name is given without tasks, all tasks will be available; if you list space-separated tasks, only those are enabled.

### File and Directory Interaction

Agents work seamlessly with files and directories:

```ruby
agent.file 'workflow.rb'           # Attach a file’s contents to the chat context
agent.directory 'theme/immune/'    # Attach all files in the directory
```

Results and logs can be persisted using:

```ruby
agent.write "results/summary"      # Save the entire chat history (including roles etc.)
agent.write_answer "results/plain" # Save only the agent's last answer (text only)
```

### Handling Images

To involve image processing or attach visuals, simply use:

```ruby
agent.image 'experiment.png'
```

### Iterating Over Dictionaries

Process multiple items from a dictionary:

```ruby
agent.iterate_dictionary <<-EOF do |name, description|
Return a dictionary of open-source projects by name and description.
EOF

  agent.start
  agent.user "Analyze #{name}: #{description}"
  agent.chat
  agent.write "deep/#{name}"
end
```

---

## 4. Structured Outputs

Scout-AI agents enable you to request and receive structured data from models—such as hashes or arrays—parsed automatically as JSON. This makes it straightforward to chain outputs with downstream analysis or further scripting.

### Simple JSON Responses

To receive a structured object (such as a hash or array) in response to a prompt, add the request directly as a user role and use the `agent.json` method.

```ruby
agent.user <<-EOF
List the top 3 movies for each protagonist of the original Ghostbusters.
EOF
movies_by_actor = agent.json
```
- The model will respond in JSON. The hash is parsed and assigned to `movies_by_actor`.
- This is best for simple structures where the expected format can be explained directly in the prompt.

### Structured Output with Custom Formats (`json_format`)

For more complex outputs or to tightly constrain the structure, use the `json_format` method with a format specification or schema. This can be either a Ruby hash describing the format, or a JSON Schema.

```ruby
schema = {
  type: "object",
  additionalProperties: {type: :array, items: {type: :string}}
}
agent.user <<-EOF
Return, as a JSON object, the top 3 movies for each main actor of Ghostbusters. The actor names are the keys, and their movie lists are the values.
EOF
result = agent.json_format(schema)
```

You can also load your format from a file or another source. This instructs the backend to validate and output the structured data according to your schema, making it suitable for downstream coding or automation.

#### Example: Using a Format for Flat String Map

```ruby
actor_format = {
  name: 'actors_and_top_movies',
  type: 'object',
  properties: {},
  additionalProperties: {type: :string}
}
agent.user <<-EOF
Name each actor from Ghostbusters and the single top movie they took part in.
EOF
result = agent.json_format(actor_format)
```

#### Example: Using a Strict Schema

```ruby
schema =  {
  "type": "object",
  "properties": {
    "people": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "name": { "type": "string" },
          "movies": {
            "type": "array",
            "items": { "type": "string" },
            "minItems": 3,
            "maxItems": 3
          }
        },
        "required": ["name", "movies"],
        "additionalProperties": false
      }
    }
  },
  "required": ["people"],
  "additionalProperties": false
}
agent.user <<-EOF
List each actor in Ghostbusters and their top 3 movies in a structured format.
EOF
result = agent.json_format(schema)
```

See also: `test/scout/llm/backends/test_responses.rb` for several practical
examples of format usage.

---

## 5. Maintaining and Extending Workflow Context

Agents can refer back to, or continue from, previous outputs or chats for multi-stage workflows:

```ruby
agent.continue :previous_session     # Continue from a prior saved chat
agent.import 'schemas/dictionary'    # Import schema or helper context
agent.user "Break down the analysis into themes."
themes = agent.json                  # Parse structured output as JSON
```

---

## 6. Saving Chats and Answers

- Use `agent.write PATH` to persist the **entire chat**, including all context and roles, for provenance and future reference.
- Use `agent.write_answer PATH` to store **only the agent's latest answer**, useful for downstream automation or reporting.

---

## 7. Other Capabilities and Tips

- Agents can handle error situations gracefully via standard Ruby error handling.
- The same agent instance can serve many different analyses if you consistently use `start` between runs.
- You may combine advanced scripting (loops, conditions) as these are ordinary Ruby objects.

---

## 8. Best Practices & Scout-AI Principles

- **Keep Agent Setups Modular**: Use `start_chat` for foundational setup, and per-analysis blocks for specifics.
- **Prefer Reuse**: Configure agents once, and call `start` for new, reproducible chats.
- **Persist Everything Important**: Persist chats and answers as required for traceability and reproducibility.
- **Expose Tools When Needed**: Use the `tool` role to let the user interactively access workflow tasks.
- **Maintain Clarity**: Save only the chat (`write`) or only the assistant's answer (`write_answer`) as appropriate.

Scout-AI enforces a shared, backend-agnostic model and strict persistence for data, options, and code artifacts—your agents should reflect these principles for maximum interoperability and maintainability.

---

## 9. Examples

### Minimal Agent

```ruby
agent = LLM::Agent.new
agent.start_chat.system "You are a helpful assistant."
agent.start
agent.user "Tell me about genome editing."
agent.chat
agent.write_answer "results/summary.txt"   # Only saves last response (plain text)
```

### Task-Integrating Agent

```ruby
Workflow.require_workflow "AGS"

agent = LLM::Agent.new
agent.start_chat.import 'system/biologist'
agent.start

agent.task AGS, :list_tfs, treatment: "INT", time_point: "6", direction: "up"
agent.user "Explain which transcription factors are most significant."
agent.endpoint :sambanova
agent.chat
agent.write "analysis/INT_tfs"
```

### Image Analysis Agent

```ruby
agent = LLM::Agent.new
agent.start_chat.system "You are a microscopy image analyst."
agent.file "experiment_script.rb"
agent.image "well_plate.png"

agent.user "Assess the image and suggest improvements for colony counting."
agent.endpoint :responses
agent.chat
agent.write "colony_feedback.txt"
```

---

## 10. Conclusion

Scout-AI agents offer a robust and flexible interface for orchestrating stateful, reproducible conversations and model-driven analyses. By following these guidelines, you can compose advanced workflows, request structured responses, integrate interactive tools for the user, and maintain a high level of clarity, reusability, and persistence—consistent with the Scout-AI engineering principles.

---
