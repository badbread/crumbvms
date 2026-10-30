package video.crumb.app.ui.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CameraSwipeTest {
    @Test fun leftSwipeIsNext() = assertEquals(1, cameraSwipeDirection(-400f, 10f, 1080))

    @Test fun rightSwipeIsPrevious() = assertEquals(-1, cameraSwipeDirection(400f, -10f, 1080))

    @Test fun shortDragIgnored() = assertNull(cameraSwipeDirection(-100f, 0f, 1080))

    @Test fun verticalDragIgnored() = assertNull(cameraSwipeDirection(-300f, 400f, 1080))

    @Test fun unmeasuredIgnored() = assertNull(cameraSwipeDirection(-400f, 0f, 0))
}
