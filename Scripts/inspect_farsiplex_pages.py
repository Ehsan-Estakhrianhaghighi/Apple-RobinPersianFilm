#!/usr/bin/env python3
"""Read-only inspection of public FarsiPlex title pages. No playback or ad bypass."""
from html.parser import HTMLParser
from urllib.request import Request, urlopen, build_opener, HTTPCookieProcessor, HTTPRedirectHandler
from urllib.parse import urlencode, parse_qs, unquote
from http.cookiejar import CookieJar
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
        self.forms = []
        self.current = None
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "form":
            self.current = {"action": attrs.get("action",""), "method": attrs.get("method","get"), "id": attrs.get("id",""), "fields":[],"data":{}}
            self.forms.append(self.current)
        elif tag == "input" and self.current is not None:
            self.current["fields"].append((attrs.get("name",""), attrs.get("type","text"), bool(attrs.get("value"))))
            if attrs.get("name") and attrs.get("type") == "hidden": self.current["data"][attrs["name"]] = attrs.get("value","")
        if tag == "script" and attrs.get("src"):
            self.scripts.append(attrs["src"])
        if tag in ("a", "iframe", "form", "video", "source", "button"):
            rec = {k:v for k,v in attrs.items() if k in
                 ("href","src","action","data-url","data-href","onclick","id","class","data-player","data-post","data-id")}
            if any(w in str(rec).lower() for w in KEYWORDS):
                self.elements.append((tag,rec))

    def handle_endtag(self, tag):
        if tag == "form": self.current = None

for url in URLS:
    print("\nTITLE:",url,flush=True)
    opener = build_opener(HTTPCookieProcessor(CookieJar()))
    req = Request(url,headers={"User-Agent":"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120.0 Safari/537.36","Accept":"text/html"})
    try:
        with opener.open(req,timeout=12) as response:
            raw=response.read(1_400_000)
            code=response.status
            final=response.geturl()
        html=raw.decode("utf-8",errors="replace")
        parser=Trace()
        parser.feed(html)
        print("status:",code,"final:",urlparse(final).path,"bytes:",len(raw))
        for form in parser.forms:
            print("form:",{"action":urlparse(form["action"]).path,"method":form["method"],"id":form["id"],"fields":form["fields"]})
        # Follow only the exact first-party watch form published by this title.
        # The request is equivalent to pressing the provider's public Play button.
        # It does not follow ads, use credentials, or circumvent access prompts.
        watch = next((f for f in parser.forms
                      if f["id"].startswith("watch-") and
                      f["method"].lower() == "post" and
                      urlparse(f["action"]).path == "/play/" and
                      set(f["data"]) == {"id"}), None)
        if watch and watch["data"]["id"].isdigit():
            try:
                post = Request("https://farsiplex.com/play/",
                    data=urlencode(watch["data"]).encode("ascii"),
                    headers={"User-Agent":"Mozilla/5.0 Chrome/120.0 Safari/537.36",
                             "Referer":final,
                             "Content-Type":"application/x-www-form-urlencoded"})
                with opener.open(post,timeout=12) as response:
                    follow_html = response.read(450000).decode("utf-8",errors="replace")
                    follow_url = response.geturl()
                    print("watch-form response:",response.status,
                          "final-host:",urlparse(follow_url).hostname,
                          "final-path:",urlparse(follow_url).path,
                          "bytes:",len(follow_html))
                    # Print only host and path, never signed query tokens.
                    decoded = follow_html.replace("\\/", "/").replace("&amp;","&")
                    media = list(re.finditer(r'https?://[^\s"<>\\]+?\.(?:mp4|m3u8)(?:\?[^\s"<>\\]*)?',decoded,re.I))
                    print("media-count",len(media))
                    for m in media[:12]:
                        u=urlparse(m.group(0).split("&quot;")[0])
                        print("media:",{"host":u.hostname,"path":u.path,
                                        "hasQuery":bool(u.query)})
                        for k,vals in parse_qs(u.query).items():
                            for val in vals[:2]:
                                inner = urlparse(unquote(val))
                                print("media-query:", {"key":k,"valueHost":inner.hostname,
                                    "valuePath":inner.path if inner.hostname else "",
                                    "length":len(val)})
                                if k == "source" and inner.hostname in {"cdn2.farsiland.com","pl.farsiplex.buzz"}:
                                    try:
                                        check = Request(val,method="HEAD",
                                            headers={"User-Agent":"Mozilla/5.0 Chrome/120.0 Safari/537.36",
                                                     "Referer":follow_url})
                                        with opener.open(check,timeout=8) as result:
                                            print("media-head:",{"status":result.status,
                                                "type":result.headers.get("Content-Type",""),
                                                "length":result.headers.get("Content-Length","")})
                                    except Exception as e:
                                        print("media-head-error:",type(e).__name__,scrub(str(e)))
                    follow = Trace()
                    follow.feed(follow_html)
                    for f2 in follow.forms:
                        if f2["id"] != "dooplay_login_user":
                            print("next-form:",{"action":urlparse(f2["action"]).path,
                                  "method":f2["method"],"id":f2["id"],"fields":f2["fields"]})
                    for k in TOKENS + ("play", "redirect.php"):
                        print("next-token",k,len(re.findall(re.escape(k),follow_html,re.I)))
            except Exception as e:
                print("watch-form error:",type(e).__name__,str(e)[:200])
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
