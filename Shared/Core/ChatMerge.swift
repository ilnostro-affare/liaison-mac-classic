import Foundation

/// A server copy of the thread arriving after the person answered something here: chat-save may not have reached
/// the server yet, so an answer marked locally (gate, ask, plan done) wins over the server's unanswered copy.
enum ChatMerge {
    static func preferLocalAnswers(server: [ChatMessage], local: [ChatMessage]) -> [ChatMessage] {
        var out = server
        for i in out.indices where i < local.count {
            let l = local[i]
            guard l.role == out[i].role, l.content == out[i].content else { continue }
            if l.gate?.done == true, out[i].gate?.done == false { out[i].gateJSON = l.gateJSON }
            if l.ask?.done == true, out[i].ask?.done == false { out[i].askJSON = l.askJSON }
            if let lp = l.plan, let sp = out[i].plan {
                let ld = JSONRead.bool(lp, "done"), sd = JSONRead.bool(sp, "done")
                // Answered here, or a publish in progress here that the server has not seen.
                if (ld && !sd) || (!sd && lp["publishing"] != nil && sp["publishing"] == nil) { out[i].planJSON = l.planJSON }
            }
        }
        return out
    }
}
