import AppKit
import CacheCueCore
import SwiftUI
import UniformTypeIdentifiers

/// Talks to the support server. The only place in the app that opens a connection of its
/// own, and only once the person has opened the support page.
enum SupportService {
    /// A random id this Mac keeps, so "My Tickets" can find what was sent from here.
    static var deviceID: String {
        let key = "support_device_id"
        if let stored = UserDefaults.standard.string(forKey: key) { return stored }
        let made = UUID().uuidString
        UserDefaults.standard.set(made, forKey: key)
        return made
    }

    struct ServerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let said = String(decoding: data.prefix(300), as: UTF8.self)
            throw ServerError(message: said.isEmpty ? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)" : said)
        }
        return data
    }

    static func submit(email: String, description: String, attachment: SupportAPI.Attachment?) async throws {
        _ = try await send(SupportAPI.submit(
            deviceID: deviceID, email: email.trimmingCharacters(in: .whitespaces), description: description,
            attachment: attachment))
    }

    static func tickets() async throws -> [SupportTicket] {
        try JSONDecoder().decode([SupportTicket].self, from: try await send(SupportAPI.tickets(deviceID: deviceID)))
    }

    static func thread(_ ticketID: String) async throws -> SupportThread {
        try JSONDecoder().decode(
            SupportThread.self, from: try await send(SupportAPI.thread(ticketID: ticketID, deviceID: deviceID)))
    }

    static func reply(_ ticketID: String, message: String, attachment: SupportAPI.Attachment?) async throws {
        _ = try await send(SupportAPI.reply(
            ticketID: ticketID, deviceID: deviceID, message: message, attachment: attachment))
    }

    enum Pick {
        case none
        case tooLarge
        case file(SupportAPI.Attachment)
    }

    /// Asks for an image or a PDF of at most 5 MB.
    @MainActor
    static func pickAttachment() -> Pick {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return .none }
        guard data.count <= SupportAPI.maxAttachmentBytes else { return .tooLarge }
        return .file(SupportAPI.Attachment(filename: url.lastPathComponent, data: data))
    }
}

/// What the support pages hold. It lives with the app, not with the popover, so a draft
/// survives the popover closing while a file is being chosen.
@MainActor
final class SupportModel: ObservableObject {
    enum Tab { case contact, tickets }
    enum Notice: Equatable {
        case sent
        case failed(String)
    }

    @Published var isPresented = false
    @Published var tab = Tab.contact
    /// The ticket open in detail, by id.
    @Published var openTicket: String?

    @Published var description = ""
    @Published var attachment: SupportAPI.Attachment?
    @Published var isTooLarge = false
    @Published var isSending = false
    @Published var notice: Notice?

    @Published var tickets: [SupportTicket]?
    @Published var thread: SupportThread?
    @Published var isLoading = false
    @Published var hasLoadFailed = false
    @Published var reply = ""
    @Published var hasReplyFailed = false

    func pick() {
        switch SupportService.pickAttachment() {
        case .none: break
        case .tooLarge:
            isTooLarge = true
            attachment = nil
        case .file(let file):
            isTooLarge = false
            attachment = file
        }
        // Choosing a file took the popover's place on screen; the draft is still here.
        isPresented = true
    }

    func submit(email: String) {
        guard !isSending else { return }
        isSending = true
        notice = nil
        Task {
            do {
                try await SupportService.submit(email: email, description: description, attachment: attachment)
                description = ""
                attachment = nil
                notice = .sent
                tickets = nil
            } catch {
                notice = .failed(error.localizedDescription)
            }
            isSending = false
        }
    }

    func loadTickets() {
        isLoading = true
        hasLoadFailed = false
        Task {
            do { tickets = try await SupportService.tickets() } catch { hasLoadFailed = true }
            isLoading = false
        }
    }

    func open(_ ticketID: String) {
        openTicket = ticketID
        thread = nil
        reply = ""
        hasReplyFailed = false
        loadThread()
    }

    func loadThread() {
        guard let openTicket else { return }
        isLoading = true
        hasLoadFailed = false
        Task {
            do { thread = try await SupportService.thread(openTicket) } catch { hasLoadFailed = true }
            isLoading = false
        }
    }

