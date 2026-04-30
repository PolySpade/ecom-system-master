#include "VideoCompressor.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMutexLocker>
#include <QProcess>
#include <QDebug>

// ── CompressionWorker ────────────────────────────────────────────────

CompressionWorker::CompressionWorker(QObject *parent)
    : QThread(parent)
{
}

void CompressionWorker::stop()
{
    m_running = false;
}

void CompressionWorker::enqueue(const CompressionJob &job)
{
    QMutexLocker locker(&m_queueLock);
    m_queue.enqueue(job);
}

int CompressionWorker::queueSize() const
{
    QMutexLocker locker(&m_queueLock);
    return m_queue.size();
}

void CompressionWorker::run()
{
    m_running = true;

    while (m_running) {
        CompressionJob job;
        bool hasJob = false;

        {
            QMutexLocker locker(&m_queueLock);
            if (!m_queue.isEmpty()) {
                job = m_queue.dequeue();
                hasJob = true;
            }
        }

        if (hasJob) {
            processJob(job);
        } else {
            msleep(500);
        }
    }
}

void CompressionWorker::processJob(const CompressionJob &job)
{
    QFileInfo inputInfo(job.videoPath);
    if (!inputInfo.exists()) {
        CompressionResult result;
        result.status = QStringLiteral("failed");
        result.message = QStringLiteral("Input file does not exist: %1").arg(job.videoPath);
        emit jobCompleted(job.transactionId, false, result);
        return;
    }

    double originalSizeMb = inputInfo.size() / (1024.0 * 1024.0);

    // Build output path: base_compressed.mp4
    QString outputPath = job.outputPath;
    if (outputPath.isEmpty()) {
        QString baseName = inputInfo.completeBaseName();
        QString outputDir = inputInfo.absolutePath();
        outputPath = QDir(outputDir).filePath(baseName + QStringLiteral("_compressed.mp4"));
    }

    CompressionJob runJob = job;
    runJob.outputPath = outputPath;

    auto [success, message] = compressVideo(runJob);

    CompressionResult result;
    if (success) {
        QFileInfo compressedInfo(outputPath);
        if (compressedInfo.exists()) {
            result.status = QStringLiteral("completed");
            result.compressedFileSizeMb = compressedInfo.size() / (1024.0 * 1024.0);
            result.compressionRatio = (originalSizeMb > 0)
                ? (1.0 - result.compressedFileSizeMb / originalSizeMb) * 100.0
                : 0;
            result.compressedFilename = compressedInfo.fileName();
            result.message = message;

            if (job.deleteOriginal) {
                QString originalPath = job.videoPath;
                if (QFile::remove(originalPath)) {
                    QFile::rename(outputPath, originalPath);
                    result.compressedFilename = inputInfo.fileName();
                } else {
                    result.message += QStringLiteral("; Warning: could not delete original file");
                }
            }
        } else {
            result.status = QStringLiteral("failed");
            result.message = QStringLiteral("Compressed file not found after FFmpeg completed");
            success = false;
        }
    } else {
        result.status = QStringLiteral("failed");
        result.message = message;
    }

    emit jobCompleted(job.transactionId, success, result);
}

QPair<bool, QString> CompressionWorker::compressVideo(const CompressionJob &job)
{
    QString videoCodec = (job.codec == QStringLiteral("h265"))
        ? QStringLiteral("libx265")
        : QStringLiteral("libx264");

    QStringList args;
    args << QStringLiteral("-i") << job.videoPath
         << QStringLiteral("-c:v") << videoCodec
         << QStringLiteral("-crf") << QString::number(job.crf)
         << QStringLiteral("-preset") << job.preset
         << QStringLiteral("-threads") << QStringLiteral("2")
         << QStringLiteral("-c:a") << QStringLiteral("aac")
         << QStringLiteral("-b:a") << QStringLiteral("128k")
         << QStringLiteral("-y")
         << job.outputPath;

    QProcess process;

#ifdef Q_OS_WIN
    int priorityFlag = 0x00004000; // BELOW_NORMAL_PRIORITY_CLASS
    if (job.priority == QStringLiteral("low"))
        priorityFlag = 0x00000040; // IDLE_PRIORITY_CLASS
    else if (job.priority == QStringLiteral("normal"))
        priorityFlag = 0x00000020; // NORMAL_PRIORITY_CLASS

    process.setCreateProcessArgumentsModifier(
        [priorityFlag](QProcess::CreateProcessArguments *args) {
            args->flags |= 0x08000000 | priorityFlag; // CREATE_NO_WINDOW
        });
#endif

    QString ffmpeg = m_ffmpegPath.isEmpty() ? QStringLiteral("ffmpeg") : m_ffmpegPath;
    process.start(ffmpeg, args);

    if (!process.waitForStarted(10000)) {
        return {false, QStringLiteral("Failed to start FFmpeg process")};
    }

    // 1-hour timeout
    if (!process.waitForFinished(3600000)) {
        process.kill();
        process.waitForFinished(5000);
        return {false, QStringLiteral("FFmpeg process timed out after 1 hour")};
    }

    if (process.exitCode() != 0) {
        QString stderr = QString::fromUtf8(process.readAllStandardError());
        return {false, QStringLiteral("FFmpeg failed (exit code %1): %2")
            .arg(process.exitCode())
            .arg(stderr.left(500))};
    }

    return {true, QStringLiteral("Compression completed successfully")};
}

