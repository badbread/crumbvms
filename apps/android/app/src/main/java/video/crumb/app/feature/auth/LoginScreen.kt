// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.feature.auth

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import video.crumb.app.di.appContainer
import video.crumb.app.ui.HintTooltip
import video.crumb.app.ui.theme.BlueAccent
import video.crumb.app.ui.theme.DangerRed
import video.crumb.app.ui.theme.NavyDeep
import video.crumb.app.ui.theme.NavySurface
import video.crumb.app.ui.theme.TextPrimary
import video.crumb.app.ui.theme.TextSecondary

/**
 * Login screen for Crumb NVR.
 *
 * Displays a centered, branded form with server URL, username, and password
 * fields. Calls [onLoggedIn] exactly once when authentication succeeds.
 *
 * The screen owns no navigation logic — the caller (NavHost) decides where to
 * go after login. The [AuthViewModel] fires a one-shot event that this
 * Composable collects via [LaunchedEffect].
 *
 * @param onLoggedIn Invoked on the main thread after a successful login.
 */
@Composable
fun LoginScreen(onLoggedIn: () -> Unit) {
    val container = appContainer()
    val vm: AuthViewModel = viewModel(
        factory = viewModelFactory {
            initializer { AuthViewModel(container.repository) }
        },
    )

    val uiState by vm.uiState.collectAsStateWithLifecycle()
    val context = LocalContext.current

    // Collect the one-shot success event and forward to the caller.
    LaunchedEffect(Unit) {
        vm.loginSuccess.collect { onLoggedIn() }
    }

    LoginContent(
        uiState = uiState,
        onServerUrlChange = vm::onServerUrlChange,
        onUsernameChange = vm::onUsernameChange,
        onPasswordChange = vm::onPasswordChange,
        onRememberChange = vm::onRememberChange,
        onSignIn = vm::login,
        onDiscover = { vm.discover(context) },
        onSelectDiscovered = vm::selectDiscovered,
        onShowRange = { vm.revealRangeScan(context) },
        onDiscoverRangeChange = vm::onDiscoverRangeChange,
        onScanRange = { vm.scanRange(context) },
    )
}

// ── private stateless content ─────────────────────────────────────────────────

