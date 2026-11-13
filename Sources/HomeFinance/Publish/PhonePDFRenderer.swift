import AppKit
import WebKit

/// Maakt van de HTML-pagina een PDF op telefoonbreedte, met een webweergave buiten beeld.
/// De PDF is één lange pagina in de lichte weergave: dezelfde pagina als het HTML-bestand, voor apps die geen
/// HTML tonen.
@MainActor
final class PhonePDFRenderer: NSObject, WKNavigationDelegate {
    /// Breedte van de pagina in punten (een gewone iPhone).
    static let pageWidth: CGFloat = 390

    enum RenderError: LocalizedError {
        case timeout
        case empty

        var errorDescription: String? {
            switch self {
            case .timeout: "De PDF maken duurde te lang."
            case .empty: "De PDF kon niet gemaakt worden."
            }
        }
    }

    /// Renderers die nog bezig zijn; houdt ze in leven tot ze klaar zijn.
    private static var active: Set<PhonePDFRenderer> = []

    let webView: WKWebView
    private var completion: ((Result<Data, Error>) -> Void)?
    private var timeoutTask: Task<Void, Never>?

    private init(dark: Bool) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // De pagina heeft geen scripts; zo gedraagt de weergave zich als de voorvertoning op de telefoon.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: Self.pageWidth, height: 844), configuration: configuration)
        webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        super.init()
        webView.navigationDelegate = self
    }

    // MARK: Gebruik

    /// Laadt de pagina en geeft de PDF terug via `completion` (op de hoofdthread). Blokkeert niet.
    static func render(html: String, timeout: TimeInterval = 15, completion: @escaping (Result<Data, Error>) -> Void) {
        load(html: html, dark: false, timeout: timeout) { renderer, result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success:
                renderer.webView.createPDF(configuration: WKPDFConfiguration()) { pdf in
                    MainActor.assumeIsolated {
                        active.remove(renderer)
                        completion(pdf.flatMap { $0.isEmpty ? .failure(RenderError.empty) : .success($0) })
                    }
                }
            }
        }
    }

    static func pdf(html: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            render(html: html) { continuation.resume(with: $0) }
        }
    }

    /// Voor bij afsluiten: wacht (met draaiende run loop) tot de PDF klaar is, hooguit `timeout` seconden.
    static func pdfBlocking(html: String, timeout: TimeInterval = 2) -> Data? {
        var result: Result<Data, Error>?
        render(html: html, timeout: timeout) { result = $0 }
        let deadline = Date().addingTimeInterval(timeout + 0.5)
        while result == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return try? result?.get()
    }

    /// Laadt de pagina in een webweergave buiten beeld. De renderer blijft in `active` tot de aanroeper hem
    /// eruit haalt (na het maken van de PDF of een afbeelding).
    static func load(html: String, dark: Bool, timeout: TimeInterval,
                     completion: @escaping (PhonePDFRenderer, Result<Void, Error>) -> Void) {
        let renderer = PhonePDFRenderer(dark: dark)
        active.insert(renderer)
        renderer.completion = { result in
            switch result {
            case .success: completion(renderer, .success(()))
            case .failure(let error):
                active.remove(renderer)
                completion(renderer, .failure(error))
            }
        }
        renderer.timeoutTask = Task { [weak renderer] in
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled { renderer?.finish(.failure(RenderError.timeout)) }
        }
        // Zonder schuifbalk, anders gaat diens breedte van de pagina af.
        let page = html.replacingOccurrences(of: "</style>", with: "html::-webkit-scrollbar{display:none}\n</style>")
        renderer.webView.loadHTMLString(page, baseURL: nil)
    }

    static func release(_ renderer: PhonePDFRenderer) { active.remove(renderer) }

    // MARK: Laden

    private func finish(_ result: Result<Data, Error>) {
        guard let completion else { return }
        self.completion = nil
        timeoutTask?.cancel()
        completion(result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(Data()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(RenderError.empty))
    }
}
