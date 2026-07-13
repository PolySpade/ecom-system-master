/// Settings Screen - tabbed settings editor (SET-02..05, SET-07, SET-08).
///
/// Behavioral port of ecom-py/app_gui.py's SettingsDialog: Video / Camera /
/// Storage tabs, Reset to Defaults / Cancel / Save & Apply buttons, and an
/// async camera reinitialization with a progress dialog when
/// capture-affecting settings change. The Compression tab is Phase 3 scope
/// (SET-06) and the Web App tab does not apply to the Flutter port (the
/// 'app' settings category is preserved untouched in settings.json for
/// ecom-py compatibility).
library;

import 'package:camera/camera.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/camera_service.dart';
import '../core/settings_manager.dart';

/// Resolution presets, matching SettingsDialog.RESOLUTION_PRESETS.
const List<(String, int, int)> _kResolutionPresets = [
  ('640x480', 640, 480),
  ('1280x720 (HD)', 1280, 720),
  ('1920x1080 (Full HD)', 1920, 1080),
  ('2560x1440 (2K)', 2560, 1440),
  ('3840x2160 (4K)', 3840, 2160),
];

/// Codec options, matching SettingsDialog.CODEC_OPTIONS. The setting is
/// persisted for ecom-py parity (SET-03); the Windows capture backend
/// (Media Foundation via camera_windows) chooses the actual encoder.
const List<(String, String)> _kCodecOptions = [
  ('MP4V (Recommended)', 'mp4v'),
  ('H264', 'avc1'),
  ('XVID', 'XVID'),
  ('MJPEG', 'MJPG'),
];

