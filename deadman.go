// deadman: a local dead man's switch. Stdlib only, no go.mod, no shared code.
//
// It does not send mail itself. It calls sendEmail.go, a standalone
// mailer in the same directory, with a system command. That keeps
// both files usable on their own.
//
// Idea: this machine holds only ciphertext and recipients' public
// keys. The sender generates the keypair, writes the private key
// straight to a clean thumb drive, and hand-delivers it. The private
// key is never printed, never emailed, never stored in the state
// directory, and never copied onto a networked machine. The recipient
// stores the drive offline, unplugged, and never touches it until the
// encrypted blob arrives, then decrypts directly from the drive.
//
// Usage, prefix every command with `go run deadman.go` (or use a
// built binary the same way):
//
//	setup                       # guided if flags are missing: id, secret file,
//	                            # recipients, keys, SMTP, trigger commands,
//	                            # then test, shred, cron
//	setup -id x -msg secret.txt -to alice@example.com -pub alice.pub -days 35 \
//	  -preset gmail -smtp-user you@gmail.com -smtp-pass-file ~/pass.txt
//	keygen -priv /media/thumb/alice.priv -pub alice.pub
//	                            # private goes only to the drive, never printed
//	decrypt -key /media/thumb/alice.priv -in ~/.deadman/x/payload.json
//	                            # verify the drive key decrypts the payload,
//	                            # BEFORE hand delivery, and again years later
//	test -id x                  # test mail, no payload, state unchanged
//	install -id x               # hourly cron for check
//	purge -id x                 # remove cron AND the whole state directory,
//	                            # shredded, not rm, start over from scratch
//	ping -id x                  # check in, resets the clock
//	status -id x                # deadline, mail route, sent flag
//	check -id x                 # what cron runs: payload once overdue, nothing before
//	resend -id x                # resend the payload if a mail is lost to spam
//	configure -id x -sendemail /path/to/sendEmail.go
//	                            # also -preset, -smtp, -smtp-user, -smtp-from,
//	                            # -smtp-pass-file, -smtp-pass-command (ex rotate-smtp)
//
// Paths: ~/ expands to your home directory, and relative paths
// work from the current directory at setup time. The sendEmail
// path is stored absolute, so cron finds it later regardless of
// its working directory.
//
// Setup order: first set up a dedicated sending email and prove
// sendEmail works on its own (dry run, then a real test to yourself
// only), then set up deadman, which needs the SMTP route and
// credential, so it cannot come first. Then test, install cron,
// and ping regularly. A failed send is never marked sent, so the
// next hourly run retries it instead of losing the only copy.
//
// SMTP hints, in short (full steps are in sendEmail.go comments,
// and setup prints the hint for the preset you pick):
//
//	gmail: dedicated account only, 2-Step Verification on, then
//	  Security, App passwords, App Mail, Device Other, name it
//	  deadman, Generate, remove spaces from the 16 characters,
//	  save it with `umask 077`, then `cat > file`, paste, Enter,
//	  Ctrl-D, then `chmod 600 file`. Never use echo (shell
//	  history) and never use the main Google password here.
//	  Username and From are both the dedicated Gmail address.
//	proton: SMTP token, paid plan plus custom domain address only.
//	  Username and From are that address, token is the password.
//	proton-bridge: Bridge must run on this machine, host
//	  127.0.0.1:1025, Bridge password, never the Proton password.
//	smtp2go: address at a domain of your own only, no Gmail or
//	  Yahoo signup. Verify the sender domain in DNS, then create
//	  an SMTP user just for deadman. From must be at that domain.
//	sendgrid: username is literally apikey, API key is Mail Send
//	  only, From must be a verified sender. Free SendGrid is now
//	  a trial in recent reports, do not rely on it for years.
//	mailgun: per-domain SMTP password, username usually
//	  postmaster@your-domain, From must be at that domain.
//	outlook: app password only if MFA is on and SMTP AUTH is on.
//	  Many personal Outlook accounts now require OAuth2 only,
//	  which sendEmail does not do, so this is best-effort.
//	Any other provider: -smtp host:port, 587 STARTTLS, 465
//	  implicit TLS. Never store a main password in plaintext;
//	  use a scoped, revocable token that can only send mail.
//	  A dedicated sending account makes even a mail-reading
//	  credential harmless, because its mailbox holds nothing.
//
// Keys and shredding: setup never deletes your files with rm.
// After a successful setup and test mail, it asks whether to
// shred the original secret file, password file, and any
// temporary private key copy. Shredding overwrites with random
// data (3 passes), then zeros, syncs, and removes.
// Honest limit: on SSDs and flash, wear leveling can keep old
// copies in blocks the OS cannot reach, so shredding reduces
// exposure but does not guarantee erasure. Writing the secret
// to a RAM disk, for example /dev/shm/secret.txt, before setup
// avoids that problem entirely.
//
// Trigger commands, optional: -trigger-cmd runs before the
// payload is sent, -after-send-cmd runs after a successful send.
// Warnings never run them, resend never re-runs them, a failing
// before-send hook does not block the payload, and an after-send
// hook runs only after sent is recorded, so its failure cannot
// cause a duplicate send. Hooks must be idempotent, and must
// not delete payload.json, smtp_pass, sendEmail, or the state
// directory before the send. Wiping the switch itself belongs
// in the after-send hook.
//
// State lives in ~/.deadman/<id>/: config.json, state.json,
// payload.json (ciphertext only), smtp_pass (0600, if a password
// file is used). If the machine running cron dies, nothing sends.
// A second independent machine with the same state directory is
// the mitigation, a duplicate ciphertext send is harmless.
// If a recipient private key is lost, that message is lost.
package main

import (
	"bufio"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

func die(err error) {
	fmt.Fprintln(os.Stderr, "deadman:", err)
	os.Exit(1)
}

func dief(format string, a ...any) { die(fmt.Errorf(format, a...)) }

// ---------- small helpers ----------

func baseDir(id string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	if strings.ContainsAny(id, "/\\") || id == "" || id == "." || id == ".." {
		return "", fmt.Errorf("bad id %q", id)
	}
	return filepath.Join(home, ".deadman", id), nil
}

func writeFile(path string, data []byte, perm os.FileMode) error {
	if err := os.WriteFile(path+".tmp", data, perm); err != nil {
		return err
	}
	return os.Rename(path+".tmp", path)
}

// expandPath expands a leading ~/ to the user's home directory.
// Relative paths already work (they are relative to the current
// directory at run time), but ~/ does not, because only the shell
// expands it, and a program reading typed input never sees the
// shell do that. This makes ~/deadman/secret.txt work in setup
// prompts and in flags, exactly as typed in a shell would.
func expandPath(p string) string {
	if p == "~" {
		if home, err := os.UserHomeDir(); err == nil {
			return home
		}
		return p
	}
	if len(p) > 2 && p[:2] == "~/" {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, p[2:])
		}
	}
	return p
}

func writeJSON(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return writeFile(path, append(b, '\n'), 0600)
}

func validEmail(s string) bool {
	return strings.Contains(s, "@") && !strings.ContainsAny(s, " \r\n\t<>") && len(s) > 3
}

// keyArg accepts a bare hex key, a key file path, or @file
// containing one. The @ is optional and kept for backward
// compatibility, so a recipient can simply type the filename
// they see on the stick, without remembering a special prefix.
// A bare path wins if a file with that name exists, which is
// safe because a 64-character hex key is almost never also a
// filename in the working directory.
func readKey(arg string) ([]byte, error) {
	s := strings.TrimSpace(arg)
	if strings.HasPrefix(s, "@") {
		s = strings.TrimPrefix(s, "@")
	}
	if info, err := os.Stat(expandPath(s)); err == nil && !info.IsDir() {
		b, err := os.ReadFile(expandPath(s))
		if err != nil {
			return nil, err
		}
		s = strings.TrimSpace(string(b))
	}
	// Tolerate "private: <hex>" style files: take the last field.
	if f := strings.Fields(s); len(f) > 1 {
		s = f[len(f)-1]
	}
	b, err := hex.DecodeString(s)
	if err != nil || len(b) != 32 {
		return nil, fmt.Errorf("key must be 32 bytes hex or a key file path")
	}
	return b, nil
}

// ---------- crypto: X25519 + AES-256-GCM, one random DEK ----------

type wrappedKey struct {
	To      string `json:"to"`
	Eph     string `json:"eph"` // ephemeral public key, base64
	Nonce   string `json:"nonce"`
	Wrapped string `json:"wrapped"` // DEK, base64
}

type envelope struct {
	V     int          `json:"v"`
	Nonce string       `json:"nonce"`
	CT    string       `json:"ct"`
	Keys  []wrappedKey `json:"keys"`
}

func gcm(key []byte) (cipher.AEAD, error) {
	b, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(b)
}

func seal(key, plaintext []byte) (nonce, ct []byte, err error) {
	a, err := gcm(key)
	if err != nil {
		return nil, nil, err
	}
	nonce = make([]byte, a.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, nil, err
	}
	return nonce, a.Seal(nil, nonce, plaintext, nil), nil
}

func open(key, nonce, ct []byte) ([]byte, error) {
	a, err := gcm(key)
	if err != nil {
		return nil, err
	}
	return a.Open(nil, nonce, ct, nil)
}

