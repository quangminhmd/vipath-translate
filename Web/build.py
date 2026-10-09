#!/usr/bin/env python3
"""Ghép Web/src thành một tệp ViPath.html: python3 Web/build.py"""
import base64, io, json, pathlib, re
from PIL import Image
root = pathlib.Path(__file__).resolve().parent
src = root / "src"
logic = re.sub(r"^export\s+", "", (src / "logic.js").read_text(), flags=re.M)
app = (src / "app.js").read_text()
style = (src / "style.css").read_text()
glossary = json.dumps(json.load(open(root.parent / "ViPathTranslate/Resources/glossary.json")), ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
icon_png = root.parent / "Design/AppIcon-1024.png"
im = Image.open(icon_png).convert("RGB").resize((128, 128), Image.LANCZOS)
buf = io.BytesIO(); im.save(buf, "PNG", optimize=True)
icon = "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()
html = (src / "index.html").read_text()
for k, v in {"{{STYLE}}": style, "{{LOGIC}}": logic, "{{APP}}": app, "{{GLOSSARY}}": glossary, "{{ICON}}": icon}.items():
    html = html.replace(k, v)
out = root / "ViPath.html"
out.write_text(html)
# Bản cho GitHub Pages: https://quangminhmd.github.io/vipath-translate/
docs = root.parent / "docs"
docs.mkdir(exist_ok=True)
(docs / "index.html").write_text(html)
print(out, f"{len(html)/1024:.0f} KB")
