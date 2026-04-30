#include "CameraHandler.h"
#include "SettingsManager.h"

#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QElapsedTimer>
#include <algorithm>
#include <opencv2/imgproc.hpp>

// --- CaptureThread ---

CaptureThread::CaptureThread(QObject *parent)
    : QThread(parent)
{
}

void CaptureThread::stop()
{
    running = false;
    if (isRunning())
        wait(3000);
}

void CaptureThread::run()
{
    QElapsedTimer timer;
    timer.start();
    int framesSinceFpsUpdate = 0;

    while (running) {
        if (!capture || !capture->isOpened()) {
            msleep(33);
            continue;
        }

        cv::Mat frame;
        bool ok = capture->read(frame);

        if (ok && !frame.empty()) {
            consecutiveFailures = 0;

            // Update latest frame
            {
                QMutexLocker lock(&frameLock);
                latestFrame = frame;
            }

            // FPS tracking
            double now = timer.elapsed() / 1000.0;
            fpsSampleTimes.push_back(now);
            while (fpsSampleTimes.size() > 30)
                fpsSampleTimes.pop_front();

            framesSinceFpsUpdate++;
            if (framesSinceFpsUpdate >= 10 && fpsSampleTimes.size() >= 2) {
                double dt = fpsSampleTimes.back() - fpsSampleTimes.front();
                if (dt > 0)
                    actualFps = static_cast<double>(fpsSampleTimes.size() - 1) / dt;
                framesSinceFpsUpdate = 0;
            }

            // Buffer for recording
            if (isRecording) {
                QMutexLocker lock(&bufferLock);
                frameBuffer.push_back(frame.clone());
                while (static_cast<int>(frameBuffer.size()) > MAX_BUFFER_SIZE)
                    frameBuffer.pop_front();
            }
        } else {
            int failures = ++consecutiveFailures;
            if (failures >= 100) {
                emit reinitRequested();
                consecutiveFailures = 0;
            }
            msleep(33);
        }
    }
}

// --- RecordingThread ---

RecordingThread::RecordingThread(QObject *parent)
    : QThread(parent)
{
}

void RecordingThread::stop()
{
    running = false;
    if (isRunning())
        wait(3000);
}

void RecordingThread::run()
{
    while (running) {
        cv::Mat frame;
        {
            QMutexLocker lock(&captureThread->bufferLock);
            if (!captureThread->frameBuffer.empty()) {
                frame = captureThread->frameBuffer.front();
                captureThread->frameBuffer.pop_front();
            }
        }

        if (frame.empty()) {
            msleep(5);
            continue;
        }

        // Resize if needed
        if (videoResolution.isValid() &&
            (frame.cols != videoResolution.width() || frame.rows != videoResolution.height())) {
            cv::resize(frame, frame, cv::Size(videoResolution.width(), videoResolution.height()));
        }

        addWatermark(frame);

        if (writer && writer->isOpened()) {
            writer->write(frame);
            frameCount++;
        }
    }
}

void RecordingThread::addWatermark(cv::Mat &frame)
{
    int fontFace = cv::FONT_HERSHEY_SIMPLEX;
    double fontScale = 0.6;
    int thickness = 2;
    int baseline = 0;

    // Timestamp top-left
    QString tsStr = QDateTime::currentDateTime().toString("yyyy-MM-dd HH:mm:ss");
    std::string timestamp = tsStr.toStdString();
    cv::Size tsSize = cv::getTextSize(timestamp, fontFace, fontScale, thickness, &baseline);
    cv::rectangle(frame, cv::Point(5, 5), cv::Point(15 + tsSize.width, 15 + tsSize.height + baseline),
                  cv::Scalar(0, 0, 0), cv::FILLED);
    cv::putText(frame, timestamp, cv::Point(10, 10 + tsSize.height),
                fontFace, fontScale, cv::Scalar(255, 255, 255), thickness);

    // Label top-right (blue bg: #667eea = BGR 234,126,102)
    if (!currentLabel.isEmpty()) {
        std::string label = currentLabel.toStdString();
        cv::Size lblSize = cv::getTextSize(label, fontFace, fontScale, thickness, &baseline);
        int x = frame.cols - lblSize.width - 15;
        cv::rectangle(frame, cv::Point(x, 5),
                      cv::Point(frame.cols - 5, 15 + lblSize.height + baseline),
                      cv::Scalar(234, 126, 102), cv::FILLED);
        cv::putText(frame, label, cv::Point(x + 5, 10 + lblSize.height),
                    fontFace, fontScale, cv::Scalar(255, 255, 255), thickness);
    }

    // Barcode bottom-left
    if (!currentBarcode.isEmpty()) {
        std::string barcodeText = ("Barcode: " + currentBarcode).toStdString();
        cv::Size bcSize = cv::getTextSize(barcodeText, fontFace, fontScale, thickness, &baseline);
        int y = frame.rows - 15 - bcSize.height - baseline;
        cv::rectangle(frame, cv::Point(5, y),
                      cv::Point(15 + bcSize.width, frame.rows - 5),
                      cv::Scalar(0, 0, 0), cv::FILLED);
        cv::putText(frame, barcodeText, cv::Point(10, frame.rows - 10 - baseline),
                    fontFace, fontScale, cv::Scalar(255, 255, 255), thickness);
    }
}

