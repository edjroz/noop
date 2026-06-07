package com.noop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.ble.LiveState
import com.noop.data.DailyMetric
import kotlin.math.roundToInt

// MARK: - Health Monitor (ported from Strand/Screens/HealthView.swift)
//
// Live heart-rate hero (streaming HR + HR-zone read-out, derived from the strap's
// R-R stream when the HR field reads 0), then a uniform grid of the body's vital
// signs (respiratory rate, blood O2, resting HR, HRV, skin temp) as fixed-height
// StatTiles, each tinted and captioned with its in-range state. Re-skinned to the
// locked NOOP component system: every surface is a NoopCard/StatTile, every chart
// is a Canvas chart — no ad-hoc card heights or paddings.
//
// macOS parity note: macOS read HR-max from a ProfileStore. There is no profile
// store on Android yet, so we use a fixed age-agnostic default (220 - 30 = 190 bpm).
// SpO2 / respiratory / skin-temp are sleep-window aggregates, so the "Vital Signs"
// grid is sourced from the most recent imported DailyMetric, exactly as on macOS.

private const val HR_MAX_DEFAULT = 190

@Composable
fun HealthScreen(vm: AppViewModel) {
    val live by vm.live.collectAsStateWithLifecycle()
    val today by vm.today.collectAsStateWithLifecycle()

    val displayHr = displayHr(live)
    val hasLiveHr = displayHr != null

    ScreenScaffold(
        title = "Health Monitor",
        subtitle = "Live vitals, streamed from the strap.",
    ) {
        if (today == null && !hasLiveHr) {
            HealthEmptyState()
        } else {
            // ScreenScaffold applies a 20dp arrangement gap between its direct children;
            // a small top-up reaches the section gap (28dp) used between macOS sections.
            HeartRateSection(live = live)
            Spacer(Modifier.height(Metrics.sectionGap - 20.dp))
            VitalsSection(today = today)
        }
    }
}

// MARK: - Derived live HR
//
// HR to display: the reported value when > 0, else derived from the latest R-R
// interval in milliseconds (the strap streams R-R even when its HR field reads 0).

private fun displayHr(live: LiveState): Int? {
    live.heartRate?.let { if (it > 0) return it }
    val lastRr = live.rr.lastOrNull()
    if (lastRr != null && lastRr > 0) return (60_000.0 / lastRr).roundToInt()
    return null
}

private fun hrIsDerived(live: LiveState): Boolean =
    (live.heartRate ?: 0) <= 0 && live.rr.isNotEmpty()

/** HR as a fraction of HR-max (0..1). */
private fun hrFraction(hr: Int?): Double {
    if (hr == null || HR_MAX_DEFAULT <= 0) return 0.0
    return (hr.toDouble() / HR_MAX_DEFAULT).coerceIn(0.0, 1.0)
}

/** Current zone 1..5 from %HR-max (WHOOP/Karvonen-style bands: 50/60/70/80/90). */
private fun hrZone(fraction: Double): Int = when {
    fraction < 0.60 -> 1
    fraction < 0.70 -> 2
    fraction < 0.80 -> 3
    fraction < 0.90 -> 4
    else -> 5
}

/** A short HR series for the hero chart, derived from streamed R-R intervals (newest
 *  last). Falls back to a flat pair at the current HR when R-R is sparse. */
private fun hrSeries(live: LiveState, hr: Int?): List<Double> {
    val beats = live.rr.takeLast(60).mapNotNull { rr ->
        if (rr > 0) 60_000.0 / rr else null
    }
    if (beats.size > 1) return beats
    if (hr != null) return listOf(hr.toDouble(), hr.toDouble())
    return emptyList()
}

// MARK: - Heart rate hero (live)

@Composable
private fun HeartRateSection(live: LiveState) {
    val displayHr = displayHr(live)
    val hasLiveHr = displayHr != null
    val derived = hrIsDerived(live)
    val fraction = hrFraction(displayHr)
    val zone = hrZone(fraction)
    val series = hrSeries(live, displayHr)
    val zoneColor = Palette.hrZoneColor(zone)

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(
            title = "Heart Rate",
            overline = "Live",
            trailing = if (derived) "from R-R" else null,
        )

        NoopCard(padding = 18.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                // Card header: title + subtitle on the left, live bpm read-out right.
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.Top,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Heart Rate", style = NoopType.headline, color = Palette.textPrimary)
                        Text(
                            text = when {
                                derived -> "Estimated from R-R interval"
                                hasLiveHr -> "Streaming live"
                                else -> "Awaiting strap"
                            },
                            style = NoopType.footnote,
                            color = Palette.textSecondary,
                        )
                    }
                    Text(
                        text = if (hasLiveHr) "$displayHr bpm" else "—",
                        style = NoopType.number(15f),
                        color = if (hasLiveHr) zoneColor else Palette.textTertiary,
                    )
                }

                // Hero chart: a tall HR line tinted to the current zone, with a status
                // pill floated top-trailing. Falls back to a big number when R-R is sparse.
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(Metrics.chartHeight),
                ) {
                    if (series.size > 1) {
                        LineChart(
                            values = series,
                            modifier = Modifier.fillMaxWidth().height(Metrics.chartHeight),
                            color = zoneColor,
                            fill = true,
                        )
                    } else {
                        Column(
                            modifier = Modifier.fillMaxWidth().height(Metrics.chartHeight),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center,
                        ) {
                            Text(
                                text = displayHr?.toString() ?: "—",
                                style = NoopType.display(72f),
                                color = if (hasLiveHr) zoneColor else Palette.textTertiary,
                            )
                            Text("bpm", style = NoopType.subhead, color = Palette.textTertiary)
                        }
                    }

                    StatePill(
                        title = zoneLabel(hasLiveHr, zone, fraction),
                        tone = if (hasLiveHr) StrandTone.Accent else StrandTone.Neutral,
                        showsDot = hasLiveHr,
                        pulsing = hasLiveHr,
                        modifier = Modifier.align(Alignment.TopEnd),
                    )
                }

                // Footer read-out row: Zone · % Max · Max HR · State.
                HeartRateFooter(
                    zone = if (hasLiveHr) "Z$zone" else "—",
                    percentMax = if (hasLiveHr) "${(fraction * 100).roundToInt()}%" else "—",
                    maxHr = "$HR_MAX_DEFAULT",
                    state = if (hasLiveHr) "STREAMING" else "IDLE",
                )
            }
        }
    }
}

