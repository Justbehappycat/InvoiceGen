import Foundation
import AppKit

/// Publishing an invoice to invoice.finecut.com.
///
/// The link is a capability: an unguessable id that anyone holding the URL can
/// open. That is what a client needs — no account, nothing to remember, works
/// on a phone. It also means the link is worth treating like the invoice
/// itself, so publishing is always an explicit act and unpublishing is one
/// click.
///
/// Only two things ever leave this Mac: the PDF you already send people, and a
/// small metadata block for the page around it — number, dates, total, status.
/// Payment details are not in that block; they stay inside the PDF, exactly as
/// they are today when you email it.
enum PublishService {

    struct Target {
        var baseURL: URL
        var token: String

        init(url: URL, token: String) {
            self.baseURL = url
            self.token = token
        }
    }

    enum Failure: LocalizedError {
        case notConfigured
        case badResponse(Int, String)
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Set the publishing address and token in Settings first."
            case .renderFailed:
                return "The invoice could not be rendered to a PDF."
            case .badResponse(let code, let body):
                return "The server answered \(code)\(body.isEmpty ? "" : ": \(body)")."
            }
        }
    }

    // MARK: - Configuration

    static func target(for business: BusinessProfile) -> Target? {
        let trimmed = business.publishBaseURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme == "https",
              let token = Keychain.publishToken(), !token.isEmpty
        else { return nil }
        return Target(url: url, token: token)
    }

    /// Unguessable, short enough to read down a phone, url-safe.
    static func makeID() -> String {
        let bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func publicURL(for id: String, target: Target) -> URL {
        target.baseURL.appendingPathComponent("i").appendingPathComponent(id)
    }

    // MARK: - The requests
    //
    // Built separately from the sending so they can be asserted on without a
    // network — see `--selftest-publish`.

    static func publishRequest(id: String, target: Target, metadata: [String: String],
                               pdf: Data) -> URLRequest {
        var request = URLRequest(url: target.baseURL
            .appendingPathComponent("publish").appendingPathComponent(id))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(target.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        if let json = try? JSONSerialization.data(withJSONObject: metadata),
           let text = String(data: json, encoding: .utf8) {
            request.setValue(text, forHTTPHeaderField: "X-Invoice-Meta")
        }
        request.httpBody = pdf
        return request
    }

    static func unpublishRequest(id: String, target: Target) -> URLRequest {
        var request = URLRequest(url: target.baseURL
            .appendingPathComponent("publish").appendingPathComponent(id))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(target.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// What the page around the PDF is allowed to say. Deliberately narrow:
    /// nothing here comes from a payment method.
    static func metadata(for invoice: Invoice, customer: Customer?,
                         business: BusinessProfile) -> [String: String] {
        [
            "number": invoice.number,
            "title": invoice.title.isEmpty ? "INVOICE" : invoice.title,
            "business": business.name,
            "amountDue": Fmt.currency(invoice.amountDue, code: invoice.currencyCode),
            "issueDate": Fmt.longDate(invoice.issueDate),
            "dueDate": Fmt.longDate(invoice.dueDate),
            "status": invoice.isOverdue ? "Overdue" : invoice.status.label,
            "accent": business.accentHex,
            "fileName": PDFExporter.suggestedFileName(for: invoice),
        ]
    }

    // MARK: - Sending

    @MainActor
    static func publish(invoice: Invoice, customer: Customer?,
                        business: BusinessProfile) async throws -> (id: String, url: URL) {
        guard let target = target(for: business) else { throw Failure.notConfigured }
        guard let pdf = PDFExporter.makePDFData(
            invoice: invoice, customer: customer, business: business
        ) else { throw Failure.renderFailed }

        // Re-publishing keeps the same link, so a client's bookmark still works.
        let id = invoice.publishedID ?? makeID()
        let request = publishRequest(
            id: id, target: target,
            metadata: metadata(for: invoice, customer: customer, business: business),
            pdf: pdf
        )
        try await send(request)
        return (id, publicURL(for: id, target: target))
    }

    @MainActor
    static func unpublish(id: String, business: BusinessProfile) async throws {
        guard let target = target(for: business) else { throw Failure.notConfigured }
        try await send(unpublishRequest(id: id, target: target))
    }

    private static func send(_ request: URLRequest) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw Failure.badResponse(code, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
    }
}
