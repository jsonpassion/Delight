#!/usr/bin/env python3
"""웹앱 HTML 구조 검증 — 태그 균형과 목차-섹션 대응을 확인한다."""
from html.parser import HTMLParser
import pathlib, re, sys

VOID = {"area","base","br","col","embed","hr","img","input","link","meta","param",
        "source","track","wbr","path","circle","rect","line","polygon","polyline",
        "text","use","stop","ellipse"}

class Check(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.errors = [], []
    def handle_starttag(self, tag, attrs):
        if tag not in VOID: self.stack.append((tag, self.getpos()))
    def handle_endtag(self, tag):
        if tag in VOID: return
        if not self.stack:
            self.errors.append(f"과잉 </{tag}> at {self.getpos()}"); return
        top, pos = self.stack.pop()
        if top != tag:
            self.errors.append(f"불일치 <{top}> {pos} vs </{tag}> {self.getpos()}")

failed = False
for name in ["web/index.html", "web/pipeline.html"]:
    src = pathlib.Path(name).read_text()
    c = Check(); c.feed(src)
    problems = c.errors + [f"닫히지 않음 <{t}>" for t, _ in c.stack]
    print(f"{name:20} {'OK' if not problems else 'FAIL'}  ({len(src):,}B)")
    for e in problems[:6]: print("   ", e); failed = True

# 목차 링크가 실제 섹션 id와 대응하는가
src = pathlib.Path("web/pipeline.html").read_text()
toc = set(re.findall(r'href="#([\w-]+)"', src.split("</nav>")[0]))
ids = set(re.findall(r'<section id="([\w-]+)"', src))
for missing in sorted(toc - ids): print(f"목차에만 있음: #{missing}"); failed = True
for orphan in sorted(ids - toc): print(f"목차에 없음:   #{orphan}"); failed = True
print(f"목차 {len(toc)}개 / 섹션 {len(ids)}개 {'OK' if not failed else ''}")
sys.exit(1 if failed else 0)
