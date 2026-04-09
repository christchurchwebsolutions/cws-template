# Onboarding instructions — for Claude Code, not for the human

> **If you are a human reading this:** this file is meant for Claude Code to follow. Open Claude Code in VS Code (with WSL) and paste this prompt:
>
> > *"My name is Jo. Set up my machine to work on Christchurch Web Solutions projects. Run `curl -fsSL https://raw.githubusercontent.com/christchurchwebsolutions/cws-template/main/ONBOARDING-FOR-CLAUDE.md` to read the instructions, then follow them step by step. Stop and wait for me whenever you need information from me."*

---

You are setting up a developer's machine for Christchurch Web Solutions (CWS) work. The user is **Jo** — she is **not** a developer; she's a non-technical collaborator who works with Claude Code to build small web projects. Be friendly, explain what each step does in one short sentence before running it, and **stop to ask** when you need information from her.

The CWS infrastructure is fully described at https://raw.githubusercontent.com/christchurchwebsolutions/cws-template/main/CWS-INFRASTRUCTURE-PUBLIC.md *(if that file doesn't exist yet, infer from this file).*

Stack: Next.js 15 + self-hosted Supabase + Coolify auto-deploy on Hetzner. Server IPs:
- coolify: `49.13.212.235`
- supabase: `91.99.87.214`

## Hard requirements before you start

1. **You must be running inside WSL (Linux), not raw Windows.** Run `uname -a`. If it doesn't say `Linux` and mention `WSL2` or similar, **stop immediately** and tell Jo: *"It looks like VS Code isn't connected to WSL. Click the green ⟩⟨ button in the bottom-left of VS Code and pick 'Connect to WSL', then open Claude Code in the new window and re-run this prompt."*

2. **You must be running as Jo's normal Linux user** (not root). Run `whoami`. If it returns `root`, stop and ask Jo to open a normal terminal.

If both checks pass, tell Jo: *"Great — I'm running in WSL as `<username>`. I'll walk through your machine setup. I'll explain each step before I do it, and I'll stop to ask when I need something from you. Ready?"* — then wait for her to say yes.

## Step 1 — System packages

Tell Jo: *"First I'll update the system and install git, ssh, and the C build tools that Node needs. This will ask for your Linux password."*

