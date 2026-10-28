import Foundation
import CoreGraphics

struct DisplayPresetEntry: Codable, Identifiable {
    var id = UUID()
    var displayUUID: String       // matches physical display
    var width: Int
    var height: Int
    var isHiDPI: Bool
    var brightness: Double?       // 0.0-1.0 SDR; higher factors within the enabled HDR range
    var brightnessScaleVersion: Int? = nil  // nil: legacy EDR percentages; 2: three HDR control steps
    var arrangementX: Double?     // optional position
    var arrangementY: Double?
}

struct DisplayPreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var icon: String              // SF Symbol name
    var isBuiltin: Bool = false
    var displays: [DisplayPresetEntry]
}