// --- CameraHandler ---

CameraHandler::CameraHandler(SettingsManager *settings, QObject *parent)
    : QObject(parent)
    , m_settings(settings)
{
    initializeCamera();
}

CameraHandler::~CameraHandler()
{
    cleanup();
}

void CameraHandler::initializeCamera()
{
    int cameraIndex = m_settings->getCameraIndex();

#ifdef Q_OS_WIN
    m_capture.open(cameraIndex, cv::CAP_MSMF);
#else
    m_capture.open(cameraIndex);
#endif

    if (!m_capture.isOpened()) {
        emit error("Failed to open camera " + QString::number(cameraIndex));
        return;
    }

    QSize res = m_settings->getVideoResolution();
    m_capture.set(cv::CAP_PROP_FRAME_WIDTH, res.width());
    m_capture.set(cv::CAP_PROP_FRAME_HEIGHT, res.height());
    m_capture.set(cv::CAP_PROP_FPS, m_settings->getVideoFps());
    m_capture.set(cv::CAP_PROP_BUFFERSIZE, 1);

    // Apply exposure settings
    applyExposureSettings(
        m_settings->getCameraAutoExposure(),
        m_settings->getCameraExposure(),
        m_settings->getCameraGain(),
        m_settings->getCameraBrightness()
    );

    // Read test frame
    cv::Mat testFrame;
    m_capture.read(testFrame);
    if (testFrame.empty()) {
        emit error("Camera opened but failed to read test frame");
    }

    // Create and start capture thread
    m_captureThread = new CaptureThread(this);
    m_captureThread->capture = &m_capture;
    m_captureThread->running = true;
    connect(m_captureThread, &CaptureThread::reinitRequested,
            this, &CameraHandler::tryReinitializeCamera, Qt::QueuedConnection);
    m_captureThread->start();

    emit cameraReady();
}

void CameraHandler::tryReinitializeCamera()
{
    qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (now - m_lastReinitTime < REINIT_COOLDOWN_MS)
        return;
    m_lastReinitTime = now;

    if (m_recording)
        return;

    emit error("Too many consecutive capture failures, reinitializing camera");
    reinitialize();
}

cv::Mat CameraHandler::getFrame()
{
    if (!m_captureThread)
        return cv::Mat();
    QMutexLocker lock(&m_captureThread->frameLock);
    return m_captureThread->latestFrame.clone();
}

cv::Mat CameraHandler::getPreviewFrame(int maxWidth, int maxHeight)
{
    cv::Mat frame = getFrame();
    if (frame.empty())
        return frame;

    double scaleW = static_cast<double>(maxWidth) / frame.cols;
    double scaleH = static_cast<double>(maxHeight) / frame.rows;
    double scale = std::min(scaleW, scaleH);

    if (scale < 1.0) {
        cv::Mat resized;
        cv::resize(frame, resized, cv::Size(), scale, scale, cv::INTER_AREA);
        return resized;
    }
    return frame;
}

double CameraHandler::getActualFps() const
{
    if (m_captureThread)
        return m_captureThread->actualFps;
    return 0.0;
}

