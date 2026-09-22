package im.nfc.flutter_nfc_kit

import io.flutter.plugin.common.MethodChannel.Result

internal data class PollError(
    val code: String,
    val message: String,
)

internal object PollErrors {
    val canceled = PollError("409", "Session canceled")
    val timedOut = PollError("408", "Polling tag timeout")
    val alreadyInProgress = PollError("429", "Polling operation already in progress")
}

internal fun Result.completeWith(error: PollError) {
    this.error(error.code, error.message, null)
}

/**
 * Preserves the lifecycle contract that native cleanup happens before Dart is
 * allowed to observe cancellation, including when cleanup throws.
 */
internal inline fun completeCancellationAfterCleanup(
    result: Result?,
    cleanup: () -> Unit,
) {
    try {
        cleanup()
    } finally {
        result?.completeWith(PollErrors.canceled)
    }
}

/**
 * Owns the active reader session and its single pending poll result.
 *
 * Calls are confined to the NFC handler thread. A monotonically increasing
 * operation ID prevents callbacks from an older reader session from claiming
 * a newer poll result or ending a newer session. A successful tag callback
 * completes the pending result but leaves the session active for NDEF and
 * transceive operations until finish is called.
 */
internal class PendingPollController<T> {
    internal data class EndedSession<T>(val operationId: Long, val pendingValue: T?)

    private data class Session<T>(
        val operationId: Long,
        var pendingValue: T?,
    )

    private var nextOperationId = 0L
    private var activeSession: Session<T>? = null

    fun begin(value: T): Long? {
        if (activeSession != null) return null

        val operationId = ++nextOperationId
        activeSession = Session(operationId, value)
        return operationId
    }

    fun take(operationId: Long): T? {
        val current = activeSession ?: return null
        if (current.operationId != operationId) return null

        val value = current.pendingValue
        current.pendingValue = null
        return value
    }

    fun isActive(operationId: Long): Boolean =
        activeSession?.operationId == operationId

    fun end(operationId: Long): EndedSession<T>? {
        val current = activeSession ?: return null
        if (current.operationId != operationId) return null

        activeSession = null
        return EndedSession(current.operationId, current.pendingValue)
    }

    fun endCurrent(): EndedSession<T>? {
        val current = activeSession ?: return null
        activeSession = null
        return EndedSession(current.operationId, current.pendingValue)
    }
}

/**
 * Tracks framework-level tag redispatch suppression independently from the
 * active reader session. Replacing ownership lets a new session suppress a
 * different tag without allowing an older removal callback to clear it.
 */
internal class TagRedispatchSuppressionController {
    private var operationId: Long? = null

    fun install(
        operationId: Long,
        installer: (onTagRemoved: () -> Unit) -> Boolean,
    ): Boolean {
        this.operationId = operationId
        val accepted = installer { clear(operationId) }
        if (!accepted) clear(operationId)
        return accepted
    }

    fun clear(operationId: Long): Boolean {
        if (this.operationId != operationId) return false
        this.operationId = null
        return true
    }

    fun clearCurrent() {
        operationId = null
    }

    fun isOwnedBy(operationId: Long): Boolean =
        this.operationId == operationId
}