func wrapKey(ephPriv, recipPub []byte) []byte {
	priv, _ := ecdh.X25519().NewPrivateKey(ephPriv)
	pub, _ := ecdh.X25519().NewPublicKey(recipPub)
	shared, _ := priv.ECDH(pub)
	ephPub := priv.PublicKey().Bytes()
	h := sha256.New()
	h.Write(shared)
	h.Write(ephPub)
	h.Write(recipPub)
	return h.Sum(nil)
}

func encrypt(plaintext []byte, recipients []string, pubkeys [][]byte) (*envelope, error) {
	dek := make([]byte, 32)
	if _, err := rand.Read(dek); err != nil {
		return nil, err
	}
	nonce, ct, err := seal(dek, plaintext)
	if err != nil {
		return nil, err
	}
	env := &envelope{V: 1, Nonce: base64.StdEncoding.EncodeToString(nonce),
		CT: base64.StdEncoding.EncodeToString(ct)}
	for i, pub := range pubkeys {
		eph, err := ecdh.X25519().GenerateKey(rand.Reader)
		if err != nil {
			return nil, err
		}
		wk := wrapKey(eph.Bytes(), pub)
		wn, wrapped, err := seal(wk, dek)
		if err != nil {
			return nil, err
		}
		env.Keys = append(env.Keys, wrappedKey{
			To: recipients[i], Eph: base64.StdEncoding.EncodeToString(eph.PublicKey().Bytes()),
			Nonce:   base64.StdEncoding.EncodeToString(wn),
			Wrapped: base64.StdEncoding.EncodeToString(wrapped),
		})
	}
	return env, nil
}

func decrypt(priv []byte, env *envelope) ([]byte, error) {
	ct, err := base64.StdEncoding.DecodeString(env.CT)
	if err != nil {
		return nil, err
	}
	nonce, err := base64.StdEncoding.DecodeString(env.Nonce)
	if err != nil {
		return nil, err
	}
	for _, k := range env.Keys {
		eph, err := base64.StdEncoding.DecodeString(k.Eph)
		if err != nil {
			continue
		}
		wn, err := base64.StdEncoding.DecodeString(k.Nonce)
		if err != nil {
			continue
		}
		wrapped, err := base64.StdEncoding.DecodeString(k.Wrapped)
		if err != nil {
			continue
		}
		// wrapKey is symmetric in the two private keys: recompute with
		// our private key and their ephemeral public key.
		p, _ := ecdh.X25519().NewPrivateKey(priv)
		q, _ := ecdh.X25519().NewPublicKey(eph)
		shared, _ := p.ECDH(q)
		h := sha256.New()
		h.Write(shared)
		h.Write(eph)
		h.Write(privPublic(priv))
		wk := h.Sum(nil)
		dek, err := open(wk, wn, wrapped)
		if err != nil {
			continue
		}
		if pt, err := open(dek, nonce, ct); err == nil {
			return pt, nil
		}
	}
	return nil, fmt.Errorf("no key entry decrypted (wrong private key?)")
}

func privPublic(priv []byte) []byte {
	p, _ := ecdh.X25519().NewPrivateKey(priv)
	return p.PublicKey().Bytes()
}

func pubFingerprint(pub []byte) string {
	sum := sha256.Sum256(pub)
	return hex.EncodeToString(sum[:])
}

// ---------- config / state ----------

type config struct {
	ID             string   `json:"id"`
	Recipients     []string `json:"recipients"`
	PubKeys        []string `json:"pubkeys"` // hex
	Days           int      `json:"days"`
	Created        int64    `json:"created"`
	SMTPHost       string   `json:"smtp_host"`   // generic host, or "" when a preset is used
	SMTPPreset     string   `json:"smtp_preset"` // e.g. gmail, proton-bridge; resolved by sendEmail.go
	SMTPUser       string   `json:"smtp_user"`
	SMTPFrom       string   `json:"smtp_from"`
	SMTPPass       string   `json:"smtp_pass_file"`    // path in state dir, "" if none
	SMTPPassCmd    string   `json:"smtp_pass_command"` // command whose stdout is the password; "" if a file is used
	CC             []string `json:"cc"`
	BCC            []string `json:"bcc"`
	SenderPath     string   `json:"sendemail_path"`      // absolute path to sendEmail binary or .go, "" = auto-discover
	TriggerCmd     string   `json:"trigger_command"`     // runs before the payload is sent, "" = none
	TriggerTimeout int      `json:"trigger_timeout_sec"` // 0 = 120
	AfterSendCmd   string   `json:"after_send_command"`  // runs after a successful send, "" = none
}

type state struct {
	LastPing int64 `json:"last_ping"`
	Sent     bool  `json:"sent"`
	SentAt   int64 `json:"sent_at"`
}

func loadConfig(dir string) (*config, error) {
	b, err := os.ReadFile(filepath.Join(dir, "config.json"))
	if err != nil {
		return nil, err
	}
	var c config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, err
	}
	return &c, nil
}

// Missing or corrupt state must not silently disable the switch.
// Fall back to the creation time (fail-open) and say so loudly.
func loadState(dir string, created int64) (*state, bool) {
	b, err := os.ReadFile(filepath.Join(dir, "state.json"))
	if err != nil {
		fmt.Fprintf(os.Stderr, "deadman: state unreadable (%v), falling back to creation time\n", err)
		return &state{LastPing: created}, false
	}
	var s state
	if err := json.Unmarshal(b, &s); err != nil || s.LastPing == 0 {
		fmt.Fprintf(os.Stderr, "deadman: state corrupt, falling back to creation time\n")
		return &state{LastPing: created}, false
	}
	return &s, true
}

func saveState(dir string, s *state) error { return writeJSON(filepath.Join(dir, "state.json"), s) }

// ---------- commands ----------

func cmdKeygen(fs *flag.FlagSet) {
	privOut := fs.String("priv", "", "file to write the private key to, e.g. a file on a freshly formatted thumb drive (required)")
	pubOut := fs.String("pub", "", "file to write the public key to; if omitted, the public key is printed (it is not secret)")
	fs.Parse(os.Args[2:])
	*privOut = expandPath(*privOut)
	*pubOut = expandPath(*pubOut)
	if *privOut == "" {
		dief("keygen needs -priv <file>: private keys are never printed to the terminal, because terminal scrollback and shell history are leak paths. Write it straight to the thumb drive, e.g. -priv /media/thumb/alice.priv")
	}
	if *privOut == *pubOut {
		dief("-priv and -pub must be different files")
	}
	absPriv, err := filepath.Abs(*privOut)
	if err != nil {
		die(err)
	}
	if home, err := os.UserHomeDir(); err == nil {
		if strings.HasPrefix(absPriv, filepath.Join(home, ".deadman")+string(os.PathSeparator)) {
			dief("refusing to write a private key into ~/.deadman: it must live only on the thumb drive, never in the switch state")
		}
	}
	if _, err := os.Stat(filepath.Dir(absPriv)); err != nil {
		dief("private output directory does not exist (is the thumb drive mounted?): %s", filepath.Dir(absPriv))
	}
	priv, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		die(err)
	}
	ph, qh := hex.EncodeToString(priv.Bytes()), hex.EncodeToString(priv.PublicKey().Bytes())
	if err := writeFile(*privOut, []byte(ph+"\n"), 0600); err != nil {
		die(err)
	}
	if *pubOut != "" {
		if err := os.WriteFile(*pubOut, []byte(qh+"\n"), 0644); err != nil {
			die(err)
		}
		fmt.Printf("private written to %s (0600, never printed, never emailed)\n", *privOut)
		fmt.Printf("public written to %s\n", *pubOut)
	} else {
		fmt.Printf("private written to %s (0600, never printed, never emailed)\n", *privOut)
		fmt.Println("public (safe to share with the sender):")
		fmt.Println(qh)
	}
	fmt.Printf("public fingerprint: %s\n", pubFingerprint(priv.PublicKey().Bytes()))
	fmt.Println("Verify this key decrypts the payload before hand delivery, then unmount the drive and hand deliver it.")
}

type strList []string

func (s *strList) String() string     { return strings.Join(*s, ",") }
func (s *strList) Set(v string) error { *s = append(*s, v); return nil }

func splitComma(values []string) []string {
	var out []string
	for _, v := range values {
		for _, e := range strings.Split(v, ",") {
			if e = strings.TrimSpace(e); e != "" {
				out = append(out, e)
			}
		}
	}
	return out
}

// locateSendEmail finds the standalone sender. Priority: the
// DEADMAN_SENDEMAIL env var, a built sendEmail binary next to this
// program, sendEmail.go next to this program, then the same two in
// the working directory. Under `go run deadman.go` the executable
// is a temp binary, so the working directory case is the usual one.
func senderArgv(path string) ([]string, error) {
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return nil, fmt.Errorf("sendEmail not found at %s", path)
	}
	if strings.HasSuffix(path, ".go") {
		return []string{"go", "run", path}, nil
	}
	return []string{path}, nil
}

