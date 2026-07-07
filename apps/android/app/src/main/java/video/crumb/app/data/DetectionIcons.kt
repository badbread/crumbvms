// SPDX-License-Identifier: AGPL-3.0-or-later

package video.crumb.app.data

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.Eco
import androidx.compose.material.icons.filled.Backpack
import androidx.compose.material.icons.filled.BakeryDining
import androidx.compose.material.icons.filled.Cake
import androidx.compose.material.icons.filled.Chair
import androidx.compose.material.icons.filled.Checkroom
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material.icons.filled.ContentCut
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.Dining
import androidx.compose.material.icons.filled.DirectionsBike
import androidx.compose.material.icons.filled.DirectionsBoat
import androidx.compose.material.icons.filled.DirectionsBus
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.DirectionsWalk
import androidx.compose.material.icons.filled.Face
import androidx.compose.material.icons.filled.Flight
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.Kitchen
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.LocalDining
import androidx.compose.material.icons.filled.LocalDrink
import androidx.compose.material.icons.filled.LocalFlorist
import androidx.compose.material.icons.filled.LocalPizza
import androidx.compose.material.icons.filled.LocalShipping
import androidx.compose.material.icons.filled.Luggage
import androidx.compose.material.icons.filled.LunchDining
import androidx.compose.material.icons.filled.MenuBook
import androidx.compose.material.icons.filled.Microwave
import androidx.compose.material.icons.filled.Mouse
import androidx.compose.material.icons.filled.Pets
import androidx.compose.material.icons.filled.PhoneIphone
import androidx.compose.material.icons.filled.RamenDining
import androidx.compose.material.icons.filled.Restaurant
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.SettingsRemote
import androidx.compose.material.icons.filled.ShoppingBag
import androidx.compose.material.icons.filled.SmartToy
import androidx.compose.material.icons.filled.SportsBaseball
import androidx.compose.material.icons.filled.SportsBasketball
import androidx.compose.material.icons.filled.SportsTennis
import androidx.compose.material.icons.filled.Traffic
import androidx.compose.material.icons.filled.Train
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.filled.TwoWheeler
import androidx.compose.material.icons.filled.Umbrella
import androidx.compose.material.icons.filled.Wash
import androidx.compose.material.icons.filled.Wc
import androidx.compose.material.icons.filled.Weekend
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * Central detection-icon mapping shared by the live wall ([LiveCameraTile]) and
 * the playback timeline ([CenteredTimeline]).
 *
 * The API emits a PER-LABEL `icon_key` (== the normalised label slug — `person`,
 * `car`, `truck`, `bus`, `bicycle`, `cat`, `dog`, `license_plate`, `face`,
 * `package`, …). The desktop + web clients render a bespoke SVG per label;
 * Compose cannot use those raw SVG strings, so each slug is mapped to the
 * closest Material (extended) vector glyph, and to its semantic-group colour
 * (matching the colour taxonomy in `docs/DETECTION-ICONS.md`).
 *
 * Unknown / future labels fall back to a neutral generic marker. Legacy grouped
 * keys (`vehicle` / `animal` / `cycle` / `plate`) from the OLD backend contract
 * are also handled so historical rows still render.
 *
 * NOTE: many COCO labels have no exact Material glyph (zebra, giraffe, broccoli,
 * toothbrush, the individual courier brands, …). Those reuse the best
 * group-level glyph (a generic animal / food / parcel icon) but still get the
 * correct per-group colour, so they read as the right *category* on the
 * timeline. See the task report's `deferred` list for labels that would benefit
 * from a custom per-label vector drawable.
 */
object DetectionIcons {

