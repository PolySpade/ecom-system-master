/// Camera Controls - DirectShow-based exposure/gain/brightness control.
///
/// camera_windows (Media Foundation) exposes no API for exposure, gain, or
/// brightness, so this module talks to the SAME physical device through
/// DirectShow property interfaces instead: IAMCameraControl (exposure) and
/// IAMVideoProcAmp (brightness/gain). These set driver-level properties, so
/// changes take effect immediately on the live preview even while Media
/// Foundation is streaming - the behavioral equivalent of ecom-py's
/// cv2.CAP_PROP_EXPOSURE/GAIN/BRIGHTNESS sets (CAP_DSHOW backend).
///
/// Implemented with raw dart:ffi COM (own vtable dispatch): the DirectShow
/// interfaces used here are not covered by package:win32, and win32 6.x's
/// typed COM model cannot express foreign interfaces without codegen.
///
/// Value semantics match ecom-py/DirectShow conventions:
/// - exposure: log2 seconds, typically -13 (darkest/fastest) .. -1
/// - gain, brightness: passed through raw, clamped to the driver's range
///   (commonly 0..255, but driver-defined)
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// --- OLE flat functions ---------------------------------------------------

final DynamicLibrary _ole32 = DynamicLibrary.open('ole32.dll');
final DynamicLibrary _oleaut32 = DynamicLibrary.open('oleaut32.dll');

final int Function(Pointer<Void>, int) _coInitializeEx = _ole32.lookupFunction<
    Int32 Function(Pointer<Void>, Uint32),
    int Function(Pointer<Void>, int)>('CoInitializeEx');

final void Function() _coUninitialize = _ole32
    .lookupFunction<Void Function(), void Function()>('CoUninitialize');

final int Function(Pointer<_Guid>, Pointer<Void>, int, Pointer<_Guid>,
        Pointer<Pointer<_ComObject>>) _coCreateInstance =
    _ole32.lookupFunction<
        Int32 Function(Pointer<_Guid>, Pointer<Void>, Uint32, Pointer<_Guid>,
            Pointer<Pointer<_ComObject>>),
        int Function(Pointer<_Guid>, Pointer<Void>, int, Pointer<_Guid>,
            Pointer<Pointer<_ComObject>>)>('CoCreateInstance');

final int Function(Pointer<Utf16>, Pointer<_Guid>) _clsidFromString =
    _ole32.lookupFunction<Int32 Function(Pointer<Utf16>, Pointer<_Guid>),
        int Function(Pointer<Utf16>, Pointer<_Guid>)>('CLSIDFromString');

final void Function(Pointer<_Variant>) _variantInit = _oleaut32.lookupFunction<
    Void Function(Pointer<_Variant>),
    void Function(Pointer<_Variant>)>('VariantInit');

final int Function(Pointer<_Variant>) _variantClear = _oleaut32.lookupFunction<
    Int32 Function(Pointer<_Variant>),
    int Function(Pointer<_Variant>)>('VariantClear');

// --- Minimal COM structs --------------------------------------------------

final class _Guid extends Struct {
  @Uint32()
  external int data1;
  @Uint16()
  external int data2;
  @Uint16()
  external int data3;
  @Array(8)
  external Array<Uint8> data4;
}

/// A COM object: the first pointer-sized field is the vtable.
final class _ComObject extends Struct {
  external Pointer<IntPtr> vtable;
}

/// VARIANT, reduced to what IPropertyBag::Read(VT_BSTR) needs. The union
/// payload starts at offset 8 on x64 (vt + three reserved WORDs).
final class _Variant extends Struct {
  @Uint16()
  external int vt;
  @Uint16()
  external int reserved1;
  @Uint16()
  external int reserved2;
  @Uint16()
  external int reserved3;
  external Pointer<Utf16> ptrValue;
  external Pointer<Void> reserved4;
}

const int _sOk = 0;
const int _clsctxInprocServer = 0x1;
const int _coinitApartmentThreaded = 0x2;
const int _vtBstr = 8;

bool _failed(int hr) => hr < 0;

