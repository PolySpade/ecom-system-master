/// Search Screen - video library grid (SRCH-01..SRCH-08).
///
/// Behavioral port of ecom-py/app_gui.py's SearchWindow, redesigned as a
/// mobile library: opening the screen loads every recording immediately (no
/// explicit "Search" action needed) into a grid of tiles color-coded by
/// Video Label, with a persistent barcode search bar and the Label/Date
/// range/Sort filters (SRCH-02..04) tucked into a bottom sheet so they don't
/// compete with the grid for screen space. Tapping a tile plays it,
/// long-pressing (or its share icon) shares it (SRCH-06). Esc / Ctrl+F / F5
/// keyboard shortcuts (SRCH-07) are preserved for external keyboards.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../core/database.dart';
import '../core/file_paths.dart';
import '../core/video_actions.dart';
import '../models/transaction.dart';

/// Header/accent purple from the reference UI (#667eea).
const Color _kAccentColor = Color(0xFF667EEA);

/// Label badge/tile colors, exactly the SearchWindow.create_result_card map.
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
  /// used with [resolveVideoPath] for Play / Share (SRCH-06).
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

  bool _loading = true;
  List<Transaction> _results = [];
  int _total = 0;

  bool get _filtersActive =>
      _labelFilter != _kLabelOptions.first ||
      _startDate != null ||
      _endDate != null ||
      _sortOption != _kSortOptions.first;

  @override
  void initState() {
    super.initState();
    // Don't request focus here - that would pop the soft keyboard open
    // immediately and cover the library grid before the user asked for it.
    // The search bar only gets focus (and the keyboard) when tapped.
    //
    // Library view: every recording loads immediately, no explicit search
    // action required.
    _performSearch();
  }

  @override
  void dispose() {
    _barcodeController.dispose();
    _barcodeFocusNode.dispose();
    super.dispose();
  }

  /// Runs the search with the current filters (SRCH-01..04). Bound to
  /// screen open, the barcode field, the filter sheet's Apply, and F5
  /// (SRCH-07).
  Future<void> _performSearch() async {
    setState(() => _loading = true);

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
      _loading = false;
      _results = result.results;
      _total = result.total;
    });
  }

  /// Resolves the transaction's file location, trying the label folder
  /// first and falling back to the legacy pre-label-folder layout
  /// (SRCH-06). Absolute Phase-1 rows pass through; ecom-py rows (basename)
  /// resolve through the layout fallbacks. Null when not found on disk.
  String? _resolvePath(Transaction t) {
    return resolveVideoPath(
      widget.videoStoragePath,
      startTime: t.startTime,
      label: t.label,
      videoFilename: t.videoFilename,
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
    final path = _resolvePath(t);
    if (path == null) {
      await _showError('Video file not found:\n${t.videoFilename}');
      return;
    }
    final error = await openVideo(path);
    if (error != null) await _showError(error);
  }

  Future<void> _shareVideo(Transaction t) async {
    final path = _resolvePath(t);
    if (path == null) {
      await _showError('Video file not found:\n${t.videoFilename}');
      return;
    }
    final error = await shareVideo(path);
    if (error != null) await _showError(error);
  }

  /// Opens the Label/Date range/Sort filter sheet. Edits are staged in the
  /// sheet's own [StatefulBuilder] state and only committed (and searched)
  /// on "Apply Filters" - writing straight to this State's fields instead
  /// would rebuild the screen behind the sheet, not the sheet's own
  /// dropdowns/date fields, so picks would silently appear not to do
  /// anything until the sheet was reopened.
  Future<void> _openFilterSheet() async {
    var sheetLabel = _labelFilter;
    var sheetStart = _startDate;
    var sheetEnd = _endDate;
    var sheetSort = _sortOption;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            Future<void> pickDate({required bool isStart}) async {
              final now = DateTime.now();
              final picked = await showDatePicker(
                context: sheetContext,
                initialDate: (isStart ? sheetStart : sheetEnd) ?? now,
                firstDate: DateTime(2020),
                lastDate: DateTime(now.year + 1, 12, 31),
              );
              if (picked == null) return;
              setSheetState(() {
                if (isStart) {
                  sheetStart = picked;
                } else {
                  sheetEnd = picked;
                }
              });
            }

            Widget dateField({required String label, required bool isStart}) {
              final value = isStart ? sheetStart : sheetEnd;
              final text = value == null
                  ? 'Any'
                  : DateFormat('yyyy-MM-dd').format(value);
              return Expanded(
                child: InkWell(
                  onTap: () => pickDate(isStart: isStart),
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
                              onPressed: () => setSheetState(() {
                                if (isStart) {
                                  sheetStart = null;
                                } else {
                                  sheetEnd = null;
                                }
                              }),
                            ),
                    ),
                    child: Text(text),
                  ),
                ),
              );
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: 16 + MediaQuery.viewInsetsOf(sheetContext).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Theme.of(sheetContext).colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Text(
                    'Filters',
                    style: Theme.of(sheetContext).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: sheetLabel,
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
                    onChanged: (value) => setSheetState(
                      () => sheetLabel = value ?? 'All Labels',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      dateField(label: 'Start Date', isStart: true),
                      const SizedBox(width: 8),
                      dateField(label: 'End Date', isStart: false),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: sheetSort,
                    decoration: const InputDecoration(
                      labelText: 'Sort By',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final option in _kSortOptions)
                        DropdownMenuItem(value: option, child: Text(option)),
                    ],
                    onChanged: (value) => setSheetState(
                      () => sheetSort = value ?? _kSortOptions.first,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            setSheetState(() {
                              sheetLabel = _kLabelOptions.first;
                              sheetStart = null;
                              sheetEnd = null;
                              sheetSort = _kSortOptions.first;
                            });
                          },
                          child: const Text('Clear'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: _kAccentColor,
                          ),
                          onPressed: () {
                            setState(() {
                              _labelFilter = sheetLabel;
                              _startDate = sheetStart;
                              _endDate = sheetEnd;
                              _sortOption = sheetSort;
                            });
                            Navigator.of(sheetContext).pop();
                            _performSearch();
                          },
                          child: const Text('Apply Filters'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Persistent barcode search bar (the primary/most common search vector)
  /// plus a filter icon that opens [_openFilterSheet] for the less-common
  /// Label/Date/Sort filters.
  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _barcodeController,
              focusNode: _barcodeFocusNode,
              decoration: InputDecoration(
                hintText: 'Search by barcode',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _barcodeController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: 'Clear',
                        onPressed: () {
                          _barcodeController.clear();
                          setState(() {});
                          _performSearch();
                        },
                      ),
                filled: true,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _performSearch(),
            ),
          ),
          const SizedBox(width: 8),
          Badge(
            isLabelVisible: _filtersActive,
            smallSize: 8,
            child: IconButton.filledTonal(
              icon: const Icon(Icons.tune),
              tooltip: 'Filters',
              onPressed: _openFilterSheet,
            ),
          ),
        ],
      ),
    );
  }

  /// One library tile: a label-colored thumbnail area (no real video-frame
  /// preview - see the barcode/duration caption below it) with a play icon,
  /// a duration badge, and a share shortcut, plus a barcode + date/size
  /// caption. Tap plays the video; long-press or the share icon shares it.
  Widget _buildLibraryTile(Transaction t) {
    final badgeColor = _kLabelColors[t.label] ?? const Color(0xFF10B981);
    final duration = t.durationSeconds ?? 0;
    final minutes = (duration ~/ 60).toString().padLeft(2, '0');
    final seconds = (duration % 60).toString().padLeft(2, '0');
    final fileSize = t.fileSizeMb ?? 0.0;

    var dateText = t.startTime;
    try {
      dateText = DateFormat('MMM d').format(DateTime.parse(t.startTime));
    } catch (_) {
      // Leave the raw value if it isn't ISO-parseable.
    }

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _playVideo(t),
        onLongPress: () => _shareVideo(t),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ColoredBox(
                color: badgeColor,
                child: Stack(
                  children: [
                    const Center(
                      child: Icon(
                        Icons.play_circle_fill,
                        color: Colors.white,
                        size: 40,
                      ),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      child: IconButton(
                        icon: const Icon(
                          Icons.share,
                          color: Colors.white,
                          size: 18,
                        ),
                        tooltip: 'Share',
                        onPressed: () => _shareVideo(t),
                      ),
                    ),
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black45,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '$minutes:$seconds',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.barcode,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    '$dateText · ${fileSize.toStringAsFixed(1)}MB',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
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

  Widget _buildLibrary() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isEmpty) {
      return const Center(child: Text('No recordings found'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            _total > _results.length
                ? 'Showing ${_results.length} of $_total'
                : '$_total recording(s)',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.78,
            ),
            itemCount: _results.length,
            itemBuilder: (context, index) => _buildLibraryTile(_results[index]),
          ),
        ),
      ],
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
            title: const Text('Video Library'),
            backgroundColor: _kAccentColor,
            foregroundColor: Colors.white,
          ),
          body: Column(
            children: [_buildSearchBar(), Expanded(child: _buildLibrary())],
          ),
        ),
      ),
    );
  }
}
