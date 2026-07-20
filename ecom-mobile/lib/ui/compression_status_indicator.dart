/// Compression Status Indicator - small self-contained readout of the
/// compressor's queue state (COMP-05 UI surface).
///
/// Phase 2 owns the main screen; this widget only needs a
/// [VideoCompressor] and can be slotted into the status panel at merge
/// time (UI-01's "compression queue" readout).
library;

import 'package:flutter/material.dart';

import '../core/video_compressor.dart';

/// Live one-line compression queue status, driven by
/// [VideoCompressor.queueStatus].
class CompressionStatusIndicator extends StatelessWidget {
  const CompressionStatusIndicator({super.key, required this.compressor});

  final VideoCompressor compressor;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CompressionQueueStatus>(
      valueListenable: compressor.queueStatus,
      builder: (context, status, _) {
        final String text;
        if (status.isProcessing) {
          text = status.queueSize > 0
              ? 'Compressing... (${status.queueSize} queued)'
              : 'Compressing...';
        } else if (status.queueSize > 0) {
          text = 'Compression queued: ${status.queueSize}';
        } else {
          text = 'Compression: idle';
        }

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (status.isProcessing)
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                Icons.compress,
                size: 14,
                color: Theme.of(context).colorScheme.outline,
              ),
            const SizedBox(width: 6),
            Text(text, style: Theme.of(context).textTheme.bodySmall),
          ],
        );
      },
    );
  }
}
