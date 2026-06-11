package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// MARK: - Donation addresses (verbatim from the shared contract; do not alter)

private data class CryptoAddress(val symbol: String, val name: String, val address: String)

private val donations = listOf(
    CryptoAddress("BTC", "Bitcoin", "bc1qn2gkl7wslwpws06mvazjn2uu689zlkv7kg3kf5"),
    CryptoAddress("ADA", "Cardano", "addr1qxsju3y0mlke2h6h2g6qgnq4r3jstngtyjxs0nnp5zrv28zv8p5rgzruxyjz33j9k23pffta8z639e2snjdd4vcetfqsn4vwr3"),
    CryptoAddress("ETH", "Ethereum", "0xd64D508b531c4b1297Ca4023C774e0E97aA67B7F"),
    CryptoAddress("XRP", "XRP", "rpvijHi2nVY9WWAJhojsAX5tJmHdmLtFhq"),
)

private data class Attribution(val repo: String, val note: String)

private val attributions = listOf(
    Attribution("my-whoop", "BLE protocol reverse-engineering"),
    Attribution("goose", "historical-data decode + offload format"),
)

/**
 * Support — attribution + optional crypto donations. Never a paywall; the whole app
 * works without it. Ports SupportView.swift, using the Android clipboard manager.
 */
@Composable
fun SupportScreen() {
    val clipboard = LocalClipboardManager.current
    var copied by remember { mutableStateOf<String?>(null) }

    ScreenScaffold(
        title = "Support",
        subtitle = "NOOP is free and always will be. If it's useful to you, you can chip in to help with development and testing costs. Totally optional.",
    ) {
        // Built on.
        NoopCard(padding = 20.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Built on", style = NoopType.headline, color = Palette.textPrimary)
                Text(
                    "This stands on community reverse-engineering. Huge thanks:",
                    style = NoopType.subhead, color = Palette.textSecondary,
                )
                attributions.forEach { a ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("›", style = NoopType.headline, color = Palette.accent)
                        Spacer(Modifier.width(8.dp))
                        Text(a.repo, style = NoopType.mono(12f), color = Palette.textPrimary)
                        Spacer(Modifier.width(6.dp))
                        Text("· ${a.note}", style = NoopType.footnote, color = Palette.textTertiary)
                    }
                }
            }
        }

        // Donate.
        NoopCard(padding = 20.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text("Support the build", style = NoopType.headline, color = Palette.textPrimary)
                Text(
                    "NOOP is free and always will be, nothing is locked. It cost real money and a lot of unpaid hours to build, and there are Windows and iOS builds I want to ship next. If it's useful to you and you want to help with the development and testing costs, even a few quid in crypto genuinely keeps it moving, and honestly it keeps me motivated to keep building.",
                    style = NoopType.subhead, color = Palette.textSecondary,
                )
                Text(
                    "I keep this project anonymous, so crypto is the only way to chip in — no Patreon, no PayPal, no name attached. Quick, global, and private for both of us.",
                    style = NoopType.footnote, color = Palette.accent,
                )
                Column {
                    donations.forEachIndexed { idx, coin ->
                        AddressRow(
                            coin = coin,
                            copied = copied == coin.symbol,
                            onCopy = {
                                clipboard.setText(AnnotatedString(coin.address))
                                copied = coin.symbol
                            },
                        )
                        if (idx < donations.size - 1) {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(1.dp)
                                    .padding(vertical = 6.dp)
                                    .background(Palette.hairline),
                            )
                        }
                    }
                }
            }
        }

        // Contact.
        NoopCard(padding = 18.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Get in touch", style = NoopType.headline, color = Palette.textPrimary)
                Text(
                    "Questions, feedback, bugs — thenoopapp@gmail.com",
                    style = NoopType.subhead, color = Palette.textSecondary,
                )
            }
        }

        // Disclaimer.
        NoopCard(padding = 18.dp) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top) {
                Icon(Icons.Filled.Info, contentDescription = null, tint = Palette.textTertiary)
                Text(
                    "Not affiliated with, endorsed by, or connected to WHOOP. Interoperability software for your own device and data. Not a medical device.",
                    style = NoopType.footnote, color = Palette.textTertiary,
                )
            }
        }
    }
}

@Composable
private fun AddressRow(coin: CryptoAddress, copied: Boolean, onCopy: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            coin.symbol,
            style = NoopType.overline.copy(letterSpacing = 0.5.sp),
            color = Palette.accent,
            modifier = Modifier
                .width(48.dp)
                .clip(shape)
                .background(Palette.accent.copy(alpha = 0.14f))
                .padding(horizontal = 8.dp, vertical = 4.dp),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(coin.name, style = NoopType.caption, color = Palette.textTertiary)
            Text(
                coin.address,
                style = NoopType.mono(12f),
                color = Palette.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconButton(onClick = onCopy) {
            Icon(
                if (copied) Icons.Filled.Check else Icons.Filled.ContentCopy,
                contentDescription = "Copy ${coin.name} address",
                tint = Palette.accent,
            )
        }
    }
}
