//
//  Item.swift
//  SkillsManager
//
//  Created by Matteo Comisso on 12/06/2026.
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
