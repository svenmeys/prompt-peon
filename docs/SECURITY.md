# Security

Prompt Peon lets a game addon send real messages to real agents. This page says what protects you, and what you have to watch yourself. AI reviewers have gone through the code, but no person has audited it and nothing certifies it.

## What it won't do

- **Approve anything.** An agent's approval requests can only be answered in T3. Questions an agent asks you can be answered in the game, because an answer says no more than a reply could. Only the answers the question offers can be picked, and a question that changed or was answered meanwhile is refused.
- **Turn an agent's words into code in the game.** They're only ever shown as text.
- **Send to an agent that acts without asking,** or start one, unless you said yes to that. You can still stop it and turn it in.
- **Cast a spell without asking.** A spell shows its exact words first, unless you turn that off in Options. No spell tells an agent to push.
- **Talk to anything except your T3 and GitHub.** While the game is open it asks GitHub every 30 minutes whether a newer release exists, and chat tells you if so. It sends nothing of yours and downloads nothing.
- **Keep your words after you close the game.** Thread text, drafts and unsent messages are cleared from the game folder. While you play, they sit there as plain text. Encrypting them wouldn't help, because the key would have to be in the game too.

## What you have to watch

- **Other addons.** WoW gives every addon the same access. An addon can read what Prompt Peon shows, fake a line or a popup that looks like ours, or write to its outbox. So while an addon you haven't trusted is installed, only thread names and status reach the game, and nothing gets sent. Only trust addons you'd trust with your threads. A trusted addon's updates are trusted too, so this is the one thing Prompt Peon can't protect you from. The `trust` command lets an agent on your machine trust an addon it built for you. It gives that agent nothing new, because anything running as you could already change your config. The game only names the command for a folder name made of letters, digits, dots, dashes and underscores, so a hostile name can't turn into a command you paste.
- **Your token.** It's the `token` file in your config folder, plus `token-local` if you show this machine's threads too, and it can read your threads and send to them. It lasts a year if T3 is on the same machine, and 30 days through a link from another one. It isn't tied to your machine, so whoever copies the file has that access. It's owner-only on Linux and a plain file on Windows. Never share it. If you lose the machine, revoke Prompt Peon in T3 under Settings, Sharing & access.
- **T3 Connect.** The link and the token are all that stand between the internet and your threads. A pasted link works once. If you'd rather not depend on that, use Tailscale, which keeps the token inside your own network.
- **Plain `http://`.** The installer asks first and defaults to no, because anyone on that network could read the traffic.
- **Pictures.** They're off unless you say yes. With them on, T3 can serve any PNG on its machine, including outside your project, and pictures appear by themselves, which can surprise you on a stream. Leave them off if that matters.
- **Hiding a thread.** Its words leave the game at once. Its title and status stay, so you can find it again.

## Updates and downloads

- **The installer updates itself.** When you run it, it asks GitHub for this repository's newest release and hands over to it if it's newer, without asking. So whoever controls this repository controls what your next install runs. Nothing of yours goes with the request, and published releases can't be changed afterwards. The companion app and the game never start it. They only tell you it's there. `--no-update` skips it.
- **The download.** Get it only from this repository. Every release carries its zip and a `SHA256SUMS.txt`, and [the install guide](INSTALL.md#2-download-it) says how to compare them. That catches a damaged copy, or one that someone changed after it left here. It can't catch someone who controls this repository.

## Reporting a problem

Report it privately on GitHub: open this repository's **Security** tab and press **Report a vulnerability**. Please don't open a public issue for it.
