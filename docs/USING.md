# Using Prompt Peon

Everything the [README](../README.md) keeps short: what each part does, how refreshes work, what to do when something goes wrong, and what to know about privacy. `/t3` works everywhere `/peon` does.

## What you get

**A quest log that works like an inbox.** `/peon` opens a two-pane window. The list is sorted by what a thread wants from you, in four groups: **Needs you** holds the ones waiting on an answer or an approval and the ones that failed, **Unread** holds finished work you haven't read, **Working** holds the agents that are busy, and **Quiet** holds the rest. A thread moves between them by itself. Working and Quiet fold away if you click their heading. There are no project headings: each line starts with two letters for its project, in that project's colour, and the tooltip has the full name. Each thread has a mark on the right, in the game's own icons:

| Mark | Meaning |
| --- | --- |
| Gold check | Done. Fades once you've read it |
| Yellow `?` | Asking you a question or for a permission |
| Red X | Failed. Fades once you've read it |
| Activity icon | Working: an eye for thinking, a gear for running a command, and so on |
| Sleep icon and a time | Snoozed until then |
| Spyglass | Pinned to your tracker by you |

**The whole thread.** Messages in full, tool steps, todo lists, open questions and pictures an agent looked at. Thinking stays folded until you click it. "Show older messages" fetches the rest when you ask. A table too wide for the window is squeezed to fit, with **Expand table** under it: expanded, every column gets the room it needs and the table scrolls sideways (drag the bar, or hold Shift and scroll). It stays expanded until you collapse it. A link to another thread shows that thread's name, and clicking it opens the thread here, delegated ones too.

**Real controls.** The open thread has a row of small icons beside its name, with a tooltip on each: Hide, Snooze, Track and Stop. Turn in takes Stop's place once the agent has finished. Model and effort sit beside the reply box.

Tabs hang off the right side of the log, like the spellbook's. The top three are pages: What happened, Achievements and Options. Under them, the open thread gets its own: Changes, Pull requests and Agents, each with a count, and only the ones that thread has. The tabs never move, whatever page is open, and the pressed one is where you are. There's no Back button: click the pressed tab again, click another tab, or click the thread's name in the list to see what it said.

- **Reply** from the box under the open thread.
- **Steer, edit or cancel** a message that's still queued.
- **Changes:** what a thread changed, file by file, in a colored diff.
- **Agents:** the subagents a thread sent out, what they were asked and what they came back with.
- **Pull requests:** every PR linked to a thread, with its state, CI, review and line counts. Click one to read its summary, checks, its own changed files, discussion and timeline. Bot comments stay folded until you ask. Reading only: you reply on GitHub.
- **Snooze** a thread until later, and **turn in** a finished one. Both move to a group at the bottom of the list. Turn in asks first. Nothing in the game tells an agent to push.

![The snooze menu: For 1 hour, For 4 hours, Until tomorrow morning, Until Monday morning.](images/snooze.png)

