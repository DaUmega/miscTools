// sendEmail: a standalone email sender. One file, stdlib only, no go.mod.
//
// Run it directly, with no other file needed:
//
//	go run sendEmail.go -to a@b -subject "Hi" -message "Hello" -preset gmail \
//	  -smtp-user you@gmail.com -smtp-pass-file ~/gmail-app-password.txt
//	go run sendEmail.go -to a@b -subject "Hi" -message-file body.txt -a report.pdf
//	go run sendEmail.go -to a@b -subject "Hi" -message - -preset proton-bridge \
//	  -smtp-user you@proton.me -smtp-pass-file ~/bridge-pass.txt < body.txt
//
// Flags: -to / -t (repeatable, comma-separated), -cc, -bcc,
// -subject / -s, -message / -m, -message-file, -message - (stdin),
// -a / -attachment (repeatable), -a-name (single attachment only),
// -preset or -smtp host:port, -smtp-user, -smtp-from (default:
// smtp-user), -smtp-pass-file or -smtp-pass-command, -timeout
// (default 30), -dry-run (print the MIME message, do not send).
// -preset list prints all presets.
//
// Paths: ~/ expands to your home directory, relative paths work
// from the current directory at run time.
//
// If no password file or command is given, sendEmail prints the
// hint for the preset you picked and asks for a password file
// path. Passwords are never typed at a prompt, because that would
// echo them. Pressing Enter with no path keeps no-auth, for
// example a local relay, so scripted calls still work.
//
// How to get a credential, by provider (setup order for deadman
// is: prove sendEmail works on its own first, with a dry run and
// then a real test to yourself only, then set up deadman):
//
//	gmail: sign in to a DEDICATED Gmail account only, not your
//	  main account. Security, then How you sign in to Google,
//	  then 2-Step Verification: turn it on with an authenticator
//	  app. App passwords do not appear until this is on. Then
//	  Security, App passwords, App Mail, Device Other, name it
//	  deadman, Generate. Copy the 16-character code shown once
//	  only, and REMOVE the spaces, so it is 16 characters with
//	  no spaces. Save it with `umask 077`, then `cat > file`,
//	  paste, Enter, Ctrl-D, then `chmod 600 file`. Do NOT use
//	  echo, that lands in shell history. Username and From are
//	  both the dedicated Gmail address. Never use the main
//	  Google password here, and never paste the code into chat.
//	proton: SMTP token, paid plan plus a custom domain address
//	  only, free Proton cannot do this. Settings, All settings,
//	  Proton Mail, IMAP/SMTP, SMTP tokens, Generate token, pick
//	  the custom domain address. Token is shown once only.
//	  Username and From are that address, token is the password,
//	  never your Proton password. It can only send, it cannot
//	  read mail or log in.
//	proton-bridge: paid Proton plan only, Bridge must run on
//	  this machine, host 127.0.0.1:1025. In Bridge, copy the
//	  SMTP username and the Bridge-generated password. That
//	  password is local only, useless on any other machine,
//	  never your Proton password.
//	smtp2go: address at a domain of your own only, no Gmail,
//	  Yahoo, or Outlook signup. Sign up, free plan, then
//	  Sending, Verified Senders, Sender Domains: add your
//	  domain, add the three CNAME records to DNS (Cloudflare
//	  proxy off for those records), then Verify. Then Sending,
//	  SMTP Users: add a user just for deadman. That username
//	  and password are the SMTP credential, NOT your SMTP2GO
//	  login password. From must be at the verified domain.
//	sendgrid: Settings, API Keys, Create API Key, Mail Send
//	  only, never Full Access. Key is shown once only, starts
//	  with SG. Username is literally apikey, key is the
//	  password. From must be a verified sender. Free SendGrid
//	  is now a trial in recent reports, do not rely on it
//	  for a switch that must fire years from now unless paid.
//	mailgun: add and verify your sending domain, then Sending,
//	  Domain settings, SMTP credentials. Username is usually
//	  postmaster@your-domain, password is per-domain, NOT your
//	  Mailgun login password. From must be at that domain.
//	outlook / office365: app password only if MFA is on and
//	  SMTP AUTH is enabled for the mailbox. Many Outlook.com
//	  personal accounts now require OAuth2 only, which this
//	  sender does not do, so this route is best-effort.
//	yahoo, icloud, aol, zoho, fastmail, gmx: turn on two-factor
//	  authentication, then generate an app-specific password
//	  for Mail. That password is the SMTP credential, never
//	  your main account password. Username and From are
//	  normally your full email address.
//	Any other provider: -smtp host:port, 587 STARTTLS, 465
//	  implicit TLS. Never store a main password in plaintext;
//	  use a scoped, revocable token that can only send mail.
//
// Transport: STARTTLS on 587, implicit TLS on 465, PLAIN auth
// with LOGIN as a fallback. Plaintext auth is refused unless
// the server offers STARTTLS, except on loopback, where TLS
// verification is skipped because Proton Bridge serves STARTTLS
// with a self-signed certificate. Remote hosts stay verified.
// Bcc is envelope-only, no Bcc header is written, so To and Cc
// recipients never see bcc recipients.
//
// It deliberately does not do OAuth2. OAuth tokens can expire
// or be revoked during months of inactivity, and app passwords
// and tokens do not have that failure mode. Providers that only
// allow OAuth2 therefore cannot be used here; use a provider
// above, or any host via -smtp.
//
// Common failures, in order: spaces left in an app password or
// token, From does not match the account or verified sender,
// 2-Step Verification not on for Gmail, SMTP AUTH disabled
// for Outlook, or a sender domain not verified for SMTP2GO
// or Mailgun.
package main

