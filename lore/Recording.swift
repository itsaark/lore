import Foundation

/// Model representing a single recording entry
struct Recording: Identifiable, Codable, Equatable {
    let id = UUID()
    var text: String
    let date: Date
    let duration: TimeInterval // in seconds
    
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
    
    /// Equatable implementation to compare recordings
    static func == (lhs: Recording, rhs: Recording) -> Bool {
        return lhs.id == rhs.id
    }
}