#pragma once

#include <QObject>
#include <QThread>
#include <QQueue>
#include <QMutex>
#include <QString>
#include <QProcess>
#include <QVariantMap>
#include <QPair>
#include <atomic>

struct CompressionJob {
    QString videoPath;
    int transactionId;
    QString codec;       // "h264" or "h265"
    int crf;             // 18-35
    QString preset;      // ultrafast/fast/medium/slow
    bool deleteOriginal;
    QString priority;    // "low", "below_normal", "normal"
    QString outputPath;
};

struct CompressionResult {
    QString status;      // "completed", "failed", "skipped"
    double compressedFileSizeMb = 0;
    double compressionRatio = 0;
    QString compressedFilename;
    QString message;
};

class CompressionWorker : public QThread {
    Q_OBJECT
public:
    explicit CompressionWorker(QObject *parent = nullptr);
    void stop();
    void enqueue(const CompressionJob &job);
    int queueSize() const;

signals:
    void jobCompleted(int transactionId, bool success, CompressionResult result);

protected:
    void run() override;

private:
    void processJob(const CompressionJob &job);
    QPair<bool, QString> compressVideo(const CompressionJob &job);

    QQueue<CompressionJob> m_queue;
    mutable QMutex m_queueLock;
    std::atomic<bool> m_running{false};

    friend class VideoCompressor;
    QString m_ffmpegPath;
};

class VideoCompressor : public QObject {
    Q_OBJECT
public:
    explicit VideoCompressor(QObject *parent = nullptr);
    ~VideoCompressor();

    void start();
    void stop();

    QPair<bool, QString> checkFfmpegInstalled();
    bool queueCompression(const QString &videoPath, int transactionId, const QVariantMap &settings);

    struct QueueStatus {
        int queueSize;
        bool isProcessing;
        bool workerRunning;
    };
    QueueStatus getQueueStatus() const;

signals:
    void compressionCompleted(int transactionId, bool success, CompressionResult result);

private:
    CompressionWorker *m_worker = nullptr;
    bool m_ffmpegAvailable = false;
    QString m_ffmpegPath;
    bool m_ffmpegChecked = false;
};
