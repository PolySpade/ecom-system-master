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

import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../core/camera_service.dart';
import '../core/database.dart';
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

/// Recording bitrate options in kbit/s (0 = camera default, which on this
/// hardware means ~15-19 Mbit/s from the Media Foundation encoder). New
/// setting for the port - lets originals come out small enough that
/// post-compression is optional.
const List<(String, int)> _kBitrateOptions = [
  ('2 Mbit/s (smallest)', 2000),
  ('4 Mbit/s', 4000),
  ('6 Mbit/s (recommended)', 6000),
  ('8 Mbit/s', 8000),
  ('12 Mbit/s', 12000),
  ('Camera default (largest)', 0),
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settingsManager,
    required this.cameraService,
    required this.database,
  });

  final SettingsManager settingsManager;
  final CameraService cameraService;

  /// For the Storage tab's Backup/Clear actions. The database file itself
  /// always lives beside the application (database.db) and is not
  /// user-relocatable.
  final AppDatabase database;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // --- Video tab state ---
  late String _resolutionPreset;
  late int _fps;
  late String _codec;
  late int _bitrateKbps;

  // --- Camera tab state ---
  List<CameraDescription> _cameras = [];
  bool _refreshingCameras = false;
  late int _cameraIndex;

  // --- Storage tab state ---
  late final TextEditingController _videoPathController;
  late final TextEditingController _logPathController;

  // --- Watermark tab state ---
  late bool _watermarkEnabled;

  // Snapshot of capture-affecting values at open time, for deciding
  // whether Save & Apply must reinitialize the camera (SET-08).
  late final int _originalCameraIndex;
  late final String _originalResolutionPreset;
  late final int _originalFps;
  late final String _originalCodec;
  late final int _originalBitrateKbps;

  @override
  void initState() {
    super.initState();
    final sm = widget.settingsManager;

    final (width, height) = sm.getVideoResolution();
    _resolutionPreset = _presetNameFor(width, height);
    _fps = _kFpsOptions.contains(sm.getVideoFps()) ? sm.getVideoFps() : 30;
    _codec = _codecNameFor(sm.getVideoCodec());
    final storedBitrate =
        (sm.get('video', 'recording_bitrate_kbps', 6000)! as num).toInt();
    _bitrateKbps = _kBitrateOptions.any((o) => o.$2 == storedBitrate)
        ? storedBitrate
        : 6000;

    _cameraIndex = sm.getCameraIndex();

    _videoPathController =
        TextEditingController(text: sm.get('storage', 'video_path') as String? ?? 'videos');
    _logPathController = TextEditingController(
        text: sm.get('storage', 'log_path') as String? ?? 'logs');

    _originalCameraIndex = _cameraIndex;
    _originalResolutionPreset = _resolutionPreset;
    _originalFps = _fps;
    _originalCodec = _codec;
    _originalBitrateKbps = _bitrateKbps;

    _watermarkEnabled =
        sm.get('video', 'watermark_enabled', true)! as bool;

    _refreshCameras();
  }

  @override
  void dispose() {
    _videoPathController.dispose();
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

  /// One-press performance presets (Video tab). They only fill the form
  /// fields - Save & Apply still confirms and applies, so a mis-press is
  /// reversible with Cancel.
  void _applyQuickPreset({
    required String name,
    required String resolutionPreset,
    required int fps,
    required int bitrateKbps,
  }) {
    setState(() {
      _resolutionPreset = resolutionPreset;
      _fps = fps;
      _bitrateKbps = bitrateKbps;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text("$name preset loaded - press Save & Apply to use it"),
      duration: const Duration(seconds: 3),
    ));
  }

  Widget _buildQuickPresets() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Quick presets:',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              icon: const Icon(Icons.speed),
              label: const Text('Low-end PC'),
              onPressed: () => _applyQuickPreset(
                name: 'Low-end PC',
                resolutionPreset: '1280x720 (HD)',
                fps: 30,
                bitrateKbps: 4000,
              ),
            ),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.balance),
              label: const Text('Balanced'),
              onPressed: () => _applyQuickPreset(
                name: 'Balanced',
                resolutionPreset: '1280x720 (HD)',
                fps: 30,
                bitrateKbps: 6000,
              ),
            ),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.high_quality),
              label: const Text('High quality'),
              onPressed: () => _applyQuickPreset(
                name: 'High quality',
                resolutionPreset: '1920x1080 (Full HD)',
                fps: 30,
                bitrateKbps: 8000,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Low-end PC: 720p, 30 FPS, 4 Mbit/s - use this if the preview '
          'or recordings lag on weaker devices.',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
        const Divider(height: 24),
      ],
    );
  }

  Widget _buildVideoTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildQuickPresets(),
        DropdownButtonFormField<String>(
          // Keyed by value so quick presets refresh the displayed selection
          // (a FormField ignores a changed initialValue on rebuild).
          key: ValueKey('resolution-$_resolutionPreset'),
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
        DropdownButtonFormField<int>(
          key: ValueKey('bitrate-$_bitrateKbps'),
          initialValue: _bitrateKbps,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Recording Bitrate',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final (name, kbps) in _kBitrateOptions)
              DropdownMenuItem(value: kbps, child: Text(name)),
          ],
          onChanged: (value) =>
              setState(() => _bitrateKbps = value ?? _bitrateKbps),
        ),
        const SizedBox(height: 4),
        Text(
          'Caps the camera encoder so recordings are small straight from '
          'the camera. At 6 Mbit/s an hour of video is ~2.7 GB before '
          'compression; the camera default writes ~15-19 Mbit/s.',
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

  /// camera_windows appends the raw device path to the friendly name
  /// (e.g. "4k Camera <\\?\usb#vid_..&pid_..#..{guid}\global>"); show only
  /// the human-readable part, matching ecom-py's camera list (SET-02).
  static String _cameraDisplayName(String rawName) {
    final cut = rawName.indexOf(' <');
    return cut > 0 ? rawName.substring(0, cut) : rawName;
  }

  Widget _buildCameraTab() {
    final cameraItems = <DropdownMenuItem<int>>[
      for (var i = 0; i < _cameras.length; i++)
        DropdownMenuItem(
          value: i,
          child: Text(
            '${_cameraDisplayName(_cameras[i].name)} (Index $i)',
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
                      isExpanded: true,
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
        const Divider(height: 32),
        const Text('Database:', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(
          'The transaction database is stored beside the application '
          '(database.db) and cannot be moved.',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 12),
        // Stacked, not side-by-side: both labels together don't fit a
        // phone-width Row without overflowing.
        OutlinedButton.icon(
          onPressed: _backupDatabase,
          icon: const Icon(Icons.save_alt),
          label: const Text('Backup Database...'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _clearDatabase,
          icon: const Icon(Icons.delete_forever),
          style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
          label: const Text('Clear Database...'),
        ),
      ],
    );
  }

  /// Backup Database: checkpoint + copy database.db to a temp file, then
  /// hand it to the Android share sheet (Drive, email, nearby PC, ...) -
  /// the mobile equivalent of the desktop "save as" backup.
  Future<void> _backupDatabase() async {
    final now = DateTime.now();
    final stamp = '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';

    try {
      final backupPath = p.join(
        Directory.systemTemp.path,
        'database_backup_$stamp.db',
      );
      await widget.database.backupTo(backupPath);
      await Share.shareXFiles(
        [XFile(backupPath)],
        subject: 'Ecom Video Tracker database backup',
      );
    } catch (e) {
      await _showInfoDialog('Backup Failed', 'Could not back up database: $e');
    }
  }

  /// Clear Database: deletes every transaction record after an explicit
  /// confirmation. Video files on disk are not touched.
  Future<void> _clearDatabase() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Database'),
        content: const Text(
          'This permanently deletes ALL transaction records.\n\n'
          'Video files on disk are NOT deleted, but they will no longer '
          'appear in Search or Recent Recordings.\n\n'
          'Consider making a backup first. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Clear Database'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final removed = await widget.database.clearAllTransactions();
      await _showInfoDialog(
        'Database Cleared',
        '$removed transaction record(s) deleted.',
      );
    } catch (e) {
      await _showInfoDialog('Error', 'Could not clear database: $e');
    }
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
      ],
    );
  }

  Widget _buildWatermarkTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          title: const Text('Burn watermark into videos'),
          subtitle: const Text(
            'Timestamp, label, and barcode overlaid on the saved file '
            '(runs in the background after each recording saves)',
          ),
          value: _watermarkEnabled,
          onChanged: (v) => setState(() => _watermarkEnabled = v),
        ),
        const SizedBox(height: 8),
        Text(
          'There is no separate compression step on mobile: recordings are '
          'already encoded at the configured recording bitrate. FFmpeg is '
          'built into the app, so no external install is needed.',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
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
      'recording_bitrate_kbps': _bitrateKbps,
      'watermark_enabled': _watermarkEnabled,
    });
    // The 'compression' settings category is deliberately untouched: no
    // compression runs on mobile, but the keys survive round-trips for
    // settings.json compatibility with the desktop app.
    sm.updateCategory('camera', {
      'index': _cameraIndex,
    });
    // database_path is deliberately not written: the database is fixed
    // beside the application (the settings.json key survives for ecom-py
    // compatibility but is not user-editable in this app).
    sm.updateCategory('storage', {
      'video_path': _videoPathController.text.trim(),
      'log_path': _logPathController.text.trim(),
    });
    // The 'app' category is intentionally untouched (Flask host/port do not
    // apply to the Flutter port) and survives round-trips unchanged.

    if (!sm.saveSettings()) {
      await _showInfoDialog('Error', 'Failed to save settings');
      return;
    }

    final captureAffecting = _cameraIndex != _originalCameraIndex ||
        _resolutionPreset != _originalResolutionPreset ||
        _fps != _originalFps ||
        _codec != _originalCodec ||
        _bitrateKbps != _originalBitrateKbps;

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
          'Settings saved but the camera did not restart yet.\n\n'
          'Error: $error\n\n'
          'The app keeps retrying in the background with the new settings; '
          'the preview should return within a few seconds. If it does not, '
          'check the camera connection or restart the application.',
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
        fps: _fps,
        videoBitrate: _bitrateKbps > 0 ? _bitrateKbps * 1000 : null,
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
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Video'),
              Tab(text: 'Camera'),
              Tab(text: 'Watermark'),
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
                  _buildWatermarkTab(),
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
