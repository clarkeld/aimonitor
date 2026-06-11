import Foundation

enum AppVersion {
    static let current: String = {
        if let infoDictionary = Bundle.main.infoDictionary,
           let version = infoDictionary["CFBundleShortVersionString"] as? String {
            return version
        }
        return "1.0.5"
    }()
    
    static let build: String = {
        if let infoDictionary = Bundle.main.infoDictionary,
           let build = infoDictionary["CFBundleVersion"] as? String {
            return build
        }
        return "5"
    }()
}