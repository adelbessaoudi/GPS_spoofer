//
//  GPSBrowserApp.swift
//  GPS Network Web Browser
//
//  A complete, single-file iOS application using Swift and SwiftUI that acts
//  as a custom Web View browser with a built-in network GPS coordinate receiver.
//
//  Key Features:
//  1. TCP / UDP Network Listener (Network.framework / NWConnection) connecting
//     to an ESP32 or Android GPS streamer on local Wi-Fi (default 192.168.4.1:10110).
//  2. High-performance NMEA 0183 Parser supporting $GPGGA, $GNGGA, $GPRMC, $GNRMC.
//  3. WKWebView with WKUserScript injection overriding navigator.geolocation
//     (getCurrentPosition & watchPosition) to feed mock network coordinates.
//  4. Clean, responsive SwiftUI UI with address bar, connection status, and live coords.
//

import SwiftUI
import WebKit
import Network
import Combine

// MARK: - Application Entry Point

@main
struct GPSBrowserApp: App {
    @StateObject private var gpsManager = GPSNetworkManager()
    @StateObject private var webViewModel = WebViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(gpsManager)
                .environmentObject(webViewModel)
        }
    }
}

// MARK: - Models & Data Structures

/// Represents a parsed GPS coordinate fix from an NMEA sentence.
struct GPSCoordinate: Equatable {
    var latitude: Double = 37.7749        // Default: San Francisco
    var longitude: Double = -122.4194
    var altitude: Double = 10.0           // Meters
    var accuracy: Double = 3.5            // Estimated accuracy in meters
    var speed: Double = 0.0               // Meters per second
    var heading: Double = 0.0             // Degrees
    var satellites: Int = 0
    var fixQuality: String = "No Fix"
    var timestamp: Date = Date()
    var sentenceType: String = "None"
    
    var formattedLatitude: String {
        let direction = latitude >= 0 ? "N" : "S"
        return String(format: "%.6f° %@", abs(latitude), direction)
    }
    
    var formattedLongitude: String {
        let direction = longitude >= 0 ? "E" : "W"
        return String(format: "%.6f° %@", abs(longitude), direction)
    }
}

