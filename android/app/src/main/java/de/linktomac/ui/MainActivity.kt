package de.linktomac.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.LinkOff
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import de.linktomac.LinkHub
import de.linktomac.LinkService
import de.linktomac.Prefs
import de.linktomac.R
import de.linktomac.net.MsgType
import de.linktomac.pairing.PairingManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    private val resumeTick = mutableIntStateOf(0)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        LinkService.start(this)
        setContent { LinkTheme { App(resumeTick.intValue) } }
    }

    override fun onResume() {
        super.onResume()
        resumeTick.intValue++
    }
}

private enum class Screen { HOME, SCAN, PERMISSIONS }

@Composable
private fun App(tick: Int) {
    val ctx = LocalContext.current
    val prefs = remember { Prefs(ctx) }
    var paired by remember { mutableStateOf(prefs.isPaired) }
    var screen by remember { mutableStateOf(Screen.HOME) }
    val state by LinkHub.state.collectAsState()
    LaunchedEffect(tick, state) { paired = prefs.isPaired }

    when {
        screen == Screen.SCAN -> ScanScreen(
            onBack = { screen = Screen.HOME },
            onPaired = {
                paired = true
                LinkService.start(ctx)
                screen = if (prefs.onboardingDone) Screen.HOME else Screen.PERMISSIONS
            },
        )
        screen == Screen.PERMISSIONS -> PermissionsScreen(tick) {
            prefs.onboardingDone = true
            LinkService.start(ctx)
            screen = Screen.HOME
        }
        !paired -> WelcomeScreen(onPair = { screen = Screen.SCAN }, onPermissions = { screen = Screen.PERMISSIONS })
        else -> ConnectedScreen(
            state = state,
            onPermissions = { screen = Screen.PERMISSIONS },
            onUnpaired = { paired = false },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SimpleScaffold(title: String, onBack: (() -> Unit)?, content: @Composable () -> Unit) {
    Scaffold(topBar = {
        TopAppBar(
            title = { Text(title) },
            navigationIcon = {
                if (onBack != null) {
                    IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back)) }
                }
            },
        )
    }) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) { content() }
    }
}

@Composable
private fun WelcomeScreen(onPair: () -> Unit, onPermissions: () -> Unit) {
    SimpleScaffold(stringResource(R.string.app_name), null) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Icon(Icons.Default.Laptop, null, Modifier.size(72.dp), tint = MaterialTheme.colorScheme.primary)
            Text(stringResource(R.string.welcome_title), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
            Text(stringResource(R.string.welcome_text))
            Text(stringResource(R.string.welcome_steps), style = MaterialTheme.typography.bodyMedium)
            Button(onClick = onPair, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Default.QrCodeScanner, null)
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.welcome_pair))
            }
            OutlinedButton(onClick = onPermissions, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.permissions))
            }
        }
    }
}

@Composable
private fun ScanScreen(onBack: () -> Unit, onPaired: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var hasCamera by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(ctx, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { hasCamera = it }
    LaunchedEffect(Unit) { if (!hasCamera) launcher.launch(Manifest.permission.CAMERA) }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val pairing = remember { PairingManager(ctx) }
    val invalidQr = stringResource(R.string.scan_invalid)

    SimpleScaffold(stringResource(R.string.scan_title), onBack) {
        Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(stringResource(R.string.scan_hint))
            if (hasCamera) {
                QrScanner(
                    Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(16.dp)),
                ) { raw ->
                    if (busy) return@QrScanner
                    val qr = pairing.parseQr(raw)
                    if (qr == null) {
                        message = invalidQr
                        return@QrScanner
                    }
                    busy = true
                    message = null
                    scope.launch {
                        val result = withContext(Dispatchers.IO) { pairing.pair(qr) }
                        busy = false
                        when (result) {
                            is PairingManager.Result.Success -> onPaired()
                            is PairingManager.Result.Rejected -> message = ctx.getString(R.string.scan_rejected)
                            is PairingManager.Result.Failed -> message = ctx.getString(R.string.scan_failed, result.message)
                        }
                    }
                }
            } else {
                Text(stringResource(R.string.scan_camera_needed))
                Button(onClick = { launcher.launch(Manifest.permission.CAMERA) }) { Text(stringResource(R.string.grant)) }
            }
            message?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }
    if (busy) {
        AlertDialog(
            onDismissRequest = {},
            confirmButton = {},
            icon = { CircularProgressIndicator() },
            title = { Text(stringResource(R.string.scan_confirm_on_mac)) },
            text = { Text(stringResource(R.string.scan_confirm_on_mac_text)) },
        )
    }
}

