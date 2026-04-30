#include "ui/SettingsDialog.h"
#include "core/SettingsManager.h"
#include "core/CameraHandler.h"
#include "core/VideoCompressor.h"
#include "core/CameraUtils.h"

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QFormLayout>
#include <QGroupBox>
#include <QFileDialog>
#include <QMessageBox>
#include <QPushButton>

SettingsDialog::SettingsDialog(SettingsManager *settings, CameraHandler *camera,
                               VideoCompressor *compressor, QWidget *parent)
    : QDialog(parent), m_settings(settings), m_camera(camera), m_compressor(compressor)
{
    m_exposureThrottleTimer = new QTimer(this);
    m_exposureThrottleTimer->setInterval(100);
    m_exposureThrottleTimer->setSingleShot(true);
    connect(m_exposureThrottleTimer, &QTimer::timeout, this, &SettingsDialog::onExposureSliderChanged);

    setupUi();
    loadCurrentSettings();
}

void SettingsDialog::setupUi()
{
    setWindowTitle("Settings");
    resize(550, 500);

    auto *mainLayout = new QVBoxLayout(this);

    auto *tabs = new QTabWidget;
    tabs->addTab(createVideoTab(), "Video");
    tabs->addTab(createCameraTab(), "Camera");
    tabs->addTab(createCompressionTab(), "Compression");
    tabs->addTab(createStorageTab(), "Storage");
    mainLayout->addWidget(tabs);

    // Bottom buttons
    auto *btnLayout = new QHBoxLayout;
    auto *resetBtn = new QPushButton("Reset to Defaults");
    connect(resetBtn, &QPushButton::clicked, this, &SettingsDialog::resetDefaults);
    btnLayout->addWidget(resetBtn);

    btnLayout->addStretch();

    auto *saveBtn = new QPushButton("Save");
    saveBtn->setObjectName("primaryButton");
    connect(saveBtn, &QPushButton::clicked, this, &SettingsDialog::saveSettings);
    btnLayout->addWidget(saveBtn);

    auto *cancelBtn = new QPushButton("Cancel");
    connect(cancelBtn, &QPushButton::clicked, this, &QDialog::reject);
    btnLayout->addWidget(cancelBtn);

    mainLayout->addLayout(btnLayout);
}

QWidget *SettingsDialog::createVideoTab()
{
    auto *widget = new QWidget;
    auto *layout = new QFormLayout(widget);
    layout->setSpacing(12);

    // Resolution
    m_resolutionCombo = new QComboBox;
    m_resolutionCombo->addItems({"640x480", "800x600", "1280x720", "1920x1080", "2560x1440", "3840x2160"});
    layout->addRow("Resolution:", m_resolutionCombo);

    // FPS
    m_fpsGroup = new QButtonGroup(this);
    auto *fpsLayout = new QHBoxLayout;
    for (int fps : {15, 24, 30, 60}) {
        auto *radio = new QRadioButton(QString::number(fps));
        m_fpsGroup->addButton(radio, fps);
        fpsLayout->addWidget(radio);
    }
    fpsLayout->addStretch();
    layout->addRow("FPS:", fpsLayout);

    // Codec
    m_codecCombo = new QComboBox;
    m_codecCombo->addItems({"mp4v", "XVID", "MJPG"});
    layout->addRow("Codec:", m_codecCombo);

    return widget;
}