/// Network Connection State for the GPS stream listener.
enum NetworkConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
    
    var statusText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .failed(let err): return "Failed: \(err)"
        }
    }
    
    var statusColor: Color {
        switch self {
        case .disconnected: return .gray
        case .connecting: return .orange
        case .connected: return .green
        case .failed: return .red
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
    
    /// Parses an incoming NMEA line and returns an updated GPSCoordinate if valid.
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
        
        // Identify sentence type regardless of talker ID (GP, GN, GL, GA)
        if header.hasSuffix("GGA") {
            return parseGGA(tokens: tokens, existing: existing)
        } else if header.hasSuffix("RMC") {
            return parseRMC(tokens: tokens, existing: existing)
        }
        
        return nil
    }
    
    /// Parses $xxGGA sentence:
    /// $--GGA,hhmmss.ss,llll.ll,a,yyyyy.yy,a,x,xx,x.x,x.x,M,x.x,M,x.x,xxxx
    /// 0: Header ($GPGGA)
    /// 1: UTC Time
    /// 2: Latitude (ddmm.mmmm)
    /// 3: N/S
    /// 4: Longitude (dddmm.mmmm)
    /// 5: E/W
    /// 6: Fix Quality (0 = invalid, 1 = GPS, 2 = DGPS)
    /// 7: Number of satellites
    /// 8: HDOP
    /// 9: Altitude
    /// 10: Altitude Unit (M)
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
        
        // If fix code is 0 (invalid), ignore unless we have no other data
        guard fixCode > 0, !rawLat.isEmpty, !rawLon.isEmpty else { return nil }
        guard let lat = convertDMStoDecimal(raw: rawLat, direction: latDir, isLatitude: true),
              let lon = convertDMStoDecimal(raw: rawLon, direction: lonDir, isLatitude: false) else {
            return nil
        }
        
        var fixName = "GPS Fix"
        if fixCode == 2 { fixName = "DGPS Fix" }
        else if fixCode == 4 { fixName = "RTK Fix" }
        else if fixCode == 5 { fixName = "Float RTK" }
        
        var coord = existing
        coord.latitude = lat
        coord.longitude = lon
        coord.altitude = altitude
        coord.accuracy = max(1.0, hdop * 2.5) // Approximate accuracy from HDOP
        coord.satellites = satellites
        coord.fixQuality = fixName
        coord.sentenceType = tokens[0]
        coord.timestamp = Date()
        return coord
    }
    
    /// Parses $xxRMC sentence:
    /// $--RMC,hhmmss.ss,A,llll.ll,a,yyyyy.yy,a,x.x,x.x,ddmmyy,,,a
    /// 0: Header ($GPRMC)
    /// 1: UTC Time
    /// 2: Status (A = Active/Valid, V = Void)
    /// 3: Latitude (ddmm.mmmm)
    /// 4: N/S
    /// 5: Longitude (dddmm.mmmm)
    /// 6: E/W
    /// 7: Speed over ground in knots
    /// 8: Track angle in degrees (Heading)
    private static func parseRMC(tokens: [String], existing: GPSCoordinate) -> GPSCoordinate? {
        guard tokens.count > 8 else { return nil }
        
        let status = tokens[2].uppercased()
        guard status == "A" else { return nil } // A = Active fix
        
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
        coord.speed = speedKnots * 0.514444 // Knots to m/s
        coord.heading = headingDeg
        coord.fixQuality = "Active (RMC)"
        coord.sentenceType = tokens[0]
        coord.timestamp = Date()
        return coord
    }
    
    /// Converts NMEA ddmm.mmmm (Lat) or dddmm.mmmm (Lon) into standard decimal degrees.
    private static func convertDMStoDecimal(raw: String, direction: String, isLatitude: Bool) -> Double? {
        let degreeDigits = isLatitude ? 2 : 3
        guard raw.count >= degreeDigits + 2 else { return nil }
        
        let degEndIndex = raw.index(raw.startIndex, offsetBy: degreeDigits)
        let degStr = String(raw[raw.startIndex..<degEndIndex])
        let minStr = String(raw[degEndIndex..<raw.endIndex])
        
        guard let degrees = Double(degStr), let minutes = Double(minStr) else {
            return nil
        }
        
        var decimal = degrees + (minutes / 60.0)
        if direction == "S" || direction == "W" {
            decimal = -decimal
        }
        return decimal
    }
}

// MARK: - Network GPS Manager (NWConnection)

/// Manages asynchronous TCP/UDP socket connections to the external GPS streamer.
@MainActor
final class GPSNetworkManager: ObservableObject {
    @Published var ipAddress: String = "192.168.4.1"
    @Published var portString: String = "10110"
    @Published var selectedProtocol: TransportProtocol = .tcp
    @Published var connectionState: NetworkConnectionState = .disconnected
    @Published var currentCoordinate: GPSCoordinate = GPSCoordinate()
    @Published var sentencesReceivedCount: Int = 0
    @Published var lastRawSentence: String = ""
    @Published var autoReconnect: Bool = true
    
    private var connection: NWConnection?
    private let networkQueue = DispatchQueue(label: "com.gpsbrowser.network", qos: .userInitiated)
    private var streamBuffer = ""
    private var reconnectWorkItem: DispatchWorkItem?

    // Closure invoked whenever a new validated GPSCoordinate is parsed.
    // The WebViewModel observes this to push the update directly to the WKWebView.
    var onCoordinateUpdated: ((GPSCoordinate) -> Void)?
    
    init() {
        // Default initial coordinate for ready state
        self.currentCoordinate = GPSCoordinate(
            latitude: 37.774929,
            longitude: -122.419416,
            altitude: 15.0,
            accuracy: 3.0,
            speed: 0.0,
            heading: 0.0,
            satellites: 9,
            fixQuality: "Ready (Default)",
            timestamp: Date(),
            sentenceType: "INIT"
        )
    }

    /// Toggles connection state between Connected and Disconnected.
    func toggleConnection() {
        if connectionState == .connected || connectionState == .connecting {
            disconnect()
        } else {
            connect()
        }
    }
    
