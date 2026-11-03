import XCTest
import Foundation
#if canImport(Liaison)
@testable import Liaison
#endif

// Pure logic: runs under Xcode (⌘U) AND under swiftc on Linux (scripts/test-core-linux.sh),
// which is how agents without a Mac prove and mutate it.
final class ChatStreamTests: XCTestCase {
    func testParsesEveryEventTheWorkerSends() {
        XCTAssertEqual(ChatEvent.parse(line: #"data:{"type":"delta","text":"Hi"}"#), .delta("Hi"))
        XCTAssertEqual(ChatEvent.parse(line: #"data:{"type":"reason","text":"hm"}"#), .reason("hm"))
        XCTAssertEqual(ChatEvent.parse(line: #"data:{"type":"act_start","id":"a1","tool":"get_ads_tree","label":"Read campaigns"}"#),
                       .actStart(id: "a1", tool: "get_ads_tree", label: "Read campaigns"))
        XCTAssertEqual(ChatEvent.parse(line: #"data:{"type":"act_done","id":7}"#), .actDone(id: "7"))
        XCTAssertEqual(ChatEvent.parse(line: #"data:{"type":"web_done","q":"meta cpl","n":3,"hosts":["facebook.com"]}"#),
                       .webDone(query: "meta cpl", count: 3, hosts: ["facebook.com"]))
        XCTAssertEqual(ChatEvent.parse(line: #"data:{"type":"error","message":"Usage limit"}"#), .error("Usage limit"))
        XCTAssertEqual(ChatEvent.parse(line: #"data:{"type":"block_supersede","period":null}"#), .blockSupersede(period: ""))
    }

    func testRejectsNonDataAndBrokenLines() {
        XCTAssertNil(ChatEvent.parse(line: ""))
        XCTAssertNil(ChatEvent.parse(line: ": keepalive"))
        XCTAssertNil(ChatEvent.parse(line: "data:{not json"))
        XCTAssertNil(ChatEvent.parse(line: #"data:{"text":"no type"}"#))
    }

    func testPlotBlockAndDoneCites() {
        guard case .block(let b)? = ChatEvent.parse(line: #"data:{"type":"block","tool":"code_interpreter","data":{"kind":"plot","url":"/intelligence/plot?member_id=m&key=k&exp=1&sig=s","type":"text/html"}}"#) else {
            return XCTFail("block not parsed")
        }
        XCTAssertTrue(b.isChart)
        XCTAssertEqual(b.absoluteURL(base: "https://ai.liaisone.com")?.absoluteString, "https://ai.liaisone.com/intelligence/plot?member_id=m&key=k&exp=1&sig=s")
        guard case let .done(cites, ms)? = ChatEvent.parse(line: #"data:{"type":"done","usage":{"ms":4200},"cites":[{"url":"https://www.facebook.com/x","title":"Budgets","host":"www.facebook.com","s":1,"e":9},{"url":"javascript:alert(1)"}]}"#) else {
            return XCTFail("done not parsed")
        }
        XCTAssertEqual(ms, 4200)
        XCTAssertEqual(cites.map(\.host), ["facebook.com"])
    }

    func testAbsoluteURLRefusesForeignHosts() {
        let b = ChatBlock(tool: nil, kind: "file", url: "https://evil.example/x.pdf", type: nil, filename: "x.pdf", bytes: nil)
        XCTAssertNil(b.absoluteURL(base: "https://ai.liaisone.com"))
    }
}

final class LiveTurnTests: XCTestCase {
    func testLedgerOrderAndTitlesLikeWeb() {
        var t = LiveTurn(startedAt: 0)
        XCTAssertTrue(t.isThinking)
        t.apply(.reason("**Scanning campaigns**\n\nLooking at spend."), now: 100)
        XCTAssertFalse(t.isThinking)
        t.apply(.actStart(id: "1", tool: "get_ads_tree", label: "Reading campaigns"), now: 1100)
        t.apply(.actStart(id: "2", tool: "get_creatives", label: "Ranking creatives"), now: 1200)
        t.apply(.actDone(id: "1"), now: 1600)
        t.apply(.webStart(query: "meta budget"), now: 2000)
        t.apply(.webDone(query: "meta budget", count: 3, hosts: ["facebook.com", "facebook.com", "meta.com"]), now: 3000)
        t.apply(.reason("**Comparing sources**\n\nTwo agree."), now: 3100)
        t.apply(.delta("Kids "), now: 4000)
        t.apply(.delta("camp"), now: 4100)
        let ph = t.timeline.phases
        XCTAssertEqual(ph.map(\.kind), [.think, .tools, .web, .think])
        XCTAssertEqual(ph.map(\.title), ["Scanning campaigns", "Reading the data, 2 requests", "Searched the web, 3 sources", "Comparing sources"])
        XCTAssertEqual(ph[0].text, "Looking at spend.")
        XCTAssertEqual(ph[0].durationMs, 1000)
        XCTAssertEqual(ph[1].items.map(\.durationMs), [500, nil])
        XCTAssertEqual(ph[1].durationMs, 900)
        XCTAssertEqual(ph[2].hosts, ["facebook.com", "meta.com"])
        XCTAssertTrue(ph.allSatisfy(\.done))
        XCTAssertEqual(t.text, "Kids camp")
    }

    func testDoneFinishesAndKeepsCites() {
        var t = LiveTurn(startedAt: 0)
        t.apply(.codeStart, now: 10)
        t.apply(.codeDelta("print(1)"), now: 20)
        let cite = ChatCite(json: ["url": "https://facebook.com/a", "title": "A"])!
        t.apply(.done(cites: [cite], ms: 900), now: 50)
        XCTAssertTrue(t.finished)
        XCTAssertEqual(t.timeline.workMs, 50)
        XCTAssertEqual(t.timeline.phases.first?.code, "print(1)")
        XCTAssertTrue(t.timeline.phases.allSatisfy(\.done))
        XCTAssertEqual(t.cites, [cite])
    }

    func testStoppedStreamClosesOpenPhases() {
        var t = LiveTurn(startedAt: 0)
        t.apply(.webStart(query: "q"), now: 5)
        t.apply(.codeStart, now: 6)
        t.finish(now: 30)
        XCTAssertEqual(t.timeline.phases.map(\.done), [true, true])
        XCTAssertEqual(t.timeline.phases.last?.durationMs, 24)
    }

    func testErrorFinishesTurn() {
        var t = LiveTurn(startedAt: 0)
        t.apply(.actStart(id: "x", tool: "t", label: "T"), now: 1)
        t.apply(.error("Usage limit reached"), now: 2)
        XCTAssertTrue(t.finished)
        XCTAssertEqual(t.error, "Usage limit reached")
        XCTAssertEqual(t.timeline.phases.map(\.done), [true])
    }

    func testBlocksDedupeByURL() {
        var t = LiveTurn()
        let b = ChatBlock(tool: "code_interpreter", kind: "plot", url: "/intelligence/plot?key=1", type: "text/html", filename: nil, bytes: nil)
        t.apply(.block(b)); t.apply(.block(b))
        XCTAssertEqual(t.blocks.count, 1)
        XCTAssertEqual(t.message(id: "a").blocks, [b])
    }
}

final class TimelineTests: XCTestCase {
    func testLabelTakesLastHeading() {
        XCTAssertEqual(Timeline.label(in: "**One**\ntext **Two** more"), "Two")
        XCTAssertEqual(Timeline.label(in: "no heading"), "")
        XCTAssertEqual(Timeline.strip("**Two**\n\nbody", title: "Two"), "body")
    }

    func testWebTitles() {
        XCTAssertEqual(Timeline.webTitle(done: false, calls: 1, sources: 0), "Searching the web")
        XCTAssertEqual(Timeline.webTitle(done: true, calls: 1, sources: 0), "Searched the web, nothing found")
        XCTAssertEqual(Timeline.webTitle(done: true, calls: 2, sources: 1), "Searched the web, 2 queries, 1 source")
    }

    func testSavedRoundTripDropsEmptyThinking() {
        var t = LiveTurn(startedAt: 0)
        t.apply(.reason("**Plan**\n\nStep one."), now: 10)
        t.apply(.webStart(query: "q"), now: 20)
        t.apply(.webDone(query: "q", count: 2, hosts: ["a.com"]), now: 40)
        t.apply(.done(cites: [], ms: nil), now: 60)
        guard let saved = t.timeline.saved() else { return XCTFail("nothing saved") }
        XCTAssertEqual(JSONRead.int(saved, "work"), 60)
        XCTAssertEqual(JSONRead.objects(saved, "ph").map { JSONRead.string($0, "k") ?? "" }, ["think", "web"])
        let back = Timeline(json: saved)
        XCTAssertEqual(back?.phases.map(\.title), ["Plan", "Searched the web, 2 sources"])
        XCTAssertEqual(back?.phases.last?.hosts, ["a.com"])
        var empty = Timeline()
        empty.collect(.reason("   "), reasoning: "   ", now: 1)
        empty.finish(now: 2, startedAt: 0, reasoning: "   ")
        XCTAssertNil(empty.saved())
    }

    func testFromReasoningSplitsBlocks() {
        let t = Timeline.fromReasoning("**Searching for competitors**\n\nI need data.\n\n**Creating a document**\n\nDOCX it is.")
        XCTAssertEqual(t?.phases.map(\.title), ["Searching for competitors", "Creating a document"])
        XCTAssertEqual(t?.phases.last?.text, "DOCX it is.")
        XCTAssertNil(Timeline.fromReasoning("  \n "))
    }
}

final class ChatDocTests: XCTestCase {
    func testParsesStoredChat() {
        let json = #"{"ok":true,"chat":{"id":"c1","title":"Budget","project":"p1","starred":true,"accounts":[{"id":"123","name":"Yoga studio"}],"ents":{"120":{"n":"Kids camp","k":"campaign"},"bad":{"k":"x"}},"messages":[{"role":"user","content":"Which campaign?","ts":1},{"role":"assistant","content":"Kids camp","reasoning":"r","blocks":[{"tool":"code_interpreter","data":{"kind":"file","url":"/intelligence/plot?key=f","filename":"leads.csv","bytes":2048}}],"cites":[{"url":"https://facebook.com","host":"facebook.com"}]},{"content":"no role"}]}}"#
        guard let doc = ChatDoc.parse(Data(json.utf8), fallbackId: "zz") else { return XCTFail("doc not parsed") }
        XCTAssertEqual(doc.id, "c1")
        XCTAssertEqual(doc.project, "p1")
        XCTAssertEqual(doc.accounts, [ChatAccount(id: "123", name: "Yoga studio")])
        XCTAssertEqual(doc.ents.keys.sorted(), ["120"])
        XCTAssertEqual(doc.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(doc.messages[1].blocks.first?.kindLabel, "Spreadsheet")
        XCTAssertEqual(doc.messages[1].blocks.first?.displayTitle, "leads")
        XCTAssertEqual(doc.messages[1].cites.count, 1)
    }

    func testStoredMessageSavesBackUntouchedAndNewOneIsBuilt() {
        let json = #"{"ok":true,"chat":{"id":"c1","title":"T","ents":{"9":{"n":"Camp"}},"messages":[{"role":"assistant","content":"old","actsHTML":"<b>x</b>","fb":"up","timeline":{"work":5,"think":1,"ph":[{"k":"web","d":2,"t":"Searched the web, 1 source","q":"x","n":1}]}}]}}"#
        guard let doc = ChatDoc.parse(Data(json.utf8), fallbackId: "c1") else { return XCTFail("doc") }
        XCTAssertEqual(doc.messages.first?.timeline?.phases.first?.query, "x")
        var fresh = ChatMessage(role: .user, content: "hi", attachments: [ChatAttachment(key: "ai/m/att/1.png", kind: "image", name: "a.png", mime: "image/png", bytes: 10)])
        fresh.ts = 7
        let body = doc.saveBody(messages: doc.messages + [fresh])
        let chat = body["chat"] as? JSONObject
        let msgs = JSONRead.objects(chat, "messages")
        XCTAssertEqual(JSONRead.string(msgs.first, "actsHTML"), "<b>x</b>")
        XCTAssertEqual(JSONRead.string(msgs.first, "fb"), "up")
        XCTAssertEqual(JSONRead.objects(msgs.last, "att").first.flatMap { JSONRead.string($0, "key") }, "ai/m/att/1.png")
        XCTAssertNotNil(chat?["_ents"] as? JSONObject)
        XCTAssertEqual(fresh.requestJSON()["content"] as? String, "hi")
    }

    func testUploadParsingAndAccounts() {
        if case .success(let a) = ChatAttachment.parseUpload(Data(#"{"ok":true,"key":"ai/m/att/f.pdf","kind":"file","name":"f.pdf","mime":"application/pdf","bytes":20}"#.utf8)) {
            XCTAssertEqual(a.name, "f.pdf")
        } else { XCTFail("upload not parsed") }
        if case .failure(let e) = ChatAttachment.parseUpload(Data(#"{"ok":false,"error":"Too big"}"#.utf8)) {
            XCTAssertEqual(e.message, "Too big")
        } else { XCTFail("error not parsed") }
        XCTAssertNil(ChatAttachment(json: ["key": "ai/m/plots/x"]))
        let acc = AdAccount.parseList(Data(#"{"accounts":[{"id":"act_123","name":"Yoga"},{"account_id":"456","name":""},{"name":"no id"}]}"#.utf8))
        XCTAssertEqual(acc.map(\.id), ["123", "456"])
        XCTAssertEqual(acc.map(\.name), ["Yoga", "456"])
    }

    func testNewChatWithoutDocAndNotOk() {
        XCTAssertEqual(ChatDoc.parse(Data(#"{"ok":true,"chat":null}"#.utf8), fallbackId: "cnew")?.id, "cnew")
        XCTAssertNil(ChatDoc.parse(Data(#"{"ok":false,"error":"unauthorized"}"#.utf8), fallbackId: "c"))
    }

    func testChatIDShape() {
        let id = ChatID.make()
        XCTAssertEqual(id.count, 9)
        XCTAssertTrue(id.hasPrefix("c"))
        XCTAssertTrue(id.allSatisfy { ($0.isASCII && $0.isLetter && $0.isLowercase) || $0.isNumber })
    }
}

final class MarkdownTests: XCTestCase {
    func testTableListsHeadingParagraph() {
        let md = """
        ## Budget
        **Kids camp** is cheapest.

        | Campaign | CPL |
        |---|---:|
        | Kids camp | €4.60 |
        | Spring |

        - one
        - two
        1. first
        2) second
        """
        XCTAssertEqual(Markdown.blocks(md), [
            .heading(level: 2, text: "Budget"),
            .paragraph("**Kids camp** is cheapest."),
            .table(header: ["Campaign", "CPL"], rows: [["Kids camp", "€4.60"], ["Spring", ""]]),
            .bullets(["one", "two"]),
            .numbered(["first", "second"]),
        ])
    }

    func testCodeFenceKeepsPipesAndHashes() {
        XCTAssertEqual(Markdown.blocks("```\n| a | b |\n# not heading\n```\nafter"),
                       [.code("| a | b |\n# not heading"), .paragraph("after")])
    }

    func testRowWithoutSeparatorIsText() {
        XCTAssertEqual(Markdown.blocks("| just | pipes |"), [.paragraph("| just | pipes |")])
    }

    func testSandboxLinksStripped() {
        XCTAssertEqual(Markdown.blocks("Get [the file](sandbox:/mnt/data/x.csv) here"), [.paragraph("Get the file here")])
    }

    func testNotAHeadingOrRule() {
        XCTAssertEqual(Markdown.blocks("#hashtag\n--"), [.paragraph("#hashtag\n--")])
    }

    /// 0.2.11: CRLF line ends part paragraphs; trailing spaces go; loose lists stay one list; an indented line goes on
    /// in its item.
    func testParagraphsAndListsAsWritten() {
        XCTAssertEqual(Markdown.blocks("One.  \r\n\r\nTwo\r\nlines"), [.paragraph("One."), .paragraph("Two\nlines")])
        XCTAssertEqual(Markdown.blocks("1. a\n\n2. b\n\n3. c\n\nAfter"), [.numbered(["a", "b", "c"]), .paragraph("After")])
        XCTAssertEqual(Markdown.blocks("- a\n  wrapped on\n- b\n\nText"), [.bullets(["a\nwrapped on", "b"]), .paragraph("Text")])
        XCTAssertEqual(Markdown.blocks("- a\n\n1. b"), [.bullets(["a"]), .numbered(["b"])])
        XCTAssertEqual(Markdown.blocks("Привет\nмир\n\nВторой абзац"), [.paragraph("Привет\nмир"), .paragraph("Второй абзац")])
    }

    func testEntityMarks() {
        let ents = ["1": ChatEntity(name: "Kids camp", kind: "campaign")]
        XCTAssertEqual(EntityText.marks(in: "Raise «Kids camp» and «Unknown one», not «x»", ents: ents),
                       [.init(name: "Kids camp", known: true), .init(name: "Unknown one", known: false)])
    }

    func testEntityInlineMarkdown() {
        let ents = ["1": ChatEntity(name: "Kids camp", kind: "campaign")]
        XCTAssertEqual(EntityText.inlineMarkdown("Raise «kids camp» not «Other»!", ents: ents), "Raise **kids camp** not «Other»!")
        XCTAssertEqual(EntityText.inlineMarkdown("No marks here", ents: ents), "No marks here")
        XCTAssertEqual(EntityText.inlineMarkdown("Open «Kids camp", ents: ents), "Open «Kids camp")
    }
}

final class InlineChipsTests: XCTestCase {
    private let ents = ["120000000000001": ChatEntity(name: "Kids camp", kind: "campaign")]

    func testWrappedLinkBecomesChipAndSwallowsBrackets() {
        XCTAssertEqual(InlineChips.segments("Teachers listed (" + "[sacantomusica.com](https://www.sacantomusica.com/x?utm_source=openai)).", ents: [:]),
                       [.text("Teachers listed "), .link(label: "sacantomusica.com", url: "https://www.sacantomusica.com/x", host: "sacantomusica.com"), .text(".")])
    }

    func testLoneBracketStays() {
        XCTAssertEqual(InlineChips.segments("see ([a](https://a.com) and more", ents: [:]),
                       [.text("see ("), .link(label: "a", url: "https://a.com", host: "a.com"), .text(" and more")])
    }

    func testEntitiesQuotesAndIds() {
        XCTAssertEqual(InlineChips.segments("Raise «kids camp» (id 120000000000001), not «Spring sale».", ents: ents),
                       [.text("Raise "), .entity(name: "kids camp", id: "120000000000001", kind: "campaign"), .text(", not "), .quote("Spring sale"), .text(".")])
        XCTAssertEqual(InlineChips.segments("Ad set 120000000000001 and 999999999999999", ents: ents),
                       [.text("Ad set "), .entity(name: "Kids camp", id: "120000000000001", kind: "campaign"), .text(" and 999999999999999")])
    }

    func testBoldAroundChipsRemoved() {
        XCTAssertEqual(InlineChips.segments("Keep **«Test 2 interview»** off and **bold** text", ents: [:]),
                       [.text("Keep "), .quote("Test 2 interview"), .text(" off and **bold** text")])
        XCTAssertEqual(InlineChips.segments("**«A1»**", ents: [:]), [.quote("A1")])
        XCTAssertEqual(InlineChips.segments("x **«A1» y", ents: [:]), [.text("x **"), .quote("A1"), .text(" y")])
    }

    func testPlainTextUntouched() {
        XCTAssertEqual(InlineChips.segments("**CPL** €3.80, 20 leads", ents: ents), [.text("**CPL** €3.80, 20 leads")])
    }
}

final class AnswerInlineTests: XCTestCase {
    func testCiteReplacesTheModelsLink() {
        let t = "Prices rise ([wordstream.com](https://wordstream.com/a)). Next."
        let ns = t as NSString
        let r = ns.range(of: "([wordstream.com](https://wordstream.com/a))")
        let c = ChatCite(url: "https://wordstream.com/a", title: "Costs", host: "wordstream.com", s: r.location, e: r.location + r.length)
        let m = CiteMark.apply(t, cites: [c])
        XCTAssertEqual(m.groups, [[c]])
        XCTAssertEqual(m.text, "Prices rise " + CiteMark.mark + "0" + CiteMark.mark + ". Next.")
        XCTAssertEqual(InlineChips.segments(m.text, ents: [:]), [.text("Prices rise "), .cite(0), .text(". Next.")])
    }

    func testCiteInsideALinkMovesPastIt() {
        let t = "See [a](https://a.com/x) now"
        let c = ChatCite(url: "https://b.com", title: "", host: "b.com", s: 0, e: 8)   // ends inside the link
        let m = CiteMark.apply(t, cites: [c])
        XCTAssertEqual(m.text, "See [a](https://a.com/x)" + CiteMark.mark + "0" + CiteMark.mark + " now")
    }

    func testUntrustedOffsetsGroupAtTheEnd() {
        let a = ChatCite(url: "https://a.com", title: "", host: "a.com", s: 0, e: 999)
        let b = ChatCite(url: "https://b.com", title: "", host: "b.com", s: 0, e: 2)
        let m = CiteMark.apply("Short", cites: [a, b])
        XCTAssertEqual(m.text, "Short" + CiteMark.mark + "0" + CiteMark.mark)
        XCTAssertEqual(m.groups, [[a, b]])
    }

    func testSameSpanIsOneChip() {
        let t = "x ([a.com](https://a.com))"
        let ns = t as NSString
        let r = ns.range(of: "([a.com](https://a.com))")
        let a = ChatCite(url: "https://a.com", title: "", host: "a.com", s: r.location, e: r.location + r.length)
        let b = ChatCite(url: "https://a.com/2", title: "", host: "a.com", s: r.location, e: r.location + r.length)
        let m = CiteMark.apply(t, cites: [a, b])
        XCTAssertEqual(m.groups, [[a, b]])
    }

    func testBareUrlIsACopyChip() {
        XCTAssertEqual(InlineChips.segments("Open https://site.com/p?a=1 today", ents: [:]),
                       [.text("Open "), .url("https://site.com/p?a=1"), .text(" today")])
        XCTAssertEqual(InlineChips.segments("x https://api.liaisone.io/meta/asset?k=1 y", ents: [:]), [.text("x  y")])
        // A markdown link is never a bare url.
        XCTAssertEqual(InlineChips.segments("[F](https://facebook.com/x)", ents: [:]),
                       [.link(label: "F", url: "https://facebook.com/x", host: "facebook.com")])
    }

    func testStyles() {
        XCTAssertEqual(InlineStyle.runs("a **b** c"), [StyledRun(text: "a "), StyledRun(text: "b", bold: true), StyledRun(text: " c")])
        XCTAssertEqual(InlineStyle.runs("use `x*y` and *it* done"),
                       [StyledRun(text: "use "), StyledRun(text: "x*y", code: true), StyledRun(text: " and "),
                        StyledRun(text: "it", italic: true), StyledRun(text: " done")])
        // The site's own rule, kept as it is: a space-led star pair is emphasis even around spaces.
        XCTAssertEqual(InlineStyle.runs("2 * 3 * 4"), [StyledRun(text: "2 "), StyledRun(text: " 3 ", italic: true), StyledRun(text: " 4")])
        XCTAssertEqual(InlineStyle.runs("CPL*"), [StyledRun(text: "CPL*")])
        XCTAssertEqual(InlineStyle.runs("Объявление **подготовлено**: 1–3 октября"),
                       [StyledRun(text: "Объявление "), StyledRun(text: "подготовлено", bold: true), StyledRun(text: ": 1–3 октября")])
    }

    func testBoldAroundAChipPairsUp() {
        let ents = ["120000000000001": ChatEntity(name: "Kids camp", kind: "campaign")]
        XCTAssertEqual(AnswerInline.pieces("**Ad set 120000000000001 is live**", ents: ents),
                       [.text(StyledRun(text: "Ad set ", bold: true)),
                        .chip(.entity(name: "Kids camp", id: "120000000000001", kind: "campaign")),
                        .text(StyledRun(text: " is live", bold: true))])
        XCTAssertEqual(AnswerInline.pieces("Sign up ([f.com](https://f.com/x))", ents: [:]),
                       [.text(StyledRun(text: "Sign up ")), .chip(.link(label: "f.com", url: "https://f.com/x", host: "f.com"))])
    }

    func testCiteOffsetsRoundTrip() {
        let c = ChatCite(json: ["url": "https://a.com", "title": "A", "s": 3, "e": 9])!
        XCTAssertEqual(c.s, 3)
        XCTAssertEqual(c.e, 9)
    }
}

final class UserTextTests: XCTestCase {
    func testCaptionsStripped() {
        XCTAssertEqual(UserText.display("[attachment_only]"), "")
        XCTAssertEqual(UserText.display("[quick_action] Show leads\n[attached_creative r2_key=a/b.png]"), "Show leads")
        XCTAssertEqual(UserText.outgoing("  ", hasAttachments: true), "[attachment_only]")
        XCTAssertEqual(UserText.outgoing(" hi ", hasAttachments: true), "hi")
        XCTAssertEqual(UserText.outgoing("", hasAttachments: false), "")
    }

    func testMemberIdFromToken() {
        let payload = Data(#"{"id":"mem_testmember0000000000001","exp":1}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        XCTAssertEqual(MemberToken.memberId(from: "h.\(payload).s"), "mem_testmember0000000000001")
        let bad = Data(#"{"id":"evil; drop"}"#.utf8).base64EncodedString()
        XCTAssertNil(MemberToken.memberId(from: "h.\(bad).s"))
        XCTAssertNil(MemberToken.memberId(from: "not-a-jwt"))
    }

    func testAttachmentTileAndFeedbackSave() {
        let a = ChatAttachment(key: "ai/m/att/r.docx", kind: "file", name: "report.docx", mime: "", bytes: 2048, url: "/intelligence/plot?key=x")
        XCTAssertEqual(a.badge, "DOCX")
        XCTAssertEqual(a.sizeLabel, "2 KB")
        XCTAssertEqual(a.absoluteURL(base: "https://ai.liaisone.com")?.absoluteString, "https://ai.liaisone.com/intelligence/plot?key=x")
        var m = ChatMessage(role: .assistant, content: "x", rawJSON: #"{"role":"assistant","content":"x","fb":"down"}"#)
        m.feedback = "up"
        XCTAssertEqual(m.saveJSON()["fb"] as? String, "up")
        m.feedback = nil
        XCTAssertNil(m.saveJSON()["fb"])
    }
}

final class AccountModelTests: XCTestCase {
    func testProfileNameLetterAndPaidPlan() {
        let json = #"{"data":{"id":"mem_1","auth":{"email":"demo@example.com"},"customFields":{"first-name":"Sam","last-name":"M"},"planConnections":[{"planId":"pln_free-example1","status":"ACTIVE"},{"planId":"pln_lia-pro-example2","status":"CANCELED"},{"planId":"pln_lia-max-example3","status":"TRIALING"}]}}"#
        let p = MemberProfile.parse(Data(json.utf8))
        XCTAssertEqual(p?.fullName, "Sam M")
        XCTAssertEqual(p?.letter, "S")
        XCTAssertEqual(p?.planName, "Lia Max · Trial")
    }

    func testProfileFallsBackToEmailAndFree() {
        let p = MemberProfile.parse(Data(#"{"data":{"id":"mem_2","auth":{"email":"user@x.it"},"planConnections":[{"planId":"pln_free-example1","status":"ACTIVE"}]}}"#.utf8))
        XCTAssertEqual(p?.fullName, "user")
        XCTAssertEqual(p?.letter, "U")
        XCTAssertEqual(p?.planName, "Free")
    }

    /// settings.js renderGeneral: the Google row and the email lock read auth.providers and auth.hasPassword.
    func testProfileGoogleProviders() {
        let g = MemberProfile.parse(Data(#"{"data":{"id":"mem_3","auth":{"email":"a@b.it","hasPassword":false,"providers":[{"provider":"GOOGLE"}]}}}"#.utf8))
        XCTAssertEqual(g?.hasGoogle, true)
        XCTAssertEqual(g?.emailEditable, false)
        XCTAssertEqual(g?.canDisconnectGoogle, false)
        let both = MemberProfile.parse(Data(#"{"data":{"id":"mem_4","auth":{"email":"a@b.it","hasPassword":true,"providers":["google"]}}}"#.utf8))
        XCTAssertEqual(both?.hasGoogle, true)
        XCTAssertEqual(both?.emailEditable, true)
        XCTAssertEqual(both?.canDisconnectGoogle, true)
        let plain = MemberProfile.parse(Data(#"{"data":{"id":"mem_5","auth":{"email":"a@b.it"}}}"#.utf8))
        XCTAssertEqual(plain?.hasGoogle, false)
        XCTAssertEqual(plain?.hasPassword, true)
        XCTAssertEqual(plain?.emailEditable, true)
    }

    func testBillingStatusAndDates() {
        let b = BillingSummary.parse(Data(#"{"plan":"Liaison","status":"trialing","price":{"amount":1500},"currentPeriodEnd":1790000000,"trialEnd":1789000000,"cancelAtPeriodEnd":false}"#.utf8))
        XCTAssertEqual(b?.statusLine, "Trial")
        XCTAssertEqual(b?.keyDate?.label, "Trial ends")
        XCTAssertEqual(b?.keyDate?.date.timeIntervalSince1970, 1789000000)
        let c = BillingSummary.parse(Data(#"{"status":"active","currentPeriodEnd":1790000000,"cancelAtPeriodEnd":true}"#.utf8))
        XCTAssertEqual(c?.keyDate?.label, "Ends")
        XCTAssertEqual(BillingSummary.parse(Data(#"{"status":"none"}"#.utf8))?.statusLine, "No subscription")
    }

    func testMetaConnection() {
        XCTAssertEqual(MetaConnection.parse(Data(#"{"connected":true,"fbUserId":"42","fbName":"Sam"}"#.utf8)), MetaConnection(connected: true, expired: false, name: "Sam"))
        XCTAssertNil(MetaConnection.parse(Data(#"{"ok":false,"error":"Unauthorized"}"#.utf8)))
    }

    func testRelayMergesDropsEchoAndSortsNewestFirst() {
        let json = #"{"journal":[{"id":"7","ts":1000000,"entity_name":"Kids camp","entity_type":"ad_set","diff":[{"kind":"budget","old":"40","new":"55"}]}],"meta_changes":[{"at":1030000,"actor":"Sam","action":"Ad set status updated","entity_name":"Kids camp","via":"Liaison"},{"at":2000000,"actor":"Alex","action":"campaign created","entity_name":"Autumn","eid":"e1"},{"at":500000,"actor":"Meta","action":"Account billed"}]}"#
        let feed = RelayFeed.parse(Data(json.utf8))
        XCTAssertEqual(feed.map(\.action), ["Created a campaign", "Changed a budget", "Billed the account"])
        XCTAssertEqual(feed[1].from, "40")
        XCTAssertEqual(feed[1].entityType, "ad set")
        XCTAssertTrue(feed[2].system)
        XCTAssertFalse(feed[0].commentable)   // Meta row without cm: the server would refuse a comment

        let cm = RelayFeed.parse(Data(#"{"journal":[{"id":"q1","ts":1,"diff":[{"kind":"paused"}]}],"meta_changes":[{"at":5000000,"actor":"Alex","action":"x","eid":"m1","cm":1},{"at":6000000,"actor":"Anna","action":"y","eid":"m2"}]}"#.utf8))
        XCTAssertEqual(cm.map(\.commentable), [false, true, true])
    }
}

final class RelayDirectoryTests: XCTestCase {
    func testProjectsFoldersUnreadAndComments() {
        let dir = RelayDirectory.parse(Data(#"{"projects":[{"id":"1","name":"Yoga studio","unread":3,"last_change_at":10},{"id":"2","name":"Second Studio","unread":120,"last_change_at":50},{"id":"3","name":"Empty","known_empty":true}],"folders":[{"id":"f1","name":"Clients","projects":["1"]}]}"#.utf8))
        XCTAssertEqual(dir.projects.map(\.id), ["2", "1"])
        XCTAssertEqual(dir.projects.first?.initials, "SS")
        XCTAssertEqual(RelayDirectory.unread(in: nil, projects: dir.projects), 123)
        XCTAssertEqual(RelayDirectory.unread(in: dir.folders.first, projects: dir.projects), 3)

        let feed = RelayFeed.parse(Data(#"{"journal":[{"id":"abc","ts":5000,"entity_name":"Kids","diff":[{"kind":"paused"}]}],"comments":{"jabc":[{"cid":"c2","n":"Alex","x":"why?","t":7,"re":{"cid":"c1","n":"Sam","x":"paused"}},{"n":"Sam","x":"first","t":6},{"n":"Ghost","x":""}]}}"#.utf8))
        XCTAssertEqual(feed.first?.eid, "jabc")
        XCTAssertEqual(feed.first?.comments.map(\.text), ["first", "why?"])
        XCTAssertEqual(feed.first?.comments.last?.replyName, "Sam")
        XCTAssertEqual(feed.first?.comments.first?.cid, String(6, radix: 36))

        let undo = RelayFeed.parse(Data(#"{"journal":[{"id":"z9","ts":1,"undo_ok":true,"session":"c123","diff":[{"kind":"paused"}]},{"id":"z8","ts":2,"undo_ok":false,"undo_block":"undone","diff":[{"kind":"resumed"}]}]}"#.utf8))
        XCTAssertEqual(undo.map(\.undoable), [false, true])
        XCTAssertEqual(undo.map(\.undone), [true, false])
        XCTAssertEqual(undo.last?.chatId, "c123")
        XCTAssertEqual(undo.last?.journalId, "z9")

        let c = RelayComment(json: ["cid": "new", "n": "Sam", "x": "done", "t": 9])!
        let added = RelayFeed.appending(c, eid: "jabc", to: feed)
        XCTAssertEqual(added.first?.comments.map(\.text), ["first", "why?", "done"])
        XCTAssertEqual(RelayFeed.appending(c, eid: "jabc", to: added).first?.comments.count, 3)
    }

    func testUsageAndNotificationPrefs() {
        let u = UsageInfo.parse(Data(#"{"ok":true,"session":{"active":true,"pct":7,"reset_at":1789600000000},"weekly":{"active":true,"pct":140,"reset_at":1789700000}}"#.utf8))
        XCTAssertEqual(u?.session.pct, 7)
        XCTAssertEqual(u?.weekly.pct, 100)
        XCTAssertEqual(u?.session.resetAt?.timeIntervalSince1970, 1789600000)
        XCTAssertEqual(u?.weekly.resetAt?.timeIntervalSince1970, 1789700000)
        XCTAssertNil(UsageInfo.parse(Data(#"{"ok":false}"#.utf8)))

        let p = NotificationPrefs.parse(Data(#"{"prefs":{"leads":{"enabled":false,"cadence":"6h"},"metrics":{"enabled":true,"cadence":"realtime"}}}"#.utf8))
        XCTAssertEqual(p.values["leads"]?.enabled, false)
        XCTAssertEqual(p.values["leads"]?.cadence, "6h")
        XCTAssertEqual(p.values["metrics"]?.cadence, "daily")
        XCTAssertEqual(p.values["system"]?.cadence, "realtime")
        XCTAssertEqual(NotificationPrefs.label("realtime", category: "leads"), "Realtime (1 min window)")
        XCTAssertEqual((p.json["leads"] as? JSONObject)?["cadence"] as? String, "6h")
    }
}

final class SVGPathTests: XCTestCase {
    func testEveryExtractedIconParsesAndStaysInItsBox() {
        XCTAssertTrue(LiaIconData.icons.count >= 60)
        for (name, parts) in LiaIconData.icons {
            for p in parts {
                let cmds = SVGPath.parse(p.d)
                XCTAssertTrue(cmds.count >= 2, name)
                XCTAssertEqual(cmds.first.map { if case .move = $0 { return true } else { return false } }, true, name)
                for c in cmds {
                    if case let .line(x, y) = c { XCTAssertTrue((-1...21).contains(x) && (-1...21).contains(y), "\(name) \(x) \(y)") }
                }
            }
        }
        XCTAssertTrue(SVGPath.parse(LiaIconData.amarkLetter).count > 20)
        XCTAssertEqual(LiaIconData.amarkDots.count, 2)
    }

    func testAbsoluteRelativeAndImplicitLines() {
        XCTAssertEqual(SVGPath.parse("M1 2 L3 4 5 6Z"), [.move(1, 2), .line(3, 4), .line(5, 6), .close])
        XCTAssertEqual(SVGPath.parse("m1 1 l2 0 h1 v-3 z"), [.move(1, 1), .line(3, 1), .line(4, 1), .line(4, -2), .close])
        XCTAssertEqual(SVGPath.parse("M0 0Q1 2 3 4"), [.move(0, 0), .quad(1, 2, 3, 4)])
        XCTAssertEqual(SVGPath.parse("M5 5 m1 1"), [.move(5, 5), .move(6, 6)])
        XCTAssertEqual(SVGPath.parse("M1 1 2 2"), [.move(1, 1), .line(2, 2)])
        XCTAssertEqual(SVGPath.parse("M10 10c1 1 2 2 3 3"), [.move(10, 10), .cubic(11, 11, 12, 12, 13, 13)])
    }

    func testCompactNumbers() {
        XCTAssertEqual(SVGPath.parse("M7.27 5.17L9.84-8.00.5.25"), [.move(7.27, 5.17), .line(9.84, -8), .line(0.5, 0.25)])
    }
}

final class AccountPeopleTests: XCTestCase {
    func testPeopleAndRecentCount() {
        let p = AccountPeople.parse(Data(#"{"ok":true,"active":[{"name":"Alex Rossi","changes":4,"last_at":100,"apps":["Power Editor","Liaison"]},{"name":"Sam M","changes":9,"last_at":300,"is_you":true}],"access":[{"name":"Anna"},{"name":""}]}"#.utf8))
        XCTAssertEqual(p?.active.map(\.name), ["Sam M", "Alex Rossi"])
        XCTAssertEqual(p?.active.last?.appsLabel, "Ads Manager, Liaison")
        XCTAssertEqual(p?.active.last?.initials, "AR")
        XCTAssertEqual(p?.count, 3)
        XCTAssertNil(AccountPeople.parse(Data(#"{"ok":false}"#.utf8)))

        let day = 86_400_000.0
        let now = 100 * day
        func ev(_ ts: Double, system: Bool = false) -> RelayEvent {
            RelayEvent(id: "\(ts)", ts: ts, actor: system ? "Meta" : "Sam", action: "a", entity: "", entityType: "", from: nil, to: nil, viaLiaison: false, system: system)
        }
        XCTAssertEqual(RelayFeed.recentCount([ev(now - day), ev(now - 13 * day), ev(now - 15 * day), ev(now - day, system: true)], now: now), 2)
        XCTAssertTrue(RelayFeed.isServiceLine(ev(1, system: true)))
        XCTAssertFalse(RelayFeed.isServiceLine(ev(1)))
    }
}

final class GreetingAndMediaTests: XCTestCase {
    func testGreetingByHourAndName() {
        XCTAssertEqual(Greeting.line(hour: 8, name: "Sam", seed: 0), "Good morning, Sam")
        XCTAssertEqual(Greeting.line(hour: 14, name: nil, seed: 0), "Good afternoon")
        XCTAssertEqual(Greeting.line(hour: 20, name: " ", seed: 3), "Good evening")
        XCTAssertEqual(Greeting.line(hour: 2, name: "Sam", seed: 0), "Up late, Sam?")
        XCTAssertEqual(Greeting.line(hour: 9, name: "Sam", seed: 1), "Welcome back, Sam")
        XCTAssertEqual(Greeting.line(hour: 9, name: "Sam", seed: -2), "Where do we start, Sam?")
    }

    func testMediaLibraryAndMarkers() {
        let lib = MediaItem.parseLibrary(Data(#"{"ok":true,"uploads":[{"r2_key":"u/1.png","name":"a.png","preview":"https://x/1"}],"meta_images":[{"image_hash":"abc"}],"meta_videos":[{"video_id":123,"length":75.4},{"name":"no id"}]}"#.utf8))
        XCTAssertEqual(lib?.uploads.first?.marker, "[attached_creative r2_key=u/1.png]")
        XCTAssertEqual(lib?.images.first?.marker, "[attached_creative image_hash=abc]")
        XCTAssertEqual(lib?.videos.map(\.id), ["123"])
        XCTAssertEqual(lib?.videos.first?.marker, "[attached_creative video_id=123]")
        XCTAssertEqual(lib?.videos.first?.durationLabel, "1:15")
        XCTAssertNil(MediaItem.parseLibrary(Data(#"{"ok":false}"#.utf8)))
    }

    func testCommentRemovalAndServerEid() {
        let feed = RelayFeed.parse(Data(#"{"journal":[{"id":"abc","eid":"jSERVER","ts":5,"diff":[{"kind":"paused"}]}],"comments":{"jSERVER":[{"cid":"c1","n":"Sam","x":"one","t":1},{"cid":"c2","name":"Alex","text":"two","t":2}]}}"#.utf8))
        XCTAssertEqual(feed.first?.comments.map(\.name), ["Sam", "Alex"])
        XCTAssertEqual(RelayFeed.removing(cid: "c1", eid: "jSERVER", from: feed).first?.comments.map(\.cid), ["c2"])
    }
}

final class WidgetTests: XCTestCase {
    func testDateRangeLabelsAndPresets() {
        XCTAssertEqual(DateRange(from: "2026-09-01", to: "2026-09-17").label, "1–17 Sep")
        XCTAssertEqual(DateRange(from: "2026-03-14", to: "2026-09-14").label, "Mar 14 – Sep 14")
        XCTAssertEqual(DateRange(from: "2025-12-30", to: "2026-01-02").label, "Dec 30 '25 – Jan 2 '26")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_789_000_000)   // UTC
        XCTAssertEqual(DateRange.preset(.today, now: now, calendar: cal), DateRange(from: "2026-09-10", to: "2026-09-10"))
        XCTAssertEqual(DateRange.preset(.week, now: now, calendar: cal), DateRange(from: "2026-09-04", to: "2026-09-10"))
        XCTAssertEqual(DateRange.preset(.thisMonth, now: now, calendar: cal), DateRange(from: "2026-09-01", to: "2026-09-10"))
        XCTAssertNil(DateRange.preset(.custom, now: now, calendar: cal))
    }

    func testCreativePerformanceAndGallery() {
        let json = #"{"account":"123","account_name":"Yoga studio","currency":"EUR","best_id":"a2","period":{"from":"2026-03-14","to":"2026-09-14"},"kpi":{"count":14,"avg_cpl":6.1,"leads":211,"worst_cpl":26.7},"creatives":[{"id":"a1","name":"11.12 winter","cpl":4.85,"leads":29,"campaign":"Spring","adset":"Milano"},{"id":"a2","name":"12.04 7 инст","img":"https://x/1","cpl":4.65,"leads":46,"video_id":"9"},{"name":"no id"}]}"#
        guard let p = CreativePerformance.parse(JSONRead.object(Data(json.utf8))) else { return XCTFail("no perf") }
        XCTAssertEqual(p.creatives.map(\.id), ["a1", "a2"])
        XCTAssertEqual(p.best?.id, "a2")
        XCTAssertTrue(p.best?.isVideo == true)
        XCTAssertEqual(p.creatives.first?.context, "Spring · Milano")
        XCTAssertEqual(p.count, 14)
        XCTAssertEqual(p.period?.label, "Mar 14 – Sep 14")

        let g = CreativeGallery.parse(JSONRead.object(Data(#"{"items":[{"id":"c1","name":"one","img":"u"},{"video_id":"7","id":"c2","name":"two"}]}"#.utf8)))
        XCTAssertEqual(g?.items.map(\.name), ["one", "two"])
        XCTAssertNil(CreativeGallery.parse(JSONRead.object(Data(#"{"items":[]}"#.utf8))))
    }

    func testLeadsSummaryAndRows() {
        let json = #"{"total":211,"with_phone":194,"account":"123","account_name":"Acme","by_platform":{"instagram":168,"facebook":43},"creatives_count":14,"adsets_count":6,"period":{"from":"2026-09-01","to":"2026-09-17"},"by_creative":[{"ad_id":"a1","name":"12.04","leads":46},{"ad_id":"a2","name":"billboard","count":38},{"ad_id":"a3","name":""}]}"#
        guard let s = LeadsSummary.parse(JSONRead.object(Data(json.utf8))) else { return XCTFail("no leads") }
        XCTAssertEqual(s.phonePercent, 92)
        XCTAssertEqual(s.topCreatives.map(\.count), [46, 38])
        XCTAssertEqual(s.period?.label, "1–17 Sep")

        let rows = Lead.parseList(Data(#"{"leads":[{"phone":"+392000000001","platform":"Instagram","created_at":"2026-09-17T16:24:00Z","ad_name":"12.04"},{"phone":"392000000001","created_at":"2026-09-17T15:58:00Z"},{"phone":"111","created_at":"2026-09-17T17:00:00Z"}]}"#.utf8))
        XCTAssertEqual(rows.map(\.quality), [.invalid, .clean, .duplicate])
        XCTAssertEqual(rows.last?.prettyPhone, "+39 200 000 00 01")
        XCTAssertEqual(rows.first?.quality, .invalid)
    }
}

