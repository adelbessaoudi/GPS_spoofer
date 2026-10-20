//
//  GPSBrowserApp.swift
//  External GPS Receiver & Network Coordinator
//
//  A native iOS application using Swift, SwiftUI, and Network.framework
//  that acts as a high-precision network GPS coordinate receiver with an Apple-style design.
//

import SwiftUI
import Foundation
import Network
import Combine

// MARK: - Application Entry Point

@main
struct GPSBrowserApp: App {
    @StateObject private var gpsManager = GPSNetworkManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(gpsManager)
        }
    }
}

// MARK: - Models & Data Structures

/// Represents a parsed GPS coordinate fix from an NMEA sentence.
struct GPSCoordinate: Equatable {
    var latitude: Double = 37.774929       // Default: San Francisco
    var longitude: Double = -122.419416
    var altitude: Double = 15.0            // Meters
    var accuracy: Double = 2.5             // Estimated accuracy in meters
    var speed: Double = 0.0                // Meters per second
    var heading: Double = 0.0              // Degrees (0-360)
    var satellites: Int = 9
    var fixQuality: String = "GPS 3D Fix"
    var timestamp: Date = Date()
    var sentenceType: String = "$GPGGA"
    
    var formattedLatitude: String {
        let direction = latitude >= 0 ? "N" : "S"
        return String(format: "%.6f° %@", abs(latitude), direction)
    }
    
    var formattedLongitude: String {
        let direction = longitude >= 0 ? "E" : "W"
        return String(format: "%.6f° %@", abs(longitude), direction)
    }
    
    var speedKmh: Double {
        speed * 3.6
    }
    
    var speedMph: Double {
        speed * 2.23694
    }
}

/// Network Connection State for the GPS stream listener.
enum NetworkConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
    
    var statusTitle: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Receiving Stream"
        case .failed: return "Connection Failed"
        }
    }
    
    var statusColor: Color {
        switch self {
        case .disconnected: return Color.gray
        case .connecting: return Color.orange
        case .connected: return Color.green
        case .failed: return Color.red
        }
    }
}

/// Transport protocol option for the network stream.
enum TransportProtocol: String, CaseIterable, Identifiable {
    case tcp = "TCP"
    case udp = "UDP"
    var id: String { rawValue }
}

// MARK: - NMEA 0183 Parser

/// Robust parser for NMEA 0183 GPS sentences ($GPGGA, $GNGGA, $GPRMC, $GNRMC).
final class NMEAParser {
    
    static func parse(sentence: String, existing: GPSCoordinate) -> GPSCoordinate? {
        let clean = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("$") || clean.hasPrefix("!") else { return nil }
        
        // Strip checksum if present (*XX)
        let body: String
        if let asteriskIndex = clean.firstIndex(of: "*") {
            body = String(clean[clean.startIndex..<asteriskIndex])
        } else {
            body = clean
        }
        
        let tokens = body.components(separatedBy: ",")
        guard let header = tokens.first, tokens.count > 6 else { return nil }
        
        if header.hasSuffix("GGA") {
            return parseGGA(tokens: tokens, existing: existing)
        } else if header.hasSuffix("RMC") {
            return parseRMC(tokens: tokens, existing: existing)
        }
        return nil
    }
    
    private static func parseGGA(tokens: [String], existing: GPSCoordinate) -> GPSCoordinate? {
        guard tokens.count > 9 else { return nil }
        let rawLat = tokens[2]
        let latDir = tokens[3].uppercased()
        let rawLon = tokens[4]
        let lonDir = tokens[5].uppercased()
        let fixCode = Int(tokens[6]) ?? 0
        let satellites = Int(tokens[7]) ?? 0
        let hdop = Double(tokens[8]) ?? 1.0
        let altitude = Double(tokens[9]) ?? existing.altitude
        
        guard fixCode > 0, !rawLat.isEmpty, !rawLon.isEmpty,
              let lat = convertDMStoDecimal(raw: rawLat, direction: latDir, isLatitude: true),
              let lon = convertDMStoDecimal(raw: rawLon, direction: lonDir, isLatitude: false) else {
            return nil
        }
        
        var fixName = "GPS 3D Fix"
        if fixCode == 2 { fixName = "DGPS Fix" }
        else if fixCode == 4 { fixName = "RTK Fix" }
        else if fixCode == 5 { fixName = "Float RTK" }
        
        var coord = existing
        coord.latitude = lat
        coord.longitude = lon
        coord.altitude = altitude
        coord.accuracy = max(0.5, hdop * 2.2)
        coord.satellites = satellites
        coord.fixQuality = fixName
        coord.sentenceType = tokens[0]
        coord.timestamp = Date()
        return coord
    }
    