    /// Connects to the configured IP and Port using NWConnection.
    func connect() {
        cancelReconnect()
        disconnectCurrentConnection()
        
        guard let portNumber = UInt16(portString), let nwPort = NWEndpoint.Port(rawValue: portNumber) else {
            self.connectionState = .failed("Invalid Port")
            return
        }
        
        let nwHost = NWEndpoint.Host(ipAddress)
        let parameters: NWParameters = (selectedProtocol == .tcp) ? .tcp : .udp
        
        // Allow fast connection on local Wi-Fi networks
        parameters.includePeerToPeer = true
        
        self.connectionState = .connecting
        let conn = NWConnection(host: nwHost, port: nwPort, using: parameters)
        self.connection = conn
        
        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                self?.handleStateUpdate(state)
            }
        }
        
        conn.start(queue: networkQueue)
        startReceiveLoop(on: conn)
    }
    
    /// Gracefully disconnects the network listener.
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
            print("[GPSNetworkManager] Attempting automatic reconnection...")
            self.connect()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }
    
    private func handleStateUpdate(_ state: NWConnection.State) {
        switch state {
        case .ready:
            self.connectionState = .connected
            print("[GPSNetworkManager] Connected to \(ipAddress):\(portString) via \(selectedProtocol.rawValue)")
        case .preparing:
            self.connectionState = .connecting
        case .waiting(let error):
            self.connectionState = .failed("Waiting: \(error.localizedDescription)")
            scheduleReconnect()
        case .failed(let error):
            self.connectionState = .failed(error.localizedDescription)
            scheduleReconnect()
        case .cancelled:
            if case .failed = connectionState {
                // Keep failed message
            } else {
                self.connectionState = .disconnected
            }
        @unknown default:
            break
        }
    }
    
    /// Continuously reads incoming TCP/UDP stream fragments.
    private func startReceiveLoop(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak conn] content, _, isComplete, error in
            guard let self = self, let activeConn = conn, activeConn === self.connection else { return }
            
            if let data = content, !data.isEmpty, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
                self.networkQueue.async {
                    self.processIncomingStream(text)
                }
            }
            
            if isComplete {
                DispatchQueue.main.async {
                    self.connectionState = .disconnected
                    self.scheduleReconnect()
                }
                return
            }
            
            if let error = error {
                DispatchQueue.main.async {
                    self.connectionState = .failed(error.localizedDescription)
                    self.scheduleReconnect()
                }
                return
            }
            
            // Continue asynchronous read loop
            self.startReceiveLoop(on: activeConn)
        }
    }
    
    /// Handles stream fragmentation by breaking received chunks into lines.
    private func processIncomingStream(_ chunk: String) {
        streamBuffer.append(chunk)
        
        // NMEA sentences end with \r\n or \n
        var lines = streamBuffer.components(separatedBy: "\n")
        
        // The last component is either empty (if ended on newline) or an incomplete sentence fragment
        streamBuffer = lines.removeLast()
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            
            // Check if this is an NMEA sentence
            if trimmed.hasPrefix("$") || trimmed.hasPrefix("!") {
                if let newCoord = NMEAParser.parse(sentence: trimmed, existing: currentCoordinate) {
                    DispatchQueue.main.async {
                        self.currentCoordinate = newCoord
                        self.sentencesReceivedCount += 1
                        self.lastRawSentence = trimmed
                        self.onCoordinateUpdated?(newCoord)
                    }
                }
            } else if trimmed.contains(",") {
                // Secondary fallback: Support simple "lat,lon" direct CSV for quick testing (e.g. "37.7749,-122.4194")
                let parts = trimmed.components(separatedBy: ",")
                if parts.count >= 2, let lat = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                   let lon = Double(parts[1].trimmingCharacters(in: .whitespaces)) {
                    DispatchQueue.main.async {
                        var coord = self.currentCoordinate
                        coord.latitude = lat
                        coord.longitude = lon
                        coord.fixQuality = "Manual/CSV Stream"
                        coord.sentenceType = "RAW_CSV"
                        coord.timestamp = Date()
                        self.currentCoordinate = coord
                        self.sentencesReceivedCount += 1
                        self.lastRawSentence = trimmed
                        self.onCoordinateUpdated?(coord)
                    }
                }
            }
        }
    }
    
    /// Injects a test coordinate (useful for Xcode Simulator validation without physical hardware).
    func injectTestCoordinate(lat: Double, lon: Double, name: String = "Test Mock") {
        var coord = currentCoordinate
        coord.latitude = lat
        coord.longitude = lon
        coord.fixQuality = name
        coord.sentenceType = "SIMULATED"
        coord.timestamp = Date()
        self.currentCoordinate = coord
        self.sentencesReceivedCount += 1
        self.lastRawSentence = "$SIM,\(lat),\(lon),MOCK*00"
        self.onCoordinateUpdated?(coord)
    }
}

