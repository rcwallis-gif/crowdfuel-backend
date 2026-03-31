//
//  Band.swift
//  CrowdFuel
//
//  Created by bob on 10/3/25.
//

import Foundation
import FirebaseFirestore

struct Band: Identifiable, Codable {
    @DocumentID var id: String?
    var name: String
    var city: String
    var logoUrl: String?
    var ownerUid: String
    var createdAt: Date
    var stripeAccountId: String?
    var stripeAccountStatus: String? // "pending", "active"
    var stripeDetailsSubmitted: Bool?
    var slug: String? // URL-friendly identifier (e.g., "aunt-betty")
    
    init(name: String, city: String, ownerUid: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed
        self.city = city
        self.ownerUid = ownerUid
        self.createdAt = Date()
        self.slug = Band.generateSlug(from: trimmed)
    }
    
    // Permanent band URL
    var permanentURL: String {
        let bandSlug = slug ?? Band.generateSlug(from: name)
        return "https://crowdfuel-86c2b.web.app/band/\(bandSlug)"
    }
    
    // Generate URL-friendly slug from band name
    static func generateSlug(from name: String) -> String {
        return name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "&", with: "and")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

struct BandMember: Identifiable, Codable {
    @DocumentID var id: String?
    var role: String // "owner" | "member"
    var sharePct: Double
    var uid: String
    
    init(uid: String, role: String, sharePct: Double = 0.0) {
        self.uid = uid
        self.role = role
        self.sharePct = sharePct
    }
}
