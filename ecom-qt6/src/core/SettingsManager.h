#pragma once

#include <QObject>
#include <QJsonObject>
#include <QSize>
#include <QString>
#include <QVariant>
#include <QVariantMap>

class SettingsManager : public QObject
{
    Q_OBJECT

public:
    explicit SettingsManager(const QString &settingsPath = QString(), QObject *parent = nullptr);

    QVariant get(const QString &category, const QString &key, const QVariant &defaultValue = QVariant()) const;
    void set(const QString &category, const QString &key, const QVariant &value);
    QJsonObject getAll() const;
    void updateCategory(const QString &category, const QJsonObject &values);
    void resetToDefaults();

    void save();
    void load();

    // Video convenience accessors
    QSize getVideoResolution() const;
    int getVideoFps() const;
    QString getVideoCodec() const;

    // Camera convenience accessors
    int getCameraIndex() const;
    bool getCameraAutoExposure() const;
    int getCameraExposure() const;
    int getCameraGain() const;
    int getCameraBrightness() const;
    QVariantMap getCameraExposureSettings() const;

    // Storage convenience accessors
    QString getVideoStoragePath() const;
    QString getDatabasePath() const;
    QString getLogPath() const;

private:
    static QJsonObject defaultSettings();
    void deepMerge(QJsonObject &target, const QJsonObject &defaults) const;

    QString m_settingsPath;
    QJsonObject m_settings;
};
