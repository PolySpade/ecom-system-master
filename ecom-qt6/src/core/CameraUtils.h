#pragma once

#include <QObject>
#include <QString>
#include <QList>
#include <QMutex>
#include <functional>

struct CameraInfo {
    int index;
    QString name;
    bool working;
    QString resolution;
};

class CameraUtils : public QObject {
    Q_OBJECT
public:
    static QList<CameraInfo> getAvailableCameras(int maxCameras = 5, bool useCache = true);
    static QList<CameraInfo> getAvailableCamerasFast();
    static void refreshCamerasAsync(std::function<void(QList<CameraInfo>)> callback = nullptr);
    static bool testCamera(int index);

private:
    static QList<CameraInfo> s_cameraCache;
    static qint64 s_cacheTime;
    static QMutex s_cacheLock;
    static constexpr int CACHE_DURATION_MS = 30000;
};
