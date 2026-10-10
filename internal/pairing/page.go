package pairing

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"html/template"
	"net/http"
	"strconv"
	"strings"
)

// pageStyle and pageScript are the page's only inline resources. The
// Content-Security-Policy names each by hash, so nothing else can run or
// style the page.
const pageStyle = `
:root{color-scheme:light dark;--bg:#f2f2f7;--card:#fff;--text:#1c1c1e;--muted:#6c6c70;--line:#e5e5ea;--accent:#0f7a66;--on-accent:#fff;--field:#f2f2f7}
@media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--text:#fff;--muted:#a1a1a6;--line:#38383a;--accent:#77e7d1;--on-accent:#06251f;--field:#2c2c2e}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);font:17px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
main{max-width:640px;margin:0 auto;padding:24px 16px 40px}
h1{font-size:28px;line-height:1.15;margin:8px 0 6px;font-weight:700;letter-spacing:-.01em}
h2{font-size:20px;margin:0 0 4px;font-weight:600}
p{margin:0}
.lede,.foot{color:var(--muted);font-size:15px}
.note{margin-top:8px}
.foot{margin-top:24px}
.card{background:var(--card);border-radius:16px;padding:16px;margin-top:16px}
.steps{margin:8px 0 4px;padding-left:20px;color:var(--muted);font-size:15px}
.steps li{margin:2px 0}
.field{margin-top:12px;padding-top:12px;border-top:1px solid var(--line)}
.label{font-size:13px;color:var(--muted);margin-bottom:4px}
.row{display:flex;align-items:center;gap:12px}
.val{flex:1;min-width:0;font:15px/1.35 ui-monospace,SFMono-Regular,Menlo,monospace;overflow-wrap:anywhere;word-break:break-all;background:var(--field);border-radius:10px;padding:10px 12px}
.btn{display:inline-flex;align-items:center;justify-content:center;min-height:44px;padding:0 16px;border-radius:12px;border:0;font:600 16px/1 -apple-system,system-ui,sans-serif;background:var(--accent);color:var(--on-accent);text-decoration:none}
.copy{display:none;width:88px;flex:none}
.js .copy{display:inline-flex}
.link{margin-top:14px}
.sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
.gone{text-align:center;padding-top:56px}
`

const pageScript = `
(function(){
document.documentElement.className='js';
var live=document.getElementById('live');
function fallbackCopy(text){
var t=document.createElement('textarea');
t.value=text;t.setAttribute('readonly','');
t.style.position='fixed';t.style.top='0';t.style.opacity='0';
document.body.appendChild(t);t.select();t.setSelectionRange(0,text.length);
var ok=false;try{ok=document.execCommand('copy');}catch(e){}
document.body.removeChild(t);return ok;
}
function copyText(text){
if(window.isSecureContext&&navigator.clipboard&&navigator.clipboard.writeText){
return navigator.clipboard.writeText(text).then(function(){return true;},function(){return fallbackCopy(text);});
}
return Promise.resolve(fallbackCopy(text));
}
var buttons=document.querySelectorAll('button.copy');
for(var i=0;i<buttons.length;i++){(function(b){
b.addEventListener('click',function(){
var text=document.getElementById(b.getAttribute('data-for')).textContent;
copyText(text).then(function(ok){
var was=b.getAttribute('data-label');
b.textContent=ok?'Copied':'Select it';
if(ok&&live){live.textContent='Copied '+b.getAttribute('data-name');}
setTimeout(function(){b.textContent=was;},1600);
});
});
})(buttons[i]);}
})();
`

