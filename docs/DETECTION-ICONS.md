# Detection Icons, canonical reference

> Source of truth for the Frigate/COCO detection icon set rendered on the
> Crumb timeline + live wall. Generated set; if you change a glyph, change it
> here and propagate to every client map listed under **How clients consume it**.

## Contract

The API emits a **per-label** `icon_key` on every `/events` row (see
`services/common/src/detection.rs`). `icon_key` equals the normalised label
slug, `car`, `truck`, `bus`, `bicycle`, `cat`, `dog`, `license_plate`,
`face`, `package`, …, so each distinct label can get its own glyph and
colour. (Earlier the backend *collapsed* `car/truck/bus → vehicle`,
`cat/dog/bird/horse → animal`, `bicycle/motorcycle → cycle`,
`license_plate → plate`; those four collapsed keys are retained by clients as
**legacy aliases** so rows ingested under the old contract still render.)

The canonical key for a number plate is **`license_plate`** (the
`licence_plate` / `plate` aliases all normalise to it).

## How clients consume it

Each client keeps a map `icon_key -> { glyph, colour }`. The lookup is:

1. Look up the row's `icon_key` in the map.
2. If absent (an unknown label / future class), fall back to the **`generic`**
   entry, a neutral grey dot. No row is ever dropped for an unknown label.

Per-client maps (keep in sync with the table below):

- **Desktop** (Flutter): `apps/desktop-flutter/lib/ui/live_status/detection_icons.dart`,
  `kDetectionIcons`, a curated Material-Icons mapping (icon + colour per
  `icon_key`) with a `kGenericDetectionIcon` fallback, rather than the raw
  inline-SVG set the retired Tauri client carried.
- **Web admin console**: `services/api/src/admin.html`, the inline timeline
  renderer's icon map (colour + shape per semantic group).
