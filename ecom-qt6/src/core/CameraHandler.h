#pragma once

#include <QObject>
#include <QThread>
#include <QMutex>
#include <QSize>
#include <QString>
#include <QElapsedTimer>
#include <opencv2/core.hpp>
#include <opencv2/videoio.hpp>
#include <deque>
#include <atomic>

class SettingsManager;

struct RecordingInfo {
    QString filename;
    int duration;           // seconds
    double fileSizeMb;
    QString labelFolder;
    double fps;
    int frameCount;
};

class CaptureThread : public QThread {
    Q_OBJECT
public:
    explicit CaptureThread(QObject *parent = nullptr);
    void stop();

    // Set by CameraHandler before starting
    cv::VideoCapture *capture = nullptr;
    std::atomic<bool> running{false};

    // Latest frame (mutex-protected)
    cv::Mat latestFrame;
    QMutex frameLock;

    // Frame buffer for recording
    std::deque<cv::Mat> frameBuffer;
    QMutex bufferLock;
    std::atomic<bool> isRecording{false};
    static constexpr int MAX_BUFFER_SIZE = 60;

    // FPS tracking
    std::deque<double> fpsSampleTimes;
    std::atomic<double> actualFps{30.0};

    // Error recovery
    std::atomic<int> consecutiveFailures{0};

signals:
    void reinitRequested();

protected:
    void run() override;
};

class RecordingThread : public QThread {
    Q_OBJECT
public:
    explicit RecordingThread(QObject *parent = nullptr);
    void stop();

    std::atomic<bool> running{false};
    CaptureThread *captureThread = nullptr;
    cv::VideoWriter *writer = nullptr;
    QString currentLabel;
    QString currentBarcode;
    QSize videoResolution;
    std::atomic<int> frameCount{0};

protected:
    void run() override;

private:
    void addWatermark(cv::Mat &frame);
};

class CameraHandler : public QObject {
    Q_OBJECT
public:
    explicit CameraHandler(SettingsManager *settings, QObject *parent = nullptr);
    ~CameraHandler();

    // Frame access
    cv::Mat getFrame();
    cv::Mat getPreviewFrame(int maxWidth = 640, int maxHeight = 480);
    double getActualFps() const;

    // Recording
    QString startRecording(const QString &barcode, const QString &label = "Normal (Standard)");
    RecordingInfo stopRecording();
    bool isRecording() const;
    int getRecordingDuration() const;

    // Camera control
    void applyExposureSettings(bool autoExposure, int exposure, int gain, int brightness);
    void reinitialize();
    void cleanup();

signals:
    void error(const QString &message);
    void cameraReady();

private:
    void initializeCamera();
    QString getLabelFolderName(const QString &label);
    void tryReinitializeCamera();

    SettingsManager *m_settings;
    cv::VideoCapture m_capture;
    CaptureThread *m_captureThread = nullptr;
    RecordingThread *m_recordingThread = nullptr;
    cv::VideoWriter m_videoWriter;

    QMutex m_lock;
    QString m_currentFilename;
    QString m_currentLabel;
    QString m_currentBarcode;
    QString m_currentLabelFolder;
    QElapsedTimer m_recordingTimer;
    double m_recordingFps = 30.0;
    std::atomic<bool> m_recording{false};

    // Reinit tracking
    qint64 m_lastReinitTime = 0;
    static constexpr int REINIT_COOLDOWN_MS = 5000;
    static constexpr int MAX_FAILURES = 100;
};