// ── VideoCompressor ──────────────────────────────────────────────────

VideoCompressor::VideoCompressor(QObject *parent)
    : QObject(parent)
{
}

VideoCompressor::~VideoCompressor()
{
    stop();
}

void VideoCompressor::start()
{
    auto [available, msg] = checkFfmpegInstalled();
    if (!available) {
        qWarning() << "VideoCompressor: FFmpeg not available:" << msg;
    }

    m_worker = new CompressionWorker(this);
    m_worker->m_ffmpegPath = m_ffmpegPath;
    connect(m_worker, &CompressionWorker::jobCompleted,
            this, &VideoCompressor::compressionCompleted);
    m_worker->start();
}

void VideoCompressor::stop()
{
    if (m_worker) {
        m_worker->stop();
        m_worker->wait(5000);
        delete m_worker;
        m_worker = nullptr;
    }
}

QPair<bool, QString> VideoCompressor::checkFfmpegInstalled()
{
    if (m_ffmpegChecked) {
        if (m_ffmpegAvailable)
            return {true, QStringLiteral("FFmpeg available (cached): %1").arg(m_ffmpegPath)};
        else
            return {false, QStringLiteral("FFmpeg not found (cached)")};
    }

    m_ffmpegChecked = true;

    // Try system ffmpeg first
    auto tryFfmpeg = [](const QString &path) -> QPair<bool, QString> {
        QProcess process;

#ifdef Q_OS_WIN
        process.setCreateProcessArgumentsModifier(
            [](QProcess::CreateProcessArguments *args) {
                args->flags |= 0x08000000; // CREATE_NO_WINDOW
            });
#endif

        process.start(path, {QStringLiteral("-version")});
        if (process.waitForFinished(5000) && process.exitCode() == 0) {
            QString output = QString::fromUtf8(process.readAllStandardOutput());
            QString version = output.section(QLatin1Char('\n'), 0, 0).trimmed();
            return {true, version};
        }
        return {false, QString()};
    };

    // Try "ffmpeg" on PATH
    auto [found, version] = tryFfmpeg(QStringLiteral("ffmpeg"));
    if (found) {
        m_ffmpegAvailable = true;
        m_ffmpegPath = QStringLiteral("ffmpeg");
        return {true, QStringLiteral("FFmpeg available: %1").arg(version)};
    }

#ifdef Q_OS_WIN
    // Check common Windows paths
    QString appDir = QCoreApplication::applicationDirPath();
    QStringList candidates = {
        QDir(appDir).filePath(QStringLiteral("ffmpeg.exe")),
        QDir(appDir).filePath(QStringLiteral("ffmpeg/ffmpeg.exe")),
        QDir(appDir).filePath(QStringLiteral("ffmpeg/bin/ffmpeg.exe")),
        QStringLiteral("C:/ffmpeg/bin/ffmpeg.exe"),
        QStringLiteral("C:/Program Files/ffmpeg/bin/ffmpeg.exe"),
    };

    for (const QString &candidate : candidates) {
        if (QFileInfo::exists(candidate)) {
            auto [ok, ver] = tryFfmpeg(candidate);
            if (ok) {
                m_ffmpegAvailable = true;
                m_ffmpegPath = candidate;
                return {true, QStringLiteral("FFmpeg available: %1").arg(ver)};
            }
        }
    }
#endif

    m_ffmpegAvailable = false;
    return {false, QStringLiteral("FFmpeg not found. Please install FFmpeg and ensure it is on PATH.")};
}

bool VideoCompressor::queueCompression(const QString &videoPath, int transactionId,
                                       const QVariantMap &settings)
{
    if (!m_ffmpegAvailable) {
        auto [available, msg] = checkFfmpegInstalled();
        if (!available) {
            qWarning() << "VideoCompressor: cannot queue compression -" << msg;
            return false;
        }
    }

    QFileInfo fileInfo(videoPath);
    if (!fileInfo.exists()) {
        qWarning() << "VideoCompressor: video file does not exist:" << videoPath;
        return false;
    }

    if (!m_worker || !m_worker->isRunning()) {
        qWarning() << "VideoCompressor: worker is not running";
        return false;
    }

    CompressionJob job;
    job.videoPath = videoPath;
    job.transactionId = transactionId;
    job.codec = settings.value(QStringLiteral("codec"), QStringLiteral("h264")).toString();
    job.crf = settings.value(QStringLiteral("crf"), 23).toInt();
    job.preset = settings.value(QStringLiteral("preset"), QStringLiteral("medium")).toString();
    job.deleteOriginal = settings.value(QStringLiteral("delete_original"), false).toBool();
    job.priority = settings.value(QStringLiteral("priority"), QStringLiteral("below_normal")).toString();

    m_worker->enqueue(job);
    return true;
}

VideoCompressor::QueueStatus VideoCompressor::getQueueStatus() const
{
    QueueStatus status;
    status.queueSize = m_worker ? m_worker->queueSize() : 0;
    status.isProcessing = m_worker && m_worker->isRunning() && status.queueSize > 0;
    status.workerRunning = m_worker && m_worker->isRunning();
    return status;
}
