import XCTest

@testable import CacheCueCore

final class SupportTests: XCTestCase {
    func body(_ request: URLRequest) -> String {
        String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }

    func testSubmitCarriesOnlyWhatThePersonGaveAndTheDeviceID() {
        let request = SupportAPI.submit(
            deviceID: "D-1", email: "a@b.co", description: "It shows --:--\nafter a turn.", attachment: nil, boundary: "XX")
        XCTAssertEqual(request.url?.absoluteString, "https://support-api.elvisli.ca/api/submit")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=XX")
        XCTAssertEqual(body(request), [
            "--XX", #"Content-Disposition: form-data; name="app_id""#, "", "CacheCue",
            "--XX", #"Content-Disposition: form-data; name="device_id""#, "", "D-1",
            "--XX", #"Content-Disposition: form-data; name="email""#, "", "a@b.co",
            "--XX", #"Content-Disposition: form-data; name="description""#, "", "It shows --:--\nafter a turn.",
            "--XX--", "",
        ].joined(separator: "\r\n"))
    }

    func testAttachmentRidesAsAFilePart() {
        let file = SupportAPI.Attachment(filename: "shot \"1\".png", data: Data([0x89, 0x50, 0x4E, 0x47]))!
        let request = SupportAPI.reply(ticketID: "T9", deviceID: "D-1", message: "see image", attachment: file, boundary: "B")
        XCTAssertEqual(request.url?.absoluteString, "https://support-api.elvisli.ca/api/user/tickets/T9/reply")
        let data = request.httpBody!
        // A quote in the name cannot break out of the header.
        XCTAssertNotNil(data.range(of: Data(#"name="file"; filename="shot 1.png""#.utf8)))
        // The server takes a file by the type it is labelled with, so the label has to be the real one.
        XCTAssertNotNil(data.range(of: Data("filename=\"shot 1.png\"\r\nContent-Type: image/png\r\n\r\n".utf8)))
        XCTAssertNil(data.range(of: Data("application/octet-stream".utf8)))
        XCTAssertNotNil(data.range(of: Data([0x89, 0x50, 0x4E, 0x47])))
        XCTAssertTrue(body(SupportAPI.reply(ticketID: "T9", deviceID: "D-1", message: "hi", attachment: nil, boundary: "B"))
            .hasPrefix("--B\r\nContent-Disposition: form-data; name=\"message\"\r\n\r\nhi\r\n--B\r\n"))
    }

    func testAttachmentsAreLabelledWithWhatTheyAre() {
        XCTAssertEqual(SupportAPI.mimeType(forFilename: "unnamed.jpg"), "image/jpeg")
        XCTAssertEqual(SupportAPI.mimeType(forFilename: "Screen Shot.PNG"), "image/png")
        XCTAssertEqual(SupportAPI.mimeType(forFilename: "a.b.jpeg"), "image/jpeg")
        XCTAssertEqual(SupportAPI.mimeType(forFilename: "invoice.pdf"), "application/pdf")
        XCTAssertEqual(SupportAPI.Attachment(filename: "photo.heic", data: Data([1]))?.mimeType, "image/heic")
        // Everything the app offers is something the server takes: an image or a PDF.
        for type in SupportAPI.attachmentTypes.values {
            XCTAssertTrue(type.hasPrefix("image/") || type == "application/pdf", type)
        }
        // Not offered: files of no known kind, and SVG, which can carry a script.
        for name in ["notes.txt", "archive.zip", "drawing.svg", "noextension", "trailing."] {
            XCTAssertNil(SupportAPI.Attachment(filename: name, data: Data([1])), name)
        }
    }

    /// Sends real requests to a ticket server, to check the two ends agree. Skipped unless
    /// CACHECUE_SUPPORT_TEST_URL names one, which should be a local copy and never the live server.
    func testAgainstALocalTicketServer() throws {
        guard let base = ProcessInfo.processInfo.environment["CACHECUE_SUPPORT_TEST_URL"] else {
            throw XCTSkip("no local ticket server named")
        }
        func send(_ request: URLRequest) -> (Int, String) {
            var request = request
            request.url = URL(string: base + request.url!.path + (request.url!.query.map { "?" + $0 } ?? ""))
            let done = DispatchSemaphore(value: 0)
            var result = (0, "")
            URLSession.shared.dataTask(with: request) { data, response, error in
                result = ((response as? HTTPURLResponse)?.statusCode ?? 0,
                          data.map { String(decoding: $0, as: UTF8.self) } ?? String(describing: error))
                done.signal()
            }.resume()
            done.wait()
            return result
        }
        // The smallest PNG there is: the server only has to store it.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let device = "test-" + UUID().uuidString
        for name in ["unnamed.jpg", "shot.png", "doc.pdf"] {
            let (status, text) = send(SupportAPI.submit(
                deviceID: device, email: "tester@example.com", description: "with \(name)",
                attachment: SupportAPI.Attachment(filename: name, data: png), boundary: "B-\(name)"))
            XCTAssertEqual(status, 200, text)
        }
        let (listStatus, listText) = send(SupportAPI.tickets(deviceID: device))
        XCTAssertEqual(listStatus, 200, listText)
        let tickets = try JSONDecoder().decode([SupportTicket].self, from: Data(listText.utf8))
        XCTAssertEqual(tickets.count, 3)
        XCTAssertTrue(tickets.allSatisfy { $0.attachmentURL?.hasPrefix("/api/attachments/") == true })
        let first = try XCTUnwrap(tickets.first)
        let (replyStatus, replyText) = send(SupportAPI.reply(
            ticketID: first.id, deviceID: device, message: "one more",
            attachment: SupportAPI.Attachment(filename: "more.png", data: png), boundary: "B-reply"))
        XCTAssertEqual(replyStatus, 200, replyText)
        let (threadStatus, threadText) = send(SupportAPI.thread(ticketID: first.id, deviceID: device))
        XCTAssertEqual(threadStatus, 200, threadText)
        let thread = try JSONDecoder().decode(SupportThread.self, from: Data(threadText.utf8))
        XCTAssertEqual(thread.replies.count, 1)
        XCTAssertNotNil(thread.replies.first?.attachmentURL)
    }

    func testReadRequestsNameTheDeviceAndEscapeIt() {
        XCTAssertEqual(
            SupportAPI.tickets(deviceID: "A B&C").url?.absoluteString,
            "https://support-api.elvisli.ca/api/user/tickets?device_id=A%20B%26C")
        XCTAssertEqual(
            SupportAPI.thread(ticketID: "t/1", deviceID: "D").url?.absoluteString,
            "https://support-api.elvisli.ca/api/user/tickets/t%2F1?device_id=D")
        XCTAssertNil(SupportAPI.tickets(deviceID: "D").httpBody)
    }

    func testDecodesWhatTheServerSends() throws {
        let json = """
        {"ticket":{"id":"T1","device_id":"D","app_id":"CacheCue","email":"a@b.co","description":"help",
          "attachment_url":null,"status":"replied","created_at":"2026-10-11 20:00:00"},
         "replies":[{"id":1,"ticket_id":"T1","message":"hello","is_admin":1,"attachment_url":"/files/x.png","created_at":"2026-10-11 21:00:00"},
                    {"id":2,"ticket_id":"T1","message":"thanks","is_admin":0,"attachment_url":null,"created_at":"2026-10-11 21:05:00"}]}
        """
        let thread = try JSONDecoder().decode(SupportThread.self, from: Data(json.utf8))
        XCTAssertEqual(thread.ticket.status, "replied")
        XCTAssertTrue(thread.ticket.acceptsReplies)
        XCTAssertEqual(thread.replies.map(\.isFromSupport), [true, false])
        XCTAssertEqual(thread.replies[0].attachmentURL, "/files/x.png")
        let list = try JSONDecoder().decode([SupportTicket].self, from: Data(#"[{"id":"T2","device_id":"D","app_id":"CacheCue","email":"a@b.co","description":"x","status":"Closed","created_at":"now"}]"#.utf8))
        XCTAssertFalse(list[0].acceptsReplies)
        XCTAssertNil(list[0].attachmentURL)
    }

    func testEmailAndAttachmentLinks() {
        for good in ["a@b.co", " me@example.com ", "first.last+tag@sub.domain.org"] {
            XCTAssertTrue(SupportAPI.isPlausibleEmail(good), good)
        }
        for bad in ["", "plain", "a@b", "@b.co", "a@.co", "a@b.", "a b@c.co", "a@@b.co"] {
            XCTAssertFalse(SupportAPI.isPlausibleEmail(bad), bad)
        }
        XCTAssertEqual(SupportAPI.attachmentURL("/files/x.png")?.absoluteString, "https://support-api.elvisli.ca/files/x.png")
        XCTAssertEqual(SupportAPI.attachmentURL("https://cdn.example.com/a.pdf")?.absoluteString, "https://cdn.example.com/a.pdf")
        // Only links that open safely in a browser.
        XCTAssertNil(SupportAPI.attachmentURL("file:///etc/passwd"))
        XCTAssertNil(SupportAPI.attachmentURL("javascript:alert(1)"))
        XCTAssertEqual(SupportAPI.maxAttachmentBytes, 5_242_880)
    }
}
