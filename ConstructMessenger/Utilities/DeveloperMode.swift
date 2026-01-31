//
//  DeveloperMode.swift
//  ConstructMessenger
//
//  Hidden developer mode for internal debugging
//  Activation: Tap app version 10 times in Settings
//

import Foundation
import UIKit

class DeveloperMode: ObservableObject {
    static let shared = DeveloperMode()
    
    // MARK: - Developer Mode State
    
    @Published private(set) var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "developerModeEnabled")
            Log.info("🔧 Developer Mode: \(isEnabled ? "ENABLED" : "DISABLED")")
        }
    }
    
    // MARK: - Activation Mechanism
    
    private var tapCount: Int = 0
    private var lastTapTime: Date = Date()
    private let requiredTaps: Int = 10
    private let tapTimeout: TimeInterval = 3.0 // Reset if idle > 3 seconds
    
    private init() {
        #if DEBUG
        // In DEBUG builds, developer mode can be enabled
        self.isEnabled = UserDefaults.standard.bool(forKey: "developerModeEnabled")
        #else
        // In PRODUCTION builds, ALWAYS disabled
        // Even if UserDefaults has it enabled, force disable
        self.isEnabled = false
        UserDefaults.standard.set(false, forKey: "developerModeEnabled")
        #endif
    }
    
    // MARK: - Public API
    
    /// Register a tap on version label (call from SettingsView)
    func registerVersionTap() {
        #if DEBUG
        let now = Date()
        
        // Reset counter if too much time passed
        if now.timeIntervalSince(lastTapTime) > tapTimeout {
            tapCount = 0
        }
        
        tapCount += 1
        lastTapTime = now
        
        Log.debug("Version tap: \(tapCount)/\(requiredTaps)")
        
        if tapCount >= requiredTaps {
            toggle()
            tapCount = 0 // Reset counter
        }
        #else
        // In production: do nothing, ignore taps
        // This prevents accidental activation even if code is somehow called
        #endif
    }
    
    /// Toggle developer mode
    private func toggle() {
        #if DEBUG
        isEnabled.toggle()
        
        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        if isEnabled {
            generator.notificationOccurred(.success)
        } else {
            generator.notificationOccurred(.warning)
        }
        #else
        // Production: NEVER allow toggling
        isEnabled = false
        #endif
    }
    
    /// Force disable (for security)
    func forceDisable() {
        isEnabled = false
        tapCount = 0
    }
    
    // MARK: - Feature Flags
    
    /// Can user enable log collection?
    var canEnableLogCollection: Bool {
        #if DEBUG
        return isEnabled
        #else
        return false // NEVER in production
        #endif
    }
    
    /// Can user view debug logs section?
    var showDebugLogsSection: Bool {
        #if DEBUG
        return isEnabled
        #else
        return false
        #endif
    }
    
    /// Can user export logs?
    var canExportLogs: Bool {
        #if DEBUG
        return isEnabled
        #else
        return false
        #endif
    }
    
    /// Show advanced session debugging?
    var showSessionDebugInfo: Bool {
        #if DEBUG
        return isEnabled
        #else
        return false
        #endif
    }
}
