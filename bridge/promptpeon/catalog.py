"""The models you can pick: T3's list as the game wants it, and checking a choice against it."""
from __future__ import annotations

import time

from . import console, gametext, settings, t3errors


def model_catalog(config: dict) -> list[dict]:
    """The models you can pick, from providers that are ready, with their effort levels."""
    providers = []
    for provider in config.get("providers") or []:
        if not provider.get("enabled") or provider.get("status") != "ready" or not provider.get("instanceId"):
            continue
        models = []
        for model in (provider.get("models") or [])[:settings.MAX_MODELS_PER_PROVIDER]:
            if not model.get("slug"):
                continue
            option_id, levels, labels, default = "", [], [], ""
            for descriptor in (model.get("capabilities") or {}).get("optionDescriptors") or []:
                if descriptor.get("id") in settings.EFFORT_OPTIONS and descriptor.get("type") == "select":
                    option_id = descriptor["id"]
                    for option in descriptor.get("options") or []:
                        if option.get("id"):
                            levels.append(str(option["id"]))
                            labels.append(gametext.readable(option.get("label") or option["id"], 20))
                            if option.get("isDefault"):
                                default = str(option["id"])
            models.append([str(model["slug"]), gametext.readable(model.get("name") or model["slug"], 40), option_id, levels, labels, default])
        if models:
            row = {"i": str(provider["instanceId"]), "n": gametext.readable(provider.get("displayName") or provider["instanceId"], 30), "m": models}
            # T3 quietly runs a mode a provider doesn't have as approval-required, so the game has to know. No list means all.
            modes = [mode for mode in settings.RUNTIME_MODES if mode in (provider.get("supportedRuntimeModes") or [])]
            if modes:
                row["rm"] = modes
            providers.append(row)
    return providers


def refresh_catalog(bridge) -> None:
    now = time.monotonic()
    if bridge.catalog_at and now - bridge.catalog_at < settings.CATALOG_SECONDS:
        return
    bridge.catalog_at = now
    try:
        bridge.catalog = model_catalog(bridge.remote.server_config())
    except (t3errors.SendRefused, t3errors.SendUncertain, OSError, ValueError, KeyError, AttributeError) as error:
        console.log(f"no model list from T3: {error}")


def model_selection(bridge, instance: str, model: str, effort: str, current: dict | None = None) -> dict:
    """What T3 wants, checked against what it offers. Other options on the thread stay as they are."""
    if bridge.catalog is None:
        bridge.catalog_at = 0.0
        refresh_catalog(bridge)
    provider = next((row for row in bridge.catalog or [] if row["i"] == instance), None)
    found = next((row for row in (provider or {}).get("m", []) if row[0] == model), None)
    if found is None:
        raise ValueError(f"T3 doesn't offer {model} right now")
    if effort and effort not in found[3]:
        raise ValueError(f"{model} doesn't have that effort level")
    options = [option for option in (current or {}).get("options") or []
               if (current or {}).get("instanceId") == instance and option.get("id") not in settings.EFFORT_OPTIONS]
    if effort:
        options.append({"id": found[2], "value": effort})
    selection = {"instanceId": instance, "model": model}
    if options:
        selection["options"] = options
    return selection
