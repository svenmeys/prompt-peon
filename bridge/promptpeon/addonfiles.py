"""The addon in the game folder: installing it and its helpers, and checking they are still what we made."""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

from . import console, pngtga, safefiles, savedvars, settings


def link_to_snapshot(data: Path, snapshot: Path, hard_links: bool = settings.IS_WINDOWS) -> None:
    """Make a slot's Data.lua the one snapshot file.

    Symlinks need admin rights or Developer Mode on Windows, and hard links need neither.
    The bridge then has to overwrite the snapshot in place, which it does on Windows.
    """
    if data.is_symlink() or data.exists():
        data.unlink()
    if hard_links:
        os.link(snapshot, data)
    else:
        data.symlink_to(f"../{settings.ADDON}/Snapshot.lua")


def client_interface(wow_dir: Path) -> str:
    """Version 1.60.1 is interface 16001. Read from the client, because a patch changes it."""
    try:
        rows = [line.split("|") for line in (wow_dir.parent / ".build.info").read_text().splitlines() if line.strip()]
        names = [cell.split("!")[0] for cell in rows[0]]
        for cells in rows[1:]:
            row = dict(zip(names, cells))
            if row.get("Product") == settings.BUILD_PRODUCTS[wow_dir.name]:
                major, minor, patch = row["Version"].split(".")[:3]
                return str(int(major) * 10000 + int(minor) * 100 + int(patch))
    except (OSError, ValueError, KeyError, IndexError):
        pass
    return settings.CLIENTS[wow_dir.name][0]


def keep_addon_current(wow_dir: Path) -> None:
    """After a game patch, update what our addon files declare, so the game keeps loading them."""
    wanted = f"## Interface: {client_interface(wow_dir)}"
    addons = wow_dir / "Interface/AddOns"
    try:
        if wanted in (addons / settings.ADDON / f"{settings.ADDON}.toc").read_text():
            return
        for name in OUR_ADDONS:  # Exactly ours. A lookalike doesn't get kept alive through a patch.
            toc = addons / name / f"{name}.toc"
            if toc.is_file() and not safefiles.is_link(toc):
                safefiles.write_atomic(toc, re.sub(r"^## Interface: .*$", wanted, toc.read_text(), flags=re.M))
        console.log(f"the game was patched, addon files now say {wanted}")
    except OSError as error:
        console.log(f"could not update the addon after a game patch: {error}")


# Exactly what the installer makes. A pattern would let "PromptPeonIn9999" past as one of ours.
OUR_ADDONS = {settings.ADDON, *(f"{settings.ADDON}In{number:03d}" for number in range(1, settings.SLOT_COUNT + 1)),
              *(f"{settings.ADDON}Out{number:02d}" for number in range(1, settings.OUT_COUNT + 1))}
ADDON_CODE = {
    "Snapshot.lua", "Core.lua", "CoreMarkdown.lua", "CoreIngest.lua", "CoreNotice.lua", "CoreRefresh.lua", "CoreEncode.lua", "CoreSend.lua", "CoreStartup.lua",
    "Chat.lua", "UI.lua", "UITracker.lua", "UIMenus.lua", "UIControls.lua", "UIOptions.lua", "UIParty.lua", "UILayout.lua", "UIFrame.lua", "UIList.lua",
    "UIDetail.lua", "UICanvas.lua", "UIChanges.lua", "UIPages.lua", "UIPullRequests.lua", "UIMessages.lua", "UIReply.lua", "UIRender.lua",
    "Game.lua", "GameAway.lua", "GameLoot.lua", "GameAchievements.lua", "GameSpells.lua",
}
ADDON_FILES = ADDON_CODE | {"Bindings.xml", f"{settings.ADDON}.toc"}


def toc_loads(toc: Path) -> set[str]:
    """The files a .toc tells the game to run."""
    lines = (line.strip() for line in toc.read_text(encoding="utf-8", errors="replace").splitlines())
    return {line for line in lines if line and not line.startswith("#")}


