import AppKit
import SwiftUI

enum AppResources {
    static func image(named name: String) -> NSImage? {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("\(name).png"),
           let image = NSImage(contentsOf: resourceURL) {
            return image
        }
        #if SWIFT_PACKAGE
        if let resourceURL = Bundle.module.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: resourceURL) {
            return image
        }
        #endif
        return nil
    }
}
