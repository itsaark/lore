import CoreLocation
import Foundation
import WeatherKit

protocol MetadataService {
    func makeCaptureMetadata(captureDate: Date) async -> StoryMetadata
}

struct LocalMetadataService: MetadataService {
    var timezoneProvider: () -> TimeZone
    var locationCaptureProvider: () async -> MetadataLocationCapture
    var locationNameProvider: (CLLocation) async -> String?
    var weatherCaptureProvider: (CLLocation) async -> MetadataWeatherCapture?

    init(
        timezoneProvider: @escaping () -> TimeZone = { .current },
        locationCaptureProvider: @escaping () async -> MetadataLocationCapture = {
            await CoreLocationCaptureProvider().captureLocation()
        },
        locationNameProvider: @escaping (CLLocation) async -> String? = { location in
            await CoreLocationPlaceNameProvider().placeName(for: location)
        },
        weatherCaptureProvider: @escaping (CLLocation) async -> MetadataWeatherCapture? = { location in
            await WeatherKitMetadataProvider().captureWeather(for: location)
        }
    ) {
        self.timezoneProvider = timezoneProvider
        self.locationCaptureProvider = locationCaptureProvider
        self.locationNameProvider = locationNameProvider
        self.weatherCaptureProvider = weatherCaptureProvider
    }

    func makeCaptureMetadata(captureDate: Date) async -> StoryMetadata {
        let timezone = timezoneProvider()
        let locationCapture = await locationCaptureProvider()
        let weatherCapture: MetadataWeatherCapture?
        let locationName: String?
        let weatherStatus: String

        if let location = locationCapture.location {
            if let capturedLocationName = locationCapture.locationName {
                locationName = capturedLocationName
            } else {
                locationName = await locationNameProvider(location)
            }
            weatherCapture = await weatherCaptureProvider(location)
            weatherStatus = weatherCapture == nil ? "unavailable" : "available"
        } else {
            locationName = nil
            weatherCapture = nil
            weatherStatus = locationCapture.captureStatus == .permissionDenied ? "notRequested" : "unavailable"
        }

        let snapshot = MetadataPermissionSnapshot(
            locationAuthorizationStatus: locationCapture.authorizationStatus.snapshotValue,
            locationCaptureStatus: locationCapture.captureStatus.rawValue,
            weatherStatus: weatherStatus
        )

        return StoryMetadata(
            captureDate: captureDate,
            timezone: timezone.identifier,
            locationName: locationName,
            latitude: locationCapture.location?.coordinate.latitude,
            longitude: locationCapture.location?.coordinate.longitude,
            weatherSummary: weatherCapture?.summary,
            temperature: weatherCapture?.temperatureCelsius,
            weatherSource: weatherCapture?.source,
            permissionSnapshot: snapshot.encodedString
        )
    }
}

struct MetadataLocationCapture: Equatable {
    var authorizationStatus: CLAuthorizationStatus
    var captureStatus: MetadataLocationCaptureStatus
    var location: CLLocation?
    var locationName: String?

    init(
        authorizationStatus: CLAuthorizationStatus,
        captureStatus: MetadataLocationCaptureStatus,
        location: CLLocation? = nil,
        locationName: String? = nil
    ) {
        self.authorizationStatus = authorizationStatus
        self.captureStatus = captureStatus
        self.location = location
        self.locationName = locationName
    }
}

enum MetadataLocationCaptureStatus: String, Codable, Equatable, Sendable {
    case captured
    case permissionDenied
    case unavailable
}

struct MetadataWeatherCapture: Equatable, Sendable {
    var summary: String
    var temperatureCelsius: Double
    var source: String
}

struct MetadataPermissionSnapshot: Codable, Equatable, Sendable {
    var locationAuthorizationStatus: String
    var locationCaptureStatus: String
    var weatherStatus: String

    var encodedString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "location=\(locationAuthorizationStatus);capture=\(locationCaptureStatus);weather=\(weatherStatus)"
        }

        return string
    }
}

private final class CoreLocationCaptureProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<MetadataLocationCapture, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    func captureLocation() async -> MetadataLocationCapture {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            handleAuthorizationStatus(manager.authorizationStatus)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorizationStatus(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finish(status: manager.authorizationStatus, captureStatus: .unavailable)
            return
        }

        finish(status: manager.authorizationStatus, captureStatus: .captured, location: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        finish(status: manager.authorizationStatus, captureStatus: .unavailable)
    }

    private func handleAuthorizationStatus(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish(status: status, captureStatus: .permissionDenied)
        @unknown default:
            finish(status: status, captureStatus: .unavailable)
        }
    }

    private func finish(
        status: CLAuthorizationStatus,
        captureStatus: MetadataLocationCaptureStatus,
        location: CLLocation? = nil
    ) {
        guard let continuation else { return }

        self.continuation = nil
        manager.delegate = nil
        continuation.resume(returning: MetadataLocationCapture(
            authorizationStatus: status,
            captureStatus: captureStatus,
            location: location
        ))
    }
}

private struct CoreLocationPlaceNameProvider {
    func placeName(for location: CLLocation) async -> String? {
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
            return nil
        }

        return [
            placemark.locality,
            placemark.administrativeArea,
            placemark.country
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

private struct WeatherKitMetadataProvider {
    func captureWeather(for location: CLLocation) async -> MetadataWeatherCapture? {
        guard let weather = try? await WeatherService.shared.weather(for: location) else {
            return nil
        }

        let currentWeather = weather.currentWeather
        return MetadataWeatherCapture(
            summary: String(describing: currentWeather.condition),
            temperatureCelsius: currentWeather.temperature.converted(to: .celsius).value,
            source: "WeatherKit"
        )
    }
}

private extension CLAuthorizationStatus {
    var snapshotValue: String {
        switch self {
        case .notDetermined:
            return "notDetermined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorizedAlways:
            return "authorizedAlways"
        case .authorizedWhenInUse:
            return "authorizedWhenInUse"
        @unknown default:
            return "unknown"
        }
    }
}
