// Station artwork from the station's public web page — the fallback for
// favourites the catalog API cannot resolve (BBC Radio 1/2/…, VRT Studio
// Brussel: `/v1/catalog/{us,gb}/stations/<id>` answers 404 for them, so
// `RadioCatalog.resolve` never fills `artworkURL` and the hero draws a
// gradient).
//
// Measured 2026-11-02: https://music.apple.com/us/station/bbc-radio-1/ra.1460912634
// answers 200 with no token and no special User-Agent; the gb page 404s. The
// page carries a `<script type="application/json" id="serialized-server-data">`
// whose station item has `"id": "<station id>"` and
// `"artwork": {"dictionary": {"url": ".../{w}x{h}bb.{f}"}}`, and an SEO block
// with `"appleContentId": "<station id>"` and `"artworkUrl"` (same template).
// Only art tied to THIS station's id is taken, so a page that ever carries
// other stations' art (a shelf) cannot give the wrong logo. og:image is not
// used: it is a 1200x630 letterbox crop, and on a page with no station art it
// could be a generic image rather than nothing.
//
// Failure is quiet by design: a 404, a changed page or no art is nil, and the
// hero keeps its gradient. Never a toast.
import Foundation

/// One page fetch: nil is a transport failure, otherwise the status and body.
typealias StationPageFetch = (URL) -> RadioCatalogResponse?

enum StationPageArtwork {
    /// The pages to try, in order: the station's own storefront, then `us`.
    /// A music:// favourite URL is fetched over https.
    static func pageURLs(for station: Station) -> [URL] {
        var out: [URL] = []
        if var comps = URLComponents(string: station.url.trimmingCharacters(in: .whitespaces)),
           comps.host == "music.apple.com", comps.path.contains("/station/") {
            comps.scheme = "https"
            comps.query = nil
            comps.fragment = nil
            if let own = comps.url { out.append(own) }
        }
        let slug = parseStationURL(station.url.replacingOccurrences(of: "music://", with: "https://"))?.slug
            ?? "station"
        if let us = URL(string: "https://music.apple.com/us/station/\(slug)/\(station.id)"),
           !out.contains(us) {
            out.append(us)
        }
        return out
    }

    /// The artwork template for `stationID` in a station page, with `{f}`
    /// normalised to `jpg` (`ArtworkStore.resolveURL` substitutes only
    /// `{w}x{h}`, which is the shape the catalog API's own templates take).
    /// nil when the page has no serialized data, or no art for this id.
    static func template(inPage html: Data, stationID: String) -> String? {
        guard let text = String(data: html, encoding: .utf8),
              let marker = text.range(of: "id=\"serialized-server-data\""),
              let open = text.range(of: ">", range: marker.upperBound..<text.endIndex),
              let close = text.range(of: "</script>", range: open.upperBound..<text.endIndex),
              let root = try? JSONSerialization.jsonObject(with: Data(text[open.upperBound..<close.lowerBound].utf8))
        else { return nil }
        guard let raw = artwork(in: root, for: stationID) else { return nil }
        let template = raw.replacingOccurrences(of: "{f}", with: "jpg")
        guard let url = URL(string: template.replacingOccurrences(of: "{w}x{h}", with: "1x1")),
              url.scheme == "https", let host = url.host,
              host == "mzstatic.com" || host.hasSuffix(".mzstatic.com")
        else { return nil }
        return template
    }

    /// Depth-first: the first dict tied to `id` that carries an artwork URL,
    /// either as the station item (`id` + `artwork.dictionary.url`) or as its
    /// SEO block (`appleContentId` + `artworkUrl`).
    private static func artwork(in node: Any, for id: String) -> String? {
        if let dict = node as? [String: Any] {
            if dict["id"] as? String == id,
               let art = dict["artwork"] as? [String: Any],
               let inner = art["dictionary"] as? [String: Any],
               let url = inner["url"] as? String {
                return url
            }
            if dict["appleContentId"] as? String == id, let url = dict["artworkUrl"] as? String {
                return url
            }
            for value in dict.values {
                if let hit = artwork(in: value, for: id) { return hit }
            }
        } else if let list = node as? [Any] {
            for value in list {
                if let hit = artwork(in: value, for: id) { return hit }
            }
        }
        return nil
    }

    /// Tries each page in `pageURLs` order until one gives this station's art.
    /// Any failure (transport, non-2xx, no art) falls through to the next.
    static func lookup(_ station: Station, fetch: StationPageFetch) -> String? {
        for url in pageURLs(for: station) {
            guard let response = fetch(url), (200...299).contains(response.status) else { continue }
            if let template = template(inPage: response.data, stationID: station.id) { return template }
        }
        return nil
    }
}

