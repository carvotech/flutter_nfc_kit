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
 * Owns the single pending poll result.
 *
 * Calls are confined to the NFC handler thread. A monotonically increasing
 * operation ID prevents callbacks from an older reader session from claiming
 * a newer poll result.
 */
internal class PendingPollController<T> {
    private data class Pending<T>(val operationId: Long, val value: T)

    private var nextOperationId = 0L
    private var pending: Pending<T>? = null

    fun begin(value: T): Long? {
        if (pending != null) return null

        val operationId = ++nextOperationId
        pending = Pending(operationId, value)
        return operationId
    }

    fun take(operationId: Long): T? {
        val current = pending ?: return null
        if (current.operationId != operationId) return null

        pending = null
        return current.value
    }

    fun takeCurrent(): T? {
        val current = pending ?: return null
        pending = null
        return current.value
    }
}
