package com.motalim.adawat

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Switch
import androidx.compose.material3.TextButton
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.motalim.adawat.core.Release
import com.motalim.adawat.core.Updates
import kotlinx.coroutines.launch
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.motalim.adawat.core.Catalog
import com.motalim.adawat.core.L10n
import com.motalim.adawat.core.Settings
import com.motalim.adawat.core.WheelMode
import com.motalim.adawat.ui.AdawatTheme
import com.motalim.adawat.ui.Look
import com.motalim.adawat.wheel.Wheel
import java.io.File

/** The app's own screen: what Adawat does, a way to pick files here, and the language. */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent { AdawatTheme { Home(::openWheel, ::setLanguage) } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    private fun openWheel(uris: List<Uri>) {
        if (uris.isEmpty()) return
        val intent = Intent(this, WheelActivity::class.java)
            .setAction(Intent.ACTION_SEND_MULTIPLE)
            .setType("*/*")
            .putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        // Debug builds pass a tool to run along, for tests driven over adb.
        if (BuildConfig.DEBUG) this.intent.getStringExtra("adawat.test.operation")?.let { intent.putExtra("adawat.test.operation", it) }
        intent.clipData = ClipData.newRawUri(null, uris[0]).apply { uris.drop(1).forEach { addItem(ClipData.Item(it)) } }
        startActivity(intent)
    }

    private fun setLanguage(value: String) {
        Settings.setLanguage(this, value)
        L10n.load(this)
        recreate()
    }
}

@Composable
private fun Home(onFiles: (List<Uri>) -> Unit, onLanguage: (String) -> Unit) {
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { onFiles(it) }
    val sample = remember { Catalog.forMode(WheelMode.Convert, listOf(File("photo.heic"))) }
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        Column(
            Modifier.fillMaxSize().systemBarsPadding().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(L10n.t("Adawat"), style = MaterialTheme.typography.headlineMedium, color = MaterialTheme.colorScheme.onBackground)
            Spacer(Modifier.height(6.dp))
            Text(L10n.t("Share any file to Adawat"), style = MaterialTheme.typography.bodyLarge, color = Look.Muted)
            Spacer(Modifier.height(18.dp))
            Wheel(sample, L10n.upper(L10n.t("Convert")), size = 260.dp, enabled = false, initiallyHovered = 1)
            Spacer(Modifier.height(20.dp))
            Button(onClick = { picker.launch(arrayOf("*/*")) }, modifier = Modifier.fillMaxWidth().height(52.dp), shape = RoundedCornerShape(16.dp)) {
                Text(L10n.t("Choose Files"), fontSize = 16.sp)
            }
            Spacer(Modifier.height(24.dp))
            Step(1, "Share any file to Adawat", "In any app, tap Share and choose Adawat. Or open a file with Adawat.")
            Step(2, "Pick Convert, Tools or Actions", "Tap the label in the middle, or the tabs under the wheel.")
            Step(3, "Tap a petal, or slide your finger to it and let go", "Results are saved in an Adawat folder in Pictures, Movies, Music or Download.")
            Spacer(Modifier.height(12.dp))
            Text(L10n.t("Everything happens on this phone. No file leaves it unless you share it."),
                 style = MaterialTheme.typography.bodySmall, color = Look.Muted)
            Spacer(Modifier.height(24.dp))
            LanguagePicker(onLanguage)
            Spacer(Modifier.height(24.dp))
            UpdateSection()
        }
    }
}

@Composable
private fun Step(number: Int, title: String, body: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.Top) {
        Box(Modifier.size(28.dp).clip(CircleShape).background(Look.AccentSoft), contentAlignment = Alignment.Center) {
            Text(number.toString(), color = Look.Accent, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.width(12.dp))
        Column {
            Text(L10n.t(title), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onBackground)
            Text(L10n.t(body), style = MaterialTheme.typography.bodyMedium, color = Look.Muted)
        }
    }
}

