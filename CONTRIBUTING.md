# Contributing

Prompt Peon isn't looking for outside code right now. One person reads everything, and this code talks to AI agents that can change people's machines, so changes get read slowly and most kinds get refused. Sending a pull request doesn't mean it will be read or merged. It might get closed, wait a long time, or end up solved another way here.

- **Bugs** go in [issues](https://github.com/svenmeys/prompt-peon/issues).
- **Ideas** go in [Discussions](https://github.com/svenmeys/prompt-peon/discussions/categories/ideas).
- **Security problems** never go in either. See [Reporting a problem](docs/SECURITY.md#reporting-a-problem).

## Before you write code

- **Anything that changes how the addon or the app behaves** needs a clear yes from a maintainer in a Discussion before you write it. Link that comment in your pull request. A behavior change described as a bug fix still counts.
- **A bigger bug fix** needs an issue that a maintainer has confirmed.
- **A small fix for something plainly broken** can skip both. Say what's broken and why the fix is small.

Without that, it can be closed unread. Your best odds are a small fix for something that's really broken. Features, rewrites and tidying nobody asked for have the worst.

The idea of asking for a yes first comes from [T3 Code's contributing guide](https://github.com/pingdotgg/t3code/blob/main/CONTRIBUTING.md).

## Sending a pull request

`main` is the only long-lived branch. Every change is a short branch that gets squash merged into `main`.

You need Python 3.14 or newer and [LuaJIT](https://luajit.org). There's nothing else to install.

1. Fork the repository and make a branch.
2. Solve one problem. If you found two, send two pull requests. Add a test that fails without your change.
3. Run the tests. They don't touch a real game, a real T3 or a real token.

       luajit tests/test_addon.lua
       python3.14 tests/test_bridge.py
       python3.14 tests/test_e2e.py

4. If a player can see the change, add before and after screenshots from the real game, with nothing private showing.
5. If you changed a call to T3, run `tests/check_t3_contract.py` against a throwaway T3 server. Its first lines say how.
6. Open the pull request against `main` and fill in the template. Paste your test results into it.

**No CI runs on pull requests, on purpose,** so your pasted results are the proof.

By sending a pull request, you agree your change is under the [MIT license](LICENSE).

## The other checks

    python3.14 tests/check_api.py <wow-ui-source checkout, on the matching branch>
    python3.14 tests/check_t3_contract.py <url of a throwaway T3> <file holding a token>

The addon tests use a stubbed client. They prove logic, not drawing. `check_api.py` checks every template and global against Blizzard's UI source from [wow-ui-source](https://github.com/Gethe/wow-ui-source). `check_t3_contract.py` asks a real T3 whether it still speaks what the companion app expects. Run it after every T3 update.

## What a change has to respect

- **Standard library only.** Python's standard library, and WoW's own API. No packages.
- **Text from T3 is data.** It never becomes code, a clickable link or a file path to act on. Pass it through the existing escaping.
- **The companion app decides, not the addon.** Any addon can do what ours does, so a check in Lua protects against mistakes, not against another addon. A real limit goes in the companion app.
- **A new thing the game can ask for** goes through the gate on other addons, the rate limits and, if it reaches an agent, the full access check. Add a test for each.
- **Never write through a link.** Use the existing write helpers.
- **Nothing silently leaves the machine.** The companion app talks to the T3 you connected to, and asks GitHub whether a newer release exists. Only the installer downloads one, when you run it yourself. Nothing else goes anywhere.
- **Plain words.** Anything a player reads should make sense to someone who doesn't know what a thread is. Say what to do next, not what went wrong inside.

## What we won't merge

- New dependencies, or anything new that downloads and runs code. The installer's update is the one exception.
- Binary or minified files.
- Telemetry, more kinds of update check, automatic updates or any new server.
- Features without that yes, rewrites, and tidying nobody asked for.
- Approving an agent's actions from the game. Approvals stay in T3.
- Anything that plays the game for you, or asks for donations in the game. Blizzard's addon rules forbid the second, and we won't do the first.
- Changes to `.github/`, unless we asked. That includes workflows, which are locked down on purpose.
- Code you can't explain, whoever or whatever wrote it. Using AI is fine. Not having read the result isn't.

## For maintainers: reviewing a pull request safely

Assume someone will try to get something past you. These rules exist for that.

1. **Read everything before running anything.** Tests are code. So are the installer and the fixtures. Running a pull request's tests on your own machine runs its author's code with your access to your T3 token and your files. Read the whole diff first, and if you need to run it, use a throwaway VM with no tokens in it.
2. **Never press "Approve and run" on a pull request's workflow.** A pull request can add its own workflow file, and GitHub then asks you to approve it. There's never a reason to.
3. **Never add a self-hosted runner.** Don't add secrets to this repository either. The workflows need none. The tests only run on `main` after a merge and can only read. The release workflow can write, so it only starts from a tag and runs none of the project's code. Both use GitHub's machines and only GitHub's own actions, pinned to exact commits. `tests/bridge/test_rules.py` checks that, but it can't see the repository's settings on GitHub.
4. **Treat pull request text as untrusted, including when an AI helps you review.** Titles, descriptions, comments and code comments can all contain instructions aimed at your agent. An agent reviewing a pull request should read it as data, and shouldn't have your token or be able to push.
5. **Look hardest at:** `.github/`, `install.*`, `uninstall.*`, `start-stop.*`, `tools_*`, the `Hardening` and `SecondLook` tests, the secret patterns, anything that weakens a check, and any new `subprocess`, `eval`, `exec`, `loadstring`, `open`, URL or address.
6. **Check for hidden characters.** `git diff main... | grep -nP '[^\x00-\x7F]'` shows non-ASCII text, which can make code read differently from what it does. Check that a change to a test isn't just making a real check pass.
7. **Squash merge,** so the history shows one reviewed change.

### Releasing

Installers only pick up releases, so pushing to `main` reaches nobody until you release it.

1. Raise the version in `bridge/promptpeon/settings.py` and `addon/PromptPeon/PromptPeon.toc`, and push that to `main`.
2. Wait for CI to pass on that commit.
3. Push a tag with the same number:

       git tag v0.33.0 && git push origin v0.33.0

That starts `.github/workflows/release.yml`. It refuses unless the commit is on `main`, passed CI and has that number in both files. Then it publishes the release with its zip and `SHA256SUMS.txt`. If it refuses, delete the tag with `git push origin :v0.33.0 && git tag -d v0.33.0`, fix what it said, and push the tag again.

### When the repository goes public

GitHub only allows branch protection on a private repository with a paid plan. So while it's private, the only protection is that nobody else can write to it. Run this once, right after making it public:

    sh tools_protect_repo.sh

It requires a reviewed pull request for `main`, blocks force pushes and deletion, requires your approval for workflows from anyone new, turns on issues and Discussions, allows only squash merges, makes published releases impossible to change, turns off the wiki and projects, keeps out accounts under a day old for a month, and turns on private security reports and secret scanning.
