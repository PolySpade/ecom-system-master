/// Search Screen - full-featured recording search (SRCH-01..SRCH-08).
///
/// Behavioral port of ecom-py/app_gui.py's SearchWindow: partial
/// case-insensitive barcode search, Video Label filter defaulting to
/// "All Labels", optional/clearable calendar date range, sort options,
/// result cards with color-coded label badges and Play / Show-in-Folder
/// actions, a "Showing X of Y" footer, and Esc / Ctrl+F / F5 keyboard
/// shortcuts.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../core/database.dart';
import '../core/file_paths.dart';
import '../core/video_actions.dart';
import '../models/transaction.dart';

/// Header/accent purple from the reference UI (#667eea).
const Color _kAccentColor = Color(0xFF667EEA);

/// Label badge colors, exactly the SearchWindow.create_result_card map.
const Map<String, Color> _kLabelColors = {
  'Return and Refund Unboxing': Color(0xFFDC2626),
  'Return Parcel Unboxing': Color(0xFFF59E0B),
  'Normal (Standard)': Color(0xFF10B981),
};

/// Label filter options (SRCH-02), in the reference's order.
const List<String> _kLabelOptions = [
  'All Labels',
  'Return and Refund Unboxing',
  'Return Parcel Unboxing',
  'Normal (Standard)',
];

/// Sort options (SRCH-04), matching the reference's combobox values.
const List<String> _kSortOptions = [
  'Date (Newest)',
  'Date (Oldest)',
  'Barcode',
  'Duration',
  'File Size',
];

/// Maximum result page size, matching SearchWindow.perform_search.
const int _kSearchLimit = 100;

