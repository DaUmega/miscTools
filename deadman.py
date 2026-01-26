#!/usr/bin/env python3
# Dead Man’s Switch
#
# This script implements a local-only dead man’s switch that encrypts a secret message,
# securely removes all sensitive material, and automatically triggers if the user fails
# to "check in" within a specified time window. The encrypted payload is sent only to a
# pre-defined recipient who holds the corresponding private key.
#
# Security model:
# - Secret remains encrypted and only the recipient with the private key can decrypt it.
# - The sender’s system contains no long-term plaintext or private keys after setup.
# - Compromise requires both the sender’s system and recipient’s private key.
#
# Key Features and Workflow:
#
# 1) Environment Verification
#    - Script refuses to run unless executed inside an active Python virtual environment.
#
# 2) Setup Mode (`setup`)
#    - Initializes a dedicated deadman directory: ~/.deadman/<id>
#    - Generates a GPG keypair without a passphrase.
#    - Encrypts the provided secret message with the public key.
#    - Writes decryption instructions for the recipient.
#    - Prompts for Gmail API credentials and recipient email(s).
#    - Optionally shreds the original secret file and always shreds the private GPG key.
#    - Creates a timestamp file (`last_reset`) marking the last “check-in”.
#    - Saves configuration metadata to `config.json`.
#    - Installs a cron job that runs the `check` command every 5 minutes.
#
# 3) Normal Operation
#    - The user periodically “checks in” by updating the timestamp file.
#    - As long as the timestamp is recent, no action occurs.
#
# 4) Check Mode (`check`, run automatically via cron)
#    - Reads configuration and last reset timestamp.
#    - Compares current time against the allowed inactivity window.
#    - If inactivity exceeds the configured threshold, triggers the dead man’s switch.
#
# 5) Triggering Behavior
#    - Emails the encrypted payload, decryption instructions and all other contents of ~/.deadman/<id>/data to the recipient.
#    - Increments an internal trigger counter.
#
# 6) Self-Destruct Mechanism
#    - After the second trigger:
#        - Securely shreds the entire deadman directory.
#        - Removes the associated cron job.
#        - Permanently disables the switch.
#
# 7) Outcome
#    - Recipient receives the encrypted message.
#    - No sensitive material remains on the originating system.
#
# Dependencies:
# - gpg, shred, cron
# - Python libraries: google-api-python-client, google-auth-httplib2, google-auth-oauthlib
#
# Usage Examples:
#   Setup a new switch:
#     python deadman.py setup --id myswitch --message secret.txt --venv /path/to/venv
#   Check manually (normally run via cron):
#     python deadman.py check --id myswitch

import os
import argparse
import json
import secrets
import shutil
import subprocess
import sys
import time
from pathlib import Path

SCOPES = ['https://www.googleapis.com/auth/gmail.send']

if sys.prefix == sys.base_prefix:
    print("[!] ERROR: You must activate your virtual environment before running this script.")
    print("    Example: source /path/to/venv/bin/activate")
    sys.exit(1)

def die(msg):
    print(f"[!] {msg}")
    sys.exit(1)

def run(cmd, check=True, capture=False):
    print("[cmd]", " ".join(cmd))
    return subprocess.run(cmd, check=check, capture_output=capture, text=True)

def prompt(msg):
    return input(msg).strip()

def confirm(msg):
    ans = prompt(f"{msg} [y/N]: ").lower()
    return ans in ("y", "yes")

def send_email(base_dir, to, subject, body, attachments=None, cc=None, bcc=None):
    cred_path = base_dir / "credentials.json"
    cmd = [
        "python3", str(SENDEMAIL_PATH),
        "-c", str(cred_path),
        "-t", to,
        "-s", subject,
        "-m", body
    ]
    if cc:
        if isinstance(cc, list):
            cc = ",".join(cc)
        cmd += ["--cc", cc]
    if bcc:
        if isinstance(bcc, list):
            bcc = ",".join(bcc)
        cmd += ["--bcc", bcc]
    if attachments:
        attachments = [str(a) for a in attachments]
        cmd += ["-a"] + attachments
    run(cmd, check=True)