// --- DirectShow GUIDs (not provided by package:win32) ---

const _clsidSystemDeviceEnum = '{62BE5D10-60EB-11D0-BD3B-00A0C911CE86}';
const _iidICreateDevEnum = '{29840822-5B84-11D0-BD3B-00A0C911CE86}';
const _clsidVideoInputDeviceCategory = '{860BB310-5D01-11D0-BD3B-00A0C911CE86}';
const _iidIPropertyBag = '{55272A00-42CB-11CE-8135-00AA004BB851}';
const _iidIBaseFilter = '{56A86895-0AD4-11CE-B03A-0020AF0BA770}';
const _iidIAMCameraControl = '{C6E13370-30AC-11D0-A18C-00A0C9118956}';
const _iidIAMVideoProcAmp = '{C6E13360-30AC-11D0-A18C-00A0C9118956}';

// --- DirectShow property ids / flags ---

const _cameraControlExposure = 4; // CameraControl_Exposure
const _cameraControlFlagsAuto = 0x0001;
const _cameraControlFlagsManual = 0x0002;

const _videoProcAmpBrightness = 0; // VideoProcAmp_Brightness
const _videoProcAmpGain = 8; // VideoProcAmp_Gain
const _videoProcAmpFlagsManual = 0x0002;

/// The exposure/gain/brightness values to push to the device (mirrors the
/// 'camera' settings category).
class CameraControlValues {
  const CameraControlValues({
    required this.autoExposure,
    required this.exposure,
    required this.gain,
    required this.brightness,
  });

  final bool autoExposure;
  final int exposure;
  final int gain;
  final int brightness;

  @override
  String toString() => autoExposure
      ? 'auto exposure'
      : 'exposure=$exposure gain=$gain brightness=$brightness';
}

/// Extracts the raw device path from a camera_windows camera name
/// ("Friendly Name <\\?\usb#vid_...&pid_...#...{guid}\global>"), or null
/// when the name carries no path suffix.
String? devicePathFromCameraName(String cameraName) {
  final start = cameraName.indexOf(' <');
  if (start < 0 || !cameraName.endsWith('>')) return null;
  final path = cameraName.substring(start + 2, cameraName.length - 1);
  return path.isEmpty ? null : path;
}

/// The friendly-name part of a camera_windows camera name.
String friendlyNameFromCameraName(String cameraName) {
  final cut = cameraName.indexOf(' <');
  return cut > 0 ? cameraName.substring(0, cut) : cameraName;
}

