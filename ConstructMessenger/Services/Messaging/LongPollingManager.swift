//
//  LongPollingManager.swift
//  Construct Messenger
//
//  Manages long polling for incoming messages
//  Extracted from ChatsViewModel as part of Phase 1 refactoring
//  Created on 2026-01-31
//

import Foundation
import Combine
import UIKit

/// Manages long polling for incoming messages with exponential backoff
@MainActor
class LongPollingManager: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var isPolling = false
    
    // MARK: - Private State
    
    private var pollingTask: Task<Void, Never>?
    private var retryCount = 0
    private let maxRetryDelay: UInt64 = 60_000_000_000  // 60 seconds max
    private var isPaused = false
    
    /// Callback when messages are received
    private var onMessagesReceived: (([ChatMessageResponse]) -> Void)?
    
    /// Callback to get current lastMessageId
    private var getLastMessageId: (() -> String?)?
    
    /// Callback to update lastMessageId
    private var updateLastMessageId: ((String) -> Void)?
    
    // MARK: - Configuration
    
    private var pollingTimeout: Int
    private var postSuccessDelaySeconds: TimeInterval
    
    // MARK: - Initialization
    
    init(pollingTimeout: Int = LongPollingConfig.fullTimeoutSeconds,
         postSuccessDelaySeconds: TimeInterval = 0) {
        self.pollingTimeout = pollingTimeout
        self.postSuccessDelaySeconds = postSuccessDelaySeconds
    }
    
    // MARK: - Public API
    
    /// Start long polling for messages
    /// - Parameters:
    ///   - getLastMessageId: Closure to get current lastMessageId
    ///   - updateLastMessageId: Closure to update lastMessageId after poll
    ///   - onMessagesReceived: Callback when messages are received
    func startPolling(
        getLastMessageId: @escaping () -> String?,
        updateLastMessageId: @escaping (String) -> Void,
        onMessagesReceived: @escaping ([ChatMessageResponse]) -> Void,
        pollingTimeout: Int,
        postSuccessDelaySeconds: TimeInterval
    ) {
        guard !isPolling else {
            Log.info("📡 Long polling already running, skipping duplicate start", category: "LongPollingManager")
            return
        }

        updateConfiguration(pollingTimeout: pollingTimeout, postSuccessDelaySeconds: postSuccessDelaySeconds)
        
        self.getLastMessageId = getLastMessageId
        self.updateLastMessageId = updateLastMessageId
        self.onMessagesReceived = onMessagesReceived
        
        isPolling = true
        Log.info("📡 ✅ Starting long polling for messages", category: "LongPollingManager")
        
        pollingTask = Task { [weak self] in
            await self?.pollMessagesLoop()
        }
    }

    func updateConfiguration(pollingTimeout: Int, postSuccessDelaySeconds: TimeInterval) {
        guard self.pollingTimeout != pollingTimeout || self.postSuccessDelaySeconds != postSuccessDelaySeconds else { return }
        self.pollingTimeout = pollingTimeout
        self.postSuccessDelaySeconds = postSuccessDelaySeconds
        Log.debug("📡 Updated polling configuration: timeout=\(pollingTimeout)s, postDelay=\(postSuccessDelaySeconds)s", category: "LongPollingManager")
    }
    
    /// Stop long polling
    func stopPolling() {
        isPolling = false
        pollingTask?.cancel()
        pollingTask = nil
        retryCount = 0  // Reset backoff counter when stopping
        Log.info("📡 Stopped long polling", category: "LongPollingManager")
    }
    
    /// Pause polling (e.g., when app goes to background)
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        stopPolling()
        Log.info("📱 Long polling paused", category: "LongPollingManager")
    }
    
    /// Resume polling (e.g., when app becomes active)
    func resume(
        getLastMessageId: @escaping () -> String?,
        updateLastMessageId: @escaping (String) -> Void,
        onMessagesReceived: @escaping ([ChatMessageResponse]) -> Void
    ) {
        guard isPaused else { return }
        isPaused = false
        Log.info("📱 Long polling resumed", category: "LongPollingManager")
        
        startPolling(
            getLastMessageId: getLastMessageId,
            updateLastMessageId: updateLastMessageId,
            onMessagesReceived: onMessagesReceived,
            pollingTimeout: pollingTimeout,
            postSuccessDelaySeconds: postSuccessDelaySeconds
        )
    }
    
    // MARK: - Private Implementation
    
    private func pollMessagesLoop() async {
        while isPolling && !Task.isCancelled {
            do {
                // Get current lastMessageId
                let lastId = getLastMessageId?()
                
                // Log current state
                if let lastId = lastId {
                    Log.info("📡 Polling loop: lastMessageId=\(lastId)", category: "LongPollingManager")
                } else {
                    Log.info("📡 Polling loop: lastMessageId is nil (first request)", category: "LongPollingManager")
                }
                
                // Poll for messages
                let response = try await MessagingAPI.shared.pollMessages(
                    sinceId: lastId,
                    timeout: pollingTimeout
                )
                
                // Log response summary
                Log.info("📥 Poll response: \(response.messages.count) messages, nextSince=\(response.nextSince ?? "nil"), hasMore=\(response.hasMore ?? false)", category: "LongPollingManager")
                
                // Notify about received messages
                if !response.messages.isEmpty {
                    onMessagesReceived?(response.messages)
                }
                
                // Update last message ID for next poll
                if let nextSince = response.nextSince {
                    updateLastMessageId?(nextSince)
                    Log.info("✅ Updated lastMessageId from nextSince: \(lastId ?? "nil") -> \(nextSince)", category: "LongPollingManager")
                } else {
                    Log.info("ℹ️ No nextSince in response, keeping lastMessageId: \(lastId ?? "nil")", category: "LongPollingManager")
                }
                
                // Reset retry count on successful poll
                retryCount = 0
                
                // If there are more messages, poll again immediately
                if response.hasMore == true {
                    Log.info("🔄 hasMore=true, polling again immediately", category: "LongPollingManager")
                    continue
                }

                // Add light jitter after successful poll to reduce timing correlation
                if UIApplication.shared.applicationState == .active {
                    let jitterMs = UInt64.random(in: LongPollingConfig.successJitterMinMs...LongPollingConfig.successJitterMaxMs)
                    if jitterMs > 0 {
                        try? await Task.sleep(nanoseconds: jitterMs * 1_000_000)
                    }
                }

                // Optional idle delay (used for minimal polling when push is enabled)
                if postSuccessDelaySeconds > 0 {
                    let delayNs = UInt64(postSuccessDelaySeconds * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: delayNs)
                }
                
            } catch {
                // Check if polling was explicitly stopped (e.g., app went to background)
                // In that case, don't log error or retry - this is expected behavior
                guard isPolling else {
                    Log.debug("📡 Polling stopped, exiting loop (error was: \(error.localizedDescription))", category: "LongPollingManager")
                    break
                }
                
                Log.error("❌ Long polling error: \(error.localizedDescription)", category: "LongPollingManager")
                
                // EXPONENTIAL BACKOFF: Increase delay with each consecutive failure
                // Pattern: 5s → 10s → 20s → 40s → 60s (max)
                // Prevents hammering server when it's down, saves battery
                retryCount += 1
                let baseDelay: UInt64 = 5_000_000_000  // 5 seconds
                let exponentialDelay = baseDelay * UInt64(pow(2.0, Double(min(retryCount - 1, 4))))
                
                // Add random jitter (0-2.5s) to prevent thundering herd
                // If many clients reconnect simultaneously, jitter spreads the load
                let jitter = UInt64.random(in: 0...(baseDelay / 2))
                let delay = min(exponentialDelay + jitter, maxRetryDelay)
                
                let delaySeconds = Double(delay) / 1_000_000_000.0
                Log.info("⏳ Retry attempt #\(retryCount) in \(String(format: "%.1f", delaySeconds))s (exponential backoff)", category: "LongPollingManager")
                
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }
}