    func sendReply() {
        let message = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let openTicket, !message.isEmpty, !isSending else { return }
        isSending = true
        hasReplyFailed = false
        Task {
            do {
                try await SupportService.reply(openTicket, message: message, attachment: nil)
                reply = ""
                thread = try await SupportService.thread(openTicket)
            } catch {
                hasReplyFailed = true
            }
            isSending = false
        }
    }
}

// MARK: - Views

/// Contact form, the list of tickets sent from this Mac, and one ticket's conversation.
struct SupportView: View {
    @ObservedObject var model: SupportModel
    let strings: Strings
    /// The off-screen render cannot draw text fields, so it gets painted ones.
    var isPreview = false
    @AppStorage("supportUserEmail") private var email = ""

    var body: some View {
        VStack(spacing: 0) {
            if let ticketID = model.openTicket {
                detail(ticketID)
            } else {
                tabs
                switch model.tab {
                case .contact: form
                case .tickets: list
                }
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            tabButton(strings.contactSupport, .contact)
            tabButton(strings.myTickets, .tickets)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.10)))
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private func tabButton(_ title: String, _ tab: SupportModel.Tab) -> some View {
        Button {
            model.tab = tab
            if tab == .tickets, model.tickets == nil { model.loadTickets() }
        } label: {
            Text(title).font(.rounded(11, .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundColor(model.tab == tab ? .primary : .secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(model.tab == tab ? Color.primary.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: Contact form

    private var canSubmit: Bool {
        SupportAPI.isPlausibleEmail(email) && !model.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isSending
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(strings.supportIntro).font(.rounded(10)).foregroundColor(.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            fieldLabel(strings.emailAddress)
            field {
                if isPreview {
                    Text("you@example.com").font(.rounded(11)).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("mail@example.com", text: $email).textFieldStyle(.plain).font(.rounded(11))
                }
            }

            fieldLabel(strings.problemDescription)
            field {
                if isPreview {
                    Text(" ").font(.rounded(11)).frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
                } else {
                    TextEditor(text: $model.description).font(.rounded(11)).scrollContentBackground(.hidden)
                        .frame(height: 84)
                }
            }

            fieldLabel(strings.attachmentOptional)
            HStack(spacing: 8) {
                Button(action: model.pick) {
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip").font(.system(size: 10, weight: .semibold))
                        Text(strings.selectFile).font(.rounded(10, .semibold)).lineLimit(1)
                    }
                    .foregroundColor(.brandAccent)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.brandAccent.opacity(0.12)))
                }
                .buttonStyle(.plain)
                Text(model.attachment?.filename ?? strings.noFileSelected)
                    .font(.rounded(10)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                if model.attachment != nil {
                    Button {
                        model.attachment = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            if model.isTooLarge {
                Text(strings.fileTooLarge).font(.rounded(9)).foregroundColor(.tone(.crit))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // What pressing Submit sends, said where it is pressed.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock.shield").font(.system(size: 10)).foregroundColor(.secondary)
                Text(strings.supportPrivacy).font(.rounded(9)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                model.submit(email: email)
            } label: {
                HStack(spacing: 6) {
                    if model.isSending { ProgressView().controlSize(.small) }
                    Text(strings.submitTicket).font(.rounded(12, .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.brandAccentFill.opacity(canSubmit || isPreview ? 1 : 0.4)))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)

            switch model.notice {
            case .sent:
                Text(strings.ticketSubmitted).font(.rounded(10, .semibold)).foregroundColor(.tone(.ok))
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let reason):
                Text(String(format: strings.ticketSubmitFailed, reason)).font(.rounded(10)).foregroundColor(.tone(.crit))
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }
        }
        .padding(12)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.rounded(10, .semibold)).foregroundColor(.secondary)
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.cardBorder, lineWidth: 1))
    }

    // MARK: My tickets

    private func status(_ ticket: SupportTicket) -> (text: String, tint: Color) {
        switch ticket.status.lowercased() {
        case "open": return (strings.statusOpen, .brandAccent)
        case "replied": return (strings.statusReplied, .tone(.warn))
        case "resolved": return (strings.statusResolved, .tone(.ok))
        case "closed": return (strings.statusClosed, .secondary)
        default: return (ticket.status, .secondary)
        }
    }

    @ViewBuilder
    private func loadState(retry: @escaping () -> Void, failure: String) -> some View {
        if model.isLoading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 28)
        } else if model.hasLoadFailed {
            VStack(spacing: 8) {
                Text(failure).font(.rounded(11)).foregroundColor(.secondary).multilineTextAlignment(.center)
                Button(strings.retry, action: retry).buttonStyle(.plain).font(.rounded(11, .bold)).foregroundColor(.brandAccent)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24)
        }
    }

    private var list: some View {
        VStack(spacing: 8) {
            if let tickets = model.tickets, !model.isLoading {
                if tickets.isEmpty {
                    Text(strings.noTickets).font(.rounded(11)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                }
                ForEach(tickets) { ticket in
                    Button {
                        model.open(ticket.id)
                    } label: {
                        Card {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(ticket.description).font(.rounded(11, .semibold)).foregroundColor(.primary)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                HStack {
                                    Text(ticket.createdAt).font(.rounded(9)).monospacedDigit().foregroundColor(.secondary)
                                    Spacer()
                                    Pill(text: status(ticket).text, tint: status(ticket).tint)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else {
                loadState(retry: model.loadTickets, failure: strings.loadTicketsFailed)
            }
        }
        .padding(12)
    }

    // MARK: One ticket

    private func attachmentLink(_ path: String?) -> some View {
        Group {
            if let path, let url = SupportAPI.attachmentURL(path) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip").font(.system(size: 9, weight: .semibold))
                        Text(strings.attachment).font(.rounded(10, .semibold))
                    }
                    .foregroundColor(.brandAccent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func detail(_ ticketID: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.openTicket = nil
                model.thread = nil
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.backward").font(.system(size: 9, weight: .bold))
                    Text(strings.myTickets).font(.rounded(11, .semibold))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            if let thread = model.thread {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(strings.originalTicket.uppercased()).font(.rounded(8, .bold)).foregroundColor(.secondary)
                            Spacer()
                            Pill(text: status(thread.ticket).text, tint: status(thread.ticket).tint)
                        }
                        Text(thread.ticket.description).font(.rounded(11)).fixedSize(horizontal: false, vertical: true)
                        attachmentLink(thread.ticket.attachmentURL)
                        Text(thread.ticket.createdAt).font(.rounded(9)).monospacedDigit().foregroundColor(.secondary)
                    }
                }

                Text(strings.conversationHistory).font(.rounded(10, .semibold)).foregroundColor(.secondary)
                if thread.replies.isEmpty {
                    Text(strings.noReplies).font(.rounded(11)).foregroundColor(.secondary)
                }
                ForEach(thread.replies) { reply in
                    VStack(alignment: reply.isFromSupport ? .leading : .trailing, spacing: 3) {
                        Text(reply.isFromSupport ? strings.support : strings.you)
                            .font(.rounded(9, .bold)).foregroundColor(reply.isFromSupport ? .brandAccent : .secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(reply.message).font(.rounded(11)).fixedSize(horizontal: false, vertical: true)
                            attachmentLink(reply.attachmentURL)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(reply.isFromSupport ? Color.brandAccent.opacity(0.10) : Color.secondary.opacity(0.14)))
                        Text(reply.createdAt).font(.rounded(8)).monospacedDigit().foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: reply.isFromSupport ? .leading : .trailing)
                }

                if thread.ticket.acceptsReplies {
                    HStack(spacing: 8) {
                        field {
                            if isPreview {
                                Text(strings.typeReply).font(.rounded(11)).foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                TextField(strings.typeReply, text: $model.reply).textFieldStyle(.plain).font(.rounded(11))
                                    .onSubmit(model.sendReply)
                            }
                        }
                        Button(action: model.sendReply) {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                                .foregroundColor(.brandAccent)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isSending || model.reply.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if model.hasReplyFailed {
                        Text(strings.sendReplyFailed).font(.rounded(10)).foregroundColor(.tone(.crit))
                    }
                } else {
                    Text(thread.ticket.status.lowercased() == "closed" ? strings.ticketClosed : strings.ticketResolved)
                        .font(.rounded(10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                loadState(retry: model.loadThread, failure: strings.loadDetailsFailed)
            }
        }
        .padding(12)
    }
}
