//
//  loreTests.swift
//  loreTests
//
//  Created by Aark Koduru on 7/18/25.
//

import Testing
import Foundation
@testable import lore

struct loreTests {

    @Test func storyDecodesLegacyPayloadWithoutID() throws {
        let json = """
        {
            "text": "A childhood memory from Hyderabad.",
            "date": 742694400,
            "duration": 75
        }
        """

        let data = try #require(json.data(using: .utf8))
        let story = try JSONDecoder().decode(Story.self, from: data)

        #expect(story.text == "A childhood memory from Hyderabad.")
        #expect(story.duration == 75)
    }

    @Test func storyKeepsStableDecodedID() throws {
        let id = UUID()
        let story = Story(id: id, text: "Today felt quieter than usual.", date: Date(), duration: 12)
        let data = try JSONEncoder().encode(story)
        let decodedStory = try JSONDecoder().decode(Story.self, from: data)

        #expect(decodedStory.id == id)
    }

    @Test func userProfileRoundTrips() throws {
        let profile = UserProfile(name: "Aark", hometown: "Hyderabad", birthYear: 1994)
        let data = try JSONEncoder().encode(profile)
        let decodedProfile = try JSONDecoder().decode(UserProfile.self, from: data)

        #expect(decodedProfile == profile)
    }

}
