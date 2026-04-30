#include "ui/MainWindow.h"
#include "ui/SavingProgressDialog.h"
#include "ui/SearchDialog.h"
#include "ui/SettingsDialog.h"
#include "core/SettingsManager.h"
#include "core/Database.h"
#include "core/BarcodeHandler.h"
#include "core/CameraHandler.h"
#include "core/VideoCompressor.h"

#include <QGridLayout>
#include <QHBoxLayout>
#include <QVBoxLayout>
#include <QFrame>
#include <QCloseEvent>
#include <QImage>
#include <QPixmap>
#include <QtConcurrent>
#include <QFutureWatcher>
#include <opencv2/imgproc.hpp>

MainWindow::MainWindow(QWidget *parent)
    : QMainWindow(parent)
{
    m_settings = new SettingsManager(QString(), this);
    m_db = new Database(m_settings->getDatabasePath(), this);
    m_barcodeHandler = new BarcodeHandler(this);
    m_camera = new CameraHandler(m_settings, this);
    m_compressor = new VideoCompressor(this);
    m_compressor->start();

    setupUi();

    m_cameraTimer = new QTimer(this);
    m_cameraTimer->setInterval(33);
    connect(m_cameraTimer, &QTimer::timeout, this, &MainWindow::updateCameraFeed);
    m_cameraTimer->start();

    m_statusTimer = new QTimer(this);
    m_statusTimer->setInterval(1000);
    connect(m_statusTimer, &QTimer::timeout, this, &MainWindow::updateStatus);
    m_statusTimer->start();

    connect(m_compressor, &VideoCompressor::compressionCompleted,
            this, [this](int transactionId, bool success, CompressionResult result) {
        if (success) {
            m_db->updateCompressionStatus(transactionId, result.status,
                                          result.compressedFileSizeMb,
                                          result.compressionRatio,
                                          result.compressedFilename);
            m_compressionStatus = QString("Compressed: %1 (%2% reduction)")
                                      .arg(result.compressedFilename)
                                      .arg(result.compressionRatio, 0, 'f', 1);
        } else {
            m_db->updateCompressionStatus(transactionId, "failed");
            m_compressionStatus = QString("Compression failed: %1").arg(result.message);
        }
        onCompressionCompleted(transactionId, success);
    });

    loadRecordings();
    m_barcodeEntry->setFocus();
}

MainWindow::~MainWindow() = default;

