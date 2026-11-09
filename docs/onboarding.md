# Onboarding: for the agent setting up mirroir

This page is written for you, the coding agent a user asked to set up mirroir. Follow it in order. The user's hands are needed for exactly three things: approving macOS permissions, connecting iPhone Mirroring, and answering at most two questions. Do everything else yourself, and end with proof that you can read their iPhone. A first errand on the phone is offered after that, and only runs if the user says yes.

## Rules

- **Look before you ask.** Check what this Mac already has before asking the user anything.
- **Ask at most two questions** in the whole setup. Prefer telling the user what you found and what you are about to do.
- **Never change a permission yourself.** macOS privacy grants are the user's to approve: tell them which pane and which app, and wait.
- **Never type a password, PIN or one-time code**, on the Mac or on the iPhone.
- **Never open the iOS Settings app**, and never tap on the iPhone during setup. The proof in step 3 only reads the screen. Step 4 acts on the phone, and only after the user says yes.
- **Never retry in a loop.** When a step needs the user, say what they must do, wait for them to say it is done, then retry once.

## Step 0: what this Mac can do

Run these and read the results:

```bash
sw_vers -productVersion        # macOS version
uname -m                       # arm64 = Apple silicon
pgrep -x "iPhone Mirroring"    # running or not
command -v node npx claude codex openclaw
```

Compare with the prerequisites:

| Requirement | Why |
|---|---|
| macOS 15 (Sequoia) or later | iPhone Mirroring ships with macOS 15 |
| A Mac with Apple silicon, or an Intel Mac with a T2 chip | Apple's requirement for iPhone Mirroring |
| iPhone on iOS 18 or later, signed in to the same Apple Account as the Mac | Apple's requirement for iPhone Mirroring |
| Bluetooth and Wi-Fi on, iPhone near the Mac | Mirroring runs over Continuity |
| iPhone Mirroring available in the user's region | Apple does not offer it everywhere, notably not in the European Union ([Apple's page](https://support.apple.com/en-us/120421)) |
| Node.js (`npx`) | The quickest install path |

If macOS is older than 15 or the Mac does not qualify, stop and tell the user in one sentence that this Mac cannot run iPhone Mirroring, so mirroir cannot drive an iPhone from it. Do not continue.

Then tell the user, in one sentence, what you found and what you will do next.

## Step 1: install and register the server

Register mirroir with the client you are running in:

```bash
# Claude Code
claude mcp add --transport stdio mirroir -- npx -y mirroir-mcp
# Codex
codex mcp add mirroir -- npx -y mirroir-mcp
# OpenClaw (needs the binary on the Gateway's PATH: brew install jfarcand/tap/mirroir-mcp)
openclaw mcp add mirroir --command mirroir-mcp
```

For Cursor, VS Code and Claude Desktop, use the configuration block for that client in the [Install guide](install.md#install).

Then install the operating manual, which teaches you (and later sessions) how to drive the phone:

```bash
npx -y mirroir-mcp skill --install
```

It writes `~/.claude/skills/mirroir/SKILL.md`, `~/.codex/skills/mirroir/SKILL.md` and `~/.openclaw/skills/mirroir/SKILL.md`. Read it now with `npx -y mirroir-mcp skill`.

## Step 2: run doctor

```bash
npx -y mirroir-mcp doctor
```

Every line that does not pass names its fix. Handle them in this order:

1. **iPhone Mirroring not running.** Start it in the background: `open -g -a "iPhone Mirroring"`.
2. **Mirroring not connected.** The doctor line quotes what the window says. Relay it: usually the user must lock their iPhone, or click the button the window shows. Wait for them, then run doctor again.
3. **Screen Recording or Accessibility not granted.** The hint names the app to turn on (the terminal, editor or AI client that runs mirroir) and the link that opens the pane. Give the user that sentence and link. Screen Recording needs that app to be quit and reopened afterwards: say so, because your own session may end when they do it.
4. **Screen read failed while Screen Recording passes.** The grant has not taken effect yet: the user must quit and reopen the app named in the hint.

Do not move on until doctor reports no failure. A warning about updates is fine.

## Step 3: the proof

When the MCP tools are available in your session (the client may need a restart after `mcp add`; if so, tell the user and stop here), call:

```
describe_screen(omit_screenshot: true)
```

Read back to the user, in one or two sentences, which app is on their iPhone and a few words of what it shows. That is the proof setup worked. Do not tap, type or open anything to produce it.

## Step 4: a first errand, if the user wants one

Setup is finished at step 3. Offer one thing more, once, and take no for an answer:

> Want to see it act? I can open mirroir.dev in Safari on your iPhone and read the page back to you.

Only if the user says yes:

1. Call `open_url` with `https://mirroir.dev/?utm_source=onboarding&utm_medium=agent&utm_campaign=first-errand`. Say what you are doing in one line first.
2. Call `describe_screen(omit_screenshot: true)` and tell the user the headline the page shows. That is the errand: the phone did something they watched.
3. The page has a "Star on GitHub" banner. Ask whether they want you to tap it, and tap it only on a second yes. If GitHub asks to sign in, stop: never type a password or a code. Give them the link instead: `https://github.com/jfarcand/mirroir-mcp`.
4. Leave Safari as it is and say that setup is done.

If the user says no at any point, stop there. Do not ask again.

## If something does not fit

- The user's Mac is fine but iPhone Mirroring will not connect: point them to [Apple's iPhone Mirroring page](https://support.apple.com/en-us/120421) and to [Troubleshooting](troubleshooting.md).
- The client cannot run MCP servers: say so; mirroir needs an MCP client.
