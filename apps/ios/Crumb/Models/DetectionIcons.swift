// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

enum DetectionIcons {

    static func sfSymbol(for iconKey: String) -> String {
        switch iconKey {
        case "person": return "figure.walk"
        case "face": return "face.smiling"
        case "car": return "car.fill"
        case "truck": return "box.truck.fill"
        case "bus": return "bus.fill"
        case "license_plate": return "creditcard.fill"
        case "airplane": return "airplane"
        case "train": return "tram.fill"
        case "boat": return "ferry.fill"
        case "bicycle": return "bicycle"
        case "motorcycle": return "scooter"
        case "cat", "dog", "bird", "horse", "sheep", "cow",
             "elephant", "bear", "zebra", "giraffe",
             "raccoon", "fox", "squirrel", "deer", "rabbit",
             "skunk", "opossum", "possum", "coyote":
            return "pawprint.fill"
        case "package": return "shippingbox.fill"
        case "amazon", "ups", "fedex", "dhl", "usps", "gls", "dpd",
             "an_post", "nzpost", "purolator", "royal_mail", "postnl",
             "postnord", "canada_post":
            return "box.truck.fill"
        case "frisbee", "sports_ball": return "sportscourt.fill"
        case "baseball_bat", "baseball_glove": return "baseball.fill"
        case "tennis_racket": return "tennisball.fill"
        case "bottle", "wine_glass", "cup": return "cup.and.saucer.fill"
        case "fork", "knife", "spoon": return "fork.knife"
        case "pizza", "sandwich", "hot_dog", "donut", "cake": return "fork.knife"
        case "bench", "chair": return "chair.fill"
        case "couch", "bed": return "sofa.fill"
        case "potted_plant", "vase": return "leaf.fill"
        case "tv": return "tv.fill"
        case "laptop": return "laptopcomputer"
        case "cell_phone": return "iphone"
        case "book": return "book.fill"
        case "backpack": return "backpack.fill"
        case "umbrella": return "umbrella.fill"
        case "suitcase": return "suitcase.fill"
        case "traffic_light", "fire_hydrant", "stop_sign", "parking_meter":
            return "light.beacon.max.fill"
        // legacy grouped keys
        case "vehicle": return "car.fill"
        case "animal": return "pawprint.fill"
        case "cycle": return "bicycle"
        case "plate": return "creditcard.fill"
        default: return "circle.fill"
        }
    }

    static func color(for iconKey: String) -> Color {
        switch iconKey {
        case "person": return DetectionColors.person
        case "face": return DetectionColors.face
        case "car", "bus", "truck", "license_plate": return DetectionColors.vehicleRoad
        case "airplane", "train", "boat": return DetectionColors.vehicleOther
        case "bicycle", "motorcycle": return DetectionColors.twoWheeler
        case "cat", "dog": return DetectionColors.animalPet
        case "bird", "elephant", "bear", "zebra", "giraffe",
             "raccoon", "fox", "squirrel", "deer", "rabbit",
             "skunk", "opossum", "possum", "coyote":
            return DetectionColors.animalWild
        case "horse", "sheep", "cow": return DetectionColors.animalFarm
        case "package", "amazon", "ups", "fedex", "dhl", "usps", "gls", "dpd",
             "an_post", "nzpost", "purolator", "royal_mail", "postnl",
             "postnord", "canada_post":
            return DetectionColors.delivery
        case "frisbee", "skis", "snowboard", "sports_ball", "kite",
             "baseball_bat", "baseball_glove", "skateboard", "surfboard",
             "tennis_racket":
            return DetectionColors.sports
        case "bottle", "wine_glass", "cup", "fork", "knife", "spoon", "bowl",
             "banana", "apple", "sandwich", "orange", "broccoli", "carrot",
             "hot_dog", "pizza", "donut", "cake":
            return DetectionColors.food
        case "backpack", "umbrella", "handbag", "tie", "suitcase", "teddy_bear":
            return DetectionColors.personalItem
        case "traffic_light", "fire_hydrant", "stop_sign", "parking_meter":
            return DetectionColors.misc
        case "bench", "chair", "couch", "potted_plant", "bed", "dining_table",
             "toilet", "tv", "laptop", "mouse", "remote", "keyboard",
             "cell_phone", "microwave", "oven", "toaster", "sink",
             "refrigerator", "book", "clock", "vase", "scissors",
             "hair_drier", "toothbrush":
            return DetectionColors.household
        case "vehicle": return DetectionColors.vehicleRoad
        case "animal": return DetectionColors.animalPet
        case "cycle": return DetectionColors.twoWheeler
        case "plate": return DetectionColors.vehicleRoad
        default: return DetectionColors.generic
        }
    }
}