@Composable
private fun LoginContent(
    uiState: AuthUiState,
    onServerUrlChange: (String) -> Unit,
    onUsernameChange: (String) -> Unit,
    onPasswordChange: (String) -> Unit,
    onRememberChange: (Boolean) -> Unit,
    onSignIn: () -> Unit,
    onDiscover: () -> Unit,
    onSelectDiscovered: (String) -> Unit,
    onShowRange: () -> Unit,
    onDiscoverRangeChange: (String) -> Unit,
    onScanRange: () -> Unit,
) {
    var passwordVisible by remember { mutableStateOf(false) }
    val focusManager = LocalFocusManager.current

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(NavyDeep)
            .imePadding(),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .widthIn(max = 400.dp)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 32.dp, vertical = 48.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {

            // ── Brand header ─────────────────────────────────────────────────
            Text(
                text = "Crumb",
                style = MaterialTheme.typography.headlineMedium,
                color = TextPrimary,
                textAlign = TextAlign.Center,
            )
            Spacer(modifier = Modifier.height(6.dp))
            Text(
                text = "Self-hosted video management",
                style = MaterialTheme.typography.bodyMedium,
                color = TextSecondary,
                textAlign = TextAlign.Center,
            )

            Spacer(modifier = Modifier.height(40.dp))

            // ── Server URL field ─────────────────────────────────────────────
            CrumbTextField(
                value = uiState.serverUrl,
                onValueChange = onServerUrlChange,
                label = "Server URL",
                placeholder = "http://192.0.2.10:8080",
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Uri,
                    imeAction = ImeAction.Next,
                ),
                keyboardActions = KeyboardActions(
                    onNext = { focusManager.moveFocus(FocusDirection.Down) },
                ),
                enabled = !uiState.loading,
            )

            // ── Auto-discover server ─────────────────────────────────────────
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (uiState.discovering) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(16.dp),
                        color = BlueAccent,
                        strokeWidth = 2.dp,
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "Scanning network…",
                        style = MaterialTheme.typography.bodySmall,
                        color = TextSecondary,
                    )
                } else {
                    TextButton(onClick = onDiscover, enabled = !uiState.loading) {
                        Text(
                            text = "Find my server",
                            style = MaterialTheme.typography.labelLarge,
                            color = BlueAccent,
                        )
                    }
                }
            }

            if (uiState.discoverMessage != null) {
                Text(
                    text = uiState.discoverMessage,
                    style = MaterialTheme.typography.bodySmall,
                    color = TextSecondary,
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            // Multiple hits → a tappable list; a single hit auto-fills the field.
            if (uiState.discovered.size > 1) {
                Spacer(modifier = Modifier.height(8.dp))
                uiState.discovered.forEach { server ->
                    Text(
                        text = server.url + (server.version?.let { "  ·  v$it" } ?: ""),
                        style = MaterialTheme.typography.bodyMedium,
                        color = TextPrimary,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(enabled = !uiState.loading) { onSelectDiscovered(server.url) }
                            .padding(vertical = 10.dp),
                    )
                }
            }

            // Scan a specific subnet — for a server on a different VLAN than the phone.
            if (!uiState.discovering) {
                if (uiState.showRangeScan) {
                    Spacer(modifier = Modifier.height(8.dp))
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        CrumbTextField(
                            value = uiState.discoverRange,
                            onValueChange = onDiscoverRangeChange,
                            label = "Subnet to scan",
                            placeholder = "198.51.100.0/24",
                            modifier = Modifier.weight(1f),
                            enabled = !uiState.loading,
                            keyboardOptions = KeyboardOptions(
                                keyboardType = KeyboardType.Uri,
                                imeAction = ImeAction.Done,
                            ),
                            keyboardActions = KeyboardActions(onDone = { onScanRange() }),
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        Button(
                            onClick = onScanRange,
                            enabled = !uiState.loading && uiState.discoverRange.isNotBlank(),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = BlueAccent,
                                contentColor = TextPrimary,
                            ),
                        ) {
                            Text("Scan")
                        }
                    }
                } else {
                    TextButton(onClick = onShowRange, enabled = !uiState.loading) {
                        Text(
                            text = "Scan a specific subnet…",
                            style = MaterialTheme.typography.bodySmall,
                            color = TextSecondary,
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(16.dp))

            // ── Username field ───────────────────────────────────────────────
            CrumbTextField(
                value = uiState.username,
                onValueChange = onUsernameChange,
                label = "Username",
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Text,
                    imeAction = ImeAction.Next,
                ),
                keyboardActions = KeyboardActions(
                    onNext = { focusManager.moveFocus(FocusDirection.Down) },
                ),
                enabled = !uiState.loading,
            )

            Spacer(modifier = Modifier.height(16.dp))

            // ── Password field ───────────────────────────────────────────────
            CrumbTextField(
                value = uiState.password,
                onValueChange = onPasswordChange,
                label = "Password",
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Password,
                    imeAction = ImeAction.Done,
                ),
                keyboardActions = KeyboardActions(
                    onDone = {
                        focusManager.clearFocus()
                        onSignIn()
                    },
                ),
                enabled = !uiState.loading,
                visualTransformation = if (passwordVisible) {
                    VisualTransformation.None
                } else {
                    PasswordVisualTransformation()
                },
                trailingIcon = {
                    HintTooltip(if (passwordVisible) "Hide password" else "Show password") {
                        IconButton(onClick = { passwordVisible = !passwordVisible }) {
                            Icon(
                                imageVector = if (passwordVisible) {
                                    Icons.Filled.Visibility
                                } else {
                                    Icons.Filled.VisibilityOff
                                },
                                contentDescription = if (passwordVisible) "Hide password" else "Show password",
                                tint = TextSecondary,
                            )
                        }
                    }
                },
            )

            Spacer(modifier = Modifier.height(20.dp))

            // ── Keep-me-signed-in toggle ──────────────────────────────────────
            // ON by default (save-login). Requests a long-lived token so the
            // session survives restarts and doesn't expire after the default window.
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(
                        indication = null,
                        interactionSource = remember { MutableInteractionSource() },
                        enabled = !uiState.loading,
                    ) { onRememberChange(!uiState.rememberMe) },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    text = "Keep me signed in",
                    style = MaterialTheme.typography.bodyMedium,
                    color = TextPrimary,
                )
                Switch(
                    checked = uiState.rememberMe,
                    onCheckedChange = onRememberChange,
                    enabled = !uiState.loading,
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = TextPrimary,
                        checkedTrackColor = BlueAccent,
                        uncheckedThumbColor = TextSecondary,
                        uncheckedTrackColor = NavySurface,
                    ),
                )
            }

            Spacer(modifier = Modifier.height(24.dp))

            // ── Sign-in button ───────────────────────────────────────────────
            Button(
                onClick = onSignIn,
                enabled = !uiState.loading,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(52.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = BlueAccent,
                    contentColor = TextPrimary,
                    disabledContainerColor = BlueAccent.copy(alpha = 0.4f),
                    disabledContentColor = TextPrimary.copy(alpha = 0.5f),
                ),
            ) {
                if (uiState.loading) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(22.dp),
                        color = TextPrimary,
                        strokeWidth = 2.5.dp,
                    )
                } else {
                    Text(
                        text = "Sign in",
                        style = MaterialTheme.typography.labelLarge,
                    )
                }
            }

            // ── Error message ────────────────────────────────────────────────
            if (uiState.error != null) {
                Spacer(modifier = Modifier.height(20.dp))
                Text(
                    text = uiState.error,
                    style = MaterialTheme.typography.bodyMedium,
                    color = DangerRed,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

// ── shared field component ─────────────────────────────────────────────────────

/**
 * Styled [OutlinedTextField] conforming to the Crumb dark palette.
 *
 * All parameters beyond the basics are optional and match the signature of
 * [OutlinedTextField] — callers that don't need trailing icons or custom
 * transformations simply omit those arguments.
 */
@Composable
private fun CrumbTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    placeholder: String? = null,
    enabled: Boolean = true,
    singleLine: Boolean = true,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    trailingIcon: (@Composable () -> Unit)? = null,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = {
            Text(
                text = label,
                style = MaterialTheme.typography.bodyMedium,
            )
        },
        placeholder = if (placeholder != null) {
            { Text(text = placeholder, color = TextSecondary) }
        } else null,
        trailingIcon = trailingIcon,
        enabled = enabled,
        singleLine = singleLine,
        keyboardOptions = keyboardOptions,
        keyboardActions = keyboardActions,
        visualTransformation = visualTransformation,
        colors = OutlinedTextFieldDefaults.colors(
            focusedContainerColor = NavySurface,
            unfocusedContainerColor = NavySurface,
            disabledContainerColor = NavySurface.copy(alpha = 0.6f),
            focusedBorderColor = BlueAccent,
            unfocusedBorderColor = TextSecondary.copy(alpha = 0.4f),
            disabledBorderColor = TextSecondary.copy(alpha = 0.2f),
            focusedLabelColor = BlueAccent,
            unfocusedLabelColor = TextSecondary,
            focusedTextColor = TextPrimary,
            unfocusedTextColor = TextPrimary,
            cursorColor = BlueAccent,
        ),
        modifier = modifier.fillMaxWidth(),
    )
}
