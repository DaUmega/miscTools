#!/usr/bin/env python3
"""
accountingTools.py — Generate invoices, receipts, and estimates as PDFs.

Usage:
    python accountingTools.py                          # guided flow
    python accountingTools.py invoice template.json   # use an existing template
    python accountingTools.py receipt template.json
    python accountingTools.py estimate template.json

Requires:  pip install reportlab
"""

import json
import sys
from datetime import date
from pathlib import Path

# ── PDF imports ───────────────────────────────────────────────────────────────

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.platypus import (
    Image, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle,
)

# ── Colour palette ────────────────────────────────────────────────────────────

GREY    = colors.HexColor("#6B7280")
BLACK   = colors.HexColor("#111111")
LIGHT   = colors.HexColor("#F3F4F6")
DIVIDER = colors.HexColor("#E5E7EB")

# ── Paths ─────────────────────────────────────────────────────────────────────

CONFIG_FILE = Path("config.json")
CLIENTS_DIR = Path("clients")
OUTPUT_DIR  = Path("output")

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def ask(prompt: str, default: str = "") -> str:
    """Prompt with an optional default. Enter alone accepts the default."""
    hint = f" [{default}]" if default else ""
    val  = input(f"  {prompt}{hint}: ").strip()
    return val or default


def ask_float(prompt: str, default: float = 0.0) -> float:
    while True:
        raw = ask(prompt, str(default))
        try:
            return float(raw)
        except ValueError:
            print("    Please enter a number.")


def load_json(path: Path) -> dict:
    with open(path) as f:
        return json.load(f)


def save_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"  ✓ Saved {path}")


def section(title: str) -> None:
    print(f"\n── {title} {'─' * max(0, 44 - len(title))}")


# ─────────────────────────────────────────────────────────────────────────────
# Config (freelancer profile)
# ─────────────────────────────────────────────────────────────────────────────

def setup_config() -> dict:
    section("Your profile (saved to config.json)")
    cfg = {
        "name":           ask("Your name / company name"),
        "email":          ask("Email"),
        "phone":          ask("Phone (optional)"),
        "address":        ask("Address (optional)"),
        "website":        ask("Website (optional)"),
        "logo":           ask("Path to logo PNG/JPG (optional)"),
        "currency_symbol":ask("Currency symbol", "$"),
        "tax_rate":       ask_float("Tax rate, e.g. 0.20 for 20% (0 to disable)", 0.0),
        "tax_label":      ask("Tax label (e.g. VAT, GST)", "Tax"),
        "invoice_terms":  ask("Invoice terms",  "Payment due within 30 days."),
        "receipt_terms":  ask("Receipt terms",  "Payment received. Thank you for your business."),
        "estimate_terms": ask("Estimate terms", "This estimate is valid for 30 days. Scope changes may affect the final price."),
        "bank_details":   ask("Bank / payment details (optional)"),
    }
    save_json(CONFIG_FILE, cfg)
    return cfg


def load_config() -> dict:
    if CONFIG_FILE.exists():
        return load_json(CONFIG_FILE)
    print("\nNo config.json found. Let's set up your profile first.")
    return setup_config()


# ─────────────────────────────────────────────────────────────────────────────
# Client
# ─────────────────────────────────────────────────────────────────────────────

def setup_client() -> dict:
    section("New client")
    client = {
        "name":    ask("Client / company name"),
        "contact": ask("Contact person (optional)"),
        "email":   ask("Client email (optional)"),
        "address": ask("Client address (optional)"),
    }
    safe   = client["name"].lower().replace(" ", "_")
    path   = CLIENTS_DIR / f"{safe}.json"
    save_json(path, client)
    print(f"  (Reuse this client next time with: {path})")
    return client


def load_client() -> dict:
    CLIENTS_DIR.mkdir(exist_ok=True)
    existing = sorted(CLIENTS_DIR.glob("*.json"))

    if existing:
        section("Client")
        print("  Existing clients:")
        for i, p in enumerate(existing, 1):
            print(f"    {i}. {p.stem}")
        print(f"    n. New client")
        choice = ask("Pick a number or 'n'").lower()
        if choice != "n":
            try:
                return load_json(existing[int(choice) - 1])
            except (ValueError, IndexError):
                print("  Invalid choice — creating new client.")

    return setup_client()