import (
	"bufio"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"flag"
	"fmt"
	"io"
	"mime"
	"net"
	"net/smtp"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

func die(err error) {
	fmt.Fprintln(os.Stderr, "sendEmail:", err)
	os.Exit(1)
}

func dief(format string, a ...any) { die(fmt.Errorf(format, a...)) }

type mailPreset struct {
	host string
	cred string
}

var mailPresets = map[string]mailPreset{
	"gmail":         {"smtp.gmail.com:587", "app password (16 chars, 2-Step Verification on; not your Google password)"},
	"outlook":       {"smtp-mail.outlook.com:587", "app password if available; Outlook.com personal accounts increasingly require OAuth2 only, which this client does not do"},
	"office365":     {"smtp.office365.com:587", "app password if MFA is on and SMTP AUTH is enabled for the mailbox; a tenant may require OAuth2"},
	"microsoft365":  {"smtp.office365.com:587", "app password if MFA is on and SMTP AUTH is enabled for the mailbox; a tenant may require OAuth2"},
	"yahoo":         {"smtp.mail.yahoo.com:587", "app password"},
	"icloud":        {"smtp.mail.me.com:587", "app-specific password"},
	"aol":           {"smtp.aol.com:587", "app password"},
	"zoho":          {"smtp.zoho.com:587", "app-specific password if 2FA is on"},
	"zoho-eu":       {"smtp.zoho.eu:587", "app-specific password if 2FA is on"},
	"fastmail":      {"smtp.fastmail.com:587", "app password"},
	"gmx":           {"mail.gmx.com:587", "account or app password; gmx.net / gmx.de use mail.gmx.net via -smtp"},
	"proton":        {"smtp.protonmail.ch:587", "SMTP token (paid plan + custom domain address; not your Proton password)"},
	"proton-bridge": {"127.0.0.1:1025", "Bridge-generated password (not your Proton password); Bridge must be running"},
	"sendgrid":      {"smtp.sendgrid.net:587", "API key with Mail Send only (username is literally apikey); send only, cannot read mail or log in"},
	"mailgun":       {"smtp.mailgun.org:587", "per-domain SMTP password; send only for that domain"},
	"mailgun-eu":    {"smtp.eu.mailgun.org:587", "per-domain SMTP password; send only for that domain"},
	"smtp2go":       {"mail.smtp2go.com:587", "SMTP user from dashboard (not your account login); free plan 1000/month, 200/day, 25/hour until a sender domain is verified"},
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

func printPresets() {
	names := make([]string, 0, len(mailPresets))
	for n := range mailPresets {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		p := mailPresets[n]
		fmt.Printf("%-14s %s  (%s)\n", n, p.host, p.cred)
	}
	fmt.Println("Any other provider: use -smtp host:port instead of -preset.")
}

// splitEmails accepts repeatable flags and comma-separated values.
func splitEmails(values []string) []string {
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

func validEmail(s string) bool {
	return strings.Contains(s, "@") && !strings.ContainsAny(s, " \r\n\t<>") && len(s) > 3
}

// loginAuth implements SMTP AUTH LOGIN, for servers that offer LOGIN
// but not PLAIN.
type loginAuth struct{ user, pass string }

func (a loginAuth) Start(server *smtp.ServerInfo) (string, []byte, error) {
	return "LOGIN", nil, nil
}

func (a loginAuth) Next(fromServer []byte, more bool) ([]byte, error) {
	if !more {
		return nil, nil
	}
	// LOGIN prompts are usually base64 ("VXNlcm5hbWU6" = "Username:").
	prompt := strings.ToLower(string(fromServer))
	if decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(fromServer))); err == nil {
		prompt = strings.ToLower(string(decoded))
	}
	switch {
	case strings.Contains(prompt, "username"):
		return []byte(a.user), nil
	case strings.Contains(prompt, "password"):
		return []byte(a.pass), nil
	default:
		return nil, fmt.Errorf("unexpected LOGIN prompt %q", fromServer)
	}
}

type mailConfig struct {
	host, user, pass, from string
	to, cc, bcc            []string
	timeout                time.Duration
}

func buildMessage(from string, to, cc, bcc []string, subject, body string, attachments []string, attachName string) ([]byte, error) {
	var b strings.Builder
	fmt.Fprintf(&b, "From: %s\r\nTo: %s\r\nSubject: %s\r\nMIME-Version: 1.0\r\n", from, strings.Join(to, ", "), subject)
	if len(cc) > 0 {
		fmt.Fprintf(&b, "Cc: %s\r\n", strings.Join(cc, ", "))
	}
	// No Bcc header on purpose: bcc recipients are envelope-only,
	// so To/Cc recipients never see them.
	if len(attachments) == 0 {
		fmt.Fprintf(&b, "Content-Type: text/plain; charset=utf-8\r\n\r\n%s\r\n", body)
		return []byte(b.String()), nil
	}
	raw := make([]byte, 12)
	if _, err := rand.Read(raw); err != nil {
		return nil, err
	}
	boundary := "sendemail-" + base64.RawURLEncoding.EncodeToString(raw)
	fmt.Fprintf(&b, "Content-Type: multipart/mixed; boundary=%s\r\n\r\n--%s\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n%s\r\n", boundary, boundary, body)
	for _, path := range attachments {
		data, err := os.ReadFile(expandPath(path))
		if err != nil {
			return nil, err
		}
		ctype := mime.TypeByExtension(filepath.Ext(path))
		if ctype == "" {
			ctype = "application/octet-stream"
		}
		name := filepath.Base(path)
		if attachName != "" {
			name = attachName
		}
		fmt.Fprintf(&b, "--%s\r\nContent-Type: %s; name=%s\r\nContent-Transfer-Encoding: base64\r\nContent-Disposition: attachment; filename=%s\r\n\r\n", boundary, ctype, name, name)
		enc := base64.NewEncoder(base64.StdEncoding, &b)
		if _, err := enc.Write(data); err != nil {
			return nil, err
		}
		enc.Close()
		fmt.Fprintf(&b, "\r\n")
	}
	fmt.Fprintf(&b, "--%s--\r\n", boundary)
	return []byte(b.String()), nil
}

func sendMail(cfg mailConfig, msg []byte) error {
	if cfg.host == "" {
		return fmt.Errorf("no smtp host configured")
	}
	host, port, err := net.SplitHostPort(cfg.host)
	if err != nil {
		return err
	}
	// Proton Bridge (and other local relays) serve STARTTLS with a
	// self-signed cert. Verification is skipped only on loopback, where
	// the traffic never leaves this machine; remote hosts stay verified.
	isLoopback := host == "localhost" || host == "127.0.0.1" || strings.HasPrefix(host, "127.")
	tlsConf := &tls.Config{ServerName: host, InsecureSkipVerify: isLoopback}
	dialer := &net.Dialer{Timeout: cfg.timeout}
	var client *smtp.Client
	if port == "465" {
		conn, err := tls.DialWithDialer(dialer, "tcp", cfg.host, tlsConf)
		if err != nil {
			return err
		}
		client, err = smtp.NewClient(conn, host)
		if err != nil {
			return err
		}
	} else {
		conn, err := dialer.Dial("tcp", cfg.host)
		if err != nil {
			return err
		}
		client, err = smtp.NewClient(conn, host)
		if err != nil {
			return err
		}
		if ok, _ := client.Extension("STARTTLS"); ok {
			if err := client.StartTLS(tlsConf); err != nil {
				return err
			}
		} else if cfg.user != "" && !isLoopback {
			return fmt.Errorf("refusing plaintext SMTP auth: server offers no STARTTLS")
		}
	}
	defer client.Quit()
	if cfg.user != "" {
		_, mechs := client.Extension("AUTH")
		if strings.Contains(mechs, "LOGIN") && !strings.Contains(mechs, "PLAIN") {
			err = client.Auth(loginAuth{cfg.user, cfg.pass})
		} else {
			err = client.Auth(smtp.PlainAuth("", cfg.user, cfg.pass, host))
		}
		if err != nil {
			return err
		}
	}
	if err := client.Mail(cfg.from); err != nil {
		return err
	}
	// Envelope recipients include bcc; the message itself has no Bcc header.
	for _, rcpt := range append(append(append([]string{}, cfg.to...), cfg.cc...), cfg.bcc...) {
		if err := client.Rcpt(rcpt); err != nil {
			return err
		}
	}
	w, err := client.Data()
	if err != nil {
		return err
	}
	defer w.Close()
	_, err = w.Write(msg)
	return err
}

type strList []string

func (s *strList) String() string     { return strings.Join(*s, ",") }
func (s *strList) Set(v string) error { *s = append(*s, v); return nil }

// smtpHint is short on purpose. Full steps live in the file
// header above, this is just the reminder at the moment
// you need the credential.
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
	default:
		return "Use a scoped token or app password, never a main password. " +
			"From must match the account or a verified alias."
	}
}

