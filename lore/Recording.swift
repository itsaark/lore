import Foundation

/// Model representing a single captured story entry.
struct Story: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    let date: Date
    let duration: TimeInterval // in seconds

    init(id: UUID = UUID(), text: String, date: Date, duration: TimeInterval) {
        self.id = id
        self.text = text
        self.date = date
        self.duration = duration
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case date
        case duration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        date = try container.decode(Date.self, forKey: .date)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
    }
    
    /// Computed property for formatted date display
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return formatter.string(from: date)
    }
    
    /// Computed property for formatted duration display
    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
    
    /// Equatable implementation to compare stories.
    static func == (lhs: Story, rhs: Story) -> Bool {
        return lhs.id == rhs.id
    }
}
