import structlog
import uvicorn
from fastapi import BackgroundTasks, FastAPI
from pydantic import BaseModel

from enforcer import PodEnforcer
from evaluator import IntentEvaluator

log = structlog.get_logger()

app = FastAPI(title="AegisShield Supervisor")

evaluator = IntentEvaluator()
enforcer = PodEnforcer()


class EvaluateRequest(BaseModel):
    action: str
    resource: str
    intent_description: str


class EvaluateResponse(BaseModel):
    verdict: str
    reason: str
    enforcement_action: str = "none"


@app.post("/evaluate", response_model=EvaluateResponse)
async def evaluate(request: EvaluateRequest, background_tasks: BackgroundTasks):
    result = await evaluator.evaluate(
        action=request.action,
        resource=request.resource,
        intent_description=request.intent_description,
    )

    enforcement = "none"
    if result["verdict"] == "MALICIOUS":
        log.warning(
            "malicious_intent_detected",
            action=request.action,
            resource=request.resource,
            reason=result["reason"],
        )
        # Schedule pod deletion as a background task so the response
        # is returned to the agent before the pod is killed.
        background_tasks.add_task(enforcer.terminate_agent, reason=result["reason"])
        enforcement = "pod_terminated"

    return EvaluateResponse(
        verdict=result["verdict"],
        reason=result["reason"],
        enforcement_action=enforcement,
    )


@app.get("/health")
def health():
    return {"status": "ok"}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8081)