private fun zoneLabel(hasLiveHr: Boolean, zone: Int, fraction: Double): String {
    if (!hasLiveHr) return "Idle"
    return "Zone $zone · ${(fraction * 100).roundToInt()}%"
}

@Composable
private fun HeartRateFooter(zone: String, percentMax: String, maxHr: String, state: String) {
    Row(modifier = Modifier.fillMaxWidth().padding(top = 4.dp)) {
        FooterStat("Zone", zone, Modifier.weight(1f))
        FooterStat("% Max", percentMax, Modifier.weight(1f))
        FooterStat("Max HR", maxHr, Modifier.weight(1f))
        FooterStat("State", state, Modifier.weight(1f))
    }
}

@Composable
private fun FooterStat(label: String, value: String, modifier: Modifier = Modifier) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Overline(label)
        Text(value, style = NoopType.captionNumber, color = Palette.textPrimary)
    }
}

// MARK: - Vitals grid (uniform StatTiles)

@Composable
private fun VitalsSection(today: DailyMetric?) {
    val vitals = vitalsFor(today)
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(
            title = "Vital Signs",
            overline = "Today",
            trailing = today?.day?.let { "as of $it" },
        )

        // A uniform 2-column grid of fixed-height tiles. The macOS LazyVGrid is
        // adaptive(min: 168); on phones two columns is the faithful equivalent.
        vitals.chunked(2).forEach { rowVitals ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(Metrics.gap),
            ) {
                rowVitals.forEach { v ->
                    StatTile(
                        modifier = Modifier
                            .weight(1f)
                            .semantics { contentDescription = v.accessibilityText },
                        label = v.label,
                        value = v.formattedValue ?: "—",
                        caption = v.stateCaption,
                        accent = v.accent,
                    )
                }
                // Pad an odd final row so the tile keeps half-width, matching the grid.
                if (rowVitals.size == 1) Spacer(Modifier.weight(1f))
            }
        }

        Text(
            text = "SpO₂, respiratory rate and skin temperature are sleep-window " +
                "aggregates from your most recent imported day; resting HR and HRV update daily.",
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
    }
}

// MARK: - Vital model

private data class Vital(
    val key: String,
    val label: String,
    val unit: String,
    val value: Double?,
    val format: (Double) -> String,
    /** Healthy range used to compute the in-range state (inclusive). */
    val inRange: ClosedFloatingPointRange<Double>,
    /** The metric's category colour (used only when in range). */
    val metricColor: Color,
) {
    val isInRange: Boolean = value?.let { inRange.contains(it) } ?: false

    /** Value with its unit appended, or null when no data. */
    val formattedValue: String? = value?.let { "${format(it)} $unit" }

    /** Colour communicates state: in-range = the metric's category colour,
     *  out-of-range = warning amber, no data = tertiary. */
    val accent: Color = when {
        value == null -> Palette.textTertiary
        isInRange -> metricColor
        else -> Palette.statusWarning
    }

    /** The textual in-range caption that stands in for a StatePill inside the
     *  fixed-height tile (keeps the row pixel-uniform). */
    val stateCaption: String = when {
        value == null -> "No data"
        isInRange -> "In range"
        else -> "Out of range"
    }

    val accessibilityText: String =
        formattedValue?.let { "$label: $it, ${if (isInRange) "in range" else "out of range"}" }
            ?: "$label: no data"
}

private fun vitalsFor(d: DailyMetric?): List<Vital> = listOf(
    Vital(
        key = "resp", label = "Resp Rate", unit = "rpm",
        value = d?.respRateBpm, format = { String.format("%.1f", it) },
        inRange = 12.0..20.0, metricColor = Palette.metricCyan,
    ),
    Vital(
        key = "spo2", label = "Blood O₂", unit = "%",
        value = d?.spo2Pct, format = { String.format("%.0f", it) },
        inRange = 95.0..100.0, metricColor = Palette.metricCyan,
    ),
    Vital(
        key = "rhr", label = "Resting HR", unit = "bpm",
        value = d?.restingHr?.toDouble(), format = { it.roundToInt().toString() },
        inRange = 40.0..60.0, metricColor = Palette.metricRose,
    ),
    Vital(
        key = "hrv", label = "HRV", unit = "ms",
        value = d?.avgHrv, format = { it.roundToInt().toString() },
        inRange = 40.0..120.0, metricColor = Palette.metricPurple,
    ),
    Vital(
        key = "skin", label = "Skin Temp", unit = "°C",
        value = d?.skinTempDevC, format = { String.format("%.1f", it) },
        inRange = 33.0..36.0, metricColor = Palette.metricAmber,
    ),
)

// MARK: - Empty state

@Composable
private fun HealthEmptyState() {
    DataPendingNote(
        title = "No biometrics yet",
        body = "No biometrics yet. Import your WHOOP export (and Apple Health if you " +
            "have it) in Data Sources to fill this in.",
    )
}