// Sender lookup order: an explicit path first (a -sendemail flag, or
// the path stored at setup), then DEADMAN_SENDEMAIL, then a built
// binary or .go file next to the deadman executable, then the same
// in the working directory. The stored path is what makes a sender
// in another directory work from cron, where env vars are not set.
func locateSendEmail(preferred string) ([]string, error) {
	if preferred != "" {
		return senderArgv(preferred)
	}
	if env := os.Getenv("DEADMAN_SENDEMAIL"); env != "" {
		return senderArgv(env)
	}
	var candidates []string
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		candidates = append(candidates,
			filepath.Join(dir, "sendEmail"), filepath.Join(dir, "sendEmail.exe"),
			filepath.Join(dir, "sendEmail.go"))
	}
	if wd, err := os.Getwd(); err == nil {
		candidates = append(candidates,
			filepath.Join(wd, "sendEmail"), filepath.Join(wd, "sendEmail.exe"),
			filepath.Join(wd, "sendEmail.go"))
	}
	for _, cand := range candidates {
		if argv, err := senderArgv(cand); err == nil {
			return argv, nil
		}
	}
	return nil, fmt.Errorf("sendEmail not found: run from the directory containing sendEmail.go, place a built sendEmail binary next to deadman, set DEADMAN_SENDEMAIL=/path/to/sendEmail.go, or store a path with setup -sendemail /abs/path or configure -sendemail /abs/path")
}

// callSendEmail shells out to the standalone sender. A failure here
// is returned, never hidden, so callers never mark a mail as sent
// when it was not.
func callSendEmail(c *config, senderOverride, subject, body, attachPath, attachName string) error {
	preferred := senderOverride
	if preferred == "" {
		preferred = c.SenderPath
	}
	argv, err := locateSendEmail(preferred)
	if err != nil {
		return err
	}
	args := append([]string{}, argv[1:]...)
	args = append(args, "-to", strings.Join(c.Recipients, ", "))
	if c.SMTPPreset != "" {
		args = append(args, "-preset", c.SMTPPreset)
	} else if c.SMTPHost != "" {
		args = append(args, "-smtp", c.SMTPHost)
	}
	if c.SMTPUser != "" {
		args = append(args, "-smtp-user", c.SMTPUser)
	}
	if c.SMTPFrom != "" {
		args = append(args, "-smtp-from", c.SMTPFrom)
	}
	if c.SMTPPassCmd != "" {
		args = append(args, "-smtp-pass-command", c.SMTPPassCmd)
	} else if c.SMTPPass != "" {
		args = append(args, "-smtp-pass-file", c.SMTPPass)
	}
	if len(c.CC) > 0 {
		args = append(args, "-cc", strings.Join(c.CC, ","))
	}
	if len(c.BCC) > 0 {
		args = append(args, "-bcc", strings.Join(c.BCC, ","))
	}
	args = append(args, "-subject", subject, "-message", body)
	if attachPath != "" {
		args = append(args, "-a", attachPath)
		if attachName != "" {
			args = append(args, "-a-name", attachName)
		}
	}
	cmd := exec.Command(argv[0], args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("sendEmail failed: %s", strings.TrimSpace(string(out)))
	}
	return nil
}

// runHook runs a user trigger command through sh. It is trusted
// (it comes from your own config), it gets the switch id, state dir,
// payload path, and recipients in the environment, and it never has
// its command string printed, in case it contains a secret. A
// failure is returned to the caller, which decides whether to
// continue; the payload send is never silently skipped because of it.
func runHook(c *config, dir, payloadPath, cmdStr string, timeoutSec int, label string) error {
	if cmdStr == "" {
		return nil
	}
	if timeoutSec <= 0 {
		timeoutSec = 120
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutSec)*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "sh", "-c", cmdStr)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	cmd.Env = append(os.Environ(),
		"DEADMAN_ID="+c.ID,
		"DEADMAN_DIR="+dir,
		"DEADMAN_PAYLOAD="+payloadPath,
		"DEADMAN_RECIPIENTS="+strings.Join(c.Recipients, ","),
		"DEADMAN_TRIGGER="+label,
	)
	if err := cmd.Run(); err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return fmt.Errorf("%s hook timed out after %d seconds", label, timeoutSec)
		}
		return err
	}
	return nil
}