QWidget *SettingsDialog::createCameraTab()
{
    auto *widget = new QWidget;
    auto *layout = new QVBoxLayout(widget);
    layout->setSpacing(10);

    // Camera selection
    auto *camLayout = new QHBoxLayout;
    m_cameraCombo = new QComboBox;
    camLayout->addWidget(m_cameraCombo, 1);

    auto *refreshBtn = new QPushButton("Refresh");
    connect(refreshBtn, &QPushButton::clicked, this, &SettingsDialog::refreshCameras);
    camLayout->addWidget(refreshBtn);
    layout->addLayout(camLayout);

    // Populate cameras
    QList<CameraInfo> cameras = CameraUtils::getAvailableCamerasFast();
    for (const CameraInfo &cam : cameras) {
        m_cameraCombo->addItem(QString("Camera %1: %2 (%3)").arg(cam.index).arg(cam.name).arg(cam.resolution),
                               cam.index);
    }
    if (m_cameraCombo->count() == 0) {
        m_cameraCombo->addItem("No cameras found", -1);
    }

    // Auto exposure
    m_autoExposureCheck = new QCheckBox("Auto Exposure");
    layout->addWidget(m_autoExposureCheck);

    // Exposure slider
    auto *expForm = new QFormLayout;
    auto *makeSliderRow = [](QSlider *&slider, QLabel *&label, int min, int max) {
        auto *row = new QHBoxLayout;
        slider = new QSlider(Qt::Horizontal);
        slider->setRange(min, max);
        label = new QLabel("0");
        label->setFixedWidth(40);
        label->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
        row->addWidget(slider, 1);
        row->addWidget(label);
        return row;
    };

    expForm->addRow("Exposure:", makeSliderRow(m_exposureSlider, m_exposureValueLabel, -13, -1));
    expForm->addRow("Gain:", makeSliderRow(m_gainSlider, m_gainValueLabel, 0, 255));
    expForm->addRow("Brightness:", makeSliderRow(m_brightnessSlider, m_brightnessValueLabel, 0, 255));
    layout->addLayout(expForm);

    // Update labels when sliders change
    connect(m_exposureSlider, &QSlider::valueChanged, this, [this](int v) {
        m_exposureValueLabel->setText(QString::number(v));
        if (m_livePreviewCheck->isChecked()) m_exposureThrottleTimer->start();
    });
    connect(m_gainSlider, &QSlider::valueChanged, this, [this](int v) {
        m_gainValueLabel->setText(QString::number(v));
        if (m_livePreviewCheck->isChecked()) m_exposureThrottleTimer->start();
    });
    connect(m_brightnessSlider, &QSlider::valueChanged, this, [this](int v) {
        m_brightnessValueLabel->setText(QString::number(v));
        if (m_livePreviewCheck->isChecked()) m_exposureThrottleTimer->start();
    });

    // Disable sliders when auto exposure is on
    connect(m_autoExposureCheck, &QCheckBox::toggled, this, [this](bool checked) {
        m_exposureSlider->setEnabled(!checked);
        m_gainSlider->setEnabled(!checked);
        m_brightnessSlider->setEnabled(!checked);
        if (m_livePreviewCheck->isChecked()) m_exposureThrottleTimer->start();
    });

    // Live preview
    m_livePreviewCheck = new QCheckBox("Live Preview (apply changes immediately)");
    layout->addWidget(m_livePreviewCheck);

    layout->addStretch();
    return widget;
}

QWidget *SettingsDialog::createCompressionTab()
{
    auto *widget = new QWidget;
    auto *layout = new QVBoxLayout(widget);
    layout->setSpacing(10);

    m_compressionEnabledCheck = new QCheckBox("Enable Automatic Compression");
    layout->addWidget(m_compressionEnabledCheck);

    // FFmpeg status
    m_ffmpegStatusLabel = new QLabel;
    auto [available, path] = m_compressor->checkFfmpegInstalled();
    if (available) {
        m_ffmpegStatusLabel->setText("FFmpeg: Found at " + path);
        m_ffmpegStatusLabel->setStyleSheet("color: #10b981; font-weight: bold;");
    } else {
        m_ffmpegStatusLabel->setText("FFmpeg: Not found");
        m_ffmpegStatusLabel->setStyleSheet("color: #dc2626; font-weight: bold;");
    }
    layout->addWidget(m_ffmpegStatusLabel);

    // Codec selection
    auto *codecGroup = new QGroupBox("Codec");
    auto *codecLayout = new QHBoxLayout(codecGroup);
    m_h264Radio = new QRadioButton("H.264");
    m_h265Radio = new QRadioButton("H.265");
    m_h264Radio->setChecked(true);
    codecLayout->addWidget(m_h264Radio);
    codecLayout->addWidget(m_h265Radio);
    codecLayout->addStretch();
    layout->addWidget(codecGroup);

    // CRF
    auto *crfLayout = new QHBoxLayout;
    crfLayout->addWidget(new QLabel("CRF:"));
    m_crfSlider = new QSlider(Qt::Horizontal);
    m_crfSlider->setRange(18, 35);
    m_crfSlider->setValue(23);
    crfLayout->addWidget(m_crfSlider, 1);
    m_crfValueLabel = new QLabel("23");
    m_crfValueLabel->setFixedWidth(30);
    m_crfValueLabel->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
    crfLayout->addWidget(m_crfValueLabel);
    connect(m_crfSlider, &QSlider::valueChanged, this, [this](int v) {
        m_crfValueLabel->setText(QString::number(v));
    });
    layout->addLayout(crfLayout);

    // Preset
    auto *presetLayout = new QHBoxLayout;
    presetLayout->addWidget(new QLabel("Preset:"));
    m_presetCombo = new QComboBox;
    m_presetCombo->addItems({"ultrafast", "fast", "medium", "slow"});
    m_presetCombo->setCurrentIndex(2);
    presetLayout->addWidget(m_presetCombo, 1);
    layout->addLayout(presetLayout);

    // Delete original
    m_deleteOriginalCheck = new QCheckBox("Delete original after compression");
    layout->addWidget(m_deleteOriginalCheck);

    // Priority
    auto *prioLayout = new QHBoxLayout;
    prioLayout->addWidget(new QLabel("Priority:"));
    m_priorityCombo = new QComboBox;
    m_priorityCombo->addItems({"low", "below_normal", "normal"});
    prioLayout->addWidget(m_priorityCombo, 1);
    layout->addLayout(prioLayout);

    layout->addStretch();
    return widget;
}

