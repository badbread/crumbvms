// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.auth

import java.io.IOException
import javax.net.ssl.SSLHandshakeException
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Test
import retrofit2.HttpException
import retrofit2.Response

class LoginErrorsTest {
    private fun http(code: Int) = HttpException(Response.error<Any>(code, "".toResponseBody(null)))

    @Test
    fun `refused credentials attach to the username field`() {
        val e = classifyLoginError(http(401))
        assertEquals(LoginErrorField.CREDENTIALS, e.field)
        assertEquals("Wrong username or password", e.message)
    }

    @Test
    fun `network and certificate failures attach to the server field`() {
        assertEquals(LoginErrorField.SERVER, classifyLoginError(IOException("boom")).field)
        assertEquals(LoginErrorField.SERVER, classifyLoginError(SSLHandshakeException("x")).field)
    }

    @Test
    fun `server errors and unknowns have no field owner`() {
        assertEquals(LoginErrorField.GENERAL, classifyLoginError(http(500)).field)
        assertEquals(LoginErrorField.GENERAL, classifyLoginError(IllegalStateException("x")).field)
    }
}
