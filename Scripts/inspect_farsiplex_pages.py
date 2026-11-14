#!/usr/bin/env python3
"""Read-only inspection of public FarsiPlex title pages. No playback or ad bypass."""
from html.parser import HTMLParser
from urllib.request import Request, urlopen
from urllib.parse import urlparse, urljoin
import re

URLS = [
    "https://farsiplex.com/movie/balit-c4048c07/",
    "https://farsiplex.com/episode/taxi-ep01-95081968/",
]
KEYWORDS = ("play", "watch", "player", "stream", "video", "source", "embed", "frame")
TOKENS = ("play-quick-view", "play-hq-player", "doo_player_ajax",
          "jwplayer", "video-js", "player_options", "ajaxurl", ".mp4")

def scrub(s):
    s = re.sub(r"(?i)(md5|token|sig|signature|auth)=[^&\s'\"<>]+", r"\1=[REDACTED]", s)
    s = re.sub(r"https?://[^\s'\"<>?#]+\?[^\s'\"<>]+", "[URL with query omitted]", s)
    return s[:180]

class Trace(HTMLParser):
    def __init__(self):
        super().__init__()
        self.elements = []
        self.scripts = []
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "script" and attrs.get("src"):
            self.scripts.append(attrs["src"])
        if tag in ("a", "iframe", "form", "video", "source", "button"):
            rec = {k:v for k,v in attrs.items() if k in
                 ("href","src","action","data-url","data-href","onclick","id","class","data-player","data-post","data-id")}
            if any(w in str(rec).lower() for w in KEYWORDS):
                self.elements.append((tag,rec))

for url in URLS:
    print("\nTITLE:",url,flush=True)
    req = Request(url,headers={"User-Agent":"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120.0 Safari/537.36","Accept":"text/html"})
    try:
        with urlopen(req,timeout=12) as response:
            raw=response.read(1_400_000)
            code=response.status
            final=response.geturl()
        html=raw.decode("utf-8",errors="replace")
        parser=Trace()
        parser.feed(html)
        print("status:",code,"final:",urlparse(final).path,"bytes:",len(raw))
        for tag,attrs in parser.elements[:25]:
            print("element:",tag,{k:scrub(v) for k,v in attrs.items()})
        for item in parser.scripts[:20]:
            print("script:",urlparse(urljoin(final,item)).path)
        for token in TOKENS:
            positions=[m.start() for m in list(re.finditer(re.escape(token),html,re.I))[:5]]
            print("token:",token,"occurrences:",len(re.findall(re.escape(token),html,re.I)),
                  "contexts:",[scrub(html[max(0,i-65):i+100]) for i in positions])
    except Exception as e:
        print("ERROR:",type(e).__name__,str(e)[:160])
