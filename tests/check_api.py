"""Every template, font and global the addon names must exist in Blizzard's UI source.

Usage: python3 tests/check_api.py <path to a wow-ui-source checkout on the matching branch>
This catches the client errors a stub can't: a misspelled template or a global that
a client doesn't have. It can't prove the window looks right. Only the game can.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "addon" / "PromptPeon"
UI = Path(sys.argv[1]) / "Interface" / "AddOns"
toc = (ROOT / "PromptPeon.toc").read_text()
# Everything the game loads, except the bridge's data file.
loaded = re.findall(r"^(\w+\.lua)\s*$", toc, re.M)
code = "".join((ROOT / name).read_text() for name in loaded if name != "Snapshot.lua")
# Comments must not count as use.
code = re.sub(r"--[^\n]*", "", code)
xml = "\n".join(p.read_text(errors="ignore") for p in UI.rglob("*.xml"))
lua = "\n".join(p.read_text(errors="ignore") for p in UI.rglob("*.lua"))
missing = []

templates = set(re.findall(r'CreateFrame\("[A-Za-z]+",\s*(?:"[^"]*"|nil),\s*[a-zA-Z.]+,\s*"([A-Za-z]+)"\)', code))
fonts = set(re.findall(r'"(Game[A-Za-z]*Font[A-Za-z]*|GameFont[A-Za-z]*)"', code))
for name in sorted(templates | fonts):
    found = f'name="{name}"' in xml
    print(f"{'ok  ' if found else 'MISS'} {name}")
    if not found:
        missing.append(name)

docs = "\n".join(p.read_text(errors="ignore") for p in (UI / "Blizzard_APIDocumentationGenerated").glob("*.lua"))
for name, where in [("LoadAddOn", docs), ("NewTicker", lua), ("ReloadUI", lua), ("UISpecialFrames", lua),
                    ("UIErrorsFrame", lua + xml), ("IG_QUEST_LOG_OPEN", lua), ("SetResizeBounds", lua + docs),
                    ("InCombatLockdown", lua + docs), ("SetHyperlinksEnabled", lua + docs), ("IsShiftKeyDown", lua + docs), ("SetMaxLines", lua + docs),
                    ("SaveAddOns", docs), ("EnableAddOn", docs), ("DisableAddOn", docs), ("DoesAddOnExist", docs),
                    ("scrollBarHideable", lua), ("ScrollFrame_OnScrollRangeChanged", lua), ("LinkTypes.AddOn", lua),
                    ('TriggerEvent("SetItemRef"', lua), ("SetObeyStepOnDrag", lua + docs),
                    ("debugprofilestop", lua + docs), ("StaticPopup_Show", lua), ("StaticPopupDialogs", lua), ("UI-PlusButton-Up", lua + xml), ("UI-MinusButton-Up", lua + xml), ("IsInInstance", lua + docs), ("GetInstanceInfo", lua + docs), ("PLAYER_ENTERING_WORLD", lua + docs), ("PLAYER_LOGOUT", lua + docs), ("TUTORIAL_POPUP", lua), ("UI_EPICLOOT_TOAST", lua), ("LOOT_WINDOW_COIN_SOUND", lua), ("READY_CHECK", lua), ("UI-TargetingFrame-Skull", lua + xml), ("ButtonHilight-Square", lua + xml), ("UI-StatusBar", lua + xml), ("SetTexCoord", lua + docs), ("GEAR_64GREY", lua + xml), ("IsMouseButtonDown", lua + docs), ("ActiveQuestIcon", lua + xml), ("UI-CheckBox-Check", lua + xml), ("UI-GroupLoot-Pass-Up", lua + xml), ("UI-SpellbookIcon-NextPage-Up", lua + xml), ("SetObeyStepOnDrag", lua + docs), ("SetChecked", lua + docs), ("GetChecked", lua + docs), ("SetDesaturated", lua + docs), ("SetStatusBarColor", lua + docs), ("GetCursorPosition", lua + docs), ("SetColorTexture", lua + docs), ("SetNormalFontObject", lua + docs), ("SetPortraitTextureFromCreatureDisplayID", lua + docs), ("UI-PartyFrame", lua + xml), ("UI-Debuff-Overlays", lua + xml), ("SetColorTexture", lua + docs), ("GLOBAL_MOUSE_DOWN", lua + docs), ("RaidNotice_AddMessage", lua), ("RaidBossEmoteFrame", lua + xml),
                    ("IG_QUEST_LIST_COMPLETE", lua), ("IG_QUEST_LOG_ABANDON_QUEST", lua), ("ChatTypeInfo", lua), ("PlayerFrame", lua + xml),
                    ("IsInGroup", lua + docs), ("RegisterForClicks", lua + docs), ("SetStatusBarColor", lua + docs),
                    ("GameTooltip", lua + xml), ("UI-StatusBar", lua + xml), ("INV_Misc_QuestionMark", lua + xml), ("CreateFont", lua + docs), ("CopyFontObject", lua + docs), ("SetToplevel", lua + docs), ("IsMouseOver", lua + docs), ("SetHyperlinksEnabled", lua + docs)]:
    found = name in where
    print(f"{'ok  ' if found else 'MISS'} {name}")
    if not found:
        missing.append(name)

print(f"TOC interface: {re.search(r'## Interface: (.+)', toc).group(1)}")
print(f"{len(missing)} missing" + (f": {missing}" if missing else ""))
sys.exit(1 if missing else 0)
