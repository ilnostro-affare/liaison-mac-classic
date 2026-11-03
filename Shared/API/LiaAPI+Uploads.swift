import Foundation

/// Storage > Uploads on the server (the server, the backend).
/// POST /intelligence/attach-stream?name=&mime=&src= the raw bytes of any file up to 100 MB (no base64): an input
/// file like /intelligence/attach's, same answer {ok, key, kind, mime, name, bytes, url, read}
/// GET /intelligence/uploads the index {ok, uploads, hidden}
/// POST /intelligence/uploads/delete {key} the row goes; bytes a chat holds stay (delete_bytes says when
/// upload_delete should delete a library file for real)
/// POST /intelligence/uploads/register {key, name, mime, bytes, src, chat} a library upload ({m}/uploads/) named
extension LiaAPI {
    private func uploadsCall(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> (Int, Data) {
        guard let url = URL(string: AppConfig.aiBase + path) else { throw AuthError.network }
        for attempt in 0..<2 {
            let token = try await token(forceRefresh: attempt == 1)
            var req = URLRequest(url: url, timeoutInterval: timeout)
            LiaClient.stamp(&req)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let result: (Data, URLResponse)
            do { result = try await session.data(for: req) } catch { throw AuthError.network }
            let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { continue }
            if status == 401 { throw AuthError.sessionExpired }
            return (status, result.0)
        }
        throw AuthError.sessionExpired
    }

    /// Any file into the input lane, streamed: from its file on this Mac (never read whole into memory) or from bytes
    /// held in memory (a paste, a converted picture).
    func uploadFileStream(name: String, mime: String, file: URL?, data: Data?, src: String = "input",
                          progress: (@Sendable (Double) -> Void)? = nil) async throws -> ChatAttachment {
        var c = URLComponents(string: AppConfig.aiBase + "/intelligence/attach-stream")!
        c.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "mime", value: mime), URLQueryItem(name: "src", value: src)]
        guard let url = c.url else { throw UploadError(message: "Could not attach that file.") }
        let delegate = StreamUploadProgress(onProgress: progress ?? { _ in })
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let token = try await token(forceRefresh: attempt == 1)
            // The time allowed with nothing moving (not the whole upload, which ChatAttach caps):
            // 15 minutes of silence kept a chip spinning that long.
            var req = URLRequest(url: url, timeoutInterval: 180)
            LiaClient.stamp(&req)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(mime.isEmpty ? "application/octet-stream" : mime, forHTTPHeaderField: "Content-Type")
            let pair: (Data, URLResponse)
            do {
                if let data { pair = try await session.upload(for: req, from: data, delegate: delegate) }
                else if let file { pair = try await session.upload(for: req, fromFile: file, delegate: delegate) }
                else { throw UploadError(message: "Could not read the file") }
            } catch let e as UploadError {
                throw e
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                throw AuthError.network
            }
            let status = (pair.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { continue }
            if status == 401 { throw AuthError.sessionExpired }
            switch ChatAttachment.parseUpload(pair.0) {
            case .success(let a): return a
            case .failure(let e): throw status >= 500 && JSONRead.object(pair.0) == nil ? UploadError(message: "Liaison could not store the file (HTTP \(status))") : e
            }
        }
        throw AuthError.sessionExpired
    }

    /// The Uploads index.
    func uploadsIndex() async throws -> (entries: [UploadEntry], hidden: Set<String>) {
        let (status, data) = try await uploadsCall("GET", "/intelligence/uploads")
        guard status == 200, let r = UploadsIndex.parse(data, base: AppConfig.aiBase) else { throw AuthError.server("Uploads did not load") }
        return r
    }

    /// Delete from Uploads (the row; the bytes only when no chat holds them - the answer says).
    func deleteUpload(key: String) async -> UploadDeleteAnswer {
        let r = try? await uploadsCall("POST", "/intelligence/uploads/delete", body: ["key": key])
        return UploadDeleteAnswer.parse(r?.1)
    }

    /// Names a library upload in the index; `chat` when a chat carries it (an Uploads delete then keeps its bytes).
    /// Best effort: the upload itself already succeeded.
    func registerUpload(key: String, name: String, mime: String, bytes: Int, src: String, chat: Bool) async {
        _ = try? await uploadsCall("POST", "/intelligence/uploads/register",
                                   body: ["key": key, "name": name, "mime": mime, "bytes": bytes, "src": src, "chat": chat])
    }
}

private final class StreamUploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(min(0.97, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
