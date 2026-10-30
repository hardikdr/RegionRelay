import hashlib
from dataclasses import dataclass
from typing import Callable, Dict, List, Optional, Tuple

import boto3
from botocore.config import Config


COUNTRIES: Dict[str, Tuple[str, str]] = {
    "india": ("ap-south-1", "india-exit-mumbai"),
    "uk": ("eu-west-2", "stream-exit-uk"),
    "canada": ("ca-central-1", "stream-exit-canada"),
    "singapore": ("ap-southeast-1", "stream-exit-singapore"),
}
ALLOWED_ACTIONS = {"up", "down", "rotate", "hunt"}
ACTIVE_BUILD_STATUSES = {"IN_PROGRESS"}


@dataclass(frozen=True)
class StartResult:
    started: bool
    build_id: Optional[str]


@dataclass(frozen=True)
class NodeStatus:
    country: str
    state: str
    public_ip: str
    is_static: bool


@dataclass(frozen=True)
class RelayStatus:
    job_status: Optional[str]
    action: Optional[str]
    nodes: List[NodeStatus]


class RegionRelayService:
    def __init__(
        self,
        project_name: str,
        codebuild=None,
        lightsail_factory: Optional[Callable[[str], object]] = None,
    ):
        if not project_name:
            raise ValueError("project_name is required")
        config = Config(
            retries={"total_max_attempts": 2, "mode": "standard"},
            connect_timeout=3,
            read_timeout=5,
            user_agent_extra="region-relay-opsy/1.0",
        )
        self.project_name = project_name
        self.codebuild = codebuild or boto3.client("codebuild", config=config)
        self.lightsail_factory = lightsail_factory or (
            lambda region: boto3.client("lightsail", region_name=region, config=config)
        )

    def _builds(self):
        response = self.codebuild.list_builds_for_project(
            projectName=self.project_name, sortOrder="DESCENDING"
        )
        ids = response.get("ids", [])[:10]
        if not ids:
            return []
        builds = self.codebuild.batch_get_builds(ids=ids).get("builds", [])
        order = {build_id: index for index, build_id in enumerate(ids)}
        return sorted(builds, key=lambda item: order.get(item.get("id"), len(order)))

    def start(
        self,
        action: str,
        country: str,
        attempts: Optional[int],
        request_id: str,
    ) -> StartResult:
        if action not in ALLOWED_ACTIONS:
            raise ValueError("unsupported action")
        if country not in COUNTRIES:
            raise ValueError("unsupported country")
        if action == "hunt" and (
            attempts is None or not isinstance(attempts, int) or not 1 <= attempts <= 400
        ):
            raise ValueError("hunt attempts must be between 1 and 400")
        if not request_id or len(request_id) > 256:
            raise ValueError("invalid request ID")

        builds = self._builds()
        active = next(
            (
                build
                for build in builds
                if build.get("buildStatus") in ACTIVE_BUILD_STATUSES
            ),
            None,
        )
        if active:
            return StartResult(False, active.get("id"))

        overrides = [
            {"name": "OPSY_ACTION", "value": action, "type": "PLAINTEXT"},
            {"name": "OPSY_COUNTRY", "value": country, "type": "PLAINTEXT"},
        ]
        if action == "hunt":
            overrides.append(
                {
                    "name": "OPSY_HUNT_ATTEMPTS",
                    "value": str(attempts),
                    "type": "PLAINTEXT",
                }
            )
        overrides.append(
            {"name": "OPSY_REQUEST_ID", "value": request_id, "type": "PLAINTEXT"}
        )
        response = self.codebuild.start_build(
            projectName=self.project_name,
            environmentVariablesOverride=overrides,
            idempotencyToken=hashlib.sha256(request_id.encode("utf-8")).hexdigest(),
        )
        return StartResult(True, response["build"]["id"])

    @staticmethod
    def _build_variable(build, name: str) -> Optional[str]:
        environment = build.get("environment", {})
        for variable in environment.get("environmentVariables", []):
            if variable.get("name") == name:
                return variable.get("value")
        return None

    def status(self) -> RelayStatus:
        builds = self._builds()
        latest = builds[0] if builds else None
        nodes: List[NodeStatus] = []

        for country, (region, instance_name) in COUNTRIES.items():
            client = self.lightsail_factory(region)
            try:
                instance = client.get_instance(instanceName=instance_name)["instance"]
            except client.exceptions.NotFoundException:
                continue

            attached_static = any(
                item.get("attachedTo") == instance_name
                for item in client.get_static_ips().get("staticIps", [])
            )
            state = instance.get("state", {}).get("name", "unknown")
            nodes.append(
                NodeStatus(
                    country=country,
                    state=state,
                    public_ip=instance.get("publicIpAddress", "unknown"),
                    is_static=attached_static,
                )
            )

        return RelayStatus(
            job_status=latest.get("buildStatus") if latest else None,
            action=self._build_variable(latest, "OPSY_ACTION") if latest else None,
            nodes=nodes,
        )
