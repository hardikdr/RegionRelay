import json
import logging
import os
from typing import Dict, Optional

from botocore.exceptions import BotoCoreError, ClientError

from .service import RegionRelayService, RelayStatus


LOGGER = logging.getLogger(__name__)
LOGGER.setLevel(logging.INFO)

COUNTRY_ALIASES = {
    "india": "india",
    "uk": "uk",
    "united kingdom": "uk",
    "great britain": "uk",
    "britain": "uk",
    "canada": "canada",
    "singapore": "singapore",
}
COUNTRY_LABELS = {
    "india": "India",
    "uk": "the United Kingdom",
    "canada": "Canada",
    "singapore": "Singapore",
}

_SERVICE = None


def _response(text: str, end_session: bool = True, reprompt: Optional[str] = None):
    body = {
        "outputSpeech": {"type": "PlainText", "text": text},
        "shouldEndSession": end_session,
    }
    if reprompt:
        body["reprompt"] = {
            "outputSpeech": {"type": "PlainText", "text": reprompt}
        }
    return {"version": "1.0", "response": body}


def _confirm_down_response():
    return {
        "version": "1.0",
        "response": {
            "outputSpeech": {
                "type": "PlainText",
                "text": "Please confirm that you want me to bring down all RegionRelay exit nodes.",
            },
            "directives": [{"type": "Dialog.ConfirmIntent"}],
            "shouldEndSession": False,
        },
    }


def _slot_value(intent: Dict, name: str) -> Optional[str]:
    slot = intent.get("slots", {}).get(name, {})
    authorities = slot.get("resolutions", {}).get("resolutionsPerAuthority", [])
    for authority in authorities:
        if authority.get("status", {}).get("code") != "ER_SUCCESS_MATCH":
            continue
        values = authority.get("values", [])
        if values:
            return values[0].get("value", {}).get("id") or values[0].get(
                "value", {}
            ).get("name")
    return slot.get("value")


def _country(intent: Dict) -> Optional[str]:
    value = _slot_value(intent, "country")
    if not value:
        return None
    return COUNTRY_ALIASES.get(value.strip().lower())


def _application_id(event: Dict) -> Optional[str]:
    session_id = event.get("session", {}).get("application", {}).get("applicationId")
    if session_id:
        return session_id
    return (
        event.get("context", {})
        .get("System", {})
        .get("application", {})
        .get("applicationId")
    )


def _validate_skill_id(event: Dict) -> None:
    expected = os.environ.get("ALEXA_SKILL_ID")
    if expected and _application_id(event) != expected:
        raise PermissionError("Alexa Skill ID did not match")


def _status_speech(status: RelayStatus) -> str:
    parts = []
    if status.job_status == "IN_PROGRESS":
        action = status.action or "lifecycle"
        parts.append("The {} job is in progress.".format(action))
    elif status.job_status:
        action = status.action or "latest"
        parts.append(
            "The {} job finished with status {}.".format(
                action, status.job_status.lower().replace("_", " ")
            )
        )
    else:
        parts.append("No Region Relay job has run yet.")

    if not status.nodes:
        parts.append("No exit node is currently present.")
    for node in status.nodes:
        address_kind = "static" if node.is_static else "dynamic"
        parts.append(
            "The exit node in {} is {}, with {} public IP {}.".format(
                COUNTRY_LABELS[node.country], node.state, address_kind, node.public_ip
            )
        )
    return " ".join(parts)


def _start_response(service, action, country, attempts, request_id):
    result = service.start(action, country, attempts, request_id)
    if not result.started:
        return _response(
            "A Region Relay job is already running. Ask Region Relay for status in a minute."
        )
    if action == "up":
        text = "I started bringing up the exit node in {}.".format(
            COUNTRY_LABELS[country]
        )
    elif action == "hunt":
        text = "I started hunting for your configured IP prefix in {}, with up to {} attempts.".format(
            COUNTRY_LABELS[country], attempts
        )
    elif action == "rotate":
        text = "I started rotating the public IP in {}.".format(
            COUNTRY_LABELS[country]
        )
    else:
        text = "I started bringing down all RegionRelay exit nodes."
    return _response(text + " Ask Region Relay for status in a minute.")


def handle(event: Dict, service):
    _validate_skill_id(event)
    request = event.get("request", {})
    request_type = request.get("type")
    help_text = (
        "Region Relay can start an exit node, hunt for your configured public IP prefix, "
        "rotate the public IP, report status, or bring the exit node down."
    )

    if request_type == "LaunchRequest":
        return _response(
            "Region Relay is ready. You can ask me to start an exit node or check status.",
            end_session=False,
            reprompt="What should Region Relay do?",
        )
    if request_type == "SessionEndedRequest":
        return {"version": "1.0", "response": {"shouldEndSession": True}}
    if request_type != "IntentRequest":
        return _response("I could not understand that Alexa request.")

    intent = request.get("intent", {})
    name = intent.get("name")
    request_id = request.get("requestId", "unknown")

    if name == "AMAZON.HelpIntent":
        return _response(help_text, end_session=False, reprompt="What should Region Relay do?")
    if name in {"AMAZON.CancelIntent", "AMAZON.StopIntent"}:
        return _response("Okay.")
    if name == "ExitNodeStatusIntent":
        return _response(_status_speech(service.status()))
    if name == "StopExitNodeIntent":
        confirmation = intent.get("confirmationStatus")
        if confirmation == "DENIED":
            return _response("Okay, I did not bring down the exit node.")
        if confirmation != "CONFIRMED":
            return _confirm_down_response()
        return _start_response(service, "down", "india", None, request_id)

    country = _country(intent)
    if not country:
        return _response(
            "Choose India, the United Kingdom, Canada, or Singapore."
        )
    if name == "StartExitNodeIntent":
        return _start_response(service, "up", country, None, request_id)
    if name == "RotatePublicIpIntent":
        return _start_response(service, "rotate", country, None, request_id)
    if name == "StartIpHuntIntent":
        raw_attempts = _slot_value(intent, "attempts") or "20"
        try:
            attempts = int(raw_attempts)
        except (TypeError, ValueError):
            attempts = 0
        if not 1 <= attempts <= 400:
            return _response("Choose a number of attempts between 1 and 400.")
        return _start_response(service, "hunt", country, attempts, request_id)
    return _response(help_text, end_session=False, reprompt="What should Region Relay do?")


def _default_service():
    global _SERVICE
    if _SERVICE is None:
        _SERVICE = RegionRelayService(os.environ["CODEBUILD_PROJECT_NAME"])
    return _SERVICE


def lambda_handler(event, context):
    try:
        return handle(event, _default_service())
    except PermissionError:
        raise
    except (ClientError, BotoCoreError, KeyError, ValueError) as error:
        LOGGER.error(
            json.dumps(
                {
                    "event": "opsy_request_failed",
                    "request_id": event.get("request", {}).get("requestId"),
                    "error_type": type(error).__name__,
                }
            )
        )
        return _response(
            "Region Relay could not reach the AWS control service. Please try again later."
        )