# ─────────────────────────────────────────────────────────────────────────────
# Document template (items + metadata)
# ─────────────────────────────────────────────────────────────────────────────

TEMPLATE_SCHEMAS = {
    "invoice": {
        "type": "invoice", "number": "INV-0001",
        "date": str(date.today()), "due_date": "",
        "discount_pct": 0,
        "discount_label": "",
        "notes": "",
        "items": [{"title": "Service or product", "details": "", "qty": 1, "rate": 0.0}],
    },
    "receipt": {
        "type": "receipt", "number": "REC-0001",
        "date": str(date.today()), "payment_method": "Bank Transfer",
        "reference": "",
        "discount_pct": 0,
        "discount_label": "",
        "notes": "",
        "items": [{"title": "Service or product", "details": "", "qty": 1, "rate": 0.0}],
    },
    "estimate": {
        "type": "estimate", "number": "EST-0001",
        "date": str(date.today()), "valid_until": "",
        "discount_pct": 0,
        "discount_label": "",
        "notes": "This estimate is valid until the date above.",
        "items": [{"title": "Service or product", "details": "", "qty": 1, "rate": 0.0}],
    },
}


def generate_template(doc_type: str) -> Path:
    section(f"Generate {doc_type} template")
    path = Path(ask("Save template to", f"{doc_type}_template.json"))
    save_json(path, TEMPLATE_SCHEMAS[doc_type])
    print(f"  Edit {path} then re-run:  python accountingTools.py {doc_type} {path}")
    return path


def load_template(path: Path) -> dict:
    tmpl = load_json(path)
    # Basic validation
    required = {"type", "number", "date", "items"}
    missing  = required - tmpl.keys()
    if missing:
        sys.exit(f"Template is missing fields: {', '.join(missing)}")
    if not tmpl["items"]:
        sys.exit("Template has no items.")
    return tmpl


def pick_template(doc_type: str) -> dict:
    section("Document template")
    path_str = ask("Path to template JSON (Enter to generate one)")
    if not path_str:
        path = generate_template(doc_type)
        sys.exit(0)
    path = Path(path_str)
    if not path.exists():
        sys.exit(f"File not found: {path}")
    return load_template(path)


# ─────────────────────────────────────────────────────────────────────────────
# PDF builder
# ─────────────────────────────────────────────────────────────────────────────

def _style(name, font="Helvetica", **kw):
    return ParagraphStyle(name, fontName=font, **kw)


