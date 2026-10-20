# GPS Network Web Browser (iOS Swift & SwiftUI)

A complete, single-file iOS application that combines a local Wi-Fi TCP/UDP network listener, an NMEA 0183 GPS parser, and an interactive `WKWebView` featuring JavaScript `navigator.geolocation` injection.

---

## Architecture Overview

```
 ┌──────────────────────────────────────────────┐
 │ External Coordinator (ESP32 / Android / PC)   │
 │ Sends $GPGGA / $GPRMC sentences over TCP/UDP │
 └───────────────────────┬──────────────────────┘
                         │ Wi-Fi Socket (192.168.4.1:10110)
                         ▼
 ┌──────────────────────────────────────────────┐
 │ GPSNetworkManager (Network.framework)        │
 │ - NWConnection (background dispatch queue)   │
 │ - Reconnect logic & stream buffer handling   │
 └───────────────────────┬──────────────────────┘
                         │ Complete lines
                         ▼
 ┌──────────────────────────────────────────────┐
 │ NMEAParser (NMEA 0183 Parser)                │
 │ - Parses ddmm.mmmm & dddmm.mmmm to Dec Deg   │
 │ - Supports $GPGGA, $GNGGA, $GPRMC, $GNRMC   │
 └───────────────────────┬──────────────────────┘
                         │ @MainActor / Thread-Safe Publish
                         ▼
 ┌──────────────────────────────────────────────┐
 │ SwiftUI UI Layer (ContentView)               │
 │ - Real-time Status & Coordinates Indicator   │
 │ - IP/Port Configuration Drawer               │
 │ - Address Bar (default: Target.com)          │
 └───────────────────────┬──────────────────────┘
                         │ evaluateJavaScript
                         ▼
 ┌──────────────────────────────────────────────┐
 │ WKWebView (WebViewRepresentable)             │
 │ - WKUserScript injected at document start    │
 │ - Overrides navigator.geolocation:          │
 │   * getCurrentPosition()                     │
 │   * watchPosition() & clearWatch()           │
 │ - Web page receives spoofed GPS fix instantly!│
 └──────────────────────────────────────────────┘
```

---

## File Contents

- [GPSBrowserApp.swift](file:///c:/Users/adelr/OneDrive/Documents/Projects/New%20folder/GPSBrowserApp.swift) — The complete, single-file iOS application (App entry point, Network Manager, NMEA Parser, WebViewModel, WKWebView Representable, and SwiftUI Views).
- [Info_plist_snippet.xml](file:///c:/Users/adelr/OneDrive/Documents/Projects/New%20folder/Info_plist_snippet.xml) — The required permissions for Local Wi-Fi network and App Transport Security.
- [mock_nmea_server.py](file:///c:/Users/adelr/OneDrive/Documents/Projects/New%20folder/mock_nmea_server.py) — A Python script to simulate an ESP32 or Android GPS streamer emitting live NMEA sentences.

---

## Xcode Setup Guide

1. **Create an iOS Project**:
   - Open **Xcode** -> **File** -> **New** -> **Project**.
   - Choose **iOS** -> **App**.
   - Interface: **SwiftUI**, Language: **Swift**.
2. **Replace Project Code**:
   - Copy the contents of [GPSBrowserApp.swift](file:///c:/Users/adelr/OneDrive/Documents/Projects/New%20folder/GPSBrowserApp.swift) into your project's main Swift file (e.g. `ContentView.swift` or `YourAppNameApp.swift`).
3. **Configure Permissions (`Info.plist`)**:
   In Xcode under your target's **Info** tab (or in `Info.plist`), add:
   - `Privacy - Local Network Usage Description` (`NSLocalNetworkUsageDescription`):
     `"Connects to local Wi-Fi GPS streamer devices (ESP32/Android) for NMEA coordinates."`
   - `App Transport Security Settings` (`NSAppTransportSecurity`):
     - `Allow Arbitrary Loads` -> `YES` (Allows browsing any HTTP/HTTPS website).
   - (Optional) `Privacy - Location When In Use Usage Description` (`NSLocationWhenInUseUsageDescription`):
     `"Used as a fallback for web page location requests."`

---

## Testing Options

### 1. Built-in SwiftUI Location Simulator
- Tap the **Antenna** icon in the top header bar to expand the network settings drawer.
- Tap **Simulate** to instantly inject preset locations (e.g., Minneapolis Target HQ, NYC Times Square, Tokyo Tower, Sydney).
- The web page will immediately receive the new location via `window.__updateMockLocation`!

### 2. Testing with Python Mock Server (Simulator or Local Wi-Fi)
Run the included Python server on your computer:
```bash
python mock_nmea_server.py --port 10110 --protocol tcp
```
- In the iOS app, set the IP to `127.0.0.1` (if running in Xcode Simulator) or your computer's local LAN IP (e.g., `192.168.1.50` if running on a real iPhone).
- Tap **Connect Stream**.
- You will see live orbit coordinates streamed at 1 Hz and received by the browser!

### 3. Testing with ESP32 / Android GPS Streamer
- Connect your iPhone to the ESP32 Wi-Fi SoftAP (often `192.168.4.1`).
- Port is typically `10110` (or `2947` for gpsd).
- The app automatically parses `$GPGGA`, `$GNGGA`, `$GPRMC`, and `$GNRMC` sentences.