![A popup: Turn in Move payments to the new API? It's marked finished and leaves your list. You can reopen it from Settled. Buttons: Turn in, Not yet.](images/turn-in.png)

**A tracker, and a party if you want one.** The tracker shows who needs you and plays a sound when a thread starts waiting on you. Turn on **Party frames** in Options and a worker stands in for each agent that is working, waiting on you or finished and not yet read: a peon for the Horde, a human peasant for the Alliance, the undead for the Forsaken, or whichever you pick in Options. Its level is how many turns it has finished, on a rising curve (turn 100 is level 10). Turn on **Elite frames** in Options and level 5 earns a silver dragon, level 10 a gold one. Health is how this turn is going: each failed step costs some, and a failed run kills it. Mana is its context left.

![Five peon party frames with health and mana bars. Two wear silver or gold dragons for their level, one is low on mana and marked OOM, and one is grey with a red mark because its agent failed.](images/party.jpg)

![The tracker as it looked in 0.32, saying Peons: 1 failed, 2 working above five threads. Since 0.38 it lists only threads that want something from you.](images/tracker.jpg)

**The fun part.** Each of these tells you something true about the work:

- The peon talks: "Work, work" when an agent starts, "More work?" when it takes the next queued message, "Work complete!" when it finishes. Click it too many times and it gets annoyed.
- Finished work drops loot, sized by the change. Click it to open the thread.
- Failed agents die. You can resurrect them, or release their spirit. Keep trying and it counts your corpse runs.
- An agent nearly out of context says "I need more mana", with the game's red error. Evocation compacts it.
- Spells send a useful prompt, like Holy Light (prove it works), Dispel Magic (stop going in circles) or Polymorph (simplify). They're real orders to a real agent, so each one shows you its exact words and asks first. Options can turn that question off.
- While CI is failing on a thread's open PR, Sunder the Build joins the spell bar. It tells the agent to read the real logs and fix the cause.

![The spell bar along the bottom of the log, with the pointer on Polymorph. Its tooltip says: Instant cast. Sends the open thread: Look at what you added. Remove anything the goal doesn't need and simplify what's left, without changing behavior.](images/spell-bar.png)
- Come out of a dungeon, log back in or reopen the log after a while, and it tells you what your agents did. The letter tab on the right side of the log brings that report back, and lights up when there's a new one.
- There are achievements, behind the seal icon beside it.

## Tracking and hiding

`/peon` opens or closes the log, and so does `/t3`. So does the book button on the edge of the minimap, which shows how many threads are waiting on you: drag it round the edge, right-click it for Options, or hide it there. On retail and WoW Forever, Prompt Peon is also in the game's addon list button by the minimap. Everything else has a button. The game's Key Bindings screen has three keys under Prompt Peon, all unset until you pick them: open or close the log, open the next thread waiting on you, and type a reply to the open thread.

The tracker is an inbox too. Its top line counts who needs you, who failed and who is working. Under it are only the threads that want something from you: the ones waiting on you first, then finished work you haven't read. A thread that is just working stays in the count. When nobody is waiting, nothing is unread and nobody is working, the tracker goes away, and comes back by itself. Read a finished thread in the log and it leaves the tracker. To keep a thread there whatever it's doing, pin it: the Track icon beside its name, or shift-click it. Options can hide the tracker, and alerts still come. The search box above the list narrows it to the threads whose name, or whose project's name, has what you type, snoozed, settled and hidden ones included. In the log, shift-click a thread to pin it, and right-click a thread for its options, which include starting a new thread in its project and hiding the whole project. Hide what you don't want on screen: hidden things move to a Hidden section at the bottom, and leave the tracker, party frames, counts and alerts. To bring something back, open Hidden and press the eye beside it.

## Reloads, and how fresh it is

The game can only read new data a limited number of times, so live updates run out after a while. A reload resets that. It reloads your whole UI, not just this addon, takes a few seconds, and you lose nothing. It never happens by itself. The bottom of the log, beside Send, always shows roughly how long is left. With 30 minutes to go, a Reload UI button appears. With 10 minutes to go, chat tells you too.

**Fast updates** are on top of that pace. When a thread changes state or starts waiting on you, the companion app rings a silent bell the game listens for, and the game refreshes within a second or two. Each time it does, it uses one of the live updates in the table below, so the times there are a little shorter on a busy day. It can't run away with them: at most 20 in ten minutes. It needs game sound on: the bell is a sound file, though you never hear it. With sound off, or with Fast updates unticked in Options, updates come at the pace below. Check the connection says which it is.

You choose the pace in Options, under Updates, from 10 to 60 seconds. Faster means reloading more often. Opening diffs and sending messages use some updates too, so these times are the most you'd get:

| Refresh every | Log open | Log closed, agents working |
| --- | --- | --- |
| 20 seconds (default) | About 5.5 hours | About 8 hours |
| 10 seconds | About 2.8 hours | About 4 hours |

With the log closed and nothing happening, it refreshes every 90 seconds, which lasts about a day. The game pauses updates during combat.

## When something goes wrong

Start with **Check the connection** at the bottom of Options. It tests each link in turn and says in chat which one is broken: the companion app, T3, live updates, and sending, which it tries for real by asking the companion app to answer. That question reaches no agent and changes nothing.

| What you see | What it means | What to do |
| --- | --- | --- |
| No data from the companion app yet, or it has gone quiet | The game can't see the companion app | Close the game, run the installer again, start the game |
| Can't reach T3 at ... | The T3 machine is asleep, or not reachable from here | Wake it, or check its network. It reconnects by itself |
| Your link to T3 has expired | Links from another machine last 30 days | Make a new link in T3 and run the installer again |
| T3 answered in a way this version doesn't understand | T3 probably updated | Get the newest Prompt Peon and run the installer again |
| It says an addon isn't trusted yet, and thread text is missing | An addon you haven't trusted appeared. Names, status, the tracker and the party keep working | If you trust it, run the command the notice names, or close WoW, run the installer again and say yes. Or remove that addon |
| Something "has been changed, so it could be something else now" | One of Prompt Peon's own folders has something in it that the installer didn't put there | Run the installer again. It repairs it |
| This agent has full access, and sending to those from the game is off | That's the safe default | Reply from T3, or run the installer again and say yes |
| Starting agents that can act without asking is off | The same answer covers starting them | Start it in T3, pick another mode, or run the installer again and say yes |
| Prompt Peon doesn't know that approval mode | The game is still running the addon from before an update | Type `/reload`, then try again |
| Saved. Press Reload UI in the log to send it now | The game hasn't restarted since you installed or updated, so it can't send without a reload yet | Press Reload UI when it suits you, or restart the game. Nothing is lost either way |
| Reload UI button, or a reminder in chat | Live updates are running low | Press it when it suits you |

## Know this before you use it

WoW gives every addon access to the same things, and nothing can change that from inside the game. So:

- **Addons you trust can see what Prompt Peon shows.** Your thread text and any diff you open sit in plain text in the addon folder while the game runs, where any addon can read them. The companion app clears them when you close the game, along with your drafts and any message that hadn't been sent.
- **Addons you haven't trusted get thread names and status, and nothing else.** WoW can't stop an addon reading what's in the game, so the companion app keeps the words out until you've said yes. They can still draw a line or a popup that looks like ours, or use up refreshes, so don't install addons you don't trust at all.
- **Sending from the game stays off while an addon you haven't trusted is installed,** because any addon could send through Prompt Peon. Add a new addon later and thread text and sending both stop until you trust it. When one new addon is in the way, the notice names the exact command, `trust` and its folder name, so an agent on this machine that built you an addon can trust it itself, with no restart. Trust works by folder name, so a trusted addon's update is trusted too. Only trust addons you would hand the keys to.
- **Hiding is a privacy curtain, not a safe.** Hide a thread or project and its words, pictures and anything you opened leave the game at once, though a picture the game has already shown stays in its memory until the next reload, but its title and status stay, so you can find it again. Don't hide something whose title is the secret.
- **Secrets get a safety net, not a guarantee.** Files like `.env`, `.envrc` and `*.pem` stay out of diffs, and text that looks like a key or password is replaced with `[hidden secret]`. Plenty of secrets don't look like one, so don't show your screen to strangers. Don't send your `WTF` folder to anyone while the game is open: it can hold your drafts and unsent messages until it closes.
- **A plain `http://` link isn't encrypted.** Anyone on that network can read your threads and take your T3 access. Only say yes on a network you trust completely, and never on shared wifi. The installer asks first. An SSH tunnel or Tailscale avoids it.
- **Your token never goes in the game folder.** It stays in your user config folder, and only ever goes back to the T3 address that gave it to us. On the same machine it lasts 30 days, and the companion app swaps it for a fresh one a week before that. You can revoke it in T3 at any time.
- **Pictures** an agent looked at need file reading on the T3 machine, which is off unless you say yes at install. Say no and the companion app never asks for that permission. A token you made by hand keeps whatever access it was made with. Images attached to messages work either way.
- **News goes in its own `Peon` chat tab:** finished threads, levels, loot and the like. In Options you can move it to your main chat or turn it off. What you ask for, and anything that goes wrong, always shows in your main chat.
- **Chat shows only the start of a finished agent's message,** because other addons and chat logs keep what chat shows. The log has all of it. Your own replies stay out of chat.
- Model and effort apply from a thread's next turn, and higher effort uses more of your quota.
- **Answer an agent's question right in the log.** Each answer is a line you click, with what it means under it, and "Something else" lets you type your own. Pick one for each question, then click Send. With several questions, one Send sends all your answers together. A question with more than 4 parts or more than 10 answers still has to be answered in T3, and the log says so.
- **New threads start in the approval mode you pick** on the New thread page: Supervised until you pick another, and your pick stays. Auto and Full access need the same yes as sending to those agents. Approvals themselves are answered in T3, unless you turn on yolo mode.
- **Yolo mode: approve from the game.** Off until you turn it on, outside the game. On the game machine, in the program folder ([COMPANION-APP.md](COMPANION-APP.md) says where), run `python3 promptpeon_bridge.py yolo on`, and `yolo off` to go back. Nothing needs restarting. With it on, a thread waiting for approval shows what it wants to do, with **Approve** and **Decline** under it, in the log and on the tracker. A request too long to read whole on the tracker is approved in the log. One the game can't show exactly as it is has to be approved in T3: a very long one, one with something that looks like a secret in it, or one with anything but plain letters, digits and punctuation in it. The agent's own reason, if it gave one, is shown after the request in grey: it is the agent's word, not part of what runs. If a request changes after you read it, your click is refused and you read it again. There is no "always allow" from the game. Know what you're turning on: any addon you trust can approve too, and a misclick approves a real command on your T3 machine.
- **Answer from the tracker.** A thread waiting on you is unfolded on the tracker with what it asks. A question with one pick shows its answers there, and one click sends it without opening the log. Anything bigger has a line that opens the log.
- This hasn't been reviewed by Blizzard, and Blizzard can change what addons may do.

[SECURITY.md](SECURITY.md) says what protects you and what you have to watch.

**Known limits:** drafts don't survive closing the game, though they do survive a reload. Pictures over 4K don't get a preview. Up to 30 open threads and the 30 most recently settled show at once. Settled and snoozed threads open without pictures or older history. A single message over about 300,000 characters ends with a note to read the rest in T3. Two WoW accounts can share an install, but what you hid is shared too, and the account that changed it last wins.
