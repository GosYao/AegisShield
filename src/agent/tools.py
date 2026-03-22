import json
import os

import httpx
from google.cloud import storage
from langchain.tools import tool

GCS_BUCKET = os.environ.get("GCS_BUCKET", "aegis-financial-data")
SUPERVISOR_URL = os.environ.get(
    "SUPERVISOR_URL",
    "http://supervisor-svc.aegis-mesh.svc.cluster.local:8081",
)


def _check_intent(action: str, resource: str, description: str) -> bool:
    """
    Pre-flight intent check via the Supervisor before any tool executes.
    Returns True if the Supervisor approves (verdict = BENIGN), False otherwise.
    The Supervisor is fail-closed: unreachable == MALICIOUS.
    """
    try:
        with httpx.Client(timeout=10.0) as client:
            resp = client.post(
                f"{SUPERVISOR_URL}/evaluate",
                json={
                    "action": action,
                    "resource": resource,
                    "intent_description": description,
                },
            )
        data = resp.json()
        return resp.status_code == 200 and data.get("verdict") == "BENIGN"
    except Exception:
        # If supervisor is unreachable, fail closed
        return False


@tool("read_financial_data")
def read_financial_data(filename: str) -> str:
    """
    Read a financial data file from the secure GCS bucket.
    Input: just the filename, e.g. 'q3-summary.json'.
    """
    approved = _check_intent(
        action="read_gcs",
        resource=f"gs://{GCS_BUCKET}/{filename}",
        description=f"Reading financial file {filename} from GCS bucket {GCS_BUCKET}",
    )
    if not approved:
        return "Action blocked by security supervisor."

    # google-cloud-storage automatically uses Workload Identity credentials
    client = storage.Client()
    bucket = client.bucket(GCS_BUCKET)
    blob = bucket.blob(filename)
    return blob.download_as_text()


@tool("list_financial_files")
def list_financial_files(prefix: str = "") -> str:
    """
    List available financial data files in the GCS bucket.
    Input: optional filename prefix to filter results.
    """
    approved = _check_intent(
        action="list_gcs",
        resource=f"gs://{GCS_BUCKET}/{prefix}",
        description=f"Listing files in GCS bucket {GCS_BUCKET} with prefix '{prefix}'",
    )
    if not approved:
        return "Action blocked by security supervisor."

    client = storage.Client()
    bucket = client.bucket(GCS_BUCKET)
    blobs = list(bucket.list_blobs(prefix=prefix))
    return json.dumps([b.name for b in blobs])
