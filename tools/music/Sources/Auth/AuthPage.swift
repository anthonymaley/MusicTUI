import ArgumentParser
import Foundation

struct AuthPage {
    /// Write the auth HTML and return the file path.
    func generate(developerToken: String, port: Int) throws -> String {
        let path = NSString(string: "~/.config/music/auth.html").expandingTildeInPath
        let html = """
        <!DOCTYPE html>
        <html><head><title>Apple Music Auth</title>
        <script src="https://js-cdn.music.apple.com/musickit/v3/musickit.js"></script>
        </head><body style="font-family:system-ui;max-width:600px;margin:40px auto;text-align:center">
        <h2>Apple Music Authorization</h2>
        <p>Click to sign in with your Apple ID.</p>
        <button id="auth" style="font-size:18px;padding:12px 24px;cursor:pointer;border-radius:8px;border:1px solid #ccc;background:#fff">Sign In with Apple Music</button>
        <div id="status" style="margin-top:20px"></div>
        <div id="fallback" style="display:none;margin-top:10px"></div>
        <script>
        document.addEventListener('musickitloaded', async () => {
            const music = await MusicKit.configure({
                developerToken: '\(developerToken)',
                app: { name: 'music', build: '1.0' }
            });
            document.getElementById('auth').onclick = async () => {
                const statusEl = document.getElementById('status');
                try {
                    statusEl.textContent = 'Waiting for Apple sign-in...';
                    statusEl.style.color = '#666';
                    await music.authorize();
                    const token = music.musicUserToken;
                    statusEl.textContent = 'Saving token...';
                    const resp = await fetch('http://localhost:\(port)/callback?token=' + encodeURIComponent(token));
                    if (resp.ok) {
                        statusEl.textContent = 'Token saved! You can close this tab.';
                        statusEl.style.color = 'green';
                        statusEl.style.fontWeight = 'bold';
                        document.getElementById('auth').style.display = 'none';
                    } else {
                        statusEl.textContent = 'Failed to save token. Copy it manually:';
                        statusEl.style.color = 'red';
                        showManualFallback(token);
                    }
                } catch(e) {
                    statusEl.textContent = 'Error: ' + e;
                    statusEl.style.color = 'red';
                }
            };
        });
        function showManualFallback(token) {
            const fb = document.getElementById('fallback');
            const ta = document.createElement('textarea');
            ta.value = token;
            ta.style.cssText = 'width:100%;height:80px;font-size:12px;margin-top:10px';
            ta.onclick = function() { this.select(); };
            ta.readOnly = true;
            fb.appendChild(ta);
            const p = document.createElement('p');
            p.textContent = 'Run: music auth set-token PASTE_HERE';
            fb.appendChild(p);
            fb.style.display = 'block';
        }
        </script></body></html>
        """
        try FileManager.default.createDirectory(atPath: AuthManager.configDir, withIntermediateDirectories: true)
        try html.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Serve the auth page with a callback endpoint that auto-saves the token.
    func serve(developerToken: String) throws {
        let port = 8537
        let htmlPath = try generate(developerToken: developerToken, port: port)
        let dir = (htmlPath as NSString).deletingLastPathComponent
        let filename = (htmlPath as NSString).lastPathComponent

        // Python server that handles both file serving and the token callback
        let serverScript = """
        import http.server, urllib.parse, os, sys

        token_path = os.path.expanduser('~/.config/music/user-token')

        class Handler(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory='\(dir)', **kwargs)

            def do_GET(self):
                parsed = urllib.parse.urlparse(self.path)
                if parsed.path == '/callback':
                    params = urllib.parse.parse_qs(parsed.query)
                    token = params.get('token', [''])[0]
                    if token:
                        os.makedirs(os.path.dirname(token_path), exist_ok=True)
                        with open(token_path, 'w') as f:
                            f.write(token)
                        self.send_response(200)
                        self.send_header('Content-Type', 'text/plain')
                        self.send_header('Access-Control-Allow-Origin', '*')
                        self.end_headers()
                        self.wfile.write(b'OK')
                    else:
                        self.send_response(400)
                        self.end_headers()
                        self.wfile.write(b'No token')
                else:
                    super().do_GET()

            def log_message(self, format, *args):
                pass

        server = http.server.HTTPServer(('127.0.0.1', \(port)), Handler)
        print('READY', flush=True)
        server.serve_forever()
        """

        let scriptPath = "\(dir)/auth_server.py"
        try serverScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)

        // Start server
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [scriptPath]

        let pipe = Pipe()
        server.standardOutput = pipe
        server.standardError = FileHandle.nullDevice
        try server.run()

        // Wait for READY signal instead of fixed sleep
        let handle = pipe.fileHandleForReading
        var ready = false
        let deadline = Date().addingTimeInterval(5)
        while !ready && Date() < deadline {
            let data = handle.availableData
            if !data.isEmpty, let output = String(data: data, encoding: .utf8), output.contains("READY") {
                ready = true
            } else {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        guard ready else {
            print("Failed to start auth server on port \(port). Is something else using it?")
            server.terminate()
            throw ExitCode.failure
        }

        // Open browser
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["http://localhost:\(port)/\(filename)"]
        try open.run()
        open.waitUntilExit()

        print("Auth page opened at http://localhost:\(port)/\(filename)")
        print("")
        print("Sign in with your Apple ID — the token will be saved automatically.")
        print("Press Enter when done to stop the server...")

        // Wait for user to press Enter (token is auto-saved via callback)
        _ = readLine()
        server.terminate()

        // Clean up server script
        try? FileManager.default.removeItem(atPath: scriptPath)

        // Verify token was saved
        let auth = AuthManager()
        if let token = auth.userToken() {
            let storefront = auth.storefront()
            let (_, status) = try syncRun {
                try await RESTAPIBackend(developerToken: developerToken, userToken: token, storefront: storefront)
                    .get("/v1/me/storefront")
            }
            if (200...299).contains(status) {
                print("")
                print("Token saved and verified. You're all set!")
            } else {
                print("")
                print("Token saved but verification failed (status \(status)). Try again with: music auth")
            }
        } else {
            print("")
            print("No token received. Try again with: music auth")
        }
    }
}
