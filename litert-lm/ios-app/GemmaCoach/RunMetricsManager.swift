// RunMetricsManager.swift
// Tracks live GPS and Motion data for the running coach.

import Foundation
import CoreLocation
import CoreMotion

@MainActor
final class RunMetricsManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var currentPaceSecondsPerMeter: Double = 0
    @Published var currentCadenceSPM: Double = 0
    @Published var isActive: Bool = false
    
    private let locationManager = CLLocationManager()
    private let pedometer = CMPedometer()
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 5 // Update every 5 meters
    }
    
    func start() {
        guard !isActive else { return }
        
        // Request Permissions & Start Location
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        
        // Start Motion
        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: Date()) { [weak self] data, error in
                guard let data = data, error == nil else { return }
                if let cadence = data.currentCadence?.doubleValue {
                    // Cadence is given in steps per second. Multiply by 60 for SPM.
                    Task { @MainActor in
                        self?.currentCadenceSPM = cadence * 60
                    }
                }
            }
        }
        
        isActive = true
    }
    
    func stop() {
        locationManager.stopUpdatingLocation()
        pedometer.stopUpdates()
        isActive = false
    }
    
    // MARK: - CLLocationManagerDelegate
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let speed = location.speed // meters per second
        Task { @MainActor in
            if speed > 0 {
                self.currentPaceSecondsPerMeter = 1.0 / speed
            } else {
                self.currentPaceSecondsPerMeter = 0
            }
        }
    }
    
    // MARK: - Formatters
    
    var formattedPace: String {
        if currentPaceSecondsPerMeter > 0 {
            // Convert sec/m to sec/mi
            let secPerMile = currentPaceSecondsPerMeter * 1609.34
            let minutes = Int(secPerMile) / 60
            let seconds = Int(secPerMile) % 60
            if minutes < 60 {
                return String(format: "%d:%02d /mi", minutes, seconds)
            }
        }
        return "Standing still"
    }
    
    func getCurrentStateString() -> String {
        return """
        Pace: \(formattedPace)
        Cadence: \(Int(currentCadenceSPM)) steps per minute
        """
    }
}