/// Fills favourites that have no art from their station pages and saves the
/// result into stations.json, so a station is looked up once, not every
/// launch. Bounded: each station id is tried at most once per instance (the
/// scene holds one per run), at most two page fetches each. A miss is retried
/// on the next launch only, which is how a station whose page gains art later
/// still picks it up without a retry storm inside one run.
///
/// Concurrency: at most `maxConcurrent` (2) station lookups run at once,
/// across the launch sweep and every single fill together, so at most two page
/// fetches are ever in flight. Two, because the hero shows one cover at a time
/// and a slow or dead page then holds back at most half the sweep, while a
/// dozen favourites still finish in about six round trips; it also matches
/// ArtworkStore's two cover slots, so the page fetches never outnumber the
/// image fetches they feed.
///
/// Synchronous; the caller runs it off the main thread.
final class StationArtworkBackfill {
    static let maxConcurrent = 2

    private let store: StationStore
    private let fetch: StationPageFetch
    private let lock = NSLock()
    private var attempted: Set<String> = []
    private let slots = DispatchSemaphore(value: StationArtworkBackfill.maxConcurrent)

    init(store: StationStore, fetch: @escaping StationPageFetch) {
        self.store = store
        self.fetch = fetch
    }

    /// Every favourite with no art not yet tried this run, `maxConcurrent` at
    /// a time. `onFilled` is called, on a worker thread, as EACH station's art
    /// is saved, so its cover can show without waiting for the rest. Returns
    /// the ids whose art was saved, once every lookup has finished.
    @discardableResult
    func fillMissing(onFilled: @escaping (String) -> Void = { _ in }) -> [String] {
        let todo = store.favorites().filter { $0.artworkURL == nil }
        guard !todo.isEmpty else { return [] }
        let queueLock = NSLock()
        var next = 0
        var filled: [String] = []
        let group = DispatchGroup()
        for _ in 0..<min(Self.maxConcurrent, todo.count) {
            group.enter()
            Thread.detachNewThread { [self] in
                defer { group.leave() }
                while true {
                    queueLock.lock()
                    guard next < todo.count else { queueLock.unlock(); return }
                    let station = todo[next]; next += 1
                    queueLock.unlock()
                    guard fillIfUntried(station) else { continue }
                    queueLock.lock(); filled.append(station.id); queueLock.unlock()
                    onFilled(station.id)
                }
            }
        }
        group.wait()
        // Favourites order, not completion order.
        return todo.map(\.id).filter { filled.contains($0) }
    }

    /// One favourite (the add path). false when it is not a favourite, already
    /// has art, was already tried this run, or its page gave none.
    @discardableResult
    func fill(id: String) -> Bool {
        guard let station = store.favorites().first(where: { $0.id == id }),
              station.artworkURL == nil else { return false }
        return fillIfUntried(station)
    }

    private func fillIfUntried(_ station: Station) -> Bool {
        lock.lock()
        let fresh = attempted.insert(station.id).inserted
        lock.unlock()
        guard fresh else { return false }
        slots.wait()
        let template = StationPageArtwork.lookup(station, fetch: fetch)
        slots.signal()
        guard let template else { return false }
        return (try? store.setArtworkIfMissing(id: station.id, url: template)) ?? false
    }
}

/// A started page request; `cancel` abandons it.
protocol StationPageTask: AnyObject {
    func cancel()
}

extension URLSessionDataTask: StationPageTask {}

/// Starts `request` and calls back once with what came back. The seam a test
/// replaces to drive the timeout and a late callback without a network.
typealias StationPageTransport = (URLRequest, @escaping (Data?, URLResponse?) -> Void) -> StationPageTask

/// The shipped transport: URLSession.shared.
func urlSessionStationPageTransport(_ request: URLRequest,
                                    _ completion: @escaping (Data?, URLResponse?) -> Void) -> StationPageTask {
    let task = URLSession.shared.dataTask(with: request) { data, response, _ in completion(data, response) }
    task.resume()
    return task
}

/// The real page fetcher: a plain GET, blocking up to `timeout`. No token, no
/// cookies sent; nil on transport failure.
///
/// RED: today's behaviour behind the new seam — the result is read after the
/// wait without synchronisation, and a timed-out task is never cancelled.
func makeStationPageFetch(transport: @escaping StationPageTransport = urlSessionStationPageTransport,
                          timeout: TimeInterval = 15,
                          onLateCallback: @escaping () -> Void = {}) -> StationPageFetch {
    return { url in
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpShouldHandleCookies = false
        let sem = DispatchSemaphore(value: 0)
        var out: RadioCatalogResponse?
        _ = transport(req) { data, response in
            if let data, let http = response as? HTTPURLResponse {
                out = RadioCatalogResponse(status: http.statusCode, data: data)
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        return out
    }
}
