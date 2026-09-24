"""A local LangChain agent with synthetic replies and no model-provider calls."""

import itertools
from collections.abc import Iterator

from langchain.agents import create_agent
from langchain_core.language_models.fake_chat_models import GenericFakeChatModel
from langchain_core.messages import AIMessage

from loadtest.payloads.generator import PayloadGenerator

PAYLOAD_KEY = "load_test_payload"


class EchoReplies:
    """Supply replies to the fake model, including calls from its worker threads."""

    def __init__(self, payloads: PayloadGenerator) -> None:
        self.payloads = payloads
        self.reply_numbers = itertools.count()

    def __iter__(self) -> Iterator[AIMessage]:
        return self

    def __next__(self) -> AIMessage:
        reply_number = next(self.reply_numbers)
        usage = None
        if reply_number % 2:
            usage = {"input_tokens": 512, "output_tokens": 128, "total_tokens": 640}
        return AIMessage(
            content="ok",
            additional_kwargs={PAYLOAD_KEY: self.payloads.next_payload().outputs},
            usage_metadata=usage,
        )


def create_echo_agent(payloads: PayloadGenerator):
    model = GenericFakeChatModel(messages=EchoReplies(payloads))
    return create_agent(model=model, tools=[])
