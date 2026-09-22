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

        assertEquals("poll", controller.takeCurrent())
        assertNull(controller.takeCurrent())
    }

    @Test
    fun timeoutTakesMatchingPollOnce() {
        val controller = PendingPollController<String>()
        val operationId = controller.begin("poll")!!

        assertEquals("poll", controller.take(operationId))
        assertNull(controller.take(operationId))
    }

    @Test
    fun tagDiscoveryTakesMatchingPollOnce() {
        val controller = PendingPollController<String>()
        val operationId = controller.begin("tag")!!

        assertEquals("tag", controller.take(operationId))
        assertNull(controller.takeCurrent())
    }

    @Test
    fun finishAfterTagDiscoveryIsHarmless() {
        val controller = PendingPollController<String>()
        val operationId = controller.begin("tag")!!

        assertEquals("tag", controller.take(operationId))
        assertNull(controller.takeCurrent())
    }

    @Test
    fun repeatedFinishIsHarmless() {
        val controller = PendingPollController<String>()
        controller.begin("poll")

        assertEquals("poll", controller.takeCurrent())
        assertNull(controller.takeCurrent())
        assertNull(controller.takeCurrent())
    }

    @Test
    fun staleTimeoutCannotTakeNewPoll() {
        val controller = PendingPollController<String>()
        val oldOperationId = controller.begin("old")!!
        assertEquals("old", controller.takeCurrent())
        val newOperationId = controller.begin("new")!!

        assertNull(controller.take(oldOperationId))
        assertEquals("new", controller.take(newOperationId))
    }

    @Test
    fun staleCallbackCannotTakeNewPoll() {
        val controller = PendingPollController<String>()
        val oldOperationId = controller.begin("old")!!
        assertEquals("old", controller.take(oldOperationId))
        val newOperationId = controller.begin("new")!!

        assertNull(controller.take(oldOperationId))
        assertEquals("new", controller.take(newOperationId))
    }

    @Test
    fun activePollRejectsAnotherBegin() {
        val controller = PendingPollController<String>()

        assertTrue(controller.begin("first") != null)
        assertNull(controller.begin("second"))
        assertEquals("first", controller.takeCurrent())
    }

    @Test
    fun detachTakesActivePoll() {
        val controller = PendingPollController<String>()
        controller.begin("poll")

        assertEquals("poll", controller.takeCurrent())
        assertNull(controller.takeCurrent())
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
