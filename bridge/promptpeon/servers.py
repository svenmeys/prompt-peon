"""More than one T3 at once, such as the one on this machine and one somewhere else, seen as one.

T3 names threads and projects with its own random ids, so two servers never share one. Each call
goes to the server that listed the thread or project it names. Projects from every server after
the first carry that server's name, like "Shop (local)", so the game can tell them apart.
"""
from __future__ import annotations

import urllib.error

from . import settings, t3errors, t3remote, userconfig


class ServerDown(Exception):
    """This server didn't answer this round. Its threads keep what they last showed."""


class ServerSet:
    def __init__(self, servers: list[tuple[str, t3remote.T3Remote]]):
        self.servers = servers  # (name, remote). The first is the one the installer set up.
        # Over T3 Connect every ask is slower, so pacing and messages go by the slowest one.
        relayed = [remote for _, remote in servers if is_relayed(remote.url)]
        self.url = (relayed or [servers[0][1]])[0].url
        self.thread_owner: dict[str, t3remote.T3Remote] = {}
        self.project_owner: dict[str, t3remote.T3Remote] = {}
        self.last_shell: dict[str, dict] = {}
        self.down: dict[str, str] = {}
        self.trouble = ""

    def shell(self) -> dict:
        """Every server's threads and projects. One that doesn't answer keeps its last list,
        and `trouble` says so, so the game never reads its agents as gone or idle."""
        merged: dict = {"threads": [], "projects": []}
        failure = None
        answered = 0
        self.down = {}
        for index, (name, remote) in enumerate(self.servers):
            try:
                shell = t3errors.check_shell(remote.shell())
                self.last_shell[name] = shell
                answered += 1
            except urllib.error.HTTPError as error:
                if error.code in (401, 403):
                    self.down[name] = f"Your link to {called(name)} has expired. Run the installer again."
                else:
                    self.down[name] = f"{called(name).capitalize()} answered with an error ({error.code})."
                failure = failure or error
                shell = self.last_shell.get(name)
            except (OSError, urllib.error.URLError, ValueError, t3errors.T3Changed) as error:
                self.down[name] = unreachable(name, remote)
                failure = failure or error
                shell = self.last_shell.get(name)
            if not shell:
                continue
            if index == 0:
                merged.update({key: value for key, value in shell.items() if key not in ("threads", "projects")})
            for project in shell.get("projects") or []:
                self.project_owner[project.get("id")] = remote
                merged["projects"].append(project if index == 0 else dict(project, title=f"{project.get('title') or 'No project'} ({name})"))
            for thread in shell.get("threads") or []:
                self.thread_owner[thread.get("id")] = remote
                merged["threads"].append(thread)
        if not answered:
            raise failure
        self.trouble = " ".join(self.down.values())
        return merged

    def _thread(self, thread_id: str) -> t3remote.T3Remote:
        remote = self.thread_owner.get(thread_id)
        if remote is None:
            raise t3errors.SendRefused("that thread is not on any of your T3 servers")
        return remote

    def _project(self, project_id: str) -> t3remote.T3Remote:
        remote = self.project_owner.get(project_id)
        if remote is None:
            raise t3errors.SendRefused("that project is not on any of your T3 servers")
        return remote

    def detail(self, thread_id: str) -> dict:
        remote = self._thread(thread_id)
        name = next(name for name, server in self.servers if server is remote)
        if name in self.down:
            raise ServerDown(name)
        try:
            return remote.detail(thread_id)
        except (OSError, urllib.error.URLError) as error:
            if isinstance(error, urllib.error.HTTPError):
                raise
            # It went away between the list and this. Don't wait on it again this round.
            self.down[name] = unreachable(name, remote)
            self.trouble = " ".join(self.down.values())
            raise ServerDown(name) from error

    def server_config(self) -> dict:
        """Every model any of them offers. The server that starts a thread says no to one it lacks."""
        providers, seen = [], set()
        for _, remote in self.servers:
            try:
                config = remote.server_config()
            except (t3errors.SendRefused, t3errors.SendUncertain, OSError, ValueError, KeyError, AttributeError):
                continue
            for provider in config.get("providers") or []:
                key = provider.get("instanceId") or provider.get("id")
                if key not in seen:
                    seen.add(key)
                    providers.append(provider)
        return {"providers": providers}

    def send_reply(self, thread: dict, text: str, message_id: str | None = None) -> str:
        return self._thread(thread["id"]).send_reply(thread, text, message_id)

    def start_thread(self, project_id: str, model_selection: dict, text: str, runtime_mode: str) -> str:
        return self._project(project_id).start_thread(project_id, model_selection, text, runtime_mode)

    def pr_diff(self, project_id: str, link: dict):
        return self._project(project_id).pr_diff(project_id, link)

    def pr_checks(self, project_id: str, link: dict):
        return self._project(project_id).pr_checks(project_id, link)

    def pr_detail(self, project_id: str, link: dict):
        return self._project(project_id).pr_detail(project_id, link)

    def pr_activity(self, project_id: str, link: dict):
        return self._project(project_id).pr_activity(project_id, link)

    def __getattr__(self, name: str):
        """Everything else names its thread first: stop, settle, answer and the rest."""
        if name.startswith("_") or not callable(getattr(t3remote.T3Remote, name, None)):
            raise AttributeError(name)

        def by_thread(thread_id: str, *args, **kwargs):
            return getattr(self._thread(thread_id), name)(thread_id, *args, **kwargs)
        return by_thread


def called(name: str) -> str:
    return "T3" if name == "main" else f"the T3 called {name}"


def unreachable(name: str, remote: t3remote.T3Remote) -> str:
    return f"Can't reach {called(name)} at {remote.url}. Its threads are as we last saw them."


def is_relayed(url: str) -> bool:
    from urllib.parse import urlsplit
    host = urlsplit(url).hostname or ""
    return host == settings.RELAY_DOMAIN or host.endswith("." + settings.RELAY_DOMAIN)


def from_config(config: dict):
    """The T3 the installer set up, plus any others it added. One server stays a plain T3Remote."""
    main = t3remote.T3Remote(config["url"], userconfig.read_token())
    extra = [(entry["name"], t3remote.T3Remote(entry["url"], userconfig.read_extra_token(entry["name"])))
             for entry in config.get("also") or [] if entry.get("name") and entry.get("url")]
    if not extra:
        return main
    return ServerSet([("main", main)] + extra)
