/// Main Screen - preview + manual barcode entry + Stop button + recordings
/// list.
///
/// Ports the process_barcode orchestration from ecom-py/app_gui.py: the
/// stop-then-start sequential ordering for stopAndStart, the Stop button's
/// disabled-while-idle rule (REC-03), and the live preview independent of
/// recording state (CAM-01).
library;

import 'package:flutter/material.dart';

import '../core/barcode_handler.dart';
import '../core/camera_service.dart';
import '../core/database.dart';
import '../models/transaction.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({
    super.key,
    required this.cameraService,
    required this.database,
    required this.barcodeHandler,
  });

  final CameraService cameraService;
  final AppDatabase database;
  final BarcodeHandler barcodeHandler;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _barcodeController = TextEditingController();
  final _focusNode = FocusNode();

  int? _currentTransactionId;
  String? _statusMessage;
  List<Transaction> _recentTransactions = [];

  @override
  void initState() {
    super.initState();
    _refreshRecentTransactions();
  }

  @override
  void dispose() {
    _barcodeController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _refreshRecentTransactions() async {
    final recent = await widget.database.getRecentTransactions(limit: 10);
    if (!mounted) return;
    setState(() => _recentTransactions = recent);
  }

  Future<void> _showErrorDialog(String title, String message) {
    return showDialog<void>(
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

  Future<void> _submitBarcode() async {
    final rawBarcode = _barcodeController.text;
    final result = widget.barcodeHandler.processBarcode(
      rawBarcode,
      isRecording: widget.cameraService.isRecording,
    );

    if (result.action == BarcodeAction.invalid) {
      await _showErrorDialog(
        'Invalid Barcode',
        'The barcode entered is invalid',
      );
      return;
    }

    try {
      if (result.action == BarcodeAction.start) {
        final filename = await widget.cameraService.startRecording(
          result.barcode,
        );
        _currentTransactionId = await widget.database.createTransaction(
          result.barcode,
          filename,
        );
        setState(() {
          _statusMessage = 'Recording started: ${result.barcode}';
        });
      } else if (result.action == BarcodeAction.stopAndStart) {
        // Stop MUST complete before the new start begins (sequential,
        // matching ecom-py's process_barcode orchestration).
        final stopResult = await widget.cameraService.stopRecording(
          stopMethod: 'barcode',
        );
        if (_currentTransactionId != null) {
          await widget.database.completeTransaction(
            _currentTransactionId!,
            durationSeconds: stopResult.duration,
            fileSizeMb: stopResult.fileSizeMb,
            stopMethod: 'barcode',
          );
        }

        final newFilename = await widget.cameraService.startRecording(
          result.barcode,
        );
        _currentTransactionId = await widget.database.createTransaction(
          result.barcode,
          newFilename,
        );
        setState(() {
          _statusMessage =
              'Switched to: ${result.barcode} (Saved: ${stopResult.duration}s)';
        });
      }

      _barcodeController.clear();
      _focusNode.requestFocus();
      await _refreshRecentTransactions();
      setState(() {});
    } catch (e) {
      await _showErrorDialog('Error', 'Failed to process barcode: $e');
    }
  }

  Future<void> _manualStop() async {
    if (!widget.cameraService.isRecording) {
      await _showErrorDialog('Not Recording', 'No recording in progress');
      return;
    }

    try {
      final stopResult = await widget.cameraService.stopRecording(
        stopMethod: 'manual',
      );
      if (_currentTransactionId != null) {
        await widget.database.completeTransaction(
          _currentTransactionId!,
          durationSeconds: stopResult.duration,
          fileSizeMb: stopResult.fileSizeMb,
          stopMethod: 'manual',
        );
        _currentTransactionId = null;
      }
      setState(() {
        _statusMessage = 'Recording stopped (${stopResult.duration}s)';
      });
      await _refreshRecentTransactions();
    } catch (e) {
      await _showErrorDialog('Error', 'Failed to stop recording: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRecording = widget.cameraService.isRecording;

    return Scaffold(
      appBar: AppBar(title: const Text('Ecom Video Tracker')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 3,
              child: Stack(
                children: [
                  Positioned.fill(child: widget.cameraService.buildPreview()),
                  if (isRecording)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'RECORDING',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _barcodeController,
                    focusNode: _focusNode,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Barcode',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _submitBarcode(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _submitBarcode,
                  child: const Text('Submit'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: isRecording ? _manualStop : null,
                  child: const Text('Stop Recording'),
                ),
              ],
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 8),
              Text(_statusMessage!),
            ],
            const SizedBox(height: 16),
            Expanded(
              flex: 2,
              child: ListView.builder(
                itemCount: _recentTransactions.length,
                itemBuilder: (context, index) {
                  final t = _recentTransactions[index];
                  return ListTile(
                    title: Text(t.barcode),
                    subtitle: Text(t.videoFilename),
                    trailing: Text(t.stopMethod ?? 'in progress'),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