QWidget *SettingsDialog::createStorageTab()
{
    auto *widget = new QWidget;
    auto *layout = new QFormLayout(widget);
    layout->setSpacing(12);

    auto *makePathRow = [](QLineEdit *&edit, const char *btnText, auto slot, QObject *receiver) {
        auto *row = new QHBoxLayout;
        edit = new QLineEdit;
        row->addWidget(edit, 1);
        auto *btn = new QPushButton(btnText);
        QObject::connect(btn, &QPushButton::clicked, receiver, slot);
        row->addWidget(btn);
        return row;
    };

    layout->addRow("Video Storage:", makePathRow(m_videoPathEdit, "Browse...",
                                                  &SettingsDialog::browseVideoPath, this));
    layout->addRow("Database:", makePathRow(m_databasePathEdit, "Browse...",
                                             &SettingsDialog::browseDatabasePath, this));
    layout->addRow("Log Path:", makePathRow(m_logPathEdit, "Browse...",
                                             &SettingsDialog::browseLogPath, this));

    return widget;
}

void SettingsDialog::loadCurrentSettings()
{
    // Video
    QSize res = m_settings->getVideoResolution();
    QString resStr = QString("%1x%2").arg(res.width()).arg(res.height());
    int resIdx = m_resolutionCombo->findText(resStr);
    if (resIdx >= 0) m_resolutionCombo->setCurrentIndex(resIdx);

    int fps = m_settings->getVideoFps();
    QAbstractButton *fpsBtn = m_fpsGroup->button(fps);
    if (fpsBtn) fpsBtn->setChecked(true);
    else if (auto *btn30 = m_fpsGroup->button(30)) btn30->setChecked(true);

    QString codec = m_settings->getVideoCodec();
    int codecIdx = m_codecCombo->findText(codec);
    if (codecIdx >= 0) m_codecCombo->setCurrentIndex(codecIdx);

    // Camera
    int camIdx = m_settings->getCameraIndex();
    for (int i = 0; i < m_cameraCombo->count(); ++i) {
        if (m_cameraCombo->itemData(i).toInt() == camIdx) {
            m_cameraCombo->setCurrentIndex(i);
            break;
        }
    }

    m_autoExposureCheck->setChecked(m_settings->getCameraAutoExposure());
    m_exposureSlider->setValue(m_settings->getCameraExposure());
    m_gainSlider->setValue(m_settings->getCameraGain());
    m_brightnessSlider->setValue(m_settings->getCameraBrightness());

    m_exposureValueLabel->setText(QString::number(m_exposureSlider->value()));
    m_gainValueLabel->setText(QString::number(m_gainSlider->value()));
    m_brightnessValueLabel->setText(QString::number(m_brightnessSlider->value()));

    bool autoExp = m_autoExposureCheck->isChecked();
    m_exposureSlider->setEnabled(!autoExp);
    m_gainSlider->setEnabled(!autoExp);
    m_brightnessSlider->setEnabled(!autoExp);

    // Compression
    bool compEnabled = m_settings->get("compression", "enabled", false).toBool();
    m_compressionEnabledCheck->setChecked(compEnabled);

    QString compCodec = m_settings->get("compression", "codec", "h264").toString();
    if (compCodec == "h265") m_h265Radio->setChecked(true);
    else m_h264Radio->setChecked(true);

    m_crfSlider->setValue(m_settings->get("compression", "crf", 23).toInt());
    m_crfValueLabel->setText(QString::number(m_crfSlider->value()));

    QString preset = m_settings->get("compression", "preset", "medium").toString();
    int presetIdx = m_presetCombo->findText(preset);
    if (presetIdx >= 0) m_presetCombo->setCurrentIndex(presetIdx);

    m_deleteOriginalCheck->setChecked(m_settings->get("compression", "delete_original", true).toBool());

    QString priority = m_settings->get("compression", "priority", "below_normal").toString();
    int prioIdx = m_priorityCombo->findText(priority);
    if (prioIdx >= 0) m_priorityCombo->setCurrentIndex(prioIdx);

    // Storage
    m_videoPathEdit->setText(m_settings->getVideoStoragePath());
    m_databasePathEdit->setText(m_settings->getDatabasePath());
    m_logPathEdit->setText(m_settings->getLogPath());
}

