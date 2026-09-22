package im.nfc.flutter_nfc_kit

import io.flutter.plugin.common.MethodChannel.Result
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PendingPollControllerTest {
    private class RecordingResult(private val events: MutableList<String>) : Result {
        override fun success(result: Any?) {
            events += "success:$result"
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            events += "error:$errorCode:$errorMessage:$errorDetails"
        }

        override fun notImplemented() {
            events += "notImplemented"
        }
    }

    @Test
    fun finishTakesPendingPollOnce() {
        val controller = PendingPollController<String>()
        controller.begin("poll")

        assertEquals("poll", controller.endCurrent()?.pendingValue)
        assertNull(controller.endCurrent())
    }

    @Test
    fun timeoutTakesMatchingPollOnce() {
        val controller = PendingPollController<String>()
        val operationId = controller.begin("poll")!!

        assertEquals("poll", controller.take(operationId))
        assertNull(controller.take(operationId))
        assertTrue(controller.isActive(operationId))
    }

    @Test
    fun tagDiscoveryTakesMatchingPollOnce() {
        val controller = PendingPollController<String>()
        val operationId = controller.begin("tag")!!

        assertEquals("tag", controller.take(operationId))
        assertNull(controller.take(operationId))
        assertTrue(controller.isActive(operationId))
    }

    @Test
    fun finishAfterTagDiscoveryIsHarmless() {
        val controller = PendingPollController<String>()
        val operationId = controller.begin("tag")!!

        assertEquals("tag", controller.take(operationId))
        assertNull(controller.endCurrent()?.pendingValue)
        assertNull(controller.endCurrent())
    }

    @Test
    fun repeatedFinishIsHarmless() {
        val controller = PendingPollController<String>()
        controller.begin("poll")

        assertEquals("poll", controller.endCurrent()?.pendingValue)
        assertNull(controller.endCurrent())
        assertNull(controller.endCurrent())
    }

    @Test
    fun staleTimeoutCannotTakeNewPoll() {
        val controller = PendingPollController<String>()
        val oldOperationId = controller.begin("old")!!
        assertEquals("old", controller.endCurrent()?.pendingValue)
        val newOperationId = controller.begin("new")!!

        assertNull(controller.end(oldOperationId))
        assertEquals("new", controller.end(newOperationId)?.pendingValue)
    }

    @Test
    fun staleCallbackCannotTakeNewPoll() {
        val controller = PendingPollController<String>()
        val oldOperationId = controller.begin("old")!!
        assertEquals("old", controller.take(oldOperationId))
        assertNull(controller.end(oldOperationId)?.pendingValue)
        val newOperationId = controller.begin("new")!!

        assertNull(controller.take(oldOperationId))
        assertEquals("new", controller.take(newOperationId))
    }

    @Test
    fun activePollRejectsAnotherBegin() {
        val controller = PendingPollController<String>()

        assertTrue(controller.begin("first") != null)
        assertNull(controller.begin("second"))
        assertEquals("first", controller.endCurrent()?.pendingValue)
    }

    @Test
    fun detachTakesActivePoll() {
        val controller = PendingPollController<String>()
        controller.begin("poll")

        assertEquals("poll", controller.endCurrent()?.pendingValue)
        assertNull(controller.endCurrent())
    }

    @Test
    fun successfulPollKeepsSessionActiveUntilFinish() {
        val controller = PendingPollController<String>()
        val operationId = controller.begin("poll")!!

        assertEquals("poll", controller.take(operationId))
        assertNull(controller.begin("new poll"))
        assertNull(controller.endCurrent()?.pendingValue)
        assertTrue(controller.begin("new poll") != null)
    }

    @Test
    fun tagRemovalOnlyClearsMatchingSuppression() {
        val controller = TagRedispatchSuppressionController()
        var onTagRemoved: (() -> Unit)? = null
        assertTrue(controller.install(1L) { listener ->
            onTagRemoved = listener
            true
        })

        assertTrue(controller.isOwnedBy(1L))
        onTagRemoved!!()
        assertTrue(!controller.isOwnedBy(1L))
    }

    @Test
    fun staleTagRemovalCannotClearNewSuppression() {
        val controller = TagRedispatchSuppressionController()
        var oldTagRemoved: (() -> Unit)? = null
        controller.install(1L) { listener ->
            oldTagRemoved = listener
            true
        }
        controller.install(2L) { true }

        oldTagRemoved!!()
        assertTrue(controller.isOwnedBy(2L))
        assertTrue(controller.clear(2L))
    }

    @Test
    fun rejectedIgnoreDoesNotKeepSuppressionOwnership() {
        val controller = TagRedispatchSuppressionController()

        assertTrue(!controller.install(1L) { false })

        assertTrue(!controller.isOwnedBy(1L))
    }

    @Test
    fun engineDetachCanClearSuppressionBookkeeping() {
        val controller = TagRedispatchSuppressionController()
        controller.install(1L) { true }

        controller.clearCurrent()

        assertTrue(!controller.isOwnedBy(1L))
    }

    @Test
    fun finishCompletesPendingPollAsCanceledAfterCleanup() {
        val events = mutableListOf<String>()
        val result = RecordingResult(events)

        completeCancellationAfterCleanup(result) {
            events += "closeTag"
            events += "disableReaderMode"
        }
        events += "finishSuccess"

        assertEquals(
            listOf(
                "closeTag",
                "disableReaderMode",
                "error:409:Session canceled:null",
                "finishSuccess",
            ),
            events,
        )
    }

    @Test
    fun cleanupFailureStillCompletesPendingPollAsCanceledOnce() {
        val events = mutableListOf<String>()
        val result = RecordingResult(events)

        try {
            completeCancellationAfterCleanup(result) {
                events += "cleanup"
                throw IllegalStateException("cleanup failed")
            }
        } catch (_: IllegalStateException) {
            events += "thrown"
        }

        assertEquals(
            listOf(
                "cleanup",
                "error:409:Session canceled:null",
                "thrown",
            ),
            events,
        )
    }

    @Test
    fun timeoutUsesStructured408Error() {
        val events = mutableListOf<String>()

        RecordingResult(events).completeWith(PollErrors.timedOut)

        assertEquals(listOf("error:408:Polling tag timeout:null"), events)
    }

    @Test
    fun concurrentPollUsesStructured429Error() {
        val events = mutableListOf<String>()

        RecordingResult(events).completeWith(PollErrors.alreadyInProgress)

        assertEquals(
            listOf("error:429:Polling operation already in progress:null"),
            events,
        )
    }
}