// MARK: - WebViewModel & JavaScript Injection

/// Manages the WKWebView instance, navigation, and evaluates location updates.
@MainActor
final class WebViewModel: ObservableObject {
    @Published var urlString: String = "https://www.target.com"
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isLoading: Bool = false
    @Published var estimatedProgress: Double = 0.0
    @Published var pageTitle: String = ""
    
    weak var webView: WKWebView?
    
    /// Builds the JavaScript user script that overrides navigator.geolocation before any page script executes.
    static func createGeolocationOverrideScript(initialCoordinate: GPSCoordinate) -> WKUserScript {
        let jsSource = """
        (function() {
            console.log("[GPSBrowser] Initializing Network Geolocation Override...");

            // Internal store holding live mock coordinates
            window.__mockGPS = {
                latitude: \(initialCoordinate.latitude),
                longitude: \(initialCoordinate.longitude),
                altitude: \(initialCoordinate.altitude),
                accuracy: \(initialCoordinate.accuracy),
                altitudeAccuracy: 5.0,
                heading: \(initialCoordinate.heading),
                speed: \(initialCoordinate.speed),
                timestamp: Date.now()
            };

            let watchIdCounter = 1;
            const activeWatchers = new Map();

            // Factory to generate W3C compliant GeolocationPosition objects
            function createGeolocationPosition() {
                const data = window.__mockGPS;
                return {
                    coords: {
                        latitude: Number(data.latitude),
                        longitude: Number(data.longitude),
                        altitude: data.altitude !== null ? Number(data.altitude) : null,
                        accuracy: Number(data.accuracy) || 5.0,
                        altitudeAccuracy: Number(data.altitudeAccuracy) || null,
                        heading: data.heading !== null ? Number(data.heading) : null,
                        speed: data.speed !== null ? Number(data.speed) : null
                    },
                    timestamp: Number(data.timestamp) || Date.now()
                };
            }

            // Custom Geolocation interface replacing standard navigator.geolocation
            const mockGeolocation = {
                getCurrentPosition: function(successCallback, errorCallback, options) {
                    console.log("[GPSBrowser] Intercepted getCurrentPosition() request!");
                    if (typeof successCallback === 'function') {
                        // Asynchronous response matching standard W3C Geolocation specification
                        setTimeout(function() {
                            const pos = createGeolocationPosition();
                            console.log("[GPSBrowser] Returning spoofed position:", pos.coords.latitude, pos.coords.longitude);
                            successCallback(pos);
                        }, 5);
                    }
                },
                watchPosition: function(successCallback, errorCallback, options) {
                    const watchId = watchIdCounter++;
                    console.log("[GPSBrowser] Intercepted watchPosition() request! Assigned watchId:", watchId);
                    if (typeof successCallback === 'function') {
                        activeWatchers.set(watchId, successCallback);
                        // Deliver immediate initial fix
                        setTimeout(function() {
                            if (activeWatchers.has(watchId)) {
                                successCallback(createGeolocationPosition());
                            }
                        }, 5);
                    }
                    return watchId;
                },
                clearWatch: function(watchId) {
                    console.log("[GPSBrowser] Intercepted clearWatch() for id:", watchId);
                    activeWatchers.delete(watchId);
                }
            };

            // Safely redefine navigator.geolocation
            try {
                Object.defineProperty(navigator, 'geolocation', {
                    value: mockGeolocation,
                    configurable: false,
                    writable: false
                });
                console.log("[GPSBrowser] navigator.geolocation successfully overridden.");
            } catch (err) {
                console.warn("[GPSBrowser] Property redefine error, falling back to direct assignment:", err);
                navigator.geolocation = mockGeolocation;
            }

            // Global hook called directly from Swift to broadcast live stream coordinates
            window.__updateMockLocation = function(lat, lon, alt, acc, spd, hdg) {
                window.__mockGPS.latitude = Number(lat);
                window.__mockGPS.longitude = Number(lon);
                if (alt !== undefined && alt !== null) window.__mockGPS.altitude = Number(alt);
                if (acc !== undefined && acc !== null) window.__mockGPS.accuracy = Number(acc);
                if (spd !== undefined && spd !== null) window.__mockGPS.speed = Number(spd);
                if (hdg !== undefined && hdg !== null) window.__mockGPS.heading = Number(hdg);
                window.__mockGPS.timestamp = Date.now();

                const pos = createGeolocationPosition();

                // Fire all registered watchPosition listeners
                activeWatchers.forEach(function(callback, id) {
                    try {
                        callback(pos);
                    } catch (cbErr) {
                        console.error("[GPSBrowser] Error in watchPosition callback id " + id + ":", cbErr);
                    }
                });

                // Dispatch global event for interactive web testers
                window.dispatchEvent(new CustomEvent("mockGPSUpdate", { detail: pos }));
            };
        })();
        """
        
        return WKUserScript(
            source: jsSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    /// Evaluates JavaScript inside the WKWebView to immediately push new coordinates to web pages.
    func pushLocationUpdateToWebView(_ coord: GPSCoordinate) {
        guard let webView = self.webView else { return }
        
        let jsCall = "if (window.__updateMockLocation) { window.__updateMockLocation(\(coord.latitude), \(coord.longitude), \(coord.altitude), \(coord.accuracy), \(coord.speed), \(coord.heading)); }"
        webView.evaluateJavaScript(jsCall) { _, error in
            if let error = error {
                // Ignore silent evaluation errors on unloaded pages
                _ = error
            }
        }
    }
    
    /// Loads a URL string, ensuring https:// scheme if missing.
    func loadUrl(_ target: String) {
        var formatted = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if !formatted.lowercased().hasPrefix("http://") && !formatted.lowercased().hasPrefix("https://") {
            formatted = "https://" + formatted
        }
        
        if let url = URL(string: formatted) {
            self.urlString = formatted
            let request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30)
            webView?.load(request)
        }
    }
    
    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
}

// MARK: - WKWebView SwiftUI Representable

struct WebViewRepresentable: UIViewRepresentable {
    @ObservedObject var webViewModel: WebViewModel
    @ObservedObject var gpsManager: GPSNetworkManager

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        
        // 1. Inject the Geolocation override script at document start
        let script = WebViewModel.createGeolocationOverrideScript(initialCoordinate: gpsManager.currentCoordinate)
        userContentController.addUserScript(script)
        config.userContentController = userContentController
        
