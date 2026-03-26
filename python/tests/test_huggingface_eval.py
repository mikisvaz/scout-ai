import unittest

from scout_ai.huggingface.eval import parse_causal_lm_response


class DummyTokenizer:
    pass


class ParserTokenizer:
    def parse_response(self, text):
        return {
            "role": "assistant",
            "content": "",
            "tool_calls": [
                {
                    "type": "function",
                    "function": {
                        "name": "multiply",
                        "arguments": {"a": 3, "b": 4},
                    },
                    "id": "call_1",
                }
            ],
        }


class HuggingfaceEvalTest(unittest.TestCase):
    def test_parse_xml_tool_call_blocks(self):
        tokenizer = DummyTokenizer()
        text = '<tool_call>{"name": "multiply", "arguments": {"a": 3, "b": 4}}</tool_call>'

        parsed = parse_causal_lm_response(tokenizer, text)

        self.assertEqual(parsed["role"], "assistant")
        self.assertEqual(parsed["tool_calls"][0]["function"]["name"], "multiply")
        self.assertEqual(parsed["tool_calls"][0]["function"]["arguments"]["a"], 3)

    def test_parse_tokenizer_response(self):
        tokenizer = ParserTokenizer()
        text = "ignored"

        parsed = parse_causal_lm_response(tokenizer, text)

        self.assertEqual(parsed["tool_calls"][0]["id"], "call_1")
        self.assertEqual(parsed["tool_calls"][0]["function"]["arguments"]["b"], 4)

    def test_parse_plain_text_when_disabled(self):
        tokenizer = ParserTokenizer()
        text = '<tool_call>{"name": "multiply", "arguments": {"a": 3, "b": 4}}</tool_call>'

        parsed = parse_causal_lm_response(tokenizer, text, response_parser="none")

        self.assertEqual(parsed, {"role": "assistant", "content": text})


if __name__ == "__main__":
    unittest.main()