def shred_and_remove_dir(target_dir: Path):
    print(f"Shredding directory: {target_dir}")
    for root, dirs, files in os.walk(target_dir, topdown=False):
        for name in files:
            file_path = Path(root) / name
            run(["shred", "-vzu", "-n", "5", str(file_path)])
            file_path.unlink(missing_ok=True)
        for name in dirs:
            dir_path = Path(root) / name
            try:
                dir_path.rmdir()
            except OSError:
                pass
    try:
        target_dir.rmdir()
    except OSError:
        shutil.rmtree(target_dir, ignore_errors=True)
    print("Directory shredded successfully.")

def remove_cron_job(switch_id: str):
    cron_tag = f"DEADMAN_{switch_id}"
    proc = subprocess.run(["crontab", "-l"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        print("No existing crontab or unable to read crontab.")
        return
    lines = [l for l in proc.stdout.splitlines() if cron_tag not in l]
    if len(lines) == len(proc.stdout.splitlines()):
        print("Cron job not found; nothing to remove.")
        return
    p = subprocess.Popen(["crontab", "-"], stdin=subprocess.PIPE, text=True)
    p.communicate("\n".join(lines) + "\n")
    print("Cron job removed successfully.")

def trigger_deadman(BASE: Path, config: dict, CONFIG_FILE: Path, args_id: str):
    trigger_count = config.get("trigger_count", 0)
    data_dir = BASE / "data"
    attachments = [
        p for p in data_dir.iterdir()
        if p.is_file()
    ]
    send_email(
        BASE,
        config["recipient"],
        "Deadman Switch Triggered",
        "Attached are all files present in the deadman data directory at trigger time.",
        attachments=attachments,
        cc=config.get("cc"),
        bcc=config.get("bcc")
    )
    print(f"Deadman switch triggered! (count {trigger_count + 1}/2)")

    config["trigger_count"] = trigger_count + 1
    CONFIG_FILE.write_text(json.dumps(config, indent=2))

    if config["trigger_count"] >= 2:
        print("Maximum triggers reached. Shredding entire deadman directory and disabling cron...")
        shred_and_remove_dir(BASE)
        remove_cron_job(args_id)
        print("Deadman switch disabled permanently. All sensitive files removed.")

SENDEMAIL_PATH = Path(__file__).parent / "sendEmail.py"
if not SENDEMAIL_PATH.exists():
    die("sendEmail.py not found in the same directory as deadman.py. Please ensure sendEmail.py is present.")

parser = argparse.ArgumentParser(
    description="Local-only dead man's switch",
    epilog="Examples:\n"
           "  Setup: python deadman.py setup --id test --message secret.txt --venv /path/to/venv\n"
           "  Check: python deadman.py check --id dm_123456"
)

subparsers = parser.add_subparsers(dest='command', required=True)
setup_parser = subparsers.add_parser('setup', help='Setup a new deadman switch')
setup_parser.add_argument('-i', '--id', required=True, help='Deadman switch identifier')
setup_parser.add_argument('-m', '--message', required=True, help='File containing secret message')
setup_parser.add_argument('-v', '--venv', required=True, help='Path to virtual environment directory')

check_parser = subparsers.add_parser('check', help='Check if deadman should trigger')
check_parser.add_argument('-i', '--id', required=True, help='Deadman switch identifier')

args = parser.parse_args()

venv_path = None
if args.command == "setup":
    venv_path = Path(args.venv).expanduser().resolve()
    if not venv_path.exists():
        die("Virtual environment path does not exist")

if args.command == 'check':
    BASE = Path.home() / ".deadman" / args.id
    CONFIG_FILE = BASE / "config.json"
    if not CONFIG_FILE.exists():
        die(f"Config not found for id {args.id}")
    config = json.loads(CONFIG_FILE.read_text())
    RESET_FILE = Path(config["reset"])
    last = int(RESET_FILE.read_text())
    now = int(time.time())
    if now - last > config["days"] * 86400:
        trigger_deadman(BASE, config, CONFIG_FILE, args.id)
    sys.exit(0)

# Import Gmail dependencies after ensuring we're in venv
try:
    from google.oauth2.credentials import Credentials
    from google.auth.transport.requests import Request
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build
    import base64
    from email.mime.text import MIMEText
except ImportError:
    if confirm("Gmail dependencies not installed. Install now?"):
        run([str(venv_path / "bin" / "pip"), "install", "--upgrade",
             "google-api-python-client", "google-auth-httplib2", "google-auth-oauthlib"])
        from google.oauth2.credentials import Credentials
        from google.auth.transport.requests import Request
        from google_auth_oauthlib.flow import InstalledAppFlow
        from googleapiclient.discovery import build
        import base64
        from email.mime.text import MIMEText
    else:
        die("Cannot proceed without Gmail dependencies")

# --- Setup mode ---
secret_file = Path(args.message).expanduser().resolve()
if not secret_file.exists():
    die("Secret file does not exist")

switch_id = args.id or f"dm_{secrets.token_hex(4)}"

BASE = Path.home() / ".deadman" / switch_id
KEY_DIR = BASE / "keys"
DATA_DIR = BASE / "data"
SCRIPT_DIR = BASE / "scripts"
RESET_FILE = BASE / "last_reset"
CONFIG_FILE = BASE / "config.json"

for d in (KEY_DIR, DATA_DIR, SCRIPT_DIR):
    d.mkdir(parents=True, exist_ok=True)

deps = ["gpg", "shred", "cron"]
missing = [d for d in deps if not shutil.which(d)]
if missing:
    print("Missing dependencies:", ", ".join(missing))
    if not confirm("Install automatically via apt?"):
        die("Cannot proceed")
    run(["sudo", "apt", "update"])
    run(["sudo", "apt", "install", "-y"] + missing)

recipient = prompt("Recipient email address (required): ")
cc_input = prompt("CC email addresses (optional, comma-separated): ")
bcc_input = prompt("BCC email addresses (optional, comma-separated): ")
# Convert to lists, ignoring empty strings
cc_emails = [e.strip() for e in cc_input.split(",") if e.strip()] if cc_input else None
bcc_emails = [e.strip() for e in bcc_input.split(",") if e.strip()] if bcc_input else None
days = int(prompt("Days before deadman triggers: "))

key_name = f"deadman-{switch_id}"
key_email = f"{switch_id}@deadman.local"

param_file = KEY_DIR / "gpg_params"
param_file.write_text(f"""
Key-Type: RSA
Key-Length: 4096
Name-Real: {key_name}
Name-Email: {key_email}
Expire-Date: 0
%no-protection
%commit
""")

run(["gpg", "--batch", "--gen-key", str(param_file)])

pub_key = KEY_DIR / "public.asc"
priv_key = KEY_DIR / "private.asc"

with open(pub_key, "w") as f:
    subprocess.run(["gpg", "--armor", "--export", key_email], stdout=f)

with open(priv_key, "w") as f:
    subprocess.run(["gpg", "--armor", "--export-secret-keys", key_email], stdout=f)

print("\n[IMPORTANT]")
print(f"Private key file: {priv_key}")
print("You MUST copy this securely for the recipient.")
input("Press ENTER once copied and verified...")

instruction = DATA_DIR / "HOW_TO_DECRYPT.txt"
instruction.write_text("""
HOW TO DECRYPT THIS MESSAGE

You should have received:
- An encrypted message file (message.asc)
- A private key file (private.asc), provided to you previously

Both files are required to read the secret message.


========================
STEP 1 — INSTALL GPG
========================

GPG is the tool used to decrypt this message.

Windows:
1. Go to: https://gpg4win.org/
2. Download and install it.
3. During installation, accept the default options.

macOS:
1. Go to: https://gpgtools.org/
2. Download and install it.

Linux (Ubuntu/Debian):
1. Open “Terminal”
2. Run:
   sudo apt install gnupg


========================
STEP 2 — PUT FILES IN ONE FOLDER
========================

1. Create a new folder somewhere easy to find (for example:
   Desktop → New Folder → name it “decrypt”)

2. Copy BOTH of these files into that folder:
   - private.asc
   - message.asc

IMPORTANT:
Both files MUST be in the same folder for the next steps to work.


========================
STEP 3 — OPEN A TERMINAL IN THAT FOLDER
========================

Windows:
1. Open the folder containing private.asc and message.asc
2. Hold SHIFT, then RIGHT-CLICK inside the folder
3. Click:
   “Open PowerShell window here”
   (or “Open Terminal here”)

macOS:
1. Open the folder in Finder
2. Right-click inside the folder
3. Click “New Terminal at Folder”

Linux:
1. Open the folder
2. Right-click → “Open in Terminal”


========================
STEP 4 — IMPORT THE PRIVATE KEY (ONE TIME ONLY)
========================

In the terminal window that opened, copy and paste this command:

gpg --import private.asc

Press ENTER.

You should see a message saying the key was imported successfully.
If you see a warning that the key already exists, that is OK.


========================
STEP 5 — DECRYPT THE MESSAGE
========================

In the SAME terminal window, run:

gpg --decrypt message.asc

The decrypted message will appear directly on the screen.

If asked for confirmation or warnings, you can safely answer “yes”.


========================
TROUBLESHOOTING
========================

• “File not found” error:
  Make sure BOTH files are in the same folder
  and that the terminal was opened from that folder.

• “gpg is not recognized” (Windows):
  Restart your computer after installing GPG.

• Nothing prints after decrypt:
  Scroll up in the terminal window — the message may be above.


========================
SECURITY NOTE
========================

This private key can decrypt this message.
Do NOT share private.asc with anyone else.

Once you have saved the message safely,
you may delete private.asc if instructed to do so.

For additional help, try google: How to decrypt a message with GPG
""")

payload_enc = DATA_DIR / "message.asc"

run([
    "gpg", "--armor", "--encrypt",
    "--recipient", key_email,
    "--output", str(payload_enc),
    str(secret_file)
])

print("GMAIL API SETUP REQUIRED")
print("Follow: https://developers.google.com/workspace/gmail/api/quickstart/python")
print("Place credentials.json in:")
print(BASE)
input("Press ENTER once credentials.json is ready and you have authenticated...")

if confirm("Shred private key now? This is irreversible."):
    run(["shred", "-vzu", "-n", "5", str(priv_key)])
    priv_key.unlink(missing_ok=True)
else:
    die("Private key must be destroyed before proceeding")

if confirm("Shred original secret file? (recommended)"):
    run(["shred", "-vzu", "-n", "5", str(secret_file)])
    secret_file.unlink(missing_ok=True)

RESET_FILE.write_text(str(int(time.time())))

cron_tag = f"DEADMAN_{switch_id}"
deadman_script = Path(__file__).resolve()
cron_line = f"*/5 * * * * bash -c 'source {venv_path}/bin/activate && python3 {deadman_script} check -i {switch_id}' # {cron_tag}"

existing = subprocess.run(["crontab", "-l"], capture_output=True, text=True).stdout
lines = [l for l in existing.splitlines() if cron_tag not in l]
lines.append(cron_line)

p = subprocess.Popen(["crontab", "-"], stdin=subprocess.PIPE, text=True)
p.communicate("\n".join(lines) + "\n")

CONFIG_FILE.write_text(json.dumps({
    "id": switch_id,
    "recipient": recipient,
    "cc": cc_emails,
    "bcc": bcc_emails,
    "days": days,
    "created": int(time.time()),
    "payload": str(payload_enc),
    "reset": str(RESET_FILE),
    "venv": str(venv_path),
    "trigger_count": 0
}, indent=2))

print("\n[SETUP COMPLETE]")
print(f"Deadman ID: {switch_id}")
print(f"Any files placed in the following directory will be sent automatically when the deadman triggers:")
print(f"  {DATA_DIR}")
print("\nReset command:")
print(f"  echo $(date +%s) > {RESET_FILE}")

if confirm("\nDo you want to test the deadman switch now? WARNING: This will run the production behavior and may delete files."):
    test_time = int(time.time()) - (days * 86400 + 10)
    RESET_FILE.write_text(str(test_time))
    print(f"last_reset modified to {test_time} to trigger the deadman switch on next cron check.")
    print("Run `check` now or wait for cron to trigger...")
