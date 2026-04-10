# Onboarding instructions — for Claude Code, not for the human

> **If you are a human reading this:** this file is meant for Claude Code to follow. Open Claude Code in VS Code (with WSL) and paste this prompt:
>
> > *"My name is Jo. Set up my machine to work on Christchurch Web Solutions projects. Run `curl -fsSL https://raw.githubusercontent.com/christchurchwebsolutions/cws-template/main/ONBOARDING-FOR-CLAUDE.md` to read the instructions, then follow them step by step. Stop and wait for me whenever you need information from me."*

---

You are setting up a developer's machine for Christchurch Web Solutions (CWS) work. The user is **Jo** — she is **not** a developer; she's a non-technical collaborator who works with Claude Code to build small web projects. Be friendly, explain what each step does in one short sentence before running it, and **stop to ask** when you need information from her.

Stack: Next.js 15 + self-hosted Supabase + Coolify auto-deploy on Hetzner. Server IPs:
- coolify: `49.13.212.235`
- supabase: `91.99.87.214`

## Critical safety rules — read these first

1. **Anything Jo pastes into this chat is logged.** If at any point you're about to ask Jo to paste a password, API token, `.env` file, or any other secret, **first warn her**: *"What I'm about to ask you to paste will end up in our conversation logs. After this onboarding is finished, we should rotate it to be safe. Are you OK with that?"* For Mark/Jo onboarding the unavoidable secrets are (a) the `.env.local` contents and (b) possibly a GitHub PAT. **Never** ask for her sudo password — see rule 2.

2. **`sudo` requires a TTY you don't have.** Any `sudo` command run from this chat will hang forever waiting for a password. **Do not run sudo yourself.** When you need root, **stop, print the exact command, and ask Jo to run it herself in a regular WSL terminal**, then tell you when she's done. Never ask her to paste her sudo password into this chat.

3. **`.env.local` contents are sensitive.** When Jo pastes them, do not echo them back. Verify with `wc -l` or `grep -c`, never `cat`. After writing, `chmod 600` immediately.

4. **Don't paste raw error tracebacks at Jo.** Read the error yourself, then say *"Something went wrong with X. The technical reason is Y. Here's what we'll try: Z."*

## Hard requirements before you start

1. **You must be running inside WSL (Linux), not raw Windows.** Run `uname -a`. If it doesn't say `Linux` and mention `WSL2` or `microsoft`, **stop immediately** and tell Jo: *"It looks like VS Code isn't connected to WSL. Click the green ⟩⟨ button in the bottom-left of VS Code and pick 'Connect to WSL', then open Claude Code in the new window and re-run the onboarding prompt."*

2. **You must be running as Jo's normal Linux user** (not root). Run `whoami`. If it returns `root`, stop and ask Jo to open a normal terminal.

3. **Check for a poisoned `~/.npmrc`.** Run `grep -n '^prefix=' ~/.npmrc 2>/dev/null`. If it returns anything, tell Jo: *"You have a `prefix=` line in `~/.npmrc` from a previous Node install. nvm doesn't work with this and will fail cryptically. I'm going to back up the file."* Then `mv ~/.npmrc ~/.npmrc.backup-$(date +%s)`.

If all checks pass, tell Jo: *"Great — I'm running in WSL as `<username>`. I'll walk through your machine setup. I'll explain each step before I do it, and I'll stop to ask when I need something from you. Ready?"* — then wait for her to say yes.

## Step 1 — System packages (run by Jo, not by you)

Tell Jo:
> *"First we need a few system packages: git, ssh, the C build tools Node needs, and the GitHub CLI. These need root, and I can't run sudo from this chat — please open a regular Ubuntu terminal (separate from VS Code), paste these commands, and tell me when they're done. They'll ask for your Linux password — that's normal."*

Give her this block to paste **in her own terminal**:

```bash
sudo apt update
sudo apt install -y curl git openssh-client build-essential
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/etc/apt/keyrings/githubcli-archive-keyring.gpg
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update
sudo apt install -y gh
```

**Wait** for her to confirm she ran them without errors. Then verify (no sudo needed):
```bash
git --version
ssh -V
gh --version
```

All three should print versions. If any are missing, ask Jo to re-run the apt step.

## Step 2 — Node.js via nvm

Tell Jo: *"Now I'll install nvm — that's Node Version Manager. It runs as your normal user (no sudo) and lets us install and switch Node versions cleanly."*

Install nvm:
```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
```

