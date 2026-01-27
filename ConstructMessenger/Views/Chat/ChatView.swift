//
//  ChatView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI
import CoreData

struct ChatView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ChatViewModel  // ✅ FIX: StateObject persists across view updates
    @ObservedObject private var connectionManager = ConnectionStatusManager.shared
    @State private var messageText = ""
    @State private var replyingTo: Message?
    @State private var showingUserProfile = false
    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var hasScrolledToBottom = false
    @State private var scrollProxy: ScrollViewProxy?
    @State private var isEditMode = false
    @State private var selectedMessages: Set<String> = []
    @State private var shouldScrollToBottom = true
    @State private var scrollOffset: CGFloat = 0
    @State private var dragOffset: CGFloat = 0
    @GestureState private var dragState: CGFloat = 0

    init(chat: Chat, context: NSManagedObjectContext) {
        // ✅ FIX: Use StateObject initializer to create ViewModel only once
        _viewModel = StateObject(wrappedValue: ChatViewModel(chat: chat, context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBanner
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // ✅ NEW: Load more messages indicator at the top
                        if viewModel.hasMoreMessages && !filteredMessages.isEmpty {
                            HStack {
                                Spacer()
                                if viewModel.isLoadingMore {
                                    ProgressView()
                                        .padding()
                                } else {
                                    Button {
                                        viewModel.loadMoreMessages()
                                    } label: {
                                        Text(NSLocalizedString("load_older_messages", comment: "Load older messages button"))
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                            .padding(.vertical, 8)
                                    }
                                }
                                Spacer()
                            }
                            .id("loadMoreIndicator")
                            .onAppear {
                                // Auto-load when scrolling near the top
                                if !viewModel.isLoadingMore && !isSearchActive {
                                    viewModel.loadMoreMessages()
                                }
                            }
                        }
                        
                        ForEach(Array(filteredMessages.enumerated()), id: \.element.id) { index, message in
                            VStack(spacing: 0) {
                                MessageBubble(
                                    message: message,
                                    isLastInGroup: isLastInGroup(message, at: index, in: filteredMessages),
                                    isSelected: selectedMessages.contains(message.id),
                                    isEditMode: isEditMode,
                                    onRetry: { msg in
                                        viewModel.retryMessage(msg)
                                    },
                                    onReply: { msg in
                                        replyingTo = msg
                                    },
                                    onDelete: { msg in
                                        viewModel.deleteMessage(msg)
                                    },
                                    onSelect: { msg in
                                        toggleMessageSelection(msg)
                                    },
                                    onEnterSelectMode: { msg in
                                        withAnimation {
                                            isEditMode = true
                                            isSearchActive = false
                                            searchText = ""
                                            selectedMessages.insert(msg.id)
                                        }
                                    }
                                )
                                .id(message.id)

                                // Add spacing after each message
                                if index < filteredMessages.count - 1 {
                                    Spacer()
                                        .frame(height: spacingAfterMessage(at: index, in: filteredMessages))
                                }
                            }
                            .onAppear {

                                if index == filteredMessages.count - 1 && shouldScrollToBottom && !hasScrolledToBottom {
                                    DispatchQueue.main.async {
                                        scrollToBottom(proxy: proxy)
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(key: ScrollOffsetPreferenceKey.self, value: geometry.frame(in: .named("scroll")).minY)
                            Color.clear.onAppear {
                                scrollProxy = proxy
                            }
                        }
                    )
                }
                .coordinateSpace(name: "scroll")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                    scrollOffset = value
                }
                .onAppear {
                    scrollProxy = proxy
                    if AppConstants.enableDebugLogging {
                        print("ChatView appeared with \(viewModel.messages.count) messages")
                    }

                    shouldScrollToBottom = true
                    hasScrolledToBottom = false
                    
                    // ✅ Clear badge when user opens a chat
                    LocalNotificationManager.shared.clearBadge()
                    
                    // Scroll to bottom when view appears if we have messages
                    if !viewModel.messages.isEmpty {
                        DispatchQueue.main.async {
                            scrollToBottom(proxy: proxy)
                        }
                    }
                }
                .onChange(of: viewModel.messages.count) { count in
                    if AppConstants.enableDebugLogging {
                        print("ChatView: messages count changed to \(count)")
                    }

                    if shouldScrollToBottom && !isSearchActive && !viewModel.messages.isEmpty {
  
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollToBottom(proxy: proxy)
                        }
                    }
                }
                .onChange(of: searchText) { newValue in

                    if !newValue.isEmpty, !filteredMessages.isEmpty, let firstMatch = filteredMessages.first {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation {
                                proxy.scrollTo(firstMatch.id, anchor: .center)
                            }
                        }
                    } else if newValue.isEmpty {
                        // When search is cleared, scroll back to bottom
                        shouldScrollToBottom = true
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: isSearchActive) { active in
                    if active {
                        // When search is activated, exit edit mode
                        if isEditMode {
                            isEditMode = false
                            selectedMessages.removeAll()
                        }
                    } else {
                        // When search is dismissed, scroll back to bottom
                        searchText = ""
                        shouldScrollToBottom = true
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: isEditMode) { editMode in
                    if editMode {
                        // When edit mode is activated, exit search
                        if isSearchActive {
                            isSearchActive = false
                            searchText = ""
                        }
                    }
                }
            }
            
            deleteButtonBar
            
            messageInputView
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar(content: toolbarContent)
        .gesture(
            DragGesture(minimumDistance: 10)
                .updating($dragState) { value, state, _ in
                    // Only allow swipe from left edge (right swipe)
                    if value.startLocation.x < 20 && value.translation.width > 0 {
                        state = min(value.translation.width, UIScreen.main.bounds.width * 0.5)
                    }
                }
                .onEnded { value in
                    // If swiped more than 100 points or 30% of screen width, dismiss
                    let threshold = max(100, UIScreen.main.bounds.width * 0.3)
                    if value.translation.width > threshold && value.startLocation.x < 20 {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dismiss()
                        }
                    }
                }
        )
        .offset(x: dragState)
        .overlay(alignment: .top, content: searchOverlay)
        .sheet(isPresented: $showingUserProfile) {
            if let user = viewModel.chat.otherUser {
                UserProfileView(user: user)
            }
        }
    }
    
    // MARK: - View Components
    
    @ViewBuilder
    private var statusBanner: some View {
        if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
            statusBannerRow(text: errorMessage, color: .red, isLocalized: false)
        } else if viewModel.isSending {
            statusBannerRow(text: NSLocalizedString("sending", comment: ""), color: .secondary)
        } else if !viewModel.isSessionReady {
            statusBannerRow(text: NSLocalizedString("initializing_secure_connection", comment: ""), color: .orange, showProgress: true)
        } else if !connectionManager.isConnected {
            statusBannerRow(text: NSLocalizedString("not_connected_to_server", comment: ""), color: .red)
        }
    }
    
    @ViewBuilder
    private func statusBannerRow(text: String, color: Color, showProgress: Bool = false, isLocalized: Bool = true) -> some View {
        HStack(spacing: 8) {
            if showProgress {
                ProgressView()
                    .scaleEffect(0.7)
            }
            // If text is already a full message (contains spaces or special chars), use it directly
            // Otherwise, try to localize it
            let displayText = isLocalized ? NSLocalizedString(text, comment: "") : text
            Text(displayText)
                .font(.caption)
                .foregroundColor(color)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.1))
    }
    
    @ViewBuilder
    private var deleteButtonBar: some View {
        if isEditMode && !selectedMessages.isEmpty {
            HStack {
                Button(role: .destructive) {
                    deleteSelectedMessages()
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("delete_selected")
                    }
                    .foregroundColor(.red)
                }
                Spacer()
                Text("\(selectedMessages.count) \(selectedMessages.count == 1 ? "message_selected" : "messages_selected")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.systemGray6))
        }
    }
    
    private var messageInputView: some View {
        MessageInputView(
            text: $messageText,
            isSending: viewModel.isSending,
            replyingTo: replyingTo,
            onSend: { images in
                viewModel.sendMessage(text: messageText, images: images, replyTo: replyingTo)
                messageText = ""
                replyingTo = nil
            },
            onCancelReply: {
                replyingTo = nil
            }
        )
        .disabled(isEditMode)
    }
    
    @ToolbarContentBuilder
    private func toolbarContent() -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button {
                showingUserProfile = true
            } label: {
                VStack(spacing: 2) {
                    Text(viewModel.chat.otherUser?.displayName ?? NSLocalizedString("chat", comment: "Default chat title"))
                        .font(.headline)
                        .foregroundColor(.primary)
                }
            }
        }
        
        ToolbarItem(placement: .navigationBarTrailing) {
            toolbarTrailingButtons
        }
    }
    
    @ViewBuilder
    private var toolbarTrailingButtons: some View {
        HStack(spacing: 12) {
            if !isEditMode {
                Button {
                    withAnimation {
                        isSearchActive.toggle()
                        if !isSearchActive {
                            searchText = ""
                        }
                    }
                } label: {
                    Image(systemName: isSearchActive ? "xmark.circle.fill" : "magnifyingglass")
                }
            }
            
            if isEditMode {
                Button {
                    withAnimation {
                        isEditMode = false
                        selectedMessages.removeAll()
                    }
                } label: {
                    Text("done")
                }
            }
        }
    }
    
    @ViewBuilder
    private func searchOverlay() -> some View {
        if isSearchActive {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    TextField("search_messages", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                    Button {
                        withAnimation {
                            isSearchActive = false
                            searchText = ""
                        }
                    } label: {
                        Text("cancel")
                    }
                }
                .padding()
                .background(Color(.systemBackground).shadow(color: .black.opacity(0.1), radius: 2, y: 1))
                Spacer()
            }
        }
    }

    // MARK: - Computed Properties
    
    private var filteredMessages: [Message] {
        if searchText.isEmpty {
            return viewModel.messages
        }
        return viewModel.messages.filter { message in
            message.decryptedContent?.localizedCaseInsensitiveContains(searchText) ?? false
        }
    }

    // MARK: - Actions
    
    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard !isSearchActive, !viewModel.messages.isEmpty else { return }
        
        if let lastMessage = viewModel.messages.last {
            withAnimation {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
            hasScrolledToBottom = true
            shouldScrollToBottom = false
        }
    }

    private func toggleMessageSelection(_ message: Message) {
        if selectedMessages.contains(message.id) {
            selectedMessages.remove(message.id)
        } else {
            selectedMessages.insert(message.id)
        }
    }
    
    private func deleteSelectedMessages() {
        guard !selectedMessages.isEmpty else { return }
        
        let messageIds = selectedMessages
        viewModel.deleteMessages(withIds: messageIds)
        
        withAnimation {
            selectedMessages.removeAll()
            isEditMode = false
        }
    }

    // MARK: - Message Grouping Logic

    /// Determines if a message is the last in a group of consecutive messages from the same sender
    private func isLastInGroup(_ message: Message, at index: Int, in messages: [Message]) -> Bool {
        // ✅ REFACTOR: No more defensive checks needed - FRC ensures valid messages only
        
        // If this is the last message, it's always the last in its group
        guard index < messages.count - 1 else {
            return true
        }

        let nextMessage = messages[index + 1]

        // Different sender = end of group
        if message.isSentByMe != nextMessage.isSentByMe {
            return true
        }

        // If more than 5 minutes apart, start a new group
        let timeDifference = nextMessage.timestamp.timeIntervalSince(message.timestamp)
        if timeDifference > 300 { // 5 minutes
            return true
        }

        return false
    }

    /// Returns appropriate spacing after a message
    private func spacingAfterMessage(at index: Int, in messages: [Message]) -> CGFloat {
        let message = messages[index]

        // If this is the last in group, use larger spacing
        if isLastInGroup(message, at: index, in: messages) {
            return 12
        }

        // Otherwise, use compact spacing within the group
        return 4
    }
}

// ✅ NEW: Preference key for tracking scroll offset
private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext

    // Create sample data
    let user = PreviewHelpers.createSampleUser(context: context, username: "alice", displayName: "Alice")
    let chat = PreviewHelpers.createSampleChat(context: context, with: user)

    // Add sample messages
    _ = PreviewHelpers.createSampleMessage(context: context, chat: chat, isSentByMe: false, text: "Hi! How are you?")
    _ = PreviewHelpers.createSampleMessage(context: context, chat: chat, isSentByMe: true, text: "I'm good, thanks!")
    _ = PreviewHelpers.createSampleMessage(context: context, chat: chat, isSentByMe: false, text: "Great to hear!")

    try? context.save()

    return NavigationStack {
        ChatView(chat: chat, context: context)
            .environment(\.managedObjectContext, context)
    }
}

