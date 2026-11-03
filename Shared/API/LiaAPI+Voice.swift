import Foundation

// Voice input (server): POST {agentsBase}/agents/voice/transcribe with one chunk of the composer's dictation,
// { audio: base64 WAV 16 kHz mono 16-bit, seconds, take, seq, lang_hint?, prev? } -> { ok, text }. The body and the
// reply are Shared/Core/VoiceChunker.swift. 429 voice_daily_limit / voice_take_limit stop the take.
extension LiaAPI {
    func voiceTranscribe(_ body: JSONObject) async -> VoiceReply {
        guard let url = URL(string: AppConfig.agentsBase + VoiceChunker.route),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return VoiceReply(text: nil) }
        for attempt in 0..<2 {
            guard let token = try? await token(forceRefresh: attempt == 1) else { break }
            var req = URLRequest(url: url, timeoutInterval: 30)
            LiaClient.stamp(&req)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = data
            guard let (d, resp) = try? await session.data(for: req) else { return VoiceReply(text: nil) }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { continue }
            if status == 401 { auth.markSessionExpired(); break }
            return VoiceReply.parse(JSONRead.object(d) ?? [:], status: status)
        }
        return VoiceReply(text: nil, error: "Your session has expired.", stop: true)
    }

    /// GET {agentsBase}/agents/voice/quota: the plan's minutes for today and what is left (nil on any failure).
    func voiceQuota() async -> VoiceQuota? {
        guard let url = URL(string: AppConfig.agentsBase + "/agents/voice/quota"),
              let token = try? await token(forceRefresh: false) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        LiaClient.stamp(&req)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return VoiceQuota.parse(JSONRead.object(d) ?? [:])
    }
}