func cmdSetup(fs *flag.FlagSet) {
	id := fs.String("id", "", "switch id")
	msg := fs.String("msg", "", "file with the secret message (read once, never stored in plaintext)")
	days := fs.Int("days", 35, "days without a check-in before triggering; 0 = send on next check")
	smtpHost := fs.String("smtp", "", "SMTP host:port, e.g. mail.example.com:587 (465 = implicit TLS)")
	preset := fs.String("preset", "", "SMTP preset instead of -smtp; run `go run sendEmail.go -preset list` to list them")
	var ccFlag, bccFlag strList
	fs.Var(&ccFlag, "cc", "cc email (repeatable)")
	fs.Var(&bccFlag, "bcc", "bcc email (repeatable)")
	smtpUser := fs.String("smtp-user", "", "SMTP username (empty = no auth, e.g. local relay)")
	smtpFrom := fs.String("smtp-from", "", "From address (default: smtp-user)")
	smtpPassFile := fs.String("smtp-pass-file", "", "file containing the SMTP password (copied to state dir, 0600)")
	smtpPassCmd := fs.String("smtp-pass-command", "", "command whose stdout is the SMTP password, e.g. 'secret-tool lookup deadman smtp'; instead of -smtp-pass-file")
	sendEmailPath := fs.String("sendemail", "", "absolute path to sendEmail binary or sendEmail.go, if it lives in another directory (stored, so cron finds it)")
	triggerCmd := fs.String("trigger-cmd", "", "command or script run before the payload is sent on trigger, e.g. 'sh /home/you/cleanup.sh'")
	triggerTimeout := fs.Int("trigger-timeout", 0, "seconds to allow the trigger command; 0 = 120")
	afterSendCmd := fs.String("after-send-cmd", "", "command or script run after a successful payload send, e.g. 'sh /home/you/wipe.sh'")
	var to, pubs strList
	fs.Var(&to, "to", "recipient email (repeatable)")
	fs.Var(&pubs, "pub", "recipient public key hex or .pub file, never a private .key/.priv file (repeatable, one per -to)")
	fs.Parse(os.Args[2:])
	*msg = expandPath(*msg)
	*smtpPassFile = expandPath(*smtpPassFile)
	*sendEmailPath = expandPath(*sendEmailPath)
	// Guided setup: any required flag left out is asked for here,
	// so `go run deadman.go setup` with no flags walks you through
	// id, secret file, recipients, keys, and SMTP, in that order.
	// Flag mode is unchanged: give all flags and no prompt appears
	// until the optional test, shred, and cron steps at the end.
	var genPrivPaths []string
	if *id == "" {
		*id = ask("Switch id", "myswitch")
		for !wizValidID(*id) {
			fmt.Println("id must not be empty and must not contain spaces or slashes")
			*id = ask("Switch id", "myswitch")
		}
	}
	if *msg == "" {
		*msg = ask("Secret message file path", "")
	}
	// Expiry: asked in setup, not just a flag, so a test switch can
	// be set to something other than 35 days. askTail is EOF-safe,
	// so flag mode with stdin closed keeps the flag value.
	if s := askTail(fmt.Sprintf("Expiry in days [%d] (Enter to keep, 0 sends on next check)", *days)); s != "" {
		if n, err := strconv.Atoi(s); err == nil && n >= 0 {
			*days = n
		} else {
			fmt.Printf("using %d days\n", *days)
		}
	}
	guided := len(to) == 0 || len(pubs) < len(to)
	promptEmail := func() string {
		for {
			email := ask("Recipient email", "")
			if validEmail(email) {
				return email
			}
			fmt.Println("that does not look like an email address")
		}
	}
	promptKey := func(email string) {
		choice := ask("For "+email+": generate a new keypair, or use an existing public key? [generate/existing]", "generate")
		if choice == "existing" || choice == "e" || choice == "pub" {
			for {
				arg := ask("Public key hex or .pub file (never the private .key/.priv file)", "")
				if _, err := readKey(arg); err == nil {
					pubs = append(pubs, arg)
					break
				}
				fmt.Println("bad public key, try again")
			}
		} else {
			var privPath string
			for {
				privPath = ask("Private key file path (ideally on a thumb drive, e.g. /media/thumb/alice.priv)", "")
				qh, fp, err := generateKey(privPath)
				if err == nil {
					pubs = append(pubs, qh)
					genPrivPaths = append(genPrivPaths, privPath)
					fmt.Printf("Public fingerprint for %s: %s\n", email, fp)
					fmt.Println("Write that fingerprint down, label the drive with it only, never email the private key.")
					break
				}
				fmt.Printf("key generation failed: %v\n", err)
				fmt.Println("mount the thumb drive first, or pick a directory that exists")
			}
		}
	}
	if len(to) == 0 {
		to = append(to, promptEmail())
	}
	for len(pubs) < len(to) {
		promptKey(to[len(pubs)])
	}
	// Only ask this in guided mode. Flag mode with complete -to/-pub
	// never prompts here, so scripted setup with stdin closed still works.
	// Bug fixed 2026-10-29: the old loop exited as soon as to and pubs
	// balanced, so answering yes to Add another never prompted for
	// a second email. This loop actually prompts for it.
	if guided {
		for askYes("Add another recipient", false) {
			to = append(to, promptEmail())
			promptKey(to[len(to)-1])
		}
	}
	if *preset == "" && *smtpHost == "" {
		*preset = ask("SMTP preset (gmail, smtp2go, proton, proton-bridge, sendgrid, mailgun, outlook, other)", "gmail")
		if *preset == "other" {
			*preset = ""
			*smtpHost = ask("Custom SMTP host:port, e.g. mail.example.com:587", "")
		}
	}
	if *smtpUser == "" {
		*smtpUser = ask("SMTP username", "")
	}
	if *smtpFrom == "" {
		*smtpFrom = ask("From address", *smtpUser)
	}
	if *smtpPassFile == "" && *smtpPassCmd == "" {
		fmt.Println(smtpHint(*preset))
		fmt.Println("Save the credential to a file first, with `umask 077`, then `cat > file`, paste, Enter, Ctrl-D, then `chmod 600 file`. Do NOT use echo, and do NOT type the credential at a prompt, that would echo it.")
		for {
			*smtpPassFile = ask("Password/token file path (Enter for no auth, e.g. local relay)", "")
			if *smtpPassFile == "" {
				break
			}
			if _, err := os.Stat(expandPath(*smtpPassFile)); err == nil {
				break
			}
			fmt.Println("that file does not exist")
		}
	}
	// Trigger commands: only asked if not already given as flags.
	// askTail returns "" on EOF, so scripted flag setup with stdin
	// closed simply keeps them unset, instead of failing.
	// If you already have a switch, you do not need to re-setup to
	// add these: configure -id x -trigger-cmd ... -after-send-cmd ...
	// does it without re-encrypting or resetting the clock.
	if *triggerCmd == "" {
		*triggerCmd = askTail("Trigger command to run before the payload is sent (Enter for none, e.g. sh /home/you/cleanup.sh)")
		if *triggerCmd != "" && *triggerTimeout == 0 {
			s := askTail("Trigger command timeout in seconds [120]")
			if s != "" {
				if n, err := strconv.Atoi(s); err == nil && n > 0 {
					*triggerTimeout = n
				} else {
					fmt.Println("using 120 seconds")
				}
			}
		}
	}
	if *afterSendCmd == "" {
		*afterSendCmd = askTail("After-send command to run after a successful send (Enter for none, e.g. sh /home/you/wipe.sh)")
	}
	if len(to) != len(pubs) {
		dief("need one -pub per -to (%d vs %d)", len(to), len(pubs))
	}
	if *days < 0 {
		dief("days must be >= 0")
	}
	if *preset != "" && *smtpHost != "" {
		dief("use either -preset or -smtp, not both")
	}
	if *triggerTimeout < 0 {
		dief("trigger-timeout must be >= 0")
	}
	senderAbs := ""
	if *sendEmailPath != "" {
		abs, err := filepath.Abs(expandPath(*sendEmailPath))
		if err != nil {
			die(err)
		}
		if _, err := senderArgv(abs); err != nil {
			die(err)
		}
		senderAbs = abs
	}
	if *preset != "" {
		if _, err := locateSendEmail(senderAbs); err != nil {
			for {
				s := ask("sendEmail path (binary or sendEmail.go, absolute path is best)", "")
				if abs, err := filepath.Abs(expandPath(s)); err == nil {
					if _, err := senderArgv(abs); err == nil {
						senderAbs = abs
						break
					}
				}
				fmt.Println("that sendEmail path does not exist")
			}
		}
	}
	ccList := splitComma(ccFlag)
	bccList := splitComma(bccFlag)
	for _, e := range append(append([]string{}, ccList...), bccList...) {
		if !validEmail(e) {
			dief("bad email address %q", e)
		}
	}
	for _, r := range to {
		if !validEmail(r) {
			dief("bad recipient %q", r)
		}
	}
	var pubkeys [][]byte
	var pubHex []string
	for _, p := range pubs {
		b, err := readKey(p)
		if err != nil {
			die(err)
		}
		pubkeys = append(pubkeys, b)
		pubHex = append(pubHex, hex.EncodeToString(b))
	}
	plain, err := os.ReadFile(expandPath(*msg))
	if err != nil {
		die(err)
	}
	if len(plain) == 0 {
		dief("message file is empty")
	}
	dir, err := baseDir(*id)
	if err != nil {
		die(err)
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		die(err)
	}
	env, err := encrypt(plain, to, pubkeys)
	if err != nil {
		die(err)
	}
	payload, err := json.MarshalIndent(env, "", "  ")
	if err != nil {
		die(err)
	}
	if err := writeFile(filepath.Join(dir, "payload.json"), append(payload, '\n'), 0600); err != nil {
		die(err)
	}
	if *smtpPassFile != "" && *smtpPassCmd != "" {
		dief("use either -smtp-pass-file or -smtp-pass-command, not both")
	}
	c := &config{ID: *id, Recipients: to, PubKeys: pubHex, Days: *days,
		Created: time.Now().Unix(), SMTPHost: *smtpHost, SMTPPreset: *preset,
		SMTPUser: *smtpUser, SMTPFrom: *smtpFrom, CC: ccList, BCC: bccList, SMTPPassCmd: *smtpPassCmd,
		SenderPath: senderAbs, TriggerCmd: *triggerCmd, TriggerTimeout: *triggerTimeout, AfterSendCmd: *afterSendCmd}
	if *smtpPassFile != "" {
		b, err := os.ReadFile(expandPath(*smtpPassFile))
		if err != nil {
			die(err)
		}
		dst := filepath.Join(dir, "smtp_pass")
		if err := writeFile(dst, []byte(strings.TrimSpace(string(b))+"\n"), 0600); err != nil {
			die(err)
		}
		c.SMTPPass = dst
		if info, err := os.Stat(expandPath(*smtpPassFile)); err == nil && info.Mode().Perm()&0077 != 0 {
			fmt.Printf("warning: original password file %s is readable by group/other; shred it after a successful test, do not just rm it\n", *smtpPassFile)
		}
	}
	if err := writeJSON(filepath.Join(dir, "config.json"), c); err != nil {
		die(err)
	}
	if err := saveState(dir, &state{LastPing: c.Created}); err != nil {
		die(err)
	}
	for i, h := range pubHex {
		if b, err := hex.DecodeString(h); err == nil {
			fmt.Printf("public fingerprint for %s: %s\n", to[i], pubFingerprint(b))
		}
	}
	fmt.Printf("setup complete: %s (deadline %d days, %d recipient(s))\n", dir, *days, len(to))
	if *days == 0 {
		fmt.Println("WARNING: expiry is 0 days, the next check will send the payload immediately. Only use this for a test switch.")
	}
	fmt.Printf("verify BEFORE hand delivery (proves the thumb-drive key decrypts this payload):\n  go run deadman.go decrypt -key <thumb-drive private file> -in %s\n", filepath.Join(dir, "payload.json"))
	fmt.Println("then unmount the drive and hand deliver it. The private key must never be emailed, and must never be copied onto this machine.")
	if senderAbs != "" {
		fmt.Printf("sendEmail stored: %s (cron will use it even from another directory)\n", senderAbs)
	}
	if *triggerCmd != "" {
		fmt.Println("trigger command set: runs before the payload is sent. Test it by running it yourself, it is an ordinary shell command.")
	}
	if *afterSendCmd != "" {
		fmt.Println("after-send command set: runs after a successful payload send.")
	}
	// Verify generated keys decrypt this payload, before shredding anything.
	verified := true
	for _, privPath := range genPrivPaths {
		priv, err := readKey("@" + privPath)
		if err != nil {
			fmt.Printf("WARNING: cannot read private key %s to verify: %v, do not shred it\n", privPath, err)
			verified = false
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, "payload.json"))
		if err != nil {
			die(err)
		}
		var env2 envelope
		if err := json.Unmarshal(b, &env2); err != nil {
			die(err)
		}
		pt, err := decrypt(priv, &env2)
		if err != nil || string(pt) != string(plain) {
			fmt.Printf("WARNING: private key %s does NOT decrypt this payload, do not shred it, do not hand it out\n", privPath)
			verified = false
			continue
		}
		fmt.Printf("Verified: private key %s decrypts this payload\n", privPath)
	}
	// Optional test, shred, and cron steps. These are skipped, not
	// failed, when stdin is closed, so scripted flag setup still works.
	testOK := false
	if askYesTail("Send a test mail now", true) {
		if err := callSendEmail(c, "", "Deadman switch test (no payload)", "This is a delivery test. No secret is attached and the switch state is unchanged.\n", "", ""); err != nil {
			fmt.Printf("Test mail FAILED: %v\n", err)
			fmt.Println("Original files will NOT be shredded. Fix the SMTP settings with configure, run test again, then shred the originals yourself.")
		} else {
			fmt.Println("Test mail sent.")
			testOK = true
		}
	} else {
		fmt.Printf("Test skipped, run it later with: go run deadman.go test -id %s\n", *id)
	}
	if verified && testOK {
		for _, privPath := range genPrivPaths {
			fmt.Printf("Private key copy: %s\n", privPath)
			fmt.Println("Copy it to a thumb drive or other offline storage if it is not already there, check its fingerprint, then type YES to shred this copy on this machine. Anything else leaves it in place.")
			if strings.ToUpper(askTail("Type YES to shred this private key copy")) == "YES" {
				if err := shredFile(privPath); err != nil {
					fmt.Printf("Shred failed for %s: %v, shred it yourself\n", privPath, err)
				} else {
					fmt.Printf("Shredded: %s\n", privPath)
				}
			} else {
				fmt.Printf("Left in place, NOT shredded: %s\n", privPath)
			}
		}
		var toShred []string
		if *msg != "" {
			toShred = append(toShred, *msg)
		}
		if *smtpPassFile != "" {
			toShred = append(toShred, *smtpPassFile)
		}
		if len(toShred) > 0 && askYesTail("Shred the original secret file and password file now (overwrite, not rm)", true) {
			for _, f := range toShred {
				if err := shredFile(f); err != nil {
					fmt.Printf("Shred failed for %s: %v\n", f, err)
				} else {
					fmt.Printf("Shredded: %s\n", f)
				}
			}
		} else if len(toShred) > 0 {
			fmt.Println("Original files left in place. Shred them yourself, do not just rm them:")
			fmt.Printf("  go run deadman.go shred %s\n", strings.Join(toShred, " "))
		}
	} else {
		fmt.Println("Skipping shred step because verification or test mail did not both succeed.")
		fmt.Println("Shred, do not just rm, the original secret and password files after a successful test:")
		fmt.Printf("  go run deadman.go shred %s %s\n", *msg, *smtpPassFile)
	}
	if askYesTail("Install hourly cron now", true) {
		tag := "DEADMAN_" + *id
		lines, err := cronLines()
		if err != nil {
			die(err)
		}
		kept := lines[:0]
		for _, l := range lines {
			if !strings.Contains(l, tag) {
				kept = append(kept, l)
			}
		}
		kept = append(kept, fmt.Sprintf("0 * * * * %s # %s", cronCommand(*id), tag))
		if err := execInput("crontab", "-", strings.Join(kept, "\n")+"\n"); err != nil {
			die(err)
		}
		fmt.Println("Cron installed: check runs hourly.")
	} else {
		fmt.Printf("Install later with: go run deadman.go install -id %s\n", *id)
	}
	fmt.Printf("check in with: go run deadman.go ping -id %s\n", *id)
	fmt.Printf("check status with: go run deadman.go status -id %s\n", *id)
}