Run:
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git openssh-client build-essential
```

Verify:
```bash
git --version
ssh -V
```

## Step 2 — Node.js via nvm

Tell Jo: *"Now I'll install nvm — that's Node Version Manager. It lets us install Node.js without needing admin permissions."*

Run:
```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
```

Then **source bashrc** so `nvm` is on the path *in the current shell* — this is important, the install script doesn't do it for you:
```bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
```

Install Node LTS:
```bash
nvm install --lts
nvm use --lts
node --version
npm --version
```

Both should print version numbers.

## Step 3 — Generate Jo's SSH key

Tell Jo: *"Next I'll create an SSH key for you. This is what your machine uses to securely talk to the server. I'll create it with no password — that means the database scripts won't need to ask for one every time. Your private key stays on this machine and is never sent anywhere. The public key is what we'll send to Mark."*

Check first if a key already exists:
```bash
ls -la ~/.ssh/id_ed25519 2>/dev/null || echo "no key yet"
```

If a key exists, ask Jo: *"You already have an SSH key — should I use the existing one or generate a fresh one?"*. If fresh, back up the old one (`mv ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.backup-$(date +%s)`).

Generate (note the `-N ""` for no passphrase, and `-q -y` to suppress prompts):
```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C "jo@christchurchwebsolutions.co.uk"
```

**Print the public key in a clearly marked block:**
```bash
echo "=========================================="
echo "  COPY THIS LINE AND SEND IT TO MARK:"
echo "=========================================="
cat ~/.ssh/id_ed25519.pub
echo "=========================================="
```

## Step 4 — STOP. Wait for Mark.

Tell Jo:
> *"I've printed your public key above. **Please copy that whole line and send it to Mark.** Mark needs to add it to the CWS server. Tell me when Mark has confirmed the key is added — I'll wait."*

**Do not proceed past this step until Jo confirms.** When she says Mark has done it, continue.

## Step 5 — Test SSH access to the supabase server

Tell Jo: *"Let me check that the server is now letting your machine in."*

Run:
```bash
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes root@91.99.87.214 'hostname'
```

- Expected output: `supabase`
- If you get `Permission denied (publickey)`: tell Jo *"The server isn't accepting your key yet. Either Mark hasn't added it, or it was added wrong. Ask Mark to double-check."* Then go back to waiting at Step 4.
- If you get `Connection timed out`: tell Jo *"The server isn't reachable. Check your internet connection and try again in a moment."*

If it prints `supabase`, tell Jo: *"Great — your machine can now talk to the server. ✅"*

## Step 6 — Clone the project

Ask Jo: *"What's the name of the project Mark set up for you? (it should be lowercase with hyphens, like `acme-website`)"*

When she gives you `<project-name>`:

```bash
cd ~
git clone https://github.com/christchurchwebsolutions/<project-name>.git
cd <project-name>
```

If the clone fails with a 404, the repo doesn't exist yet — tell Jo to ask Mark to create it.
If it asks for credentials, tell Jo: *"GitHub Desktop should have set up your credentials, but it looks like it hasn't. Open GitHub Desktop, sign in to your account, and try again."*

## Step 7 — Set up `.env.local`

Tell Jo:
> *"This project needs a file called `.env.local` containing some passwords and keys. Mark should have sent you the contents of this file via a secure channel (password manager, Signal, etc.). **Please paste the entire contents of that file here in the chat now**, and I'll save it to the right place."*

When Jo pastes the contents:

1. Validate it has the four expected keys: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `DB_NAME`, `POSTGRES_PASSWORD`. If any are missing, tell Jo *"This is missing the `<key>` line — please ask Mark to send the full file."*

2. Write it to `~/<project-name>/.env.local` and chmod 600:
```bash
chmod 600 ~/<project-name>/.env.local
```

3. **Do not echo the file contents back to Jo.** Confirm with `wc -l ~/<project-name>/.env.local` instead.

## Step 8 — Install dependencies

```bash
cd ~/<project-name>
npm install
```

This takes ~30 seconds. While it runs, tell Jo: *"Installing all the JavaScript packages this project needs..."*

## Step 9 — Verify it builds and runs

Run a build (smoke test):
```bash
npm run build
```

If the build fails, read the error and either fix it or report it to Jo with a clear description.

If the build succeeds, tell Jo: *"Everything builds. Now I'll start the dev server so you can see it running."*

Start the dev server **in the background** so you can keep going:
```bash
npm run dev
```
*(Use the run_in_background tool option if you have it.)*

Wait a few seconds, then verify it's serving:
```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000
```

If it returns `200`, tell Jo: *"Your local dev server is running at http://localhost:3000 — open that in your browser to see it."*

## Step 10 — End-to-end test

Tell Jo:
> *"Everything's set up. Let's do one quick test to make sure the whole pipeline works:*
>
> *1. Tell me a tiny change you'd like — like 'change the heading to say Hello from Jo'.*
> *2. I'll edit the file.*
> *3. You then open **GitHub Desktop** (the Windows app, not WSL), write a commit message like 'first deploy', click **Commit**, then click **Push origin**.*
> *4. Wait about 2 minutes.*
> *5. Open `https://<project-name>.apps.christchurchwebsolutions.co.uk` in your browser — your change should be live."*

Make whatever change she asks for in `src/app/page.tsx` (or wherever fits best).

After the change, **do not commit it yourself** — Jo learns the GitHub Desktop flow by doing it. Just edit, save, and tell her *"Done — now switch to GitHub Desktop, write a commit message, and click Commit then Push."*

## Step 11 — You're done

Tell Jo:
> *"You're fully set up. From now on, the workflow is:*
>
> - *Open this project in VS Code (it remembers).*
> - *Talk to me in the Claude Code panel — describe what you want to build.*
> - *I'll write the code, run database migrations, and update everything.*
> - *When you're happy, GitHub Desktop → Commit → Push, and the live site updates automatically.*
>
> *If you ever want a brand-new project, ask Mark — he runs one command on his end and it appears in GitHub.*
>
> *Welcome to CWS. 🎉"*

---

## Notes for Claude

- **Never expose `.env.local` contents in chat output.** Use `wc -l` or `grep -c` to confirm contents instead of `cat`.
- **Don't sudo unless step 1.** Everything else runs as Jo's normal user.
- **If a step fails**, diagnose the error before retrying — don't loop. Most failures here are network timeouts (retry once) or wrong keys (escalate to Mark).
- **Jo is non-technical** — never paste raw error tracebacks at her. Read the error yourself, then say *"Something went wrong with X. The technical reason is Y. Here's what we can do: Z."*
- **The CWS migration workflow** lives in `AGENTS.md` and `CLAUDE.md` in this repo. After onboarding, that's the most important document for future sessions to read.
