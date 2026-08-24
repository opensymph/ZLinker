package org.songsong.zremote

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray

/**
 * Home-screen widget: shows up to three pinned/recent devices and opens
 * the app on tap (`zremote://device/<id>`).
 *
 * Data is written by the Flutter `home_widget` plugin into the default
 * shared preferences under key `devices_json`.
 */
class ZRemoteWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        ids: IntArray
    ) {
        for (id in ids) {
            updateAppWidget(context, manager, id)
        }
    }

    companion object {
        private const val PREFS = "HomeWidgetPreferences"
        private const val KEY = "devices_json"

        fun updateAppWidget(
            context: Context,
            manager: AppWidgetManager,
            appWidgetId: Int
        ) {
            val views = RemoteViews(context.packageName, R.layout.zremote_widget)
            val prefs: SharedPreferences =
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val raw = prefs.getString(KEY, "[]") ?: "[]"
            val devices = try {
                JSONArray(raw)
            } catch (_: Exception) {
                JSONArray()
            }

            val rows = listOf(
                Triple(R.id.device_1, R.id.device_1_label, 0),
                Triple(R.id.device_2, R.id.device_2_label, 1),
                Triple(R.id.device_3, R.id.device_3_label, 2),
            )
            for ((rowId, labelId, index) in rows) {
                if (index < devices.length()) {
                    val obj = devices.getJSONObject(index)
                    val id = obj.optString("id")
                    val label = obj.optString("label", "Device")
                    views.setViewVisibility(rowId, View.VISIBLE)
                    views.setTextViewText(labelId, label)
                    val intent = Intent(context, MainActivity::class.java).apply {
                        action = Intent.ACTION_VIEW
                        data = Uri.parse("zremote://device/$id")
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP
                    }
                    val pending = PendingIntent.getActivity(
                        context,
                        index + 100,
                        intent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )
                    views.setOnClickPendingIntent(rowId, pending)
                } else {
                    views.setViewVisibility(rowId, View.GONE)
                }
            }

            val openApp = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            views.setOnClickPendingIntent(
                R.id.widget_title,
                PendingIntent.getActivity(
                    context,
                    1,
                    openApp,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )

            if (devices.length() == 0) {
                views.setViewVisibility(R.id.device_1, View.VISIBLE)
                views.setTextViewText(R.id.device_1_label, "Add a device in ZRemote")
                views.setOnClickPendingIntent(
                    R.id.device_1,
                    PendingIntent.getActivity(
                        context,
                        2,
                        openApp,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )
                )
            }

            manager.updateAppWidget(appWidgetId, views)
        }
    }
}
