import Foundation

final class CircleHTTPTransport: CircleHTTPClient, @unchecked Sendable {
    let endpoint: URL
    private let token: String
    private let session: URLSession

    static func canonicalEndpoint(_ value: String) throws -> URL {
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { throw CircleConnectionError.invalidEndpoint }
        parts.path = ""
        guard let url = parts.url else { throw CircleConnectionError.invalidEndpoint }
        return url
    }

    init(endpoint: String, token: String, configuration: URLSessionConfiguration = .ephemeral) throws {
        self.endpoint = try Self.canonicalEndpoint(endpoint)
        guard !token.isEmpty, token.utf8.count <= 4096,
              !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            throw CircleConnectionError.rejectedSession
        }
        self.token = token
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: CircleNoRedirect(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    private static func validQuery(_ path: String, route: String, method: String, body: Data?) -> Bool {
        guard path.contains("?") else { return true }
        guard method == "GET", body == nil,
              route.range(of: #"^/v1/streams/[A-Za-z0-9_-]{1,64}/records$"#, options: .regularExpression) != nil,
              let parts = URLComponents(string: path), parts.percentEncodedPath == route,
              let items = parts.queryItems, !items.isEmpty,
              Set(items.map(\.name)).count == items.count else { return false }
        return items.allSatisfy { item in
            guard let value = item.value else { return false }
            switch item.name {
            case "limit": return (1...20).map(String.init).contains(value)
            case "cursor": return CircleStreamReader.validCursor(value)
            default: return false
            }
        }
    }

    func request(path: String, method: String, body: Data?, maxBytes: Int) async throws -> CircleHTTPReply {
        let route = String(path.prefix { $0 != "?" })
        guard route.hasPrefix("/v1/"), !path.contains("#"), !route.contains("%"),
              !route.contains(".."), !path.contains("\\"), !route.contains("//"),
              Self.validQuery(path, route: route, method: method, body: body),
              maxBytes > 0, maxBytes <= 2 * 1024 * 1024,
              ["GET", "POST"].contains(method), let url = URL(string: endpoint.absoluteString + path) else {
            throw CircleConnectionError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse,
                  response.url?.host == endpoint.host,
                  !(300..<400).contains(response.statusCode),
                  response.expectedContentLength <= Int64(maxBytes) else { throw CircleConnectionError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maxBytes else { throw CircleConnectionError.invalidResponse }
                data.append(byte)
            }
            return CircleHTTPReply(status: response.statusCode, data: data)
        } catch is CancellationError { throw CancellationError() }
        catch let error as CircleConnectionError { throw error }
        catch { throw CircleConnectionError.unavailable }
    }
}

private final class CircleNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