/// Canonicalizes a device interface path down to the device instance part
/// so paths from different APIs compare equal: Media Foundation and
/// DirectShow report the SAME device with different interface-class GUID
/// suffixes (e.g. `#{e5323777-...}\global` vs `#{65e8773d-...}\global`).
///
/// `\\?\usb#vid_x&pid_y#serial#{guid}\global` -> `usb#vid_x&pid_y#serial`
String? canonicalDeviceId(String? devicePath) {
  if (devicePath == null) return null;
  var path = devicePath.toLowerCase();
  if (path.startsWith(r'\\?\') || path.startsWith(r'\\.\')) {
    path = path.substring(4);
  }
  final cut = path.indexOf('#{');
  if (cut > 0) path = path.substring(0, cut);
  return path;
}

/// Applies [values] to the camera identified by [cameraName] (the raw name
/// from camera_windows / availableCameras). Returns a human-readable
/// per-property report; throws [StateError] when the device cannot be
/// found or COM setup fails.
String applyCameraControls(String cameraName, CameraControlValues values) {
  final targetPath = canonicalDeviceId(devicePathFromCameraName(cameraName));
  final targetName = friendlyNameFromCameraName(cameraName).toLowerCase();

  final needsCoUninit = _initializeCom();
  try {
    final filter = _findVideoInputFilter(targetPath, targetName);
    if (filter == nullptr) {
      throw StateError('No DirectShow device matches "$cameraName"');
    }
    try {
      final report = <String>[
        _applyExposure(filter, values),
        _applyProcAmp(filter, _videoProcAmpGain, 'gain', values.gain,
            useDefault: values.autoExposure),
        _applyProcAmp(
            filter, _videoProcAmpBrightness, 'brightness', values.brightness,
            useDefault: values.autoExposure),
      ];
      return report.join('; ');
    } finally {
      _release(filter);
    }
  } finally {
    if (needsCoUninit) _coUninitialize();
  }
}

// --- COM plumbing ---------------------------------------------------------

/// Initializes COM on this thread. Returns whether a matching
/// CoUninitialize is owed. RPC_E_CHANGED_MODE means COM is already up in a
/// different mode - usable as-is, nothing owed.
bool _initializeCom() {
  final hr = _coInitializeEx(nullptr, _coinitApartmentThreaded);
  if (hr.toUnsigned(32) == 0x80010106 /* RPC_E_CHANGED_MODE */) return false;
  if (_failed(hr)) {
    throw StateError('CoInitializeEx failed: 0x${hr.toUnsigned(32).toRadixString(16)}');
  }
  return true;
}

Pointer<_Guid> _guid(Arena arena, String value) {
  final guid = arena<_Guid>();
  final hr = _clsidFromString(value.toNativeUtf16(allocator: arena), guid);
  if (_failed(hr)) {
    throw StateError('Bad GUID $value');
  }
  return guid;
}

/// vtable slot [index] as a COM method with signature
/// `HRESULT (*)(This*, ...)`; each call site casts to its concrete shape.
Pointer<NativeFunction<T>> _method<T extends Function>(
        Pointer<_ComObject> obj, int index) =>
    Pointer.fromAddress((obj.ref.vtable + index).value);

int _release(Pointer<_ComObject> obj) {
  final fn = _method<Uint32 Function(Pointer<_ComObject>)>(obj, 2)
      .asFunction<int Function(Pointer<_ComObject>)>();
  return fn(obj);
}

Pointer<_ComObject> _queryInterface(
    Arena arena, Pointer<_ComObject> obj, String iid) {
  final fn = _method<
          Int32 Function(Pointer<_ComObject>, Pointer<_Guid>,
              Pointer<Pointer<_ComObject>>)>(obj, 0)
      .asFunction<
          int Function(Pointer<_ComObject>, Pointer<_Guid>,
              Pointer<Pointer<_ComObject>>)>();
  final out = arena<Pointer<_ComObject>>();
  final hr = fn(obj, _guid(arena, iid), out);
  return _failed(hr) ? nullptr : out.value;
}

/// Enumerates DirectShow video input devices and returns the bound
/// IBaseFilter for the device whose DevicePath (preferred) or FriendlyName
/// matches. Caller releases the returned filter. Returns nullptr when no
/// device matches.
Pointer<_ComObject> _findVideoInputFilter(
    String? targetPath, String targetName) {
  return using((arena) {
    final devEnumPtr = arena<Pointer<_ComObject>>();
    var hr = _coCreateInstance(
      _guid(arena, _clsidSystemDeviceEnum),
      nullptr,
      _clsctxInprocServer,
      _guid(arena, _iidICreateDevEnum),
      devEnumPtr,
    );
    if (_failed(hr)) {
      throw StateError(
          'SystemDeviceEnum failed: 0x${hr.toUnsigned(32).toRadixString(16)}');
    }
    final devEnum = devEnumPtr.value;

    try {
      // ICreateDevEnum::CreateClassEnumerator (vtable slot 3).
      final createClassEnumerator = _method<
              Int32 Function(Pointer<_ComObject>, Pointer<_Guid>,
                  Pointer<Pointer<_ComObject>>, Uint32)>(devEnum, 3)
          .asFunction<
              int Function(Pointer<_ComObject>, Pointer<_Guid>,
                  Pointer<Pointer<_ComObject>>, int)>();
      final enumPtr = arena<Pointer<_ComObject>>();
      hr = createClassEnumerator(
          devEnum, _guid(arena, _clsidVideoInputDeviceCategory), enumPtr, 0);
      if (hr != _sOk) return nullptr; // S_FALSE: category empty.
      final enumMoniker = enumPtr.value;

      try {
        // IEnumMoniker::Next (vtable slot 3).
        final next = _method<
                Int32 Function(Pointer<_ComObject>, Uint32,
                    Pointer<Pointer<_ComObject>>, Pointer<Uint32>)>(
                enumMoniker, 3)
            .asFunction<
                int Function(Pointer<_ComObject>, int,
                    Pointer<Pointer<_ComObject>>, Pointer<Uint32>)>();

        final monikerPtr = arena<Pointer<_ComObject>>();
        final fetched = arena<Uint32>();
        while (next(enumMoniker, 1, monikerPtr, fetched) == _sOk) {
          final moniker = monikerPtr.value;
          try {
            if (_monikerMatches(arena, moniker, targetPath, targetName)) {
              return _bindToFilter(arena, moniker);
            }
          } finally {
            _release(moniker);
          }
        }
        return nullptr;
      } finally {
        _release(enumMoniker);
      }
    } finally {
      _release(devEnum);
    }
  });
}

/// IMoniker::BindToObject / BindToStorage share this shape (slots 8 / 9:
/// IUnknown 0-2, IPersist 3, IPersistStream 4-7, then IMoniker).
typedef _BindNative = Int32 Function(Pointer<_ComObject>, Pointer<Void>,
    Pointer<Void>, Pointer<_Guid>, Pointer<Pointer<_ComObject>>);
typedef _BindDart = int Function(Pointer<_ComObject>, Pointer<Void>,
    Pointer<Void>, Pointer<_Guid>, Pointer<Pointer<_ComObject>>);

bool _monikerMatches(Arena arena, Pointer<_ComObject> moniker,
    String? targetPath, String targetName) {
  final bindToStorage =
      _method<_BindNative>(moniker, 9).asFunction<_BindDart>();
  final bagPtr = arena<Pointer<_ComObject>>();
  final hr = bindToStorage(
      moniker, nullptr, nullptr, _guid(arena, _iidIPropertyBag), bagPtr);
  if (_failed(hr)) return false;
  final bag = bagPtr.value;

  try {
    final devicePath = canonicalDeviceId(_readBagString(arena, bag, 'DevicePath'));
    if (targetPath != null && devicePath != null) {
      return devicePath == targetPath;
    }
    final friendlyName = _readBagString(arena, bag, 'FriendlyName');
    return friendlyName != null && friendlyName.toLowerCase() == targetName;
  } finally {
    _release(bag);
  }
}

String? _readBagString(Arena arena, Pointer<_ComObject> bag, String property) {
  // IPropertyBag::Read (vtable slot 3).
  final read = _method<
          Int32 Function(Pointer<_ComObject>, Pointer<Utf16>,
              Pointer<_Variant>, Pointer<Void>)>(bag, 3)
      .asFunction<
          int Function(Pointer<_ComObject>, Pointer<Utf16>, Pointer<_Variant>,
              Pointer<Void>)>();
  final variant = arena<_Variant>();
  _variantInit(variant);
  try {
    final hr = read(
        bag, property.toNativeUtf16(allocator: arena), variant, nullptr);
    if (_failed(hr) || variant.ref.vt != _vtBstr) return null;
    final value = variant.ref.ptrValue;
    return value == nullptr ? null : value.toDartString();
  } finally {
    _variantClear(variant);
  }
}

Pointer<_ComObject> _bindToFilter(Arena arena, Pointer<_ComObject> moniker) {
  final bindToObject =
      _method<_BindNative>(moniker, 8).asFunction<_BindDart>();
  final filterPtr = arena<Pointer<_ComObject>>();
  final hr = bindToObject(
      moniker, nullptr, nullptr, _guid(arena, _iidIBaseFilter), filterPtr);
  if (_failed(hr)) {
    throw StateError('BindToObject(IBaseFilter) failed: '
        '0x${hr.toUnsigned(32).toRadixString(16)}');
  }
  return filterPtr.value;
}

// --- Property application --------------------------------------------------

/// IAMCameraControl and IAMVideoProcAmp share the same vtable layout:
/// IUnknown 0-2, GetRange 3, Set 4, Get 5.
typedef _GetRangeNative = Int32 Function(Pointer<_ComObject>, Int32,
    Pointer<Int32>, Pointer<Int32>, Pointer<Int32>, Pointer<Int32>,
    Pointer<Int32>);
typedef _GetRangeDart = int Function(Pointer<_ComObject>, int, Pointer<Int32>,
    Pointer<Int32>, Pointer<Int32>, Pointer<Int32>, Pointer<Int32>);
typedef _SetNative = Int32 Function(Pointer<_ComObject>, Int32, Int32, Int32);
typedef _SetDart = int Function(Pointer<_ComObject>, int, int, int);

_GetRangeDart _getRangeOf(Pointer<_ComObject> obj) =>
    _method<_GetRangeNative>(obj, 3).asFunction<_GetRangeDart>();

_SetDart _setOf(Pointer<_ComObject> obj) =>
    _method<_SetNative>(obj, 4).asFunction<_SetDart>();

String _applyExposure(Pointer<_ComObject> filter, CameraControlValues values) {
  return using((arena) {
    final control = _queryInterface(arena, filter, _iidIAMCameraControl);
    if (control == nullptr) return 'exposure: IAMCameraControl unsupported';
    try {
      final min = arena<Int32>(),
          max = arena<Int32>(),
          step = arena<Int32>(),
          def = arena<Int32>(),
          caps = arena<Int32>();
      final hasRange = _getRangeOf(control)(
              control, _cameraControlExposure, min, max, step, def, caps) ==
          _sOk;

      if (values.autoExposure) {
        final value = hasRange ? def.value : 0;
        final hr = _setOf(control)(
            control, _cameraControlExposure, value, _cameraControlFlagsAuto);
        return _failed(hr)
            ? 'exposure auto: failed 0x${hr.toUnsigned(32).toRadixString(16)}'
            : 'exposure: auto';
      }

      var value = values.exposure;
      if (hasRange) value = value.clamp(min.value, max.value);
      final hr = _setOf(control)(
          control, _cameraControlExposure, value, _cameraControlFlagsManual);
      return _failed(hr)
          ? 'exposure=$value: failed 0x${hr.toUnsigned(32).toRadixString(16)}'
          : 'exposure=$value: OK'
              '${hasRange ? ' (range ${min.value}..${max.value})' : ''}';
    } finally {
      _release(control);
    }
  });
}

String _applyProcAmp(
    Pointer<_ComObject> filter, int property, String label, int requested,
    {required bool useDefault}) {
  return using((arena) {
    final amp = _queryInterface(arena, filter, _iidIAMVideoProcAmp);
    if (amp == nullptr) return '$label: IAMVideoProcAmp unsupported';
    try {
      final min = arena<Int32>(),
          max = arena<Int32>(),
          step = arena<Int32>(),
          def = arena<Int32>(),
          caps = arena<Int32>();
      final hasRange =
          _getRangeOf(amp)(amp, property, min, max, step, def, caps) == _sOk;

      if (useDefault) {
        // Auto exposure mode: return the property to its driver default so
        // a previous manual session doesn't linger.
        if (!hasRange) return '$label: left unchanged';
        final hr =
            _setOf(amp)(amp, property, def.value, _videoProcAmpFlagsManual);
        return _failed(hr)
            ? '$label default: failed 0x${hr.toUnsigned(32).toRadixString(16)}'
            : '$label: default (${def.value})';
      }

      var value = requested;
      if (hasRange) value = value.clamp(min.value, max.value);
      final hr = _setOf(amp)(amp, property, value, _videoProcAmpFlagsManual);
      return _failed(hr)
          ? '$label=$value: failed 0x${hr.toUnsigned(32).toRadixString(16)}'
          : '$label=$value: OK'
              '${hasRange ? ' (range ${min.value}..${max.value})' : ''}';
    } finally {
      _release(amp);
    }
  });
}