def tampered_addons(wow_dir: Path, copy: Path | None = None) -> list[str]:
    """Our helpers are trusted by name, so check they are still what the installer made. Anything
    extra in one would run as us. `copy` is our own copy of the addon, to compare the code with."""
    addons = wow_dir / "Interface/AddOns"
    bad = []
    snapshot = addons / settings.ADDON / "Snapshot.lua"
    for name in sorted(OUR_ADDONS - {settings.ADDON}):
        slot = addons / name
        if not slot.exists() and not slot.is_symlink():
            continue
        toc = slot / f"{name}.toc"
        takes_data = "Out" not in name[len(settings.ADDON):]
        expected = {toc.name, "Data.lua"} if takes_data else {toc.name}
        if safefiles.is_link(slot) or {path.name for path in slot.iterdir()} - expected:
            bad.append(name)
            continue
        if toc.exists() and toc_loads(toc) - ({"Data.lua"} if takes_data else set()):
            bad.append(name)
            continue
        data = slot / "Data.lua"
        if takes_data and (data.exists() or data.is_symlink()):
            aimed = os.readlink(data).replace("\\", "/") if data.is_symlink() else None
            if aimed != f"../{settings.ADDON}/Snapshot.lua" and not (aimed is None and snapshot.exists() and data.samefile(snapshot)):
                bad.append(name)
    main = addons / settings.ADDON
    if safefiles.is_link(main):
        bad.append(settings.ADDON)
    elif main.is_dir():
        code = {path.name for path in main.iterdir() if path.suffix.lower() in (".lua", ".xml", ".toc")}
        toc = main / f"{settings.ADDON}.toc"
        changed = bool(code - ADDON_FILES) or (toc.exists() and bool(toc_loads(toc) - ADDON_CODE))
        for file_name in sorted(ADDON_FILES - {"Snapshot.lua", f"{settings.ADDON}.toc"}) if copy and copy.is_dir() else []:
            ours, there = copy / file_name, main / file_name
            if ours.is_file() and there.is_file() and ours.read_bytes() != there.read_bytes():
                changed = True
        if changed:
            bad.append(settings.ADDON)
    return bad


def other_addons_in(wow_dir: Path, trusted: list[str]) -> list[str]:
    """Every installed addon but ours and the ones you trust, by exact name. Raises if it can't look."""
    folder = wow_dir / "Interface/AddOns"
    try:
        names = [path.name for path in folder.iterdir() if path.is_dir()]
    except FileNotFoundError:
        return []
    # No exception for "Blizzard_": the game's own addons aren't in this folder, so one there is somebody's.
    return sorted(name for name in names if name not in OUR_ADDONS and name not in trusted)


def clear_game_folder(wow_dir: Path) -> None:
    """Thread text and pictures from a client you moved away from shouldn't stay in its folder."""
    target = wow_dir / "Interface/AddOns" / settings.ADDON
    snapshot = target / "Snapshot.lua"
    if not target.is_dir():
        return
    blank = "-- Written by the Prompt Peon bridge. Data only.\n"
    if snapshot.is_file() and settings.IS_WINDOWS:
        safefiles.write_in_place(snapshot, blank)
    elif snapshot.is_file():
        safefiles.write_atomic(snapshot, blank)
    for picture in (target / "previews").glob("p*.tga"):
        safefiles.write_binary_atomic(picture, pngtga.blank_tga())
    for saved in (wow_dir / "WTF/Account").glob(f"*/SavedVariables/{settings.ADDON}.lua*"):
        savedvars.clear_typed_words(saved)


