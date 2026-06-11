package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp

// MARK: - WhatsNewSheet (ported from Strand/Screens/WhatsNewView.swift)
//
// A proper in-app changelog, shown automatically after an update and reachable any time
// from Settings. It also restates, up top, what NOOP is and what to expect, so people who
// never open GitHub still understand the experimental footing and the WHOOP 5/MG status.
//
// macOS parity notes:
//  - macOS rendered a fixed 560×640 panel with a header / scroll / footer split and a
//    hairline divider between each region. On phone the panel is presented full-screen
//    (the integration step wraps this in a Dialog/overlay), so we fill the surface and let
//    the body scroll. The header → divider → scroll → divider → "Got it" footer order is
//    preserved exactly, as is the "WHAT TO EXPECT" card then one card per release.
//  - The xmark.circle.fill close glyph maps to Icons.Filled.Close; the borderedProminent
//    "Got it" maps to a Palette.accent Material Button.

@Composable
fun WhatsNewSheet(onClose: () -> Unit) {
    Surface(
        modifier = Modifier.fillMaxSize(),
        color = Palette.surfaceBase,
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            Header(onClose = onClose)
            Hairline()

            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(Metrics.sectionGap),
            ) {
                ExpectationsCard()
                AppChangelog.releases.forEach { release ->
                    ReleaseCard(release)
                }
            }

            Hairline()
            Footer(onClose = onClose)
        }
    }
}

// MARK: - Header ("What's new" + "NOOP <version>" + close X)

@Composable
private fun Header(onClose: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(20.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text("What's new", style = NoopType.title2, color = Palette.textPrimary)
            Text(
                "NOOP ${AppChangelog.CURRENT_VERSION}",
                style = NoopType.caption,
                color = Palette.textTertiary,
            )
        }
        IconButton(onClick = onClose, modifier = Modifier.size(36.dp)) {
            Icon(
                Icons.Filled.Close,
                contentDescription = "Close",
                tint = Palette.textTertiary,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

// MARK: - "WHAT TO EXPECT" card (icon + title + body per expectation)

@Composable
private fun ExpectationsCard() {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Overline("What to expect")
            AppChangelog.expectations.forEach { e ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Icon(
                        e.icon,
                        contentDescription = null,
                        tint = Palette.accent,
                        modifier = Modifier
                            .padding(top = 2.dp)
                            .size(22.dp),
                    )
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(3.dp),
                    ) {
                        Text(e.title, style = NoopType.headline, color = Palette.textPrimary)
                        Text(e.body, style = NoopType.subhead, color = Palette.textSecondary)
                    }
                }
            }
        }
    }
}

// MARK: - Release card (v-badge + title + date, then bulleted items)

@Composable
private fun ReleaseCard(release: AppChangelog.Release) {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                SourceBadge("v${release.version}")
                Text(
                    release.title,
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                Text(release.date, style = NoopType.caption, color = Palette.textTertiary)
            }
            release.items.forEach { item ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Box(
                        modifier = Modifier
                            .padding(top = 7.dp)
                            .size(5.dp)
                            .clip(CircleShape)
                            .background(Palette.accent),
                    )
                    Text(
                        item,
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
    }
}

// MARK: - Footer (primary "Got it" → onClose)

@Composable
private fun Footer(onClose: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
        horizontalArrangement = Arrangement.End,
    ) {
        Button(
            onClick = onClose,
            colors = ButtonDefaults.buttonColors(
                containerColor = Palette.accent,
                contentColor = Palette.surfaceBase,
            ),
        ) {
            Text("Got it", style = NoopType.captionNumber)
        }
    }
}

// MARK: - Hairline divider (mirrors the macOS Divider().overlay(hairline))

@Composable
private fun Hairline() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(Palette.hairline),
    )
}
