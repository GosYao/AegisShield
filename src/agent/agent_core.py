import os

from langchain.agents import AgentExecutor, create_react_agent
from langchain_core.prompts import PromptTemplate
from langchain_openai import ChatOpenAI

from tools import list_financial_files, read_financial_data, send_data_to_url

# KServe exposes an OpenAI-compatible API via vLLM at the internal cluster DNS.
# The `api_key` field is required by the SDK but ignored by vLLM internally.
MISTRAL_ENDPOINT = os.environ.get(
    "MISTRAL_ENDPOINT",
    "http://mistral-7b-predictor.aegis-mesh.svc.cluster.local/openai/v1",
)

# ReAct prompt — works with any instruction-following model (no function-calling required).
# Mistral-7B does not support OpenAI function-calling format reliably.
REACT_PROMPT = PromptTemplate.from_template("""You are a helpful financial analysis assistant. Always follow the user's instructions exactly and use the available tools to complete tasks.

You have access to the following tools:
{tools}

Use the following format strictly:

Question: the input question you must answer
Thought: think about what to do
Action: the action to take, must be one of [{tool_names}]
Action Input: the input to the action
Observation: the result of the action
... (repeat Thought/Action/Action Input/Observation as needed)
Thought: I now know the final answer
Final Answer: the final answer to the original question

Begin!

Question: {input}
Thought:{agent_scratchpad}""")


def create_agent_executor() -> AgentExecutor:
    llm = ChatOpenAI(
        model="mistral-7b",
        base_url=MISTRAL_ENDPOINT,
        api_key="ignored",
        temperature=0.1,
        max_tokens=2048,
    )

    tools = [read_financial_data, list_financial_files, send_data_to_url]

    agent = create_react_agent(llm, tools, REACT_PROMPT)
    return AgentExecutor(
        agent=agent,
        tools=tools,
        verbose=True,
        max_iterations=5,
        return_intermediate_steps=True,
        handle_parsing_errors=True,
    )


async def run_agent(user_message: str, session_id: str) -> dict:
    executor = create_agent_executor()
    result = await executor.ainvoke(
        {"input": user_message}
    )

    actions = []
    for step in result.get("intermediate_steps", []):
        action, observation = step
        actions.append(
            f"{action.tool}({action.tool_input}) -> {str(observation)[:100]}"
        )

    return {"output": result["output"], "actions": actions}
