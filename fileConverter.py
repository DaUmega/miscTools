#!/usr/bin/env python3
import subprocess
import shutil
import sys
import mimetypes
from pathlib import Path
from collections import deque

EXTENSION_MIME_OVERRIDES = {
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "png": "image/png",
    "pdf": "application/pdf",
    "md": "text/markdown",
    "html": "text/html",
    "htm": "text/html",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
}

def mime_from_extension(ext: str) -> str:
    ext = ext.lower().lstrip(".")
    if ext in EXTENSION_MIME_OVERRIDES:
        return EXTENSION_MIME_OVERRIDES[ext]

    mime, _ = mimetypes.guess_type(f"file.{ext}")
    if not mime:
        raise ValueError(f"Unknown output extension: .{ext}")
    return mime

# ----------------------------
# Tool registry
# ----------------------------

TOOLS = {
    "pdftoppm": {
        "bin": "pdftoppm",
        "install": "sudo apt install poppler-utils",
        "conversions": {
            ("application/pdf", "image/png"): lambda s, d: [
                "pdftoppm", "-png", "-r", "300", s, d
            ],
            ("application/pdf", "image/jpeg"): lambda s, d: [
                "pdftoppm", "-jpeg", "-r", "300", s, d
            ],
        },
    },
    "ghostscript": {
        "bin": "gs",
        "install": "sudo apt install ghostscript",
        "conversions": {
            ("application/pdf", "image/png"): lambda s, d: [
                "gs", "-dSAFER", "-dBATCH", "-dNOPAUSE",
                "-sDEVICE=png16m", "-r300",
                f"-sOutputFile={d}-%03d.png", s
            ],
        },
    },
    "soffice": {
        "bin": "soffice",
        "install": "sudo apt install libreoffice",
        "conversions": {
            ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/pdf"):
                lambda s, d: ["soffice", "--headless", "--convert-to", "pdf", "--outdir", d, s],
        },
    },
    "pandoc": {
        "bin": "pandoc",
        "install": "sudo apt install pandoc",
        "conversions": {
            ("text/markdown", "text/html"):
                lambda s, d: ["pandoc", s, "-o", d],
            ("text/markdown", "application/pdf"):
                lambda s, d: ["pandoc", s, "-o", d],
        },
    },
}

# ----------------------------
# Helpers
# ----------------------------

def have(binname):
    return shutil.which(binname) is not None

def mime(path):
    return mimetypes.guess_type(path)[0]

def require_tool(tool):
    if not have(tool["bin"]):
        print(f"\nMissing dependency: {tool['bin']}")
        print(f"Install with:\n  {tool['install']}\n")
        sys.exit(1)

# ----------------------------
# Graph search (BFS)
# ----------------------------

def build_graph():
    graph = {}
    for tool in TOOLS.values():
        for (src, dst) in tool["conversions"]:
            graph.setdefault(src, []).append(dst)
    return graph

def find_path(start, goal, graph):
    q = deque([(start, [])])
    seen = set()

    while q:
        node, path = q.popleft()
        if node == goal:
            return path + [node]
        if node in seen:
            continue
        seen.add(node)
        for nxt in graph.get(node, []):
            q.append((nxt, path + [node]))
    return None

def find_tool(src, dst):
    for tool in TOOLS.values():
        if (src, dst) in tool["conversions"]:
            return tool, tool["conversions"][(src, dst)]
    return None, None

# ----------------------------
# Execution
# ----------------------------

def convert(src, target_mime, out_prefix):
    graph = build_graph()
    src_mime = mime(src)

    if not src_mime:
        raise RuntimeError("Unknown source MIME type")

    path = find_path(src_mime, target_mime, graph)
    if not path:
        raise RuntimeError(f"No conversion path from {src_mime} → {target_mime}")

    current = src
    for i in range(len(path) - 1):
        a, b = path[i], path[i + 1]
        tool, cmd_fn = find_tool(a, b)
        require_tool(tool)

        out = out_prefix if i == len(path) - 2 else f"{out_prefix}.tmp{i}"
        cmd = cmd_fn(current, out)

        print("RUN:", " ".join(cmd))
        subprocess.run(cmd, check=True)

        current = out

# ----------------------------
# CLI
# ----------------------------

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: fileConverter.py <input> <output-extension> <output-prefix>")
        print("Example: fileConverter.py file.pdf png page")
        sys.exit(1)

    src = sys.argv[1]
    ext = sys.argv[2]
    out_prefix = sys.argv[3]

    target_mime = mime_from_extension(ext)
    convert(src, target_mime, out_prefix)
