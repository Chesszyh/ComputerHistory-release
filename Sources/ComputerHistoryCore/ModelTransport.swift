import Foundation

final class ModelTransport: NSObject, URLSessionTaskDelegate {
    static func validate(_ url: URL, allowInsecureHTTP: Bool = false) throws {
        guard let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil,
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) else {
            throw ModelSettings.SettingsError.invalid("模型服务地址须为不含用户名和密码的 HTTP 或 HTTPS 地址。")
        }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host == "::1"
        guard scheme == "https" || loopback || allowInsecureHTTP else {
            throw ModelSettings.SettingsError.invalid("非本机模型服务须使用 HTTPS。若确认接受明文传输活动内容和密钥的风险，可为此模型组设置 allowInsecureHTTP: true。")
        }
    }

    // A redirect can forward the activity body to a different service or downgrade HTTPS.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
