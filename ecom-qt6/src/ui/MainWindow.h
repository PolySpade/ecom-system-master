#pragma once

#include <QMainWindow>
#include <QLabel>
#include <QLineEdit>
#include <QComboBox>
#include <QPushButton>
#include <QTimer>
#include <QStatusBar>
#include <QListWidget>

class SettingsManager;
class Database;
class BarcodeHandler;
class CameraHandler;
class VideoCompressor;

class MainWindow : public QMainWindow {
    Q_OBJECT
public:
    explicit MainWindow(QWidget *parent = nullptr);
    ~MainWindow();

protected:
    void closeEvent(QCloseEvent *event) override;

private slots:
    void updateCameraFeed();
    void updateStatus();
    void processBarcode();
    void manualStop();
    void openSettings();
    void openSearchDialog();
    void onCompressionCompleted(int transactionId, bool success);

private:
    void setupUi();
    void loadRecordings();
    void startNewRecording(const QString &barcode, const QString &label);
    void stopCurrentRecording(const QString &stopMethod, const QString &newBarcode = "", const QString &newLabel = "");

    // Core objects
    SettingsManager *m_settings;
    Database *m_db;
    BarcodeHandler *m_barcodeHandler;
    CameraHandler *m_camera;
    VideoCompressor *m_compressor;

    // UI widgets
    QLabel *m_cameraLabel;
    QLabel *m_recordingIndicator;
    QComboBox *m_labelCombo;
    QLineEdit *m_barcodeEntry;
    QPushButton *m_submitButton;
    QPushButton *m_stopButton;
    QPushButton *m_searchButton;
    QLabel *m_statusLabel;
    QLabel *m_filenameLabel;
    QLabel *m_durationLabel;
    QLabel *m_storageLabel;
    QLabel *m_compressionLabel;
    QListWidget *m_recordingsList;

    // Timers
    QTimer *m_cameraTimer;
    QTimer *m_statusTimer;

    // State
    int m_currentTransactionId = -1;
    QString m_compressionStatus;
};
