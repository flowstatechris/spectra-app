//
//  Item.swift
//  spectra-app
//
//  Created by Chris Victorin on 8/26/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
