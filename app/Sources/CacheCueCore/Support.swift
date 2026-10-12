import Foundation

/// A support ticket as the server keeps it.
public struct SupportTicket: Decodable, Identifiable, Equatable {
    public let id: String
    public let email: String
    public let description: String
    /// A path on the support server, when a file came with the ticket.
    public let attachmentURL: String?
    /// `open`, `replied`, `resolved` or `closed`.
    public let status: String
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, email, description, status
        case attachmentURL = "attachment_url"
        case createdAt = "created_at"
    }

    /// A resolved or closed ticket takes no more replies.
    public var acceptsReplies: Bool {
        !["closed", "resolved"].contains(status.lowercased())
    }
}

public struct SupportReply: Decodable, Identifiable, Equatable {
    public let id: Int
    public let message: String
    /// Written by support, not by the person.
    public let isFromSupport: Bool
    public let attachmentURL: String?
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, message
        case isAdmin = "is_admin"
        case attachmentURL = "attachment_url"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        message = try values.decode(String.self, forKey: .message)
        isFromSupport = try values.decode(Int.self, forKey: .isAdmin) != 0
        attachmentURL = try values.decodeIfPresent(String.self, forKey: .attachmentURL)
        createdAt = try values.decode(String.self, forKey: .createdAt)
    }
}

public struct SupportThread: Decodable, Equatable {
    public let ticket: SupportTicket
    public let replies: [SupportReply]
}

/// The requests the support pages make, built here so they can be checked without a
/// network. Nothing is sent until the person opens the support page: a ticket carries
/// what they typed, their email, and `deviceID`, a random id this Mac keeps so that
/// "My Tickets" can find them again. It carries nothing about their sessions.
public enum SupportAPI {
    public static let baseURL = URL(string: "https://support-api.elvisli.ca")!
    public static let appID = "CacheCue"
    public static let maxAttachmentBytes = 5 * 1024 * 1024

    public struct Attachment: Equatable {
        public let filename: String
        public let data: Data

        public init(filename: String, data: Data) {
            self.filename = filename
            self.data = data
        }
    }

    /// Enough of a check to catch a slip of the keyboard; the server has the last word.
    public static func isPlausibleEmail(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !trimmed.contains(" ") else { return false }
        return !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
    }

    private static func multipart(
        _ url: URL, fields: [(name: String, value: String)], attachment: Attachment?, boundary: String
    ) -> URLRequest {
        var body = Data()
        for field in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n\(field.value)\r\n".utf8))
        }
        if let attachment {
            // A quote or a line break in a file name would end the header early.
            let name = attachment.filename.filter { $0 != "\"" && $0 != "\r" && $0 != "\n" }
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n".utf8))
            body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(attachment.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private static func url(_ path: [String], deviceID: String? = nil) -> URL {
        // Each part is escaped whole, so an id with a slash in it stays one path segment.
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        let escaped = path.map { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        var text = baseURL.absoluteString + "/" + escaped.joined(separator: "/")
        if let deviceID {
            text += "?device_id=" + (deviceID.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
        }
        return URL(string: text) ?? baseURL
    }

    public static func submit(
        deviceID: String, email: String, description: String, attachment: Attachment?,
        boundary: String = UUID().uuidString
    ) -> URLRequest {
        multipart(
            url(["api", "submit"]),
            fields: [("app_id", appID), ("device_id", deviceID), ("email", email), ("description", description)],
            attachment: attachment, boundary: boundary)
    }

    public static func tickets(deviceID: String) -> URLRequest {
        URLRequest(url: url(["api", "user", "tickets"], deviceID: deviceID), timeoutInterval: 30)
    }

    public static func thread(ticketID: String, deviceID: String) -> URLRequest {
        URLRequest(url: url(["api", "user", "tickets", ticketID], deviceID: deviceID), timeoutInterval: 30)
    }

    public static func reply(
        ticketID: String, deviceID: String, message: String, attachment: Attachment?,
        boundary: String = UUID().uuidString
    ) -> URLRequest {
        multipart(
            url(["api", "user", "tickets", ticketID, "reply"]),
            fields: [("message", message), ("device_id", deviceID)], attachment: attachment, boundary: boundary)
    }

    /// Where an attachment's path on the server can be opened in a browser.
    public static func attachmentURL(_ path: String) -> URL? {
        if let absolute = URL(string: path), absolute.scheme == "https" { return absolute }
        guard path.hasPrefix("/") else { return nil }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }
}
