# The companion app

The small program that runs next to WoW and talks to T3 for the addon. This page lists everything it does and touches, so you can decide whether to trust it. The code and its logs call it the bridge. It starts from [`bridge/promptpeon_bridge.py`](../bridge/promptpeon_bridge.py), and the rest is in [`bridge/promptpeon/`](../bridge/promptpeon).

## In short

- It's Python 3.14 or newer, standard library only, with nothing else to install.
- It talks to the T3 address you gave it, plus the T3 on this machine if you said yes to showing both, and to GitHub for one thing: while the game is open, it asks every 30 minutes whether a newer release exists, so the game can tell you. Nothing of yours goes with that, and it never downloads anything. Updating is still you running the installer. To stop that question, add `"update_check": false` to `config.json`. There's no telemetry and no other server. It ignores proxy settings and refuses redirects, so your token can't be sent somewhere else.
- It only talks to T3 and GitHub while WoW is running.
- When the game closes, it clears your thread text, drafts and unsent messages from the game folder. If T3 can't be reached, an unsent message gets two minutes to go first, and the next session tells you if it was lost.
- While an addon you haven't trusted is installed, no thread text goes in the game folder at all.
- You can remove all of it with one command.

## When it runs

| | Windows | Linux, SteamOS |
| --- | --- | --- |
| Starts | At login, from the `PromptPeon` value in `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` | At login, as the systemd user service `prompt-peon` |
| Python | Runs in isolated mode (`-I`), so settings like `PYTHONPATH` can't change what it loads | The same |
| Runs as | `pythonw`, so no window | `python3`, restarted if it stops |
| Needs admin | No | No |

It's always running but idle until it sees the game, in any client it was installed into. It serves one game at a time, so if two are open, the second waits until the first closes. It looks every 5 seconds. While the game runs, it asks T3 for changes every 5 seconds, or every 15 over T3 Connect, and looks 50 times a second at whether the file your replies travel in has changed, reading it only when it has. Only one copy can run at a time.

macOS isn't supported.

## What it touches

| Where | What | Sensitive? |
| --- | --- | --- |
| Config folder: `%APPDATA%\prompt-peon` or `~/.config/prompt-peon` | `token`, your access to T3, and `token-local` for the T3 on this machine if you show both. Owner-only on Linux. `config.json`: T3's address, the WoW folder, the addons you trust, whether pictures are on, whether yolo mode is on, and when a token from this machine's T3 was last renewed | **Yes.** Don't share this folder |
| State folder: `%LOCALAPPDATA%\prompt-peon` or `~/.local/state/prompt-peon` | `state.json`: what's been sent and what you hid. `sent.log`: time, thread id, length and whether each send worked, never the words. It rolls over at 1 MB. `previews.json`, a lock file and a process id | Thread ids, project names you hid, picture paths and checksums of what you sent. Not your words |
| Program folder: `%LOCALAPPDATA%\prompt-peon` or `~/.local/share/prompt-peon` | A copy of the companion app and the setup and removal scripts, so you can delete the download | No |
| `Interface/AddOns/PromptPeon*` in the WoW folder | The addon, 1,096 helper addons, 64 picture files and 9 silent sound files | `Snapshot.lua` holds thread text while the game runs, and any addon can read it |
| `WTF/Account/*/SavedVariables/PromptPeon.lua` and its `.bak` | Read, as the fallback way to get replies out. Once the game has closed and any last reply has gone, it removes drafts and unsent messages and leaves the rest alone. The game writes it | **Yes,** while the game is open. It can hold drafts and unsent messages |
| `AddOns.txt` under `WTF/Account` | Read, to get replies out. The game writes it | Only what's being sent right now |

It doesn't read anything else in your WoW folder, except the list of addon folders, its own addon files to check nothing changed them, and `.build.info` to learn the game version. Outside these places it looks at the process list, to see whether the game is running. During setup it also looks for WoW and may run the `t3` program on this machine to get a token. If it got one that way, it runs `t3` again about every three weeks to renew it, with the same access and nothing more.

## What it sends, and to whom

Except for that question to GitHub, all of it goes to the T3 address you gave it, with your token. Over an `https://` address or an SSH tunnel it's encrypted. Over plain `http://` on a network it isn't, and the installer asks before accepting that.

| When | What it asks T3 | Why |
| --- | --- | --- |
| Every 5 seconds, or 15 over T3 Connect | The thread list, and the messages of threads that changed | The log |
| Every 10 minutes | The list of models | The model picker |
| When you open something | A diff, a subagent's report, older messages, a settled thread, a pull request's description, checks, comments and commits | Reading |
| For recent threads with a picture, if you turned pictures on. This happens by itself, not only when you open one | The picture file | Previews |
| When you send | Your reply or command | Doing what you asked |