void MainWindow::setupUi()
{
    setWindowTitle("Ecom Video Tracker");
    resize(1000, 800);
    setMinimumSize(800, 600);

    auto *central = new QWidget(this);
    setCentralWidget(central);

    auto *mainLayout = new QVBoxLayout(central);
    mainLayout->setContentsMargins(0, 0, 0, 0);
    mainLayout->setSpacing(0);

    // Header
    auto *headerFrame = new QFrame;
    headerFrame->setObjectName("headerFrame");
    headerFrame->setStyleSheet(
        "QFrame#headerFrame { background: qlineargradient(x1:0, y1:0, x2:1, y2:0, "
        "stop:0 #667eea, stop:1 #764ba2); }");
    headerFrame->setFixedHeight(60);

    auto *headerLayout = new QHBoxLayout(headerFrame);
    headerLayout->setContentsMargins(20, 8, 20, 8);

    auto *titleLabel = new QLabel("Ecom Video Tracker");
    titleLabel->setObjectName("headerTitle");
    titleLabel->setStyleSheet("color: white; font-size: 24px; font-weight: bold; background: transparent;");
    headerLayout->addWidget(titleLabel);
    headerLayout->addStretch();

    auto *settingsButton = new QPushButton("Settings");
    settingsButton->setObjectName("settingsButton");
    connect(settingsButton, &QPushButton::clicked, this, &MainWindow::openSettings);
    headerLayout->addWidget(settingsButton);

    mainLayout->addWidget(headerFrame);

    // Content area
    auto *contentWidget = new QWidget;
    auto *contentLayout = new QHBoxLayout(contentWidget);
    contentLayout->setContentsMargins(12, 12, 12, 12);
    contentLayout->setSpacing(12);

    // Camera panel (left, stretch 3)
    auto *cameraCard = new QFrame;
    cameraCard->setProperty("class", "card");
    cameraCard->setStyleSheet(
        "QFrame { background-color: white; border: 1px solid #e2e8f0; border-radius: 8px; }");

    auto *cameraLayout = new QVBoxLayout(cameraCard);
    cameraLayout->setContentsMargins(12, 12, 12, 12);

    auto *cameraTitleLabel = new QLabel("Camera Feed");
    cameraTitleLabel->setObjectName("sectionTitle");
    cameraLayout->addWidget(cameraTitleLabel);

    // Camera view container with overlay support
    auto *cameraContainer = new QWidget;
    auto *cameraContainerLayout = new QVBoxLayout(cameraContainer);
    cameraContainerLayout->setContentsMargins(0, 0, 0, 0);

    m_cameraLabel = new QLabel;
    m_cameraLabel->setObjectName("cameraLabel");
    m_cameraLabel->setAlignment(Qt::AlignCenter);
    m_cameraLabel->setMinimumSize(320, 240);
    m_cameraLabel->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    m_cameraLabel->setText("Initializing camera...");
    m_cameraLabel->setStyleSheet("background-color: black; color: #64748b; border: 2px solid #334155; border-radius: 4px;");
    cameraContainerLayout->addWidget(m_cameraLabel);

    // Recording indicator overlaid on camera
    m_recordingIndicator = new QLabel("REC", m_cameraLabel);
    m_recordingIndicator->setObjectName("recordingIndicator");
    m_recordingIndicator->setFixedSize(60, 28);
    m_recordingIndicator->setAlignment(Qt::AlignCenter);
    m_recordingIndicator->move(10, 10);
    m_recordingIndicator->hide();

    cameraLayout->addWidget(cameraContainer, 1);
    contentLayout->addWidget(cameraCard, 3);

    // Control panel (right, stretch 2)
    auto *controlCard = new QFrame;
    controlCard->setProperty("class", "card");
    controlCard->setStyleSheet(
        "QFrame { background-color: white; border: 1px solid #e2e8f0; border-radius: 8px; }");

    auto *controlLayout = new QVBoxLayout(controlCard);
    controlLayout->setContentsMargins(12, 12, 12, 12);
    controlLayout->setSpacing(10);

    // Label combo
    auto *labelTitle = new QLabel("Label");
    labelTitle->setObjectName("sectionTitle");
    controlLayout->addWidget(labelTitle);

    m_labelCombo = new QComboBox;
    m_labelCombo->addItems({"Return and Refund Unboxing", "Return Parcel Unboxing", "Normal (Standard)"});
    m_labelCombo->setCurrentIndex(2);
    controlLayout->addWidget(m_labelCombo);

    // Barcode entry
    auto *barcodeTitle = new QLabel("Barcode");
    barcodeTitle->setObjectName("sectionTitle");
    controlLayout->addWidget(barcodeTitle);

    m_barcodeEntry = new QLineEdit;
    m_barcodeEntry->setPlaceholderText("Scan or type barcode...");
    connect(m_barcodeEntry, &QLineEdit::returnPressed, this, &MainWindow::processBarcode);
    controlLayout->addWidget(m_barcodeEntry);

    // Buttons
    auto *buttonLayout = new QHBoxLayout;

    m_submitButton = new QPushButton("Submit");
    m_submitButton->setObjectName("submitButton");
    connect(m_submitButton, &QPushButton::clicked, this, &MainWindow::processBarcode);
    buttonLayout->addWidget(m_submitButton);

    m_stopButton = new QPushButton("Stop");
    m_stopButton->setObjectName("stopButton");
    m_stopButton->setEnabled(false);
    connect(m_stopButton, &QPushButton::clicked, this, &MainWindow::manualStop);
    buttonLayout->addWidget(m_stopButton);

    controlLayout->addLayout(buttonLayout);

    m_searchButton = new QPushButton("Search Recordings");
    m_searchButton->setObjectName("searchButton");
    connect(m_searchButton, &QPushButton::clicked, this, &MainWindow::openSearchDialog);
    controlLayout->addWidget(m_searchButton);

    // System status card
    controlLayout->addSpacing(8);
    auto *statusTitle = new QLabel("System Status");
    statusTitle->setObjectName("sectionTitle");
    controlLayout->addWidget(statusTitle);

    auto *statusFrame = new QFrame;
    statusFrame->setStyleSheet(
        "QFrame { background-color: #f8fafc; border: 1px solid #e2e8f0; border-radius: 6px; padding: 8px; }");
    auto *statusFormLayout = new QVBoxLayout(statusFrame);
    statusFormLayout->setSpacing(4);

    m_statusLabel = new QLabel("Status: Ready");
    m_filenameLabel = new QLabel("File: --");
    m_durationLabel = new QLabel("Duration: 00:00");
    m_storageLabel = new QLabel("Storage: -- MB");
    m_compressionLabel = new QLabel("Compression: Idle");

    for (auto *lbl : {m_statusLabel, m_filenameLabel, m_durationLabel, m_storageLabel, m_compressionLabel}) {
        lbl->setStyleSheet("font-size: 12px; color: #475569; background: transparent; border: none;");
        statusFormLayout->addWidget(lbl);
    }

    controlLayout->addWidget(statusFrame);

    // Recent recordings
    controlLayout->addSpacing(8);
    auto *recentTitle = new QLabel("Recent Recordings");
    recentTitle->setObjectName("sectionTitle");
    controlLayout->addWidget(recentTitle);

    m_recordingsList = new QListWidget;
    m_recordingsList->setMaximumHeight(200);
    controlLayout->addWidget(m_recordingsList);

    controlLayout->addStretch();
    contentLayout->addWidget(controlCard, 2);

    mainLayout->addWidget(contentWidget, 1);

    // Status bar
    statusBar()->showMessage("Ready");
}