@Composable
private fun PermissionsScreen(tick: Int, onDone: () -> Unit) {
    val ctx = LocalContext.current
    var refresh by remember { mutableIntStateOf(0) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { refresh++ }
    val items = remember { PermissionCatalog.all() }

    SimpleScaffold(stringResource(R.string.permissions), onDone) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(stringResource(R.string.perm_intro))
            // Read tick/refresh so the list re-evaluates after returning from settings.
            val key = tick + refresh
            items.forEach { item ->
                val granted = remember(key) { item.isGranted(ctx) }
                Card(colors = CardDefaults.cardColors()) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                if (granted) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked,
                                null,
                                tint = if (granted) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline,
                            )
                            Spacer(Modifier.width(12.dp))
                            Text(stringResource(item.title), style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                        }
                        Text(stringResource(item.explanation), style = MaterialTheme.typography.bodyMedium)
                        if (!granted) {
                            FilledTonalButton(onClick = {
                                if (item.runtime.isNotEmpty()) {
                                    launcher.launch(item.runtime.toTypedArray())
                                } else {
                                    item.special?.let { mk ->
                                        try {
                                            ctx.startActivity(mk(ctx))
                                        } catch (_: Exception) {
                                            ctx.startActivity(PermissionCatalog.appDetails(ctx))
                                        }
                                    }
                                }
                            }) { Text(stringResource(R.string.grant)) }
                        }
                    }
                }
            }
            if (Build.VERSION.SDK_INT >= 33) {
                Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Security, null)
                            Spacer(Modifier.width(12.dp))
                            Text(stringResource(R.string.perm_restricted_title), style = MaterialTheme.typography.titleMedium)
                        }
                        Text(stringResource(R.string.perm_restricted_text))
                        OutlinedButton(onClick = { ctx.startActivity(PermissionCatalog.appDetails(ctx)) }) {
                            Text(stringResource(R.string.perm_open_app_info))
                        }
                    }
                }
            }
            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.perm_samsung_title), style = MaterialTheme.typography.titleMedium)
                    Text(stringResource(R.string.perm_samsung_text))
                }
            }
            Button(onClick = onDone, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.done)) }
        }
    }
}

@Composable
private fun ConnectedScreen(state: LinkHub.State, onPermissions: () -> Unit, onUnpaired: () -> Unit) {
    val ctx = LocalContext.current
    val prefs = remember { Prefs(ctx) }
    var confirmUnpair by remember { mutableStateOf(false) }
    val macName = prefs.macName ?: "Mac"

    SimpleScaffold(stringResource(R.string.app_name), null) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Card(
                colors = CardDefaults.cardColors(
                    containerColor = if (state == LinkHub.State.CONNECTED) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceVariant,
                ),
            ) {
                Row(Modifier.padding(20.dp).fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.Laptop, null, Modifier.size(40.dp))
                    Spacer(Modifier.width(16.dp))
                    Column {
                        Text(macName, style = MaterialTheme.typography.titleLarge)
                        Text(
                            stringResource(
                                when (state) {
                                    LinkHub.State.CONNECTED -> R.string.state_connected
                                    LinkHub.State.WAITING -> R.string.state_waiting
                                    LinkHub.State.STOPPED -> R.string.state_stopped
                                },
                            ),
                        )
                    }
                }
            }
            if (state == LinkHub.State.STOPPED) {
                Button(onClick = { LinkService.start(ctx) }, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Default.Sync, null)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.start_service))
                }
            }
            FilledTonalButton(
                onClick = { ctx.startActivity(Intent(ctx, de.linktomac.features.ClipboardSendActivity::class.java)) },
                enabled = state == LinkHub.State.CONNECTED,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Default.ContentPaste, null)
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.send_clipboard))
            }

            Text(stringResource(R.string.features), style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 8.dp))
            Card {
                Column(Modifier.padding(vertical = 4.dp)) {
                    featureLabels().forEachIndexed { i, (key, label) ->
                        var on by remember { mutableStateOf(prefs.feature(key)) }
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(stringResource(label), modifier = Modifier.weight(1f))
                            Switch(checked = on, onCheckedChange = {
                                on = it
                                prefs.setFeature(key, it)
                            })
                        }
                        if (i < Prefs.FEATURES.size - 1) HorizontalDivider()
                    }
                }
            }
            OutlinedButton(onClick = onPermissions, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.permissions)) }
            TextButton(onClick = { confirmUnpair = true }, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Default.LinkOff, null)
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.unpair), color = MaterialTheme.colorScheme.error)
            }
            Spacer(Modifier.height(24.dp))
        }
    }
    if (confirmUnpair) {
        AlertDialog(
            onDismissRequest = { confirmUnpair = false },
            title = { Text(stringResource(R.string.unpair_confirm_title)) },
            text = { Text(stringResource(R.string.unpair_confirm_text, macName)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmUnpair = false
                    LinkHub.send(de.linktomac.net.Envelope.empty(MsgType.UNPAIR))
                    prefs.clearPairing()
                    PairingManager(ctx).resetIdentity()
                    LinkService.stop(ctx)
                    onUnpaired()
                }) { Text(stringResource(R.string.unpair)) }
            },
            dismissButton = { TextButton(onClick = { confirmUnpair = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

private fun featureLabels() = listOf(
    "notifications" to R.string.feature_notifications,
    "sms" to R.string.feature_sms,
    "calls" to R.string.feature_calls,
    "photos" to R.string.feature_photos,
    "files" to R.string.feature_files,
    "clipboard" to R.string.feature_clipboard,
    "mirror" to R.string.feature_mirror,
    "media" to R.string.feature_media,
)