QString CameraHandler::startRecording(const QString &barcode, const QString &label)
{
    QMutexLocker lock(&m_lock);

    if (m_recording)
        return QString();

    m_currentBarcode = barcode;
    m_currentLabel = label;
    m_currentLabelFolder = getLabelFolderName(label);

    // Create folder structure: storage/YYYY-MM-DD/LabelFolder/
    QString dateStr = QDateTime::currentDateTime().toString("yyyy-MM-dd");
    QString folderPath = QDir(m_settings->getVideoStoragePath()).filePath(dateStr + "/" + m_currentLabelFolder);
    QDir().mkpath(folderPath);

    // Filename: YYYYMMDD_HHMMSS_BARCODE.mp4
    QString timeStr = QDateTime::currentDateTime().toString("yyyyMMdd_HHmmss");
    m_currentFilename = folderPath + "/" + timeStr + "_" + barcode + ".mp4";

    // Use measured FPS clamped 10-60
    double measuredFps = getActualFps();
    m_recordingFps = std::clamp(measuredFps, 10.0, 60.0);

    // Init VideoWriter with fourcc from settings
    QString codec = m_settings->getVideoCodec();
    int fourcc = cv::VideoWriter::fourcc(
        codec.at(0).toLatin1(), codec.at(1).toLatin1(),
        codec.at(2).toLatin1(), codec.at(3).toLatin1()
    );

    QSize res = m_settings->getVideoResolution();
    m_videoWriter.open(m_currentFilename.toStdString(), fourcc, m_recordingFps,
                       cv::Size(res.width(), res.height()));

    if (!m_videoWriter.isOpened()) {
        emit error("Failed to open video writer: " + m_currentFilename);
        return QString();
    }

    // Clear frame buffer
    if (m_captureThread) {
        QMutexLocker bufLock(&m_captureThread->bufferLock);
        m_captureThread->frameBuffer.clear();
        m_captureThread->isRecording = true;
    }

    // Create and start recording thread
    m_recordingThread = new RecordingThread(this);
    m_recordingThread->captureThread = m_captureThread;
    m_recordingThread->writer = &m_videoWriter;
    m_recordingThread->currentLabel = m_currentLabel;
    m_recordingThread->currentBarcode = m_currentBarcode;
    m_recordingThread->videoResolution = res;
    m_recordingThread->frameCount = 0;
    m_recordingThread->running = true;

    m_recording = true;
    m_recordingTimer.start();
    m_recordingThread->start();

    return m_currentFilename;
}

RecordingInfo CameraHandler::stopRecording()
{
    QMutexLocker lock(&m_lock);

    RecordingInfo info;
    info.filename = m_currentFilename;
    info.labelFolder = m_currentLabelFolder;
    info.fps = m_recordingFps;

    if (!m_recording)
        return info;

    m_recording = false;

    // Stop capture thread from buffering
    if (m_captureThread)
        m_captureThread->isRecording = false;

    // Stop recording thread
    if (m_recordingThread) {
        m_recordingThread->running = false;
        m_recordingThread->quit();
        m_recordingThread->wait(5000);
    }

    // Write remaining frames from buffer with watermark
    if (m_captureThread && m_videoWriter.isOpened()) {
        QMutexLocker bufLock(&m_captureThread->bufferLock);
        QSize res = m_settings->getVideoResolution();

        while (!m_captureThread->frameBuffer.empty()) {
            cv::Mat frame = m_captureThread->frameBuffer.front();
            m_captureThread->frameBuffer.pop_front();

            if (frame.cols != res.width() || frame.rows != res.height())
                cv::resize(frame, frame, cv::Size(res.width(), res.height()));

            // Inline watermark for remaining frames
            int fontFace = cv::FONT_HERSHEY_SIMPLEX;
            double fontScale = 0.6;
            int thickness = 2;
            int baseline = 0;

            std::string timestamp = QDateTime::currentDateTime().toString("yyyy-MM-dd HH:mm:ss").toStdString();
            cv::Size tsSize = cv::getTextSize(timestamp, fontFace, fontScale, thickness, &baseline);
            cv::rectangle(frame, cv::Point(5, 5), cv::Point(15 + tsSize.width, 15 + tsSize.height + baseline),
                          cv::Scalar(0, 0, 0), cv::FILLED);
            cv::putText(frame, timestamp, cv::Point(10, 10 + tsSize.height),
                        fontFace, fontScale, cv::Scalar(255, 255, 255), thickness);

            if (!m_currentLabel.isEmpty()) {
                std::string label = m_currentLabel.toStdString();
                cv::Size lblSize = cv::getTextSize(label, fontFace, fontScale, thickness, &baseline);
                int x = frame.cols - lblSize.width - 15;
                cv::rectangle(frame, cv::Point(x, 5),
                              cv::Point(frame.cols - 5, 15 + lblSize.height + baseline),
                              cv::Scalar(234, 126, 102), cv::FILLED);
                cv::putText(frame, label, cv::Point(x + 5, 10 + lblSize.height),
                            fontFace, fontScale, cv::Scalar(255, 255, 255), thickness);
            }

            if (!m_currentBarcode.isEmpty()) {
                std::string barcodeText = ("Barcode: " + m_currentBarcode).toStdString();
                cv::Size bcSize = cv::getTextSize(barcodeText, fontFace, fontScale, thickness, &baseline);
                int y = frame.rows - 15 - bcSize.height - baseline;
                cv::rectangle(frame, cv::Point(5, y),
                              cv::Point(15 + bcSize.width, frame.rows - 5),
                              cv::Scalar(0, 0, 0), cv::FILLED);
                cv::putText(frame, barcodeText, cv::Point(10, frame.rows - 10 - baseline),
                            fontFace, fontScale, cv::Scalar(255, 255, 255), thickness);
            }

            m_videoWriter.write(frame);
            if (m_recordingThread)
                m_recordingThread->frameCount++;
        }
    }

    info.frameCount = m_recordingThread ? static_cast<int>(m_recordingThread->frameCount) : 0;

    // Release video writer
    m_videoWriter.release();

    // Calculate duration and file size
    info.duration = static_cast<int>(m_recordingTimer.elapsed() / 1000);
    QFileInfo fi(m_currentFilename);
    info.fileSizeMb = fi.exists() ? fi.size() / (1024.0 * 1024.0) : 0.0;

    // Clean up recording thread
    if (m_recordingThread) {
        m_recordingThread->deleteLater();
        m_recordingThread = nullptr;
    }

    return info;
}