def install_addon(wow_dir: Path, source: Path, hard_links: bool = settings.IS_WINDOWS) -> int:
    """Copy the addon and create its refresh slots. Each slot's Data.lua points at one snapshot."""
    interface = client_interface(wow_dir)
    addons = wow_dir / "Interface/AddOns"
    addons.mkdir(parents=True, exist_ok=True)
    target = addons / settings.ADDON
    safefiles.own_folder(target)
    shipped = {"previews", "Snapshot.lua"}
    for path in source.iterdir():
        if path.is_file() and path.name != "Snapshot.lua":
            safefiles.write_binary_atomic(target / path.name, path.read_bytes())
            shipped.add(path.name)
    # Whatever else is in there would run as us. It came from somewhere else.
    for path in target.iterdir():
        if path.name not in shipped:
            safefiles.remove_path(path)
    previews = target / "previews"
    safefiles.own_folder(previews)
    for number in range(1, settings.PREVIEW_FILES + 1):
        picture = previews / f"p{number:02d}.tga"
        if not picture.is_file() or safefiles.is_link(picture):
            safefiles.write_binary_atomic(picture, pngtga.blank_tga())
    toc = target / f"{settings.ADDON}.toc"
    safefiles.write_atomic(toc, re.sub(r"^## Interface: .*$", f"## Interface: {interface}", toc.read_text(), flags=re.M))
    # Always a new file. An old one could be hard linked to anything, and Windows writes through it.
    # Every helper gets linked to this one just below, and the companion app fills it in.
    snapshot = target / "Snapshot.lua"
    safefiles.write_binary_atomic(snapshot, (source / "Snapshot.lua").read_bytes())
    # All of them hang under one parent in one category, so the addon list can collapse them.
    parent = f"{settings.ADDON}In001"

    def write_toc(slot: Path, name: str, title: str, notes: str, data: bool) -> None:
        safefiles.own_folder(slot)
        for path in slot.iterdir():
            if path.name != f"{name}.toc" and not (data and path.name == "Data.lua"):
                safefiles.remove_path(path)
        category = f"## Category: {settings.INTERNALS}\n" if name == parent else ""
        safefiles.write_atomic(slot / f"{name}.toc",
                     f"## Interface: {interface}\n## Title: {title}\n## Notes: {notes}\n"
                     f"## IconTexture: Interface\\QuestFrame\\UI-QuestLog-BookIcon\n"
                     f"## LoadOnDemand: 1\n## Group: {parent}\n{category}" + ("Data.lua\n" if data else ""))

    for number in range(1, settings.SLOT_COUNT + 1):
        name = f"{settings.ADDON}In{number:03d}"
        slot = addons / name
        write_toc(slot, name, f"T3 refresh {number:03d}", "Lets Prompt Peon refresh without a reload. Leave enabled.", True)
        link_to_snapshot(slot / "Data.lua", snapshot, hard_links)
    for number in range(1, settings.OUT_COUNT + 1):
        name = f"{settings.ADDON}Out{number:02d}"
        write_toc(addons / name, name, f"T3 send {number:02d}", "Lets Prompt Peon send replies without a reload. Leave as it is.", False)
    return settings.SLOT_COUNT + settings.OUT_COUNT


def remove_from_client(wow_dir: Path) -> tuple[int, list[str]]:
    """Take Prompt Peon and what the game saved for it out of one client, and nobody else's addons.
    Says how many addons went, and what it couldn't remove."""
    removed, left = 0, []
    for path in [*(wow_dir / "Interface/AddOns").glob(f"{settings.ADDON}*"), *(wow_dir / "WTF/Account").glob(f"*/SavedVariables/{settings.ADDON}.lua*")]:
        is_addon = path.parent.name == "AddOns"
        if is_addon and path.name not in OUR_ADDONS:
            continue
        try:
            safefiles.remove_path(path)
            removed += is_addon
        except OSError:
            left.append(str(path))
    return removed, left


def place_addon(wow_dir: Path, source: Path) -> int:
    """Put the addon in the game, or say in plain words why it can't go there."""
    try:
        return install_addon(wow_dir, source)
    except PermissionError:
        sys.exit("Windows would not let us change the addon files. Close WoW and run this again.")
    except OSError as error:
        hint = " The drive WoW is on may not support hard links: FAT32 and exFAT drives don't. WoW has to be on an NTFS drive." if settings.IS_WINDOWS else ""
        sys.exit(f"Could not set up the addon files: {error}.{hint}")