func mustDir(id string) (string, *config) {
	dir, err := baseDir(id)
	if err != nil {
		die(err)
	}
	c, err := loadConfig(dir)
	if err != nil {
		die(err)
	}
	return dir, c
}

func cmdPing(fs *flag.FlagSet) {
	id := fs.String("id", "", "switch id")
	fs.Parse(os.Args[2:])
	dir, c := mustDir(*id)
	s, _ := loadState(dir, c.Created)
	if s.Sent {
		dief("switch %s already triggered; ping has no effect (use resend to send again)", *id)
	}
	s.LastPing = time.Now().Unix()
	if err := saveState(dir, s); err != nil {
		die(err)
	}
	fmt.Printf("checked in: next deadline %s\n",
		time.Unix(s.LastPing, 0).Add(time.Duration(c.Days)*24*time.Hour).Format(time.RFC3339))
}

func cmdStatus(fs *flag.FlagSet) {
	id := fs.String("id", "", "switch id")
	fs.Parse(os.Args[2:])
	dir, c := mustDir(*id)
	s, _ := loadState(dir, c.Created)
	_, err := os.Stat(filepath.Join(dir, "payload.json"))
	left := time.Duration(c.Days)*24*time.Hour - time.Since(time.Unix(s.LastPing, 0))
	mailRoute := c.SMTPHost
	if c.SMTPPreset != "" {
		mailRoute = "preset " + c.SMTPPreset
	}
	var fps []string
	for _, h := range c.PubKeys {
		if b, err := hex.DecodeString(h); err == nil {
			fps = append(fps, pubFingerprint(b))
		}
	}
	credType := "none"
	if c.SMTPPassCmd != "" {
		credType = "command (password itself is never stored)"
	} else if c.SMTPPass != "" {
		credType = "file (0600, in state dir)"
	}
	sender := c.SenderPath
	if sender == "" {
		sender = "auto (next to deadman, then working directory, or DEADMAN_SENDEMAIL)"
	}
	trigger := "not set"
	if c.TriggerCmd != "" {
		trigger = "set"
	}
	afterSend := "not set"
	if c.AfterSendCmd != "" {
		afterSend = "set"
	}
	timeout := c.TriggerTimeout
	if timeout <= 0 {
		timeout = 120
	}
	fmt.Printf("id: %s\nrecipients: %s\npub fingerprints: %s\nmail: %s\nsmtp credential: %s\nsendEmail: %s\ntrigger command: %s (timeout %ds)\nafter-send command: %s\ndeadline: %d days\nlast check-in: %s\ntime left: %s\nsent: %v\npayload on disk: %v\n",
		c.ID, strings.Join(c.Recipients, ", "), strings.Join(fps, ", "), mailRoute, credType, sender, trigger, timeout, afterSend, c.Days,
		time.Unix(s.LastPing, 0).Format(time.RFC3339), left.Round(time.Hour),
		s.Sent, err == nil)
}

func cmdTest(fs *flag.FlagSet) {
	id := fs.String("id", "", "switch id")
	sendEmailPath := fs.String("sendemail", "", "sender path for this run only (overrides the stored path)")
	fs.Parse(os.Args[2:])
	_, c := mustDir(*id)
	if err := callSendEmail(c, *sendEmailPath, "Deadman switch test (no payload)",
		"This is a delivery test. No secret is attached and the switch state is unchanged. Trigger commands are NOT run by test.\n", "", ""); err != nil {
		die(err)
	}
	fmt.Println("test mail sent")
}

// triggerBody is the payload mail body, shared by check and resend
// so the two can never drift apart. It assumes the hand-delivered
// stick contains unlock.key and deadman.go; if a recipient's key
// file is named differently, the body says to use that name instead.
func triggerBody() string {
	return "You are receiving this because the sender has not checked in, and this is the message they left for you.\n\n" +
		"You need the USB stick they gave you in person. It should contain unlock.key and deadman.go. Do not copy unlock.key to your computer, and never email it to anyone.\n\n" +
		"1. Plug in the USB stick.\n" +
		"2. Save the attached message.enc.json to your Downloads folder. If it saves as message.enc (1).json, rename it to message.enc.json.\n" +
		"3. Open a terminal in the USB stick folder.\n" +
		"4. If you do not have Go installed, install it from https://go.dev/dl first, then come back to this step.\n" +
		"5. Run this command exactly:\n" +
		"   go run deadman.go decrypt -key unlock.key -in ~/Downloads/message.enc.json\n" +
		"   If your key file is called something else, use that name instead of unlock.key.\n" +
		"6. The message will print in the terminal. Copy it somewhere safe, then eject the stick.\n\n" +
		"If you see \"go: command not found\", do step 4.\n" +
		"If you see \"no such file\", check the stick is plugged in, check the download name in step 2, and check you are in the stick folder in step 3.\n" +
		"If you see \"no key entry decrypted\", you are using the wrong key file for this message.\n\n" +
		"The private key was never emailed and is not attached here. Only the holder of that stick can read this message.\n"
}

func cmdResend(fs *flag.FlagSet) {
	id := fs.String("id", "", "switch id")
	sendEmailPath := fs.String("sendemail", "", "sender path for this run only (overrides the stored path)")
	fs.Parse(os.Args[2:])
	dir, c := mustDir(*id)
	payloadPath := filepath.Join(dir, "payload.json")
	if _, err := os.Stat(payloadPath); err != nil {
		die(err)
	}
	// Resend is a manual re-send of a lost mail, not a new trigger:
	// trigger and after-send commands are deliberately NOT re-run here.
	if err := callSendEmail(c, *sendEmailPath, "Deadman switch triggered",
		triggerBody(), payloadPath, "message.enc.json"); err != nil {
		die(err)
	}
	s, _ := loadState(dir, c.Created)
	s.Sent, s.SentAt = true, time.Now().Unix()
	if err := saveState(dir, s); err != nil {
		die(err)
	}
	fmt.Println("payload sent and marked sent (payload file kept, so a lost mail can be resent)")
}

func cmdCheck(fs *flag.FlagSet) {
	id := fs.String("id", "", "switch id")
	sendEmailPath := fs.String("sendemail", "", "sender path for this run only (overrides the stored path)")
	fs.Parse(os.Args[2:])
	dir, c := mustDir(*id)
	s, _ := loadState(dir, c.Created)
	if s.Sent {
		fmt.Println("already sent, nothing to do")
		return
	}
	elapsed := time.Since(time.Unix(s.LastPing, 0))
	day := 24 * time.Hour
	deadline := time.Duration(c.Days) * day
	if elapsed >= deadline {
		payloadPath := filepath.Join(dir, "payload.json")
		if _, err := os.Stat(payloadPath); err != nil {
			die(err) // loud failure: do not mark sent, do not delete
		}
		// Cleanup first, then send. A failing hook is warned about
		// but does not block the payload: the secret is the point,
		// and a failed cleanup must not silently eat it. If the send
		// then fails, nothing is marked sent, so the next run retries
		// both the hook and the send (hooks must be idempotent).
		if c.TriggerCmd != "" {
			fmt.Println("running trigger command...")
			if err := runHook(c, dir, payloadPath, c.TriggerCmd, c.TriggerTimeout, "before"); err != nil {
				fmt.Fprintf(os.Stderr, "deadman: trigger command failed (%v), continuing to send payload\n", err)
			}
		}
		if err := callSendEmail(c, *sendEmailPath, "Deadman switch triggered",
			triggerBody(), payloadPath, "message.enc.json"); err != nil {
			die(err) // not marked sent: next run retries
		}
		s.Sent, s.SentAt = true, time.Now().Unix()
		if err := saveState(dir, s); err != nil {
			die(err)
		}
		// After-send runs only after sent is recorded, so a failing
		// after-send hook cannot cause a duplicate payload send.
		if c.AfterSendCmd != "" {
			fmt.Println("running after-send command...")
			if err := runHook(c, dir, payloadPath, c.AfterSendCmd, c.TriggerTimeout, "after"); err != nil {
				fmt.Fprintf(os.Stderr, "deadman: after-send command failed (%v), payload already sent and marked sent\n", err)
			}
		}
		fmt.Println("triggered: payload sent")
	} else {
		fmt.Printf("ok: %s left\n", (deadline - elapsed).Round(time.Hour))
	}
}

