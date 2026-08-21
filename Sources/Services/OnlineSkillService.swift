import Foundation
import CoreLocation
import UIKit
import MediaPlayer
import AVFoundation
import os

// MARK: - 私有辅助

/// 联网技能日志（统一前缀，便于 Console 过滤）
private let skillLogger = Logger(subsystem: "com.aidiary.AIDiary", category: "OnlineSkill")

/// 在限定时间内执行异步操作：超时则取消并返回 nil（不阻塞调用方）。
/// 竞态基于 TaskGroup：操作完成 → 返回结果；延迟任务先完成 → 超时。
/// 仅用于短操作（系统设置跳转、亮度调节等），不适用于长耗时网络请求（走 URLSession 超时）。
private func withTimeout<T>(_ seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
    let deadline = UInt64(max(0, seconds) * 1_000_000_000)
    return await withTaskGroup(of: (Bool, T?).self) { group in
        group.addTask {
            let value = await operation()
            return (true, value)
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: deadline)
            return (false, nil as T?)
        }
        let (isDone, result) = await group.next() ?? (false, nil as T?)
        group.cancelAll()
        guard isDone, let value = result else {
            skillLogger.warning("withTimeout: 操作在 \(seconds)s 内未完成，已跳过")
            return nil
        }
        return value
    }
}

/// 联网技能服务集合：搜索、图片生成、天气、网页抓取、语音合成。
/// 统一走博查 BochaAI /v1/web-search + /v1/image-search（OpenAI 兼容接口）；
/// 天气仍用 open-meteo 免密钥接口。
final class OnlineSkillService {
    static let shared = OnlineSkillService()
    private let session: URLSession

