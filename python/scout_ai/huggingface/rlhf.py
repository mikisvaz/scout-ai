from trl import PPOTrainer, AutoModelForCausalLMWithValueHead, PPOConfig
import torch
import scout_ai

from copy import deepcopy
from datasets import Dataset


class PPOTrainerWithPrecomputedReward(PPOTrainer):
    def get_rewards(self, **kwargs):
        return torch.tensor(self.train_dataset['reward'], dtype=torch.float32)

def train_rlhf(path, tokenizer, pairs, rewards, config=None, generation_config=None):
    """
    pairs: List of tuples (messages, response)
        - messages: List[Dict[str, str]] (OpenAI/chatML-style messages)
        - response: string (the model output to be rewarded)
    """
    config = config or {}
    device = scout_ai.device()
    device = 'cuda'

    tokenizer.padding_side = "left"
    tokenizer.pad_token = tokenizer.eos_token

    prompts, responses = [], []
    for pair in pairs:
        messages, response = pair
        # Ensure tokenizer supports chat template (HF >=4.34)
        if hasattr(tokenizer, 'apply_chat_template'):
            # Use default: add_generation_prompt needed for LLMs like Llama, Mistral, etc
            prompt = tokenizer.apply_chat_template(
                messages, add_generation_prompt=True, tokenize=False
            )
        else:
            # Fallback: join user/assistant messages
            prompt = "\n".join(msg['content'] for msg in messages)
        prompts.append(prompt)
        responses.append(response)

    train_dataset = Dataset.from_dict({'prompt': prompts, 'response': responses, 'reward': rewards})

    # Wrap model with Value Head for PPO
    from trl import PPOTrainer, AutoModelForCausalLMWithValueHead, PPOConfig
    model = AutoModelForCausalLMWithValueHead.from_pretrained(path)
    model.to(device)

    from transformers import GenerationConfig
    
    generation_config = GenerationConfig()

    ppo_config = PPOConfig(
        batch_size=config.get('batch_size', 4),
        learning_rate=config.get('learning_rate', 1e-5),
        mini_batch_size=config.get('mini_batch_size', 1),
        gradient_accumulation_steps=1,
    )

    model.base_model_prefix = 'model'

    ref_model = deepcopy(model)
    ref_model.to(device)

    model.generation_config=generation_config

    print(model)
    print(ref_model)

    ppo_trainer = PPOTrainerWithPrecomputedReward(
        args=ppo_config,
        model=model,
        ref_model=ref_model,
        reward_model=model,  # dummy
        value_model=model,  # dummy
        train_dataset=train_dataset,
        processing_class=None,
    )

    
    print("Step")
    stats = ppo_trainer.train(prompts, responses, rewards)
    model.save
    return stats