/// FPS options, matching SettingsDialog.FPS_OPTIONS (SET-02).
const List<int> _kFpsOptions = [15, 24, 30, 60];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settingsManager,
    required this.cameraService,
  });

  final SettingsManager settingsManager;
  final CameraService cameraService;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // --- Video tab state ---
  late String _resolutionPreset;
  late int _fps;
  late String _codec;

  // --- Camera tab state ---
  List<CameraDescription> _cameras = [];
  bool _refreshingCameras = false;
  late int _cameraIndex;
  late bool _autoExposure;
  late double _exposure;
  late double _gain;
  late double _brightness;

  // --- Storage tab state ---
  late final TextEditingController _videoPathController;
  late final TextEditingController _dbPathController;
  late final TextEditingController _logPathController;

  // Snapshot of capture-affecting values at open time, for deciding
  // whether Save & Apply must reinitialize the camera (SET-08).
  late final int _originalCameraIndex;
  late final String _originalResolutionPreset;
  late final int _originalFps;
  late final String _originalCodec;

  @override
  void initState() {
    super.initState();
    final sm = widget.settingsManager;

    final (width, height) = sm.getVideoResolution();
    _resolutionPreset = _presetNameFor(width, height);
    _fps = _kFpsOptions.contains(sm.getVideoFps()) ? sm.getVideoFps() : 30;
    _codec = _codecNameFor(sm.getVideoCodec());

    _cameraIndex = sm.getCameraIndex();
    _autoExposure = sm.getCameraAutoExposure();
    _exposure = sm.getCameraExposure().clamp(-13, -1).toDouble();
    _gain = sm.getCameraGain().clamp(0, 255).toDouble();
    _brightness = sm.getCameraBrightness().clamp(0, 255).toDouble();

    _videoPathController =
        TextEditingController(text: sm.get('storage', 'video_path') as String? ?? 'videos');
    _dbPathController = TextEditingController(
        text: sm.get('storage', 'database_path') as String? ?? 'database.db');
    _logPathController = TextEditingController(
        text: sm.get('storage', 'log_path') as String? ?? 'logs');

    _originalCameraIndex = _cameraIndex;
    _originalResolutionPreset = _resolutionPreset;
    _originalFps = _fps;
    _originalCodec = _codec;

    _refreshCameras();
  }

  @override
  void dispose() {
    _videoPathController.dispose();
    _dbPathController.dispose();
    _logPathController.dispose();
    super.dispose();
  }

  static String _presetNameFor(int width, int height) {
    for (final (name, w, h) in _kResolutionPresets) {
      if (w == width && h == height) return name;
    }
    return '1280x720 (HD)';
  }

  static String _codecNameFor(String codec) {
    for (final (name, value) in _kCodecOptions) {
      if (value == codec) return name;
    }
    return 'MP4V (Recommended)';
  }

  (int, int) get _selectedResolution {
    for (final (name, w, h) in _kResolutionPresets) {
      if (name == _resolutionPreset) return (w, h);
    }
    return (1280, 720);
  }

  String get _selectedCodec {
    for (final (name, value) in _kCodecOptions) {
      if (name == _codec) return value;
    }
    return 'mp4v';
  }

  /// Non-blocking camera enumeration for the dropdown (the plugin call is
  /// async; the UI shows a spinner while it runs).
  Future<void> _refreshCameras() async {
    setState(() => _refreshingCameras = true);
    try {
      final cameras = await CameraService.listCameras();
      if (!mounted) return;
      setState(() {
        _cameras = cameras;
        _refreshingCameras = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cameras = [];
        _refreshingCameras = false;
      });
    }
  }

  // --- Tabs ---

  Widget _buildVideoTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        DropdownButtonFormField<String>(
          initialValue: _resolutionPreset,
          decoration: const InputDecoration(
            labelText: 'Resolution',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final (name, _, _) in _kResolutionPresets)
              DropdownMenuItem(value: name, child: Text(name)),
          ],
          onChanged: (value) =>
              setState(() => _resolutionPreset = value ?? _resolutionPreset),
        ),
        const SizedBox(height: 4),
        Text(
          'Note: the Windows capture backend maps the resolution to its '
          'nearest supported preset.',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 16),
        const Text('FPS (Frames Per Second):',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: [
            for (final fps in _kFpsOptions)
              ButtonSegment(value: fps, label: Text('$fps FPS')),
          ],
          selected: {_fps},
          onSelectionChanged: (selection) =>
              setState(() => _fps = selection.first),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: _codec,
          decoration: const InputDecoration(
            labelText: 'Video Codec',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final (name, _) in _kCodecOptions)
              DropdownMenuItem(value: name, child: Text(name)),
          ],
          onChanged: (value) => setState(() => _codec = value ?? _codec),
        ),
        const SizedBox(height: 4),
        Text(
          'Persisted for ecom-py parity; the Windows capture backend '
          '(Media Foundation) selects the actual recording encoder. '
          'Higher resolution and FPS require more storage.',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _buildCameraTab() {
    final cameraItems = <DropdownMenuItem<int>>[
      for (var i = 0; i < _cameras.length; i++)
        DropdownMenuItem(
          value: i,
          child: Text(
            '${_cameras[i].name} (Index $i)',
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
    final selectedCameraIndex =
        _cameraIndex < _cameras.length ? _cameraIndex : null;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: _refreshingCameras
                  ? const InputDecorator(
                      decoration: InputDecoration(
                        labelText: 'Select Camera',
                        border: OutlineInputBorder(),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 8),
                          Text('Refreshing cameras...'),
                        ],
                      ),
                    )
                  : DropdownButtonFormField<int>(
                      key: ValueKey(_cameras.length),
                      initialValue: selectedCameraIndex,
                      decoration: const InputDecoration(
                        labelText: 'Select Camera',
                        border: OutlineInputBorder(),
                      ),
                      hint: const Text('No cameras detected'),
                      items: cameraItems,
                      onChanged: (value) =>
                          setState(() => _cameraIndex = value ?? _cameraIndex),
                    ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _refreshingCameras ? null : _refreshCameras,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh Cameras'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          "Click 'Refresh Cameras' if your camera is not shown.",
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
        const Divider(height: 32),
        const Text('Exposure Settings:',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.amber.shade100,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.amber.shade400),
          ),
          child: Row(
            children: [
              Icon(Icons.warning_amber, size: 18, color: Colors.amber.shade900),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Manual exposure, gain, and brightness are NOT supported '
                  'by the current Windows camera backend (camera_windows). '
                  'Values are saved to settings.json but cannot be applied '
                  'to the camera yet.',
                  style: TextStyle(fontSize: 11, color: Colors.amber.shade900),
                ),
              ),
            ],
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Auto Exposure'),
          subtitle: const Text('Turn off for manual control (unsupported on '
              'this backend - persisted only)'),
          value: _autoExposure,
          onChanged: (value) => setState(() => _autoExposure = value),
        ),
        _buildSlider(
          label: 'Exposure',
          hint: '(darker <-> brighter)',
          value: _exposure,
          min: -13,
          max: -1,
          onChanged:
              _autoExposure ? null : (v) => setState(() => _exposure = v),
        ),
        _buildSlider(
          label: 'Gain',
          hint: '(amplification)',
          value: _gain,
          min: 0,
          max: 255,
          onChanged: _autoExposure ? null : (v) => setState(() => _gain = v),
        ),
        _buildSlider(
          label: 'Brightness',
          hint: '(image brightness)',
          value: _brightness,
          min: 0,
          max: 255,
          onChanged:
              _autoExposure ? null : (v) => setState(() => _brightness = v),
        ),
      ],
    );
  }

  Widget _buildSlider({
    required String label,
    required String hint,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double>? onChanged,
  }) {
    return Row(
      children: [
        SizedBox(width: 90, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: (max - min).round(),
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 36, child: Text('${value.round()}')),
        Text(hint,
            style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
      ],
    );
  }

  Widget _buildStorageTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildPathField(
          label: 'Video Storage Path',
          controller: _videoPathController,
          pickDirectory: true,
        ),
        const SizedBox(height: 16),
        _buildPathField(
          label: 'Database Path',
          controller: _dbPathController,
          pickDirectory: false,
        ),
        const SizedBox(height: 16),
        _buildPathField(
          label: 'Log Storage Path',
          controller: _logPathController,
          pickDirectory: true,
        ),
        const SizedBox(height: 12),
        Text(
          'Use relative or absolute paths. Restart the app after changing '
          'storage paths.',
          style: TextStyle(
            fontSize: 11,
            fontStyle: FontStyle.italic,
            color: Colors.grey.shade600,
          ),
        ),
      ],
    );
  }

  Widget _buildPathField({
    required String label,
    required TextEditingController controller,
    required bool pickDirectory,
  }) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: () async {
            if (pickDirectory) {
              final path = await getDirectoryPath();
              if (path != null) controller.text = path;
            } else {
              final file = await openFile(acceptedTypeGroups: const [
                XTypeGroup(label: 'Database', extensions: ['db']),
                XTypeGroup(label: 'All files'),
              ]);
              if (file != null) controller.text = file.path;
            }
          },
          child: const Text('Browse'),
        ),
      ],
    );
  }

  // --- Buttons ---

  /// Reset to Defaults: confirm, reset the in-memory settings, close the
  /// screen (matching the reference, which does not persist the reset -
  /// Save & Apply afterwards writes it to disk).
  Future<void> _resetDefaults() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Settings'),
        content: const Text('Reset all settings to default values?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    widget.settingsManager.resetToDefaults();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Settings Reset'),
        content: const Text('Settings have been reset to defaults.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  /// Save & Apply (SET-08): persist all tab values through SettingsManager;
  /// when capture-affecting settings changed, reinitialize the camera
  /// asynchronously behind a non-dismissible progress dialog.
  Future<void> _saveSettings() async {
    final sm = widget.settingsManager;
    final (width, height) = _selectedResolution;

    sm.updateCategory('video', {
      'resolution_width': width,
      'resolution_height': height,
      'fps': _fps,
      'codec': _selectedCodec,
    });
    sm.updateCategory('camera', {
      'index': _cameraIndex,
      'auto_exposure': _autoExposure,
      'exposure': _exposure.round(),
      'gain': _gain.round(),
      'brightness': _brightness.round(),
    });
    sm.updateCategory('storage', {
      'video_path': _videoPathController.text.trim(),
      'database_path': _dbPathController.text.trim(),
      'log_path': _logPathController.text.trim(),
    });
    // 'app' and 'compression' categories are intentionally untouched here:
    // compression settings are Phase 3 scope (SET-06) and app settings do
    // not apply to the Flutter port - both survive round-trips unchanged.

    if (!sm.saveSettings()) {
      await _showInfoDialog('Error', 'Failed to save settings');
      return;
    }

    final captureAffecting = _cameraIndex != _originalCameraIndex ||
        _resolutionPreset != _originalResolutionPreset ||
        _fps != _originalFps ||
        _codec != _originalCodec;

    if (captureAffecting) {
      final error = await _reinitializeCameraWithProgress(width, height);
      if (!mounted) return;
      if (error == null) {
        await _showInfoDialog(
          'Settings Saved',
          'Settings saved and camera restarted.',
        );
      } else {
        await _showInfoDialog(
          'Settings Saved',
          'Settings saved but camera restart failed.\n\n'
          'Error: $error\n\nPlease restart the application.',
        );
      }
    } else {
      await _showInfoDialog('Settings Saved', 'Settings saved.');
    }

    if (mounted) Navigator.of(context).pop(true);
  }

  /// Runs the async camera reinit behind a non-dismissible progress dialog.
  /// Returns null on success, or the error message.
  Future<String?> _reinitializeCameraWithProgress(
    int width,
    int height,
  ) async {
    // Non-dismissible progress dialog (the SET-08 progress requirement).
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text('Applying Settings'),
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Expanded(child: Text('Restarting camera...\nPlease wait...')),
            ],
          ),
        ),
      ),
    );

    String? error;
    try {
      await widget.cameraService.reinitialize(
        _cameraIndex,
        resolutionPreset: resolutionPresetFor(width, height),
      );
    } catch (e) {
      error = '$e';
    }

    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop(); // close progress
    }
    return error;
  }

  Future<void> _showInfoDialog(String title, String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Video'),
              Tab(text: 'Camera'),
              Tab(text: 'Storage'),
            ],
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: TabBarView(
                children: [
                  _buildVideoTab(),
                  _buildCameraTab(),
                  _buildStorageTab(),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _resetDefaults,
                      child: const Text('Reset to Defaults'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: _saveSettings,
                      child: const Text('Save & Apply'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
