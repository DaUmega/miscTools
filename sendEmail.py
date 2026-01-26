# Create and activate virtual environment if you don't have one yet: python3 -m venv ~/Downloads/.venv
# Activate: source ~/Downloads/.venv/bin/activate
# Dependencies: pip install --upgrade google-api-python-client google-auth-httplib2 google-auth-oauthlib
# GMAIL API SETUP REQUIRED
# Follow: https://developers.google.com/workspace/gmail/api/quickstart/python
# Usage: python3 sendEmail.py -c path/to/credentials.json -t recipient@example.com -s "Subject" -m "Body of the email" --cc "cc1@example.com,cc2@example.com" --bcc "bcc1@example.com,bcc2@example.com" -a file1.txt file2.pdf
# token.json cannot be re-used in other machines, need fresh authentication using credentials.json

import os
import base64
import argparse
import mimetypes
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.mime.base import MIMEBase
from email import encoders

SCOPES = ['https://www.googleapis.com/auth/gmail.send']

print("[i] For authentication in ssh/headless environments, note the port number in the URL: redirect_uri=http%3A%2F%2Flocalhost%3A49651...")
print("[i] Then run ssh -i ~/.ssh/id_ed25519 -N -L 49651:localhost:49651 ubuntu@<vps_ip>")

def get_gmail_service(credentials_path):
    credentials_path = os.path.abspath(credentials_path)
    creds = None
    token_path = os.path.join(os.path.dirname(credentials_path), 'token.json')
    if os.path.exists(token_path):
        creds = Credentials.from_authorized_user_file(token_path, SCOPES)
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            flow = InstalledAppFlow.from_client_secrets_file(credentials_path, SCOPES)
            creds = flow.run_local_server(open_browser=False, port=0)
        with open(token_path, 'w') as token:
            token.write(creds.to_json())
    return build('gmail', 'v1', credentials=creds)

def create_message(sender, to, subject, message_text, attachment_paths=None, cc=None, bcc=None):
    # If multiple emails, join them into comma-separated strings
    cc_header = ",".join(cc) if isinstance(cc, list) else cc
    bcc_header = ",".join(bcc) if isinstance(bcc, list) else bcc

    if attachment_paths:
        message = MIMEMultipart()
        message['to'], message['from'], message['subject'] = to, sender, subject
        if cc_header:
            message['cc'] = cc_header
        if bcc_header:
            message['bcc'] = bcc_header

        # Attach text part
        text_part = MIMEText(message_text)
        message.attach(text_part)

        # Attach files
        for attachment_path in attachment_paths:
            attachment_path = os.path.abspath(attachment_path)
            if not os.path.exists(attachment_path):
                raise FileNotFoundError(f"Attachment file not found: {attachment_path}")
            with open(attachment_path, 'rb') as f:
                file_data = f.read()
            filename = os.path.basename(attachment_path)
            content_type, _ = mimetypes.guess_type(attachment_path)
            if content_type:
                main_type, sub_type = content_type.split('/', 1)
                attachment = MIMEBase(main_type, sub_type)
            else:
                attachment = MIMEBase('application', 'octet-stream')
            attachment.set_payload(file_data)
            encoders.encode_base64(attachment)
            attachment.add_header('Content-Disposition', f'attachment; filename="{filename}"')
            message.attach(attachment)
    else:
        message = MIMEText(message_text)
        message['to'], message['from'], message['subject'] = to, sender, subject
        if cc_header:
            message['cc'] = cc_header
        if bcc_header:
            message['bcc'] = bcc_header
    return {'raw': base64.urlsafe_b64encode(message.as_bytes()).decode('utf-8')}

def send_email(service, sender, to, subject, message_text, attachment_paths=None, cc=None, bcc=None):
    message = create_message(sender, to, subject, message_text, attachment_paths, cc, bcc)
    sent_message = service.users().messages().send(userId='me', body=message).execute()
    print(f"Email sent! Message ID: {sent_message['id']}")

def main():
    parser = argparse.ArgumentParser(description="Send email via Gmail API", add_help=True)
    parser.add_argument("-c", "--credentials", required=True, help="Path to credentials.json file")
    parser.add_argument("-t", "--to", required=True, help="Recipient's email")
    parser.add_argument("-s", "--subject", required=True, help="Email subject")
    parser.add_argument("-m", "--message", required=True, help="Email body")
    parser.add_argument("-a", "--attachment", nargs='*', help="Path(s) to attachment file(s) (optional)")
    parser.add_argument("--cc", help="CC recipient(s), comma-separated")
    parser.add_argument("--bcc", help="BCC recipient(s), comma-separated")
    args = parser.parse_args()

    # Convert CC/BCC to list
    cc_list = [e.strip() for e in args.cc.split(",") if e.strip()] if args.cc else None
    bcc_list = [e.strip() for e in args.bcc.split(",") if e.strip()] if args.bcc else None

    args.credentials = os.path.abspath(args.credentials)  # Convert to absolute path
    if args.attachment:
        args.attachment = [os.path.abspath(a) for a in args.attachment]  # Convert all attachments to absolute paths

    if not os.path.exists(args.credentials):
        raise FileNotFoundError(f"Credentials file not found: {args.credentials}")

    service = get_gmail_service(args.credentials)
    send_email(
        service,
        'me',
        args.to,
        args.subject,
        args.message,
        attachment_paths=args.attachment,
        cc=cc_list,
        bcc=bcc_list
    )

if __name__ == '__main__':
    main()