    private static func parseRMC(tokens: [String], existing: GPSCoordinate) -> GPSCoordinate? {
        guard tokens.count > 8, tokens[2].uppercased() == "A" else { return nil }
        let rawLat = tokens[3]
        let latDir = tokens[4].uppercased()
        let rawLon = tokens[5]
        let lonDir = tokens[6].uppercased()
        let speedKnots = Double(tokens[7]) ?? 0.0
        let headingDeg = Double(tokens[8]) ?? existing.heading
        
        guard let lat = convertDMStoDecimal(raw: rawLat, direction: latDir, isLatitude: true),
              let lon = convertDMStoDecimal(raw: rawLon, direction: lonDir, isLatitude: false) else {
            return nil
        }
        
        var coord = existing
        coord.latitude = lat
        coord.longitude = lon
        coord.speed = speedKnots * 0.514444 // knots to m/s
        coord.heading = headingDeg
        coord.fixQuality = "Active GNSS"
        coord.sentenceType = tokens[0]
        coord.timestamp = Date()
        return coord
    }
    
    private static func convertDMStoDecimal(raw: String, direction: String, isLatitude: Bool) -> Double? {
        let degreeDigits = isLatitude ? 2 : 3
        guard raw.count >= degreeDigits + 2 else { return nil }
        
        let degEndIndex = raw.index(raw.startIndex, offsetBy: degreeDigits)
        let degStr = String(raw[raw.startIndex..<degEndIndex])
        let minStr = String(raw[degEndIndex..<raw.endIndex])
        
        guard let degrees = Double(degStr), let minutes = Double(minStr) else { return nil }
        var decimal = degrees + (minutes / 60.0)
        if direction == "S" || direction == "W" { decimal = -decimal }
        return decimal
    }
}

// MARK: - Network GPS Manager (NWConnection)

@MainActor
final class GPSNetworkManager: ObservableObject {
    @Published var ipAddress: String = "192.168.4.1"
    @Published var portString: String = "10110"
    @Published var selectedProtocol: TransportProtocol = .tcp
    @Published var connectionState: NetworkConnectionState = .disconnected
    @Published var currentCoordinate: GPSCoordinate = GPSCoordinate()
    @Published var packetsReceivedCount: Int = 0
    @Published var lastRawSentence: String = ""
    @Published var autoReconnect: Bool = true
    
    private var connection: NWConnection?
    private let networkQueue = DispatchQueue(label: "com.gpsreceiver.network", qos: .userInitiated)
    private var streamBuffer = ""
    private var reconnectWorkItem: DispatchWorkItem?
    
    func toggleConnection() {
        if connectionState == .connected || connectionState == .connecting {
            disconnect()
        } else {
            connect()
        }
    }
    
    func connect() {
        cancelReconnect()
        disconnectCurrentConnection()
        
        guard let portNumber = UInt16(portString), let nwPort = NWEndpoint.Port(rawValue: portNumber) else {
            self.connectionState = .failed("Invalid Port")
            return
        }
        
        let nwHost = NWEndpoint.Host(ipAddress)
        let parameters: NWParameters = (selectedProtocol == .tcp) ? .tcp : .udp
        parameters.includePeerToPeer = true
        
        self.connectionState = .connecting
        let conn = NWConnection(host: nwHost, port: nwPort, using: parameters)
        self.connection = conn
        
        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { self?.handleStateUpdate(state) }
        }
        
