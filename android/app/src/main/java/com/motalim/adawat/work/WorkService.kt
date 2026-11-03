package com.motalim.adawat.work

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import com.motalim.adawat.R
import com.motalim.adawat.core.AdawatException
import com.motalim.adawat.core.Catalog
import com.motalim.adawat.core.L10n
import com.motalim.adawat.core.OperationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Runs tools in the foreground with a progress notification, so long jobs such as video finish even after the wheel closes.
 * Results are saved to the shared Adawat folders when the tool is done.
 */
class WorkService : LifecycleService() {
    private val running = mutableMapOf<String, Job>()
    private var lastProgressPost = 0L

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        when (intent?.action) {
            ACTION_CANCEL -> intent.getStringExtra(EXTRA_JOB)?.let { running[it]?.cancel() }
            ACTION_RUN -> {
                val id = intent.getStringExtra(EXTRA_JOB) ?: return START_NOT_STICKY
                val operation = intent.getStringExtra(EXTRA_OPERATION) ?: return START_NOT_STICKY
                val files = intent.getStringArrayExtra(EXTRA_FILES)?.map(::File) ?: return START_NOT_STICKY
                val options = intent.getBundleExtra(EXTRA_OPTIONS)?.let { b -> b.keySet().associateWith { b.getString(it).orEmpty() } }.orEmpty()
                startInForeground(id)
                run(id, operation, files, options)
            }
        }
        if (running.isEmpty()) stopSelf()
        return START_NOT_STICKY
    }

    private fun startInForeground(id: String) {
        val type = if (Build.VERSION.SDK_INT >= 35) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING
                   else ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        startForeground(PROGRESS_ID, progressNotification(Jobs.all.value[id]), type)
    }

    private fun run(id: String, operationId: String, files: List<File>, options: Map<String, String>) {
        val operation = Catalog.find(operationId, files)
        if (operation == null) {
            Jobs.change(id) { it.copy(finished = true, error = L10n.t("This choice no longer fits these files.")) }
            return
        }
        val out = File(cacheDir, "out/$id").apply { mkdirs() }
        running[id] = lifecycleScope.launch {
            val context = OperationContext(
                out,
                options,
                onReport = { text -> Jobs.change(id) { it.copy(status = text) }; postProgress(id) },
                onProgress = { fraction -> Jobs.change(id) { it.copy(progress = fraction) }; postProgress(id) },
            )
            val started = System.currentTimeMillis()
            try {
                val results = withContext(Dispatchers.Default) { operation.run(files, context) }
                android.util.Log.i("Adawat", "$operationId took ${System.currentTimeMillis() - started} ms")
                val saved = withContext(Dispatchers.IO) { results.flatMap { Outputs.saveAll(this@WorkService, it) } }
                Jobs.change(id) { it.copy(finished = true, progress = 1.0, saved = saved, message = context.message, link = context.link) }
                notifyDone(id)
            } catch (e: CancellationException) {
                Jobs.change(id) { it.copy(finished = true, error = L10n.t("Cancelled")) }
            } catch (e: AdawatException) {
                android.util.Log.w("Adawat", "$operationId failed: ${e.message}")
                Jobs.change(id) { it.copy(finished = true, error = e.message) }
                notifyDone(id)
            } catch (e: Throwable) {
                android.util.Log.e("Adawat", "$operationId failed", e)
                Jobs.change(id) { it.copy(finished = true, error = L10n.t("Something went wrong: {1}").replace("{1}", e.message ?: e.javaClass.simpleName)) }
                notifyDone(id)
            } finally {
                out.deleteRecursively()
                // Each wheel runs one job, so its copies of the shared files are done with too.
                files.firstOrNull()?.parentFile?.takeIf { it.parentFile == File(cacheDir, "in") }?.deleteRecursively()
                running.remove(id)
                if (running.isEmpty()) {
                    ServiceCompat.stopForeground(this@WorkService, ServiceCompat.STOP_FOREGROUND_REMOVE)
                    stopSelf()
                } else {
                    postProgress(running.keys.first(), force = true)
                }
            }
        }
    }

    private fun postProgress(id: String, force: Boolean = false) {
        val now = System.currentTimeMillis()
        if (!force && now - lastProgressPost < 400) return
        lastProgressPost = now
        if (ContextCompat.checkSelfPermission(this, android.Manifest.permission.POST_NOTIFICATIONS) == 0 || Build.VERSION.SDK_INT < 33) {
            NotificationManagerCompat.from(this).notify(PROGRESS_ID, progressNotification(Jobs.all.value[id]))
        }
    }

    private fun progressNotification(state: JobState?): Notification {
        channels(this)
        val builder = NotificationCompat.Builder(this, CHANNEL_WORK)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(state?.title ?: L10n.t("Working…"))
            .setContentText(state?.status?.ifEmpty { null } ?: L10n.t("Working…"))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
        val progress = state?.progress
        if (progress == null) builder.setProgress(0, 0, true) else builder.setProgress(1000, (progress * 1000).toInt(), false)
        if (state != null) {
            val cancel = PendingIntent.getService(
                this, state.id.hashCode(),
                Intent(this, WorkService::class.java).setAction(ACTION_CANCEL).putExtra(EXTRA_JOB, state.id),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            builder.addAction(0, L10n.t("Cancel"), cancel)
        }
        return builder.build()
    }

    /** A finished-job notification, for when the wheel is no longer on screen. Tapping it opens the first result. */
    private fun notifyDone(id: String) {
        val state = Jobs.all.value[id] ?: return
        if (state.error == null && WheelVisibility.watching == id) return
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(this, android.Manifest.permission.POST_NOTIFICATIONS) != 0) return
        channels(this)
        val builder = NotificationCompat.Builder(this, CHANNEL_DONE)
            .setSmallIcon(R.drawable.ic_notification)
            .setAutoCancel(true)
            .setContentTitle(state.title)
        if (state.error != null) {
            builder.setContentText(state.error)
        } else {
            val text = state.message ?: if (state.saved.size == 1) L10n.t("Saved {1}").replace("{1}", state.saved[0].name)
                                         else L10n.t("Saved {1} files").replace("{1}", state.saved.size.toString())
            builder.setContentText(text).setSubText(state.saved.firstOrNull()?.folder)
            state.saved.firstOrNull()?.let { first ->
                val view = Intent(Intent.ACTION_VIEW).setDataAndType(first.uri, first.mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                builder.setContentIntent(PendingIntent.getActivity(this, id.hashCode(), Intent.createChooser(view, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                                                                   PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            }
        }
        NotificationManagerCompat.from(this).notify(id.hashCode(), builder.build())
    }

    companion object {
        const val ACTION_RUN = "com.motalim.adawat.RUN"
        const val ACTION_CANCEL = "com.motalim.adawat.CANCEL"
        const val EXTRA_JOB = "job"
        const val EXTRA_OPERATION = "operation"
        const val EXTRA_FILES = "files"
        const val EXTRA_OPTIONS = "options"
        private const val CHANNEL_WORK = "work"
        private const val CHANNEL_DONE = "done"
        private const val PROGRESS_ID = 1

        fun start(context: Context, state: JobState, operationId: String, files: List<File>, options: Map<String, String> = emptyMap()) {
            Jobs.put(state)
            val intent = Intent(context, WorkService::class.java).setAction(ACTION_RUN)
                .putExtra(EXTRA_JOB, state.id).putExtra(EXTRA_OPERATION, operationId)
                .putExtra(EXTRA_FILES, files.map { it.path }.toTypedArray())
                .putExtra(EXTRA_OPTIONS, android.os.Bundle().apply { options.forEach { (k, v) -> putString(k, v) } })
            ContextCompat.startForegroundService(context, intent)
        }

        fun cancel(context: Context, id: String) {
            context.startService(Intent(context, WorkService::class.java).setAction(ACTION_CANCEL).putExtra(EXTRA_JOB, id))
        }

        fun channels(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(CHANNEL_WORK, L10n.t("Working…").trimEnd('…'), NotificationManager.IMPORTANCE_LOW))
            manager.createNotificationChannel(NotificationChannel(CHANNEL_DONE, L10n.t("Done"), NotificationManager.IMPORTANCE_DEFAULT))
        }
    }
}

/** The job the wheel screen is showing, so its own finish card replaces the notification. */
object WheelVisibility {
    @Volatile var watching: String? = null
}
