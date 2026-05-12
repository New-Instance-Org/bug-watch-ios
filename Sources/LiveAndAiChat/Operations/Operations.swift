import Foundation

/// GraphQL operation strings. Mirrors `Operations.kt` and the web SDK's
/// `core/operations.ts` field-for-field so all three clients pin the
/// same selection sets and the gql-server only needs one source of truth.
enum Operations {
    static let getCsConfig = """
    query GetCsConfig {
      getCsConfig {
        branding { primaryColor secondaryColor accentColor backgroundColor textColor fontFamily logoUrl companyName }
        appearance {
          version fontFamily themeMode
          colors {
            chatBackground headerBackground headerPrimaryText headerSecondaryText headerIcon closeButton
            receivedBubble receivedText receivedTimestamp
            sentBubble sentText sentTimestamp
            systemMessageText
            daySeparatorBackground daySeparatorText
            footerContainer
            chatInputBackground chatInputText chatInputPlaceholder chatInputBorder
            sendButtonBackground sendButtonIcon
            attachmentButton emojiButton
            typingIndicatorBackground typingIndicatorDot
            unreadBadgeBackground unreadBadgeText
            scrollToBottomButtonBackground scrollToBottomButtonIcon
            onlineStatus offlineStatus
            error success warning
          }
          backgroundImage { enabled url opacity position size repeat overlayColor overlayOpacity }
        }
        settings { welcomeMessage offlineMessage placeholderText enableFileUpload enableEmojis enableTypingIndicator requireCustomerEmail }
        widget { position size theme showOnlineStatus enableSounds }
        chatInterface { enabled }
        aiChatbot { enabled }
        liveChatModule { enabled }
      }
    }
    """

    static let getLiveChatBootstrap = """
    query GetLiveChatBootstrap {
      getLiveChatBootstrap {
        transport sseUrl wsUrl
        reconnect { initialDelayMs maxDelayMs maxAttempts }
        eventReplayWindowSeconds serverTime
      }
    }
    """

    static let getCsEventsSince = """
    query GetCsEventsSince($conversationId: ID!, $sinceSeq: Int!, $limit: Int) {
      getCsEventsSince(conversationId: $conversationId, sinceSeq: $sinceSeq, limit: $limit) {
        conversationId latestSeq complete
        events { seq type at payload }
      }
    }
    """

    static let initChat = """
    mutation InitCsAiChat($input: InitCsAiChatInput!) {
      initCsAiChat(input: $input) {
        success conversationId
        conversation { id status assignedAgentId assignedAgentName }
        assignment { id conversationId status assignedAgentId assignedAgentName queuePosition estimatedWaitTime }
        messages {
          id conversationId seq clientId content type status
          sender { senderId senderName senderEmail }
          attachments { url name type size }
          sentAt deliveredAt readAt
        }
      }
    }
    """

    static let getConversationState = """
    query GetCsConversationState($conversationId: ID!) {
      getCsConversationState(conversationId: $conversationId) {
        conversation { id status assignedAgentId assignedAgentName }
        assignment { id conversationId status assignedAgentId assignedAgentName queuePosition estimatedWaitTime }
      }
    }
    """

    static let sendMessage = """
    mutation SendCsCustomerMessage($conversationId: ID!, $content: String!, $attachments: [CsAttachmentInput!], $clientId: String) {
      sendCsCustomerMessage(conversationId: $conversationId, content: $content, attachments: $attachments, clientId: $clientId) {
        success
        customerMessage {
          id conversationId seq clientId content type status
          sender { senderId senderName senderEmail }
          attachments { url name type size }
          sentAt
        }
        aiResponse {
          id conversationId seq clientId content type status
          sender { senderId senderName senderEmail }
          attachments { url name type size }
          sentAt
        }
        handoffRequested
        assignment {
          id conversationId status assignedAgentId assignedAgentName
          customerName source handoffReason estimatedWaitTime queuePosition
        }
      }
    }
    """

    static let requestHandoff = """
    mutation RequestCsHandoff($conversationId: ID!, $reason: String) {
      requestCsHandoff(conversationId: $conversationId, reason: $reason) {
        success message
        assignment { id conversationId status estimatedWaitTime queuePosition }
      }
    }
    """

    static let getMessages = """
    query GetCsMessages($conversationId: ID!, $limit: Int, $before: DateTime) {
      getCsMessages(conversationId: $conversationId, limit: $limit, before: $before) {
        id conversationId seq clientId content type status
        sender { senderId senderName senderEmail }
        attachments { url name type size }
        sentAt deliveredAt readAt
      }
    }
    """

    static let sendTypingStart = """
    mutation SendCsTypingStart($conversationId: ID!, $userName: String) {
      sendCsTypingStart(conversationId: $conversationId, userName: $userName)
    }
    """

    static let sendTypingStop = """
    mutation SendCsTypingStop($conversationId: ID!) {
      sendCsTypingStop(conversationId: $conversationId)
    }
    """

    static let subMessageReceived = """
    subscription CsMessageReceived($conversationId: ID!) {
      csMessageReceived(conversationId: $conversationId) {
        id conversationId seq clientId content type status
        sender { senderId senderName senderEmail }
        attachments { url name type size }
        sentAt deliveredAt readAt
        totalMessages
      }
    }
    """

    static let subConversationUpdated = """
    subscription CsConversationUpdated($conversationId: ID!) {
      csConversationUpdated(conversationId: $conversationId) {
        id status assignedAgentId assignedAgentName
      }
    }
    """

    static let subTypingIndicator = """
    subscription CsTypingIndicator($conversationId: ID!) {
      csTypingIndicator(conversationId: $conversationId) {
        conversationId isTyping userName userType
      }
    }
    """

    static let subAssignmentUpdated = """
    subscription CsAssignmentUpdated($conversationId: ID!) {
      csAssignmentUpdated(conversationId: $conversationId) {
        id conversationId status
        assignedAgentId assignedAgentName
        queuePosition estimatedWaitTime
        source handoffReason requestedAt
      }
    }
    """

    static let subHeartbeat = """
    subscription CsHeartbeat {
      csHeartbeat { at seq }
    }
    """

    static let requestPresignedUpload = """
    mutation RequestPresignedUpload($files: [PresignedUploadInput!]!) {
      requestPresignedUpload(files: $files) { fileId uploadUrl }
    }
    """

    static let confirmFileUpload = """
    mutation ConfirmFileUpload($fileId: String!) {
      confirmFileUpload(fileId: $fileId) { fileId publicUrl }
    }
    """
}
