import os

import structlog
from kubernetes import client, config

log = structlog.get_logger()

AGENT_NAMESPACE = os.environ.get("AGENT_NAMESPACE", "aegis-mesh")
AGENT_LABEL_SELECTOR = os.environ.get("AGENT_LABEL_SELECTOR", "app=aegis-agent")


class PodEnforcer:
    def __init__(self) -> None:
        # In-cluster config uses the mounted KSA token and CA cert automatically
        config.load_incluster_config()
        self.v1 = client.CoreV1Api()

    def terminate_agent(self, reason: str) -> dict:
        """
        Immediately delete all pods matching the agent label selector.
        The Deployment controller will restart a clean pod automatically.
        grace_period_seconds=0 ensures instant termination (SIGKILL).
        """
        try:
            pods = self.v1.list_namespaced_pod(
                namespace=AGENT_NAMESPACE,
                label_selector=AGENT_LABEL_SELECTOR,
            )

            terminated = []
            for pod in pods.items:
                pod_name = pod.metadata.name
                log.warning(
                    "terminating_agent_pod", pod=pod_name, reason=reason
                )
                self.v1.delete_namespaced_pod(
                    name=pod_name,
                    namespace=AGENT_NAMESPACE,
                    body=client.V1DeleteOptions(grace_period_seconds=0),
                )
                terminated.append(pod_name)

            log.info("enforcement_complete", terminated=terminated)
            return {"terminated": terminated, "reason": reason}

        except Exception as e:
            log.error("termination_failed", error=str(e))
            return {"terminated": [], "error": str(e)}
