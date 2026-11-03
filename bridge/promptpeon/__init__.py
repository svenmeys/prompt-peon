"""Prompt Peon's companion app, split by what each part does.

promptpeon_bridge.py, one folder up, is what starts it, and everything here is imported at startup.
So a copy that's already running can't end up mixing two versions after an install replaces these files.

Modules import each other as modules, and call `safefiles.write_atomic(...)` rather than importing the
name. That leaves one copy of each name, so patching it in a test reaches everything that uses it.
"""
