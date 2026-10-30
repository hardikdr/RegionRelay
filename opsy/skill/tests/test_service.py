import unittest

from opsy.skill.service import RegionRelayService


class FakeNotFound(Exception):
    pass


class FakeLightsail:
    class exceptions:
        NotFoundException = FakeNotFound

    def __init__(self, instance=None, static_ips=None):
        self.instance = instance
        self.static_ips = static_ips or []

    def get_instance(self, instanceName):
        if not self.instance:
            raise FakeNotFound()
        self.asserted_instance_name = instanceName
        return {"instance": self.instance}

    def get_static_ips(self):
        return {"staticIps": self.static_ips}


class FakeCodeBuild:
    def __init__(self, builds=None):
        self.builds = builds or []
        self.start_calls = []

    def list_builds_for_project(self, **kwargs):
        self.list_args = kwargs
        return {"ids": [build["id"] for build in self.builds]}

    def batch_get_builds(self, ids):
        wanted = set(ids)
        return {"builds": [build for build in self.builds if build["id"] in wanted]}

    def start_build(self, **kwargs):
        self.start_calls.append(kwargs)
        return {"build": {"id": "opsy:build-2"}}


class ServiceTests(unittest.TestCase):
    def service(self, codebuild, clients=None):
        clients = clients or {}
        return RegionRelayService(
            project_name="opsy-project",
            codebuild=codebuild,
            lightsail_factory=lambda region: clients.get(region, FakeLightsail()),
        )

    def test_start_rejects_duplicate_while_latest_build_is_active(self):
        codebuild = FakeCodeBuild(
            [{"id": "opsy:active", "buildStatus": "IN_PROGRESS"}]
        )
        service = self.service(codebuild)

        result = service.start("up", "india", None, "request-1")

        self.assertFalse(result.started)
        self.assertEqual("opsy:active", result.build_id)
        self.assertEqual([], codebuild.start_calls)

    def test_start_build_uses_only_fixed_environment_overrides(self):
        codebuild = FakeCodeBuild()
        service = self.service(codebuild)

        result = service.start("hunt", "canada", 400, "request-2")

        self.assertTrue(result.started)
        call = codebuild.start_calls[0]
        self.assertEqual("opsy-project", call["projectName"])
        self.assertEqual(
            "6fc63565247226593c49a36e9da488e6e1c33a9a1fcd8a76f55573483136b880",
            call["idempotencyToken"],
        )
        self.assertEqual(
            [
                {"name": "OPSY_ACTION", "value": "hunt", "type": "PLAINTEXT"},
                {"name": "OPSY_COUNTRY", "value": "canada", "type": "PLAINTEXT"},
                {"name": "OPSY_HUNT_ATTEMPTS", "value": "400", "type": "PLAINTEXT"},
                {"name": "OPSY_REQUEST_ID", "value": "request-2", "type": "PLAINTEXT"},
            ],
            call["environmentVariablesOverride"],
        )

    def test_status_handles_no_build_history_and_no_instances(self):
        status = self.service(FakeCodeBuild()).status()

        self.assertIsNone(status.job_status)
        self.assertIsNone(status.action)
        self.assertEqual([], status.nodes)

    def test_status_reports_active_instance_and_attached_static_ip(self):
        build = {
            "id": "opsy:done",
            "buildStatus": "SUCCEEDED",
            "environment": {
                "environmentVariables": [
                    {"name": "OPSY_ACTION", "value": "hunt"},
                    {"name": "OPSY_COUNTRY", "value": "india"},
                ]
            },
        }
        india = FakeLightsail(
            instance={
                "name": "india-exit-mumbai",
                "state": {"name": "running"},
                "publicIpAddress": "43.204.8.21",
            },
            static_ips=[
                {
                    "name": "india-exit-mumbai-hunt-1",
                    "ipAddress": "43.204.8.21",
                    "attachedTo": "india-exit-mumbai",
                }
            ],
        )
        service = self.service(
            FakeCodeBuild([build]), {"ap-south-1": india}
        )

        status = service.status()

        self.assertEqual("SUCCEEDED", status.job_status)
        self.assertEqual("hunt", status.action)
        self.assertEqual(1, len(status.nodes))
        self.assertEqual("india", status.nodes[0].country)
        self.assertEqual("43.204.8.21", status.nodes[0].public_ip)
        self.assertTrue(status.nodes[0].is_static)


if __name__ == "__main__":
    unittest.main()