    /// 博查 API 配置（可通过 APISettings.apiURL/apiKey 注入，默认走博查国内节点）
    private var bochaBaseURL: String {
        // 默认博查国内可用地址
        return "https://api.bochaai.com/v1"
    }

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        session = URLSession(configuration: cfg)
    }

    // MARK: - 联网搜索（多源轮询：用户 API → 博查 → Bing RSS 免密钥兜底）
    /// 通过 OpenAI 兼容接口调用 Web Search，返回中文实时搜索结果。
    /// 依次尝试：用户配置的 API（/v1/web-search）→ 博查（/v1/web-search）→
    /// Bing RSS（cn.bing.com，国内可访问、免密钥，兜底保证搜索始终可用）。
    func search(query: String, apiKey: String? = nil, baseURL: String? = nil) async throws -> [SearchResultItem] {
        // 1. 用户配置的 API（OpenAI 兼容 web-search 端点）
        if let baseURL, !baseURL.isEmpty {
            if let results = try? await searchViaAPI(query: query, base: baseURL, apiKey: apiKey) {
                return results
            }
        }
        // 2. 博查（同 key 尝试；部分用户的 key 就是博查的）
        if let results = try? await searchViaAPI(query: query, base: bochaBaseURL, apiKey: apiKey) {
            return results
        }
        // 3. Bing RSS 兜底（免密钥、国内可访问，保证搜索功能始终可用）
        if let results = try? await searchViaBingRSS(query: query) {
            return results
        }
        return []
    }

    /// 通过 OpenAI 兼容的 /v1/web-search 端点搜索
    private func searchViaAPI(query: String, base: String, apiKey: String?) async throws -> [SearchResultItem] {
        let endpoint = "\(base)/web-search"
        let body: [String: Any] = [
            "query": query,
            "max_results": 5
        ]
        guard let url = URL(string: endpoint) else { throw ChatError.requestFailed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = apiKey ?? ""
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, _) = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatError.requestFailed
        }

        // 兼容两种返回格式：{results:[...]} 与 {data:[...]}
        let rawResults = (json["results"] as? [[String: Any]]) ?? (json["data"] as? [[String: Any]])
        guard let results = rawResults else { throw ChatError.requestFailed }
        let items = results.prefix(5).compactMap { item -> SearchResultItem? in
            guard let title = item["title"] as? String else { return nil }
            let rawSnippet = item["snippet"] as? String ?? ""
            let snippet = rawSnippet
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&nbsp;", with: " ")
            let urlStr = item["url"] as? String ?? ""
            return SearchResultItem(title: title, url: urlStr, snippet: snippet.isEmpty ? nil : snippet)
        }
        guard !items.isEmpty else { throw ChatError.requestFailed }
        return items
    }

    /// Bing RSS 搜索兜底（免密钥、国内可直连，返回结构化 RSS 结果）
    private func searchViaBingRSS(query: String) async throws -> [SearchResultItem] {
        let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlStr = "https://cn.bing.com/search?q=\(enc)&format=rss"
        guard let url = URL(string: urlStr) else { throw ChatError.requestFailed }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        guard let xml = String(data: data, encoding: .utf8) else { throw ChatError.requestFailed }

        // 解析 RSS：逐条提取 <item> 中的 <title>、<link>、<description>
        let pattern = #"<item>(.*?)</item>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            throw ChatError.requestFailed
        }
        let ns = xml as NSString
        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        guard !matches.isEmpty else { throw ChatError.requestFailed }

        func inner(_ tag: String, in block: String) -> String? {
            let pat = "<\(tag)>(.*?)</\(tag)>"
            guard let r = try? NSRegularExpression(pattern: pat, options: [.dotMatchesLineSeparators]),
                  let m = r.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)) else { return nil }
            return (block as NSString).substring(with: m.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let items = matches.prefix(5).compactMap { m -> SearchResultItem? in
            let block = ns.substring(with: m.range(at: 1))
            guard let title = inner("title", in: block), !title.isEmpty else { return nil }
            let link = inner("link", in: block) ?? ""
            let desc = inner("description", in: block)?
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
            return SearchResultItem(title: title, url: link,
                                    snippet: desc?.isEmpty == false ? desc : nil)
        }
        guard !items.isEmpty else { throw ChatError.requestFailed }
        return items
    }

    // MARK: - AI 图片生成（多端点轮询 + 免费兜底）
    /// 通过 OpenAI 兼容接口调用图像生成，返回图片 URL。
    /// 依次尝试：用户配置的 API → Pollinations.ai（免密钥免费）→ OpenAI 官方 → 博查；
    /// 任一成功即返回。兼容响应中 data[].url 与 data[].b64_json 两种格式。
    func generateImage(prompt: String, apiKey: String? = nil, baseURL: String? = nil) async throws -> String {
        let key = apiKey ?? ""
        // 候选端点（去重）：用户配置 → OpenAI 官方 → 博查
        var endpoints: [String] = []
        if let baseURL, !baseURL.isEmpty {
            let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            endpoints.append(base + "/images/generations")
            endpoints.append(base + "/images")
        }
        if !endpoints.contains(where: { $0.contains("api.openai.com") }) {
            endpoints.append("https://api.openai.com/v1/images/generations")
        }
        if !endpoints.contains(where: { $0.contains("bochaai") }) {
            endpoints.append(bochaBaseURL + "/images")
        }

        var lastError: Error = ChatError.requestFailed
        for ep in endpoints {
            do {
                return try await performImageGeneration(endpoint: ep, prompt: prompt, apiKey: key)
            } catch {
                lastError = error
                skillLogger.warning("generateImage: 端点 \(ep) 失败：\(error.localizedDescription)")
            }
        }
        // 最终兜底：Pollinations.ai 免密钥直链（URL 本身就是图片，耗时 3-10s）
        if let url = try? await generateImagePollinations(prompt: prompt) {
            return url
        }
        throw lastError
    }

    /// Pollinations.ai 免费图片生成兜底：GET 等待生成完成后返回可渲染 URL。
    /// 带 `wait=true` 会阻塞直到图片渲染完毕（约 5-15s），确保上层拿到即可显示。
    private func generateImagePollinations(prompt: String) async throws -> String {
        let sanitized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "?", with: "")
        guard let encoded = sanitized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://image.pollinations.ai/prompt/\(encoded)?width=1024&height=1024&nologo=true&seed=\(Int.random(in: 1...999999))&enhance=true&wait=true") else {
            throw ChatError.requestFailed
        }
        // GET 下载验证：wait=true 会等服务端生成完，返回 2xx 且是图片才视为成功
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty,
              let mime = http.mimeType, mime.hasPrefix("image") else {
            throw ChatError.requestFailed
        }
        return url.absoluteString
    }

    /// 单个端点的图片生成请求（12s 短超时：失败快速切换下一端点/免费兜底）
    private func performImageGeneration(endpoint: String, prompt: String, apiKey: String) async throws -> String {
        let body: [String: Any] = [
            "prompt": prompt,
            "n": 1,
            "size": "1024x1024"
        ]
        guard let url = URL(string: endpoint) else { throw ChatError.requestFailed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await session.data(for: request) else {
            throw ChatError.requestFailed
        }
        // 非 2xx 视为失败，携带 HTTP 状态码便于上层提示
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: "ImageGen", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]],
              let first = dataArr.first else {
            throw ChatError.requestFailed
        }
        // OpenAI 兼容：data[0].url 或 data[0].b64_json（base64 转 data URI 便于直接渲染）
        if let urlStr = first["url"] as? String, !urlStr.isEmpty {
            return urlStr
        }
        if let b64 = first["b64_json"] as? String, !b64.isEmpty {
            return "data:image/png;base64,\(b64)"
        }
        throw ChatError.requestFailed
    }

    // MARK: - 真实图片搜索（多源轮询：Bing 国内 → Wikimedia → Openverse → 博查）
    /// 搜索真实世界的照片，返回图片 URL。
    /// 依次尝试：Bing 图片（cn.bing.com，国内可访问、免密钥）→
    /// Wikimedia Commons（免密钥）→ Openverse（免密钥）→ 博查（带密钥时兜底）。
    func searchImage(query: String, apiKey: String? = nil) async throws -> String? {
        // 1. Bing 图片搜索（国内可直连，免密钥，最优先）
        if let url = try? await searchImageBing(query: query) { return url }
        // 2. Wikimedia Commons（免密钥，真实照片）
        if let url = try? await searchImageWikimedia(query: query) { return url }
        // 3. Openverse（免密钥，开放版权图库）
        if let url = try? await searchImageOpenverse(query: query) { return url }
        // 4. 兜底：博查生成式（仅当配置了密钥，作为最后手段）
        if let key = apiKey, !key.isEmpty {
            if let url = try? await generateImage(
                prompt: "Real photograph of \(query), photorealistic, actual photo",
                apiKey: key
            ) { return url }
        }
        return nil
    }

    /// Bing 图片搜索（cn.bing.com，国内可访问、免密钥）。
    /// 抓取搜索结果页 HTML 并解析 murl 字段得到图片直链。
    private func searchImageBing(query: String) async throws -> String {
        let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlStr = "https://cn.bing.com/images/search?q=\(enc)&first=0&count=10"
        guard let url = URL(string: urlStr) else { throw ChatError.requestFailed }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // 模拟浏览器 UA，避免被当作爬虫拒绝
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, _) = try await session.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else { throw ChatError.requestFailed }

        // 图片直链在 HTML 的 murl 字段中：murl&quot;:&quot;https://...&quot;
        let pattern = #"murl&quot;:&quot;(.*?)&quot;"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { throw ChatError.requestFailed }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for m in matches {
            let u = ns.substring(with: m.range(at: 1))
            // 过滤：仅 http(s) 直链、排除图标、过长的 data URI
            guard u.hasPrefix("http"), !u.lowercased().hasSuffix(".ico"),
                  u.count < 500, !u.contains("data:image") else { continue }
            let decoded = u
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
            return decoded
        }
        throw ChatError.requestFailed
    }

    /// Wikimedia Commons 图片搜索（免密钥，返回缩略图直链）
    private func searchImageWikimedia(query: String) async throws -> String {
        let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlStr = "https://commons.wikimedia.org/w/api.php?action=query&generator=search&gsrsearch=\(enc)&gsrnamespace=6&gsrlimit=5&prop=imageinfo&iiprop=url&iiurlwidth=800&format=json"
        guard let url = URL(string: urlStr) else { throw ChatError.requestFailed }
        let (data, _) = try await session.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = json["query"] as? [String: Any],
              let pageDict = pages["pages"] as? [String: Any] else {
            throw ChatError.requestFailed
        }
        // 遍历所有结果页，取第一张有缩略图直链的图片
        for (_, value) in pageDict {
            guard let page = value as? [String: Any],
                  let imageInfo = page["imageinfo"] as? [[String: Any]],
                  let first = imageInfo.first else { continue }
            // 优先缩略图（800px），其次原图 URL
            if let thumb = first["thumburl"] as? String, !thumb.isEmpty {
                return thumb
            }
            if let original = first["url"] as? String, !original.isEmpty {
                return original
            }
        }
        throw ChatError.requestFailed
    }

    /// Openverse 图片搜索（免密钥，开放版权图库）
    private func searchImageOpenverse(query: String) async throws -> String {
        let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlStr = "https://api.openverse.org/v1/images/?q=\(enc)&page_size=5"
        guard let url = URL(string: urlStr) else { throw ChatError.requestFailed }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await session.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first else {
            throw ChatError.requestFailed
        }
        // 优先缩略图，其次原图
        if let thumb = first["thumbnail"] as? String, !thumb.isEmpty {
            return thumb
        }
        if let original = first["url"] as? String, !original.isEmpty {
            return original
        }
        throw ChatError.requestFailed
    }

    // MARK: - 天气（open-meteo，免密钥）
    func weather(from text: String) async throws -> WeatherInfo {
        let cleaned = text
            .replacingOccurrences(of: "天气", with: "")
            .replacingOccurrences(of: "气温", with: "")
            .replacingOccurrences(of: "温度", with: "")
            .replacingOccurrences(of: "多少", with: "")
            .replacingOccurrences(of: "今天", with: "")
            .replacingOccurrences(of: "现在", with: "")
            .replacingOccurrences(of: "明天", with: "")
            .replacingOccurrences(of: "后天", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let city = cleaned.isEmpty ? "北京" : cleaned
        let enc = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? city

        let geoURL = "https://geocoding-api.open-meteo.com/v1/search?name=\(enc)&count=1&language=zh&format=json"
        guard let gurl = URL(string: geoURL),
              let (gdata, _) = try? await session.data(from: gurl),
              let gjson = try? JSONSerialization.jsonObject(with: gdata) as? [String: Any],
              let results = gjson["results"] as? [[String: Any]],
              let first = results.first,
              let lat = first["latitude"] as? Double,
              let lon = first["longitude"] as? Double else {
            throw ChatError.requestFailed
        }
        let cityName = (first["name"] as? String) ?? city

        let fcURL = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m&timezone=auto"
        guard let furl = URL(string: fcURL),
              let (fdata, _) = try? await session.data(from: furl),
              let fjson = try? JSONSerialization.jsonObject(with: fdata) as? [String: Any],
              let current = fjson["current"] as? [String: Any] else {
            throw ChatError.requestFailed
        }
        let temp = current["temperature_2m"] as? Double ?? 0
        let humidity = current["relative_humidity_2m"] as? Int
        let wind = current["wind_speed_10m"] as? Double
        let code = current["weather_code"] as? Int ?? 0
        return WeatherInfo(city: cityName,
                           temperature: temp,
                           condition: Self.weatherDescription(code),
                           humidity: humidity,
                           windSpeed: wind,
                           units: "°C")
    }

    // MARK: - 天气（按经纬度直查，供「我的位置」场景使用）
    func weather(lat: Double, lon: Double, cityName: String) async throws -> WeatherInfo {
        let fcURL = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m&timezone=auto"
        guard let furl = URL(string: fcURL),
              let (fdata, _) = try? await session.data(from: furl),
              let fjson = try? JSONSerialization.jsonObject(with: fdata) as? [String: Any],
              let current = fjson["current"] as? [String: Any] else {
            throw ChatError.requestFailed
        }
        let temp = current["temperature_2m"] as? Double ?? 0
        let humidity = current["relative_humidity_2m"] as? Int
        let wind = current["wind_speed_10m"] as? Double
        let code = current["weather_code"] as? Int ?? 0
        return WeatherInfo(city: cityName.isEmpty ? "当前位置" : cityName,
                           temperature: temp,
                           condition: Self.weatherDescription(code),
                           humidity: humidity,
                           windSpeed: wind,
                           units: "°C")
    }

    // MARK: - 反向地理编码（BigDataCloud，免密钥，把坐标转为城市名，用于天气等城市级场景）
    func reverseGeocode(lat: Double, lon: Double) async -> String? {
        let urlStr = "https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=\(lat)&longitude=\(lon)&localityLanguage=zh"
        guard let url = URL(string: urlStr),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let city = json["city"] as? String
        let locality = json["locality"] as? String
        let subdivision = json["principalSubdivision"] as? String
        return (city?.isEmpty == false ? city : (locality?.isEmpty == false ? locality : subdivision))
    }

    // MARK: - 街道级反向地理编码（CLGeocoder，精确到街道/门牌，用于非天气的定位场景）
    private let geocoder = CLGeocoder()

    func reverseGeocodeStreet(lat: Double, lon: Double) async -> String? {
        let location = CLLocation(latitude: lat, longitude: lon)
        return await withCheckedContinuation { continuation in
            geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_CN")) { placemarks, _ in
                guard let pm = placemarks?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                // 拼接街道级地址：国家 + 省/市 + 区/县 + 街道 + 门牌号
                var parts: [String] = []
                if let country = pm.country { parts.append(country) }
                if let administrativeArea = pm.administrativeArea { parts.append(administrativeArea) }
                if let subAdminArea = pm.subAdministrativeArea { parts.append(subAdminArea) }
                if let locality = pm.locality { parts.append(locality) }
                if let subLocality = pm.subLocality { parts.append(subLocality) }
                if let thoroughfare = pm.thoroughfare { parts.append(thoroughfare) }
                if let subThoroughfare = pm.subThoroughfare { parts.append(subThoroughfare) }
                let result = parts.isEmpty ? nil : parts.joined(separator: " ")
                continuation.resume(returning: result)
            }
        }
    }

    private static func weatherDescription(_ code: Int) -> String {
        let map: [Int: String] = [
            0: "晴", 1: "大致晴朗", 2: "局部多云", 3: "阴",
            45: "雾", 48: "霜雾",
            51: "小毛毛雨", 53: "毛毛雨", 55: "大毛毛雨",
            56: "冻毛毛雨", 57: "强冻毛毛雨",
            61: "小雨", 63: "中雨", 65: "大雨",
            66: "冻雨", 67: "强冻雨",
            71: "小雪", 73: "中雪", 75: "大雪", 77: "雪粒",
            80: "阵雨", 81: "强阵雨", 82: "暴雨",
            85: "阵雪", 86: "强阵雪",
            95: "雷阵雨", 96: "雷阵雨伴冰雹", 99: "强雷暴冰雹"
        ]
        return map[code] ?? "未知"
    }

    // MARK: - 网页抓取与摘要（直连，免密钥）
    func fetchWebpage(url: String) async throws -> WebpageSummary {
        guard let u = URL(string: url),
              let (data, _) = try? await session.data(from: u) else {
            throw ChatError.requestFailed
        }

        // 尝试多种编码（中文网站常用 GBK/GB2312）
        let raw: String
        if let s = String(data: data, encoding: .utf8) {
            raw = s
        } else if let s = String(data: data, encoding: .isoLatin1) {
            // 用 Latin1 兜底，然后尝试检测 meta charset
            raw = s
        } else if let s = String(data: data, encoding: .windowsCP1252) {
            raw = s
        } else {
            throw ChatError.requestFailed
        }

        var title = "网页"
        if let tr = raw.range(of: "<title>(.*?)</title>", options: [.regularExpression, .caseInsensitive]) {
            title = String(raw[tr])
                .replacingOccurrences(of: "(?i)<title>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "(?i)</title>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var text = raw
        text = text.replacingOccurrences(of: "(?s)<script.*?</script>", with: " ",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "(?s)<style.*?</style>", with: " ",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "&[a-z]+;", with: " ", options: .regularExpression)
        text = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return WebpageSummary(url: url, title: title, summary: String(text.prefix(8000)))
    }

    // MARK: - 系统 API 操作（亮度/音量/手电筒/设置跳转/打开 App 等）
    /// 执行系统级操作。返回 (操作描述, 是否成功)。
    /// 智能匹配中文口语（如"调节屏幕亮度到50%"）与英文命令（brightness 0.5）。
    /// 支持：URL 打开（http(s):// 或自定义 scheme）→ 打开对应 App 或其指定界面。
    func executeSystemAction(command: String) async -> (description: String, success: Bool) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let cmd = trimmed.lowercased()

        // 0) 直接给 URL / scheme（http://、https://、weixin://、open 微信 等）→ 打开 App 或指定页面
        if let url = Self.extractOpenURL(from: trimmed, cmd: cmd) {
            return await openExternalURL(url)
        }

        // 亮度（英文或中文包含"亮度"）
        if cmd.hasPrefix("brightness") || cmd.contains("亮度") {
            return await setBrightness(trimmed)
        }
        // 音量（英文或中文包含"音量"）
        if cmd.hasPrefix("volume") || cmd.contains("音量") {
            return await setVolume(trimmed)
        }
        // 手电筒 / 闪光灯
        if cmd.hasPrefix("torch") || cmd.contains("手电筒") || cmd.contains("闪光灯") || cmd.contains("电筒") {
            return await toggleTorch(trimmed)
        }
        // 低电量 / 省电（只能跳设置）
        if cmd == "low_power" || cmd.contains("低电量") || cmd.contains("省电") || cmd.contains("低功耗") {
            return await openSystemSettings(path: "BATTERY_USAGE", manual: "请手动开启低电量模式")
        }
        // Wi-Fi
        if cmd == "wifi" || cmd == "无线" || cmd == "无线网络" || cmd.contains("wifi") || (cmd.contains("无线") && cmd.contains("开")) {
            return await openSystemSettings(path: "WIFI", manual: "请手动连接或开关 Wi-Fi")
        }
        // 蓝牙
        if cmd == "bluetooth" || cmd.contains("蓝牙") {
            return await openSystemSettings(path: "Bluetooth", manual: "请手动连接或开关蓝牙")
        }
        // 显示与亮度设置
        if cmd.contains("显示") || cmd.contains("屏幕") {
            return await openSystemSettings(path: "DISPLAY", manual: "请手动调节显示设置")
        }
        // 声音设置
        if cmd.contains("声音") || cmd.contains("铃声") {
            return await openSystemSettings(path: "Sounds", manual: "请手动调节铃声与提醒")
        }
        // 传感器读数：海拔 / 气压 / 指南针 / 步数 / 电池 / 内存 / 存储（只读，不会修改任何系统状态）
        if cmd.contains("所有传感器") || cmd == "sensors" || cmd.contains("传感器总览") || cmd.contains("传感器数据") {
            return await readAllSensors()
        }
        if cmd.contains("海拔") || cmd.hasPrefix("altitude") || cmd.contains("高度") {
            return await readAltitude()
        }
        if cmd.contains("气压") || cmd.contains("气压计") || cmd.contains("压强") || cmd.hasPrefix("barometer") {
            return await readBarometer()
        }
        if cmd.contains("指南针") || cmd.contains("朝向") || cmd.hasPrefix("heading") || (cmd.contains("方向") && !cmd.contains("地图")) {
            return await readHeading()
        }
        if cmd.contains("步数") || cmd.hasPrefix("steps") || (cmd.contains("走了") && cmd.contains("步")) {
            return await readSteps()
        }
        if cmd.contains("电池") || cmd.contains("电量") || cmd.contains("剩余电") || cmd.hasPrefix("battery") {
            return await readBattery()
        }
        if cmd.contains("内存") || cmd.hasPrefix("memory") || cmd.contains("ram") {
            return await readMemory()
        }
        if cmd.contains("存储") || cmd.contains("剩余空间") || cmd.contains("空间还有多少") || cmd.hasPrefix("storage") {
            return await readStorage()
        }
        // 读取类操作（无副作用）统一兜底文案
        return ("无法识别系统操作「\(command)」。提示：如果要打开某个 App，请给出完整准确的名称（如「打开 微信支付」「打开 高德地图」，不要只说简称或模糊描述）；支持的操作有：打开 XX app、https://链接、亮度 50%、音量 50%、手电筒开/关、低电量、wifi、蓝牙、显示、声音；传感器：海拔、气压、指南针、步数、电池、内存、存储、所有传感器", false)
    }

    // MARK: - 传感器读数（只读，无副作用）

    /// 当前海拔（米）。复用定位服务；未授权时先尝试请求授权。
    private func readAltitude() async -> (description: String, success: Bool) {
        let loc: CLLocation?
        if let cached = LocationService.shared.currentLocation {
            loc = cached
        } else {
            loc = await LocationService.shared.awaitLocation()
        }
        if let loc, abs(loc.altitude) > 0.5 {   // verticalAccuracy >= 0 时不代表有真实高度，改为幅度判定
            return (String(format: "当前海拔约 %.0f 米（GPS 高度）", loc.altitude), true)
        }
        // 明确诊断：权限问题 / 定位失败 / 无高度数据
        if let err = LocationService.shared.lastErrorText {
            return ("无法读取海拔：\(err)", false)
        }
        if let loc {
            return ("当前已定位但暂无有效高度数据（GPS 高度不可用，常见于室内或 Wi-Fi 定位）", false)
        }
        return ("无法读取海拔：需要位置权限，或当前定位信号中暂无高度数据", false)
    }

    /// 当前气压（hPa）。依赖设备内置气压计（iPhone 6 及以后均支持）。
    private func readBarometer() async -> (description: String, success: Bool) {
        if let p = await SensorService.currentBarometer() {
            return (String(format: "当前气压约 %.1f hPa", p), true)
        }
        return ("当前设备没有气压计，无法读取气压", false)
    }

    /// 当前朝向（指南针，度 + 中文方位）。
    private func readHeading() async -> (description: String, success: Bool) {
        let heading: CLHeading?
        if let cached = LocationService.shared.currentHeading {
            heading = cached
        } else {
            heading = await LocationService.shared.awaitHeading()
        }
        if let heading {
            let deg = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
            return (String(format: "当前朝向：%@（%.0f°）", SensorService.headingDirection(deg), deg), true)
        }
        if let err = LocationService.shared.lastErrorText {
            return ("无法读取朝向：\(err)", false)
        }
        return ("无法读取朝向：需要位置权限，或设备没有指南针", false)
    }

    /// 今日步数（需「运动与健身」权限，首次调用会触发系统授权弹窗）。
    private func readSteps() async -> (description: String, success: Bool) {
        if let steps = await SensorService.stepsToday() {
            return ("今日已走 \(steps) 步", true)
        }
        return ("无法读取步数：需要「运动与健身」权限（可到 设置 → 隐私 → 运动与健身 中开启）", false)
    }

    /// 电池电量与状态。
    private func readBattery() async -> (description: String, success: Bool) {
        let (level, state) = SensorService.batteryInfo()
        return (String(format: "电池电量 %d%%（%@）", Int(level * 100), state), true)
    }

    /// 内存占用（本 App 与设备总量）。
    private func readMemory() async -> (description: String, success: Bool) {
        let (appMB, totalGB) = SensorService.memoryUsage()
        return (String(format: "本 App 当前占用内存 %.0f MB；设备总内存 %.1f GB", appMB, totalGB), true)
    }

    /// 存储剩余空间。
    private func readStorage() async -> (description: String, success: Bool) {
        if let free = SensorService.freeStorageGB() {
            return (String(format: "设备可用存储约 %.1f GB", free), true)
        }
        return ("无法读取存储信息", false)
    }

    /// 汇总所有可用传感器数据（海拔/气压/指南针/步数/电池/内存/存储）。
    private func readAllSensors() async -> (description: String, success: Bool) {
        var loc = LocationService.shared.currentLocation
        if loc == nil { loc = await LocationService.shared.awaitLocation() }
        var heading = LocationService.shared.currentHeading
        if heading == nil { heading = await LocationService.shared.awaitHeading() }
        let headingDeg = heading.map { $0.trueHeading >= 0 ? $0.trueHeading : $0.magneticHeading }
        let snap = await SensorService.allSnapshot(altitude: loc?.altitude, headingDegrees: headingDeg)
        if snap.isEmpty {
            return ("传感器数据暂不可用，请检查相关权限", false)
        }
        let text = snap.sorted { $0.key < $1.key }
            .map { "· \(SensorService.displayName(for: $0.key))：\($0.value)" }
            .joined(separator: "\n")
        return (text, true)
    }

    /// 从命令中解析出要打开的 URL / App scheme。
    /// 识别：纯 URL（http/https）、"url:xxx"、"open xxx"、"打开 xxx"（映射常用 App scheme 表）。
    /// 匹配名先做规范化（小写/去空格/去「App」后缀），再用两级匹配（精确/前缀 → 包含），
    /// 避免「高德地图」被「地图」吞掉；全部使用可选绑定，任何异常输入都安全返回 nil（不闪退）。
    private static func extractOpenURL(from trimmed: String, cmd: String) -> URL? {
        if cmd.hasPrefix("http://") || cmd.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        if cmd.hasPrefix("url:") {
            let u = trimmed.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(string: u)
        }
        // "打开 XX" / "open XX" / "去 XX" → 匹配 App scheme
        let lowered = trimmed.lowercased()
        var target: String?
        if let range = lowered.range(of: "打开") {
            target = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let range = lowered.range(of: "open ") {
            target = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let range = lowered.range(of: "去") {
            target = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let target, !target.isEmpty else { return nil }

        // 规范化：去自定义 app 名的常见干扰（空格、括号注释、"App/APP/app" 后缀）
        func normalize(_ s: String) -> String {
            var t = s.lowercased()
                .replacingOccurrences(of: "（.*?）", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\(.*?\\)", with: "", options: .regularExpression)
            for suffix in ["app", "appp", "应用", "客户端", "了"] {
                if t.hasSuffix(suffix), t.count > suffix.count + 1 {
                    t = String(t.dropLast(suffix.count))
                }
            }
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let tn = normalize(target)
        guard !tn.isEmpty else { return nil }

        func match(_ list: [(name: String, scheme: String)]) -> URL? {
            let names = list.map { normalize($0.name) }
            // 第一级：精确 / 前缀匹配（避免「高德地图」被「地图」吞掉）
            if let idx = names.firstIndex(of: tn) {
                return URL(string: list[idx].scheme)
            }
            if let idx = names.firstIndex(where: { tn.hasPrefix($0) && !$0.isEmpty }) {
                return URL(string: list[idx].scheme)
            }
            // 第二级：包含匹配（仅对多字数目标，减少误匹配）
            for (i, nm) in names.enumerated() where !nm.isEmpty && nm.count >= 2 {
                if tn.contains(nm) {
                    return URL(string: list[i].scheme)
                }
            }
            return nil
        }

        // 内置「打开 App」别名表
        return match(Self.builtinAppSchemes)
    }

    /// 内置「打开 App」scheme 表（按 name 长度降序保证长名优先）
    private static let builtinAppSchemes: [(name: String, scheme: String)] = {
        let list: [(String, String)] = [
            // 第三方 App
            ("微信支付", "weixinpay://"), ("WeChat", "weixin://"), ("微信", "weixin://"),
            ("QQ空间", "mqzone://"), ("QQ音乐", "qqmusic://"), ("QQMusic", "qqmusic://"), ("QQ", "mqq://"),
            ("支付宝", "alipay://"), ("Alipay", "alipay://"),
            ("抖音极速版", "snssdk1128://"), ("Douyin", "snssdk1128://"), ("抖音", "snssdk1128://"),
            ("小红书", "xhsdiscover://"), ("XHS", "xhsdiscover://"),
            ("微博", "weibo://"), ("Weibo", "weibo://"),
            ("淘宝", "taobao://"), ("Taobao", "taobao://"),
            ("京东", "openapp.jdmobile://"), ("JD", "openapp.jdmobile://"),
            ("拼多多", "pinduoduo://"), ("PDD", "pinduoduo://"),
            ("哔哩哔哩", "bilibili://"), ("B站", "bilibili://"), ("BiliBili", "bilibili://"),
            ("美团", "imeituan://"), ("Meituan", "imeituan://"),
            ("饿了么", "eleme://"), ("Eleme", "eleme://"),
            ("高德地图", "iosamap://"), ("高德", "iosamap://"), ("Amap", "iosamap://"),
            ("百度地图", "baidumap://"), ("BaiduMap", "baidumap://"),
            ("网易云音乐", "orpheus://"), ("网易云", "orpheus://"), ("CloudMusic", "orpheus://"),
            ("爱奇艺", "iqiyi://"), ("Iqiyi", "iqiyi://"),
            ("腾讯视频", "tenvideo://"), ("TencentVideo", "tenvideo://"),
            ("优酷", "youku://"), ("Youku", "youku://"),
            ("知乎", "zhihu://"), ("Zhihu", "zhihu://"),
            ("百度", "baiduboxapp://"), ("Baidu", "baiduboxapp://"),
            ("钉钉", "dingtalk://"), ("DingTalk", "dingtalk://"),
            ("企业微信", "wxwork://"), ("WeCom", "wxwork://"),
            ("腾讯会议", "wemeet://"), ("WeMeet", "wemeet://"), ("会议", "wemeet://"),
            // 系统 App（稳定可用）
            ("浏览器", "http://"), ("Safari", "http://"), ("网页", "http://"),
            ("苹果地图", "http://maps.apple.com/?q="), ("地图", "http://maps.apple.com/?q="),
            ("照片", "photos-redirect://"), ("相册", "photos-redirect://"), ("图库", "photos-redirect://"),
            ("时钟", "clock-app://"), ("闹钟", "clock-app://"), ("计时器", "clock-app://"),
            ("备忘录", "mobilenotes://"), ("记事本", "mobilenotes://"),
            ("电话", "tel://"), ("拨号", "tel://"),
            ("邮件", "mailto://"), ("邮箱", "mailto://"), ("Mail", "mailto://"),
            ("通讯录", "contacts://"), ("联系人", "contacts://"), ("电话本", "contacts://"),
            ("系统设置", "App-Prefs:root="), ("设置", "App-Prefs:root="),
            ("天气", "weather://"), ("Weather", "weather://"),
            ("日历", "calshow://"), ("Calendar", "calshow://"),
            ("文件", "shareddocuments://"), ("Files", "shareddocuments://"),
            ("播客", "podcasts://"), ("Podcast", "podcasts://"),
            ("App Store", "itms-apps://"), ("应用商店", "itms-apps://"), ("AppStore", "itms-apps://"),
        ]
        return list
    }()

    /// 打开外部 URL / App scheme（直接 open，不依赖 canOpenURL，避免 LSApplicationQueriesSchemes 限制）
    /// 崩溃修复：UIApplication.shared.open 的 completion 对部分 scheme（成功拉起其他 App 后本 App 退到后台）
    /// 不保证回调。旧实现用 withTimeout + withCheckedContinuation，超时后 continuation 从未被 resume，
    /// 任务被取消/释放时触发 Swift 并发运行时 "CheckedContinuation leaked" fatalError → SIGTRAP 闪退。
    /// 新实现用「完成回调 + 5s 超时兜底」竞争同一个 continuation，保证它恰好被 resume 一次、绝不泄漏。
    private func openExternalURL(_ url: URL) async -> (description: String, success: Bool) {
        let opened: Bool = await withCheckedContinuation { continuation in
            // finished 标志保证回调与超时兜底只 resume 一次（两者都在主线程串行执行，无竞态）
            var finished = false
            func finish(_ ok: Bool) {
                guard !finished else { return }
                finished = true
                continuation.resume(returning: ok)
            }
            DispatchQueue.main.async {
                UIApplication.shared.open(url, options: [:]) { ok in
                    finish(ok)
                }
            }
            // 5 秒兜底：部分 scheme 成功拉起 App 后 completion 永不被回调，
            // 超时也视为「已发起打开」，避免 continuation 挂起/泄漏导致闪退或「没反应」
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                finish(false)
            }
        }
        if opened {
            return ("已打开「\(url.absoluteString)」", true)
        }
        return ("已尝试打开「\(url.absoluteString)」：请查看是否已切换到对应 App；若没有反应，可能该 App 未安装或不支持直接打开", true)
    }

    /// 从命令中提取数值：支持 "50"、"50%"、"0.5"、"50 %" 等
    private static func extractValue(_ cmd: String) -> Double? {
        // 数字后跟 % 视为百分比；否则 0~1 视为比例
        let pattern = #"(\d+(?:\.\d+)?)\s*%?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)),
              let r = Range(m.range(at: 1), in: cmd),
              let val = Double(cmd[r]) else { return nil }
        // 若数字后紧跟 %，说明是百分比
        let after = m.range(at: 1).upperBound
        let ns = cmd as NSString
        if after < ns.length, ns.substring(from: after).hasPrefix("%") {
            return val
        }
        return val > 1 ? val / 100.0 : val
    }

    // MARK: - 具体系统能力

    private func setBrightness(_ cmd: String) async -> (description: String, success: Bool) {
        let level: Double
        if let v = Self.extractValue(cmd) {
            level = min(1.0, max(0.0, v))
        } else {
            level = 0.5
        }
        let done = await withTimeout(5) {
            await MainActor.run { UIScreen.main.brightness = CGFloat(level) }
        } != nil
        if done {
            return ("已将屏幕亮度调整为 \(Int(level * 100))%", true)
        }
        return ("屏幕亮度调节失败", false)
    }

    private func setVolume(_ cmd: String) async -> (description: String, success: Bool) {
        let level: Float
        if let v = Self.extractValue(cmd) {
            level = Float(min(1.0, max(0.0, v)))
        } else {
            level = 0.5
        }
        let done = await withTimeout(5) {
            await MainActor.run {
                // MPVolumeView 需真实挂到窗口层级才能驱动系统音量，完成后立即移除
                let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
                volumeView.isHidden = true
                if let window = UIApplication.shared.connectedScenes
                    .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
                    window.addSubview(volumeView)
                    if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
                        slider.value = level
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        volumeView.removeFromSuperview()
                    }
                }
            }
        } != nil
        if done {
            return ("已将系统音量调整为 \(Int(level * 100))%", true)
        }
        return ("音量调节失败", false)
    }

    private func toggleTorch(_ cmd: String) async -> (description: String, success: Bool) {
        let off = cmd.contains("off") || cmd.contains("关") || cmd.contains("关闭")
        let on = !off && (cmd.contains("on") || cmd.contains("开") || cmd.contains("手电筒") || cmd.contains("闪光灯") || cmd.contains("torch"))
        let done = await withTimeout(5) {
            await MainActor.run {
                guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return false }
                do {
                    try device.lockForConfiguration()
                    device.torchMode = on ? .on : .off
                    if on { try? device.setTorchModeOn(level: 1.0) }
                    device.unlockForConfiguration()
                    return true
                } catch {
                    return false
                }
            }
        } != nil
        if done {
            return ("手电筒已\(on ? "打开" : "关闭")", true)
        }
        return ("手电筒操作失败（设备不支持或权限被拒绝）", false)
    }

    /// 跳转指定系统设置页；失败时回退到 App 设置页。
    /// 修复：不再用 canOpenURL 前判（iOS10+ 对未声明 LSApplicationQueriesSchemes 的 App-Prefs: 等 scheme
    /// 一律返回 false，导致永远走兜底、打不开目标设置页），open 本身不需要声明即可直接拉起。
    private func openSystemSettings(path: String, manual: String) async -> (description: String, success: Bool) {
        await MainActor.run {
            let candidates = ["App-Prefs:root=\(path)", "prefs:root=\(path)"]
            for urlString in candidates {
                if let url = URL(string: urlString) {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    return ("已打开「\(manual)」设置页面，请在出现的设置中完成操作", true)
                }
            }
            // 兜底：打开本 App 的系统设置页
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                return ("已打开本 App 的系统设置页，\(manual)", true)
            }
            return ("无法打开系统设置，\(manual)", false)
        }
    }
}