var pageTemplate = template.Must(template.New("page").Parse(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<meta name="referrer" content="no-referrer">
<title>Connect a follower app</title>
<style>{{.Style}}</style>
</head>
<body>
<main>
<h1>Connect your follower app</h1>
<p class="lede">Find your app below. Tap Copy next to each value and paste it into the app.</p>
{{if .LocalNetwork}}<p class="lede note">Each phone needs CGM Relay's certificate once before it can connect over your Wi-Fi. To add another phone, choose Set Up a Phone in CGM Relay's Advanced settings on your Mac.</p>{{end}}
{{range .Apps}}
<section class="card" aria-labelledby="{{.ID}}-h">
<h2 id="{{.ID}}-h">{{.Name}}</h2>
<ol class="steps">{{range .Steps}}<li>{{.}}</li>{{end}}</ol>
{{range .Fields}}
<div class="field">
<div class="label" id="{{.ID}}-l">{{.Label}}</div>
<div class="row"><code class="val" id="{{.ID}}" aria-labelledby="{{.ID}}-l">{{.Value}}</code><button type="button" class="btn copy" data-for="{{.ID}}" data-label="Copy" data-name="{{.Label}}" aria-label="Copy {{.Label}} for {{.App}}">Copy</button></div>
</div>
{{end}}
{{range .Links}}<p class="link"><a class="btn" href="{{.URL}}">{{.Label}}</a></p>{{end}}
</section>
{{end}}
<p class="foot">This page shows your access token and stops working when the code on your Mac expires. Close it when you are done.</p>
<div id="live" class="sr" role="status" aria-live="polite"></div>
</main>
<script>{{.Script}}</script>
</body>
</html>
`))

var expiredTemplate = template.Must(template.New("expired").Parse(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<meta name="referrer" content="no-referrer">
<title>Code expired</title>
<style>{{.Style}}</style>
</head>
<body>
<main class="gone">
<h1>This code has expired</h1>
<p class="lede">Scan the new code on your Mac to try again.</p>
</main>
</body>
</html>
`))

type link struct {
	Label string
	URL   template.URL
}

type field struct {
	ID, Label, Value, App string
}

type appCard struct {
	ID, Name string
	Steps    []string
	Fields   []field
	Links    []link
}

type pageData struct {
	Style  template.CSS
	Script template.JS
	Apps   []appCard
	// LocalNetwork is set when the page is served over the relay's own TLS
	// listener, which a phone reaches only after the certificate step.
	LocalNetwork bool
}

type expiredData struct{ Style template.CSS }

// cards turns the minted apps into what the template shows, inserting
// token where a field's value asks for it.
func cards(apps []App, token string) []appCard {
	out := make([]appCard, len(apps))
	for i, a := range apps {
		id := "a" + strconv.Itoa(i)
		c := appCard{ID: id, Name: a.Name, Steps: a.Steps}
		for j, f := range a.Fields {
			c.Fields = append(c.Fields, field{
				ID:    id + "-f" + strconv.Itoa(j),
				Label: f.Label,
				Value: strings.ReplaceAll(f.Value, tokenPlaceholder, token),
				App:   a.Name,
			})
		}
		for _, l := range a.Links {
			c.Links = append(c.Links, link{Label: l.Label, URL: template.URL(l.URL)})
		}
		out[i] = c
	}
	return out
}

func cspHash(s string) string {
	sum := sha256.Sum256([]byte(s))
	return "'sha256-" + base64.StdEncoding.EncodeToString(sum[:]) + "'"
}

var contentSecurityPolicy = "default-src 'none'; style-src " + cspHash(pageStyle) +
	"; script-src " + cspHash(pageScript) + "; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

func setSecurityHeaders(w http.ResponseWriter) {
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Cache-Control", "no-store")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("Content-Security-Policy", contentSecurityPolicy)
	h.Set("X-Robots-Tag", "noindex")
	h.Set("X-Content-Type-Options", "nosniff")
}

// PageHandler serves GET /connect/<code>: the pairing page for the store's
// live code, or a token-free "expired" page for anything else. token is the
// relay's access token and appears only in a page served for a live code.
// Served over the relay's own TLS (the local network route), the page also
// says each phone needs the certificate step once.
func PageHandler(store *Store, token string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		code := strings.TrimPrefix(r.URL.Path, "/connect/")
		apps, live := store.Lookup(code)
		setSecurityHeaders(w)

		var buf bytes.Buffer
		status := http.StatusOK
		if live {
			data := pageData{Style: template.CSS(pageStyle), Script: template.JS(pageScript), Apps: cards(apps, token), LocalNetwork: r.TLS != nil}
			if err := pageTemplate.Execute(&buf, data); err != nil {
				live = false
			}
		}
		if !live {
			buf.Reset()
			status = http.StatusGone
			_ = expiredTemplate.Execute(&buf, expiredData{Style: template.CSS(pageStyle)})
		}
		w.WriteHeader(status)
		if r.Method == http.MethodGet {
			_, _ = w.Write(buf.Bytes())
		}
	})
}
