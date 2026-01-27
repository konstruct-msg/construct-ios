# State Machine Architecture Migration Plan

## Current Status: Phase 2 (Reactive Combine)

**Date Created:** 2026-01-24  
**Priority:** Medium (Future Enhancement)  
**Estimated Effort:** 2-3 days

---

## Overview

This document outlines a planned migration from the current **Reactive Combine** architecture to an explicit **State Machine** pattern for managing authentication and polling states.

### Current Architecture (Phase 2)

```swift
// SessionManager.swift
class SessionManager: ObservableObject {
    @Published private(set) var sessionToken: String?
}

// ChatsViewModel.swift
Publishers.CombineLatest(
    SessionManager.shared.$sessionToken,
    connectionStatusManager.$connectionStatus
)
.sink { token, status in
    if token != nil && status == .connected {
        startLongPolling()
    }
}
```

**Strengths:**
- ✅ Declarative and reactive
- ✅ SwiftUI-idiomatic
- ✅ Eliminated race conditions
- ✅ Automatic state synchronization

**Weaknesses:**
- ⚠️ Implicit state - hard to see all possible states
- ⚠️ No validation of state transitions
- ⚠️ Difficult to add complex logic (offline mode, reconnection backoff)
- ⚠️ State can become inconsistent (token exists but userId is nil)

---

## Proposed Architecture (Phase 3)

### Explicit State Machine

```swift
// MARK: - Authentication State

enum AuthState: Equatable {
    case unauthenticated
    case authenticating
    case authenticated(token: String, userId: String, expiresAt: Date)
    case sessionExpired(userId: String)
}

// MARK: - Polling State

enum PollingState: Equatable {
    case stopped
    case starting
    case active(lastMessageId: String?)
    case suspended(reason: SuspensionReason)
    case reconnecting(attempt: Int, backoff: TimeInterval)
    
    enum SuspensionReason {
        case noNetwork
        case appInBackground
        case rateLimited
    }
}

// MARK: - State Manager

class AppStateManager: ObservableObject {
    @Published private(set) var authState: AuthState = .unauthenticated
    @Published private(set) var pollingState: PollingState = .stopped
    
    // MARK: - State Transitions
    
    func authenticate(token: String, userId: String, expiresAt: Date) {
        guard case .unauthenticated = authState else {
            assertionFailure("Invalid state transition: already authenticated")
            return
        }
        
        authState = .authenticated(token: token, userId: userId, expiresAt: expiresAt)
        // Automatically transition polling state
        attemptStartPolling()
    }
    
    func startPolling() {
        guard case .authenticated = authState else {
            assertionFailure("Cannot start polling: not authenticated")
            return
        }
        
        guard case .stopped = pollingState else {
            return // Already polling
        }
        
        pollingState = .starting
        // Actual polling logic...
    }
    
    func handleNetworkDisconnect() {
        guard case .active = pollingState else { return }
        pollingState = .suspended(reason: .noNetwork)
    }
    
    func handleNetworkReconnect() {
        guard case .suspended(.noNetwork) = pollingState else { return }
        pollingState = .reconnecting(attempt: 1, backoff: 1.0)
    }
}
```

---

## Benefits of State Machine

### 1. **Impossible States Are Impossible**

**Current Problem:**
```swift
// This can happen:
sessionToken = "abc123"
currentUserId = nil  // ❌ Inconsistent state!
```

**State Machine Solution:**
```swift
case authenticated(token: String, userId: String, expiresAt: Date)
// Token and userId are always together ✅
```

### 2. **Explicit State Transitions**

**Current Problem:**
```swift
// What states can transition to polling?
// Where in the code do these transitions happen?
// 🤷 Hard to tell
```

**State Machine Solution:**
```swift
func attemptStartPolling() {
    switch authState {
    case .authenticated(_, _, _):
        pollingState = .starting  // ✅ Clear transition
    case .unauthenticated, .sessionExpired:
        // ❌ Not allowed
        break
    }
}
```

### 3. **Better Error Handling**

```swift
func handlePollingError(_ error: Error) {
    guard case .active(let lastId) = pollingState else {
        assertionFailure("Received polling error in invalid state")
        return
    }
    
    switch error {
    case NetworkError.rateLimited:
        pollingState = .suspended(reason: .rateLimited)
    case NetworkError.unauthorized:
        authState = .sessionExpired(userId: currentUserId)
        pollingState = .stopped
    default:
        // Exponential backoff
        pollingState = .reconnecting(attempt: 1, backoff: 1.0)
    }
}
```

### 4. **Offline Mode Support**

```swift
enum PollingState {
    case offline(queuedMessages: [Message])
    
    // When network returns:
    func handleNetworkRestored() {
        if case .offline(let queued) = pollingState {
            pollingState = .active(lastMessageId: nil)
            sendQueuedMessages(queued)
        }
    }
}
```

---

## Migration Strategy

### Phase 1: Add State Types (No Breaking Changes)

1. Create `AppStateManager.swift` with state enums
2. Keep existing `SessionManager` for backward compatibility
3. Mirror state in both systems

### Phase 2: Gradual Migration

1. Migrate `ChatsViewModel` to use `AppStateManager`
2. Migrate `AuthViewModel` to use state transitions
3. Add unit tests for state transitions

### Phase 3: Cleanup

1. Remove old reactive publishers
2. Remove `SessionManager` (or make it internal)
3. Update all views to use new state

---

## Testing Strategy

### Unit Tests for State Transitions

```swift
func testAuthenticationFlow() {
    let manager = AppStateManager()
    
    XCTAssertEqual(manager.authState, .unauthenticated)
    
    manager.authenticate(
        token: "token",
        userId: "user123",
        expiresAt: Date().addingTimeInterval(3600)
    )
    
    guard case .authenticated = manager.authState else {
        XCTFail("Expected authenticated state")
        return
    }
    
    XCTAssertEqual(manager.pollingState, .starting)
}

func testInvalidTransitions() {
    let manager = AppStateManager()
    
    // Try to start polling without auth
    manager.startPolling()
    
    // Should remain stopped
    XCTAssertEqual(manager.pollingState, .stopped)
}
```

---

## Files to Modify

### New Files
- `AppStateManager.swift` - Central state machine
- `AuthState.swift` - Auth state enum
- `PollingState.swift` - Polling state enum
- `AppStateManagerTests.swift` - Unit tests

### Modified Files
- `SessionManager.swift` - Wrapper around AppStateManager
- `ChatsViewModel.swift` - Use state machine
- `AuthViewModel.swift` - Use state transitions
- `ConnectionStatusManager.swift` - Integrate with state machine

---

## References

- [State Machines in Swift](https://www.vadimbulavin.com/state-machine-design-pattern-in-swift/)
- [Finite State Machines for iOS](https://medium.com/swiftcairo/finite-state-machines-in-swift-5-b6e0b7f7f0a0)
- [TCA State Management](https://github.com/pointfreeco/swift-composable-architecture)

---

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-01-24 | Use Combine (Phase 2) | Quick fix for race condition, reactive approach works for current scope |
| TBD | Migrate to State Machine (Phase 3) | When adding offline mode, reconnection logic, or complex state management |

---

## Notes

- This migration is **not urgent** - current Combine approach is working
- Trigger migration when:
  - Adding offline mode
  - Implementing complex reconnection logic
  - Debugging hard-to-reproduce state bugs
  - Team has bandwidth for 2-3 day refactor