void MainWindow::updateCameraFeed()
{
    cv::Mat frame = m_camera->getPreviewFrame(m_cameraLabel->width(), m_cameraLabel->height());
    if (frame.empty()) return;

    cv::Mat rgb;
    cv::cvtColor(frame, rgb, cv::COLOR_BGR2RGB);
    QImage img(rgb.data, rgb.cols, rgb.rows, static_cast<int>(rgb.step), QImage::Format_RGB888);
    QPixmap pixmap = QPixmap::fromImage(img.copy());
    m_cameraLabel->setPixmap(pixmap.scaled(m_cameraLabel->size(), Qt::KeepAspectRatio, Qt::FastTransformation));
}

void MainWindow::updateStatus()
{
    if (m_camera->isRecording()) {
        int duration = m_camera->getRecordingDuration();
        int mins = duration / 60;
        int secs = duration % 60;
        m_durationLabel->setText(QString("Duration: %1:%2")
                                     .arg(mins, 2, 10, QChar('0'))
                                     .arg(secs, 2, 10, QChar('0')));
        m_statusLabel->setText("Status: Recording");
        m_storageLabel->setText(QString("Storage: %1 MB total").arg(m_db->getTotalStorageUsed(), 0, 'f', 1));
    }

    if (!m_compressionStatus.isEmpty()) {
        m_compressionLabel->setText(m_compressionStatus);
    }

    auto queueStatus = m_compressor->getQueueStatus();
    if (queueStatus.queueSize > 0) {
        statusBar()->showMessage(QString("Compression queue: %1 remaining").arg(queueStatus.queueSize));
    }
}

void MainWindow::processBarcode()
{
    QString text = m_barcodeEntry->text().trimmed();
    m_barcodeEntry->clear();

    if (text.isEmpty()) return;

    BarcodeResult result = m_barcodeHandler->processBarcode(text, m_camera->isRecording());

    switch (result.action) {
    case BarcodeResult::Start:
        startNewRecording(result.barcode, m_labelCombo->currentText());
        break;
    case BarcodeResult::StopAndStart:
        stopCurrentRecording("barcode", result.barcode, m_labelCombo->currentText());
        break;
    case BarcodeResult::Invalid:
        statusBar()->showMessage("Invalid barcode: " + text, 3000);
        break;
    }
}

void MainWindow::manualStop()
{
    if (m_camera->isRecording()) {
        stopCurrentRecording("manual");
    }
}

