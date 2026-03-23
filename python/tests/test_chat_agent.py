import unittest

from scout_ai import Chat, Message, load_agent


class FakeRunner:
    def ask_messages(self, messages, agent_name=None):
        messages = list(messages)
        label = agent_name or "llm"
        return messages + [
            {"role": "assistant", "content": f"reply from {label}"},
            {"role": "previous_response_id", "content": f"resp-{label}"},
        ]

    def load_agent_start_chat(self, agent_name):
        return [{"role": "system", "content": f"Agent {agent_name}"}]

    def save_messages(self, path, messages, output_format="chat"):
        return path


class ChatAgentTest(unittest.TestCase):
    def test_chat_ask_returns_only_new_messages(self):
        runner = FakeRunner()
        chat = Chat(runner=runner).system("You are concise").user("Hello")

        delta = chat.ask()

        self.assertEqual(len(chat), 2)
        self.assertEqual(len(delta), 2)
        self.assertEqual(delta[0].role, "assistant")
        self.assertEqual(delta[0].content, "reply from llm")
        self.assertEqual(delta[1].role, "previous_response_id")

    def test_chat_chat_mutates_and_returns_last_meaningful_message(self):
        runner = FakeRunner()
        chat = Chat(runner=runner).user("Hello")

        message = chat.chat()

        self.assertIsInstance(message, Message)
        self.assertEqual(message.role, "assistant")
        self.assertEqual(str(message), "reply from llm")
        self.assertEqual(len(chat), 3)
        self.assertEqual(chat[-1].role, "previous_response_id")

    def test_agent_eager_current_chat_and_delegation(self):
        runner = FakeRunner()
        agent = load_agent("Planner", runner=runner, endpoint="nano")

        self.assertEqual(agent.start_chat[0].role, "system")
        self.assertEqual(agent.start_chat[0].content, "Agent Planner")
        self.assertEqual(agent.current_chat[1].role, "endpoint")
        self.assertEqual(agent.current_chat[1].content, "nano")

        agent.user("Summarize this")
        self.assertEqual(len(agent.start_chat), 2)
        self.assertEqual(len(agent.current_chat), 3)

        message = agent.chat()
        self.assertEqual(message.role, "assistant")
        self.assertEqual(message.content, "reply from Planner")
        self.assertEqual(agent.current_chat[-1].role, "previous_response_id")


if __name__ == "__main__":
    unittest.main()
