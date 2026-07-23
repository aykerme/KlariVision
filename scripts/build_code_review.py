"""Build one browsable local page containing the project's reviewable text files."""

from __future__ import annotations

import html
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
OUTPUT = PROJECT_ROOT / "outputs" / "kod-inceleme.html"
INCLUDED = ("src", "tests", "scripts", "docs", "README.md", "pyproject.toml")
SUFFIXES = {".py", ".md", ".toml"}


def files_for_review() -> list[Path]:
    files: list[Path] = []
    for item in INCLUDED:
        path = PROJECT_ROOT / item
        if path.is_file() and path.suffix in SUFFIXES:
            files.append(path)
        elif path.is_dir():
            files.extend(file for file in path.rglob("*") if file.is_file() and file.suffix in SUFFIXES)
    return sorted(files)


def build() -> None:
    documents = []
    navigation = []
    for index, path in enumerate(files_for_review()):
        relative = path.relative_to(PROJECT_ROOT).as_posix()
        anchor = f"file-{index}"
        source = html.escape(path.read_text(encoding="utf-8"))
        navigation.append(f'<a href="#{anchor}">{html.escape(relative)}</a>')
        documents.append(
            f'<details id="{anchor}"><summary>{html.escape(relative)}</summary>'
            f'<pre><code>{source}</code></pre></details>'
        )

    OUTPUT.parent.mkdir(exist_ok=True)
    OUTPUT.write_text(
        "<!doctype html><html lang=\"tr\"><meta charset=\"utf-8\">"
        "<title>KlariVision · Kod İnceleme</title>"
        "<style>body{margin:0;font:14px ui-monospace,SFMono-Regular,Menlo,monospace;color:#1f2933;background:#f6f8fa}"
        "header{position:sticky;top:0;padding:16px 24px;background:#17212b;color:#fff;z-index:2}"
        "header h1{font:600 20px system-ui;margin:0 0 5px}header p{font:14px system-ui;margin:0;color:#d7e0e8}"
        "main{display:grid;grid-template-columns:280px minmax(0,1fr);gap:20px;max-width:1500px;margin:auto;padding:20px}"
        "nav{position:sticky;top:87px;align-self:start;max-height:calc(100vh - 110px);overflow:auto;background:#fff;border:1px solid #d0d7de;padding:12px}"
        "nav a{display:block;padding:5px 3px;color:#0969da;text-decoration:none;overflow-wrap:anywhere}details{background:#fff;border:1px solid #d0d7de;margin-bottom:14px}"
        "summary{cursor:pointer;padding:12px;font-weight:700}pre{margin:0;padding:15px;overflow:auto;background:#0d1117;color:#c9d1d9;line-height:1.45}"
        "@media(max-width:800px){main{display:block;padding:10px}nav{position:static;max-height:300px;margin-bottom:14px}}</style>"
        "<header><h1>KlariVision · Kod İnceleme</h1><p>v0.2.0 temel sürüm · Kaynak, test, betik ve belgeler</p></header>"
        f"<main><nav>{''.join(navigation)}</nav><section>{''.join(documents)}</section></main></html>",
        encoding="utf-8",
    )


if __name__ == "__main__":
    build()
