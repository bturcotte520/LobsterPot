import Foundation

/// Delegate-based SSE client. URLSession.bytes(for:) buffers in the iOS
/// Simulator and on some networks; URLSessionDataDelegate gets each chunk
/// as it arrives, so events surface live.
final class SSEStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    typealias EventHandler = (_ id: String?, _ event: String, _ data: String) -> Void
    typealias ConnectionHandler = (Bool) -> Void

    private let url: URL
    private let bearerToken: String
    private let lastEventId: String?
    private let onEvent: EventHandler
    private let onConnectionChange: ConnectionHandler
    private let onError: (Error) -> Void

    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var buffer = Data()

    // Reassembly state for one SSE event
    private var currentId: String?
    private var currentEvent: String = "message"
    private var currentDataLines: [String] = []

    init(
        url: URL,
        bearerToken: String,
        lastEventId: String?,
        onEvent: @escaping EventHandler,
        onConnectionChange: @escaping ConnectionHandler,
        onError: @escaping (Error) -> Void
    ) {
        self.url = url
        self.bearerToken = bearerToken
        self.lastEventId = lastEventId
        self.onEvent = onEvent
        self.onConnectionChange = onConnectionChange
        self.onError = onError
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = TimeInterval.infinity
        config.timeoutIntervalForResource = TimeInterval.infinity
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpAdditionalHeaders = [
            "Accept": "text/event-stream",
            "Cache-Control": "no-cache",
            "Authorization": "Bearer \(bearerToken)"
        ]
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func start() {
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        if let last = lastEventId {
            request.setValue(last, forHTTPHeaderField: "Last-Event-Id")
        }
        let t = session.dataTask(with: request)
        task = t
        t.resume()
    }

    func stop() {
        task?.cancel()
        task = nil
        session.invalidateAndCancel()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode == 200 {
            onConnectionChange(true)
            completionHandler(.allow)
        } else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            onError(NSError(domain: "SSEStream", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"]))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        buffer.append(data)
        // Process lines as they accumulate. SSE separates lines with \n,
        // events with blank lines (\n\n).
        while let nlRange = buffer.range(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: 0..<nlRange.lowerBound)
            buffer.removeSubrange(0..<nlRange.upperBound)
            // Strip trailing \r if present
            let trimmed = lineData.last == 0x0D ? lineData.dropLast() : Data(lineData)
            let line = String(data: trimmed, encoding: .utf8) ?? ""
            handleLine(line)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        onConnectionChange(false)
        if let err = error, (err as NSError).code != NSURLErrorCancelled {
            onError(err)
        }
    }

    // MARK: - SSE parsing

    private func handleLine(_ line: String) {
        if line.isEmpty {
            // Dispatch
            if !currentDataLines.isEmpty {
                let payload = currentDataLines.joined(separator: "\n")
                onEvent(currentId, currentEvent, payload)
            }
            currentEvent = "message"
            currentDataLines = []
            return
        }
        if line.hasPrefix(":") { return } // comment

        if let colonIdx = line.firstIndex(of: ":") {
            let field = String(line[..<colonIdx])
            var value = String(line[line.index(after: colonIdx)...])
            if value.hasPrefix(" ") { value.removeFirst() }
            switch field {
            case "id": currentId = value
            case "event": currentEvent = value
            case "data": currentDataLines.append(value)
            default: break
            }
        } else {
            // Field with no value — line is the field name
            // (rarely used; ignore)
        }
    }
}