func execOutput(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	out, err := cmd.Output()
	return string(out), err
}

func execInput(name, arg, input string) error {
	cmd := exec.Command(name, arg)
	cmd.Stdin = strings.NewReader(input)
	return cmd.Run()
}

func cronLines() ([]string, error) {
	// Reading crontab via a pipe keeps this dependency-free; a missing
	// crontab is an empty one, not an error.
	out, _ := execOutput("crontab", "-l")
	if out == "" {
		return nil, nil
	}
	return strings.Split(strings.TrimRight(out, "\n"), "\n"), nil
}

// cronCommand returns the command cron should run. Under `go run`
// the executable is a throwaway temp binary, so cron must re-run the
// source from its directory instead; otherwise it points at a binary
// that no longer exists. The PATH prefix keeps `go` findable under
// cron's minimal PATH, and deadman then finds sendEmail.go in that
// same directory.
func cronCommand(id string) string {
	exe, err := os.Executable()
	if err == nil && !strings.Contains(exe, "go-build") {
		return fmt.Sprintf("%s check -id %s", exe, id)
	}
	wd, err := os.Getwd()
	if err != nil {
		die(err)
	}
	if _, err := os.Stat(filepath.Join(wd, "deadman.go")); err != nil {
		dief("install from a built binary, or run it from the directory containing deadman.go and sendEmail.go")
	}
	// Sender may live elsewhere if a path is stored in the config;
	// otherwise fall back to auto-discovery, and say how to store one.
	if cfgDir, err := baseDir(id); err == nil {
		if cfg, err := loadConfig(cfgDir); err == nil && cfg.SenderPath != "" {
			if _, err := senderArgv(cfg.SenderPath); err != nil {
				die(err)
			}
		} else if _, err := locateSendEmail(""); err != nil {
			dief("sendEmail not found: place sendEmail.go in %s, or store a path with configure -sendemail /abs/path", wd)
		}
	} else if _, err := os.Stat(filepath.Join(wd, "sendEmail.go")); err != nil {
		dief("sendEmail.go not found in %s; deadman needs it in the same directory, or a stored -sendemail path", wd)
	}
	if goPath, err := exec.LookPath("go"); err == nil {
		return fmt.Sprintf("cd %s && PATH=%s:/usr/bin:/bin %s run deadman.go check -id %s", wd, filepath.Dir(goPath), goPath, id)
	}
	return fmt.Sprintf("cd %s && go run deadman.go check -id %s", wd, id)
}

func cmdInstall(fs *flag.FlagSet, remove bool) {
	id := fs.String("id", "", "switch id")
	fs.Parse(os.Args[2:])
	tag := "DEADMAN_" + *id
	lines, err := cronLines()
	if err != nil {
		die(err)
	}
	kept := lines[:0]
	for _, l := range lines {
		if !strings.Contains(l, tag) {
			kept = append(kept, l)
		}
	}
	if !remove {
		kept = append(kept, fmt.Sprintf("0 * * * * %s # %s", cronCommand(*id), tag))
	}
	if err := execInput("crontab", "-", strings.Join(kept, "\n")+"\n"); err != nil {
		die(err)
	}
	if remove {
		fmt.Println("cron job removed (state and payload files kept)")
	} else {
		fmt.Println("cron installed: check runs hourly")
	}
}

func cmdDecrypt(fs *flag.FlagSet) {
	keyArg := fs.String("key", "", "private key hex or key file")
	in := fs.String("in", "", "payload file (message.enc.json)")
	fs.Parse(os.Args[2:])
	priv, err := readKey(*keyArg)
	if err != nil {
		die(err)
	}
	b, err := os.ReadFile(expandPath(*in))
	if err != nil {
		die(err)
	}
	var env envelope
	if err := json.Unmarshal(b, &env); err != nil {
		die(err)
	}
	pt, err := decrypt(priv, &env)
	if err != nil {
		var tos []string
		for _, k := range env.Keys {
			tos = append(tos, k.To)
		}
		dief("no key entry decrypted (wrong private key? tried public fingerprint %s, payload recipients: %s)", pubFingerprint(privPublic(priv)), strings.Join(tos, ", "))
	}
	os.Stdout.Write(pt)
	if len(pt) == 0 || pt[len(pt)-1] != '\n' {
		fmt.Println()
	}
}

// cmdFingerprint prints only a key's SHA256 fingerprint, never
// the key itself. Use -key for a private key file (it derives the
// public key first) and -pub for a public key file (it hashes it
// directly). Comparing the two tells you whether a file holds the
// private key or the public key: -key must match the fingerprint
// status prints for the switch, -pub must match it only if the
// file actually is the public key. This is the diagnostic for a
// "no key entry decrypted" failure, which otherwise gives no clue
// which key you tried.
func cmdFingerprint(fs *flag.FlagSet) {
	pubArg := fs.String("pub", "", "public key hex or .pub file")
	keyArg := fs.String("key", "", "private key hex or key file (prints only the fingerprint, never the key)")
	fs.Parse(os.Args[2:])
	var pub []byte
	var err error
	switch {
	case *pubArg != "" && *keyArg != "":
		dief("use either -pub or -key, not both")
	case *pubArg != "":
		pub, err = readKey(*pubArg)
	case *keyArg != "":
		var priv []byte
		priv, err = readKey(*keyArg)
		if err == nil {
			pub = privPublic(priv)
		}
	default:
		dief("fingerprint needs -pub or -key")
	}
	if err != nil {
		die(err)
	}
	fmt.Printf("fingerprint: %s\n", pubFingerprint(pub))
}