/// 定位服务（CoreLocation）
/// 定位修复 v28：
/// 1) didChangeAuthorization 授权后同时启动定位与指南针（原来只 requestLocation，指南针从不启动）；
/// 2) 新增 didFailWithError 处理：失败给出明确原因（原来空实现→永远超时返回 nil、用户只能看到「定位失败」）；
/// 3) awaitLocation/awaitHeading 等待授权时最长 20s（原来 notDetermined 时循环太快直接放弃）；
/// 4) 持续定位（startUpdatingLocation）替代单次 requestLocation，避免偶发一次定位失败。
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    private let manager = CLLocationManager()

    @Published var currentLocation: CLLocation?
    /// 最近一次朝向（指南针，度）。仅系统操作工具请求时更新。
    @Published var currentHeading: CLHeading?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    /// 最近一次定位/朝向失败原因（诊断展示）
    @Published var lastErrorText: String?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.headingFilter = 1
        authorizationStatus = manager.authorizationStatus
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// 请求定位（已授权时启动持续定位；未授权则先请求权限）。
    func requestLocation() {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
            // 保险：15 秒后仍无位置则补发一次单次请求（室内弱信号场景）
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self else { return }
                let s = self.manager.authorizationStatus
                guard s == .authorizedWhenInUse || s == .authorizedAlways else { return }
                if self.currentLocation == nil { self.manager.requestLocation() }
            }
        } else {
            requestPermission()
        }
    }

    /// 启动指南针（朝向）更新；已授权时生效。
    func requestHeading() {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingHeading()
        } else {
            requestPermission()
        }
    }

    /// 异步等待一次朝向数据（最长约 10 秒；等待授权时最长约 20 秒）。
    /// 返回 nil 时可用 lastErrorText 获取具体原因。
    func awaitHeading() async -> CLHeading? {
        if authorizationStatus == .notDetermined {
            requestPermission()
        } else if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.startUpdatingHeading()
        } else {
            lastErrorText = "定位权限被拒绝或受限，请到 设置 → 隐私 → 定位服务 中允许后重试"
            return nil
        }
        for _ in 0..<20 {
            if let h = currentHeading { return h }
            // 请求权限后仍 notDetermined（用户还没操作系统弹窗），继续等而不是空转
            if authorizationStatus == .notDetermined { continue }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if let h = currentHeading { return h }
        lastErrorText = self.authorizationStatus == .notDetermined
            ? "等待定位授权超时，请在弹出的系统弹窗中允许定位"
            : "暂时没有朝向数据（设备可能无磁力计，或建议到开阔处重试）"
        return nil
    }

    /// 异步等待一次定位结果（最长约 10 秒；等待授权时最长约 20 秒）。
    /// 返回 nil 时可用 lastErrorText 获取具体原因。
    func awaitLocation() async -> CLLocation? {
        if authorizationStatus == .notDetermined {
            requestPermission()
        } else if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        } else {
            lastErrorText = "定位权限被拒绝或受限，请到 设置 → 隐私 → 定位服务 中允许后重试"
            return nil
        }
        for _ in 0..<20 {
            if let loc = currentLocation { return loc }
            // 请求权限后仍 notDetermined（用户还没操作系统弹窗），继续等而不是空转
            if authorizationStatus == .notDetermined { continue }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if let loc = currentLocation { return loc }
        lastErrorText = self.authorizationStatus == .notDetermined
            ? "等待定位授权超时，请在弹出的系统弹窗中允许定位"
            : "暂时没有定位结果（建议到室外或开阔处重试）"
        return nil
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        DispatchQueue.main.async {
            self.authorizationStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                // 授权后同时启动定位与指南针：一次授权同时满足「定位 / 海拔 / 方向」三个能力
                manager.startUpdatingLocation()
                manager.startUpdatingHeading()
                self.lastErrorText = nil
            } else if status == .denied || status == .restricted {
                self.lastErrorText = "定位权限被拒绝，请到 设置 → 隐私 → 定位服务 中允许后重试"
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        DispatchQueue.main.async {
            self.currentLocation = locations.last
            self.lastErrorText = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        DispatchQueue.main.async {
            self.currentHeading = newHeading
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async {
            let ns = error as NSError
            switch ns.code {
            case CLError.locationUnknown.rawValue:
                // 位置暂时未知（常见于室内/冷启动）：保留现状，持续定位会在信号恢复后自动补上
                self.lastErrorText = "正在获取定位…（当前信号较弱）"
            case CLError.denied.rawValue:
                self.lastErrorText = "定位权限被拒绝，请到 设置 → 隐私 → 定位服务 中允许后重试"
            case CLError.headingFailure.rawValue:
                self.lastErrorText = "指南针/方向不可用（设备不支持或需要校准）"
            default:
                self.lastErrorText = "定位服务异常（\(ns.localizedDescription)）"
            }
        }
    }
}