void MainWindow::startNewRecording(const QString &barcode, const QString &label)
{
    QString filename = m_camera->startRecording(barcode, label);
    m_currentTransactionId = m_db->createTransaction(barcode, filename, label);

    m_stopButton->setEnabled(true);
    m_recordingIndicator->show();
    m_statusLabel->setText("Status: Recording");
    m_filenameLabel->setText("File: " + filename);
    m_durationLabel->setText("Duration: 00:00");
    statusBar()->showMessage("Recording started: " + barcode);
}

void MainWindow::stopCurrentRecording(const QString &stopMethod, const QString &newBarcode, const QString &newLabel)
{
    if (!m_camera->isRecording()) return;

    m_stopButton->setEnabled(false);
    m_recordingIndicator->hide();

    auto *dialog = new SavingProgressDialog(this);
    dialog->show();

    int txId = m_currentTransactionId;
    m_currentTransactionId = -1;

    auto future = QtConcurrent::run([this]() { return m_camera->stopRecording(); });
    auto *watcher = new QFutureWatcher<RecordingInfo>(this);
    connect(watcher, &QFutureWatcher<RecordingInfo>::finished, this, [=]() {
        RecordingInfo info = watcher->result();
        m_db->completeTransaction(txId, info.duration, info.fileSizeMb, stopMethod);

        // Queue compression if enabled
        bool compressionEnabled = m_settings->get("compression", "enabled", false).toBool();
        if (compressionEnabled) {
            QVariantMap compSettings;
            compSettings["codec"] = m_settings->get("compression", "codec", "h264").toString();
            compSettings["crf"] = m_settings->get("compression", "crf", 23).toInt();
            compSettings["preset"] = m_settings->get("compression", "preset", "medium").toString();
            compSettings["delete_original"] = m_settings->get("compression", "delete_original", true).toBool();
            compSettings["priority"] = m_settings->get("compression", "priority", "below_normal").toString();

            // info.filename already contains the full path from CameraHandler
            QString videoPath = info.filename;
            m_compressor->queueCompression(videoPath, txId, compSettings);
            m_compressionStatus = "Compression: Queued";
        }

        m_statusLabel->setText("Status: Ready");
        m_filenameLabel->setText("File: --");
        m_durationLabel->setText("Duration: 00:00");

        dialog->close();
        dialog->deleteLater();
        watcher->deleteLater();

        if (!newBarcode.isEmpty()) {
            startNewRecording(newBarcode, newLabel);
        }

        loadRecordings();
        statusBar()->showMessage("Recording saved", 3000);
    });
    watcher->setFuture(future);
}

void MainWindow::loadRecordings()
{
    m_recordingsList->clear();
    QList<QVariantMap> records = m_db->getRecentTransactions(10);
    for (const QVariantMap &rec : records) {
        QString barcode = rec.value("barcode").toString();
        QString date = rec.value("created_at").toString();
        int duration = rec.value("duration_seconds", 0).toInt();
        QString label = rec.value("label").toString();
        QString text = QString("%1 | %2 | %3:%4 | %5")
                           .arg(barcode)
                           .arg(date.left(16))
                           .arg(duration / 60, 2, 10, QChar('0'))
                           .arg(duration % 60, 2, 10, QChar('0'))
                           .arg(label);
        m_recordingsList->addItem(text);
    }
}

void MainWindow::openSettings()
{
    SettingsDialog dlg(m_settings, m_camera, m_compressor, this);
    if (dlg.exec() == QDialog::Accepted) {
        m_camera->reinitialize();
    }
}

void MainWindow::openSearchDialog()
{
    SearchDialog dlg(m_db, m_settings, this);
    dlg.exec();
}

void MainWindow::onCompressionCompleted(int transactionId, bool success)
{
    Q_UNUSED(transactionId)
    if (success) {
        statusBar()->showMessage("Compression completed", 3000);
    } else {
        statusBar()->showMessage("Compression failed", 3000);
    }
    loadRecordings();
}

void MainWindow::closeEvent(QCloseEvent *event)
{
    if (m_camera->isRecording()) {
        m_camera->stopRecording();
        if (m_currentTransactionId >= 0) {
            m_db->completeTransaction(m_currentTransactionId, m_camera->getRecordingDuration(), 0, "app_close");
        }
    }
    m_compressor->stop();
    m_camera->cleanup();
    event->accept();
}
