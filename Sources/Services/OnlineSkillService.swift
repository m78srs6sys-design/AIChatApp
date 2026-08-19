import Foundation
import CoreLocation

/// 联网技能服务集合：搜索、图片生成、天气、网页抓取、语音合成。
/// 全部使用「免密钥」公开接口实现，无需配置任何后端服务：
///   - 搜索：维基百科 API
///   - 图片生成：Pollinations.ai
///   - 天气：open-meteo
///   - 网页抓取：直连目标 URL 并裁剪正文
final class OnlineSkillService {
    static let shared = OnlineSkillService()
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        session = URLSession(configuration: cfg)
    }

    // MARK: - 联网搜索（维基百科，免密钥）
    func search(query: String) async throws -> [SearchResultItem] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlStr = "https://zh.wikipedia.org/w/api.php?action=query&list=search&srsearch=\(q)&format=json&srlimit=5&prop=snippet"
        guard let url = URL(string: urlStr) else { return [] }
        let (data, resp) = try await session.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queryObj = json["query"] as? [String: Any],
              let searchArr = queryObj["search"] as? [[String: Any]] else { return [] }
        return searchArr.compactMap { d -> SearchResultItem? in
            guard let title = d["title"] as? String else { return nil }
            let raw = d["snippet"] as? String ?? ""
            let snippet = raw
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&nbsp;", with: " ")
            let enc = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
            return SearchResultItem(title: title,
                                    url: "https://zh.wikipedia.org/wiki/\(enc)",
                                    snippet: snippet.isEmpty ? nil : snippet)
        }
    }

    // MARK: - AI 图片生成（Pollinations，免密钥，直出图片 URL）
    /// 使用 flux 模型 + enhance 自动增强提示词（大幅提升「贴合度」）。
    /// 建议让模型在 <image> 标签内填写「英文画面描述」以获得最佳效果。
    func generateImage(prompt: String) async throws -> String {
        let p = prompt.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? prompt
        let seed = Int.random(in: 1...1_000_000)
        let url = "https://image.pollinations.ai/prompt/\(p)?width=1024&height=1024&nologo=true&model=flux&enhance=true&seed=\(seed)"
        guard URL(string: url) != nil else { throw ChatError.requestFailed }
        return url
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
              let (data, _) = try? await session.data(from: u),
              let raw = String(data: data, encoding: .utf8) else {
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
        return WebpageSummary(url: url, title: title, summary: String(text.prefix(4000)))
    }

    // MARK: - 语音合成（未接入后端时降级，不影响文本）
    func synthesizeSpeech(text: String) async throws -> String {
        throw ChatError.requestFailed
    }
}

/// 定位服务（CoreLocation）
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    private let manager = CLLocationManager()

    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authorizationStatus = manager.authorizationStatus
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func requestLocation() {
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        } else {
            requestPermission()
        }
    }

    /// 异步等待一次定位结果（最多约 10 秒）。未授权时先弹权限请求。
    func awaitLocation() async -> CLLocation? {
        if authorizationStatus == .notDetermined {
            requestPermission()
        } else if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        } else {
            return nil
        }
        for _ in 0..<20 {
            if let loc = currentLocation { return loc }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return currentLocation
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        DispatchQueue.main.async { self.authorizationStatus = status }
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        DispatchQueue.main.async {
            self.currentLocation = locations.last
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