The token can do what the pairing link allowed: `orchestration:read` and `orchestration:operate`, plus `filesystem:read` if you said yes to pictures. If you said no, it never asks for that permission.

## What it will and won't do when the game asks

The game can ask for the actions listed in [ARCHITECTURE.md](ARCHITECTURE.md#commands). The companion app treats those requests as untrusted, because any addon could write them.

| Rail | What it does |
| --- | --- |
| Other addons | Keeps thread text out of the game and refuses every send while an addon you haven't trusted is installed. Names and status still go. Hiding more still works, and showing again doesn't |
| Our own folders | Only the exact names the installer made count as ours. If anything extra is in one of them, thread text and sending stop until the installer repairs it |
| Full access | Refuses replies, steering, edits and model changes to agents that can act without asking, and starting new ones, unless you explicitly said yes. An agent mode it doesn't recognize counts as full access. Stop and settle aren't affected by this setting, but other addons and the rate limit still apply |
| Rate limits | 10 replies or changing commands a minute, and 60 reads a minute |
| Size | 4,000 bytes per reply |
| New threads | Start in the mode the game asks for. `approval-required` and `auto-accept-edits` always work. `auto` and `full-access` need the yes above. Any other mode starts nothing |
| Once only | Each message has a number and only runs once, even after a crash |
| Hidden threads | Their words never go to the game, and it refuses to fetch them |
| Secrets | Files like `.env` and `*.pem` stay out of diffs, and text that looks like a key is replaced before it reaches the game. This is a safety net, not a guarantee |
| Text as data | Everything from T3 is written as quoted Lua strings, so a message can't become code |
| Pictures | Off unless you say yes. Size and pixel limits, and a check against files that decompress to far more than they claim |
| What T3 sends | Limits on the size of every answer, including compressed ones, and on how long its body takes, so a broken server can't fill memory |
| Writing files | Replaces links instead of following them, in the game folder, the program's own copy and the token. Temporary files have random names. The Windows helpers' hard links to the snapshot are by design, and each install makes a new snapshot file |
| A closed game | Stays cleared, including pictures that were on their way. A last reply delivered after you quit still goes, without bringing any words back |
| A removed addon | Stays removed. It won't recreate the folder |

It never runs a command on your machine because of something in the game, and it has no way to do so. What agents do on the T3 machine is T3's business, under T3's permissions.

## When T3 updates

T3's remote API isn't public, so an update can change it. If T3 answers in a way the companion app doesn't know, it doesn't crash or show an empty list. The game shows a plain notice, the threads you had stay on screen, and it recovers by itself if the answer goes back to normal. A send that fails this way gives your words back. If T3 answered in nonsense after it got the message, it may already have acted, so the game says "unknown" and asks you to check T3.

## Running it by hand

The installer copies the app to the program folder above. From there:

    python3 promptpeon_bridge.py status      # check the connection to T3
    python3 promptpeon_bridge.py once        # refresh once and print what happened
    python3 promptpeon_bridge.py run         # run in the foreground
    python3 promptpeon_bridge.py start-stop  # turn it off if it's running, and on if it isn't
    python3 promptpeon_bridge.py trust MyAddon  # trust an addon by its folder name, no restart needed
    python3 promptpeon_bridge.py yolo on     # let the game approve what agents ask to do; yolo off takes it back
    python3 promptpeon_bridge.py uninstall   # remove everything

The installer takes `--client era|retail|forever`, `--wow-dir`, `--link`, `--url`, `--pictures`, `--no-pictures`, `--full-access`, `--no-full-access`, `--no-start`, `--allow-unencrypted` and `--no-update`.

Logs: `journalctl --user -u prompt-peon` on Linux, and `bridge.log` in the state folder on Windows. They hold errors and results, and can name a file or thread id. Thread text stays out.

## Turning it off

Double-click `start-stop.cmd` on Windows, or run `sh start-stop.sh` on Linux. It's next to the installer in the folder you downloaded, and in the program folder too. It turns the companion app off if it's running and on if it isn't, and says which. Off stays off after a reboot until you run it again.

With it off, the game says the companion app has gone quiet, and replies wait until it's back.

## Removing it

Close WoW, then run `uninstall.cmd` from the program folder on Windows, or `sh uninstall.sh` from it on Linux. That stops the companion app, even one you started by hand, and removes the addon and helpers from every client it went into, its start-at-login entry, your token and all saved data. It refuses while WoW is running, because the game would save its data again on exit, and it names anything it couldn't remove. Then revoke Prompt Peon in T3 under Settings, Sharing & access, because deleting files doesn't cancel the access T3 gave.
