import Foundation

struct AuthPage {
    /// Write the auth HTML and return the file path.
    func generate(developerToken: String) throws -> String {
        let path = NSString(string: "~/.config/music/auth.html").expandingTildeInPath
        let html = """
        <!DOCTYPE html>
        <html><head><title>Apple Music Auth</title>
        <script src="https://js-cdn.music.apple.com/musickit/v3/musickit.js"></script>
        </head><body style="font-family:system-ui;max-width:600px;margin:40px auto;text-align:center">
        <h2>Apple Music Authorization</h2>
        <p>Click to sign in and get your user token.</p>
        <button id="auth" style="font-size:18px;padding:12px 24px;cursor:pointer">Sign In</button>
        <div id="status" style="margin-top:20px"></div>
        <textarea id="token-output" style="display:none;width:100%;height:80px;font-size:12px;margin-top:10px" onclick="this.select()" readonly></textarea>
        <p id="instructions" style="display:none">Copy the token above, then run:<br><code>music auth set-token PASTE_HERE</code></p>
        <script>
        document.addEventListener('musickitloaded', async () => {
            const music = await MusicKit.configure({
                developerToken: '\(developerToken)',
                app: { name: 'music', build: '1.0' }
            });
            document.getElementById('auth').onclick = async () => {
                const statusEl = document.getElementById('status');
                const tokenEl = document.getElementById('token-output');
                const instrEl = document.getElementById('instructions');
                try {
                    await music.authorize();
                    const token = music.musicUserToken;
                    statusEl.textContent = 'Success! Copy this token:';
                    statusEl.style.color = 'green';
                    statusEl.style.fontWeight = 'bold';
                    tokenEl.value = token;
                    tokenEl.style.display = 'block';
                    instrEl.style.display = 'block';
                } catch(e) {
                    statusEl.textContent = 'Error: ' + e;
                    statusEl.style.color = 'red';
                }
            };
        });
        </script></body></html>
        """
        try FileManager.default.createDirectory(atPath: AuthManager.configDir, withIntermediateDirectories: true)
        try html.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Serve the auth page on localhost via Python HTTP server, open browser, wait for user.
    /// MusicKit JS requires an HTTP origin (file:// URLs are rejected by Apple's auth server).
    func serve(developerToken: String) throws {
        let htmlPath = try generate(developerToken: developerToken)
        let dir = (htmlPath as NSString).deletingLastPathComponent
        let filename = (htmlPath as NSString).lastPathComponent
        let port = 8537

        // Start Python HTTP server in background
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", dir]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()

        // Give server time to bind
        Thread.sleep(forTimeInterval: 1.0)

        // Open browser to localhost
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["http://localhost:\(port)/\(filename)"]
        try open.run()
        open.waitUntilExit()

        print("Auth page served at http://localhost:\(port)/\(filename)")
        print("Sign in, copy the token, then run: music auth set-token <TOKEN>")
        print("")
        print("Press Enter to stop the server...")
        _ = readLine()
        server.terminate()
    }
}