        // Enable smooth media and responsive scrolling
        config.allowsInlineMediaPlayback = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        
        // Link coordinator observations
        context.coordinator.setupObservers(for: webView)
        webViewModel.webView = webView
        
        // Wire live GPS updates to automatically push to this webView
        gpsManager.onCoordinateUpdated = { [weak webViewModel] coord in
            webViewModel?.pushLocationUpdateToWebView(coord)
        }
        
        // Load initial target site
        webViewModel.loadUrl(webViewModel.urlString)
        
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Dynamic state updates are driven by the ViewModel and delegate methods
    }

    // MARK: Coordinator
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WebViewRepresentable
        private var estimatedProgressObservation: NSKeyValueObservation?
        private var canGoBackObservation: NSKeyValueObservation?
        private var canGoForwardObservation: NSKeyValueObservation?
        private var titleObservation: NSKeyValueObservation?

        init(_ parent: WebViewRepresentable) {
            self.parent = parent
        }

        func setupObservers(for webView: WKWebView) {
            estimatedProgressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.parent.webViewModel.estimatedProgress = wv.estimatedProgress
                    self?.parent.webViewModel.isLoading = wv.estimatedProgress < 1.0
                }
            }

            canGoBackObservation = webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.parent.webViewModel.canGoBack = wv.canGoBack
                }
            }

            canGoForwardObservation = webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.parent.webViewModel.canGoForward = wv.canGoForward
                }
            }
            
            titleObservation = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.parent.webViewModel.pageTitle = wv.title ?? ""
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.webViewModel.isLoading = true
                if let currentUrl = webView.url?.absoluteString {
                    self.parent.webViewModel.urlString = currentUrl
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.webViewModel.isLoading = false
                if let currentUrl = webView.url?.absoluteString {
                    self.parent.webViewModel.urlString = currentUrl
                }
                // Push latest coordinates immediately once document is loaded
                self.parent.webViewModel.pushLocationUpdateToWebView(self.parent.gpsManager.currentCoordinate)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.webViewModel.isLoading = false
            }
        }
        
        // Handle target="_blank" new window links by loading them inside the same view
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}

