import unittest
from unittest.mock import patch

import aircard


class DeviceDiscoveryTests(unittest.TestCase):
    def test_selects_usb_iphone_and_ignores_wifi_devices(self) -> None:
        devices = [
            {
                "udid": "wifi-iphone",
                "name": "Wi-Fi iPhone",
                "product": "iPhone16,2",
                "version": "27.0",
                "usb": 0,
            },
            {
                "udid": "usb-ipad",
                "name": "USB iPad",
                "product": "iPad13,4",
                "version": "27.0",
                "usb": 1,
            },
            {
                "udid": "usb-iphone",
                "name": "USB iPhone",
                "product": "iPhone18,1",
                "version": "27.0",
                "usb": 1,
            },
        ]
        with patch.object(aircard, "list_devices", return_value=devices):
            device = aircard.get_connected_device()

        self.assertIsNotNone(device)
        self.assertEqual(device["udid"], "usb-iphone")
        self.assertEqual(device["name"], "USB iPhone")

    def test_wifi_only_devices_are_not_treated_as_connected(self) -> None:
        devices = [{
            "udid": "wifi-iphone",
            "name": "Wi-Fi iPhone",
            "product": "iPhone16,2",
            "version": "27.0",
            "usb": 0,
        }]
        with patch.object(aircard, "list_devices", return_value=devices):
            self.assertIsNone(aircard.get_connected_device())


if __name__ == "__main__":
    unittest.main()
