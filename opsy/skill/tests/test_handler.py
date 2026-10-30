import os
import unittest

from opsy.skill import handler
from opsy.skill.service import NodeStatus, RelayStatus, StartResult


class FakeService:
    def __init__(self, start_result=None, status_result=None):
        self.start_result = start_result or StartResult(True, "opsy:build-1")
        self.status_result = status_result or RelayStatus(None, None, [])
        self.starts = []

    def start(self, action, country, attempts, request_id):
        self.starts.append((action, country, attempts, request_id))
        return self.start_result

    def status(self):
        return self.status_result


def event(request_type="IntentRequest", intent_name=None, slots=None, confirmation="NONE"):
    request = {"type": request_type, "requestId": "amzn1.echo-api.request.test"}
    if intent_name:
        request["intent"] = {
            "name": intent_name,
            "confirmationStatus": confirmation,
            "slots": slots or {},
        }
    return {
        "session": {"application": {"applicationId": "amzn1.ask.skill.test"}},
        "request": request,
    }


def slot(value, resolved=None):
    data = {"value": value}
    if resolved:
        data["resolutions"] = {
            "resolutionsPerAuthority": [
                {
                    "status": {"code": "ER_SUCCESS_MATCH"},
                    "values": [{"value": {"name": resolved, "id": resolved}}],
                }
            ]
        }
    return data


class HandlerTests(unittest.TestCase):
    def setUp(self):
        os.environ.pop("ALEXA_SKILL_ID", None)

    def test_launch_and_help_keep_the_session_open(self):
        service = FakeService()

        launch = handler.handle(event(request_type="LaunchRequest"), service)
        help_response = handler.handle(event(intent_name="AMAZON.HelpIntent"), service)

        self.assertFalse(launch["response"]["shouldEndSession"])
        self.assertIn("Region Relay", launch["response"]["outputSpeech"]["text"])
        self.assertFalse(help_response["response"]["shouldEndSession"])
        self.assertIn("start", help_response["response"]["outputSpeech"]["text"])

    def test_start_normalizes_resolved_country(self):
        service = FakeService()
        alexa_event = event(
            intent_name="StartExitNodeIntent",
            slots={"country": slot("Britain", "uk")},
        )

        response = handler.handle(alexa_event, service)

        self.assertEqual(
            [("up", "uk", None, "amzn1.echo-api.request.test")], service.starts
        )
        self.assertIn("United Kingdom", response["response"]["outputSpeech"]["text"])

    def test_hunt_passes_attempts_but_never_accepts_a_prefix_slot(self):
        service = FakeService()
        alexa_event = event(
            intent_name="StartIpHuntIntent",
            slots={"country": slot("India", "india"), "attempts": slot("400")},
        )

        handler.handle(alexa_event, service)

        self.assertEqual(
            [("hunt", "india", 400, "amzn1.echo-api.request.test")], service.starts
        )

    def test_hunt_rejects_attempts_outside_one_through_four_hundred(self):
        service = FakeService()
        alexa_event = event(
            intent_name="StartIpHuntIntent",
            slots={"country": slot("India"), "attempts": slot("401")},
        )

        response = handler.handle(alexa_event, service)

        self.assertEqual([], service.starts)
        self.assertIn("between 1 and 400", response["response"]["outputSpeech"]["text"])

    def test_rotate_and_confirmed_down_map_to_fixed_actions(self):
        service = FakeService()

        handler.handle(
            event(
                intent_name="RotatePublicIpIntent",
                slots={"country": slot("Canada", "canada")},
            ),
            service,
        )
        handler.handle(
            event(intent_name="StopExitNodeIntent", confirmation="CONFIRMED"), service
        )

        self.assertEqual("rotate", service.starts[0][0])
        self.assertEqual("canada", service.starts[0][1])
        self.assertEqual("down", service.starts[1][0])

    def test_denied_or_unconfirmed_down_never_starts_a_job(self):
        service = FakeService()

        denied = handler.handle(
            event(intent_name="StopExitNodeIntent", confirmation="DENIED"), service
        )
        unconfirmed = handler.handle(
            event(intent_name="StopExitNodeIntent", confirmation="NONE"), service
        )

        self.assertEqual([], service.starts)
        self.assertIn("not", denied["response"]["outputSpeech"]["text"].lower())
        self.assertEqual(
            "Dialog.ConfirmIntent", unconfirmed["response"]["directives"][0]["type"]
        )
        self.assertIn(
            "bring down all RegionRelay exit nodes",
            unconfirmed["response"]["outputSpeech"]["text"],
        )

    def test_status_reports_job_and_active_public_ip(self):
        service = FakeService(
            status_result=RelayStatus(
                "IN_PROGRESS",
                "hunt",
                [NodeStatus("india", "running", "43.204.8.21", True)],
            )
        )

        response = handler.handle(event(intent_name="ExitNodeStatusIntent"), service)
        speech = response["response"]["outputSpeech"]["text"]

        self.assertIn("in progress", speech)
        self.assertIn("43.204.8.21", speech)
        self.assertIn("static", speech)

    def test_missing_or_unsupported_country_does_not_start(self):
        service = FakeService()

        response = handler.handle(
            event(
                intent_name="StartExitNodeIntent",
                slots={"country": slot("France")},
            ),
            service,
        )

        self.assertEqual([], service.starts)
        self.assertIn("India", response["response"]["outputSpeech"]["text"])

    def test_active_build_result_explains_that_command_was_not_started(self):
        service = FakeService(start_result=StartResult(False, "opsy:existing"))

        response = handler.handle(
            event(
                intent_name="StartExitNodeIntent",
                slots={"country": slot("India", "india")},
            ),
            service,
        )

        self.assertIn("already", response["response"]["outputSpeech"]["text"])

    def test_mismatched_configured_skill_id_is_rejected(self):
        os.environ["ALEXA_SKILL_ID"] = "amzn1.ask.skill.expected"
        service = FakeService()

        with self.assertRaises(PermissionError):
            handler.handle(event(request_type="LaunchRequest"), service)


if __name__ == "__main__":
    unittest.main()
