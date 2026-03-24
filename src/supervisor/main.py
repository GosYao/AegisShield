import os
from collections import defaultdict
from typing import Optional

import structlog
import uvicorn
from fastapi import BackgroundTasks, FastAPI, Request
from pydantic import BaseModel

from enforcer import PodEnforcer
from evaluator import IntentEvaluator

log = structlog.get_logger()

app = FastAPI(title="AegisShield Supervisor")

evaluator = IntentEvaluator()
enforcer = PodEnforcer()

# Number of consecutive MALICIOUS verdicts before the agent pod is terminated.
# Configurable via env var; defaults to 3.
STRIKE_LIMIT = int(os.environ.get("MALICIOUS_STRIKE_LIMIT", "3"))

# In-memory strike counters.
# Key: session_id (primary) or client IP (fallback).
# Value: consecutive MALICIOUS count.
_strikes: dict[str, int] = defaultdict(int)


def _strike_key(session_id: Optional[str], client_ip: str) -> str:
    """Return session_id if present and non-trivial, else fall back to client IP."""
    if session_id and len(session_id) > 4:
        return f"session:{session_id}"
    return f"ip:{client_ip}"


class EvaluateRequest(BaseModel):
    action: str
    resource: str
    intent_description: str
    session_id: Optional[str] = None


class EvaluateResponse(BaseModel):
    verdict: str
    reason: str
    enforcement_action: str = "none"
    strikes: int = 0
    strike_limit: int = STRIKE_LIMIT


@app.post("/evaluate", response_model=EvaluateResponse)
async def evaluate(
    request: EvaluateRequest,
    http_request: Request,
    background_tasks: BackgroundTasks,
):
    result = await evaluator.evaluate(
        action=request.action,
        resource=request.resource,
        intent_description=request.intent_description,
    )

    client_ip = http_request.client.host if http_request.client else "unknown"
    key = _strike_key(request.session_id, client_ip)
    enforcement = "none"
    current_strikes = 0

    if result["verdict"] == "MALICIOUS":
        _strikes[key] += 1
        current_strikes = _strikes[key]

        log.warning(
            "malicious_intent_detected",
            action=request.action,
            resource=request.resource,
            reason=result["reason"],
            strike_key=key,
            strikes=current_strikes,
            strike_limit=STRIKE_LIMIT,
        )

        if current_strikes >= STRIKE_LIMIT:
            log.error(
                "strike_limit_reached",
                strike_key=key,
                strikes=current_strikes,
                action="terminating_agent_pod",
            )
            _strikes[key] = 0  # reset so a restarted pod starts clean
            background_tasks.add_task(enforcer.terminate_agent, reason=result["reason"])
            enforcement = "pod_terminated"
        else:
            enforcement = "blocked"

    else:
        # BENIGN verdict — reset strike counter for this key
        if _strikes[key] > 0:
            log.info("strikes_reset", strike_key=key, previous_strikes=_strikes[key])
        _strikes[key] = 0
        current_strikes = 0

    return EvaluateResponse(
        verdict=result["verdict"],
        reason=result["reason"],
        enforcement_action=enforcement,
        strikes=current_strikes,
        strike_limit=STRIKE_LIMIT,
    )


@app.get("/health")
def health():
    return {"status": "ok"}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8081)
