import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from agent_core import run_agent

app = FastAPI(title="AegisShield Agent")


class ChatRequest(BaseModel):
    message: str
    session_id: str = "default"


class ChatResponse(BaseModel):
    response: str
    actions_taken: list[str]


@app.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):
    try:
        result = await run_agent(request.message, request.session_id)
        return ChatResponse(
            response=result["output"],
            actions_taken=result.get("actions", []),
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/health")
def health():
    return {"status": "ok"}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)
