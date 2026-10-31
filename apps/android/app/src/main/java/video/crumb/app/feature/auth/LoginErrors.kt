// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.auth

import retrofit2.HttpException
import video.crumb.app.data.toUserMessage

/** Which sign-in field an error belongs to (polish pass I4). */
enum class LoginErrorField {
    /** Network and certificate problems: shown on the server address field. */
    SERVER,

    /** A refused username or password: shown on the username field. */
    CREDENTIALS,

    /** Anything else: shown under the Sign in button. */
    GENERAL,
}

/** A sign-in failure with the field it should be attached to. */
data class LoginError(val field: LoginErrorField, val message: String)

/**
 * Sort a sign-in failure onto the field that caused it. A 401 (or 403) from the login
 * call means the credentials were refused; an I/O or TLS failure means the server
 * address could not be used. Anything else has no single owner.
 */
fun classifyLoginError(t: Throwable): LoginError = when {
    t is HttpException && (t.code() == 401 || t.code() == 403) ->
        LoginError(LoginErrorField.CREDENTIALS, "Wrong username or password")
    t is HttpException -> LoginError(LoginErrorField.GENERAL, t.toUserMessage())
    t is java.io.IOException -> LoginError(LoginErrorField.SERVER, t.toUserMessage())
    else -> LoginError(LoginErrorField.GENERAL, t.toUserMessage())
}
