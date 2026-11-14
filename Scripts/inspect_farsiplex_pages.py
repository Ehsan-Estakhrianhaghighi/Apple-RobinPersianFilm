#!/usr/bin/env python3
"""Read-only inspection of public FarsiPlex title pages. No playback or ad bypass."""
from html.parser import HTMLParser
from urllib.request import Request, urlopen, build_opener, HTTPCookieProcessor, HTTPRedirectHandler
from urllib.parse import urlencode, parse_qs, unquote
from http.cookiejar import CookieJar
import socket
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

# Compare provider-published public search listings for fallback availability.
for q in ("Taxi","Balit","Mashghe Emshab","Ostokhan Sooz","Meymoone Mast"):
    url = "https://farsiland.com/?"+urlencode({"s":q})
    try:
        with urlopen(Request(url,headers={"User-Agent":"Mozilla/5.0"}),timeout=9) as response:
            html = response.read(200000).decode("utf-8",errors="replace")
            print("farsiland-search",q,"status",response.status,
                  "final-path",urlparse(response.geturl()).path,
                  "matches",len(re.findall(r"/(?:movies|episodes|tvshows)/",html,re.I)),
                  "bytes",len(html))
    except Exception as e:
        print("farsiland-search",q,"error",type(e).__name__)

for path in ("/tvshows/ostokhan-sooz/", "/episodes/ostokhan-sooz-ep01/",
             "/tvshows/taxi/", "/episodes/taxi-ep01/"):
    try:
        testurl="https://farsiland.com"+path
        with urlopen(Request(testurl,headers={"User-Agent":"Mozilla/5.0"}),timeout=9) as response:
            body=response.read(180000).decode("utf-8",errors="replace")
            p=Trace()
            p.feed(body)
            print("farsiland-public",path,response.status,"bytes",len(body),
                  "forms",[(form["method"],urlparse(form["action"]).hostname,
                             urlparse(form["action"]).path, [x[0] for x in form["fields"]][:9])
                           for form in p.forms[:12]])
    except Exception as e:
        print("farsiland-public",path,"error",type(e).__name__)

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
                                if k == "source":
                                    try:
                                        socket.getaddrinfo(inner.hostname,443)
                                        print("dns:",inner.hostname,"resolves")
                                    except Exception as dns_error:
                                        print("dns:",inner.hostname,type(dns_error).__name__)
                                    try:
                                        frame_request = Request(m.group(0).split("&quot;")[0],
                                            headers={"User-Agent":"Mozilla/5.0 Chrome/120.0 Safari/537.36",
                                                     "Referer":follow_url})
                                        with opener.open(frame_request,timeout=9) as frame:
                                            frame_text=frame.read(150000).decode("utf-8",errors="replace")
                                            print("jwplayer:",frame.status,"html_bytes",len(frame_text))
                                        print("jwplayer contains:",{
                                            k:len(re.findall(re.escape(k),frame_text,re.I))
                                            for k in ("cdn2.farsiland.com","pl.farsiplex.buzz","video","source",
                                                      "fetch(","xmlhttprequest","player.setup","jwplayer(", ".mp4")})
                                        if not globals().get("_printed_frame_hints",False):
                                            globals()["_printed_frame_hints"] = True
                                            for word in ("URLSearchParams", "fetch(", "new URL(", "source", "player.setup", "jwplayer(", ".replace(", "playlist", "file:", "token", "src:"):
                                                hits=list(re.finditer(re.escape(word),frame_text,re.I))
                                                contexts=[scrub(frame_text[max(0,m.start()-100):m.start()+150]) for m in hits[:2]]
                                                print("frame-hint:",word,"hits:",len(hits),"contexts:",contexts)
                                            for word in ("var jw =", "let jw =", "const jw =", "sources: [{", "Server 1", "Server 2", "jw.file", "jw.file2"):
                                                matches = list(re.finditer(re.escape(word),frame_text,re.I))
                                                for item in matches[:1]:
                                                    excerpt = frame_text[max(0,item.start()-100):item.start()+1200]
                                                    excerpt = re.sub(r"https?://[^\\s'\"<>]+","[REDACTED_URL]",excerpt)
                                                    excerpt = re.sub(r"(?i)(md5|token|sig|signature|auth)=[^&\\s'\"<>]+",r"\\1=[REDACTED]",excerpt)
                                                    print("frame-config:",word,len(matches),excerpt.replace("\\n"," ")[:1000])
                                        iframe = Trace()
                                        iframe.feed(frame_text)
                                        print("jwplayer scripts:",[
                                            urlparse(urljoin("https://farsiplex.com/jwplayer/",sc)).path
                                            for sc in iframe.scripts[:20]])
                                    except Exception as frame_error:
                                        print("jwplayer-error:",type(frame_error).__name__,scrub(str(frame_error)))
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