    /**
     * The complete, distinct set of Material glyphs [icon] can return, plus the
     * generic fallback. The playback timeline pre-creates one `VectorPainter`
     * per entry (a fixed composable-call count) and resolves
     * `key → icon() → painter` at draw time.
     */
    val allIcons: List<ImageVector> = listOf(
        Icons.Default.DirectionsWalk,
        Icons.Default.Face,
        Icons.Default.DirectionsCar,
        Icons.Default.LocalShipping,
        Icons.Default.DirectionsBus,
        Icons.Default.CreditCard,
        Icons.Default.Flight,
        Icons.Default.Train,
        Icons.Default.DirectionsBoat,
        Icons.Default.DirectionsBike,
        Icons.Default.TwoWheeler,
        Icons.Default.Pets,
        Icons.Default.Inventory2,
        Icons.Default.SportsBasketball,
        Icons.Default.Air,
        Icons.Default.SportsBaseball,
        Icons.Default.SportsTennis,
        Icons.Default.LocalDrink,
        Icons.Default.Restaurant,
        Icons.Default.RamenDining,
        Icons.Default.Eco,
        Icons.Default.LunchDining,
        Icons.Default.LocalDining,
        Icons.Default.LocalPizza,
        Icons.Default.BakeryDining,
        Icons.Default.Cake,
        Icons.Default.Chair,
        Icons.Default.Weekend,
        Icons.Default.LocalFlorist,
        Icons.Default.Dining,
        Icons.Default.Wc,
        Icons.Default.Tv,
        Icons.Default.Laptop,
        Icons.Default.Mouse,
        Icons.Default.SettingsRemote,
        Icons.Default.Keyboard,
        Icons.Default.PhoneIphone,
        Icons.Default.Microwave,
        Icons.Default.Kitchen,
        Icons.Default.MenuBook,
        Icons.Default.Schedule,
        Icons.Default.ContentCut,
        Icons.Default.Wash,
        Icons.Default.Backpack,
        Icons.Default.Umbrella,
        Icons.Default.ShoppingBag,
        Icons.Default.Checkroom,
        Icons.Default.Luggage,
        Icons.Default.SmartToy,
        Icons.Default.Traffic,
        Icons.Default.Circle,
    )

    /** Closest Material glyph for a per-label detection [iconKey]. */
    fun icon(iconKey: String): ImageVector = when (iconKey) {
        // people / faces
        "person" -> Icons.Default.DirectionsWalk
        "face" -> Icons.Default.Face

        // road vehicles
        "car" -> Icons.Default.DirectionsCar
        "truck" -> Icons.Default.LocalShipping
        "bus" -> Icons.Default.DirectionsBus
        "license_plate" -> Icons.Default.CreditCard
        // other vehicles
        "airplane" -> Icons.Default.Flight
        "train" -> Icons.Default.Train
        "boat" -> Icons.Default.DirectionsBoat
        // two-wheelers
        "bicycle" -> Icons.Default.DirectionsBike
        "motorcycle" -> Icons.Default.TwoWheeler

        // animals — pet / wild / farm share the paw glyph (per-group colour
        // distinguishes them; no per-species Material glyph exists).
        "cat", "dog", "bird", "horse", "sheep", "cow",
        "elephant", "bear", "zebra", "giraffe",
        "raccoon", "fox", "squirrel", "deer", "rabbit",
        "skunk", "opossum", "possum", "coyote" -> Icons.Default.Pets

        // delivery / couriers — a parcel/shipping glyph; brand identity is
        // carried by the per-courier colour, not a per-brand Material glyph.
        "package" -> Icons.Default.Inventory2
        "amazon", "ups", "fedex", "dhl", "usps", "gls", "dpd", "an_post",
        "nzpost", "purolator", "royal_mail", "postnl", "postnord",
        "canada_post" -> Icons.Default.LocalShipping

        // sports
        "frisbee", "sports_ball" -> Icons.Default.SportsBasketball
        "skis", "snowboard", "skateboard", "surfboard", "kite" -> Icons.Default.Air
        "baseball_bat", "baseball_glove" -> Icons.Default.SportsBaseball
        "tennis_racket" -> Icons.Default.SportsTennis

        // food & drink
        "bottle", "wine_glass", "cup" -> Icons.Default.LocalDrink
        "fork", "knife", "spoon" -> Icons.Default.Restaurant
        "bowl" -> Icons.Default.RamenDining
        "banana", "apple", "orange" -> Icons.Default.Eco
        "sandwich", "hot_dog" -> Icons.Default.LunchDining
        "broccoli", "carrot" -> Icons.Default.LocalDining
        "pizza" -> Icons.Default.LocalPizza
        "donut" -> Icons.Default.BakeryDining
        "cake" -> Icons.Default.Cake

        // household / furniture / appliances / electronics
        "bench", "chair" -> Icons.Default.Chair
        "couch", "bed" -> Icons.Default.Weekend
        "potted_plant", "vase" -> Icons.Default.LocalFlorist
        "dining_table" -> Icons.Default.Dining
        "toilet", "sink" -> Icons.Default.Wc
        "tv" -> Icons.Default.Tv
        "laptop" -> Icons.Default.Laptop
        "mouse" -> Icons.Default.Mouse
        "remote" -> Icons.Default.SettingsRemote
        "keyboard" -> Icons.Default.Keyboard
        "cell_phone" -> Icons.Default.PhoneIphone
        "microwave" -> Icons.Default.Microwave
        "oven", "toaster", "refrigerator" -> Icons.Default.Kitchen
        "book" -> Icons.Default.MenuBook
        "clock" -> Icons.Default.Schedule
        "scissors" -> Icons.Default.ContentCut
        "hair_drier", "toothbrush" -> Icons.Default.Wash

        // personal items
        "backpack" -> Icons.Default.Backpack
        "umbrella" -> Icons.Default.Umbrella
        "handbag" -> Icons.Default.ShoppingBag
        "tie" -> Icons.Default.Checkroom
        "suitcase" -> Icons.Default.Luggage
        "teddy_bear" -> Icons.Default.SmartToy

        // misc street furniture
        "traffic_light", "fire_hydrant", "stop_sign", "parking_meter" ->
            Icons.Default.Traffic

        // ── legacy grouped keys (pre per-label contract) ──
        "vehicle" -> Icons.Default.DirectionsCar
        "animal" -> Icons.Default.Pets
        "cycle" -> Icons.Default.DirectionsBike
        "plate" -> Icons.Default.CreditCard

        // Unknown / future label: a neutral filled dot (matches the desktop/web
        // "generic" grey marker). Deliberately NOT a question-mark glyph.
        else -> Icons.Default.Circle
    }

