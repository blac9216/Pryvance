---
name: with-secrets
description: >-
  Run a command that needs a credential (passwords, API tokens, registry logins, DB
  passwords, vCenter/ESXi/NetApp/SSH auth, terraform/ansible/govc/docker that require
  secrets) WITHOUT ever seeing, printing, or persisting the secret value. Use whenever a
  task needs a password/token from the smartcard-gated vault at
  $WORKSPACE_DIR/.config/secrets/. Host inventory is in connections.yml.
---

# with-secrets — use credentials without exposing them

Secrets live encrypted in `$WORKSPACE_DIR/.config/secrets/secrets.env` (ansible-vault, gated
on the user's smartcard). `with-secrets` decrypts them in memory and injects them into the
environment of the command it runs. You invoke it with a **reference** to a command; values
are never returned to you.

## Absolute rules — never break these

1. **Never emit a secret value where it can be seen or stored.** Not to stdout/stderr (no
   `echo`/`printf`/`print` of a value; no `printenv`/`env`/`set`/`cat` that reveals one), not
   into a file, not into the conversation, and **never onto a command's argv** (no
   `--password "$X"`, no `-p "$X"` — argv is visible in `ps` and logs).
2. **Never read the vault for values.** No `cat secrets.env`, `ansible-vault view …`, or
   `secret <NAME>` (it prints). Those are for the human, not you.
3. **Feed secrets to tools only by the methods below** — env, `--as`, stdin pipe, or a
   process-substitution file. Each keeps the value off the screen, off disk, and off argv.
4. **If decryption fails, stop and ask the user** to make sure their smartcard is present.
   Do not work around the vault.

## How to feed a secret to a tool

Pick whichever input the tool supports. Each keeps the value off your screen, off disk, and
off argv.

**Tool reads an env var** (terraform `TF_VAR_*`, `GOVC_PASSWORD`, ansible, `PGPASSWORD`, …) —
every variable in `secrets.env` is already in the tool's environment:

```bash
with-secrets terraform apply
with-secrets govc ls
```

**Tool wants a DIFFERENT env-var name** than how it's stored — remap with `--as NEW=OLD`:

```bash
with-secrets --as SSHPASS=ESXI_ROOT_PASSWORD sshpass -e ssh root@host
with-secrets --as DOCKER_PASSWORD=REGISTRY_TOKEN some-deploy-tool
```

**Tool reads the secret from STDIN** (`docker login --password-stdin`,
`gh auth login --with-token`, …) — pipe a *reference* in. This is the allowed use of
`sh -c`: piping a reference into the tool, never printing it:

```bash
with-secrets sh -c 'printf %s "$REGISTRY_TOKEN" | docker login -u me --password-stdin reg.example'
```

**Tool wants a password FILE** — hand it a process-substitution FD, never a real file:

```bash
with-secrets sh -c 'sometool --password-file <(printf %s "$THE_SECRET")'
```

**SSH** — `ssh` ignores env-var passwords (it reads the TTY), so bridge with `sshpass`:

```bash
with-secrets --as SSHPASS=<CRED> sshpass -e ssh user@host    # password host
ssh user@host                                                # key_only host (no secret)
```

Use `with-secrets --list` to see available variable **names** (never values).

## Inventory (connections.yml)

Plaintext, safe to read. Per host: `host`, `username`, `cred_ref` (the var name in
`secrets.env`), `key_only` (true → no secret needed), and `note` (read it — it may say the
cred is non-static and how to obtain it, e.g. the vSphere Supervisor root password comes from
running `/usr/lib/vmware-wcp/decryptK8Pwd.py` on the hosting vCenter).

## What this guarantees / doesn't

It keeps secrets off disk, out of this transcript, and gated on the user's card. It does
**not** make values cryptographically invisible to you — which is why rules 1–3 are
mandatory. If a task seems to need you to *see* a value, it doesn't: feed it to the consuming
tool with one of the methods above, or ask the user.
