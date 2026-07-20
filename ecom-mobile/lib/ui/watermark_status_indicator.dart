/// Watermark Status Indicator - small self-contained readout of the
/// watermark worker's queue state (status panel surface).
library;

import 'package:flutter/material.dart';

import '../core/watermark_service.dart';

/// Live one-line watermark queue status, driven by
/// [WatermarkService.queueStatus].
class WatermarkStatusIndicator extends StatelessWidget {
  const WatermarkStatusIndicator({super.key, required this.watermarkService});

  final WatermarkService watermarkService;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<WatermarkQueueStatus>(
      valueListenable: watermarkService.queueStatus,
      builder: (context, status, _) {
        // pendingCount includes the in-flight job.
        final waiting = status.isProcessing
            ? status.pendingCount - 1
            : status.pendingCount;
        final String text;
        if (status.isProcessing) {
          text = waiting > 0
              ? 'Watermarking... ($waiting queued)'
              : 'Watermarking...';
        } else if (waiting > 0) {
          text = 'Watermark queued: $waiting';
        } else {
          text = 'Watermark: idle';
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
                Icons.branding_watermark_outlined,
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
