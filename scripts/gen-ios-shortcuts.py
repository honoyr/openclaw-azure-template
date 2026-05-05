#!/usr/bin/env python3
"""Generate iOS Shortcut .shortcut files (binary plist) for OpenClaw control."""
import plistlib, uuid, os, sys

# Pull credentials from env
TENANT  = os.environ["PHONE_CONTROL_TENANT_ID"]
CLIENT  = os.environ["PHONE_CONTROL_CLIENT_ID"]
SECRET  = os.environ["PHONE_CONTROL_CLIENT_SECRET"]
SUB     = os.environ["SUBSCRIPTION"]
RG      = os.environ["RG"]
NAME    = os.environ["CONTAINER"]

ACI_PATH  = f"/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.ContainerInstance/containerGroups/{NAME}"
TOKEN_URL = f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/token"
ARM_BASE  = f"https://management.azure.com{ACI_PATH}"

OBJ = "\uFFFC"  # Object Replacement Character — placeholder for inline variable

def U(): return str(uuid.uuid4()).upper()

def text(s, atts=None):
    """A WFTextTokenString — plain text or text with variable attachments."""
    return {
        "Value": {"string": s, "attachmentsByRange": atts or {}},
        "WFSerializationType": "WFTextTokenString",
    }

def attach(out_uuid, out_name="Dictionary Value"):
    return {"Type": "ActionOutput", "OutputName": out_name, "OutputUUID": out_uuid,
            "Aggrandizements": []}

def var_input(out_uuid, out_name):
    """A WFTextTokenAttachment — used as WFInput to explicitly chain a prior action's output."""
    return {
        "Value": attach(out_uuid, out_name),
        "WFSerializationType": "WFTextTokenAttachment",
    }

def dict_field(items):
    return {
        "Value": {"WFDictionaryFieldValueItems": items},
        "WFSerializationType": "WFDictionaryFieldValue",
    }

def kv(k, v):  # key/value pair for form/header dictionaries
    return {"WFItemType": 0, "WFKey": text(k), "WFValue": text(v) if isinstance(v, str) else v}

def url_action(u):
    return {
        "WFWorkflowActionIdentifier": "is.workflow.actions.url",
        "WFWorkflowActionParameters": {"UUID": U(), "WFURLActionURL": u},
    }

def post_form(url, form_pairs):
    return {
        "WFWorkflowActionIdentifier": "is.workflow.actions.downloadurl",
        "WFWorkflowActionParameters": {
            "UUID": U(),
            "WFURL": text(url),
            "WFHTTPMethod": "POST",
            "WFHTTPBodyType": "Form",
            "WFFormValues": dict_field([kv(k, v) for k, v in form_pairs]),
        },
    }

def get_dict_value(key, prev_uuid, prev_output="Dictionary Value"):
    return {
        "WFWorkflowActionIdentifier": "is.workflow.actions.getvalueforkey",
        "WFWorkflowActionParameters": {
            "UUID": U(),
            "WFGetDictionaryValueType": "Value",
            "WFDictionaryKey": text(key),
            "WFInput": var_input(prev_uuid, prev_output),
        },
    }

def http_with_auth(url, method, body_type, token_action_uuid, json_body=None):
    auth_value = {
        "Value": {
            "string": f"Bearer {OBJ}",
            "attachmentsByRange": {"{7, 1}": attach(token_action_uuid)},
        },
        "WFSerializationType": "WFTextTokenString",
    }
    params = {
        "UUID": U(),
        "WFURL": text(url),
        "WFHTTPMethod": method,
        "WFHTTPHeaders": dict_field([kv("Authorization", auth_value)]),
    }
    if body_type:
        params["WFHTTPBodyType"] = body_type
        if body_type == "JSON" and json_body is not None:
            params["WFJSONValues"] = dict_field([kv(k, v) for k, v in json_body])
    return {
        "WFWorkflowActionIdentifier": "is.workflow.actions.downloadurl",
        "WFWorkflowActionParameters": params,
    }

def show_result(prev_action_uuid, label):
    body = {
        "Value": {
            "string": f"{label}: {OBJ}",
            "attachmentsByRange": {f"{{{len(label)+2}, 1}}": attach(prev_action_uuid, "Contents of URL")},
        },
        "WFSerializationType": "WFTextTokenString",
    }
    return {
        "WFWorkflowActionIdentifier": "is.workflow.actions.showresult",
        "WFWorkflowActionParameters": {"UUID": U(), "Text": body},
    }

def notification(text_str):
    return {
        "WFWorkflowActionIdentifier": "is.workflow.actions.notification",
        "WFWorkflowActionParameters": {"UUID": U(), "WFNotificationActionBody": text(text_str)},
    }

