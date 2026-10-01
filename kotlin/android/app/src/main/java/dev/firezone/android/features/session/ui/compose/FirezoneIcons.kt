// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.dp

// Material Symbols Rounded (https://fonts.google.com/icons), path data copied verbatim.
object FirezoneIcons {
    val ChevronRight: ImageVector by lazy {
        materialSymbol(
            name = "ChevronRight",
            autoMirror = true,
            pathData =
                "M504,480L348,324Q337,313 337,296Q337,279 348,268Q359,257 376,257Q393,257 404,268L588,452Q594,458 596.5,465" +
                    "Q599,472 599,480Q599,488 596.5,495Q594,502 588,508L404,692Q393,703 376,703Q359,703 348,692Q337,681 337,664" +
                    "Q337,647 348,636L504,480Z",
        )
    }

    val Devices: ImageVector by lazy {
        materialSymbol(
            name = "Devices",
            pathData =
                "M140,800Q115,800 97.5,782.5Q80,765 80,740Q80,715 97.5,697.5Q115,680 140,680L160,680L160,240Q160,207 183.5,183.5" +
                    "Q207,160 240,160L800,160Q817,160 828.5,171.5Q840,183 840,200Q840,217 828.5,228.5Q817,240 800,240L240,240" +
                    "Q240,240 240,240Q240,240 240,240L240,680L420,680Q445,680 462.5,697.5Q480,715 480,740Q480,765 462.5,782.5" +
                    "Q445,800 420,800L140,800ZM600,800Q583,800 571.5,788.5Q560,777 560,760L560,360Q560,343 571.5,331.5Q583,320 600,320" +
                    "L840,320Q857,320 868.5,331.5Q880,343 880,360L880,760Q880,777 868.5,788.5Q857,800 840,800L600,800Z" +
                    "M640,680L800,680L800,400L640,400L640,680ZM640,680L640,680L800,680L800,680L640,680Z",
        )
    }
}

private fun materialSymbol(
    name: String,
    pathData: String,
    autoMirror: Boolean = false,
): ImageVector =
    ImageVector
        .Builder(
            name = name,
            defaultWidth = 24.dp,
            defaultHeight = 24.dp,
            viewportWidth = 960f,
            viewportHeight = 960f,
            autoMirror = autoMirror,
        ).addPath(pathData = addPathNodes(pathData), fill = SolidColor(Color.Black))
        .build()