@Composable
private fun LanguagePicker(onLanguage: (String) -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val current = Settings.language(context)
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(L10n.t("Language"), style = MaterialTheme.typography.labelLarge, color = Look.Muted)
        Spacer(Modifier.height(8.dp))
        Row(Modifier.clip(RoundedCornerShape(50)).background(Color(0x14000000)).padding(4.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            listOf("system" to L10n.t("System"), "ar" to "العربية", "en" to "English").forEach { (value, title) ->
                val selected = value == current
                Text(
                    title, color = if (selected) Color.White else MaterialTheme.colorScheme.onBackground, style = MaterialTheme.typography.labelLarge,
                    modifier = Modifier.clip(RoundedCornerShape(50)).background(if (selected) Look.Accent else Color.Transparent)
                        .clickable { onLanguage(value) }.padding(horizontal = 14.dp, vertical = 8.dp),
                )
            }
        }
    }
}


/** Checks GitHub Releases at start (unless turned off) or on request, and offers a newer version with its notes. */
@Composable
private fun UpdateSection() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var automatic by remember { mutableStateOf(Settings.checkForUpdates(context)) }
    var release by remember { mutableStateOf<Release?>(null) }
    var progress by remember { mutableStateOf<Float?>(null) }
    var status by remember { mutableStateOf("") }

    fun check(quiet: Boolean) = scope.launch {
        if (!quiet) status = L10n.t("Checking for updates…")
        status = try {
            val found = Updates.latest()
            if (found != null && !(quiet && found.version == Settings.skippedVersion(context))) release = found
            if (found != null || quiet) "" else L10n.t("Adawat ${Updates.current} is the latest version")
        } catch (e: Exception) {
            if (quiet) "" else L10n.t("Could not check for updates. Check your internet connection.")
        }
    }
    LaunchedEffect(Unit) { if (automatic) check(quiet = true) }

    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(L10n.t("Check for updates when Adawat starts"), Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onBackground)
            Switch(automatic, { automatic = it; Settings.setCheckForUpdates(context, it) })
        }
        TextButton(onClick = { check(quiet = false) }) { Text(L10n.t("Check for Updates…")) }
        if (status.isNotEmpty()) Text(status, style = MaterialTheme.typography.bodySmall, color = Look.Muted)
    }

    val shown = release ?: return
    AlertDialog(
        onDismissRequest = { if (progress == null) release = null },
        title = { Text(L10n.t("Update Adawat")) },
        text = {
            Column {
                Text(L10n.t("Adawat ${shown.version} is available. You have ${Updates.current}."), fontWeight = FontWeight.SemiBold)
                Text(L10n.t("Your settings and files stay as they are."), style = MaterialTheme.typography.bodySmall, color = Look.Muted)
                if (shown.notes.isNotEmpty()) {
                    Spacer(Modifier.height(12.dp))
                    Text(L10n.t("What's new"), style = MaterialTheme.typography.labelLarge, color = Look.Muted)
                    Text(shown.notes, Modifier.heightIn(max = 240.dp).verticalScroll(rememberScrollState()), style = MaterialTheme.typography.bodySmall)
                }
                progress?.let { fraction ->
                    Spacer(Modifier.height(12.dp))
                    LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth())
                }
            }
        },
        confirmButton = {
            TextButton(enabled = progress == null, onClick = {
                scope.launch {
                    progress = 0f
                    try {
                        val apk = Updates.download(context, shown) { progress = it }
                        release = null
                        Updates.install(context, apk)
                    } catch (e: Exception) {
                        release = null
                        status = L10n.t(if (e is Updates.DamagedDownload) e.message!! else "Could not download the update. Check your internet connection.")
                    } finally {
                        progress = null
                    }
                }
            }) { Text(L10n.t("Update Now")) }
        },
        dismissButton = {
            Row {
                TextButton(enabled = progress == null, onClick = { Settings.setSkippedVersion(context, shown.version); release = null }) { Text(L10n.t("Skip This Version")) }
                TextButton(enabled = progress == null, onClick = { release = null }) { Text(L10n.t("Later")) }
            }
        },
    )
}