void SettingsDialog::saveSettings()
{
    // Video - parse resolution
    QStringList resParts = m_resolutionCombo->currentText().split('x');
    if (resParts.size() == 2) {
        m_settings->set("video", "resolution_width", resParts[0].toInt());
        m_settings->set("video", "resolution_height", resParts[1].toInt());
    }

    int fps = m_fpsGroup->checkedId();
    if (fps > 0) m_settings->set("video", "fps", fps);

    m_settings->set("video", "codec", m_codecCombo->currentText());

    // Camera
    int camIndex = m_cameraCombo->currentData().toInt();
    m_settings->set("camera", "index", camIndex);
    m_settings->set("camera", "auto_exposure", m_autoExposureCheck->isChecked());
    m_settings->set("camera", "exposure", m_exposureSlider->value());
    m_settings->set("camera", "gain", m_gainSlider->value());
    m_settings->set("camera", "brightness", m_brightnessSlider->value());

    // Compression
    m_settings->set("compression", "enabled", m_compressionEnabledCheck->isChecked());
    m_settings->set("compression", "codec", m_h265Radio->isChecked() ? "h265" : "h264");
    m_settings->set("compression", "crf", m_crfSlider->value());
    m_settings->set("compression", "preset", m_presetCombo->currentText());
    m_settings->set("compression", "delete_original", m_deleteOriginalCheck->isChecked());
    m_settings->set("compression", "priority", m_priorityCombo->currentText());

    // Storage
    m_settings->set("storage", "video_path", m_videoPathEdit->text());
    m_settings->set("storage", "database_path", m_databasePathEdit->text());
    m_settings->set("storage", "log_path", m_logPathEdit->text());

    m_settings->save();
    accept();
}

void SettingsDialog::resetDefaults()
{
    int ret = QMessageBox::question(this, "Reset Settings",
                                     "Are you sure you want to reset all settings to defaults?",
                                     QMessageBox::Yes | QMessageBox::No);
    if (ret == QMessageBox::Yes) {
        m_settings->resetToDefaults();
        loadCurrentSettings();
    }
}

void SettingsDialog::browseVideoPath()
{
    QString dir = QFileDialog::getExistingDirectory(this, "Select Video Storage Directory",
                                                     m_videoPathEdit->text());
    if (!dir.isEmpty()) m_videoPathEdit->setText(dir);
}

void SettingsDialog::browseDatabasePath()
{
    QString file = QFileDialog::getSaveFileName(this, "Select Database File",
                                                 m_databasePathEdit->text(),
                                                 "SQLite Database (*.db)");
    if (!file.isEmpty()) m_databasePathEdit->setText(file);
}

void SettingsDialog::browseLogPath()
{
    QString dir = QFileDialog::getExistingDirectory(this, "Select Log Directory",
                                                     m_logPathEdit->text());
    if (!dir.isEmpty()) m_logPathEdit->setText(dir);
}

void SettingsDialog::refreshCameras()
{
    m_cameraCombo->clear();
    m_cameraCombo->addItem("Scanning cameras...", -1);
    m_cameraCombo->setEnabled(false);

    CameraUtils::refreshCamerasAsync([this](QList<CameraInfo> cameras) {
        QMetaObject::invokeMethod(this, [this, cameras]() {
            m_cameraCombo->clear();
            m_cameraCombo->setEnabled(true);
            for (const CameraInfo &cam : cameras) {
                m_cameraCombo->addItem(
                    QString("Camera %1: %2 (%3)").arg(cam.index).arg(cam.name).arg(cam.resolution),
                    cam.index);
            }
            if (m_cameraCombo->count() == 0) {
                m_cameraCombo->addItem("No cameras found", -1);
            }
        });
    });
}

void SettingsDialog::onExposureSliderChanged()
{
    if (m_camera) {
        m_camera->applyExposureSettings(
            m_autoExposureCheck->isChecked(),
            m_exposureSlider->value(),
            m_gainSlider->value(),
            m_brightnessSlider->value());
    }
}
