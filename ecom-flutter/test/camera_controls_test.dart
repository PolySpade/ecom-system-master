import 'package:flutter_test/flutter_test.dart';

import 'package:ecom_flutter/core/camera_controls.dart';

void main() {
  const pluginName =
      r'4k Camera <\\?\usb#vid_ea11&pid_1303&mi_00#7&d11c3c4&0&0000#'
      r'{e5323777-f976-4f5b-9b55-b94699c46e44}\global>';

  test('devicePathFromCameraName extracts the path between angle brackets',
      () {
    expect(
      devicePathFromCameraName(pluginName),
      r'\\?\usb#vid_ea11&pid_1303&mi_00#7&d11c3c4&0&0000#'
      r'{e5323777-f976-4f5b-9b55-b94699c46e44}\global',
    );
  });

  test('devicePathFromCameraName returns null without a path suffix', () {
    expect(devicePathFromCameraName('Integrated Webcam'), isNull);
    expect(devicePathFromCameraName('Weird <unclosed'), isNull);
    expect(devicePathFromCameraName('Empty <>'), isNull);
  });

  test('friendlyNameFromCameraName strips the device path suffix', () {
    expect(friendlyNameFromCameraName(pluginName), '4k Camera');
    expect(friendlyNameFromCameraName('Integrated Webcam'),
        'Integrated Webcam');
  });

  test('canonicalDeviceId equates MF and DirectShow paths of one device', () {
    // Media Foundation reports KSCATEGORY_VIDEO_CAMERA; DirectShow reports
    // its own interface class GUID for the same physical device.
    const mfPath = r'\\?\usb#vid_ea11&pid_1303&mi_00#7&d11c3c4&0&0000#'
        r'{e5323777-f976-4f5b-9b55-b94699c46e44}\global';
    const dshowPath = r'\\?\usb#vid_ea11&pid_1303&mi_00#7&d11c3c4&0&0000#'
        r'{65e8773d-8f56-11d0-a3b9-00a0c9223196}\global';
    expect(canonicalDeviceId(mfPath), canonicalDeviceId(dshowPath));
    expect(canonicalDeviceId(mfPath),
        r'usb#vid_ea11&pid_1303&mi_00#7&d11c3c4&0&0000');
  });

  test('canonicalDeviceId handles null and case differences', () {
    expect(canonicalDeviceId(null), isNull);
    expect(canonicalDeviceId(r'\\?\USB#VID_AB12#X#{guid}\global'),
        canonicalDeviceId(r'\\?\usb#vid_ab12#x#{other}\global'));
  });

  test('CameraControlValues describes itself for logs', () {
    const auto = CameraControlValues(
        autoExposure: true, exposure: -4, gain: 0, brightness: 128);
    const manual = CameraControlValues(
        autoExposure: false, exposure: -6, gain: 10, brightness: 200);
    expect(auto.toString(), 'auto exposure');
    expect(manual.toString(), 'exposure=-6 gain=10 brightness=200');
  });
}