// MARK: - SwiftUI User Interface

struct ContentView: View {
    @EnvironmentObject var gpsManager: GPSNetworkManager
    @EnvironmentObject var webViewModel: WebViewModel
    
    @State private var urlInput: String = "https://www.target.com"
    @State private var isConfigExpanded: Bool = false
    @State private var showingTestPresets: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. Top Network GPS Status & Configuration Drawer
            headerBar
            
            if isConfigExpanded {
                networkConfigPanel
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            
            // 2. Web Browser Address Bar & Controls
            browserNavigationBar
            
            // 3. Web Page Loading Progress Bar
            if webViewModel.isLoading {
                ProgressView(value: webViewModel.estimatedProgress, total: 1.0)
                    .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                    .frame(height: 2)
            } else {
                Divider()
            }
            
            // 4. Interactive Full-Screen WKWebView
            ZStack(alignment: .bottomTrailing) {
                WebViewRepresentable(webViewModel: webViewModel, gpsManager: gpsManager)
                    .edgesIgnoringSafeArea(.bottom)
                
                // Floating Live Location HUD Pill
                liveLocationOverlayPill
                    .padding()
            }
        }
        .onAppear {
            urlInput = webViewModel.urlString
        }
        .animation(.easeInOut(duration: 0.25), value: isConfigExpanded)
    }

    // MARK: - Header Bar (Status & Toggle)
    private var headerBar: some View {
        HStack(spacing: 12) {
            // Status Indicator Circle & Label
            HStack(spacing: 6) {
                Circle()
                    .fill(gpsManager.connectionState.statusColor)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(gpsManager.connectionState.statusColor.opacity(0.4), lineWidth: 3)
                            .scaleEffect(gpsManager.connectionState == .connected ? 1.6 : 1.0)
                            .opacity(gpsManager.connectionState == .connected ? 0.0 : 1.0)
                            .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: gpsManager.connectionState)
                    )
                
                Text(gpsManager.connectionState.statusText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
            }
            
            Spacer()
            
            // Current Fix Summary Badge
            HStack(spacing: 4) {
                Image(systemName: "location.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.blue)
                
                Text("\(gpsManager.currentCoordinate.formattedLatitude), \(gpsManager.currentCoordinate.formattedLongitude)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)
            
            // Settings Toggle Button
            Button(action: {
                withAnimation {
                    isConfigExpanded.toggle()
                }
            }) {
                Image(systemName: isConfigExpanded ? "chevron.up.circle.fill" : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.accentColor)
                    .padding(4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: - Network Config Panel
    private var networkConfigPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                // IP Address Input
                VStack(alignment: .leading, spacing: 4) {
                    Text("IP Address")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    TextField("192.168.4.1", text: $gpsManager.ipAddress)
                        .keyboardType(.numbersAndPunctuation)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(size: 14, design: .monospaced))
                        .padding(8)
                        .background(Color(.tertiarySystemBackground))
                        .cornerRadius(8)
                }
                .frame(maxWidth: .infinity)
                
                // Port Input
                VStack(alignment: .leading, spacing: 4) {
                    Text("Port")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    TextField("10110", text: $gpsManager.portString)
                        .keyboardType(.numberPad)
                        .font(.system(size: 14, design: .monospaced))
                        .padding(8)
                        .background(Color(.tertiarySystemBackground))
                        .cornerRadius(8)
                }
                .frame(width: 80)
                
                // Protocol Picker
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
                    .frame(width: 90)
                }
            }
            
            HStack(spacing: 12) {
                // Connect / Disconnect Toggle Button
                Button(action: {
                    gpsManager.toggleConnection()
                }) {
                    HStack {
                        Image(systemName: (gpsManager.connectionState == .connected || gpsManager.connectionState == .connecting) ? "bolt.slash.fill" : "bolt.fill")
                        Text((gpsManager.connectionState == .connected || gpsManager.connectionState == .connecting) ? "Disconnect Stream" : "Connect Stream")
                            .fontWeight(.semibold)
                    }
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background((gpsManager.connectionState == .connected || gpsManager.connectionState == .connecting) ? Color.red.opacity(0.15) : Color.blue)
                    .foregroundColor((gpsManager.connectionState == .connected || gpsManager.connectionState == .connecting) ? Color.red : Color.white)
                    .cornerRadius(8)
                }
                
                // Quick Test Location Simulator (Great for Xcode Simulator testing)
                Menu {
                    Button("Target Store (Minneapolis: 44.9778, -93.2650)") {
                        gpsManager.injectTestCoordinate(lat: 44.9778, lon: -93.2650, name: "Minneapolis HQ")
                    }
                    Button("Times Square, NYC (40.7580, -73.9855)") {
                        gpsManager.injectTestCoordinate(lat: 40.7580, lon: -73.9855, name: "NYC")
                    }
                    Button("Tokyo Tower, Japan (35.6586, 139.7454)") {
                        gpsManager.injectTestCoordinate(lat: 35.6586, lon: 139.7454, name: "Tokyo")
                    }
                    Button("Sydney Opera House (-33.8568, 151.2153)") {
                        gpsManager.injectTestCoordinate(lat: -33.8568, lon: 151.2153, name: "Sydney")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                        Text("Simulate")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color(.tertiarySystemBackground))
                    .foregroundColor(.accentColor)
                    .cornerRadius(8)
                }
            }
            
            // Sentence telemetry info
            HStack {
                Text("Packets: \(gpsManager.sentencesReceivedCount)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if !gpsManager.lastRawSentence.isEmpty {
                    Text("Last: \(gpsManager.lastRawSentence)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: - Browser Navigation & Address Bar
    private var browserNavigationBar: some View {
        HStack(spacing: 8) {
            // Back Button
            Button(action: { webViewModel.goBack() }) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(webViewModel.canGoBack ? .primary : .gray.opacity(0.4))
            }
            .disabled(!webViewModel.canGoBack)
            
            // Forward Button
            Button(action: { webViewModel.goForward() }) {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(webViewModel.canGoForward ? .primary : .gray.opacity(0.4))
            }
            .disabled(!webViewModel.canGoForward)
            
            // URL Address Field
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.green)
                
                TextField("Search or enter website name", text: $urlInput, onCommit: {
                    webViewModel.loadUrl(urlInput)
                })
                .keyboardType(.URL)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .font(.system(size: 14))
                
                if !urlInput.isEmpty {
                    Button(action: { urlInput = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
            
            // Go / Reload Button
            Button(action: {
                if webViewModel.isLoading {
                    webViewModel.webView?.stopLoading()
                    webViewModel.isLoading = false
                } else if urlInput != webViewModel.urlString {
                    webViewModel.loadUrl(urlInput)
                } else {
                    webViewModel.reload()
                }
            }) {
                Image(systemName: webViewModel.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 28, height: 28)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
    }
    
    // MARK: - Floating Location Telemetry Pill
    private var liveLocationOverlayPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 11))
                .foregroundColor(.green)
            
            VStack(alignment: .leading, spacing: 1) {
                Text("NETWORK GPS ACTIVE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                
                Text("\(gpsManager.currentCoordinate.formattedLatitude), \(gpsManager.currentCoordinate.formattedLongitude)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
            }
            
            if gpsManager.currentCoordinate.satellites > 0 {
                Divider().frame(height: 14)
                HStack(spacing: 2) {
                    Image(systemName: "network")
                        .font(.system(size: 9))
                    Text("\(gpsManager.currentCoordinate.satellites)")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundColor(.blue)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
    }
}

// MARK: - Xcode Preview Provider

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(GPSNetworkManager())
            .environmentObject(WebViewModel())
    }
}
