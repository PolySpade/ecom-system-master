#pragma once

#include <QDialog>
#include <QTabWidget>
#include <QComboBox>
#include <QCheckBox>
#include <QSlider>
#include <QLabel>
#include <QLineEdit>
#include <QRadioButton>
#include <QButtonGroup>
#include <QTimer>

class SettingsManager;
class CameraHandler;
class VideoCompressor;

class SettingsDialog : public QDialog {
    Q_OBJECT
public:
    explicit SettingsDialog(SettingsManager *settings, CameraHandler *camera,
                            VideoCompressor *compressor, QWidget *parent = nullptr);

private slots:
    void saveSettings();
    void resetDefaults();
    void browseVideoPath();
    void browseDatabasePath();
    void browseLogPath();
    void refreshCameras();
    void onExposureSliderChanged();

private:
    void setupUi();
    QWidget *createVideoTab();
    QWidget *createCameraTab();
    QWidget *createCompressionTab();
    QWidget *createStorageTab();
    void loadCurrentSettings();

    SettingsManager *m_settings;
    CameraHandler *m_camera;
    VideoCompressor *m_compressor;

    // Video tab
    QComboBox *m_resolutionCombo;
    QButtonGroup *m_fpsGroup;
    QComboBox *m_codecCombo;

    // Camera tab
    QComboBox *m_cameraCombo;
    QCheckBox *m_autoExposureCheck;
    QSlider *m_exposureSlider;
    QSlider *m_gainSlider;
    QSlider *m_brightnessSlider;
    QLabel *m_exposureValueLabel;
    QLabel *m_gainValueLabel;
    QLabel *m_brightnessValueLabel;
    QCheckBox *m_livePreviewCheck;
    QTimer *m_exposureThrottleTimer;

    // Compression tab
    QCheckBox *m_compressionEnabledCheck;
    QLabel *m_ffmpegStatusLabel;
    QRadioButton *m_h264Radio;
    QRadioButton *m_h265Radio;
    QSlider *m_crfSlider;
    QLabel *m_crfValueLabel;
    QComboBox *m_presetCombo;
    QCheckBox *m_deleteOriginalCheck;
    QComboBox *m_priorityCombo;

    // Storage tab
    QLineEdit *m_videoPathEdit;
    QLineEdit *m_databasePathEdit;
    QLineEdit *m_logPathEdit;
};