def build_pdf(doc_type: str, tmpl: dict, cfg: dict, client: dict) -> str:
    sym      = cfg.get("currency_symbol", "$")
    items    = tmpl["items"]
    subtotal = sum(i["qty"] * i["rate"] for i in items)

    # Discount is applied to subtotal BEFORE tax so that GST/VAT is
    # calculated on the already-reduced amount.
    discount_pct   = float(tmpl.get("discount_pct", 0))
    discount_label = tmpl.get("discount_label", "Discount").strip() or "Discount"
    discount_amt   = subtotal * (discount_pct / 100) if discount_pct else 0
    discounted     = subtotal - discount_amt

    tax_rate = cfg.get("tax_rate", 0)
    tax_amt  = discounted * tax_rate if tax_rate else 0
    total    = discounted + tax_amt

    safe_num    = tmpl["number"].replace("/", "-")
    safe_client = client["name"].replace(" ", "_")
    OUTPUT_DIR.mkdir(exist_ok=True)
    filepath = str(OUTPUT_DIR / f"{safe_num}_{safe_client}.pdf")

    doc = SimpleDocTemplate(
        filepath, pagesize=A4,
        leftMargin=20*mm, rightMargin=20*mm,
        topMargin=20*mm,  bottomMargin=20*mm,
    )
    W = A4[0] - 40*mm

    sN = _style("N", fontSize=9,  textColor=BLACK, leading=13)
    sS = _style("S", fontSize=8,  textColor=GREY,  leading=12)
    sH = _style("H", font="Helvetica-Bold", fontSize=22, textColor=BLACK)
    sL = _style("L", fontSize=7,  textColor=GREY,  leading=10, spaceAfter=1)
    sV = _style("V", fontSize=9,  textColor=BLACK, leading=13)
    sT = _style("T", font="Helvetica-Bold", fontSize=12, textColor=BLACK)

    story = []

    # Header — logo left, doc type right
    logo_cell: object = ""
    logo_path = cfg.get("logo", "")
    if logo_path and Path(logo_path).exists():
        logo_cell = Image(logo_path, width=35*mm, height=18*mm, kind="proportional")

    hdr = Table([[logo_cell, Paragraph(doc_type.upper(), sH)]], colWidths=[W*.5, W*.5])
    hdr.setStyle(TableStyle([
        ("VALIGN", (0,0), (-1,-1), "MIDDLE"),
        ("ALIGN",  (1,0), (1, 0), "RIGHT"),
    ]))
    story += [hdr, Spacer(1, 6*mm)]

    # From / To
    from_txt = "<br/>".join(filter(None, [
        cfg.get("name",""), cfg.get("address",""),
        cfg.get("phone",""), cfg.get("email",""), cfg.get("website",""),
    ]))
    to_txt = "<br/>".join(filter(None, [
        client.get("name",""), client.get("contact",""),
        client.get("email",""), client.get("address",""),
    ]))
    meta_left = Table([
        [Paragraph("FROM", sL)], [Paragraph(from_txt, sS)],
        [Spacer(1,3*mm)],
        [Paragraph("TO", sL)],   [Paragraph(to_txt, sS)],
    ], colWidths=[W*.45])

    # Right-side meta fields vary by doc type
    extra = {
        "invoice":  [("DUE DATE", tmpl.get("due_date",""))],
        "receipt":  [("PAYMENT",  tmpl.get("payment_method","")),
                     ("FOR INV.", tmpl.get("reference",""))],
        "estimate": [("VALID UNTIL", tmpl.get("valid_until",""))],
    }.get(doc_type, [])
    extra = [(l, v) for l, v in extra if v]  # drop blank rows

    meta_rows  = (
        [[Paragraph(f"{doc_type.upper()} #", sL), Paragraph(tmpl["number"], sV)],
         [Paragraph("DATE", sL), Paragraph(tmpl["date"], sV)]]
        + [[Paragraph(l, sL), Paragraph(v, sV)] for l, v in extra]
    )
    meta_right = Table(meta_rows, colWidths=[W*.22, W*.33])
    meta_right.setStyle(TableStyle([
        ("ALIGN", (1,0),(1,-1), "RIGHT"),
        ("TOPPADDING",    (0,0),(-1,-1), 2),
        ("BOTTOMPADDING", (0,0),(-1,-1), 2),
    ]))

    meta = Table([[meta_left, meta_right]], colWidths=[W*.45, W*.55])
    meta.setStyle(TableStyle([("VALIGN",(0,0),(-1,-1),"TOP")]))
    story += [meta, Spacer(1, 8*mm)]

    # Line items
    rows = [[Paragraph(h, sL) for h in ("ITEM","QTY","RATE","AMOUNT")]]
    for it in items:
        amt = it["qty"] * it["rate"]
        qty = str(int(it["qty"])) if it["qty"] == int(it["qty"]) else str(it["qty"])
        title   = it.get("title", it.get("description", ""))
        details = it.get("details", "").strip()
        cell    = Paragraph(title, sN)
        if details:
            cell = Paragraph(f"{title}<br/><font size=7 color=#6B7280>{details}</font>", sN)
        rows.append([
            cell,
            Paragraph(qty, sN),
            Paragraph(f"{sym}{it['rate']:,.2f}", sN),
            Paragraph(f"{sym}{amt:,.2f}", sN),
        ])
    itbl = Table(rows, colWidths=[W*.52, W*.12, W*.18, W*.18])
    itbl.setStyle(TableStyle([
        ("BACKGROUND",    (0,0),(-1,0),  LIGHT),
        ("LINEBELOW",     (0,0),(-1,0),  0.5, DIVIDER),
        ("LINEBELOW",     (0,1),(-1,-1), 0.3, DIVIDER),
        ("ALIGN",         (1,0),(-1,-1), "RIGHT"),
        ("VALIGN",        (0,0),(-1,-1), "TOP"),
        ("TOPPADDING",    (0,0),(-1,-1), 5),
        ("BOTTOMPADDING", (0,0),(-1,-1), 5),
        ("LEFTPADDING",   (0,0),(-1,-1), 4),
        ("RIGHTPADDING",  (0,0),(-1,-1), 4),
    ]))
    story += [itbl, Spacer(1, 4*mm)]

    # Totals
    # Display order: Subtotal → Discount → Discounted subtotal → Tax → Total
    totals = [["", Paragraph("Subtotal", sN), Paragraph(f"{sym}{subtotal:,.2f}", sN)]]

    if discount_amt:
        lbl = f"{discount_label}<br/><font size=7 color=#6B7280>({discount_pct:g}% off)</font>"
        totals.append(["", Paragraph(lbl, sN), Paragraph(f"- {sym}{discount_amt:,.2f}", sN)])
        totals.append(["", Paragraph("Discounted subtotal", sN), Paragraph(f"{sym}{discounted:,.2f}", sN)])

    if tax_amt:
        totals.append(["", Paragraph(f"{cfg.get('tax_label','Tax')} ({int(tax_rate*100)}%)", sN),
                            Paragraph(f"{sym}{tax_amt:,.2f}", sN)])

    totals.append(["", Paragraph("TOTAL", sT), Paragraph(f"{sym}{total:,.2f}", sT)])

    ttbl = Table(totals, colWidths=[W*.52, W*.30, W*.18])
    last = len(totals) - 1
    ttbl.setStyle(TableStyle([
        ("ALIGN",         (1,0),(-1,-1), "RIGHT"),
        ("TOPPADDING",    (0,0),(-1,-1), 3),
        ("BOTTOMPADDING", (0,0),(-1,-1), 3),
        ("LINEABOVE",     (1,last),(-1,last), 0.8, BLACK),
    ]))
    story.append(ttbl)

    # Notes — use doc-type-specific terms from config
    terms_key  = f"{doc_type}_terms"
    note_parts = list(filter(None, [
        cfg.get(terms_key, cfg.get("payment_terms", "")),  # fallback for old configs
        cfg.get("bank_details",""), tmpl.get("notes",""),
    ]))
    if note_parts:
        story += [Spacer(1,10*mm), Paragraph("NOTES", sL), Spacer(1,1*mm)]
        for part in note_parts:
            story += [Paragraph(part, sS), Spacer(1,2*mm)]

    doc.build(story)
    return filepath


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

DOC_TYPES = ("invoice", "receipt", "estimate")


def main():
    # ── Parse optional CLI args: accountingTools.py [doc_type] [template.json] ──
    args      = sys.argv[1:]
    doc_type  = args[0].lower() if args and args[0].lower() in DOC_TYPES else None
    tmpl_arg  = args[1] if len(args) > 1 else None

    print("─" * 48)
    print("  accountingTools.py — invoice / receipt / estimate")
    print("─" * 48)

    # 1. Config
    cfg = load_config()

    # 2. Doc type
    if not doc_type:
        section("Document type")
        choice = ask("Type  [invoice / receipt / estimate]", "invoice").lower()
        doc_type = choice if choice in DOC_TYPES else "invoice"

    # 3. Client
    client = load_client()

    # 4. Template
    if tmpl_arg:
        path = Path(tmpl_arg)
        if not path.exists():
            sys.exit(f"Template not found: {path}")
        tmpl = load_template(path)
    else:
        tmpl = pick_template(doc_type)

    # 5. Build PDF
    section("Generating PDF")
    path = build_pdf(doc_type, tmpl, cfg, client)
    print(f"\n  ✓  {doc_type.capitalize()} saved → {path}\n")


if __name__ == "__main__":
    main()