func main() {
	var to, cc, bcc, attach strList
	preset := flag.String("preset", "", "provider preset, or 'list' to print all presets; instead of -smtp")
	smtpHost := flag.String("smtp", "", "SMTP host:port, e.g. mail.example.com:587 (465 = implicit TLS)")
	smtpUser := flag.String("smtp-user", "", "SMTP username (empty = no auth, e.g. local relay)")
	smtpFrom := flag.String("smtp-from", "", "From address (default: smtp-user)")
	smtpPassFile := flag.String("smtp-pass-file", "", "file containing the SMTP password (never pass a password on the command line)")
	smtpPassCmd := flag.String("smtp-pass-command", "", "command whose stdout is the SMTP password, e.g. 'secret-tool lookup deadman smtp' or 'security find-generic-password -s deadman -w'; instead of -smtp-pass-file, and never logged")
	subject := flag.String("subject", "", "email subject")
	subjectShort := flag.String("s", "", "email subject (short form)")
	message := flag.String("message", "", "email body, or '-' to read stdin")
	messageShort := flag.String("m", "", "email body (short form)")
	messageFile := flag.String("message-file", "", "file to read the email body from")
	timeout := flag.Int("timeout", 30, "SMTP dial timeout in seconds")
	dryRun := flag.Bool("dry-run", false, "print the MIME message instead of sending it")
	flag.Var(&to, "to", "recipient email, repeatable and/or comma-separated")
	flag.Var(&to, "t", "recipient email (short form)")
	flag.Var(&cc, "cc", "cc recipient, repeatable and/or comma-separated")
	flag.Var(&bcc, "bcc", "bcc recipient, repeatable and/or comma-separated")
	attachName := flag.String("a-name", "", "filename to use for a single attachment (default: the file's own name)")
	flag.Var(&attach, "a", "attachment file, repeatable")
	flag.Var(&attach, "attachment", "attachment file, repeatable")
	flag.Parse()

	if *preset == "list" {
		printPresets()
		return
	}
	if *preset != "" && *smtpHost != "" {
		dief("use either -preset or -smtp, not both")
	}
	if *preset != "" {
		p, ok := mailPresets[*preset]
		if !ok {
			names := make([]string, 0, len(mailPresets))
			for n := range mailPresets {
				names = append(names, n)
			}
			sort.Strings(names)
			dief("unknown preset %q (%s)", *preset, strings.Join(names, ", "))
		}
		*smtpHost = p.host
	}
	if *subjectShort != "" {
		*subject = *subjectShort
	}
	if *messageShort != "" {
		*message = *messageShort
	}
	recipients := splitEmails(to)
	ccs := splitEmails(cc)
	bccs := splitEmails(bcc)
	if len(recipients) == 0 {
		dief("at least one -to recipient is required")
	}
	for _, e := range append(append(append([]string{}, recipients...), ccs...), bccs...) {
		if !validEmail(e) {
			dief("bad email address %q", e)
		}
	}
	if *subject == "" {
		dief("a subject (-subject / -s) is required")
	}
	var body string
	switch {
	case *messageFile != "":
		b, err := os.ReadFile(expandPath(*messageFile))
		if err != nil {
			die(err)
		}
		body = string(b)
	case *message == "-":
		b, err := io.ReadAll(os.Stdin)
		if err != nil {
			die(err)
		}
		body = string(b)
	case *message != "":
		body = *message
	default:
		dief("a body is required: -message, -message-file, or -message - (stdin)")
	}
	for i, a := range attach {
		attach[i] = expandPath(a)
		if _, err := os.Stat(attach[i]); err != nil {
			die(err)
		}
	}
	if *attachName != "" && len(attach) != 1 {
		dief("-a-name only applies to a single attachment")
	}
	// Guided hint: if no credential was given, print the hint for
	// the preset you picked and ask for a password file path.
	// Passwords are never typed at a prompt here, because that
	// would echo them. Save the credential to a file first, then
	// give the file path. Pressing Enter with no path keeps no-auth,
	// for example a local relay, so scripted calls still work.
	if *smtpPassFile == "" && *smtpPassCmd == "" {
		fmt.Println(smtpHint(*preset))
		fmt.Println("Save the credential to a file first, with `umask 077`, then `cat > file`, paste, Enter, Ctrl-D, then `chmod 600 file`. Do NOT use echo.")
		fmt.Print("Password/token file path (Enter for no auth): ")
		reader := bufio.NewReader(os.Stdin)
		line, err := reader.ReadString('\n')
		if err == nil {
			if s := strings.TrimSpace(line); s != "" {
				if _, err := os.Stat(expandPath(s)); err == nil {
					*smtpPassFile = expandPath(s)
				} else {
					fmt.Printf("that file does not exist, continuing with no auth\n")
				}
			}
		}
	}
	if *smtpPassFile != "" && *smtpPassCmd != "" {
		dief("use either -smtp-pass-file or -smtp-pass-command, not both")
	}
	pass := ""
	switch {
	case *smtpPassFile != "":
		b, err := os.ReadFile(expandPath(*smtpPassFile))
		if err != nil {
			die(err)
		}
		pass = strings.TrimSpace(string(b))
	case *smtpPassCmd != "":
		// Run through sh so a normal keyring/pass command works as-is.
		// The command string is trusted (it comes from your own flag),
		// and its output is never printed, even on failure.
		out, err := exec.Command("sh", "-c", *smtpPassCmd).Output()
		if err != nil {
			dief("smtp pass command failed")
		}
		pass = strings.TrimSpace(string(out))
	}
	from := *smtpFrom
	if from == "" {
		from = *smtpUser
	}
	if from == "" {
		dief("a From address is required: -smtp-from, or -smtp-user")
	}
	msg, err := buildMessage(from, recipients, ccs, bccs, *subject, body, attach, *attachName)
	if err != nil {
		die(err)
	}
	if *dryRun {
		os.Stdout.Write(msg)
		return
	}
	cfg := mailConfig{host: *smtpHost, user: *smtpUser, pass: pass, from: from,
		to: recipients, cc: ccs, bcc: bccs, timeout: time.Duration(*timeout) * time.Second}
	if err := sendMail(cfg, msg); err != nil {
		die(err)
	}
	fmt.Println("Email sent")
}
