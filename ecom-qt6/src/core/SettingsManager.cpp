#include "SettingsManager.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>

SettingsManager::SettingsManager(const QString &settingsPath, QObject *parent)
    : QObject(parent)
{
    if (settingsPath.isEmpty()) {
        m_settingsPath = QDir(QCoreApplication::applicationDirPath()).filePath("settings.json");
    } else {
        m_settingsPath = settingsPath;
    }

    m_settings = defaultSettings();
    load();
}

QJsonObject SettingsManager::defaultSettings()
{
    QJsonObject video;
    video["resolution_width"] = 1280;
    video["resolution_height"] = 720;
    video["fps"] = 30;
    video["codec"] = QStringLiteral("mp4v");

    QJsonObject camera;
    camera["index"] = 0;
    camera["auto_exposure"] = true;
    camera["exposure"] = -4;
    camera["gain"] = 0;
    camera["brightness"] = 128;

    QJsonObject storage;
    storage["video_path"] = QStringLiteral("videos");
    storage["database_path"] = QStringLiteral("database.db");
    storage["log_path"] = QStringLiteral("logs");

    QJsonObject compression;
    compression["enabled"] = true;
    compression["codec"] = QStringLiteral("h264");
    compression["crf"] = 23;
    compression["preset"] = QStringLiteral("medium");
    compression["delete_original"] = true;
    compression["priority"] = QStringLiteral("below_normal");

    QJsonObject settings;
    settings["video"] = video;
    settings["camera"] = camera;
    settings["storage"] = storage;
    settings["compression"] = compression;

    return settings;
}

void SettingsManager::deepMerge(QJsonObject &target, const QJsonObject &defaults) const
{
    for (auto it = defaults.constBegin(); it != defaults.constEnd(); ++it) {
        if (!target.contains(it.key())) {
            target[it.key()] = it.value();
        } else if (it.value().isObject() && target[it.key()].isObject()) {
            QJsonObject nested = target[it.key()].toObject();
            deepMerge(nested, it.value().toObject());
            target[it.key()] = nested;
        }
    }
}

void SettingsManager::load()
{
    QFile file(m_settingsPath);
    if (!file.exists()) {
        save();
        return;
    }

    if (!file.open(QIODevice::ReadOnly)) {
        return;
    }

    QJsonParseError error;
    QJsonDocument doc = QJsonDocument::fromJson(file.readAll(), &error);
    file.close();

    if (error.error != QJsonParseError::NoError || !doc.isObject()) {
        return;
    }

    m_settings = doc.object();

    // Ensure all defaults exist
    QJsonObject defaults = defaultSettings();
    deepMerge(m_settings, defaults);
}

void SettingsManager::save()
{
    QFile file(m_settingsPath);
    if (!file.open(QIODevice::WriteOnly)) {
        return;
    }

    QJsonDocument doc(m_settings);
    file.write(doc.toJson(QJsonDocument::Indented));
    file.close();
}

QVariant SettingsManager::get(const QString &category, const QString &key, const QVariant &defaultValue) const
{
    if (!m_settings.contains(category)) {
        return defaultValue;
    }

    QJsonObject cat = m_settings[category].toObject();
    if (!cat.contains(key)) {
        return defaultValue;
    }

    return cat[key].toVariant();
}

void SettingsManager::set(const QString &category, const QString &key, const QVariant &value)
{
    QJsonObject cat = m_settings[category].toObject();
    cat[key] = QJsonValue::fromVariant(value);
    m_settings[category] = cat;
    save();
}

QJsonObject SettingsManager::getAll() const
{
    return m_settings;
}

void SettingsManager::updateCategory(const QString &category, const QJsonObject &values)
{
    QJsonObject cat = m_settings[category].toObject();
    for (auto it = values.constBegin(); it != values.constEnd(); ++it) {
        cat[it.key()] = it.value();
    }
    m_settings[category] = cat;
    save();
}

void SettingsManager::resetToDefaults()
{
    m_settings = defaultSettings();
    save();
}

QSize SettingsManager::getVideoResolution() const
{
    int w = get("video", "resolution_width", 1280).toInt();
    int h = get("video", "resolution_height", 720).toInt();
    return QSize(w, h);
}

int SettingsManager::getVideoFps() const
{
    return get("video", "fps", 30).toInt();
}

QString SettingsManager::getVideoCodec() const
{
    return get("video", "codec", "mp4v").toString();
}

int SettingsManager::getCameraIndex() const
{
    return get("camera", "index", 0).toInt();
}

bool SettingsManager::getCameraAutoExposure() const
{
    return get("camera", "auto_exposure", true).toBool();
}

int SettingsManager::getCameraExposure() const
{
    return get("camera", "exposure", -4).toInt();
}

int SettingsManager::getCameraGain() const
{
    return get("camera", "gain", 0).toInt();
}

int SettingsManager::getCameraBrightness() const
{
    return get("camera", "brightness", 128).toInt();
}

QVariantMap SettingsManager::getCameraExposureSettings() const
{
    QVariantMap map;
    map["auto_exposure"] = getCameraAutoExposure();
    map["exposure"] = getCameraExposure();
    map["gain"] = getCameraGain();
    map["brightness"] = getCameraBrightness();
    return map;
}

QString SettingsManager::getVideoStoragePath() const
{
    return get("storage", "video_path", "videos").toString();
}

QString SettingsManager::getDatabasePath() const
{
    return get("storage", "database_path", "database.db").toString();
}

QString SettingsManager::getLogPath() const
{
    return get("storage", "log_path", "logs").toString();
}
