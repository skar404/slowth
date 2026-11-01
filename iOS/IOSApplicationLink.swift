import Foundation

/// App-owned routes. Opening a URL never changes Screen Time protection.
enum IOSApplicationLink {
    static func url(for target: String) -> URL? {
        let links = ["youtube": "youtube://", "instagram": "instagram://app",
                     "facebook": "fb://feed", "x": "twitter://timeline"]
        return links[target].flatMap(URL.init(string:))
    }

}