        conn.start(queue: networkQueue)
        startReceiveLoop(on: conn)
    }
    
    func disconnect() {
        cancelReconnect()
        disconnectCurrentConnection()
        self.connectionState = .disconnected
    }
    
    private func disconnectCurrentConnection() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        streamBuffer = ""
    }
    
    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }
    
    private func scheduleReconnect() {
        guard autoReconnect else { return }
        cancelReconnect()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.connectionState != .connected else { return }
            self.connect()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }
    
    private func handleStateUpdate(_ state: NWConnection.State) {
        switch state {
        case .ready:
            self.connectionState = .connected
        case .preparing:
            self.connectionState = .connecting
        case .waiting(let error):
            self.connectionState = .failed(error.localizedDescription)
            scheduleReconnect()
        case .failed(let error):
            self.connectionState = .failed(error.localizedDescription)
            scheduleReconnect()
        case .cancelled:
            if case .failed = connectionState { } else { self.connectionState = .disconnected }
        @unknown default:
            break
        }
    }
    
    private func startReceiveLoop(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak conn] content, _, isComplete, error in
            guard let self = self, let activeConn = conn, activeConn === self.connection else { return }
            
            if let data = content, !data.isEmpty, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
                self.networkQueue.async { self.processIncomingStream(text) }
            }
            if isComplete || error != nil {
                DispatchQueue.main.async {
                    if let error = error { self.connectionState = .failed(error.localizedDescription) }
                    else { self.connectionState = .disconnected }
                    self.scheduleReconnect()
                }
                return
            }
            self.startReceiveLoop(on: activeConn)
        }
    }
    
    private func processIncomingStream(_ chunk: String) {
        streamBuffer.append(chunk)
        var lines = streamBuffer.components(separatedBy: "\n")
        streamBuffer = lines.removeLast()
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            
            if trimmed.hasPrefix("$") || trimmed.hasPrefix("!") {
                if let newCoord = NMEAParser.parse(sentence: trimmed, existing: currentCoordinate) {
                    DispatchQueue.main.async {
                        self.currentCoordinate = newCoord
                        self.packetsReceivedCount += 1
                        self.lastRawSentence = trimmed
                    }
                }
            } else if trimmed.contains(",") {
                // Support quick CSV testing: "37.7749,-122.4194"
                let parts = trimmed.components(separatedBy: ",")
                if parts.count >= 2, let lat = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                   let lon = Double(parts[1].trimmingCharacters(in: .whitespaces)) {
                    DispatchQueue.main.async {
                        var coord = self.currentCoordinate
                        coord.latitude = lat
                        coord.longitude = lon
                        coord.fixQuality = "Manual CSV"
                        coord.sentenceType = "RAW_CSV"
                        self.currentCoordinate = coord
                        self.packetsReceivedCount += 1
                        self.lastRawSentence = trimmed
                    }
                }
            }
        }
    }
    
    func injectTestCoordinate(lat: Double, lon: Double, name: String = "Simulated Fix") {
        var coord = currentCoordinate
        coord.latitude = lat
        coord.longitude = lon
        coord.fixQuality = name
        coord.sentenceType = "$SIM"
        coord.timestamp = Date()
        self.currentCoordinate = coord
        self.packetsReceivedCount += 1
        self.lastRawSentence = "$SIM,\(lat),\(lon),MOCK*00"
    }
}

// MARK: - Apple-Style SwiftUI User Interface

