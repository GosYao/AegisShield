import time
import uuid
import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Any

from agent_core import run_agent

app = FastAPI(title="AegisShield Agent")


class ChatRequest(BaseModel):
    message: str
    session_id: str = "default"


class ChatResponse(BaseModel):
    response: str
    actions_taken: list[str]


@app.post("/chat", response_model=ChatResponse)
@app.post("/v1/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):
    try:
        result = await run_agent(request.message, request.session_id)
        return ChatResponse(
            response=result["output"],
            actions_taken=result.get("actions", []),
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/v1/chat/completions")
@app.post("/chat/completions")
async def openai_chat(request: dict[str, Any]):
    """OpenAI-compatible endpoint for FortiAIGate AI Flow integration.
    Accepts OpenAI /v1/chat/completions format, runs through agent logic,
    returns OpenAI-compatible response.
    """
    try:
        messages = request.get("messages", [])
        # Extract the last user message as the prompt
        user_message = next(
            (m["content"] for m in reversed(messages) if m.get("role") == "user"),
            "",
        )
        if not user_message:
            raise HTTPException(status_code=400, detail="No user message found")

        session_id = request.get("user", "default")
        result = await run_agent(user_message, session_id)

        return {
            "id": f"chatcmpl-{uuid.uuid4().hex[:8]}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": request.get("model", "aegis-agent"),
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": result["output"],
                },
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/health")
def health():
    return {"status": "ok"}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)