bool CameraHandler::isRecording() const
{
    return m_recording;
}

int CameraHandler::getRecordingDuration() const
{
    if (!m_recording)
        return 0;
    return static_cast<int>(m_recordingTimer.elapsed() / 1000);
}

void CameraHandler::applyExposureSettings(bool autoExposure, int exposure, int gain, int brightness)
{
    if (!m_capture.isOpened())
        return;

    if (autoExposure) {
        m_capture.set(cv::CAP_PROP_AUTO_EXPOSURE, 3);  // Auto mode
    } else {
        m_capture.set(cv::CAP_PROP_AUTO_EXPOSURE, 1);  // Manual mode
        m_capture.set(cv::CAP_PROP_EXPOSURE, exposure);
    }
    m_capture.set(cv::CAP_PROP_GAIN, gain);
    m_capture.set(cv::CAP_PROP_BRIGHTNESS, brightness);
}

void CameraHandler::reinitialize()
{
    if (m_recording)
        return;

    // Stop capture thread
    if (m_captureThread) {
        m_captureThread->stop();
        m_captureThread->deleteLater();
        m_captureThread = nullptr;
    }

    // Release camera
    if (m_capture.isOpened())
        m_capture.release();

    initializeCamera();
}

void CameraHandler::cleanup()
{
    // Stop recording if active
    if (m_recording) {
        m_recording = false;
        if (m_captureThread)
            m_captureThread->isRecording = false;
        if (m_recordingThread) {
            m_recordingThread->running = false;
            m_recordingThread->quit();
            m_recordingThread->wait(3000);
            m_recordingThread->deleteLater();
            m_recordingThread = nullptr;
        }
        m_videoWriter.release();
    }

    // Stop capture thread
    if (m_captureThread) {
        m_captureThread->stop();
        m_captureThread->deleteLater();
        m_captureThread = nullptr;
    }

    // Release camera
    if (m_capture.isOpened())
        m_capture.release();
}

QString CameraHandler::getLabelFolderName(const QString &label)
{
    if (label == "Return and Refund Unboxing")
        return QStringLiteral("Return and Refund");
    if (label == "Return Parcel Unboxing")
        return QStringLiteral("Return Parcel");
    if (label == "Normal (Standard)")
        return QStringLiteral("Normal");
    return label;
}