- **Android** (Compose): `apps/android/.../data/Models.kt` —
  `detectionIconFor(iconKey)` maps the slug to a Compose vector/drawn glyph
  (Kotlin can't use the raw SVG strings); generic fallback marker.

## Legacy aliases

| legacy key | → representative glyph |
|---|---|
| `vehicle` | `car` |
| `animal` | `dog` |
| `cycle` | `bicycle` |
| `plate` | `license_plate` |
| `generic` | neutral grey dot (`#8E8E93`) |

## Icon set

97 labels. `color` is applied to the glyph via `currentColor`.

| label | group | source | icon_key | color | aliases |
|---|---|---|---|---|---|
| airplane | vehicle-other | coco-80 | `airplane` | `#FF6B22` | aeroplane, plane |
| Amazon | delivery | frigate-custom | `amazon` | `#C8923F` | amzn |
| An Post | delivery | frigate-custom | `an_post` | `#3E8A6E` | anpost, an post |
| Apple | food | coco-80 | `apple` | `#FF1F4A` |  |
| Backpack | personal-item | coco-80 | `backpack` | `#C0A062` | rucksack, knapsack |
| Banana | food | coco-80 | `banana` | `#FF3B61` |  |
| Baseball bat | sports | coco-80 | `baseball_bat` | `#4A48C8` | baseball bat, bat |
| Baseball glove | sports | coco-80 | `baseball_glove` | `#8482EC` | baseball glove, mitt |
| bear | animal-wild | coco-80 | `bear` | `#3FA8B5` |  |
| Bed | household | coco-80 | `bed` | `#63707F` |  |
| Bench | household | coco-80 | `bench` | `#5B6675` |  |
| Bicycle | two-wheeler | coco-80 | `bicycle` | `#FFCC00` | bike, pushbike |
| bird | animal-wild | coco-80 | `bird` | `#5AC8DA` |  |
| boat | vehicle-other | coco-80 | `boat` | `#E0531A` |  |
| Book | household | coco-80 | `book` | `#626E7D` |  |
| bottle | food | coco-80 | `bottle` | `#FF2D55` |  |
| Bowl | food | coco-80 | `bowl` | `#D62A4E` |  |
| Broccoli | food | coco-80 | `broccoli` | `#E83A5C` |  |
| bus | vehicle-road | coco-80 | `bus` | `#F08200` | autobus, omnibus |
| Cake | food | coco-80 | `cake` | `#FF6A8A` |  |
| Canada Post | delivery | frigate-custom | `canada_post` | `#C24B3E` | canadapost, canada post, postescanada |
| car | vehicle-road | coco-80 | `car` | `#FF9500` | automobile |
| Carrot | food | coco-80 | `carrot` | `#FF4060` |  |
| Cat | animal-pet | coco-80 | `cat` | `#5CD679` | kitten |
| Cell phone | household | coco-80 | `cell_phone` | `#606C7B` | cell phone, cellphone, mobile phone, smartphone |
| Chair | household | coco-80 | `chair` | `#5E6A79` |  |
| Clock | household | coco-80 | `clock` | `#64717F` |  |
| Couch | household | coco-80 | `couch` | `#616D7C` | sofa, settee |
| cow | animal-farm | coco-80 | `cow` | `#94B23A` | cattle |
| Cup | food | coco-80 | `cup` | `#E0244A` | mug |
| DHL | delivery | frigate-custom | `dhl` | `#C9A23D` |  |
| Dining table | household | coco-80 | `dining_table` | `#56616F` | dining table, diningtable, table |
| Dog | animal-pet | coco-80 | `dog` | `#2BA84A` | puppy |
| Donut | food | coco-80 | `donut` | `#FF577A` | doughnut |
| DPD | delivery | frigate-custom | `dpd` | `#C0966B` |  |
| elephant | animal-wild | coco-80 | `elephant` | `#2E8B98` |  |
| Face | face | frigate-custom | `face` | `#AF52DE` |  |
| FedEx | delivery | frigate-custom | `fedex` | `#C77A3B` | fed_ex |
| fire_hydrant | misc | coco-80 | `fire_hydrant` | `#9A9AA0` | fire hydrant, hydrant |
| Fork | food | coco-80 | `fork` | `#FF6680` |  |
| Frisbee | sports | coco-80 | `frisbee` | `#6E6CE0` | disc |
| giraffe | animal-wild | coco-80 | `giraffe` | `#49C6CC` |  |
| GLS | delivery | frigate-custom | `gls` | `#6E8A4F` |  |
| Hair drier | household | coco-80 | `hair_drier` | `#5C6979` | hair drier, hair dryer, hairdryer, blow dryer |
| Handbag | personal-item | coco-80 | `handbag` | `#B59554` | purse |
| horse | animal-farm | coco-80 | `horse` | `#A8C84A` |  |
| Hot dog | food | coco-80 | `hot_dog` | `#FF2D55` | hot dog, hotdog |
| Keyboard | household | coco-80 | `keyboard` | `#586573` |  |
| Kite | sports | coco-80 | `kite` | `#6260DE` |  |
| Knife | food | coco-80 | `knife` | `#C71F40` |  |
| Laptop | household | coco-80 | `laptop` | `#5A6573` | notebook |
| license_plate | vehicle-road | frigate-custom | `license_plate` | `#FFB143` | licence_plate, license plate, plate, number plate |
| Microwave | household | coco-80 | `microwave` | `#54606E` |  |
| Motorcycle | two-wheeler | coco-80 | `motorcycle` | `#E0A800` | motorbike |
| Mouse | household | coco-80 | `mouse` | `#67748A` |  |
| NZ Post | delivery | frigate-custom | `nzpost` | `#2E6FB0` | nz_post, nz post |
| Orange | food | coco-80 | `orange` | `#FF3355` |  |
| Oven | household | coco-80 | `oven` | `#525E6C` |  |
| Package | delivery | frigate-custom | `package` | `#A5825A` | parcel |
| parking_meter | misc | coco-80 | `parking_meter` | `#76767D` | parking meter |
| person | person | coco-80 | `person` | `#34AADC` |  |
| Pizza | food | coco-80 | `pizza` | `#FF3B61` |  |
| PostNL | delivery | frigate-custom | `postnl` | `#C77F3A` | post_nl, post nl |
| PostNord | delivery | frigate-custom | `postnord` | `#3F6DA8` | post_nord, post nord |
| Potted plant | household | coco-80 | `potted_plant` | `#586474` | potted plant, pottedplant, houseplant |
| Purolator | delivery | frigate-custom | `purolator` | `#B85C45` |  |
| Refrigerator | household | coco-80 | `refrigerator` | `#566270` | fridge |
| Remote | household | coco-80 | `remote` | `#5D6878` | remote control |
| Royal Mail | delivery | frigate-custom | `royal_mail` | `#9A4D55` | royalmail, royal mail |
| Sandwich | food | coco-80 | `sandwich` | `#FF5C77` |  |
| Scissors | household | coco-80 | `scissors` | `#5E6B7C` |  |
| sheep | animal-farm | coco-80 | `sheep` | `#BBD46A` | lamb |
| Sink | household | coco-80 | `sink` | `#5B6877` |  |
| Skateboard | sports | coco-80 | `skateboard` | `#5C5AD8` |  |
| Skis | sports | coco-80 | `skis` | `#5856D6` | ski |
| Snowboard | sports | coco-80 | `snowboard` | `#504ECF` |  |
| Spoon | food | coco-80 | `spoon` | `#FF879B` |  |
| Sports ball | sports | coco-80 | `sports_ball` | `#7472E6` | sports ball, ball |
| stop_sign | misc | coco-80 | `stop_sign` | `#83838A` | stop sign, stopsign |
| Suitcase | personal-item | coco-80 | `suitcase` | `#C7AC78` | luggage |
| Surfboard | sports | coco-80 | `surfboard` | `#6664E2` |  |
| Teddy bear | personal-item | coco-80 | `teddy_bear` | `#B89A5E` | teddy bear, teddybear, teddy |
| Tennis racket | sports | coco-80 | `tennis_racket` | `#46449E` | tennis racket, tennis racquet, racquet |
| Tie | personal-item | coco-80 | `tie` | `#A88A4B` | necktie |
| Toaster | household | coco-80 | `toaster` | `#5F6B7A` |  |
| Toilet | household | coco-80 | `toilet` | `#5C6776` |  |
| Toothbrush | household | coco-80 | `toothbrush` | `#606D7E` |  |
| traffic_light | misc | coco-80 | `traffic_light` | `#8E8E93` | traffic light, trafficlight |
| train | vehicle-other | coco-80 | `train` | `#FF8242` |  |
| truck | vehicle-road | coco-80 | `truck` | `#D97A00` | lorry |
| TV | household | coco-80 | `tv` | `#647183` | tvmonitor, television, monitor |
| Umbrella | personal-item | coco-80 | `umbrella` | `#CBAE73` | parasol |
| UPS | delivery | frigate-custom | `ups` | `#8A6233` |  |
| USPS | delivery | frigate-custom | `usps` | `#7A5C8A` | us_mail |
| Vase | household | coco-80 | `vase` | `#596574` |  |
| Wine glass | food | coco-80 | `wine_glass` | `#FF4F6E` | wine glass, wineglass |
| zebra | animal-wild | coco-80 | `zebra` | `#34B5C4` |  |

## Glyph SVGs

Each entry is the **inner** markup for a `<svg viewBox="0 0 24 24">`. Colour
comes from `currentColor` (set to the `color` above).

### `airplane`, airplane (#FF6B22)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#FF6B22">
  <path fill="currentColor" d="M21.5 11.2 13.5 9.2V4.3c0-.8-.65-1.5-1.5-1.5s-1.5.7-1.5 1.5v4.9L2.5 11.2c-.3.07-.5.34-.5.65v1.1c0 .33.31.58.63.5L10.5 12v3.6l-2 1.4c-.16.12-.25.3-.25.5v.9c0 .28.27.48.54.4L12 18l3.21.8c.27.07.54-.12.54-.4v-.9c0-.2-.09-.38-.25-.5l-2-1.4V12l7.87 1.45c.32.08.63-.17.63-.5v-1.1c0-.31-.2-.58-.5-.65z"/>
</svg>
```

### `amazon`, Amazon (#C8923F)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#C8923F">
  <path fill="currentColor" d="M4 6.4h16v2.1H4zM5.4 10h13.2l-1 9.1c-.1.92-.88 1.6-1.8 1.6H8.2c-.92 0-1.7-.68-1.8-1.6L5.4 10zm4.6 2.9v4.9h1.5v-4.9H10zm3.5 0v4.9H15v-4.9h-1.5z"/><path fill="currentColor" d="M6 18.8c3.85 1.9 8.15 1.9 12 0 .32-.16.58.24.3.5-1.45 1.25-3.9 1.95-6.3 1.95s-4.85-.7-6.3-1.95c-.28-.26-.02-.66.3-.5z"/>
</svg>
```

### `an_post`, An Post (#3E8A6E)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#3E8A6E">
  <path fill="currentColor" d="M12 2.5l2.6 6.2 6.7.5-5.1 4.4 1.6 6.5L12 16.9l-5.8 3.7 1.6-6.5L2.7 9.7l6.7-.5L12 2.5z"/>
</svg>
```

### `apple`, Apple (#FF1F4A)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#FF1F4A">
  <path fill="currentColor" d="M12 7c-1.5-1.5-4-2-6-1-2.5 1.3-3 5-1.5 8.5C5.7 17.5 8 21 10 21c1 0 1.3-.5 2-.5s1 .5 2 .5c2 0 4.3-3.5 5.5-6.5C21 11 20.5 7.3 18 6c-2-1-4.5-.5-6 1z"/><path stroke="currentColor" stroke-width="1.8" stroke-linecap="round" fill="none" d="M12 7c0-2 1-3.5 3-4"/>
</svg>
```

### `backpack`, Backpack (#C0A062)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#C0A062">
  <path fill="currentColor" d="M12 2c-1.86 0-3.4 1.4-3.6 3.2C6.5 5.9 5 7.8 5 10v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-9c0-2.2-1.5-4.1-3.4-4.8C15.4 3.4 13.86 2 12 2zm0 2c.83 0 1.5.67 1.5 1.5V6h-3v-.5C10.5 4.67 11.17 4 12 4zm-3 8h6a1 1 0 0 1 1 1v3H8v-3a1 1 0 0 1 1-1zm0 6h6v1H9v-1z"/>
</svg>
```

### `banana`, Banana (#FF3B61)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#FF3B61">
  <path fill="currentColor" d="M4 9c0 6 5 11 11 11 2.5 0 4.5-1 5-2-2 .5-9 0-12-4S5 6 7 4C5 4 4 6 4 9z"/>
</svg>
```

### `baseball_bat`, Baseball bat (#4A48C8)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#4A48C8">
  <path d="M5 19 L16 8" fill="none" stroke="currentColor" stroke-width="4" stroke-linecap="round"/><path d="M4.5 20.5 L7 18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
</svg>
```

### `baseball_glove`, Baseball glove (#8482EC)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#8482EC">
  <path fill-rule="evenodd" clip-rule="evenodd" d="M8 21 q-4 0 -4-4.5 Q4 13 6 11 V7.5 q0-1.8 1.6-1.8 q1.6 0 1.6 1.8 V5 q0-1.8 1.6-1.8 q1.6 0 1.6 1.8 v1.4 q0-1.6 1.5-1.6 q1.6 0 1.6 2.2 V12 q2 1 2 4.5 Q19 21 15 21 Z M11.5 13.1 a2.4 2.4 0 1 0 0 4.8 a2.4 2.4 0 1 0 0-4.8 Z" fill="currentColor"/>
</svg>
```

### `bear`, bear (#3FA8B5)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#3FA8B5">
  <path fill="currentColor" d="M7 4.5a2.6 2.6 0 0 0-2.4 3.6A6.5 6.5 0 0 0 3.5 12c0 3.6 3.8 6.5 8.5 6.5s8.5-2.9 8.5-6.5c0-1.4-.4-2.7-1.1-3.9A2.6 2.6 0 1 0 15.6 5 9.9 9.9 0 0 0 12 4.4c-1.3 0-2.5.2-3.6.6A2.6 2.6 0 0 0 7 4.5zm2.2 6.2a1.1 1.1 0 1 1 0 2.2 1.1 1.1 0 0 1 0-2.2zm5.6 0a1.1 1.1 0 1 1 0 2.2 1.1 1.1 0 0 1 0-2.2zM12 13.5c.9 0 1.6.6 1.6 1.3 0 .7-.7 1.2-1.6 1.2s-1.6-.5-1.6-1.2c0-.7.7-1.3 1.6-1.3z"/>
</svg>
```

### `bed`, Bed (#63707F)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#63707F">
  <path fill="currentColor" d="M3 9a1 1 0 0 1 1 1v3h7v-2a1 1 0 0 1 1-1h7a3 3 0 0 1 3 3v6a1 1 0 0 1-2 0v-1H4v1a1 1 0 0 1-2 0V10a1 1 0 0 1 1-1zm3 1.5a2 2 0 1 1 0 .01z"/>
</svg>
```

### `bench`, Bench (#5B6675)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#5B6675">
  <path fill="currentColor" d="M3 10h18a1 1 0 0 1 1 1v1H2v-1a1 1 0 0 1 1-1zm-1 3h20v1.5H2zm1 1.5h1.6V20a.8.8 0 0 1-1.6 0zm17.4 0H22V20a.8.8 0 0 1-1.6 0z"/>
</svg>
```

### `bicycle`, Bicycle (#FFCC00)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#FFCC00">
  <g fill="currentColor"><circle cx="6" cy="16" r="4"/><circle cx="18" cy="16" r="4"/><path d="M6 16l5-7h6l-3 7H6z" stroke="currentColor" stroke-width="2" stroke-linejoin="round" fill="none"/><path d="M9 9h4" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></g>
</svg>
```

### `bird`, bird (#5AC8DA)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#5AC8DA">
  <path fill="currentColor" d="M14.5 5.2c-2.8 0-5 2.2-5 5 0 .4-.3.7-.7 1.1-1 .9-2.6 1.7-4.3 1.7 0 1.7 1.6 3.1 3.6 3.1.3 0 .6 0 .9-.1-.5.9-1.4 1.6-2.5 1.9 1 .7 2.3 1.1 3.6 1.1 3.6 0 6.4-2.9 6.4-6.5v-.3l2-2-2.6-.3-1-1.9-.8 2c-.6-.3-1.1-.5-1.8-.6.1-.2.1-.4.1-.7 0-.9.7-1.6 1.6-1.6V5.2zm.6 3.1a.8.8 0 1 1 0 1.6.8.8 0 0 1 0-1.6z"/>
</svg>
```

### `boat`, boat (#E0531A)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#E0531A">
  <path fill="currentColor" d="M12.75 3.2c0-.55-.6-.9-1.08-.62l-5.5 3.2c-.23.14-.37.39-.37.65V11h-1.3c-.55 0-.94.54-.77 1.06l1.6 4.94H4c-.55 0-1 .45-1 1s.45 1 1 1h.6c.9 0 1.73-.42 2.27-1.12.54.7 1.37 1.12 2.27 1.12h.86c.9 0 1.73-.42 2.27-1.12.54.7 1.37 1.12 2.27 1.12h.86c.9 0 1.73-.42 2.27-1.12.54.7 1.37 1.12 2.27 1.12H20c.55 0 1-.45 1-1s-.45-1-1-1h-.13l1.6-4.94c.17-.52-.22-1.06-.77-1.06H12.75V3.2zM10.75 11H8.25V7.6l2.5-1.45V11z"/>
</svg>
```

### `book`, Book (#626E7D)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#626E7D">
  <path fill="currentColor" d="M5 3h7v16H6a2 2 0 0 0-1.5.68V4a1 1 0 0 1 1-1zm14 0a1 1 0 0 1 1 1v15.68A2 2 0 0 0 18 19h-5V3zm-1 18H6a2 2 0 0 1 0-4h12a2 2 0 0 1 0 4z"/>
</svg>
```

### `bottle`, bottle (#FF2D55)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#FF2D55">
  <path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M10 2h4v3l1.5 2.5c.3.5.5 1.1.5 1.7V20a2 2 0 0 1-2 2H10a2 2 0 0 1-2-2V9.2c0-.6.2-1.2.5-1.7L10 5V2z"/><path stroke="currentColor" stroke-width="1.8" d="M8 13h8"/>
</svg>
```

### `bowl`, Bowl (#D62A4E)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#D62A4E">
  <path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" d="M3 11h18a9 9 0 0 1-18 0z"/><path stroke="currentColor" stroke-width="1.6" stroke-linecap="round" d="M8 8c0-2 1-3 0-5M12 8c0-2 1-3 0-5M16 8c0-2 1-3 0-5"/>
</svg>
```

### `broccoli`, Broccoli (#E83A5C)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#E83A5C">
  <path fill="currentColor" d="M9 3a3 3 0 0 0-2.8 4A3 3 0 0 0 4 9.8 3 3 0 0 0 6.5 13h11A3 3 0 0 0 20 9.8 3 3 0 0 0 17.8 7 3 3 0 0 0 13 4.2 3 3 0 0 0 9 3z"/><path stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M10 13l-.5 8M14 13l.5 8M12 13v8"/>
</svg>
```

### `bus`, bus (#F08200)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#F08200">
  <path fill="currentColor" d="M5 4h14c1.1 0 2 .9 2 2v11.5c0 .66-.4 1.23-.98 1.48v.52a1.5 1.5 0 0 1-3 0V19H6.98v.5a1.5 1.5 0 0 1-3 0v-.52A1.6 1.6 0 0 1 3 17.5V6c0-1.1.9-2 2-2zm.5 3.5v4h5v-4h-5zm8 0v4h5v-4h-5zM7 14.5a1.25 1.25 0 1 0 0 2.5 1.25 1.25 0 0 0 0-2.5zm10 0a1.25 1.25 0 1 0 0 2.5 1.25 1.25 0 0 0 0-2.5z"/>
</svg>
```

### `cake`, Cake (#FF6A8A)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#FF6A8A">
  <path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M4 13c0-2 1.5-3 4-3h8c2.5 0 4 1 4 3v7H4v-7z"/><path stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M3 20h18M8 10V6.5M12 10V6.5M16 10V6.5"/><path fill="currentColor" d="M8 4.5a1 1 0 0 0 2 0c0-.7-1-1.5-1-1.5s-1 .8-1 1.5zM11 4.5a1 1 0 0 0 2 0c0-.7-1-1.5-1-1.5s-1 .8-1 1.5zM15 4.5a1 1 0 0 0 2 0c0-.7-1-1.5-1-1.5s-1 .8-1 1.5z"/>
</svg>
```

### `canada_post`, Canada Post (#C24B3E)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#C24B3E">
  <path fill="currentColor" d="M12 2.5l2.2 4.9 5.3-1.4-2.4 4.9 4 3.6-5.3.6.3 5.4L12 17.8l-4.1 2.7.3-5.4-5.3-.6 4-3.6L4.5 6l5.3 1.4L12 2.5z"/>
</svg>
```

### `car`, car (#FF9500)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#FF9500">
  <path fill="currentColor" d="M3 14.2c0-.5.32-.94.79-1.1l1.86-.62 2.2-3.05c.45-.62 1.17-.99 1.94-.99h4.9c.63 0 1.23.25 1.68.69l2.32 2.32 2.05.51c.62.16 1.05.71 1.05 1.35V16c0 .55-.45 1-1 1h-1.04a2.5 2.5 0 0 1-4.92 0H9.96a2.5 2.5 0 0 1-4.92 0H4c-.55 0-1-.45-1-1v-1.8zM9.2 10.4 7.7 12.5h4.3V10h-1.86c-.37 0-.72.15-.94.4zM13.5 12.5h3.9l-1.7-1.7a1 1 0 0 0-.71-.3H13.5v2zM6.5 16.5a1 1 0 1 0 2 0 1 1 0 0 0-2 0zm9 0a1 1 0 1 0 2 0 1 1 0 0 0-2 0z"/>
</svg>
```

### `carrot`, Carrot (#FF4060)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#FF4060">
  <path fill="currentColor" d="M16.2 8.8c1-1.5-.6-3.1-2-2L4.5 16.5c-1.1 1.1.4 2.6 1.5 1.5l10.2-9.2z"/><path fill="currentColor" d="M15 7.5c-.6-2 .2-3.6 1.6-4.4-.2 1.3.1 2.3.9 3-.9-.1-1.8.4-2.5 1.4zM16 7c1.4-1.5 3.2-1.7 4.7-1-1.2.6-1.9 1.4-2 2.5-.6-.8-1.5-1.3-2.7-1.5zM15.6 7.4c-1.9-.6-2.9.1-3.6 1.5 1.3-.3 2.3 0 3 .9.1-1 .3-1.8.6-2.4z"/>
</svg>
```

### `cat`, Cat (#5CD679)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#5CD679">
  <path fill="currentColor" fill-rule="evenodd" d="M5.7 3.8c.5-.4 1.2-.1 1.3.5l.9 3.2a6 6 0 0 1 5.7-.1l.9-3.1c.2-.6.9-.9 1.4-.5.3.2.4.5.4.9l-.5 3.6a6 6 0 0 1 2.5 4.9c0 1.6-.7 3-1.7 4 .5.3 1.2.2 1.6-.3.3-.4 1-.4 1.2.1.2.4 0 .9-.4 1.1-1.4.8-3.2.5-4.2-.7a6.7 6.7 0 0 1-4.4 0 6 6 0 0 1-7.6-5.3 6 6 0 0 1 2.5-5L4.9 4.7c-.1-.4 0-.7.3-.9zM9 12.4c.6 0 1-.5 1-1.1s-.4-1.1-1-1.1-1 .5-1 1.1.4 1.1 1 1.1zm6 0c.6 0 1-.5 1-1.1s-.4-1.1-1-1.1-1 .5-1 1.1.4 1.1 1 1.1z" clip-rule="evenodd"/>
</svg>
```

### `cell_phone`, Cell phone (#606C7B)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#606C7B">
  <path fill="currentColor" d="M8 2h8a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zm0 3.5v11h8v-11zm4 12.5a1 1 0 1 0 0 2 1 1 0 0 0 0-2z"/>
</svg>
```

### `chair`, Chair (#5E6A79)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#5E6A79">
  <path fill="currentColor" d="M7 3a1 1 0 0 1 1 1v8h8V4a1 1 0 0 1 2 0v15a1 1 0 0 1-2 0v-3H8v3a1 1 0 0 1-2 0V4a1 1 0 0 1 1-1z"/>
</svg>
```

### `clock`, Clock (#64717F)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#64717F">
  <path fill="currentColor" d="M12 3a9 9 0 1 1 0 18 9 9 0 0 1 0-18zm0 2a7 7 0 1 0 0 14 7 7 0 0 0 0-14zm-.9 2.5a.9.9 0 0 1 1.8 0v4.1l2.7 1.6a.9.9 0 1 1-.9 1.55l-3.1-1.8a.9.9 0 0 1-.5-.8z"/>
</svg>
```

### `couch`, Couch (#616D7C)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#616D7C">
  <path fill="currentColor" d="M4 11V8a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v3a2 2 0 0 0-1 1.73V15H3v-2.27A2 2 0 0 0 2 11a2 2 0 0 1 2 0zm-2 5h20v2H21v1.5a.75.75 0 0 1-1.5 0V18h-15v1.5a.75.75 0 0 1-1.5 0V18H2z"/>
</svg>
```

### `cow`, cow (#94B23A)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#94B23A">
  <path fill="currentColor" fill-rule="evenodd" d="M2.2 8.4c-.1-.5.4-.9.8-.6l1.7 1.1c.6-.4 1.4-.6 2.3-.6h7c1.6 0 3 .8 3.9 2l.3-1.9c.1-.6-.1-1.2-.5-1.7l-.8-.9c-.3-.4 0-1 .5-.9l1 .2c1 .2 1.8 1 2 2l.3 1.7c.2 1.1-.1 2.2-.8 3.1-.1.5-.3 1-.5 1.4v3.4c0 .6-.4 1-1 1s-1-.4-1-1v-1.2c-.3.1-.7.2-1 .2v1.2c0 .6-.4 1-1 1s-1-.4-1-1v-1H9v1c0 .6-.4 1-1 1s-1-.4-1-1v-1.2c-.4 0-.7-.1-1-.2v1.4c0 .6-.4 1-1 1s-1-.4-1-1V13c-.6-.8-1-1.7-1-2.8 0-.3 0-.5.1-.8L2.2 8.4zM8.5 9c-1.4 0-2.5 1.1-2.5 2.5S7.1 14 8.5 14 11 12.9 11 11.5 9.9 9 8.5 9z"/>
</svg>
```

### `cup`, Cup (#E0244A)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#E0244A">
  <path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M5 8h11v7a4 4 0 0 1-4 4H9a4 4 0 0 1-4-4V8z"/><path fill="none" stroke="currentColor" stroke-width="1.8" d="M16 10h2a2 2 0 0 1 0 4h-2"/><path stroke="currentColor" stroke-width="1.6" stroke-linecap="round" d="M8 3v2M11.5 3v2"/>
</svg>
```

### `dhl`, DHL (#C9A23D)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#C9A23D">
  <path fill="currentColor" d="M2 9.4h7.2l-.6 1.4H2.6l-.6-1.4zm.9 2.2h6.5l-.6 1.4H3.5l-.6-1.4zm10.3-2.2H22l-.55 1.4h-7.6l-.55-1.4zm-.9 2.2h7.5l-.55 1.4h-7.5l.55-1.4z"/><path fill="currentColor" d="M11.3 7.5h2.3l-3.2 9h-2.3l3.2-9z"/>
</svg>
```

### `dining_table`, Dining table (#56616F)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#56616F">
  <path fill="currentColor" d="M3 8h18a1 1 0 0 1 0 2H3a1 1 0 0 1 0-2zm2 3h1.6v9a.8.8 0 0 1-1.6 0zm12.4 0H19v9a.8.8 0 0 1-1.6 0zM8 13h8v1.4H8z"/>
</svg>
```

### `dog`, Dog (#2BA84A)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#2BA84A">
  <path fill="currentColor" fill-rule="evenodd" d="M5.6 4.4c1.4-.5 2.7.2 3.5 1.2.9-.4 1.9-.6 2.9-.6s2 .2 2.9.6c.8-1 2.1-1.7 3.5-1.2 1.3.5 1.7 2 1.4 3.5-.2 1-.6 2.2-1 3.3.5.9.7 1.9.7 2.9 0 2.5-1.7 4.6-4 5.4-.3 1.1-.6 1.8-1 2.2-.4.4-1 .5-2.5.5h-.1c-1.5 0-2.1-.1-2.5-.5-.4-.4-.7-1.1-1-2.2-2.3-.8-4-2.9-4-5.4 0-1 .2-2 .7-2.9-.4-1.1-.8-2.3-1-3.3-.3-1.5.1-3 1.4-3.5zM6.3 6.2c-.3.1-.5.6-.3 1.6.2.9.5 1.9.9 2.8l.3-.3c.4-1.3.5-2.6.4-3.5-.1-.5-.3-.7-.4-.7-.4-.1-.8 0-.9.1zm11.4 0c-.1-.1-.5-.2-.9-.1-.1 0-.3.2-.4.7-.1.9 0 2.2.4 3.5l.3.3c.4-.9.7-1.9.9-2.8.2-1-.0-1.5-.3-1.6zM9.5 12.3a.95.95 0 1 0 0 1.9.95.95 0 0 0 0-1.9zm5 0a.95.95 0 1 0 0 1.9.95.95 0 0 0 0-1.9zM12 15.4c-.7 0-1.3.3-1.6.8-.2.3 0 .7.4.8.4.1.8.1 1.2.1s.8 0 1.2-.1c.4-.1.6-.5.4-.8-.3-.5-.9-.8-1.6-.8z" clip-rule="evenodd"/>
</svg>
```

### `donut`, Donut (#FF577A)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#FF577A">
  <path fill="currentColor" fill-rule="evenodd" d="M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zm0 6a3 3 0 1 1 0 6 3 3 0 0 1 0-6z"/>
</svg>
```

### `dpd`, DPD (#C0966B)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#C0966B">
  <path fill="currentColor" d="M3 6h10a1 1 0 0 1 1 1v3h3.2a1 1 0 0 1 .82.43l2.8 4A1 1 0 0 1 21 16v2h-1.6a2.4 2.4 0 0 1-4.8 0H9.4a2.4 2.4 0 0 1-4.8 0H3a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1zm11 6v3.05A2.4 2.4 0 0 1 16.05 14H19v-.18L16.68 12H14zm-7 3.6a1 1 0 1 0 0 2 1 1 0 0 0 0-2zm10 0a1 1 0 1 0 0 2 1 1 0 0 0 0-2z"/>
</svg>
```

### `elephant`, elephant (#2E8B98)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#2E8B98">
  <path fill="currentColor" d="M8.5 4.5C5.7 4.5 3.5 6.7 3.5 9.5v6c0 .8.7 1.5 1.5 1.5s1.5-.7 1.5-1.5V12c0-.6.4-1 1-1s1 .4 1 1v3.5c0 .8.7 1.5 1.5 1.5s1.5-.7 1.5-1.5V11c1 .8 2.3 1.3 3.7 1.3.4 0 .8 0 1.2-.1v3.6c0 1 .3 2 .9 2.9.3.4.8.5 1.2.3.4-.3.5-.8.3-1.2-.4-.6-.6-1.2-.6-1.9V9.5c0-2.8-2.2-5-5-5h-5zm1 3a1 1 0 1 1 0 2 1 1 0 0 1 0-2z"/>
</svg>
```

### `face`, Face (#AF52DE)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#AF52DE">
  <circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" stroke-width="1.8"/><circle cx="9" cy="10" r="1.15" fill="currentColor"/><circle cx="15" cy="10" r="1.15" fill="currentColor"/><path d="M8.2 14.2c.9 1.6 2.3 2.5 3.8 2.5s2.9-.9 3.8-2.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>
</svg>
```

### `fedex`, FedEx (#C77A3B)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#C77A3B">
  <path fill="currentColor" d="M4 7.5a1 1 0 0 1 1-1h8.5a1 1 0 0 1 1 1v7.5H4z"/><path fill="currentColor" d="M14.5 9.5h3.2a1 1 0 0 1 .82.43l1.98 2.77a1 1 0 0 1 .2.6V15h-7z"/><circle cx="8" cy="16.8" r="2.1" fill="currentColor"/><circle cx="17.4" cy="16.8" r="2.1" fill="currentColor"/><path fill="currentColor" d="M2.4 9h2.1v1.4H2.4zM2 11.4h2.5v1.4H2z"/>
</svg>
```

### `fire_hydrant`, fire_hydrant (#9A9AA0)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#9A9AA0">
  <path fill="currentColor" d="M10 12v7a1 1 0 0 0 1 1h2a1 1 0 0 0 1-1v-7h2.5a1 1 0 0 0 0-2H16V8.5h1.5a.9.9 0 0 0 0-1.8H16V6a4 4 0 0 0-8 0v.7H6.5a.9.9 0 0 0 0 1.8H8V10H6.5a1 1 0 0 0 0 2H10zm0-6a2 2 0 0 1 4 0v4h-4V6z"/>
</svg>
```

### `fork`, Fork (#FF6680)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#FF6680">
  <path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" d="M7 3v4M10 3v4M13 3v4M6.5 7h7a3.5 3.5 0 0 1-3.5 3.5v0M10 10.5V21"/>
</svg>
```

### `frisbee`, Frisbee (#6E6CE0)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#6E6CE0">
  <ellipse cx="12" cy="12" rx="9" ry="4" fill="none" stroke="currentColor" stroke-width="2"/><ellipse cx="12" cy="11" rx="5" ry="2.2" fill="currentColor" opacity="0.9"/>
</svg>
```

### `giraffe`, giraffe (#49C6CC)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#49C6CC">
  <path fill="currentColor" d="M9 20.5c-.4 0-.8-.3-.8-.8l-.4-7.4-1.6 1.3c-.4.3-1 .3-1.3-.1-.3-.4-.3-1 .1-1.3l2.7-2.2.9-6.2c0-.5.5-.9 1-.8.3 0 .5.2.6.4l.7-1.1c.2-.4.7-.5 1.1-.3.3.2.5.5.4.9l-.5 1.7.1 1.6 1.3 7.7c.4 2.4-.9 4.8-3.1 5.8l-.1 1.6c0 .4-.4.8-.8.8H9zm2.3-15a.7.7 0 1 0 0-1.4.7.7 0 0 0 0 1.4zm1.6 1.5a.7.7 0 1 0 0-1.4.7.7 0 0 0 0 1.4zm-1 2.4a.8.8 0 1 0 0-1.6.8.8 0 0 0 0 1.6zm1.6 1.8a.7.7 0 1 0 0-1.4.7.7 0 0 0 0 1.4z"/>
</svg>
```

### `gls`, GLS (#6E8A4F)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#6E8A4F">
  <path fill="currentColor" d="M12 3a9 9 0 100 18 9 9 0 000-18zm0 2a7 7 0 016.9 5.8h-4.3A3 3 0 0012 9.2V5zm-2 .4v9.2a7 7 0 01-4-6.3 7 7 0 014-2.9zM12 11a1 1 0 110 2 1 1 0 010-2zm2.6 3.8h4.3A7 7 0 0112 19v-4.2a3 3 0 002.6-1z"/>
</svg>
```

### `hair_drier`, Hair drier (#5C6979)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#5C6979">
  <path fill="currentColor" d="M3 8a4 4 0 0 1 4-4h6a4 4 0 0 1 0 8h-1.2l1 6.8A1 1 0 0 1 11.8 20H9.5a1 1 0 0 1-1-.85L7.4 12H7a4 4 0 0 1-4-4zm4-1.5a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3z"/>
</svg>
```

### `handbag`, Handbag (#B59554)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#B59554">
  <path fill="currentColor" d="M9 6a3 3 0 0 1 6 0v1h2.2a1.5 1.5 0 0 1 1.49 1.33l1.1 9.5A2.5 2.5 0 0 1 17.3 21H6.7a2.5 2.5 0 0 1-2.49-2.67l1.1-9.5A1.5 1.5 0 0 1 6.8 7H9V6zm2 1h2V6a1 1 0 1 0-2 0v1z"/>
</svg>
```

### `horse`, horse (#A8C84A)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#A8C84A">
  <path fill="currentColor" d="M4 12.5c0-2.5 2-4.5 4.5-4.5h5.5c2.2 0 4 1.8 4 4v1c0 1.3-.6 2.5-1.6 3.3l.4 2.5c.1.5-.3.9-.8.9h-.4c-.4 0-.7-.3-.8-.7l-.3-1.9c-.4.1-.7.1-1.1.1H8.6c-.4 0-.8 0-1.1-.1l-.3 1.9c-.1.4-.4.7-.8.7h-.4c-.5 0-.9-.4-.8-.9l.4-2.4C4.7 15.6 4 14.1 4 12.5z"/><path fill="currentColor" d="M13 9.5l1.8-5.4c.2-.6.9-.8 1.4-.4l1 .8c.3.3.5.7.4 1.1l-1.2 4.6c-.2.7-.8 1.2-1.5 1.2H13z"/><path fill="currentColor" d="M15.8 3.2l2.6-.7c.5-.1 1 .3 1 .8l-.1 2.8c0 .5-.4.8-.9.8h-.8l-2.3-2.6c-.4-.5-.2-1.2.5-1.4z"/><rect x="6.3" y="16.5" width="1.6" height="4.5" rx=".8" fill="currentColor"/><rect x="9.3" y="16.5" width="1.6" height="4.5" rx=".8" fill="currentColor"/><rect x="13.3" y="16.5" width="1.6" height="4.5" rx=".8" fill="currentColor"/><rect x="15.6" y="16.5" width="1.6" height="4.5" rx=".8" fill="currentColor"/><path fill="currentColor" d="M4 12c-.8.3-1.4 1.1-1.6 2l-.3 1.4c-.1.5.5.8.9.5.5-.4.8-1 1-1.6l.6-1.8z"/>
</svg>
```

### `hot_dog`, Hot dog (#FF2D55)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#FF2D55">
  <rect x="2.5" y="9" width="19" height="6" rx="3" fill="none" stroke="currentColor" stroke-width="1.8"/><rect x="5" y="10.6" width="14" height="2.8" rx="1.4" fill="currentColor"/>
</svg>
```

### `keyboard`, Keyboard (#586573)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#586573">
  <path fill="currentColor" d="M3 6h18a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2zm2 2.5v2h2v-2zm3 0v2h2v-2zm3 0v2h2v-2zm3 0v2h2v-2zm3 0v2h2v-2zM5 12v2h2v-2zm3 0v2h2v-2zm3 0v2h2v-2zm3 0v2h2v-2zm3 0v2h2v-2zM8 15.5v1.5h8v-1.5z"/>
</svg>
```

### `kite`, Kite (#6260DE)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#6260DE">
  <path d="M12 3 L19 10 L12 17 L5 10 Z" fill="currentColor"/><path d="M12 3 V17 M5 10 H19" fill="none" stroke="currentColor" stroke-width="1" opacity="0.35"/><path d="M12 17 q-1.5 2.5 0.5 3.8 q-2 1 -1 -2" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>
</svg>
```

### `knife`, Knife (#C71F40)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#C71F40">
  <path fill="currentColor" d="M4 14L18 3c.5-.4 1.2.2.9.8L9 16l-3.2.6L5 20l-.8-.2.5-3.4L4 14z"/><path stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M9.5 15.5l5.5 5.5"/>
</svg>
```

### `laptop`, Laptop (#5A6573)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#5A6573">
  <path fill="currentColor" d="M5 5a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v9H5V5zm1.5 1.5v6h11v-6zM2.5 16h19a.5.5 0 0 1 .47.66l-.5 1.5A1 1 0 0 1 20.5 19h-17a1 1 0 0 1-.95-.84l-.5-1.5A.5.5 0 0 1 2.5 16z"/>
</svg>
```

### `license_plate`, license_plate (#FFB143)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#FFB143">
  <rect x="2.5" y="6" width="19" height="12" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path fill="currentColor" d="M6 10h2v4H6zm3.5 0h2v4h-2zm3.5 0h5v4h-5z"/>
</svg>
```

### `microwave`, Microwave (#54606E)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#54606E">
  <path fill="currentColor" fill-rule="evenodd" d="M2 5h20a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1H2a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1zm2 3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h9a1 1 0 0 0 1-1V9a1 1 0 0 0-1-1H4zm13 0a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2a1 1 0 0 0 1-1V9a1 1 0 0 0-1-1h-2zm.5 2a1 1 0 1 1 0 2 1 1 0 0 1 0-2zm0 3.5a1 1 0 1 1 0 2 1 1 0 0 1 0-2z" clip-rule="evenodd"/>
</svg>
```

### `motorcycle`, Motorcycle (#E0A800)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#E0A800">
  <circle cx="5" cy="16.5" r="3.5" fill="currentColor"/><circle cx="19" cy="16.5" r="3.5" fill="currentColor"/><circle cx="5" cy="16.5" r="1.2" fill="none" stroke="currentColor" stroke-width="1.4"/><circle cx="19" cy="16.5" r="1.2" fill="none" stroke="currentColor" stroke-width="1.4"/><path fill="currentColor" d="M3 11.5l3.5-1.5 4 2.5 3-3.5h2.2l1 2 2.3.5v2.5l-3-.5-3.5-1-3 2H8.5l-1.5-2-3 .5z"/><path d="M14.5 8h3.5" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>
</svg>
```

### `mouse`, Mouse (#67748A)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#67748A">
  <path fill="currentColor" d="M12 3a7 7 0 0 1 7 7v4a7 7 0 0 1-14 0v-4a7 7 0 0 1 7-7zm-.9 2.1A5 5 0 0 0 7 10v.9h4V5.1zM13 5.1V11h4v-1a5 5 0 0 0-4-4.9z"/>
</svg>
```

### `nzpost`, NZ Post (#2E6FB0)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#2E6FB0">
  <path fill="currentColor" d="M5 19V5h2.4l6.2 8.4V5H16v14h-2.4L7.4 10.6V19H5z"/><path fill="currentColor" d="M17.8 6.1a1.3 1.3 0 110 2.6 1.3 1.3 0 010-2.6z"/>
</svg>
```

### `orange`, Orange (#FF3355)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#FF3355">
  <circle cx="12" cy="13" r="8" fill="currentColor"/><path stroke="currentColor" stroke-width="1.8" stroke-linecap="round" fill="none" d="M12 5c.5-1.5 2-2.5 3.5-2.5"/>
</svg>
```

### `oven`, Oven (#525E6C)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#525E6C">
  <g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><rect x="3.5" y="2.5" width="17" height="19" rx="1.5"/><line x1="3.5" y1="8" x2="20.5" y2="8"/><line x1="7" y1="11.5" x2="17" y2="11.5"/></g><g fill="currentColor"><circle cx="6.5" cy="5.25" r="1"/><circle cx="10" cy="5.25" r="1"/><circle cx="13.5" cy="5.25" r="1"/><circle cx="17.5" cy="5.25" r="1"/></g>
</svg>
```

### `package`, Package (#A5825A)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#A5825A">
  <path fill="currentColor" d="M21 7.5l-9-5-9 5v9l9 5 9-5v-9zm-9 1.31L6.96 6 12 3.19 17.04 6 12 8.81zM5 9.21l6 3.33v6.46l-6-3.33V9.21zm8 9.79v-6.46l6-3.33v6.46L13 19z"/>
</svg>
```

### `parking_meter`, parking_meter (#76767D)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#76767D">
  <rect x="7.5" y="3" width="9" height="9" rx="2.4" fill="none" stroke="currentColor" stroke-width="1.8"/><circle cx="12" cy="7.5" r="1.7" fill="currentColor"/><path d="M11 12.5h2l-.5 5.5h-1z" fill="currentColor"/><path d="M9 21h6" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>
</svg>
```

### `person`, person (#34AADC)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#34AADC">
  <path fill="currentColor" d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/>
</svg>
```

### `pizza`, Pizza (#FF3B61)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#FF3B61">
  <path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M4 6c5-2 11-2 16 0l-8 15L4 6z"/><circle cx="10" cy="8" r="1.1" fill="currentColor"/><circle cx="14" cy="9" r="1.1" fill="currentColor"/><circle cx="12" cy="13" r="1.1" fill="currentColor"/>
</svg>
```

### `postnl`, PostNL (#C77F3A)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#C77F3A">
  <path fill="currentColor" d="M3 18l8-12 4 6h-3l2 3h-3l1.4 2.1c.2.3 0 .9-.4.9H3z"/><path fill="currentColor" d="M16.8 9.2l3.6 6.3-1.8 1-3.6-6.3 1.8-1z"/>
</svg>
```

### `postnord`, PostNord (#3F6DA8)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#3F6DA8">
  <path fill="currentColor" d="M12 2.5L3 8v8l9 5.5L21 16V8l-9-5.5zm0 2.3l6.7 4.1L12 13 5.3 8.9 12 4.8zM4.8 10.4l6.3 3.9v5.3l-6.3-3.9v-5.3zm14.4 0v5.3l-6.3 3.9v-5.3l6.3-3.9z"/>
</svg>
```

### `potted_plant`, Potted plant (#586474)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#586474">
  <path fill="currentColor" d="M12 11c0-3 1.5-5.5 5-7-.5 3.5-2 5.5-4 6.4 2-.2 3.5-1.4 5-3.4-1 4-3.5 5.5-6 5.5V14h-1v-1.5C8.5 12.5 6 11 5 7c1.5 2 3 3.2 5 3.4C8 9.5 6.5 7.5 6 4c3.5 1.5 5 4 5 7z"/><path fill="currentColor" d="M7 14h10l-1.2 6a1 1 0 0 1-1 .8H9.2a1 1 0 0 1-1-.8z"/>
</svg>
```

### `purolator`, Purolator (#B85C45)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#B85C45">
  <path fill="currentColor" d="M12 2.5l8 4.3v8.4l-8 4.3-8-4.3V6.8l8-4.3zm0 2.3L6.3 7.9 12 11l5.7-3.1L12 4.8zM5.6 9.3v5.1l5.5 3v-5.1l-5.5-3zm12.8 0l-5.5 3v5.1l5.5-3V9.3z"/><path fill="currentColor" d="M11.2 12.8h1.6v4h-1.6z"/>
</svg>
```

### `refrigerator`, Refrigerator (#566270)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#566270">
  <g fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round" stroke-linecap="round"><rect x="6" y="3" width="12" height="18" rx="1.6"/><line x1="6" y1="9.5" x2="18" y2="9.5"/><line x1="9" y1="5.4" x2="9" y2="7.6"/><line x1="9" y1="12" x2="9" y2="16"/></g>
</svg>
```

### `remote`, Remote (#5D6878)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#5D6878">
  <path fill="currentColor" d="M9 2h6a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H9a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zm3 2.2a1.4 1.4 0 1 0 0 2.8 1.4 1.4 0 0 0 0-2.8zM9.5 10h2v2h-2zm3 0h2v2h-2zm-3 3h2v2h-2zm3 0h2v2h-2zm-3 3h2v2h-2zm3 0h2v2h-2z"/>
</svg>
```

### `royal_mail`, Royal Mail (#9A4D55)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#9A4D55">
  <path fill="currentColor" d="M12 3a4.2 4.2 0 014.2 4.2V9h.8c.7 0 1.3.6 1.3 1.3V19c0 .7-.6 1.3-1.3 1.3H7c-.7 0-1.3-.6-1.3-1.3v-8.7C5.7 9.6 6.3 9 7 9h.8V7.2A4.2 4.2 0 0112 3zm0 2a2.2 2.2 0 00-2.2 2.2V9h4.4V7.2A2.2 2.2 0 0012 5zm0 8.5a1.6 1.6 0 100 3.2 1.6 1.6 0 000-3.2z"/>
</svg>
```

### `sandwich`, Sandwich (#FF5C77)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#FF5C77">
  <path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M4 8c0-2.2 3.6-4 8-4s8 1.8 8 4H4z"/><path stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M4 11.5h16M5 15l14-1.5"/><path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M4 16h16v1a3 3 0 0 1-3 3H7a3 3 0 0 1-3-3v-1z"/>
</svg>
```

### `scissors`, Scissors (#5E6B7C)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#5E6B7C">
  <path fill="currentColor" d="M6.5 2a3.5 3.5 0 0 1 2.9 5.45L12 11l6.3-7.7a1 1 0 0 1 1.55 1.27L13.3 12.5l1.3 1.59A3.5 3.5 0 1 1 13 15.5l-1-1.2-1 1.2A3.5 3.5 0 1 1 9.4 14.1L10.7 12.5 4.45 4.55A1 1 0 0 1 5 2.9 3.49 3.49 0 0 1 6.5 2zm0 2a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3zm11 13a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3zm-11 0a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3z"/>
</svg>
```

### `sheep`, sheep (#BBD46A)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#BBD46A">
  <path fill="currentColor" fill-rule="evenodd" d="M9.5 4.2c.7 0 1.3.3 1.7.8.5-.2 1.1-.3 1.6-.3s1.1.1 1.6.3c.4-.5 1-.8 1.7-.8 1.1 0 2 .9 2 2 0 .5-.2 1-.5 1.3 1.4.8 2.4 2.3 2.4 4 0 2.1-1.4 3.8-3.3 4.4l.6 2.6c.1.5-.3.9-.8.9s-.9-.4-.9-.9v-.5h-2v.5c0 .5-.4.9-.9.9s-.9-.4-.8-.9l.1-.5h-2.2l.1.5c.1.5-.3.9-.8.9s-.9-.4-.9-.9v-.5h-2v.5c0 .5-.4.9-.9.9s-.9-.4-.8-.9l.6-2.6C4.4 15.8 3 14.1 3 12c0-1.7 1-3.2 2.4-4-.3-.3-.5-.8-.5-1.3 0-1.1.9-2 2-2 .2 0 .4 0 .6.1zM12 6.6c-1.4 0-2.6 1.2-2.6 2.6S10.6 11.8 12 11.8s2.6-1.2 2.6-2.6S13.4 6.6 12 6.6z"/>
</svg>
```

### `sink`, Sink (#5B6877)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#5B6877">
  <path fill="currentColor" d="M11 3a1 1 0 0 1 2 0v2h3a2 2 0 0 1 2 2v1a1 1 0 0 1-2 0V7h-3v3h7a1 1 0 0 1 1 1 8 8 0 0 1-3 6.24V20a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1v-1.76A8 8 0 0 1 4 12a1 1 0 0 1 1-1h6V3z"/>
</svg>
```

### `skateboard`, Skateboard (#5C5AD8)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#5C5AD8">
  <path d="M3 9 q9-3 18 0" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"/><circle cx="7.5" cy="14" r="2" fill="currentColor"/><circle cx="16.5" cy="14" r="2" fill="currentColor"/><path d="M7.5 11.8 V12.2 M16.5 11.8 V12.2" stroke="currentColor" stroke-width="1.4"/>
</svg>
```

### `skis`, Skis (#5856D6)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#5856D6">
  <g stroke="currentColor" stroke-width="2" stroke-linecap="round" fill="none"><path d="M6 21 L9 4"/><path d="M3.5 5.5 q2.5-1 5 0"/><path d="M14 21 L17 4"/><path d="M11.5 5.5 q2.5-1 5 0"/></g>
</svg>
```

### `snowboard`, Snowboard (#504ECF)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#504ECF">
  <g transform="rotate(-45 12 12)"><path fill="currentColor" fill-rule="evenodd" clip-rule="evenodd" d="M12 2.2c1.55 0 2.8 1.25 2.8 2.8v14c0 1.55-1.25 2.8-2.8 2.8S9.2 20.55 9.2 19V5c0-1.55 1.25-2.8 2.8-2.8zm0 1.8c-.66 0-1.2.54-1.2 1.2v2.55h2.4V5.2c0-.66-.54-1.2-1.2-1.2zm1.2 5.95h-2.4v4.1h2.4v-4.1zm0 5.5h-2.4V19c0 .66.54 1.2 1.2 1.2s1.2-.54 1.2-1.2v-2.55z"/></g>
</svg>
```

### `spoon`, Spoon (#FF879B)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#FF879B">
  <path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" d="M12 3c2.5 0 4 2 4 4.5S14.5 12 12 12s-4-2-4-4.5S9.5 3 12 3z"/><path stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M12 12v9"/>
</svg>
```

### `sports_ball`, Sports ball (#7472E6)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#7472E6">
  <circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M12 3.5c-3.2 2.3-3.2 14.7 0 17M12 3.5c3.2 2.3 3.2 14.7 0 17M3.6 9.2c4 1.7 12.8 1.7 16.8 0M4.2 16c4-1.7 11.6-1.7 15.6 0" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>
</svg>
```

### `stop_sign`, stop_sign (#83838A)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#83838A">
  <polygon points="8.5,3 15.5,3 21,8.5 21,15.5 15.5,21 8.5,21 3,15.5 3,8.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/><rect x="7.5" y="10.5" width="9" height="3" rx="0.6" fill="currentColor"/>
</svg>
```

### `suitcase`, Suitcase (#C7AC78)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#C7AC78">
  <path fill="currentColor" d="M9 4a2 2 0 0 0-2 2v1H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-2V6a2 2 0 0 0-2-2H9zm0 2h6v1H9V6zM4.5 9.5h15V20H4.5V9.5zm4 1.5a.75.75 0 0 0-.75.75v6a.75.75 0 0 0 1.5 0v-6A.75.75 0 0 0 8.5 11zm7 0a.75.75 0 0 0-.75.75v6a.75.75 0 0 0 1.5 0v-6a.75.75 0 0 0-.75-.75z"/>
</svg>
```

### `surfboard`, Surfboard (#6664E2)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#6664E2">
  <path fill="currentColor" fill-rule="evenodd" d="M5 19C3 11 9 3 13 4c4 1 4 10-4 16-1.5 1-3 1-4-1Zm2.6-2.2 6-9c.3-.45.18-1.05-.27-1.35-.45-.3-1.05-.18-1.35.27l-6 9c-.3.45-.18 1.05.27 1.35.45.3 1.05.18 1.35-.27Z" clip-rule="evenodd"/>
</svg>
```

### `teddy_bear`, Teddy bear (#B89A5E)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#B89A5E">
  <path fill="currentColor" d="M7.5 4.2a2.3 2.3 0 0 0-1.6 3.94A4.5 4.5 0 0 0 5 10.5c0 1.9 1.27 3.5 3.06 4.2A2.5 2.5 0 0 0 8 15.5c0 .9.42 1.7 1.07 2.2A2.5 2.5 0 0 0 8.5 19a2.5 2.5 0 0 0 2.5 2.5h2A2.5 2.5 0 0 0 15.5 19c0-.47-.13-.9-.35-1.28A2.74 2.74 0 0 0 16 15.5c0-.28-.02-.54-.06-.8A4.51 4.51 0 0 0 19 10.5c0-.86-.24-1.66-.65-2.35A2.3 2.3 0 1 0 15.1 4.8 4.5 4.5 0 0 0 12 3.6a4.5 4.5 0 0 0-3.1 1.2 2.29 2.29 0 0 0-1.4-.6zM10 9.5a1 1 0 1 1 0 2 1 1 0 0 1 0-2zm4 0a1 1 0 1 1 0 2 1 1 0 0 1 0-2zm-2 2.5c.7 0 1.3.4 1.6 1h-3.2c.3-.6.9-1 1.6-1z"/>
</svg>
```

### `tennis_racket`, Tennis racket (#46449E)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#46449E">
  <ellipse cx="9.5" cy="9.5" rx="6" ry="7" fill="none" stroke="currentColor" stroke-width="2" transform="rotate(-40 9.5 9.5)"/><path d="M14 14 L20 20" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"/><path d="M6.5 6.5 L13 13 M5 10 L11 5" stroke="currentColor" stroke-width="0.9" opacity="0.55"/>
</svg>
```

### `tie`, Tie (#A88A4B)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#A88A4B">
  <path fill="currentColor" d="M10.2 2h3.6a1 1 0 0 1 .95 1.32l-.7 2.1 1.86 8.36a1 1 0 0 1-.24.9l-2.94 3.1a1 1 0 0 1-1.45 0l-2.94-3.1a1 1 0 0 1-.24-.9l1.86-8.36-.7-2.1A1 1 0 0 1 10.2 2zm1.1 4.3-1.6 7.2L12 16.1l2.3-2.6-1.6-7.2h-1.4z"/>
</svg>
```

### `toaster`, Toaster (#5F6B7A)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#5F6B7A">
  <path fill="currentColor" d="M3 11a3 3 0 0 1 3-3h12a3 3 0 0 1 3 3v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-6zm5-5.5a1 1 0 0 1 1 1V8H7V6.5a1 1 0 0 1 1-1zm4 0a1 1 0 0 1 1 1V8h-2V6.5a1 1 0 0 1 1-1zm5.5 6.5a1 1 0 0 0-1 1v3a1 1 0 0 0 2 0v-3a1 1 0 0 0-1-1z"/>
</svg>
```

### `toilet`, Toilet (#5C6776)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#5C6776">
  <path fill="currentColor" d="M6 3h2a1 1 0 0 1 1 1v4h7a1 1 0 0 1 1 1v1a6 6 0 0 1-4 5.66V19h1a1 1 0 0 1 0 2H9a1 1 0 0 1 0-2h1v-3.34A6 6 0 0 1 7 11V4H6a1 1 0 0 1 0-2z"/>
</svg>
```

### `toothbrush`, Toothbrush (#606D7E)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#606D7E">
  <path fill="currentColor" d="M4.2 4.1a1 1 0 0 1 1.32-.5l3.4 1.5a3 3 0 0 1 1.6 1.7l.9 2.5 8.86 9.93a1.5 1.5 0 0 1-2.24 2L9.6 11.6 7.1 10.7a3 3 0 0 1-1.7-1.6L4 5.7a1 1 0 0 1 .2-1.6zm2.3 1.9 1 2.8a1 1 0 0 0 .57.55l1.4.5-.5-1.4a1 1 0 0 0-.53-.57z"/>
</svg>
```

### `traffic_light`, traffic_light (#8E8E93)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#8E8E93">
  <rect x="8.5" y="3" width="7" height="15" rx="2.2" fill="none" stroke="currentColor" stroke-width="1.8"/><circle cx="12" cy="6.5" r="1.4" fill="currentColor"/><circle cx="12" cy="10.5" r="1.4" fill="currentColor"/><circle cx="12" cy="14.5" r="1.4" fill="currentColor"/><path d="M12 18v3" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>
</svg>
```

### `train`, train (#FF8242)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#FF8242">
  <path fill="currentColor" d="M7 3c-2.2 0-4 1.8-4 4v8c0 1.66 1.34 3 3 3l-1.3 1.3c-.2.2-.06.55.22.55h1.66c.2 0 .39-.08.53-.22L8.83 18h6.34l1.69 1.63c.14.14.33.22.53.22h1.66c.28 0 .42-.35.22-.55L18 18c1.66 0 3-1.34 3-3V7c0-2.2-1.8-4-4-4H7zm-1.5 13c-.83 0-1.5-.67-1.5-1.5S4.67 13 5.5 13s1.5.67 1.5 1.5S6.33 16 5.5 16zM11 11H5V7h6v4zm2 0V7h6v4h-6zm5.5 5c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5z"/>
</svg>
```

### `truck`, truck (#D97A00)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#D97A00">
  <path fill="currentColor" d="M3 6.5C3 5.67 3.67 5 4.5 5h8c.83 0 1.5.67 1.5 1.5V9h3.26c.6 0 1.15.36 1.39.91l1.74 4.06c.1.24.16.5.16.76V16c0 .55-.45 1-1 1h-.54a2.5 2.5 0 0 1-4.92 0H9.96a2.5 2.5 0 0 1-4.92 0H4.5C3.67 17 3 16.33 3 15.5v-9zM14 10.5V15h.04a2.5 2.5 0 0 1 4.5-.5H19v-.83L17.43 10.5H14zM6.5 16.5a1 1 0 1 0 2 0 1 1 0 0 0-2 0zm10 0a1 1 0 1 0 2 0 1 1 0 0 0-2 0z"/>
</svg>
```

### `tv`, TV (#647183)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#647183">
  <rect x="3" y="4" width="18" height="12" rx="1.5" fill="currentColor"/><path fill="currentColor" d="M8 19a1 1 0 0 1 1-1h6a1 1 0 0 1 0 2H9a1 1 0 0 1-1-1z"/>
</svg>
```

### `umbrella`, Umbrella (#CBAE73)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#CBAE73">
  <path fill="currentColor" d="M12 2a9 9 0 0 0-9 9 .8.8 0 0 0 .8.8c.45 0 .82-.3 1.1-.6.45-.5 1-.8 1.6-.8s1.15.3 1.6.8c.3.32.68.6 1.1.6s.8-.28 1.1-.6c.18-.2.38-.36.6-.48V19a2 2 0 0 1-4 0 1 1 0 1 0-2 0 4 4 0 0 0 8 0v-8.08c.22.12.42.28.6.48.3.32.68.6 1.1.6s.8-.28 1.1-.6c.45-.5 1-.8 1.6-.8s1.15.3 1.6.8c.28.3.65.6 1.1.6a.8.8 0 0 0 .8-.8 9 9 0 0 0-9-9zm0 2a7 7 0 0 1 5.4 2.55A4 4 0 0 0 16 6c-.9 0-1.72.3-2.4.8A3.96 3.96 0 0 0 12 6c-.6 0-1.15.13-1.6.36A3.97 3.97 0 0 0 8 6c-.5 0-.97.09-1.4.25A7 7 0 0 1 12 4z"/>
</svg>
```

### `ups`, UPS (#8A6233)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#8A6233">
  <path fill="currentColor" d="M12 2.2l-7 2.7v7.3c0 4 2.85 6.6 7 8.6 4.15-2 7-4.6 7-8.6V4.9L12 2.2zm0 2.1l5 1.95v6.25c0 2.95-1.95 4.95-5 6.5-3.05-1.55-5-3.55-5-6.5V6.25L12 4.3zm-2.4 3.4v5c0 1.5 1 2.4 2.4 2.4s2.4-.9 2.4-2.4v-5h-1.6v5c0 .55-.3.85-.8.85s-.8-.3-.8-.85v-5H9.6z"/>
</svg>
```

### `usps`, USPS (#7A5C8A)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#7A5C8A">
  <path fill="currentColor" d="M3 16l8.7-9.2c.2-.2.55-.05.5.25L11 11h9.3c.35 0 .5.45.2.65L4.2 16.8c-.4.25-.85-.3-.55-.65L3 16z"/><path fill="currentColor" d="M3.6 17.5h17v1.4h-17z"/>
</svg>
```

### `vase`, Vase (#596574)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#596574">
  <path fill="currentColor" d="M8 3h8a1 1 0 0 1 .96 1.28l-1 3.4a1 1 0 0 0 .04.64C16.64 9.5 17 11.2 17 13a5 5 0 0 1-10 0c0-1.8.36-3.5 1-4.68a1 1 0 0 0 .04-.64l-1-3.4A1 1 0 0 1 8 3zm2.2 2 .6 2h2.4l.6-2z"/>
</svg>
```

### `wine_glass`, Wine glass (#FF4F6E)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#FF4F6E">
  <path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" d="M7 3h10l-1 5a5 5 0 0 1-8 0L7 3z"/><path stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M12 13v7M8 21h8"/>
</svg>
```

### `zebra`, zebra (#34B5C4)

```svg
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="color:#34B5C4">
  <path fill="currentColor" d="M5 19c-.4 0-.8-.3-.9-.7-.6-2.4 0-4.9 1.6-6.8l3-3.5V5.5c0-.6.3-1 .8-1.2.5-.2 1 0 1.4.4l1.4 1.6 2.7.5c2.1.4 3.7 2.1 4 4.2l.5 3.6c.1.6-.2 1.1-.7 1.3-.5.2-1.1 0-1.4-.5l-.8-1.3v3.6c0 .5-.4.9-.9.9h-1c-.3 0-.5-.2-.5-.5l-.3-3.6-2.1.3-.6 3.5c0 .3-.3.5-.6.5H8c-.4 0-.6-.4-.5-.7l.7-3.3-1.7 1.9c-.4.5-.5 1-.5 1.6 0 .4-.3.8-.7.8H5zm5.6-11.2-.3 1.9 1.5-.6-1.2-1.3zm3.6 2.1.7 1.7 1.4-.7-.6-.8-1.5-.2zm-4 1.4-.9 1.6 1.6-.3.3-1.6-1 .3zm3.1.4-.4 1.7 1.6-.2-.3-1.6-.9.1z"/>
</svg>
```