Source it into the **current** shell (the install script edits `~/.bashrc` but doesn't reload it):
```bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
```

Install Node LTS and **set it as the default for new shells**:
```bash
nvm install --lts
nvm use --lts
nvm alias default 'lts/*'
```

The `nvm alias default` line is critical — without it, new shells fall back to the system Node (often v18) and `next build` will fail with *"Node.js >=20.9.0 required."*

**Verify in the current shell** AND **in a fresh subshell**:
```bash
node --version
bash -lc 'node --version'
```

Both should print the same major version (currently `v22.x`). If the second one prints a different (older) version, the system has another Node ahead of nvm in `PATH`. Tell Jo:
> *"Your VS Code terminal is pinning an older Node version via its environment. Please completely close every VS Code window, reopen VS Code, reconnect to WSL, and re-open Claude Code. Then re-run the onboarding prompt — I'll skip ahead to here."*

Do **not** proceed to the next steps with mismatched node versions; the build will fail later in a way that's much harder to diagnose.

## Step 3 — Authenticate with GitHub (gh CLI)

Tell Jo: *"Now I'll set up GitHub access on your machine so we can clone the project. The `gh` command will print a one-time code and a URL — open the URL, paste the code, sign in, and authorize."*

Run:
```bash
gh auth login
```

When prompted, choose:
- **GitHub.com**
- **HTTPS**
- **Login with a web browser** (yes to git credential helper if asked)

After authentication:
```bash
gh auth status
gh auth setup-git
```

`gh auth setup-git` makes regular `git clone`/`git push` use the gh credentials — without this, `git push` will 403 even though `gh repo clone` works.

### SSO note (paste this to Jo)
> *"One thing to know: the `christchurchwebsolutions` GitHub org may require SSO authorization on personal access tokens. If we hit a 403 later when pushing, you'll need to visit https://github.com/settings/tokens, find the token gh just created (named something like 'gh-cli'), click 'Configure SSO', and authorize it for the org. I'll tell you if/when that happens."*

## Step 4 — Generate Jo's SSH key

Tell Jo: *"Next I'll create an SSH key so your machine can run the database scripts (which talk to the Supabase server). Your private key never leaves this machine. The public key is what we'll send to Mark."*

Ask Jo for her name and email **before generating** so the key has a meaningful comment:
> *"What name and email should I label this key with? I'll use it as the 'comment' on the key — it doesn't affect security, just helps Mark see whose key is whose on the server."*

Wait for her answer. Then check if a key already exists:
```bash
ls -la ~/.ssh/id_ed25519 2>/dev/null || echo "no key yet"
```

If a key exists, ask Jo whether to use it or generate a fresh one. If fresh: `mv ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.backup-$(date +%s)` and likewise for `.pub`.

Generate the key (no passphrase — otherwise the database scripts will pause for input every time):
```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C "<NAME> <EMAIL>"
```

Substitute Jo's actual name and email into the `-C` comment.

Print the public key in a clearly marked block:
```bash
echo "=========================================="
echo "  COPY THIS LINE AND SEND IT TO MARK:"
echo "=========================================="
cat ~/.ssh/id_ed25519.pub
echo "=========================================="
```

## Step 5 — STOP. Wait for Mark.

Tell Jo:
> *"I've printed your public key above. **Please copy that whole line and send it to Mark.** Mark needs to add it to the CWS server. Tell me when Mark has confirmed the key is added — I'll wait."*

**Do not proceed past this step until Jo confirms.** When she says Mark has done it, continue.

## Step 6 — Test SSH access AND the database tunnel

Tell Jo: *"Let me check that your machine can reach the server, AND that the database is reachable through it — the database scripts need both."*

First, basic SSH:
```bash
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes root@91.99.87.214 'hostname'
```

Expected: `supabase`. Failure modes:
- `Permission denied (publickey)` → tell Jo *"The server isn't accepting your key yet — Mark either hasn't added it or added it wrong. Please double-check with Mark."* Go back to Step 5.
- `Connection timed out` → network issue, retry once.

Now the **real** smoke test — can we list schemas through the same channel the migration scripts will use?
```bash
ssh root@91.99.87.214 "docker exec -i supabase-db psql -U supabase_admin -d postgres -c '\\dn' | head -20"
```

If this prints a list of schemas (you should see `public`, `auth`, `storage`, and any project schemas like `cortex`), the migration tooling will work. ✅

If it fails, do **not** continue — the database scripts won't work either. Show Jo a friendly version of the error and ask her to flag it to Mark.

## Step 7 — Clone the project

Ask Jo: *"What's the name of the project Mark set up for you? (it should be lowercase with hyphens, like `acme-website`)"*

When she gives you `<project-name>`:

```bash
cd ~
gh repo clone christchurchwebsolutions/<project-name>
cd <project-name>
```

Failure modes:
- **404 / repo not found** → tell Jo *"That repo doesn't exist on GitHub yet. Please ask Mark to create it."*
- **403 forbidden** → SSO authorization needed. Tell Jo: *"GitHub is blocking us because the org requires SSO. Please visit https://github.com/settings/tokens, find the gh-cli token, click 'Configure SSO', and authorize it for `christchurchwebsolutions`. Then tell me when done."* Wait, then retry.
- **Repo exists but Jo's account isn't a member** → tell Jo *"Your GitHub account doesn't have access to this private repo yet. Please ask Mark to add you as a collaborator."*

## Step 8 — Set up `.env.local`

**Warn Jo about the secret** (rule 1 from the top of this file):
> *"This project needs a file called `.env.local` containing some passwords and keys. Mark should have sent you the contents via a secure channel (password manager, Signal, etc.). I need you to paste the entire contents into this chat — but be aware that **anything you paste here will end up in our conversation logs**. After we're done with onboarding, we should rotate the database password to be safe. Are you OK with that?"*

Wait for Jo to acknowledge, then ask her to paste.

When Jo pastes the contents:

1. **Validate** it has the four expected keys: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `DB_NAME`, `POSTGRES_PASSWORD`. If any are missing, tell Jo *"This is missing the `<key>` line — please ask Mark to send the full file."*

2. **Write it** to `~/<project-name>/.env.local` and chmod 600.

3. **Do not echo the contents back.** Confirm with `wc -l ~/<project-name>/.env.local && grep -c '=' ~/<project-name>/.env.local`.

```bash
chmod 600 ~/<project-name>/.env.local
```

## Step 9 — Install dependencies and build

```bash
cd ~/<project-name>
npm install
```

Tell Jo: *"Installing all the JavaScript packages this project needs..."*

Then a smoke-test build:
```bash
npm run build
```

If the build fails with *"Node.js >=X required"* — go back and re-do Step 2's `nvm alias default` + fresh-shell verification. Almost certainly the wrong Node version is being used.

If the build succeeds, tell Jo: *"Everything builds. Now I'll start the dev server so you can see it running."*

Start the dev server **in the background**:
```bash
npm run dev
```
*(Use `run_in_background` if you have it, or append `&`. After ~3 seconds, smoke-check it.)*

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000
```

If it returns `200`, tell Jo: *"Your local dev server is running at http://localhost:3000 — open that in your browser to see it."*

## Step 10 — End-to-end test (CLI flow, no GitHub Desktop)

Tell Jo:
> *"Everything's set up. Let's do one quick test to make sure the whole pipeline — local edit → git → Coolify → live site — actually works:*
>
> *Tell me a tiny change you'd like — like 'change the heading to say Hello from Jo'. I'll make the edit, show you the diff, and walk you through committing and pushing it. Your change will be live on the public site about 2 minutes after we push."*

Make whatever change she asks for in `src/app/page.tsx`. Then:

```bash
git diff
```

Show Jo what changed in plain English: *"This adds the line X and removes Y."* Then:

> *"Ready to commit and push? If yes, say 'yes' and I'll do it."*

When she confirms, commit and push:
```bash
git add -A
git commit -m "first edit: <short description of the change>"
git push
```

Watch the push output. If it 403s, it's the SSO issue from Step 3 — tell Jo to authorize the token and try again.

When the push succeeds, tell Jo:
> *"Pushed! Coolify is now building and deploying — this takes about 2 minutes. The live URL is `https://<project-name>.apps.christchurchwebsolutions.co.uk`. Refresh it in a couple of minutes and you'll see your change."*

## Step 11 — You're done

Tell Jo:
> *"You're fully set up. From now on, the workflow is:*
>
> - *Open this project in VS Code (it remembers).*
> - *Talk to me in the Claude Code panel — describe what you want to build.*
> - *I'll write the code, run database migrations, and update everything.*
> - *When we're happy, I'll show you the diff and commit and push.*
> - *Coolify auto-deploys, the live site updates, done.*
>
> *If you ever want a brand-new project, ask Mark — he runs one command on his end and it appears in GitHub.*
>
> *⚠️ **One important thing:** during onboarding you pasted some secrets into our chat (the `.env.local`, your GitHub PAT, etc.). Those are now in our conversation logs. Please ask Mark to rotate the database password and revoke any GitHub tokens you no longer need, just to be safe.*
>
> *Welcome to CWS. 🎉"*

---

## Notes for Claude (recap)

- **Never run sudo yourself** — print the command and ask Jo to run it in a regular terminal
- **Never echo `.env.local` contents** — use `wc -l` / `grep -c` to verify
- **Always warn before asking for secrets** — they end up in chat logs
- **Verify Node version in a fresh subshell** after nvm install — `bash -lc 'node --version'`
- **Always run `gh auth setup-git`** after `gh auth login` so plain `git push` works
- **Database tunnel test (`ssh ... docker exec ... psql ... \l`)** is the real smoke test, not just `hostname`
- **If Jo is non-technical and confused**, slow down and explain what you're doing in one sentence — never paste raw tracebacks at her
- **The CWS migration workflow** lives in `AGENTS.md` and `CLAUDE.md` in this repo. After onboarding, that's the most important document for future sessions to read.
