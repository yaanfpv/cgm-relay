package nightscout

import "net/http"

const rootPage = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CGM Relay</title>
</head>
<body>
<h1>CGM Relay</h1>
<p>This is a CGM Relay. Follower apps read glucose from it using the access token set up in the CGM Relay app.</p>
</body>
</html>
`

// handleRoot serves the plain page at "/", the address a follower app opens
// when someone taps its service status. It shows nothing about the relay's
// readings, token, account, address or version.
func (h *handler) handleRoot(w http.ResponseWriter, r *http.Request) {
	hdr := w.Header()
	hdr.Set("Content-Type", "text/html; charset=utf-8")
	hdr.Set("X-Content-Type-Options", "nosniff")
	hdr.Set("Referrer-Policy", "no-referrer")
	hdr.Set("Content-Security-Policy", "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	hdr.Set("X-Robots-Tag", "noindex")
	hdr.Set("Cache-Control", "no-store")
	_, _ = w.Write([]byte(rootPage))
}