class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.database,
    required this.videoStoragePath,
  });

  final AppDatabase database;

  /// Resolved base folder recordings live under (config.videoStoragePath),
  /// used with [resolveVideoPath] for Play / Show-in-Folder (SRCH-06).
  final String videoStoragePath;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _barcodeController = TextEditingController();
  final _barcodeFocusNode = FocusNode();

  String _labelFilter = _kLabelOptions.first;
  DateTime? _startDate;
  DateTime? _endDate;
  String _sortOption = _kSortOptions.first;

  bool _searched = false;
  List<Transaction> _results = [];
  int _total = 0;

  @override
  void initState() {
    super.initState();
    // Focus the barcode field on open, like the reference window.
    _barcodeFocusNode.requestFocus();
  }

  @override
  void dispose() {
    _barcodeController.dispose();
    _barcodeFocusNode.dispose();
    super.dispose();
  }

  /// Runs the search with the current filters (SRCH-01..04). Bound to the
  /// Search button, Enter in the barcode field, and F5 (SRCH-07).
  Future<void> _performSearch() async {
    final barcode = _barcodeController.text.trim();

    var sortBy = 'created_at';
    var sortOrder = 'DESC';
    switch (_sortOption) {
      case 'Date (Oldest)':
        sortBy = 'created_at';
        sortOrder = 'ASC';
      case 'Barcode':
        sortBy = 'barcode';
        sortOrder = 'ASC';
      case 'Duration':
        sortBy = 'duration_seconds';
        sortOrder = 'DESC';
      case 'File Size':
        sortBy = 'file_size_mb';
        sortOrder = 'DESC';
    }

    final dateFormat = DateFormat('yyyy-MM-dd');
    final result = await widget.database.advancedSearch(
      barcode: barcode.isEmpty ? null : barcode,
      startDate: _startDate == null ? null : dateFormat.format(_startDate!),
      endDate: _endDate == null ? null : dateFormat.format(_endDate!),
      label: _labelFilter == 'All Labels' ? null : _labelFilter,
      sortBy: sortBy,
      sortOrder: sortOrder,
      limit: _kSearchLimit,
    );

    if (!mounted) return;
    setState(() {
      _searched = true;
      _results = result.results;
      _total = result.total;
    });
  }

  /// Clears all filters and results back to the initial state.
  void _clearFilters() {
    setState(() {
      _barcodeController.clear();
      _labelFilter = _kLabelOptions.first;
      _startDate = null;
      _endDate = null;
      _sortOption = _kSortOptions.first;
      _searched = false;
      _results = [];
      _total = 0;
    });
  }

  Future<void> _pickDate({required bool isStart}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: (isStart ? _startDate : _endDate) ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 1, 12, 31),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _startDate = picked;
      } else {
        _endDate = picked;
      }
    });
  }

  /// Resolves the transaction's file location, trying the label folder
  /// first and falling back to the legacy pre-label-folder layout
  /// (SRCH-06). Uses the basename so rows written by either app (ecom-py
  /// stores the basename; earlier Flutter builds stored the full path)
  /// resolve identically.
  String _resolvePath(Transaction t) {
    return resolveVideoPath(
      basePath: widget.videoStoragePath,
      startTime: t.startTime,
      label: t.label,
      videoFilename: p.basename(t.videoFilename),
    );
  }

  Future<void> _showError(String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
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

  Future<void> _playVideo(Transaction t) async {
    final error = await openVideo(_resolvePath(t));
    if (error != null) await _showError(error);
  }

  Future<void> _revealVideo(Transaction t) async {
    final error = await showInFolder(_resolvePath(t));
    if (error != null) await _showError(error);
  }

  Widget _buildDateField({required String label, required bool isStart}) {
    final value = isStart ? _startDate : _endDate;
    final text =
        value == null ? 'Any' : DateFormat('yyyy-MM-dd').format(value);
    return Expanded(
      child: InkWell(
        onTap: () => _pickDate(isStart: isStart),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: value == null
                ? const Icon(Icons.calendar_today, size: 18)
                : IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    tooltip: 'Clear date',
                    onPressed: () => setState(() {
                      if (isStart) {
                        _startDate = null;
                      } else {
                        _endDate = null;
                      }
                    }),
                  ),
          ),
          child: Text(text),
        ),
      ),
    );
  }

  Widget _buildFilters() {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _barcodeController,
                    focusNode: _barcodeFocusNode,
                    decoration: const InputDecoration(
                      labelText: 'Barcode',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _performSearch(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    initialValue: _labelFilter,
                    decoration: const InputDecoration(
                      labelText: 'Label',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final option in _kLabelOptions)
                        DropdownMenuItem(
                          value: option,
                          child: Text(option, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (value) =>
                        setState(() => _labelFilter = value ?? 'All Labels'),
                  ),
                ),
                const SizedBox(width: 8),
                _buildDateField(label: 'Start Date', isStart: true),
                const SizedBox(width: 8),
                _buildDateField(label: 'End Date', isStart: false),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 220,
                  child: DropdownButtonFormField<String>(
                    initialValue: _sortOption,
                    decoration: const InputDecoration(
                      labelText: 'Sort By',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final option in _kSortOptions)
                        DropdownMenuItem(value: option, child: Text(option)),
                    ],
                    onChanged: (value) => setState(
                      () => _sortOption = value ?? _kSortOptions.first,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: _kAccentColor),
                  onPressed: _performSearch,
                  icon: const Icon(Icons.search),
                  label: const Text('Search'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _clearFilters,
                  child: const Text('Clear'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard(Transaction t) {
    final label = t.label;
    final badgeColor = _kLabelColors[label] ?? const Color(0xFF10B981);

    String startTimeText = t.startTime;
    try {
      startTimeText =
          DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.parse(t.startTime));
    } catch (_) {
      // Leave the raw value if it isn't ISO-parseable.
    }
    final duration = t.durationSeconds ?? 0;
    final fileSize = t.fileSizeMb ?? 0.0;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t.barcode,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: _kAccentColor,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: badgeColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    label,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '$startTimeText   |   ${duration}s   |   '
              '${fileSize.toStringAsFixed(2)}MB',
              style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              p.basename(t.videoFilename),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: _kAccentColor),
                  onPressed: () => _playVideo(t),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('Play Video'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => _revealVideo(t),
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Show in Folder'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (!_searched) {
      return const Center(
        child: Text('Enter search criteria and click Search'),
      );
    }
    if (_results.isEmpty) {
      return const Center(child: Text('No recordings found'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            'Found $_total recording(s)',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _results.length,
            itemBuilder: (context, index) => _buildResultCard(_results[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildFooter() {
    final text = _searched
        ? 'Showing ${_results.length} of $_total results'
        : 'Ready to search';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Text(text),
    );
  }

  @override
  Widget build(BuildContext context) {
    // SRCH-07 keyboard shortcuts: Esc closes, Ctrl+F focuses the barcode
    // field, F5 re-runs the search. CallbackShortcuts sits above the whole
    // screen so the bindings fire while any descendant (including the
    // barcode TextField) has focus.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
            _barcodeFocusNode.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.f5): _performSearch,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Search Recordings'),
            backgroundColor: _kAccentColor,
            foregroundColor: Colors.white,
            actions: const [
              Center(
                child: Padding(
                  padding: EdgeInsets.only(right: 16),
                  child: Text(
                    'ESC to close | Ctrl+F to focus search | F5 to refresh',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              _buildFilters(),
              Expanded(child: _buildResults()),
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }
}
