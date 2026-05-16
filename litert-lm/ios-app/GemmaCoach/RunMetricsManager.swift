// RunMetricsManager.swift
// Tracks live GPS and Motion data for the running coach.

import Foundation
import CoreLocation
import CoreMotion
import CoreBluetooth

@MainActor
final class RunMetricsManager: NSObject, ObservableObject, CLLocationManagerDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var currentPaceSecondsPerMeter: Double = 0
    @Published var currentCadenceSPM: Double = 0
    @Published var currentHeartRateBPM: Int = 0
    @Published var currentElevationMeters: Double = 0
    @Published var isActive: Bool = false
    
    private let locationManager = CLLocationManager()
    private let pedometer = CMPedometer()
    private let altimeter = CMAltimeter()
    private var centralManager: CBCentralManager!
    private var hrPeripheral: CBPeripheral?
    private var mockTimer: Timer?
    
    let hrServiceUUID = CBUUID(string: "180D")
    let hrMeasurementUUID = CBUUID(string: "2A37")
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 5 // Update every 5 meters
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func start() {
        guard !isActive else { return }
        
        #if targetEnvironment(simulator)
        // MOCK DATA FOR XCODE SIMULATOR
        mockTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Random mock speed (roughly 6:00/mi to 10:00/mi pace)
                let randomSpeedMetersPerSec = Double.random(in: 2.6...4.4)
                self?.currentPaceSecondsPerMeter = 1.0 / randomSpeedMetersPerSec
                
                // Random mock cadence
                self?.currentCadenceSPM = Double.random(in: 150...180)
                
                // Random mock heart rate
                self?.currentHeartRateBPM = Int.random(in: 130...190)
                
                // Random mock elevation change
                self?.currentElevationMeters = Double.random(in: -5...15)
            }
        }
        #else
        // REAL HARDWARE
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
        
        // Start Altimeter (Barometer)
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
                guard let data = data, error == nil else { return }
                Task { @MainActor in
                    self?.currentElevationMeters = data.relativeAltitude.doubleValue
                }
            }
        }
        
        // Start Heart Rate Scan
        if centralManager.state == .poweredOn {
            centralManager.scanForPeripherals(withServices: [hrServiceUUID])
        }
        #endif
        
        isActive = true
    }
    
    func stop() {
        #if targetEnvironment(simulator)
        mockTimer?.invalidate()
        mockTimer = nil
        #else
        locationManager.stopUpdatingLocation()
        pedometer.stopUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        centralManager.stopScan()
        if let p = hrPeripheral {
            centralManager.cancelPeripheralConnection(p)
        }
        #endif
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
        Heart Rate: \(currentHeartRateBPM > 0 ? "\(currentHeartRateBPM) BPM" : "Searching...")
        Pace: \(formattedPace)
        Cadence: \(Int(currentCadenceSPM)) steps per minute
        Elevation Change: \(String(format: "%.1f", currentElevationMeters)) meters
        """
    }
    
    // MARK: - CBCentralManagerDelegate
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Automatically handled in start()
    }
    
    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            self.hrPeripheral = peripheral
            self.hrPeripheral?.delegate = self
            self.centralManager.connect(peripheral)
        }
    }
    
    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Task { @MainActor in self.hrServiceUUID }.value])
    }
    
    // MARK: - CBPeripheralDelegate
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics([Task { @MainActor in self.hrMeasurementUUID }.value], for: service)
        }
    }
    
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            if characteristic.uuid == Task({ @MainActor in self.hrMeasurementUUID }).value {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }
    
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        // The first byte determines the format (8-bit or 16-bit).
        let flags = data[0]
        let format = flags & 0x01
        let bpm = format == 0 ? Int(data[1]) : Int(data[1]) + (Int(data[2]) << 8)
        
        Task { @MainActor in
            self.currentHeartRateBPM = bpm
        }
    }
}