struct ContentView: View {
    @EnvironmentObject var gpsManager: GPSNetworkManager
    @State private var isConfigExpanded: Bool = true
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 16) {
                        // 1. Connection Status Banner
                        statusHeaderCard
                        
                        // 2. Hero Coordinates Display Card
                        heroCoordinateCard
                        
                        // 3. Apple-style Radar Target Visualizer
                        radarVisualizerCard
                        
                        // 4. Telemetry Metrics 4x Grid
                        telemetryMetricsGrid
                        
                        // 5. Network Configuration Card
                        networkConfigurationCard
                        
                        // 6. Network Stream & NMEA Inspector Card
                        streamInspectorCard
                        
                        // 7. Test Simulator Controls
                        simulatorPresetsCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 36)
                }
            }
            .navigationTitle("GPS Receiver")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    // MARK: - 1. Status Header Card
    private var statusHeaderCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(gpsManager.connectionState.statusColor)
                    .frame(width: 14, height: 14)
                
                if gpsManager.connectionState == .connected {
                    Circle()
                        .stroke(gpsManager.connectionState.statusColor.opacity(0.4), lineWidth: 4)
                        .scaleEffect(1.8)
                        .opacity(0.0)
                        .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: gpsManager.connectionState == .connected)
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(gpsManager.connectionState.statusTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                
                Text("\(gpsManager.selectedProtocol.rawValue) • \(gpsManager.ipAddress):\(gpsManager.portString)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: {
                gpsManager.toggleConnection()
            }) {
                HStack(spacing: 5) {
                    Image(systemName: gpsManager.connectionState == .connected ? "stop.fill" : "play.fill")
                        .font(.system(size: 11))
                    Text(gpsManager.connectionState == .connected ? "Disconnect" : "Connect")
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(gpsManager.connectionState == .connected ? Color.red.opacity(0.12) : Color.blue)
                .foregroundColor(gpsManager.connectionState == .connected ? .red : .white)
                .clipShape(Capsule())
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
    }
    
    // MARK: - 2. Hero Coordinates Display Card
    private var heroCoordinateCard: some View {
        VStack(spacing: 16) {
            HStack {
                Label("LIVE COORDINATES", systemImage: "location.north.circle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.blue)
                
                Spacer()
                
                Text(gpsManager.currentCoordinate.fixQuality)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.15))
                    .foregroundColor(.green)
                    .clipShape(Capsule())
            }
            
            HStack(spacing: 12) {
                // Latitude Box
                VStack(alignment: .leading, spacing: 4) {
                    Text("LATITUDE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    Text(gpsManager.currentCoordinate.formattedLatitude)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground))
                .cornerRadius(12)
                
                // Longitude Box
                VStack(alignment: .leading, spacing: 4) {
                    Text("LONGITUDE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    Text(gpsManager.currentCoordinate.formattedLongitude)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground))
                .cornerRadius(12)
            }
            
            // Decimal Degrees row
            HStack {
                Text("Decimal: \(String(format: "%.6f", gpsManager.currentCoordinate.latitude)), \(String(format: "%.6f", gpsManager.currentCoordinate.longitude))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("Fix: \(gpsManager.currentCoordinate.sentenceType)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(18)
        .shadow(color: Color.black.opacity(0.04), radius: 8, y: 3)
    }
    
    // MARK: - 3. Apple-style Radar Target Visualizer
    private var radarVisualizerCard: some View {
        VStack(spacing: 12) {
            HStack {
                Label("SIGNAL RADAR", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Text(gpsManager.connectionState == .connected ? "LOCKED" : "STANDBY")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(gpsManager.connectionState == .connected ? .green : .secondary)
            }
            
            ZStack {
                // Radar Rings
                Circle()
                    .stroke(Color.blue.opacity(0.12), lineWidth: 1)
                    .frame(width: 140, height: 140)
                Circle()
                    .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                    .frame(width: 90, height: 90)
                Circle()
                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    .frame(width: 40, height: 40)
                
                // Crosshairs
                Rectangle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 1, height: 150)
                Rectangle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 150, height: 1)
                
                // Target Beacon
                VStack(spacing: 2) {
                    Circle()
                        .fill(gpsManager.connectionState == .connected ? Color.green : Color.blue)
                        .frame(width: 12, height: 12)
                        .shadow(color: (gpsManager.connectionState == .connected ? Color.green : Color.blue).opacity(0.6), radius: 6)
                    
                    Text(gpsManager.connectionState == .connected ? "ONLINE" : "READY")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(gpsManager.connectionState == .connected ? .green : .blue)
                }
            }
            .frame(height: 160)
            .frame(maxWidth: .infinity)
            .background(Color(.tertiarySystemGroupedBackground))
            .cornerRadius(14)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(18)
        .shadow(color: Color.black.opacity(0.04), radius: 8, y: 3)
    }
    
    // MARK: - 4. Telemetry Metrics 4x Grid
    private var telemetryMetricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            MetricCard(
                title: "ALTITUDE",
                value: String(format: "%.1f m", gpsManager.currentCoordinate.altitude),
                subtitle: String(format: "%.0f ft", gpsManager.currentCoordinate.altitude * 3.28084),
                icon: "mountain.2.fill",
                accentColor: .indigo
            )
            
            MetricCard(
                title: "SPEED",
                value: String(format: "%.1f km/h", gpsManager.currentCoordinate.speedKmh),
                subtitle: String(format: "%.1f mph", gpsManager.currentCoordinate.speedMph),
                icon: "speedometer",
                accentColor: .blue
            )
            
            MetricCard(
                title: "SATELLITES",
                value: "\(gpsManager.currentCoordinate.satellites)",
                subtitle: "GNSS in view",
                icon: "network",
                accentColor: .teal
            )
            
            MetricCard(
                title: "ACCURACY",
                value: String(format: "±%.1f m", gpsManager.currentCoordinate.accuracy),
                subtitle: "Estimated fix",
                icon: "scope",
                accentColor: .green
            )
        }
    }
    
    // MARK: - 5. Network Configuration Card
    private var networkConfigurationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("COORDINATOR CONNECTION", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: {
                    withAnimation { isConfigExpanded.toggle() }
                }) {
                    Image(systemName: isConfigExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 15))
                }
            }
            
            if isConfigExpanded {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("IP Address")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            
                            TextField("192.168.4.1", text: $gpsManager.ipAddress)
                                .keyboardType(.numbersAndPunctuation)
                                .font(.system(size: 14, design: .monospaced))
                                .padding(8)
                                .background(Color(.tertiarySystemGroupedBackground))
                                .cornerRadius(8)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Port")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            
                            TextField("10110", text: $gpsManager.portString)
                                .keyboardType(.numberPad)
                                .font(.system(size: 14, design: .monospaced))
                                .padding(8)
                                .background(Color(.tertiarySystemGroupedBackground))
                                .cornerRadius(8)
                        }
                        .frame(width: 80)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Proto")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            
                            Picker("Protocol", selection: $gpsManager.selectedProtocol) {
                                ForEach(TransportProtocol.allCases) { proto in
                                    Text(proto.rawValue).tag(proto)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .frame(width: 85)
                        }
                    }
                    
                    Toggle(isOn: $gpsManager.autoReconnect) {
                        Text("Auto Reconnect")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(18)
        .shadow(color: Color.black.opacity(0.04), radius: 8, y: 3)
    }
    
    // MARK: - 6. Stream Inspector Card
    private var streamInspectorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("NMEA TELEMETRY STREAM", systemImage: "terminal.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("\(gpsManager.packetsReceivedCount) sentences")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Text(gpsManager.lastRawSentence.isEmpty ? "Waiting for incoming NMEA sentences ($GPGGA, $GPRMC)..." : gpsManager.lastRawSentence)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(gpsManager.lastRawSentence.isEmpty ? .secondary : .primary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemGroupedBackground))
                .cornerRadius(10)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(18)
        .shadow(color: Color.black.opacity(0.04), radius: 8, y: 3)
    }
    
    // MARK: - 7. Test Simulator Controls
    private var simulatorPresetsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SIMULATE COORDINATES (TESTING)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button(action: {
                        gpsManager.injectTestCoordinate(lat: 44.9778, lon: -93.2650, name: "Minneapolis HQ")
                    }) {
                        Text("📍 Minneapolis")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .foregroundColor(.primary)
                            .clipShape(Capsule())
                    }
                    
                    Button(action: {
                        gpsManager.injectTestCoordinate(lat: 40.7580, lon: -73.9855, name: "Times Square")
                    }) {
                        Text("🗽 NYC")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .foregroundColor(.primary)
                            .clipShape(Capsule())
                    }
                    
                    Button(action: {
                        gpsManager.injectTestCoordinate(lat: 35.6586, lon: 139.7454, name: "Tokyo Tower")
                    }) {
                        Text("🗼 Tokyo")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .foregroundColor(.primary)
                            .clipShape(Capsule())
                    }
                    
                    Button(action: {
                        gpsManager.injectTestCoordinate(lat: -33.8568, lon: 151.2153, name: "Sydney Harbour")
                    }) {
                        Text("🦘 Sydney")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .foregroundColor(.primary)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(18)
        .shadow(color: Color.black.opacity(0.04), radius: 8, y: 3)
    }
}

// MARK: - Telemetry Metric Card Component

struct MetricCard: some View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let accentColor: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(accentColor)
                Spacer()
            }
            
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            
            HStack {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
    }
}

// MARK: - Preview Provider

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(GPSNetworkManager())
    }
}