// cmdConfigure updates an existing switch without touching the
// payload, recipients, or keys, so no re-encryption and no clock
// reset. It covers the sender path, trigger hooks, expiry days, and,
// formerly rotate-smtp, the SMTP route and credential. Changing days
// does NOT reset last_ping, so setting days to 0 on an existing switch
// makes the next check send the payload, which is how a live test
// payload is triggered. With flags it just applies them, no prompts.
// With no flags at all it prompts interactively, Enter keeps the
// current value, so `configure -id x` alone is now a guided edit,
// not just a printout. Command strings are never printed, in case
// they hold a secret.
func cmdConfigure(fs *flag.FlagSet) {
	id := fs.String("id", "", "switch id")
	sendEmailPath := fs.String("sendemail", "", "absolute path to sendEmail binary or sendEmail.go")
	clearSender := fs.Bool("clear-sendemail", false, "forget the stored sender path, go back to auto-discovery")
	triggerCmd := fs.String("trigger-cmd", "", "command run before the payload is sent on trigger")
	clearTrigger := fs.Bool("clear-trigger", false, "remove the trigger command")
	triggerTimeout := fs.Int("trigger-timeout", -1, "seconds to allow the trigger command (-1 = leave unchanged)")
	afterSendCmd := fs.String("after-send-cmd", "", "command run after a successful payload send")
	clearAfterSend := fs.Bool("clear-after-send", false, "remove the after-send command")
	preset := fs.String("preset", "", "new SMTP preset (optional)")
	smtpHost := fs.String("smtp", "", "new SMTP host:port (optional)")
	smtpUser := fs.String("smtp-user", "", "new SMTP username (optional)")
	smtpFrom := fs.String("smtp-from", "", "new From address (optional)")
	smtpPassFile := fs.String("smtp-pass-file", "", "new password file (copied to state dir, 0600)")
	smtpPassCmd := fs.String("smtp-pass-command", "", "new password command, instead of -smtp-pass-file")
	daysFlag := fs.Int("days", -1, "new expiry in days (-1 = leave unchanged; 0 = send on next check)")
	fs.Parse(os.Args[2:])
	dir, c := mustDir(*id)
	// Guided mode: only when no change flag was given at all.
	// Flag mode is untouched, so scripted configure calls never
	// prompt. Guided prompts use askTail, which returns "" on EOF,
	// so a scripted call with stdin closed simply keeps everything
	// and prints the settings, exactly as the old no-flag behaviour.
	// Guided only if no change flag was explicitly given. Checking
	// values alone is wrong: -days -1 and -trigger-timeout -1 mean
	// "leave unchanged" explicitly, but look identical to the defaults.
	// fs.Visit only reports flags the user actually set, so a script
	// passing -days -1 does not accidentally get prompted.
	visited := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { visited[f.Name] = true })
	if len(visited) == 1 && visited["id"] {
		fmt.Printf("Configure %s (Enter keeps current, 'clear' removes where shown):\n", *id)
		if ans := askTail(fmt.Sprintf("Expiry in days [%d] (Enter to keep, 0 sends on next check)", c.Days)); ans != "" {
			if n, err := strconv.Atoi(ans); err == nil && n >= 0 {
				*daysFlag = n
			} else {
				fmt.Printf("keeping %d days\n", c.Days)
			}
		}
		curRoute := c.SMTPHost
		if c.SMTPPreset != "" {
			curRoute = "preset " + c.SMTPPreset
		}
		if ans := askTail(fmt.Sprintf("SMTP preset or host:port [%s] (Enter to keep, a preset name, or 'custom' for host:port)", curRoute)); ans != "" {
			if ans == "custom" {
				if host := askTail("Custom SMTP host:port, e.g. mail.example.com:587"); host != "" {
					*smtpHost, *preset = host, ""
				}
			} else {
				*preset, *smtpHost = ans, ""
			}
		}
		if ans := askTail(fmt.Sprintf("SMTP username [%s] (Enter to keep)", c.SMTPUser)); ans != "" {
			*smtpUser = ans
		}
		curFrom := c.SMTPFrom
		if curFrom == "" {
			curFrom = c.SMTPUser
		}
		if ans := askTail(fmt.Sprintf("From address [%s] (Enter to keep)", curFrom)); ans != "" {
			*smtpFrom = ans
		}
		if ans := askTail("SMTP credential (Enter to keep, 'file' for a new password file, 'command' for a password command)"); ans == "file" {
			fmt.Println("Save the credential to a file first, with `umask 077`, then `cat > file`, paste, Enter, Ctrl-D, then `chmod 600 file`. Do NOT use echo, and do NOT type the credential at a prompt, that would echo it.")
			for {
				f := askTail("Password/token file path (Enter to keep current credential)")
				if f == "" {
					break
				}
				if _, err := os.Stat(expandPath(f)); err == nil {
					*smtpPassFile = f
					break
				}
				fmt.Println("that file does not exist")
			}
		} else if ans == "command" {
			if cmd := askTail("Password command, e.g. 'secret-tool lookup deadman smtp'"); cmd != "" {
				*smtpPassCmd = cmd
			}
		}
		trigState := "not set"
		if c.TriggerCmd != "" {
			trigState = "set"
		}
		if ans := askTail(fmt.Sprintf("Trigger command [%s] (Enter to keep, 'clear' to remove, or type a new command)", trigState)); ans == "clear" {
			*clearTrigger = true
		} else if ans != "" {
			*triggerCmd = ans
		}
		afterState := "not set"
		if c.AfterSendCmd != "" {
			afterState = "set"
		}
		if ans := askTail(fmt.Sprintf("After-send command [%s] (Enter to keep, 'clear' to remove, or type a new command)", afterState)); ans == "clear" {
			*clearAfterSend = true
		} else if ans != "" {
			*afterSendCmd = ans
		}
		curTimeout := c.TriggerTimeout
		if curTimeout <= 0 {
			curTimeout = 120
		}
		if ans := askTail(fmt.Sprintf("Trigger timeout seconds [%d] (Enter to keep)", curTimeout)); ans != "" {
			if n, err := strconv.Atoi(ans); err == nil && n > 0 {
				*triggerTimeout = n
			} else {
				fmt.Println("keeping current timeout")
			}
		}
		curSender := c.SenderPath
		if curSender == "" {
			curSender = "auto"
		}
		for {
			ans := askTail(fmt.Sprintf("sendEmail path [%s] (Enter to keep, 'clear' to forget stored path, or type a new path)", curSender))
			if ans == "" {
				break
			}
			if ans == "clear" {
				*clearSender = true
				break
			}
			if abs, err := filepath.Abs(expandPath(ans)); err == nil {
				if _, err := senderArgv(abs); err == nil {
					*sendEmailPath = ans
					break
				}
			}
			fmt.Println("that sendEmail path does not exist")
		}
	}
	if *preset != "" && *smtpHost != "" {
		dief("use either -preset or -smtp, not both")
	}
	if *smtpPassFile != "" && *smtpPassCmd != "" {
		dief("use either -smtp-pass-file or -smtp-pass-command, not both")
	}
	changed, smtpChanged := false, false
	if *clearSender {
		c.SenderPath, changed = "", true
	} else if *sendEmailPath != "" {
		abs, err := filepath.Abs(expandPath(*sendEmailPath))
		if err != nil {
			die(err)
		}
		if _, err := senderArgv(abs); err != nil {
			die(err)
		}
		c.SenderPath, changed = abs, true
	}
	if *clearTrigger {
		c.TriggerCmd, changed = "", true
	} else if *triggerCmd != "" {
		c.TriggerCmd, changed = *triggerCmd, true
	}
	if *triggerTimeout >= 0 {
		c.TriggerTimeout, changed = *triggerTimeout, true
	}
	if *clearAfterSend {
		c.AfterSendCmd, changed = "", true
	} else if *afterSendCmd != "" {
		c.AfterSendCmd, changed = *afterSendCmd, true
	}
	if *daysFlag >= 0 {
		c.Days, changed = *daysFlag, true
	}
	if *preset != "" {
		c.SMTPPreset, c.SMTPHost, changed, smtpChanged = *preset, "", true, true
	}
	if *smtpHost != "" {
		c.SMTPHost, c.SMTPPreset, changed, smtpChanged = *smtpHost, "", true, true
	}
	if *smtpUser != "" {
		c.SMTPUser, changed, smtpChanged = *smtpUser, true, true
	}
	if *smtpFrom != "" {
		c.SMTPFrom, changed, smtpChanged = *smtpFrom, true, true
	}
	if *smtpPassFile != "" {
		b, err := os.ReadFile(expandPath(*smtpPassFile))
		if err != nil {
			die(err)
		}
		dst := filepath.Join(dir, "smtp_pass")
		if err := writeFile(dst, []byte(strings.TrimSpace(string(b))+"\n"), 0600); err != nil {
			die(err)
		}
		c.SMTPPass, c.SMTPPassCmd, changed, smtpChanged = dst, "", true, true
	}
	if *smtpPassCmd != "" {
		c.SMTPPassCmd, changed, smtpChanged = *smtpPassCmd, true, true
		if c.SMTPPass != "" {
			os.Remove(c.SMTPPass) // no stale plaintext credential left behind
			c.SMTPPass = ""
		}
	}
	if changed {
		if err := writeJSON(filepath.Join(dir, "config.json"), c); err != nil {
			die(err)
		}
		fmt.Println("updated, payload unchanged.")
		if c.Days == 0 {
			fmt.Println("WARNING: expiry is 0 days, the next check will send the payload immediately. Only use this for a test switch.")
		}
		if smtpChanged {
			fmt.Printf("Run test to verify the new SMTP settings:\n  go run deadman.go test -id %s\n", *id)
		}
	}
	sender := c.SenderPath
	if sender == "" {
		sender = "auto (next to deadman, then working directory, or DEADMAN_SENDEMAIL)"
	}
	mailRoute := c.SMTPHost
	if c.SMTPPreset != "" {
		mailRoute = "preset " + c.SMTPPreset
	}
	credType := "none"
	if c.SMTPPassCmd != "" {
		credType = "command (password itself is never stored)"
	} else if c.SMTPPass != "" {
		credType = "file (0600, in state dir)"
	}
	timeout := c.TriggerTimeout
	if timeout <= 0 {
		timeout = 120
	}
	fmt.Printf("sendEmail: %s\nmail: %s\nsmtp credential: %s\ndeadline: %d days\ntrigger command: %v\nafter-send command: %v\ntrigger timeout: %ds\n",
		sender, mailRoute, credType, c.Days, c.TriggerCmd != "", c.AfterSendCmd != "", timeout)
}

// ---------- guided setup helpers ----------
// ask reads one line. askYes dies on EOF (required prompts).
// askYesTail and askTail return false / "" on EOF, so a scripted
// setup with all flags and stdin closed simply skips the optional
// test, shred, and cron steps instead of failing.
var askReader = bufio.NewReader(os.Stdin)

func readLine() (string, error) {
	line, err := askReader.ReadString('\n')
	if err != nil && len(line) == 0 {
		return "", err
	}
	return strings.TrimSpace(line), nil
}

func ask(prompt, def string) string {
	if def != "" {
		fmt.Printf("%s [%s]: ", prompt, def)
	} else {
		fmt.Printf("%s: ", prompt)
	}
	s, err := readLine()
	if err != nil {
		dief("setup input ended unexpectedly")
	}
	if s == "" {
		return def
	}
	return s
}

func askYes(prompt string, def bool) bool {
	d := "n"
	if def {
		d = "y"
	}
	s := strings.ToLower(ask(prompt+" (y/n)", d))
	return s == "y" || s == "yes"
}

func askYesTail(prompt string, def bool) bool {
	d := "n"
	if def {
		d = "y"
	}
	fmt.Printf("%s (y/n) [%s]: ", prompt, d)
	s, err := readLine()
	if err != nil {
		return false
	}
	if s == "" {
		return def
	}
	s = strings.ToLower(s)
	return s == "y" || s == "yes"
}

func askTail(prompt string) string {
	fmt.Printf("%s: ", prompt)
	s, err := readLine()
	if err != nil {
		return ""
	}
	return s
}

func generateKey(privPath string) (string, string, error) {
	privPath = expandPath(privPath)
	absPriv, err := filepath.Abs(privPath)
	if err != nil {
		return "", "", err
	}
	if home, err := os.UserHomeDir(); err == nil {
		if strings.HasPrefix(absPriv, filepath.Join(home, ".deadman")+string(os.PathSeparator)) {
			return "", "", fmt.Errorf("refusing to write a private key into ~/.deadman")
		}
	}
	if _, err := os.Stat(filepath.Dir(absPriv)); err != nil {
		return "", "", fmt.Errorf("private output directory does not exist (is the thumb drive mounted?): %s", filepath.Dir(absPriv))
	}
	priv, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return "", "", err
	}
	ph, qh := hex.EncodeToString(priv.Bytes()), hex.EncodeToString(priv.PublicKey().Bytes())
	if err := writeFile(privPath, []byte(ph+"\n"), 0600); err != nil {
		return "", "", err
	}
	return qh, pubFingerprint(priv.PublicKey().Bytes()), nil
}

