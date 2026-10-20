#!/usr/bin/env python3
"""
Mock NMEA GPS Coordinator Server (TCP / UDP)
Simulates an ESP32 or Android GPS Streamer emitting $GPGGA and $GPRMC sentences.
Use this script to test GPSBrowserApp on the iOS Simulator or a physical iPhone.

Usage:
    python mock_nmea_server.py --port 10110 --protocol tcp
    python mock_nmea_server.py --port 10110 --protocol udp
"""

import socket
import time
import argparse
import math
from datetime import datetime

def calculate_checksum(nmea_str: str) -> str:
    """Calculates standard 2-digit hex XOR checksum for NMEA sentences."""
    csum = 0
    for char in nmea_str:
        csum ^= ord(char)
    return f"{csum:02X}"

def decimal_to_nmea(lat: float, lon: float):
    """Converts decimal degrees to NMEA ddmm.mmmm and dddmm.mmmm format."""
    lat_deg = int(abs(lat))
    lat_min = (abs(lat) - lat_deg) * 60.0
    lat_str = f"{lat_deg:02d}{lat_min:07.4f}"
    lat_dir = "N" if lat >= 0 else "S"

    lon_deg = int(abs(lon))
    lon_min = (abs(lon) - lon_deg) * 60.0
    lon_str = f"{lon_deg:03d}{lon_min:07.4f}"
    lon_dir = "E" if lon >= 0 else "W"

    return lat_str, lat_dir, lon_str, lon_dir

def build_nmea_sentences(lat: float, lon: float, alt: float = 24.5, speed_knots: float = 5.2, heading: float = 180.0):
    """Constructs valid $GPGGA and $GPRMC strings."""
    now = datetime.utcnow()
    utc_time = now.strftime("%H%M%S.00")
    utc_date = now.strftime("%d%m%y")

    lat_str, lat_dir, lon_str, lon_dir = decimal_to_nmea(lat, lon)

    # 1. $GPGGA: Global Positioning System Fix Data
    # Fix quality 1 (GPS fix), 8 satellites, HDOP 0.9, Altitude 24.5m
    gga_body = f"GPGGA,{utc_time},{lat_str},{lat_dir},{lon_str},{lon_dir},1,08,0.9,{alt:.1f},M,0.0,M,,"
    gga_sentence = f"${gga_body}*{calculate_checksum(gga_body)}\r\n"

    # 2. $GPRMC: Recommended Minimum Specific GNSS Data
    # Status A (active), speed in knots, heading in degrees
    rmc_body = f"GPRMC,{utc_time},A,{lat_str},{lat_dir},{lon_str},{lon_dir},{speed_knots:.1f},{heading:.1f},{utc_date},,,A"
    rmc_sentence = f"${rmc_body}*{calculate_checksum(rmc_body)}\r\n"

    return gga_sentence + rmc_sentence

def run_tcp_server(host: str, port: int, start_lat: float, start_lon: float):
    print(f"[*] Starting TCP NMEA Streamer on {host}:{port}...")
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((host, port))
    server.listen(1)
    print(f"[+] Listening for incoming connections from iOS app...")

    step = 0
    try:
        while True:
            client, addr = server.accept()
            print(f"[+] Client connected from {addr}!")
            try:
                while True:
                    # Orbit coordinates slightly to simulate live moving GPS fix
                    radius = 0.0015
                    curr_lat = start_lat + (radius * math.cos(step * 0.1))
                    curr_lon = start_lon + (radius * math.sin(step * 0.1))
                    nmea = build_nmea_sentences(curr_lat, curr_lon, alt=18.0 + step % 5, speed_knots=3.5)

                    client.sendall(nmea.encode("utf-8"))
                    print(f" -> Sent fix: Lat {curr_lat:.6f}, Lon {curr_lon:.6f} to {addr}")
                    step += 1
                    time.sleep(1.0)
            except (ConnectionResetError, BrokenPipeError):
                print(f"[-] Client {addr} disconnected.")
            finally:
                client.close()
    except KeyboardInterrupt:
        print("\nStopping server.")
    finally:
        server.close()

def run_udp_server(host: str, port: int, start_lat: float, start_lon: float):
    print(f"[*] Starting UDP NMEA Streamer on {host}:{port}...")
    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    step = 0
    try:
        while True:
            radius = 0.0015
            curr_lat = start_lat + (radius * math.cos(step * 0.1))
            curr_lon = start_lon + (radius * math.sin(step * 0.1))
            nmea = build_nmea_sentences(curr_lat, curr_lon)

            # Broadcast or send to local subnet / simulator
            server.sendto(nmea.encode("utf-8"), ("127.0.0.1", port))
            print(f" -> Broadcast UDP fix: Lat {curr_lat:.6f}, Lon {curr_lon:.6f}")
            step += 1
            time.sleep(1.0)
    except KeyboardInterrupt:
        print("\nStopping UDP broadcast.")
    finally:
        server.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Mock NMEA GPS Coordinator Server")
    parser.add_argument("--host", default="0.0.0.0", help="Host IP to bind (default 0.0.0.0)")
    parser.add_argument("--port", type=int, default=10110, help="Port to stream on (default 10110)")
    parser.add_argument("--protocol", choices=["tcp", "udp"], default="tcp", help="Protocol: tcp or udp")
    parser.add_argument("--lat", type=float, default=44.9778, help="Starting Latitude (default Minneapolis: 44.9778)")
    parser.add_argument("--lon", type=float, default=-93.2650, help="Starting Longitude (default: -93.2650)")
    args = parser.parse_args()

    if args.protocol == "tcp":
        run_tcp_server(args.host, args.port, args.lat, args.lon)
    else:
        run_udp_server(args.host, args.port, args.lat, args.lon)
