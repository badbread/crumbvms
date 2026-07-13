// Icon + color mapping for detection `icon_key` values (see
// services/api/src/dto.rs `DetectionEventDto.icon_key` — the per-label slug
// contract: "person", "car", "truck", "bus", "bicycle", "cat", "dog",
// "license_plate", "face", "package", …). Any key not listed here falls back
// to a neutral generic marker so unknown/future labels still render.
//
// Deliberately a curated Material-Icons mapping rather than the old client's
// bespoke 100+ inline-SVG glyph set (apps/desktop/src/app.js DETECTION_ICONS)
// — same idea (color-coded per-label icon), simpler and dependency-free.

import 'package:flutter/material.dart';

class DetectionIconSpec {
  const DetectionIconSpec(this.icon, this.color);
  final IconData icon;
  final Color color;
}

const Map<String, DetectionIconSpec> kDetectionIcons = {
  'person': DetectionIconSpec(Icons.person, Color(0xFF33C3FF)),
  'car': DetectionIconSpec(Icons.directions_car, Color(0xFFFF9500)),
  'truck': DetectionIconSpec(Icons.local_shipping, Color(0xFFD97A00)),
  'bus': DetectionIconSpec(Icons.directions_bus, Color(0xFFFF6B22)),
  'bicycle': DetectionIconSpec(Icons.pedal_bike, Color(0xFFFFCC00)),
  'motorcycle': DetectionIconSpec(Icons.two_wheeler, Color(0xFFFFB143)),
  'cat': DetectionIconSpec(Icons.pets, Color(0xFF2BA84A)),
  'dog': DetectionIconSpec(Icons.pets, Color(0xFF34B5C4)),
  'bird': DetectionIconSpec(Icons.flutter_dash, Color(0xFF5AC8FA)),
  'package': DetectionIconSpec(Icons.inventory_2, Color(0xFFC7AC78)),
  'license_plate': DetectionIconSpec(Icons.pin, Color(0xFFFFB143)),
  'face': DetectionIconSpec(Icons.face, Color(0xFF33C3FF)),
  // Legacy grouped keys from older backends (pre per-label contract).
  'vehicle': DetectionIconSpec(Icons.directions_car, Color(0xFFFF9500)),
  'animal': DetectionIconSpec(Icons.pets, Color(0xFF2BA84A)),
  'plate': DetectionIconSpec(Icons.pin, Color(0xFFFFB143)),
};

const DetectionIconSpec kGenericDetectionIcon = DetectionIconSpec(
  Icons.crop_free,
  Color(0xFF8E8E93),
);

DetectionIconSpec detectionIconFor(String key) =>
    kDetectionIcons[key] ?? kGenericDetectionIcon;