// shredFile overwrites a file with random data (3 passes) then
// zeros, syncs, and removes it. This is not rm: rm only unlinks
// the name and leaves the bytes on disk. Honest limit, stated
// wherever shred is used: on SSDs and flash, wear leveling can
// keep old copies in blocks the OS cannot reach, so shredding
// reduces exposure but does not guarantee erasure. The only
// certain way to avoid that is to never write plaintext to an
// SSD in the first place, for example by using /dev/shm.
func shredFile(path string) error {
	path = expandPath(path)
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	size := info.Size()
	buf := make([]byte, 64*1024)
	for pass := 0; pass < 3; pass++ {
		if _, err := f.Seek(0, 0); err != nil {
			f.Close()
			return err
		}
		left := size
		for left > 0 {
			n := int64(len(buf))
			if left < n {
				n = left
			}
			if _, err := rand.Read(buf[:n]); err != nil {
				f.Close()
				return err
			}
			if _, err := f.Write(buf[:n]); err != nil {
				f.Close()
				return err
			}
			left -= n
		}
		if err := f.Sync(); err != nil {
			f.Close()
			return err
		}
	}
	if _, err := f.Seek(0, 0); err != nil {
		f.Close()
		return err
	}
	for i := int64(0); i < size; {
		n := int64(len(buf))
		if size-i < n {
			n = size - i
		}
		for j := int64(0); j < n; j++ {
			buf[j] = 0
		}
		if _, err := f.Write(buf[:n]); err != nil {
			f.Close()
			return err
		}
		i += n
	}
	f.Sync()
	f.Close()
	return os.Remove(path)
}

// smtpHint is short on purpose. Full steps live in the file
// header above and in sendEmail.go, this is just the reminder
// at the moment you need the credential.
func smtpHint(preset string) string {
	switch preset {
	case "gmail":
		return "Gmail: dedicated account only, 2-Step Verification on, " +
			"Security, App passwords, App Mail, Device Other, name it deadman, " +
			"Generate, remove spaces, save with `umask 077`, then `cat > file`, " +
			"paste, Enter, Ctrl-D, `chmod 600 file`. Never echo, never the main password."
	case "proton":
		return "Proton: SMTP token, paid plan plus custom domain address only. " +
			"Username and From are that address, token is the password, shown once."
	case "proton-bridge":
		return "Proton Bridge: must run on this machine, 127.0.0.1:1025, " +
			"Bridge password, never the Proton password."
	case "smtp2go":
		return "SMTP2GO: domain address only, no Gmail signup. Verify the sender " +
			"domain in DNS, create an SMTP user just for deadman, From at that domain."
	case "sendgrid":
		return "SendGrid: username is literally apikey, API key Mail Send only, " +
			"From must be a verified sender."
	case "mailgun", "mailgun-eu":
		return "Mailgun: per-domain SMTP password, From at that domain."
	case "outlook", "office365", "microsoft365":
		return "Outlook: app password only if MFA and SMTP AUTH are on. " +
			"Many personal accounts now require OAuth2 only, best-effort here."
	default:
		return "Use a scoped token or app password, never a main password. " +
			"From must match the account or a verified alias."
	}
}

// cmdPurge removes everything related to one switch id, so a
// misconfigured switch can be started over from scratch.
// It removes the cron job for that id, then shreds every file in
// ~/.deadman/<id>/ (config, state, payload, smtp_pass) and removes
// the directory. Shredding is overwrite then remove, not rm.
// Files outside the state directory are NOT touched: your original
// secret file, password file, and private key files may be needed
// for a re-setup, or for another switch, so purge lists them as
// your job to shred yourself if you want them gone.
// Confirmation is typing the id itself, not just y, because this
// is irreversible. -force skips that prompt, for scripts only.
func cmdPurge(fs *flag.FlagSet) {
	id := fs.String("id", "", "switch id to purge")
	force := fs.Bool("force", false, "skip the confirmation prompt")
	fs.Parse(os.Args[2:])
	if *id == "" {
		dief("purge needs -id, e.g. go run deadman.go purge -id myswitch")
	}
	dir, err := baseDir(*id)
	if err != nil {
		die(err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		fmt.Printf("no switch %s found at %s, removing its cron job if any\n", *id, dir)
	} else {
		fmt.Printf("This will PERMANENTLY purge switch %s:\n", *id)
		fmt.Printf("  state directory: %s\n", dir)
		for _, e := range entries {
			fmt.Printf("  shred and remove: %s\n", e.Name())
		}
		fmt.Println("  cron job: removed, so it does not keep failing on a deleted switch")
		fmt.Println("  NOT touched: original secret, password, and private key files outside this directory")
		if !*force {
			confirm := askTail("Type the switch id to confirm purge")
			if confirm != *id {
				fmt.Println("Aborted, nothing deleted. Confirmation did not match the switch id.")
				return
			}
		}
	}
	// Remove cron first, so a deleted switch does not keep running.
	tag := "DEADMAN_" + *id
	if lines, err := cronLines(); err == nil {
		kept := lines[:0]
		for _, l := range lines {
			if !strings.Contains(l, tag) {
				kept = append(kept, l)
			}
		}
		if len(kept) != len(lines) {
			if err := execInput("crontab", "-", strings.Join(kept, "\n")+"\n"); err != nil {
				fmt.Printf("warning: cron removal failed: %v, run uninstall -id %s yourself\n", err, *id)
			} else {
				fmt.Println("Cron job removed.")
			}
		} else {
			fmt.Println("No cron job found for this switch.")
		}
	} else {
		fmt.Printf("warning: could not read crontab: %v\n", err)
	}
	if err != nil {
		return
	}
	for _, e := range entries {
		path := filepath.Join(dir, e.Name())
		if e.IsDir() {
			continue
		}
		if err := shredFile(path); err != nil {
			fmt.Printf("Shred failed for %s: %v, removing it anyway so purge completes\n", path, err)
			os.Remove(path)
		} else {
			fmt.Printf("Shredded: %s\n", path)
		}
	}
	if err := os.RemoveAll(dir); err != nil {
		die(err)
	}
	fmt.Printf("Purged switch %s. Start over with: go run deadman.go setup -id %s\n", *id, *id)
}

func wizValidID(id string) bool {
	if id == "" || strings.ContainsAny(id, " /\\") {
		return false
	}
	return true
}

// cmdShred shreds files properly: overwrite, sync, remove.
// rm only unlinks a name and leaves the bytes on disk. Use this
// for secret and password files after setup, and for temporary
// private key copies after they are safely on offline storage.
// SSD and flash warning: wear leveling can keep old copies in
// blocks the OS cannot reach, so shredding reduces exposure but
// does not guarantee erasure. Writing the secret to /dev/shm
// before setup avoids that problem entirely.
func cmdShred(fs *flag.FlagSet) {
	fs.Parse(os.Args[2:])
	if fs.NArg() == 0 {
		dief("shred needs at least one file, e.g. go run deadman.go shred secret.txt pass.txt")
	}
	for _, f := range fs.Args() {
		if err := shredFile(f); err != nil {
			fmt.Printf("shred failed for %s: %v\n", f, err)
		} else {
			fmt.Printf("Shredded: %s\n", f)
		}
	}
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("usage: go run deadman.go <keygen|setup|ping|status|test|resend|check|install|uninstall|decrypt|fingerprint|configure|shred|purge> [flags]")
		fmt.Println("  keygen:   sender generates a keypair straight to a thumb drive (private never printed, never emailed)")
		fmt.Println("  setup:    sender encrypts a message to recipients' public keys")
		fmt.Println("  ping:     check in, resets the deadline clock")
		fmt.Println("  status:   deadline, mail route, sent flag")
		fmt.Println("  test:     test mail, no payload, state unchanged")
		fmt.Println("  resend:   resend the payload if a mail is lost to spam")
		fmt.Println("  check:    run from cron; sends the payload once overdue, nothing before")
		fmt.Println("  install:  hourly cron for check")
		fmt.Println("  uninstall: remove cron, keep state and payload")
		fmt.Println("  decrypt:  recipient decrypts message.enc.json with the private key on their thumb drive")
		fmt.Println("  fingerprint: print a key fingerprint, without printing the key, to check a key file against status")
		fmt.Println("  configure: change expiry days, sender path, trigger commands, or SMTP route and credential, payload unchanged (prompts if no flags)")
		fmt.Println("  shred:     shred files properly (overwrite, not rm), e.g. shred secret.txt pass.txt")
		fmt.Println("  purge:     remove cron AND the whole state directory for an id, shredded, start over")
		os.Exit(2)
	}
	fs := flag.NewFlagSet(os.Args[1], flag.ExitOnError)
	switch os.Args[1] {
	case "keygen":
		cmdKeygen(fs)
	case "setup":
		cmdSetup(fs)
	case "ping":
		cmdPing(fs)
	case "status":
		cmdStatus(fs)
	case "test":
		cmdTest(fs)
	case "resend":
		cmdResend(fs)
	case "check":
		cmdCheck(fs)
	case "install":
		cmdInstall(fs, false)
	case "uninstall":
		cmdInstall(fs, true)
	case "decrypt":
		cmdDecrypt(fs)
	case "fingerprint":
		cmdFingerprint(fs)
	case "configure":
		cmdConfigure(fs)
	case "shred":
		cmdShred(fs)
	case "purge":
		cmdPurge(fs)
	default:
		dief("unknown command %q", os.Args[1])
	}
}
