#include "CameraUtils.h"

#include <QDateTime>
#include <QtConcurrent>
#include <opencv2/videoio.hpp>

QList<CameraInfo> CameraUtils::s_cameraCache;
qint64 CameraUtils::s_cacheTime = 0;
QMutex CameraUtils::s_cacheLock;

QList<CameraInfo> CameraUtils::getAvailableCameras(int maxCameras, bool useCache)
{
    QMutexLocker lock(&s_cacheLock);

    // Return cache if valid
    if (useCache && !s_cameraCache.isEmpty()) {
        qint64 now = QDateTime::currentMSecsSinceEpoch();
        if (now - s_cacheTime < CACHE_DURATION_MS)
            return s_cameraCache;
    }

    QList<CameraInfo> cameras;

    for (int i = 0; i < maxCameras; ++i) {
        CameraInfo info;
        info.index = i;
        info.name = QString("Camera %1").arg(i);
        info.working = false;
        info.resolution = "N/A";

        cv::VideoCapture cap;
#ifdef Q_OS_WIN
        cap.open(i, cv::CAP_MSMF);
#else
        cap.open(i);
#endif

        if (cap.isOpened()) {
            cv::Mat frame;
            if (cap.read(frame) && !frame.empty()) {
                info.working = true;
                int w = static_cast<int>(cap.get(cv::CAP_PROP_FRAME_WIDTH));
                int h = static_cast<int>(cap.get(cv::CAP_PROP_FRAME_HEIGHT));
                info.resolution = QString("%1x%2").arg(w).arg(h);
            }
            cap.release();
        }

        if (info.working)
            cameras.append(info);
    }

    // Always ensure index 0 exists
    bool hasZero = false;
    for (const auto &cam : cameras) {
        if (cam.index == 0) {
            hasZero = true;
            break;
        }
    }
    if (!hasZero) {
        CameraInfo defaultCam;
        defaultCam.index = 0;
        defaultCam.name = "Camera 0";
        defaultCam.working = false;
        defaultCam.resolution = "N/A";
        cameras.prepend(defaultCam);
    }

    // Update cache
    s_cameraCache = cameras;
    s_cacheTime = QDateTime::currentMSecsSinceEpoch();

    return cameras;
}

QList<CameraInfo> CameraUtils::getAvailableCamerasFast()
{
    QMutexLocker lock(&s_cacheLock);
    if (!s_cameraCache.isEmpty())
        return s_cameraCache;

    return {{0, "Default Camera", true, "Auto"}};
}

void CameraUtils::refreshCamerasAsync(std::function<void(QList<CameraInfo>)> callback)
{
    QtConcurrent::run([callback]() {
        // Clear cache
        {
            QMutexLocker lock(&s_cacheLock);
            s_cameraCache.clear();
            s_cacheTime = 0;
        }

        QList<CameraInfo> cameras = getAvailableCameras(5, false);

        if (callback)
            callback(cameras);
    });
}

bool CameraUtils::testCamera(int index)
{
    cv::VideoCapture cap;
#ifdef Q_OS_WIN
    cap.open(index, cv::CAP_MSMF);
#else
    cap.open(index);
#endif

    if (!cap.isOpened())
        return false;

    cv::Mat frame;
    bool ok = cap.read(frame) && !frame.empty();
    cap.release();
    return ok;
}