    /**
     * Semantic-group colour for a per-label detection [iconKey], matching the
     * colour taxonomy. Per-label tint variations from the SVG set are collapsed
     * to the group base hue here (Compose markers are small; the group colour is
     * what reads at a glance).
     */
    fun color(iconKey: String): Color = when (iconKey) {
        "person" -> DetectionColors.person
        "face" -> DetectionColors.face

        "car", "bus", "truck", "license_plate" -> DetectionColors.vehicleRoad
        "airplane", "train", "boat" -> DetectionColors.vehicleOther
        "bicycle", "motorcycle" -> DetectionColors.twoWheeler

        "cat", "dog" -> DetectionColors.animalPet
        "bird", "elephant", "bear", "zebra", "giraffe",
        "raccoon", "fox", "squirrel", "deer", "rabbit",
        "skunk", "opossum", "possum", "coyote" -> DetectionColors.animalWild
        "horse", "sheep", "cow" -> DetectionColors.animalFarm

        "package", "amazon", "ups", "fedex", "dhl", "usps", "gls", "dpd",
        "an_post", "nzpost", "purolator", "royal_mail", "postnl", "postnord",
        "canada_post" -> DetectionColors.delivery

        "frisbee", "skis", "snowboard", "sports_ball", "kite", "baseball_bat",
        "baseball_glove", "skateboard", "surfboard", "tennis_racket" ->
            DetectionColors.sports

        "bottle", "wine_glass", "cup", "fork", "knife", "spoon", "bowl",
        "banana", "apple", "sandwich", "orange", "broccoli", "carrot",
        "hot_dog", "pizza", "donut", "cake" -> DetectionColors.food

        "backpack", "umbrella", "handbag", "tie", "suitcase", "teddy_bear" ->
            DetectionColors.personalItem

        "traffic_light", "fire_hydrant", "stop_sign", "parking_meter" ->
            DetectionColors.misc

        "bench", "chair", "couch", "potted_plant", "bed", "dining_table",
        "toilet", "tv", "laptop", "mouse", "remote", "keyboard", "cell_phone",
        "microwave", "oven", "toaster", "sink", "refrigerator", "book", "clock",
        "vase", "scissors", "hair_drier", "toothbrush" -> DetectionColors.household

        // ── legacy grouped keys ──
        "vehicle" -> DetectionColors.vehicleRoad
        "animal" -> DetectionColors.animalPet
        "cycle" -> DetectionColors.twoWheeler
        "plate" -> DetectionColors.vehicleRoad

        else -> DetectionColors.generic
    }
}

/**
 * Per-semantic-group base hues for detection markers (one hue per group, mirrors
 * the colour taxonomy in `docs/DETECTION-ICONS.md`).
 */
private object DetectionColors {
    val person = Color(0xFF34AADC)
    val face = Color(0xFFAF52DE)
    val vehicleRoad = Color(0xFFFF9500)
    val vehicleOther = Color(0xFFFF6B22)
    val twoWheeler = Color(0xFFFFCC00)
    val animalPet = Color(0xFF34C759)
    val animalWild = Color(0xFF30B0C7)
    val animalFarm = Color(0xFFA8C84A)
    val delivery = Color(0xFFA5825A)
    val sports = Color(0xFF5856D6)
    val food = Color(0xFFFF2D55)
    val household = Color(0xFF64748B)
    val personalItem = Color(0xFFC0A062)
    val misc = Color(0xFF8E8E93)
    val generic = Color(0xFF8E8E93)
}