def shortcut(actions, glyph=59511, color=4282601983):
    return {
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "2607.0.3",
        "WFWorkflowClientRelease": "7.0",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {
            "WFWorkflowIconStartColor": color,
            "WFWorkflowIconGlyphNumber": glyph,
        },
        "WFWorkflowImportQuestions": [],
        "WFWorkflowTypes": [],
        "WFWorkflowInputContentItemClasses": [
            "WFAppContentItem","WFAppStoreAppContentItem","WFArticleContentItem",
            "WFContactContentItem","WFDateContentItem","WFEmailAddressContentItem",
            "WFGenericFileContentItem","WFImageContentItem","WFiTunesProductContentItem",
            "WFLocationContentItem","WFDictionaryContentItem","WFMapsLinkContentItem",
            "WFNoInputContentItem","WFNumberContentItem","WFPDFContentItem",
            "WFPhoneNumberContentItem","WFRichTextContentItem","WFSafariWebPageContentItem",
            "WFStringContentItem","WFTimeContentItem","WFURLContentItem"
        ],
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowHasShortcutInputVariables": False,
        "WFWorkflowHasOutputFallback": False,
        "WFQuickActionSurfaces": [],
    }

def build_token_chain():
    """Returns (actions, token_extractor_uuid)."""
    a_post = post_form(TOKEN_URL, [
        ("client_id", CLIENT),
        ("client_secret", SECRET),
        ("grant_type", "client_credentials"),
        ("scope", "https://management.azure.com/.default"),
    ])
    a_extract = get_dict_value("access_token", a_post["WFWorkflowActionParameters"]["UUID"], "Contents of URL")
    return [a_post, a_extract], a_extract["WFWorkflowActionParameters"]["UUID"]

def build_status():
    actions, tok = build_token_chain()
    a_get = http_with_auth(f"{ARM_BASE}?api-version=2023-05-01", "GET", None, tok)
    get_uuid = a_get["WFWorkflowActionParameters"]["UUID"]
    a_props = get_dict_value("properties", get_uuid, "Contents of URL")
    a_iv = get_dict_value("instanceView", a_props["WFWorkflowActionParameters"]["UUID"])
    a_state = get_dict_value("state", a_iv["WFWorkflowActionParameters"]["UUID"])
    actions += [a_get, a_props, a_iv, a_state]
    last_uuid = a_state["WFWorkflowActionParameters"]["UUID"]
    actions.append({
        "WFWorkflowActionIdentifier": "is.workflow.actions.showresult",
        "WFWorkflowActionParameters": {
            "UUID": U(),
            "Text": {
                "Value": {
                    "string": f"OpenClaw: {OBJ}",
                    "attachmentsByRange": {"{10, 1}": attach(last_uuid, "Dictionary Value")},
                },
                "WFSerializationType": "WFTextTokenString",
            },
        },
    })
    return shortcut(actions, glyph=61713, color=2071128575)

def build_action(verb, glyph, color, msg):
    actions, tok = build_token_chain()
    actions += [
        http_with_auth(f"{ARM_BASE}/{verb}?api-version=2023-05-01", "POST", "JSON", tok, json_body=[]),
        notification(msg),
    ]
    return shortcut(actions, glyph=glyph, color=color)

def build_start():
    return build_action("start", glyph=61003, color=763359231, msg="🟢 Starting OpenClaw…")  # green play

def build_stop():
    return build_action("stop", glyph=61453, color=4292311295, msg="🛑 Stopping OpenClaw…")  # red stop

def write(path, wf):
    with open(path, "wb") as f:
        plistlib.dump(wf, f, fmt=plistlib.FMT_BINARY)

if __name__ == "__main__":
    out = os.path.expanduser("~/Downloads/openclaw-shortcuts")
    os.makedirs(out, exist_ok=True)
    files = [
        ("OpenClaw-Status", build_status()),
        ("OpenClaw-Start",  build_start()),
        ("OpenClaw-Stop",   build_stop()),
    ]
    import subprocess, shutil
    for name, wf in files:
        unsigned = f"{out}/{name}.shortcut"
        signed   = f"{out}/{name}-Signed.shortcut"
        write(unsigned, wf)
        # Sign with macOS `shortcuts` CLI. Stderr has objc runtime noise we ignore.
        result = subprocess.run(
            ["shortcuts", "sign",
             "--mode", "people-who-know-me",
             "--input", unsigned,
             "--output", signed],
            capture_output=True, text=True,
        )
        if result.returncode != 0 or not os.path.exists(signed):
            print(f"  {name}: SIGN FAILED — {result.stderr.strip()}", file=sys.stderr)
            sys.exit(1)
        # Replace the unsigned with the signed version (single canonical file per shortcut)
        shutil.move(signed, unsigned)
        print(f"  {name}.shortcut signed ({os.path.getsize(unsigned)} bytes)")
    print(f"\nAll three shortcuts signed and ready in {out}")
    print("Drag onto Shortcuts.app — iCloud will sync to iPhone within ~30 s.")

